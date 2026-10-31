import AppKit
import BotChuCore

/// The release build under test: a copy with its own bundle identifier, so what it keeps in its
/// defaults (the status sidebar's visibility, the window's frame) never reaches the installed app's,
/// and without App Nap, launched in front on the fixture, and read through its frame marks
/// and accessibility.
final class AppUnderTest {
    static let bundleIdentifier = "local.BotChu.journeys"

    let bundle: URL
    let environment: [String: String]
    let marksURL: URL
    private(set) var running: NSRunningApplication?
    private var marksRead: UInt64 = 0
    private var partialLine = ""
    private(set) var marks: [FrameMarks.Mark] = []

    init(bundle: URL, environment: [String: String], marksURL: URL) {
        self.bundle = bundle
        self.environment = environment
        self.marksURL = marksURL
    }

    /// Copies `source` into `folder` under the journeys' bundle identifier, signed again.
    static func prepare(from source: URL, into folder: URL) throws -> URL {
        let copy = folder.appendingPathComponent("BotChu.app")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", [source.path, copy.path])
        let plistURL = copy.appendingPathComponent("Contents/Info.plist")
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any] else {
            throw HarnessFailure("\(plistURL.path) isn't a property list")
        }
        plist["CFBundleIdentifier"] = bundleIdentifier
        plist["CFBundleName"] = "BotChu Journeys"
        // Prevent App Nap as well as launching in front. Disabling App Nap alone does not keep
        // a background copy on the scheduling path of the owner's foreground interaction (#388).
        plist["LSAppNapIsDisabled"] = true
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        // As macOS/build.sh signs: with the development identity when there is one, else ad hoc.
        if (try? run("/usr/bin/codesign", ["-fs", "Apple Development", copy.path])) == nil {
            try run("/usr/bin/codesign", ["-fs", "-", copy.path])
        }
        return copy
    }

    /// Clears what an earlier run kept in the copy's defaults.
    static func forgetDefaults() {
        _ = try? run("/usr/bin/defaults", ["delete", bundleIdentifier])
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarnessFailure("\(tool) \(arguments.joined(separator: " ")) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    var pid: pid_t { running?.processIdentifier ?? 0 }
    var ax: AXElement { AXElement.application(pid) }

    /// Launches it in front, as the owner uses it, and returns when the launch began. LaunchServices can
    /// refuse a launch just after the last copy quit (`procNotFound`) and still have started the copy,
    /// so that copy is stopped and the launch tried again once.
    func launch() throws -> UInt64 {
        do {
            return try launchOnce()
        } catch {
            print("journeys: \(error); launching again")
            Self.stopCopies(where: { $0 == executable })
            sleep(2)
            return try launchOnce()
        }
    }

    private func launchOnce() throws -> UInt64 {
        for leftover in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier) {
            leftover.forceTerminate()
        }
        Self.stopCopies(where: Self.isLeftBehind)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.promptsUserIfNeeded = false
        configuration.environment = environment
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var launched: NSRunningApplication?
        nonisolated(unsafe) var failure: Error?
        let start = Self.now
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
            launched = app
            failure = error
            done.signal()
        }
        guard done.wait(timeout: .now() + 60) == .success else { throw HarnessFailure("BotChu didn't launch within 60 s") }
        guard let launched else { throw HarnessFailure("BotChu didn't launch: \(failure.map(String.init(describing:)) ?? "no app")") }
        running = launched
        return start
    }

    /// Quits it as the owner would, and waits until it has gone, with any copy of this run that
    /// LaunchServices lost track of.
    func quit(timeout: TimeInterval = 20) {
        defer { Self.stopCopies(where: { $0 == executable }) }
        guard let running else { return }
        let pid = running.processIdentifier
        running.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
        if kill(pid, 0) == 0 {
            print("journeys: BotChu didn't quit within \(Int(timeout)) s; forcing it")
            running.forceTerminate()
            while kill(pid, 0) == 0 { usleep(20_000) }
        }
        // Until LaunchServices has let it go too.
        let gone = Date().addingTimeInterval(5)
        while Date() < gone, NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).contains(where: { $0.processIdentifier == pid }) {
            usleep(20_000)
        }
        self.running = nil
    }

    var isRunning: Bool { pid > 0 && kill(pid, 0) == 0 }

    /// The copy's executable, as the system reports a process's path (`/private/var/…`).
    private var executable: String {
        let path = bundle.appendingPathComponent("Contents/MacOS/BotChu").path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is a copy in the work folder of a run whose harness has gone (`run-<pid>`).
    static func isLeftBehind(_ path: String) -> Bool {
        guard path.hasSuffix("/BotChu.app/Contents/MacOS/BotChu"), let run = path.range(of: "/botchu-journeys.noindex/run-"),
              let harness = pid_t(path[run.upperBound...].prefix(while: \.isNumber)) else { return false }
        return kill(harness, 0) != 0 && errno == ESRCH
    }

    /// Stops the processes whose executable `matches` accepts: politely, then after 10 s for good.
    static func stopCopies(where matches: (String) -> Bool) {
        var pids = [pid_t](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 256)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let copies = pids.prefix(max(count, 0)).filter { pid in
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && matches(String(cString: path))
        }
        guard !copies.isEmpty else { return }
        print("journeys: stopping copies of BotChu left running: \(copies.map(String.init).joined(separator: ", "))")
        copies.forEach { kill($0, SIGTERM) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, copies.contains(where: { kill($0, 0) == 0 }) { usleep(50_000) }
        copies.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
    }

    /// The marks written since the last read.
    @discardableResult
    func readMarks() -> [FrameMarks.Mark] {
        guard let handle = try? FileHandle(forReadingFrom: marksURL) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: marksRead)
        let data = handle.readDataToEndOfFile()
        marksRead += UInt64(data.count)
        let text = partialLine + String(decoding: data, as: UTF8.self)
        let complete = text.hasSuffix("\n") ? text : String(text[..<(text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex)])
        partialLine = String(text.dropFirst(complete.count))
        let new = FrameMarks.parse(complete)
        marks += new
        return new
    }

    /// The first mark named `name` committed after `start`, waiting up to `timeout`.
    func mark(_ name: String, after start: UInt64, timeout: TimeInterval = 5) throws -> FrameMarks.Mark {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            readMarks()
            if let found = marks.first(where: { $0.name == name && $0.nanoseconds >= start }) { return found }
            guard Date() < deadline else { throw HarnessFailure("BotChu wrote no \"\(name)\" mark within \(Int(timeout)) s") }
            guard isRunning else { throw HarnessFailure("BotChu quit while waiting for \"\(name)\"") }
            usleep(1_000)
        }
    }

    /// Waits until no mark has been written for `quiet` seconds (at most `limit`), so what an action
    /// set going has settled before the next one. Marks that keep coming while something animates
    /// or the main thread works (`FrameMarks.isContinuous`) don't count.
    func settle(quiet: TimeInterval = 0.3, limit: TimeInterval = 5) {
        let end = Date().addingTimeInterval(limit)
        func settling() -> Int { marks.count(where: { !FrameMarks.isContinuous($0.name) }) }
        var lastCount = settling(), lastChange = Date()
        while Date() < end {
            usleep(20_000)
            readMarks()
            let count = settling()
            if count != lastCount { lastCount = count; lastChange = Date() }
            else if Date().timeIntervalSince(lastChange) >= quiet { return }
        }
    }

    /// The marks between two times, read up to now.
    func marks(from start: UInt64, to end: UInt64 = .max) -> [FrameMarks.Mark] {
        readMarks()
        return marks.filter { $0.nanoseconds >= start && $0.nanoseconds <= end }
    }

    /// The longest stretch the main thread was busy without a frame, among those that ended between
    /// two times; 0 when none reached `FrameMarks.busyThreshold`.
    func longestBusy(from start: UInt64, to end: UInt64) -> Double {
        marks(from: start, to: end).compactMap { FrameMarks.busyMilliseconds($0.name) }.max() ?? 0
    }

    /// Stops the whole app, its main thread included, for `milliseconds`: a stall injected from
    /// outside, to check that a journey sees one.
    func stall(milliseconds: Double) {
        guard pid > 0, milliseconds > 0 else { return }
        kill(pid, SIGSTOP)
        usleep(useconds_t(milliseconds * 1_000))
        kill(pid, SIGCONT)
    }

    /// Its standard window, through accessibility.
    func window(timeout: TimeInterval = 10) throws -> AXElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = ax.windows.first(where: { $0.subrole == kAXStandardWindowSubrole as String }) { return window }
            usleep(50_000)
        }
        throw HarnessFailure("BotChu showed no window within \(Int(timeout)) s")
    }

    /// A covered, inactive app can be demoted even with App Nap disabled (#388). Measure the
    /// foreground interaction the journey describes, and check that it still has focus at the end.
    func requireForeground() throws {
        guard let focused = AXElement.systemWide.element(kAXFocusedApplicationAttribute), focused.pid == pid else {
            throw HarnessFailure("BotChu lost keyboard focus; foreground journeys cannot measure a background app")
        }
    }
}
