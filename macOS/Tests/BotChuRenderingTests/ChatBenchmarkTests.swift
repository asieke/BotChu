import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import BotChuCore
@testable import BotChu

/// Chat latency with realistic histories (#48): conversation switching, streamed replies (also a
/// long one being written, with the composer typed in meanwhile, and a rich one until WebKit has
/// drawn it, #106), a live many-call exploration, seventeen sub-agents, expanding a group or a
/// large output, and the grouping itself. Not part of
/// `scripts/check.sh`, and it asserts nothing about time, which varies with load: it runs only with
/// `BOTCHU_BENCHMARK` set, prints a table and, when the variable names a file, writes it there.
///
///     BOTCHU_BENCHMARK=/tmp/chat-bench.txt swift test --package-path macOS --filter chatBenchmark
///
/// Each timing runs from the change (a click on a conversation, a streamed batch) until the window
/// has laid out and drawn the result, on the main thread, as the person using BotChu waits for it.
extension RenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_BENCHMARK"] != nil))
    func chatBenchmark() async throws {
        _ = NSApplication.shared
        let bench = try ChatBenchFixture()
        defer { bench.cleanUp() }
        let app = bench.app
        let defaults = UserDefaults(suiteName: bench.domain)!
        defaults.set(true, forKey: "showsStatus")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        app.show(bench.home)
        // `BOTCHU_BENCHMARK_SCOPE=chat` measures the chat column alone, without the sidebar and the
        // status sidebar, which also redraw for every change to a conversation.
        let chatOnly = ProcessInfo.processInfo.environment["BOTCHU_BENCHMARK_SCOPE"] == "chat"
        window.contentView = chatOnly
            ? NSHostingView(rootView: AnyView(ChatColumn().environment(app).defaultAppStorage(defaults)))
            : NSHostingView(rootView: AnyView(ContentView().environment(app).defaultAppStorage(defaults)))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        var report = ChatBenchReport()

        func draw() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func time(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            draw()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        // Lets SwiftUI finish deferred work (scrolling, web views) between samples.
        func idle(_ milliseconds: Int = 60) async throws {
            draw()
            try await Task.sleep(for: .milliseconds(milliseconds))
            draw()
        }

        // Conversation switching: from a short Home to each long conversation and back.
        for (name, target) in bench.conversations {
            var samples: [Double] = []
            for _ in 0..<5 {
                app.show(bench.home)
                try await idle(120)
                samples.append(time { app.show(target) })
                try await idle(120)
            }
            report.add("Switch to \(name)", samples)
        }
        // The same, to a conversation whose grouped transcript isn't kept (never shown, or evicted):
        // until it shows, and until its earlier items, grouped off the main thread, are there too.
        for (name, target) in bench.conversations {
            var samples: [Double] = [], ready: [Double] = []
            for _ in 0..<5 {
                app.show(bench.home)
                try await idle(120)
                TranscriptCache.forget(target)
                let start = DispatchTime.now().uptimeNanoseconds
                samples.append(time { app.show(target) })
                while TranscriptCache.model(for: target).isLoadingEarlier { try await Task.sleep(for: .milliseconds(2)) }
                draw()
                ready.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                try await idle(400)
            }
            report.add("Cold switch to \(name)", samples)
            report.add("  …earlier items ready", ready)
        }

        // A reply streaming into the long conversation, a delta at a time.
        app.show(bench.long)
        app.runStates[bench.long] = RunState(hasOutput: true)
        try await idle(200)
        // Written as a turn writes it: through the conversation's own state.
        let long = app.conversation(bench.long)
        long.append(ChatBenchFixture.message(["role": "assistant", "text": "Streaming"]))
        try await idle()
        var deltas: [Double] = []
        for i in 0..<40 {
            deltas.append(time {
                long.stream { $0[$0.count - 1].text += " token\(i) with **some** words" }
            })
            try await idle(20)
        }
        report.add("Stream delta, long conversation", deltas)

        // #106: a long reply being written: 128 KB of prose given 100 rapid deltas, while the
        // composer is typed in. A probe posts to the main thread every 5 ms from another thread:
        // how long it waits is how long a key press or Stop would wait.
        let paragraph = "A **measured** answer has `code`, a [link](https://example.test), and explanation.\n\n"
        long.append(ChatBenchFixture.message(["role": "assistant", "text": String(repeating: paragraph, count: 131_072 / paragraph.utf8.count)]))
        for _ in 0..<100 where MarkdownCache.shared.cached(long.messages.last!.text) == nil { try await idle(20) }
        try await idle(200)
        let content = try #require(window.contentView)
        let editor = try #require(composerTextView(in: content))
        let workerBefore = MarkdownWorker.shared.statistics
        let parsedOnMain = MarkdownParses.main
        // At once: 100 deltas, 10 ms apart.
        var longDeltas: [Double] = []
        for i in 0..<100 {
            longDeltas.append(time {
                long.stream { $0[$0.count - 1].text += " delta \(i) with **bold** words" }
            })
            try await idle(10)
        }
        let finalText = long.messages.last!.text
        let lastDelta = DispatchTime.now().uptimeNanoseconds
        try await waitUntil(steps: 1_000, every: .milliseconds(2)) { MarkdownCache.shared.cached(finalText) != nil }
        draw()
        let settled = Double(DispatchTime.now().uptimeNanoseconds - lastDelta) / 1_000_000
        let worker = MarkdownWorker.shared.statistics
        report.add("Stream delta, 128 KB reply", longDeltas)
        report.add("Last delta to its rendering drawn", [settled])
        report.note("128 KB reply, 100 deltas: parses started \(worker.started - workerBefore.started), completed \(worker.completed - workerBefore.completed), replaced while waiting \(worker.superseded - workerBefore.superseded), most at once \(worker.peak) (limit \(MarkdownWorker.shared.limit)), on the main thread \(MarkdownParses.main - parsedOnMain)")
        // As the app delivers output, a few times a second: 30 deltas 200 ms apart, with a key
        // press in the message box between each two. Meanwhile a typist, on its own schedule,
        // presses a key every 40 ms: from the press until the message box has drawn it is how
        // long typing waits; and from when each delta is due until its text is drawn, how fresh
        // the reply's text is.
        try await idle(300)
        // The same probe with nothing happening: what the Mac's load alone costs.
        let quiet = MainThreadProbe()
        try await Task.sleep(for: .seconds(3))
        report.add("Main-thread wait, nothing streaming", quiet.stop())
        let probe = MainThreadProbe()
        let typist = MainThreadProbe(every: 40_000) {
            editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
            draw()
        }
        var paced: [Double] = [], keys: [Double] = [], fresh: [Double] = []
        let clock = ContinuousClock()
        let begin = clock.now
        for i in 0..<30 {
            let due = begin.advanced(by: .milliseconds(200 * i))
            try await Task.sleep(until: due, clock: clock)
            paced.append(time { long.stream { $0[$0.count - 1].text += " paced \(i) with **bold** words" } })
            let late = (clock.now - due).components
            fresh.append(Double(late.seconds) * 1_000 + Double(late.attoseconds) / 1e15)
            try await Task.sleep(until: due.advanced(by: .milliseconds(100)), clock: clock)
            keys.append(time { editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) })
        }
        try await Task.sleep(for: .milliseconds(200))
        let typed = typist.stop()
        let waits = probe.stop()
        report.add("Stream delta, 128 KB reply, 5 a second", paced)
        report.add("  …from when it was due until drawn", fresh)
        report.add("Key press in the composer, meanwhile", keys)
        report.add("Key press every 40 ms, from it until drawn", typed)
        report.add("Main-thread wait, meanwhile", waits)
        editor.string = ""
        app.drafts[bench.long] = nil
        // Each revision the worker prepares, shown on its own: the longest the main thread is held
        // from the delta's text drawn until a while after the worker has the revision, which is
        // showing it (a probe posting every millisecond, so to within one).
        try await idle(300)
        let fine = MainThreadProbe(every: 1_000)
        var shown: [Double] = []
        for i in 0..<30 {
            long.stream { $0[$0.count - 1].text += " shown \(i) with **bold** words" }
            draw()
            let drawn = DispatchTime.now().uptimeNanoseconds
            let text = long.messages.last!.text
            try await waitUntil(steps: 2_000, every: .milliseconds(1)) { MarkdownCache.shared.cached(text) != nil }
            try await Task.sleep(for: .milliseconds(150))
            shown.append(fine.longest(postedAfter: drawn))
        }
        _ = fine.stop()
        report.add("A prepared 128 KB revision shown", shown)

        // A rich reply being written: 32 KB with 282 equations, then 60 deltas with one more each,
        // timed on the main thread and until WebKit has drawn the last.
        let rich = paragraph + "The equation is $x^2+y^2=z^2$.\n\n"
        let marker = UUID().uuidString
        long.append(ChatBenchFixture.message(["role": "assistant", "text": "Rich reply \(marker)\n\n" + String(repeating: rich, count: 32_768 / rich.utf8.count)]))
        func richView() -> ChatWebView? {
            webViews(in: window.contentView!).compactMap { $0 as? ChatWebView }.first { $0.rendered?.html.contains(marker) == true }
        }
        for _ in 0..<200 where richView()?.alphaValue != 1 { try await idle(20) }
        let richWeb = try #require(richView())
        let rendersBefore = richWeb.renders, skippedBefore = richWeb.skipped
        var richDeltas: [Double] = []
        for i in 0..<60 {
            richDeltas.append(time { long.stream { $0[$0.count - 1].text += " Then $y_{\(i)}^2$ follows." } })
            try await idle(10)
        }
        let finalHTML = try #require(RichMarkdown.html(long.messages.last!.text))
        let richLast = DispatchTime.now().uptimeNanoseconds
        try await waitUntil(steps: 2_000, every: .milliseconds(2)) { richWeb.rendered?.html == finalHTML && !richWeb.busy }
        let richSettled = Double(DispatchTime.now().uptimeNanoseconds - richLast) / 1_000_000
        report.add("Stream delta, 32 KB rich reply", richDeltas)
        report.add("Last rich delta to WebKit's render done", [richSettled])
        report.note("32 KB rich reply, 60 deltas: WebKit renders \(richWeb.renders - rendersBefore), revisions skipped while one rendered \(richWeb.skipped - skippedBefore)")
        app.runStates[bench.long] = nil

        // A live exploration: 400 (or 5,000) read-only calls so far, then each new call starts and
        // finishes.
        for (name, target) in [("400+", bench.explore), ("5,000+", bench.explore5k)] {
            app.show(target)
            app.runStates[target] = RunState(hasOutput: true, activity: .researching)
            try await idle(600)
            let explore = app.conversation(target)
            var calls: [Double] = []
            for i in 0..<30 {
                var call = ChatBenchFixture.toolCall(index: 10_000 + i, kind: i % 3, state: "running")
                calls.append(time { explore.stream { $0.append(call) } })
                try await idle(15)
                call.toolState = .done
                call.toolOutput = String(repeating: "let value = \(i)\n", count: 120)
                calls.append(time { explore.stream { $0[$0.count - 1] = call } })
                try await idle(15)
            }
            report.add("Live exploration call (\(name) calls)", calls)
            app.runStates[target] = nil
        }

        // Seventeen sub-agents streaming their own tool calls while the parent chat is shown.
        app.show(bench.subagents)
        app.runStates[bench.subagents] = RunState(hasOutput: true)
        try await idle(300)
        var children: [Double] = []
        for i in 0..<34 {
            let run = bench.runs[i % bench.runs.count]
            var thread = app.delegation.threads[run.id] ?? []
            thread.append(ChatBenchFixture.toolCall(index: 20_000 + i, kind: i % 4, state: "done"))
            children.append(time { app.delegation.threads[run.id] = thread })
            try await idle(15)
        }
        report.add("Sub-agent update (17 running)", children)
        app.runStates[bench.subagents] = nil

        // A long history that started thirty-seven sub-agents: twenty finished long ago, seventeen
        // running now, each with a long transcript of its own. A reply streams into the parent, then
        // the running children stream tool calls.
        app.show(bench.combined)
        app.runStates[bench.combined] = RunState(hasOutput: true)
        try await idle(400)
        let combined = app.conversation(bench.combined)
        combined.append(ChatBenchFixture.message(["role": "assistant", "text": "Streaming"]))
        try await idle()
        var parentDeltas: [Double] = []
        for i in 0..<40 {
            parentDeltas.append(time {
                combined.stream { $0[$0.count - 1].text += " token\(i) with **some** words" }
            })
            try await idle(20)
        }
        report.add("Stream delta, history + 37 sub-agents", parentDeltas)
        var childUpdates: [Double] = []
        for i in 0..<34 {
            let run = bench.combinedRuns[i % bench.combinedRuns.count]
            var thread = app.delegation.threads[run.id] ?? []
            thread.append(ChatBenchFixture.toolCall(index: 30_000 + i, kind: i % 4, state: "done"))
            childUpdates.append(time { app.delegation.threads[run.id] = thread })
            try await idle(15)
        }
        report.add("Sub-agent update, history + 37 sub-agents", childUpdates)
        app.runStates[bench.combined] = nil

        // Expanding: the 400-call exploration group, and a command card with a megabyte of output,
        // each drawn closed and then opened in the chat's column, as a click on it does.
        let transcript = TranscriptModel()
        let group: ExplorationGroup = {
            var activity = ActivityTranscript(root: "/Users/me/project")
            activity.update(app.thread(bench.explore))
            for item in activity.items { if case .exploration(let group) = item { return group } }
            fatalError("The exploration fixture has no group")
        }()
        let command: ToolCallItem = {
            var activity = ActivityTranscript(root: "/Users/me/project")
            activity.update(app.thread(bench.outputs))
            for item in activity.items { if case .tool(let tool) = item, (tool.message.toolOutput?.utf8.count ?? 0) > 900_000 { return tool } }
            fatalError("The outputs fixture has no large command")
        }()
        let column = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        column.isReleasedWhenClosed = false
        defer { column.contentView = nil; column.close() }
        func expansion(_ closed: some View, _ open: some View) async throws -> Double {
            let host = NSHostingView(rootView: AnyView(closed.environment(transcript).environment(app).frame(width: 712)))
            column.contentView = host
            column.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded(); column.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            let start = DispatchTime.now().uptimeNanoseconds
            host.rootView = AnyView(open.environment(transcript).environment(app).frame(width: 712))
            host.layoutSubtreeIfNeeded(); column.displayIfNeeded()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        var groups: [Double] = [], outputs: [Double] = []
        for _ in 0..<6 {
            groups.append(try await expansion(ExplorationCard(group: group, live: false, density: .detailed, open: false, kind: .claude),
                                              ExplorationCard(group: group, live: false, density: .detailed, open: true, kind: .claude)))
            outputs.append(try await expansion(CommandCard(item: command, density: .detailed, open: false, kind: .claude),
                                               CommandCard(item: command, density: .detailed, open: true, kind: .claude)))
        }
        report.add("Expand the 400-call group", groups)
        report.add("Expand a 1 MB command output", outputs)

        // Grouping alone (Core), for a streamed delta at the end of the 1,500-message thread.
        var core = ActivityTranscript(root: "/Users/me/project")
        var thread = app.thread(bench.long)
        core.update(thread)
        var regroups: [Double] = []
        for i in 0..<40 {
            thread[thread.count - 1].text += " more \(i)"
            let start = DispatchTime.now().uptimeNanoseconds
            core.update(thread)
            regroups.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        report.add("Regroup per delta (Core, 1,500 messages)", regroups)
        var full = ActivityTranscript(root: "/Users/me/project")
        let firstStart = DispatchTime.now().uptimeNanoseconds
        full.update(thread)
        report.add("Group the whole thread once (Core)", [Double(DispatchTime.now().uptimeNanoseconds - firstStart) / 1_000_000])

        // Grouping alone (Core) for one open exploration of 400, 1,000 and 5,000 calls: each new call
        // starting and then finishing, timed apart from the comparison of the group before and after
        // it that a row's equality check makes; then grouping each from nothing.
        for count in [400, 1_000, 5_000] {
            var messages = (0..<count).map { ChatBenchFixture.coreCall(index: $0, state: .done) }
            var projection = ActivityTranscript(root: "/Users/me/project")
            projection.update(messages)
            var updates: [Double] = [], comparisons: [Double] = []
            for i in 0..<30 {
                for step in 0..<2 {
                    if step == 0 {
                        messages.append(ChatBenchFixture.coreCall(index: count + i, state: .running))
                    } else {
                        messages[messages.count - 1] = ChatBenchFixture.coreCall(index: count + i, state: .done, id: messages[messages.count - 1].id)
                    }
                    let before = projection.items.last
                    let start = DispatchTime.now().uptimeNanoseconds
                    projection.update(messages)
                    updates.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    let after = projection.items.last
                    let compared = DispatchTime.now().uptimeNanoseconds
                    let same = before == after
                    comparisons.append(Double(DispatchTime.now().uptimeNanoseconds - compared) / 1_000_000)
                    #expect(!same)
                }
            }
            report.add("Core update, open \(count)-call group", updates)
            report.add("Group comparison, \(count)-call group", comparisons)
            var cold: [Double] = []
            for _ in 0..<5 {
                var fresh = ActivityTranscript(root: "/Users/me/project")
                let start = DispatchTime.now().uptimeNanoseconds
                fresh.update(messages)
                cold.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            report.add("Core cold grouping, \(count) calls", cold)
        }
        // What a 5,000-call projection keeps, beyond the messages themselves, open and once settled.
        do {
            let messages = (0..<5_000).map { ChatBenchFixture.coreCall(index: $0, state: .done) }
            let settledMessages = messages + [ChatBenchFixture.message(["role": "assistant", "text": "Done."])]
            let baseline = ChatBenchReport.heapInUse()
            var open = ActivityTranscript(root: "/Users/me/project")
            open.update(messages)
            let afterOpen = ChatBenchReport.heapInUse()
            var settled = ActivityTranscript(root: "/Users/me/project")
            settled.update(settledMessages)
            let afterSettled = ChatBenchReport.heapInUse()
            report.note(String(format: "Retained by a 5,000-call projection: open %.1f MB, settled %.1f MB",
                               Double(afterOpen - baseline) / 1_048_576, Double(afterSettled - afterOpen) / 1_048_576))
            withExtendedLifetime((open, settled)) {}
        }

        let text = report.text(title: "Chat benchmark (\(chatOnly ? "chat column" : "whole window")) · load \(ChatBenchReport.load())")
        print(text)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_BENCHMARK"], path.hasPrefix("/") {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// How long blocks posted to the main thread every 5 ms wait to run, from when it is made until
/// `stop`: as long as a key press or a click would wait.
final class MainThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var waits: [Double] = []
    private var posts: [UInt64] = []
    private var running = true

    /// Posts to the main thread every `interval` microseconds, from a thread of its own, and
    /// records how long until the main thread has run it, and `work` with it.
    init(every interval: useconds_t = 5_000, _ work: (@MainActor () -> Void)? = nil) {
        nonisolated(unsafe) let work = work
        Thread.detachNewThread { [self] in
            while isRunning {
                let posted = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { [self] in
                    if let work { MainActor.assumeIsolated { work() } }
                    record(Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000, posted: posted)
                }
                usleep(interval)
            }
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func record(_ wait: Double, posted: UInt64) {
        lock.lock()
        waits.append(wait)
        posts.append(posted)
        lock.unlock()
    }

    /// The longest wait of those posted after `start` (`DispatchTime` nanoseconds) and run so far.
    func longest(postedAfter start: UInt64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return zip(posts, waits).filter { $0.0 >= start }.map(\.1).max() ?? 0
    }

    func stop() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        running = false
        return waits
    }
}

/// Waits a step at a time, at most `steps` of them, until `done`; it stops looking once it is, as a
/// timing that follows must not include looking again.
@MainActor private func waitUntil(steps: Int, every step: Duration, _ done: () -> Bool) async throws {
    for _ in 0..<steps {
        if done() { return }
        try await Task.sleep(for: step)
    }
}

@MainActor private func composerTextView(in view: NSView) -> ComposerTextView? {
    (view as? ComposerTextView) ?? view.subviews.lazy.compactMap { composerTextView(in: $0) }.first
}

@MainActor private func webViews(in view: NSView) -> [WKWebView] {
    (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
}

/// The chat of the selected bot's shown conversation, as ContentView shows it, without the rest.
private struct ChatColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.selection {
            let tab = model.tab(of: id)
            ChatView(target: tab).id(tab)
        }
    }
}

struct ChatBenchReport {
    var rows: [(String, [Double])] = []
    var notes: [String] = []

    mutating func add(_ name: String, _ samples: [Double]) { rows.append((name, samples)) }
    mutating func note(_ line: String) { notes.append(line) }

    /// Bytes allocated on the heap and not yet freed, in every malloc zone.
    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    func text(title: String) -> String {
        var lines = [title, String(format: "%-44@ %8@ %8@ %8@ %4@", "Measure" as NSString, "median" as NSString, "p95" as NSString, "max" as NSString, "n" as NSString)]
        for (name, samples) in rows {
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { lines.append("\(name): no samples"); continue }
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            // A p95 of fewer than 30 samples would only be their maximum again.
            let p95Text = sorted.count >= 30 ? String(format: "%6.2fms", p95) : "      -  "
            lines.append(String(format: "%-44@ %6.2fms %@ %6.2fms %4d", name as NSString, median, p95Text as NSString, sorted.last!, sorted.count))
        }
        return (lines + notes).joined(separator: "\n")
    }

    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? String(format: "%.1f %.1f %.1f", loads[0], loads[1], loads[2]) : "?"
    }
}

/// One bot with a short Home and four long conversations: 1,500 messages of replies and tool calls;
/// tool calls with outputs of 200 KB to 1 MB; one turn with 400 read-only calls (some failing); and
/// seventeen running sub-agents with their own threads.
@MainActor final class ChatBenchFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-bench-\(UUID().uuidString)")
    let domain = "local.BotChu.ChatBenchmark.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let bot: Bot
    let app: AppModel
    let home: ChatTarget
    let long: ChatTarget
    let outputs: ChatTarget
    let explore: ChatTarget
    let subagents: ChatTarget
    let explore5k: ChatTarget
    let combined: ChatTarget
    var runs: [SubagentRun] = []
    /// The long history's running children.
    var combinedRuns: [SubagentRun] = []
    var conversations: [(String, ChatTarget)] {
        [("1,500 messages", long), ("large outputs", outputs), ("400-call exploration", explore), ("17 sub-agents", subagents),
         ("5,000-call exploration", explore5k), ("history + 37 sub-agents", combined)]
    }

    init() throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        bot = Bot(name: "Bench", accountID: "claude-dev", workspace: root.appendingPathComponent("bot").path)
        let botHome = BotHome(workspace: bot.workspace)
        try botHome.save(bot)
        let start = Date().addingTimeInterval(-86_400)
        try Self.write([
            ["role": "note", "text": "Bench was created on Claude Dev"],
            ["role": "user", "text": "Hello"],
            ["role": "assistant", "text": "Hi! What should I look at?"],
        ], start: start, to: botHome.threadURL)
        let bot = bot, root = root
        func task(_ title: String, _ messages: [[String: Any]]) throws -> ChatTarget {
            var task = BotTask(for: bot, repo: "bench/\(title)", checkout: root.path, work: nil, brief: title)
            task.folder = root.appendingPathComponent("repo").path
            try botHome.save(task)
            try ChatBenchFixture.write(messages, start: start, to: botHome.taskThreadURL(task.id))
            return .task(task.id, of: bot.id)
        }
        long = try task("long", Self.longConversation())
        outputs = try task("outputs", Self.largeOutputs())
        explore = try task("explore", Self.exploration())
        let fanOut = Self.fanOut()
        subagents = try task("subagents", fanOut.messages)
        explore5k = try task("explore5k", Self.exploration(calls: 5_000))
        let history = Self.historyWithChildren()
        combined = try task("combined", history.messages)
        home = .home(bot.id)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in benchmarks.") })
        // Seventeen running children of the fan-out conversation, each with its own thread.
        for (index, id) in fanOut.ids.enumerated() {
            let child = Bot(name: "Helper \(index + 1)", emoji: "🦝", workspace: root.appendingPathComponent("helper").path)
            var run = SubagentRun(id: id, rootBotID: bot.id, rootTaskID: subagents.taskID, depth: 1, targetBot: child,
                                  title: "Investigate area \(index + 1)", brief: "Look into area \(index + 1) and report.",
                                  workingDirectory: root.path, phase: .running,
                                  createdAt: start.addingTimeInterval(4_000 + Double(index)))
            run.startedAt = run.createdAt.addingTimeInterval(1)
            runs.append(run)
            app.delegation.threads[id] = [Self.message(["role": "user", "text": run.brief])]
                + (0..<30).map { Self.toolCall(index: index * 100 + $0, kind: $0 % 4, state: "done") }
            app.delegation.states[id] = RunState(hasOutput: true, activity: .researching)
        }
        app.delegation.records[subagents] = runs
        // The long history's children: twenty finished, seventeen running, 300 messages each.
        var combinedRecords: [SubagentRun] = []
        for (index, child) in history.children.enumerated() {
            let helper = Bot(name: "Helper \(index + 1)", emoji: "🦝", workspace: root.appendingPathComponent("helper").path)
            var run = SubagentRun(id: child.id, rootBotID: bot.id, rootTaskID: combined.taskID, depth: 1, targetBot: helper,
                                  title: "Investigate area \(index + 1)", brief: "Look into area \(index + 1) and report.",
                                  workingDirectory: root.path, phase: child.running ? .running : .completed,
                                  createdAt: start.addingTimeInterval(child.offset + 0.3))
            run.startedAt = run.createdAt.addingTimeInterval(1)
            if !child.running {
                run.finishedAt = run.createdAt.addingTimeInterval(40)
                run.handoffOutput = "All done in area \(index + 1)."
            }
            combinedRecords.append(run)
            if child.running { combinedRuns.append(run) }
            app.delegation.threads[child.id] = [Self.message(["role": "user", "text": run.brief])]
                + (0..<300).map { Self.toolCall(index: index * 1_000 + $0, kind: $0 % 4, state: "done") }
            if child.running { app.delegation.states[child.id] = RunState(hasOutput: true, activity: .researching) }
        }
        app.delegation.records[combined] = combinedRecords
    }

    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
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

    static func longConversation() -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for turn in 0..<150 {
            messages.append(["role": "user", "text": "Step \(turn): keep going with the next part."])
            for call in 0..<6 {
                messages.append(toolDictionary(index: turn * 10 + call, kind: call % 4, state: "done",
                                               output: String(repeating: "line of output \(call)\n", count: 120)))
                if call == 2 || call == 5 { messages.append(["role": "assistant", "text": "Step \(turn).\(call)\n\n" + reply]) }
            }
            messages.append(["role": "assistant", "text": "Turn \(turn) done.\n\n" + reply])
        }
        return messages
    }

    static func largeOutputs() -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "user", "text": "Run the builds and show me the logs."]]
        for index in 0..<60 {
            let size = index % 20 == 0 ? 1_000_000 : 200_000
            let line = "CompileSwift normal arm64 /Users/me/project/Sources/File\(index).swift (in target 'App')\n"
            messages.append(toolDictionary(index: index, kind: 3, state: "done",
                                           output: String(repeating: line, count: size / line.utf8.count)))
            if index % 10 == 9 { messages.append(["role": "assistant", "text": "Build \(index) finished.\n\n" + reply]) }
        }
        return messages
    }

    static func exploration(calls: Int = 400) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "user", "text": "Trace what happens when I click an agent."],
                                         ["role": "assistant", "text": "I'll trace it, starting with the app model."]]
        for index in 0..<calls {
            let failed = index % 37 == 5
            messages.append(toolDictionary(index: index, kind: index % 3, state: failed ? "failed" : "done",
                                           output: failed ? "File does not exist." : String(repeating: "  let x = \(index)\n", count: 200)))
        }
        return messages
    }

    static func fanOut() -> (messages: [[String: Any]], ids: [UUID]) {
        let ids = (0..<17).map { _ in UUID() }
        var messages: [[String: Any]] = [["role": "user", "text": "Split the audit across seventeen helpers."],
                                         ["role": "assistant", "text": "I'll hand one area to each helper."]]
        for (index, id) in ids.enumerated() {
            messages.append(["role": "tool", "text": "", "toolID": "spawn-\(index)", "toolName": "Bash",
                             "toolInput": "botchu-subagent spawn --agent 'Helper \(index + 1)' --title 'Investigate area \(index + 1)' --brief 'Look into area \(index + 1) and report.'",
                             "toolOutput": id.uuidString.lowercased() + "\n", "toolState": "done", "offset": 3_990 + index])
        }
        messages.append(["role": "tool", "text": "", "toolID": "wait", "toolName": "Bash",
                         "toolInput": "botchu-subagent wait " + ids.map { $0.uuidString.lowercased() }.joined(separator: " "),
                         "toolState": "running", "offset": 4_020])
        return (messages, ids)
    }

    /// The 1,500-message conversation, with a `botchu-subagent spawn` every 75 messages (twenty, whose
    /// runs finished) and seventeen more at its end, still running, with a `wait` for them.
    static func historyWithChildren() -> (messages: [[String: Any]], children: [(id: UUID, offset: Double, running: Bool)]) {
        var messages: [[String: Any]] = []
        var children: [(id: UUID, offset: Double, running: Bool)] = []
        func spawn(_ running: Bool) {
            let id = UUID(), index = children.count
            children.append((id, Double(messages.count), running))
            messages.append(["role": "tool", "text": "", "toolID": "spawn-\(index)", "toolName": "Bash",
                             "toolInput": "botchu-subagent spawn --agent 'Helper \(index + 1)' --title 'Investigate area \(index + 1)' --brief 'Look into area \(index + 1) and report.'",
                             "toolOutput": id.uuidString.lowercased() + "\n", "toolState": "done"])
        }
        for (index, message) in longConversation().enumerated() {
            messages.append(message)
            if index % 75 == 74 { spawn(false) }
        }
        messages.append(["role": "user", "text": "Now split the rest across seventeen helpers."])
        for _ in 0..<17 { spawn(true) }
        let waiting = children.suffix(17).map { $0.id.uuidString.lowercased() }
        messages.append(["role": "tool", "text": "", "toolID": "wait", "toolName": "Bash",
                         "toolInput": "botchu-subagent wait " + waiting.joined(separator: " "), "toolState": "running"])
        return (messages, children)
    }

    // MARK: Messages

    /// A read, a search or a listing made in memory, for grouping alone: distinct files in four folders.
    static func coreCall(index: Int, state: ChatMessage.ToolState, id: UUID = UUID()) -> ChatMessage {
        let file = "/Users/me/project/macOS/Sources/BotChu/\(["App", "Chat", "Inspector", "Sidebar"][index % 4])/File\(index).swift"
        let (name, input, arguments): (String, String, String?) = switch index % 3 {
        case 0: ("Read", file, #"{"file_path":"\#(file)","limit":120,"offset":\#(1 + index % 5 * 120)}"#)
        case 1: ("Grep", "func tab\\(of", #"{"pattern":"func tab\\(of","path":"/Users/me/project/macOS/Sources"}"#)
        default: ("Bash", "ls -la /Users/me/project/macOS/Sources/BotChu", nil)
        }
        return ChatMessage(id: id, role: .tool, toolID: "core-\(index)", toolName: name, toolInput: input,
                           toolOutput: state == .running ? nil : "let value = \(index)\n", toolState: state, toolArguments: arguments)
    }

    /// A tool call as Claude Code saves it: kind 0 reads a file, 1 searches, 2 lists, 3 runs a build.
    static func toolDictionary(index: Int, kind: Int, state: String, output: String) -> [String: Any] {
        let file = "/Users/me/project/macOS/Sources/BotChu/\(["App", "Chat", "Inspector", "Sidebar"][index % 4])/File\(index % 23).swift"
        let (name, input): (String, String) = switch kind {
        case 0: ("Read", file)
        case 1: ("Grep", "func tab\\(of")
        case 2: ("Bash", "ls -la /Users/me/project/macOS/Sources/BotChu")
        default: ("Bash", "swift build --package-path macOS")
        }
        var message: [String: Any] = ["role": "tool", "text": "", "toolID": "call-\(index)", "toolName": name, "toolInput": input,
                                      "toolOutput": output, "toolState": state]
        if kind == 0 {
            message["toolArguments"] = #"{"file_path":"\#(file)","limit":120,"offset":\#(1 + index % 5 * 120)}"#
        }
        return message
    }

    static func toolCall(index: Int, kind: Int, state: String) -> ChatMessage {
        message(toolDictionary(index: index, kind: kind, state: state, output: state == "running" ? "" : "ok\n"))
    }

    /// Decoded from JSON, as BotChu loads a saved thread.
    static func message(_ fields: [String: Any], date: Date = Date()) -> ChatMessage {
        var fields = fields
        fields["id"] = fields["id"] ?? UUID().uuidString
        fields["date"] = ISO8601DateFormatter().string(from: date)
        fields["text"] = fields["text"] ?? ""
        fields.removeValue(forKey: "offset")
        let data = try! JSONSerialization.data(withJSONObject: fields)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(ChatMessage.self, from: data)
    }

    static func write(_ messages: [[String: Any]], start: Date, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let lines = try messages.enumerated().map { index, fields -> String in
            var fields = fields
            let offset = (fields.removeValue(forKey: "offset") as? Int).map(Double.init) ?? Double(index)
            fields["id"] = UUID().uuidString
            fields["date"] = formatter.string(from: start.addingTimeInterval(offset))
            fields["text"] = fields["text"] ?? ""
            return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
