import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// What a launch costs with months of history (#109): eight bots, forty open tasks, sixteen closed
/// ones and a hundred finished sub-agents, over 100 MB of transcripts on disk. Not part of
/// `scripts/check.sh`, and it asserts nothing about time, which varies with load: it runs only with
/// `BOTCHU_LAUNCH_BENCHMARK` set, prints a table and, when the variable names a file, writes it there.
///
///     BOTCHU_LAUNCH_BENCHMARK=/tmp/launch-bench.txt swift test --configuration release \
///         --package-path macOS --filter launchBenchmark
///
/// Each launch makes the model over the folder, puts the window up and draws it, then types into the
/// composer, waits for the selected conversation's messages, and opens a conversation never shown,
/// each timed from the launch's start (the last from its click) until the window has drawn it.
/// `BOTCHU_LAUNCH_SAMPLES` sets how many launches (30 by default). One more launch then opens every
/// Home and open task, one after another, and reads how much memory the process keeps. Counters say
/// how many files were read, decoded, written and copied by the time the window was drawn, and once
/// background work settled.
extension RenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_LAUNCH_BENCHMARK"] != nil))
    func launchBenchmark() async throws {
        _ = NSApplication.shared
        let environment = ProcessInfo.processInfo.environment
        let built = DispatchTime.now().uptimeNanoseconds
        let bench = try LaunchBenchFixture()
        defer { bench.cleanUp() }
        var report = ChatBenchReport()
        report.note(String(format: "Fixture: %d bots, %d open tasks, %d closed tasks, %d finished sub-agents; %.1f MB in %d messages, written in %.1f s",
                           bench.bots.count, bench.openTasks.count, bench.closedTasks, bench.children, Double(bench.bytes) / 1_000_000,
                           bench.messages, Double(DispatchTime.now().uptimeNanoseconds - built) / 1_000_000_000))
        report.note("Machine: \(LaunchBenchFixture.machine()); warm file cache (the fixture was just written and is read again each launch)")
        report.note("Load before: \(ChatBenchReport.load())")
        let samples = Int(environment["BOTCHU_LAUNCH_SAMPLES"] ?? "") ?? 30

        var initTimes: [Double] = [], windows: [Double] = [], inputs: [Double] = [], contents: [Double] = []
        var opens: [Double] = [], openedShown: [Double] = []
        var atWindow = HistoryCounters.Counts(), settled = HistoryCounters.Counts()
        for index in 0..<samples {
            let target = bench.openTasks[index % bench.openTasks.count]
            let sample = try await bench.launch(opening: target)
            initTimes.append(sample.initialized)
            windows.append(sample.window)
            inputs.append(sample.input)
            contents.append(sample.content)
            opens.append(sample.openFeedback)
            openedShown.append(sample.opened)
            if index == 0 {
                atWindow = sample.atWindow
                settled = sample.settled
            }
        }
        report.add("Model made (launch to init's end)", initTimes)
        report.add("First usable window (drawn)", windows)
        report.add("First input (typed into the composer)", inputs)
        report.add("First selected content (drawn)", contents)
        report.add("Open an uncached task: first draw", opens)
        report.add("  …its messages drawn", openedShown)
        report.note("Counters by the first window (launch 1): \(atWindow.summary)")
        report.note("Counters once background work settled (launch 1): \(settled.summary)")

        let memory = try await bench.visitEverything()
        report.add("Open each of 48 histories in turn (shown)", memory.visits)
        report.note(String(format: "Memory after visiting all 48 histories: footprint %.1f MB (%.1f MB above the fixture's baseline), heap in use %.1f MB; %d conversations hold %.1f MB of messages",
                           Double(memory.footprint) / 1_000_000, Double(memory.footprint - memory.baseline) / 1_000_000,
                           Double(memory.heap) / 1_000_000, memory.loaded, Double(memory.retained) / 1_000_000))
        report.note("Counters for that launch: \(memory.counts.summary)")
        report.note("Every message decoded: \(memory.allDecoded ? "yes" : "NO") (\(memory.decodedOpen) of \(bench.openMessages) in Homes and open tasks)")
        report.note("Load after: \(ChatBenchReport.load())")

        let text = report.text(title: "Launch benchmark · \(samples) launches")
        print(text)
        if let path = environment["BOTCHU_LAUNCH_BENCHMARK"], path.hasPrefix("/") {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Eight bots, each with a Home of 400 messages, five open tasks of 600 and two closed ones of 600,
/// and a hundred finished sub-agents of 60 messages: a fifth under Homes, the rest under tasks, a
/// third of those under closed ones. Every message is written by BotChu's own encoder, so each one
/// decodes.
@MainActor final class LaunchBenchFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-launch-\(UUID().uuidString)")
    let domain = "local.BotChu.LaunchBenchmark.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    private(set) var bots: [Bot] = []
    /// The Homes and open tasks, with how many messages each holds.
    private(set) var openTasks: [ChatTarget] = []
    private(set) var expected: [ChatTarget: Int] = [:]
    private(set) var closedTasks = 0
    private(set) var children = 0
    private(set) var bytes = 0
    private(set) var messages = 0
    private(set) var openMessages = 0
    var homes: [ChatTarget] { bots.map { .home($0.id) } }

    struct Launch {
        var initialized: Double
        var window: Double
        var input: Double
        var content: Double
        var openFeedback: Double
        var opened: Double
        var atWindow: HistoryCounters.Counts
        var settled: HistoryCounters.Counts
    }

    struct Visit {
        var visits: [Double]
        var footprint: Int
        var baseline: Int
        var heap: Int
        var loaded: Int
        var retained: Int
        var counts: HistoryCounters.Counts
        var allDecoded: Bool
        var decodedOpen: Int
    }

    init() throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        let start = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate - 90 * 86_400).rounded(.down))
        var entries: [Store.Entry] = []
        var childIndex = 0
        for b in 0..<8 {
            let bot = Bot(name: "Bot \(b + 1)", accountID: "claude-dev", workspace: root.appendingPathComponent("bots/bot-\(b + 1)").path)
            let home = BotHome(workspace: bot.workspace)
            try home.save(bot)
            bots.append(bot)
            entries.append(Store.Entry(id: bot.id, workspace: bot.workspace))
            try write(Self.conversation(turns: 33, start: start), to: home, task: nil, target: .home(bot.id), open: true)
            var roots: [UUID?] = [nil]
            for t in 0..<7 {
                var task = BotTask(for: bot, repo: "bench/repo-\(b)-\(t)", checkout: root.appendingPathComponent("repos/r").path, work: nil,
                                   brief: "Task \(t) of bot \(b + 1)")
                task.folder = root.appendingPathComponent("repos/r").path
                task.createdAt = start.addingTimeInterval(Double(t) * 3_600)
                let closed = t >= 5
                if closed { task.archivedAt = start.addingTimeInterval(Double(t) * 3_600 + 1_800) }
                try home.save(task)
                try write(Self.conversation(turns: 52, start: start), to: home, task: task.id, target: .task(task.id, of: bot.id), open: !closed)
                if closed { closedTasks += 1 } else { openTasks.append(.task(task.id, of: bot.id)) }
                roots.append(task.id)
            }
            // Twelve or thirteen finished sub-agents per bot: under its Home, open tasks and closed tasks.
            let count = b < 4 ? 13 : 12
            for c in 0..<count {
                let taskID = roots[c % roots.count]
                let helper = Bot(name: "Helper", emoji: "🦝", workspace: root.appendingPathComponent("helper").path)
                var run = SubagentRun(rootBotID: bot.id, rootTaskID: taskID, depth: 1, targetBot: helper, title: "Look into area \(c)",
                                      brief: "Look into area \(c) and report.", workingDirectory: bot.workspace, phase: .completed,
                                      createdAt: start.addingTimeInterval(Double(childIndex) * 60))
                run.startedAt = run.createdAt.addingTimeInterval(1)
                run.finishedAt = run.createdAt.addingTimeInterval(40)
                run.handoffOutput = "All done in area \(c)."
                try home.saveSubagent(run)
                let thread = Self.conversation(turns: 5, start: run.createdAt)
                bytes += try home.saveSubagentThread(thread, id: run.id, taskID: taskID)
                messages += thread.count
                children += 1
                childIndex += 1
            }
        }
        try store.saveIndex(entries)
    }

    private func write(_ thread: [ChatMessage], to home: BotHome, task: UUID?, target: ChatTarget, open: Bool) throws {
        bytes += try home.writeTranscript(thread, task: task)
        messages += thread.count
        if open {
            expected[target] = thread.count
            openMessages += thread.count
        }
    }

    func cleanUp() {
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Launching

    nonisolated private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    nonisolated private static func ms(_ from: UInt64, _ to: UInt64 = now()) -> Double { Double(to - from) / 1_000_000 }

    private func window(for app: AppModel) -> NSWindow {
        let defaults = UserDefaults(suiteName: domain)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AnyView(ContentView().environment(app).defaultAppStorage(defaults)))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private static func draw(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func waitUntil(_ window: NSWindow, timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw LaunchBenchFailure("timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
        draw(window)
    }

    private func close(_ window: NSWindow, _ app: AppModel, storage: StorageQueue) async {
        window.contentView = nil
        window.close()
        app.stopAll()
        storage.wait(timeout: 10)
        await storage.settle()
    }

    /// One launch: the window, a keystroke, the selected conversation, then `target` opened.
    func launch(opening target: ChatTarget) async throws -> Launch {
        HistoryCounters.shared.reset(under: root)
        let storage = StorageQueue()
        let start = Self.now()
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in benchmarks.") },
                           storage: storage)
        let initialized = Self.ms(start)
        let window = window(for: app)
        Self.draw(window)
        let drawn = Self.ms(start)
        let atWindow = HistoryCounters.shared.counts(under: root)
        let selected = app.tab(of: try #require(app.selection))
        // A keystroke into the composer, as soon as the window is up.
        let editor = try #require(Self.textView(in: window.contentView))
        window.makeFirstResponder(editor)
        editor.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Self.waitUntil(window) { app.drafts[selected] == "x" }
        let input = Self.ms(start)
        let count = expected[selected] ?? 0
        try await Self.waitUntil(window) { app.thread(selected).count >= count }
        let content = Self.ms(start)
        // A conversation never shown in this launch.
        try await Task.sleep(for: .milliseconds(150))
        let click = Self.now()
        app.show(target)
        Self.draw(window)
        let feedback = Self.ms(click)
        let opened = expected[target] ?? 0
        try await Self.waitUntil(window) { app.thread(target).count >= opened }
        let shown = Self.ms(click)
        try await Task.sleep(for: .milliseconds(400))
        await storage.settle()
        let settled = HistoryCounters.shared.counts(under: root)
        await close(window, app, storage: storage)
        return Launch(initialized: initialized, window: drawn, input: input, content: content, openFeedback: feedback, opened: shown,
                      atWindow: atWindow, settled: settled)
    }

    /// One launch that opens every Home and open task in turn, then reads the process's memory.
    func visitEverything() async throws -> Visit {
        HistoryCounters.shared.reset(under: root)
        try await Task.sleep(for: .milliseconds(300))
        let baseline = Self.footprint()
        let storage = StorageQueue()
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in benchmarks.") },
                           storage: storage)
        let window = window(for: app)
        Self.draw(window)
        var visits: [Double] = []
        var decodedOpen = 0
        for target in homes + openTasks {
            let count = expected[target] ?? 0
            let click = Self.now()
            app.show(target)
            Self.draw(window)
            try await Self.waitUntil(window) { app.thread(target).count >= count }
            visits.append(Self.ms(click))
            decodedOpen += app.thread(target).count
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(500))
        await storage.settle()
        Self.draw(window)
        let footprint = Self.footprint()
        let heap = ChatBenchReport.heapInUse()
        let loaded = app.conversations.values.filter { !$0.messages.isEmpty }
        let retained = loaded.reduce(0) { sum, conversation in
            sum + conversation.messages.reduce(0) { $0 + $1.text.utf8.count + ($1.toolInput?.utf8.count ?? 0) + ($1.toolOutput?.utf8.count ?? 0) }
        }
        let counts = HistoryCounters.shared.counts(under: root)
        await close(window, app, storage: storage)
        return Visit(visits: visits, footprint: footprint, baseline: baseline, heap: heap, loaded: loaded.count, retained: retained,
                     counts: counts, allDecoded: decodedOpen == openMessages, decodedOpen: decodedOpen)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable { return text }
        for child in view.subviews {
            if let found = textView(in: child) { return found }
        }
        return nil
    }

    /// The process's physical footprint, as Activity Monitor's Memory column shows it.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func machine() -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buffer = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname(name, &buffer, &size, nil, 0)
            return String(cString: buffer)
        }
        var memory: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memory, &size, nil, 0)
        return "\(sysctl("machdep.cpu.brand_string")), \(memory / 1_073_741_824) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    // MARK: Conversations

    static let reply = """
    ## Finding

    The sidebar's selection drives **which conversation** is shown, through `AppModel.tab(of:)`. Switching \
    rebuilds the chat; see [the docs](https://example.com/docs) for the layout rules.

    - Read the thread once per switch.
    - Keep the composer's draft.
    - Leave the inspector's tab alone.

    ```swift
    let target = model.tab(of: id)
    print(target)
    ```

    Next I'll check how long threads load.
    """

    /// `turns` turns of twelve messages: the owner's message, nine tool calls with about 3 KB of
    /// output each, and two replies.
    static func conversation(turns: Int, start: Date) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var clock = start
        func next() -> Date {
            clock = clock.addingTimeInterval(7)
            return clock
        }
        for turn in 0..<turns {
            messages.append(ChatMessage(role: .user, text: "Step \(turn): keep going with the next part.", date: next()))
            for call in 0..<9 {
                let file = "/Users/me/project/macOS/Sources/BotChu/\(["App", "Chat", "Inspector", "Sidebar"][call % 4])/File\(call).swift"
                let (name, input) = call % 3 == 0 ? ("Read", file) : call % 3 == 1 ? ("Grep", "func tab\\(of") : ("Bash", "swift build --package-path macOS")
                messages.append(ChatMessage(role: .tool, date: next(), toolID: "call-\(turn)-\(call)", toolName: name, toolInput: input,
                                            toolOutput: String(repeating: "line \(call) of the output, with some words in it\n", count: 60),
                                            toolState: .done, toolExitCode: name == "Bash" ? 0 : nil))
                if call == 4 || call == 8 { messages.append(ChatMessage(role: .assistant, text: "Turn \(turn).\(call)\n\n" + reply, date: next())) }
            }
        }
        return messages
    }
}

struct LaunchBenchFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
