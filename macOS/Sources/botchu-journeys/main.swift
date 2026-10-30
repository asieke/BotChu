import AppKit
import BotChuCore

// The journeys harness (#323; README.md, Test): drives a release build of BotChu from its own process,
// in the background, through the Accessibility API, on a synthetic fixture with a fake Claude Code CLI.
//   botchu-journeys --app <BotChu.app> [--journeys <names or numbers>] [--baseline <file>]
//                   [--record <file>] [--repeats <n>] [--keep]
//   botchu-journeys dump --app <BotChu.app>     the app's accessibility tree on the fixture
//   botchu-journeys fake-claude <arguments…>    the fixture's Claude Code CLI (FakeClaude)

let usage = """
    usage: botchu-journeys --app <BotChu.app> [--journeys <names or numbers>] [--baseline <file>] [--record <file>] [--repeats <n>] [--keep]
           botchu-journeys dump --app <BotChu.app>
    """

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "fake-claude" { exit(FakeClaude.run(Array(arguments.dropFirst()))) }
setvbuf(stdout, nil, _IOLBF, 0)

let dumping = arguments.first == "dump"
if dumping { arguments.removeFirst() }
var options: [String: String] = [:]
var keep = false
while let flag = arguments.first {
    arguments.removeFirst()
    if flag == "--keep" { keep = true; continue }
    guard ["--app", "--journeys", "--baseline", "--record", "--repeats"].contains(flag), let value = arguments.first else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
    arguments.removeFirst()
    options[flag] = value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("journeys: \(message)\n".utf8))
    exit(1)
}

func load() -> [Double] {
    var load = [Double](repeating: 0, count: 3)
    _ = getloadavg(&load, 3)
    return load.map { ($0 * 100).rounded() / 100 }
}

func machine() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return "\(String(cString: model)), \(ProcessInfo.processInfo.activeProcessorCount) cores, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
}

guard let appPath = options["--app"] else { fail("--app <BotChu.app> is required\n\(usage)") }
let selection: JourneySelection
do { selection = try JourneySelection.parse(options["--journeys"] ?? "", catalog: Journeys.catalog) } catch { fail("\(error)") }
let repeats = options["--repeats"].flatMap(Int.init) ?? 6
let baseline: JourneyBaseline?
if let path = options["--baseline"], FileManager.default.fileExists(atPath: path) {
    do { baseline = try JourneyBaseline.decode(Data(contentsOf: URL(fileURLWithPath: path))) } catch { fail("Couldn't read the baseline \(path): \(error)") }
} else {
    baseline = nil
}

do { try Permission.requireAccessibility() } catch { fail("\(error)") }

let source = URL(fileURLWithPath: appPath).standardizedFileURL
guard FileManager.default.fileExists(atPath: source.appendingPathComponent("Contents/MacOS/BotChu").path) else { fail("\(source.path) isn't a BotChu build") }
let work = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-journeys.noindex/run-\(getpid())", isDirectory: true)
let started = Date()
let loadBefore = load()
print("journeys: start; load \(loadBefore.map { String($0) }.joined(separator: " ")); \(machine()); "
      + (Permission.responsibleApp().map { "Accessibility through \($0.lastPathComponent); " } ?? "") + "work \(work.path)")

let app: AppUnderTest
let fixture: Fixture
do {
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let harness = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    let fake = work.appendingPathComponent("fake-claude")
    try FakeClaude.writeWrapper(at: fake, harness: harness)
    let began = Date()
    fixture = try Fixture.make(in: work.appendingPathComponent("data"), fakeCLI: fake.path)
    print(String(format: "journeys: fixture made in %.1f s", Date().timeIntervalSince(began)))
    let bundle = try AppUnderTest.prepare(from: source, into: work)
    AppUnderTest.forgetDefaults()
    let marks = work.appendingPathComponent("marks.txt")
    FileManager.default.createFile(atPath: marks.path, contents: nil)
    app = AppUnderTest(bundle: bundle, environment: [
        "BOTCHU_DATA_DIR": fixture.data.path,
        FrameMarks.environmentKey: marks.path,
        "BOTCHU_PROFILE": "Journey Claude|claude|\(fake.path)",
        "BOTCHU_JOURNEY_FAKE_LOG": work.appendingPathComponent("fake-claude.log").path,
    ], marksURL: marks)
} catch {
    fail("\(error)")
}

func finish(_ code: Int32) -> Never {
    app.quit()
    AppUnderTest.forgetDefaults()
    if !keep { try? FileManager.default.removeItem(at: work) }
    exit(code)
}

if dumping {
    do {
        _ = try app.launch()
        _ = try app.mark(FrameMarks.chat(fixture.longBot.id), after: 0, timeout: 60)
        app.settle(quiet: 1)
        var lines: [String] = []
        try app.window().dump(into: &lines)
        print(lines.joined(separator: "\n"))
        print("marks:\n" + app.marks.map { "\($0.nanoseconds) \($0.name)" }.joined(separator: "\n"))
        finish(0)
    } catch {
        print("journeys: \(error)")
        finish(1)
    }
}

var results: [JourneyResult] = []
let journeys = Journeys(app: app, fixture: fixture, baseline: baseline, repeats: repeats) { print("journey \($0.report)") }
if selection.numbers.contains(1) {
    results += journeys.launch()
} else {
    do {
        let start = try app.launch()
        _ = try app.mark(FrameMarks.chat(fixture.longBot.id), after: start, timeout: 60)
        app.settle(quiet: 0.5, limit: 10)
    } catch {
        print("journeys: \(error)")
        finish(1)
    }
}
if app.isRunning, let window = try? app.window(), let button = window.first(identifier: "toolbar-status") {
    // What an action costs before the app acts on it: a request SwiftUI answers on the app's main thread.
    let trips = (0..<10).map { _ in
        let start = AppUnderTest.now
        _ = button.label
        return Double(AppUnderTest.now - start) / 1_000_000
    }
    print(String(format: "journeys: accessibility round trip %.2f ms (median of 10)", JourneyStats.median(trips) ?? 0))
    // Accessibility's frames are from the top left of the main screen, AppKit's from its bottom left.
    if let frame = window.frame, let height = NSScreen.screens.first?.frame.height,
       let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: height - frame.midY)) }) {
        print("journeys: window \(Int(frame.width))×\(Int(frame.height)) on a \(screen.maximumFramesPerSecond) Hz display")
    }
}
for (number, run) in [(2, journeys.sidebarAndInspector), (3, journeys.switchBots)] where selection.numbers.contains(number) {
    if app.isRunning { results += run() }
    else { results.append(journeys.notRun(number, because: "BotChu isn't running")) }
}

let loadAfter = load()
let failed = results.filter { !$0.passed }
print("journeys: \(results.count - failed.count) of \(results.count) steps within budget in \(Int(Date().timeIntervalSince(started))) s; "
      + "load \(loadBefore.map { String($0) }.joined(separator: " ")) → \(loadAfter.map { String($0) }.joined(separator: " "))")
for result in failed { print("journeys: FAILED \(result.report)") }
if let path = options["--record"] {
    let commit = (Bundle(url: app.bundle)?.object(forInfoDictionaryKey: "BotChuCommit") as? String) ?? ""
    let recorded = JourneyBaseline(recordedAt: started, commit: commit, machine: machine(), loadBefore: loadBefore, loadAfter: loadAfter, results: results)
    do {
        let file = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try recorded.encoded().write(to: file)
        print("journeys: recorded the baseline in \(path)")
    } catch {
        print("journeys: couldn't record the baseline: \(error)")
    }
}
finish(failed.isEmpty ? 0 : 1)
