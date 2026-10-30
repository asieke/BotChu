import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// Run on both revisions with the same fixture, through the window gate (#321). This file compiles
/// on the revision before the checkout cache too, for a real before/after pair.
extension RenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_PROJECTS_BENCHMARK"] != nil))
    func projectsTableBenchmark() async throws {
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let repoCount = environment["BOTCHU_PROJECTS_ROWS"].flatMap(Int.init) ?? 60
        let cycles = environment["BOTCHU_PROJECTS_CYCLES"].flatMap(Int.init) ?? 2
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-projects-bench-\(UUID().uuidString)")
        let domain = "BotChu.ProjectsBenchmark.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let repos = root.appendingPathComponent("repos").path
        try FileManager.default.createDirectory(atPath: repos, withIntermediateDirectories: true)
        // Real checkouts: clean, behind, ahead, with local changes, or not cloned.
        let origin = root.appendingPathComponent("origin").path
        try fixtureGit(["init", "-q", "-b", "main", origin], in: root.path)
        for n in 1...12 { try fixtureGit(["commit", "-q", "--allow-empty", "-m", "Commit \(n)"], in: origin) }
        var kinds: [String: Int] = [:], cloned: [String] = []
        for index in 0..<repoCount {
            let path = repos + "/repo-\(index)"
            if index % 7 == 3 { kinds["none", default: 0] += 1; continue }
            try fixtureGit(["clone", "-q", origin, path], in: root.path)
            cloned.append(path)
            switch index % 5 {
            case 0: try fixtureGit(["reset", "-q", "--hard", "HEAD~\(index % 9 + 1)"], in: path); kinds["behind", default: 0] += 1
            case 1: try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8); kinds["dirty", default: 0] += 1
            case 2:
                try fixtureGit(["commit", "-q", "--allow-empty", "-m", "Local"], in: path)
                try "draft".write(toFile: path + "/notes.txt", atomically: true, encoding: .utf8)
                kinds["ahead and dirty", default: 0] += 1
            default: kinds["clean", default: 0] += 1
            }
        }

        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Scout", emoji: "🦊", workspace: root.appendingPathComponent("bot").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = repos
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in benchmarks.") },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        app.sailKey = { nil }
        app.repositories = (0..<repoCount).map {
            GitHubLookup.Repo(nameWithOwner: "octocat/repo-\($0)", description: "Benchmark repository \($0)", pushedAt: Date().addingTimeInterval(-Double($0) * 3600),
                              isPrivate: $0.isMultiple(of: 2), openIssues: $0 % 4, openPullRequests: $0 % 3)
        }
        app.repositoriesReadAt = Date()
        for index in 0..<repoCount {
            let metadata = ProjectMetadata(name: "repo-\(index)", kind: index.isMultiple(of: 3) ? .hosted : .local, deploy: "local:my-mac:~/apps/repo-\(index)")
            app.projectRecords["octocat/repo-\(index)"] = ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(metadata), sha: "\(index)")
        }
        defaults.set("table", forKey: "projectsLayoutV2")
        defaults.set("repositories", forKey: "projectsScope")
        app.destination = .projects

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let busy = MainThreadBusy()
        busy.start()
        defer { busy.stop() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        let shown = DispatchTime.now().uptimeNanoseconds
        func draw() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func milliseconds(since start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        // Every checkout read once, and drawn.
        try await Task.sleep(for: .seconds(5))
        draw()
        let table = try #require(projectsBenchTable(in: window.contentView!))
        let scroller = try #require(table.enclosingScrollView)
        #expect(table.numberOfRows == repoCount)
        let heights = (0..<table.numberOfRows).map { table.rect(ofRow: $0).height }

        var report = ChatBenchReport()
        report.note("\(repoCount) repositories (\(kinds.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))); "
                    + "1400×820 window; \(ProcessInfo.processInfo.operatingSystemVersionString)")
        report.note("Load before: \(ChatBenchReport.load())")
        report.note(String(format: "Row heights: %.0f–%.0f pt (%d rows)", heights.min() ?? 0, heights.max() ?? 0, heights.count))

        // The periodic re-read of every checkout, 30 seconds after the first: main-thread work
        // between cycles, with nothing else asked of the window. Before each, every checkout is
        // fetched (its FETCH_HEAD written), as agents do, so each cycle has news for every row.
        let firstCycle = Double(DispatchTime.now().uptimeNanoseconds - shown) / 1e9
        try await Task.sleep(for: .seconds(max(0, 25 - firstCycle)))
        busy.reset()
        let cpu = projectsBenchChildCPU()
        for _ in 0..<cycles {
            for path in cloned { try Data().write(to: URL(fileURLWithPath: path + "/.git/FETCH_HEAD")) }
            try await Task.sleep(for: .seconds(30))
        }
        let refresh = busy.samples
        report.add("Main-thread blocks over \(cycles) refresh cycles", refresh)
        if cycles > 0 { report.note(String(format: "Per refresh cycle: %.1f ms of main-thread work in %.0f run-loop wakeups (%.0f of them over 1 ms); %.0f ms of git's CPU",
                           refresh.reduce(0, +) / Double(cycles), Double(refresh.count) / Double(cycles),
                           Double(refresh.filter { $0 > 1 }.count) / Double(cycles), (projectsBenchChildCPU() - cpu) / Double(cycles))) }

        let made = (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: false) != nil }.count
        report.note("Rows made before scrolling: \(made) of \(table.numberOfRows)")
        // Scrolling: one 20-point step a frame, down to the end and back, until drawn. The first
        // way down makes the rows not shown yet; later passes reuse them.
        let clip = scroller.contentView
        let bottom = max(0, table.frame.height - clip.bounds.height)
        var y: CGFloat = 0, direction: CGFloat = 1, reachedBottom = false
        var frames: [Double] = [], firstDown: [Double] = [], later: [Double] = []
        busy.reset()
        for _ in 0..<240 {
            y = min(bottom, max(0, y + 20 * direction))
            let start = DispatchTime.now().uptimeNanoseconds
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroller.reflectScrolledClipView(clip)
            draw()
            frames.append(milliseconds(since: start))
            if reachedBottom { later.append(frames.last!) } else { firstDown.append(frames.last!) }
            if y == bottom { reachedBottom = true }
            if y == bottom || y == 0 { direction = -direction }
            try await Task.sleep(for: .milliseconds(16))
        }
        let between = busy.samples
        report.add("Scroll 20 pt and draw", frames)
        report.add("  the first way down", firstDown)
        report.add("  later passes", later)
        report.add("Main-thread blocks while scrolling", between)
        // A row at a time, so each step brings one row in whatever their heights.
        var rows: [Double] = []
        for pass in 0..<4 {
            for index in pass.isMultiple(of: 2) ? Array(0..<table.numberOfRows) : (0..<table.numberOfRows).reversed() {
                let row = table.rect(ofRow: index)
                let target = pass.isMultiple(of: 2) ? row.maxY - clip.bounds.height : row.minY
                guard target > 0, target < bottom else { continue }
                let start = DispatchTime.now().uptimeNanoseconds
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                scroller.reflectScrolledClipView(clip)
                draw()
                rows.append(milliseconds(since: start))
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        report.add("Scroll one row and draw", rows)
        report.note(String(format: "Scrolled %.0f pt of %.0f", bottom, table.frame.height))
        report.note("Load after: \(ChatBenchReport.load())")
        let text = report.text(title: "#321 Projects table benchmark")
        print(text)
        if let path = environment["BOTCHU_PROJECTS_BENCHMARK"], path.hasPrefix("/") {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// How long each turn of the main run loop works, from waking to waiting again.
@MainActor private final class MainThreadBusy {
    private(set) var samples: [Double] = []
    private var woke: UInt64?
    private var observer: CFRunLoopObserver?

    func start() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if activity == .afterWaiting {
                    self.woke = now
                } else if let woke = self.woke {
                    self.samples.append(Double(now - woke) / 1_000_000)
                    self.woke = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func reset() { samples = [] }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
    }
}

/// The CPU time of the processes this one started and waited for, in milliseconds.
private func projectsBenchChildCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_CHILDREN, &usage)
    func ms(_ time: timeval) -> Double { Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000 }
    return ms(usage.ru_utime) + ms(usage.ru_stime)
}

@MainActor private func projectsBenchTable(in view: NSView) -> NSTableView? {
    (view as? NSTableView) ?? view.subviews.lazy.compactMap { projectsBenchTable(in: $0) }.first
}

/// git itself, without the login shell, for a fixture's checkouts.
func fixtureGit(_ arguments: [String], in directory: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
}
