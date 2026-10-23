import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// Chat latency with realistic histories (#48): conversation switching, streamed replies, a live
/// many-call exploration, seventeen sub-agents, expanding a group or a large output, and the
/// grouping itself. Not part of
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

        // A reply streaming into the long conversation, a delta at a time.
        app.show(bench.long)
        app.runStates[bench.long] = RunState(hasOutput: true)
        try await idle(200)
        var streamed = app.thread(bench.long)
        streamed.append(ChatBenchFixture.message(["role": "assistant", "text": "Streaming"]))
        app.threads[bench.long] = streamed
        try await idle()
        var deltas: [Double] = []
        for i in 0..<40 {
            deltas.append(time {
                streamed[streamed.count - 1].text += " token\(i) with **some** words"
                app.threads[bench.long] = streamed
            })
            try await idle(20)
        }
        report.add("Stream delta, long conversation", deltas)
        app.runStates[bench.long] = nil

        // A live exploration: 400 read-only calls so far, then each new call starts and finishes.
        app.show(bench.explore)
        app.runStates[bench.explore] = RunState(hasOutput: true, activity: .researching)
        try await idle(200)
        var explore = app.thread(bench.explore)
        var calls: [Double] = []
        for i in 0..<30 {
            var call = ChatBenchFixture.toolCall(index: 10_000 + i, kind: i % 3, state: "running")
            calls.append(time {
                explore.append(call)
                app.threads[bench.explore] = explore
            })
            try await idle(15)
            call.toolState = .done
            call.toolOutput = String(repeating: "let value = \(i)\n", count: 120)
            calls.append(time {
                explore[explore.count - 1] = call
                app.threads[bench.explore] = explore
            })
            try await idle(15)
        }
        report.add("Live exploration call (400+ calls)", calls)
        app.runStates[bench.explore] = nil

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

        let text = report.text(title: "Chat benchmark (\(chatOnly ? "chat column" : "whole window")) · load \(ChatBenchReport.load())")
        print(text)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_BENCHMARK"], path.hasPrefix("/") {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
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

    mutating func add(_ name: String, _ samples: [Double]) { rows.append((name, samples)) }

    func text(title: String) -> String {
        var lines = [title, String(format: "%-40@ %8@ %8@ %8@ %4@", "Measure" as NSString, "median" as NSString, "p95" as NSString, "max" as NSString, "n" as NSString)]
        for (name, samples) in rows {
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { lines.append("\(name): no samples"); continue }
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            lines.append(String(format: "%-40@ %6.1fms %6.1fms %6.1fms %4d", name as NSString, median, p95, sorted.last!, sorted.count))
        }
        return lines.joined(separator: "\n")
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
    var runs: [SubagentRun] = []
    var conversations: [(String, ChatTarget)] { [("1,500 messages", long), ("large outputs", outputs), ("400-call exploration", explore), ("17 sub-agents", subagents)] }

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

    static func exploration() -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "user", "text": "Trace what happens when I click an agent."],
                                         ["role": "assistant", "text": "I'll trace it, starting with the app model."]]
        for index in 0..<400 {
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

    // MARK: Messages

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
