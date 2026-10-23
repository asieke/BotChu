import Foundation
import BotChuCore

/// `BOTCHU_DEMO=activity` on throwaway data (`macOS/ui-review.sh`): the shown conversation becomes
/// a long agent run, in memory only, for checking the chat's activity cards. It explores the
/// BotChu sources (with failed reads and a file read twice), runs a build, explores logs, edits a
/// file, hands work to three sub-agents (one running, one done, one failed), and is exploring
/// live when the screen is taken. Nothing is saved and no CLI runs.
@MainActor
enum DemoActivity {
    static func install(in model: AppModel, target: ChatTarget) {
        guard let bot = model.bot(target.botID) else { return }
        let root = model.task(target)?.folder ?? bot.workspace
        let sources = root + "/macOS/Sources"
        let now = Date()
        var clock = now.addingTimeInterval(-600)
        func tick(_ seconds: Double) -> Date {
            clock = clock.addingTimeInterval(seconds)
            return clock
        }
        func tool(_ name: String, _ input: String, _ arguments: [String: Any]? = nil, output: String = "ok",
                  state: ChatMessage.ToolState = .done, exit: Int? = nil, seconds: Double = 0.3) -> ChatMessage {
            var message = ChatMessage(role: .tool, date: tick(seconds), toolID: UUID().uuidString, toolName: name, toolInput: input,
                                      toolOutput: state == .running ? nil : output, toolState: state,
                                      toolArguments: arguments.flatMap { ToolArguments.digest($0) }, toolExitCode: exit)
            if state != .running { message.toolDuration = seconds * 0.8 }
            return message
        }
        func read(_ path: String, offset: Int? = nil, limit: Int? = nil, failed: Bool = false, state: ChatMessage.ToolState = .done) -> ChatMessage {
            var args: [String: Any] = ["file_path": path]
            if let offset { args["offset"] = offset }
            if let limit { args["limit"] = limit }
            return tool("Read", path, args, output: failed ? "<tool_use_error>File does not exist.</tool_use_error>" : "     1\timport SwiftUI\n",
                        state: failed ? .failed : state)
        }

        var messages: [ChatMessage] = [
            ChatMessage(role: .user, text: "Clicking a busy agent in the sidebar feels slow. Can you find out why?", date: tick(0)),
            ChatMessage(role: .assistant, text: "I'll trace what happens when you click an agent in the sidebar, starting with the app model, sidebar and inspector views.", date: tick(4)),
        ]
        let files = ["BotChuCore/BotStatus.swift", "BotChuCore/SubagentTransport.swift", "BotChu/App/AppModel.swift", "BotChu/App/BotChuApp.swift",
                     "BotChu/App/ContentView.swift", "BotChu/App/SubagentRuntime.swift", "BotChu/Sidebar/SidebarView.swift", "BotChu/Chat/ChatView.swift",
                     "BotChu/Chat/MessageViews.swift", "BotChu/Chat/MarkdownText.swift", "BotChu/Inspector/BotInspector.swift",
                     "BotChu/Inspector/InspectorPanel.swift", "BotChu/Inspector/SubagentsSection.swift", "BotChu/Sidebar/SidebarNavigation.swift",
                     "BotChu/Chat/Composer.swift", "BotChu/Chat/RichMarkdownText.swift", "BotChuCore/Store.swift", "BotChuCore/Models.swift",
                     "BotChu/App/AppModel.swift", "BotChuCore/AgentRun.swift"]
        for (index, file) in files.enumerated() {
            messages.append(read("\(sources)/\(file)", offset: index % 3 == 0 ? 1 : nil, limit: index % 3 == 0 ? 200 : nil))
            if index == 6 {
                messages.append(tool("Grep", "func tab(of", ["pattern": "func tab\\(of", "path": sources, "glob": "*.swift"],
                                     output: "macOS/Sources/BotChu/App/AppModel.swift:213"))
            }
        }
        for missing in ["MainWindow", "Pets", "MessageRow", "MarkdownView", "ThreadView", "ChatList", "RowCache"] {
            messages.append(read("\(sources)/BotChu/Chat/\(missing).swift", failed: true))
        }
        let build = "** BUILD SUCCEEDED **\n" + (1...212).map { "CompileSwift normal arm64 \(sources)/BotChu/File\($0).swift" }.joined(separator: "\n")
        messages.append(tool("Bash", "xcodebuild -scheme BotChu -configuration Debug build",
                             ["command": "xcodebuild -scheme BotChu -configuration Debug build", "description": "Build the app"],
                             output: build, exit: 0, seconds: 60))
        messages.append(ChatMessage(role: .assistant, text: "Now checking how long threads and step outputs are loaded.", date: tick(3)))
        let thread = "\(root)/.botchu/tasks/2DB14BE2-49F0-4D1F-B8C5-3F35D2397220/thread.jsonl"
        messages += [
            tool("Bash", "tail -n 30 \"\(root)/.botchu/thread.jsonl\"", output: "{}\n"),
            read("\(root)/steps/38/output.txt", offset: 1, limit: 120),
            read(thread, offset: 1, limit: 30),
            read(thread, offset: 31, limit: 30),
            tool("Bash", "tail -n 20 ~/.gemini/antigravity-cli/logs/transcript.jsonl", output: "{}\n"),
            read("\(root)/steps/46/output.txt", offset: 1, limit: 30),
            read("\(root)/steps/transcript_full.jsonl", offset: 211),
        ]
        messages.append(tool("Edit", "\(sources)/BotChu/App/AppModel.swift",
                             ["file_path": "\(sources)/BotChu/App/AppModel.swift",
                              "old_string": "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4",
                              "new_string": "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4\n" + (1...11).map { "let e\($0) = \($0)" }.joined(separator: "\n")],
                             output: "The file has been updated successfully."))
        messages.append(tool("Bash", "swift test --filter ChatSwitching", output: "error: 2 tests failed\nTest switchingIsFast failed\nTest windowSlides failed", state: .failed, exit: 1, seconds: 31))

        // Three sub-agents: one running, one done, one failed.
        let helpers: [(String, String, String, SubagentPhase)] = [
            ("IT Racoon", "🦝", "Investigate BotChu UI & runtime latency", .running),
            ("QA Duck", "🦆", "Check the chat on a 17-sub-agent fan-out", .completed),
            ("Docs Owl", "🦉", "Draft the README's Chat section", .failed),
        ]
        var runs: [SubagentRun] = []
        for (name, emoji, title, phase) in helpers {
            let id = UUID()
            let spawn = tool("Bash", "botchu-subagent spawn --agent '\(name)' --title '\(title)' --brief 'Look into it and report back.'",
                             output: id.uuidString.lowercased() + "\n", seconds: 2)
            messages.append(spawn)
            let helper = model.bots.first { $0.name == name } ?? Bot(name: name, emoji: emoji, workspace: bot.workspace)
            var run = SubagentRun(id: id, rootBotID: target.botID, rootTaskID: target.taskID, depth: 1, targetBot: helper, title: title,
                                  brief: "Look into it and report back.", workingDirectory: root, phase: phase,
                                  createdAt: spawn.date.addingTimeInterval(0.4))
            run.startedAt = run.createdAt.addingTimeInterval(1)
            if phase != .running { run.finishedAt = run.startedAt!.addingTimeInterval(phase == .failed ? 41 : 272) }
            if phase == .completed { run.handoffOutput = "The chat stays responsive: 17 calm cards, no tool rows in the parent." }
            if phase == .failed { run.errorMessage = "Codex Dev exited with status 1 without replying." }
            runs.append(run)
            var childThread = [ChatMessage(role: .user, text: run.brief)]
            for index in 0..<23 {
                childThread.append(ChatMessage(role: .tool, toolID: "c\(index)", toolName: index % 5 == 0 ? "Bash" : "Read",
                                               toolInput: index % 5 == 0 ? "rg -n onChange" : "\(sources)/BotChu/Chat/ChatView.swift", toolState: .done))
            }
            model.delegation.threads[id] = childThread
            if phase == .running { model.delegation.states[id] = RunState(hasOutput: true, activity: .researching) }
        }
        model.delegation.records[target] = runs
        messages.append(tool("Bash", "botchu-subagent wait " + runs.map { $0.id.uuidString.lowercased() }.joined(separator: " "),
                             state: .running, seconds: 1))
        messages.append(ChatMessage(role: .assistant, text: "While they work, I'll look up the DeviceActivity interface in the Xcode SDK.", date: tick(2)))
        messages += [
            tool("Bash", "find /Applications/Xcode.app -path \"*DeviceActivity*\" -name '*.swiftinterface'", output: "/Applications/Xcode.app/…/arm64-apple-ios-simulator.swiftinterface"),
            read("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/DeviceActivity.framework/arm64-apple-ios-simulator.swiftinterface", offset: 1, limit: 80),
            read("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/DeviceActivity.framework/arm64-apple-ios-simulator.swiftinterface", offset: 81, limit: 80),
            read("/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/DeviceActivity.framework/DeviceActivity.swiftinterface", state: .running),
        ]
        // The live group started nine seconds ago.
        let liveStart = now.addingTimeInterval(-9)
        for index in messages.indices.suffix(4) { messages[index].date = liveStart.addingTimeInterval(Double(index - messages.count + 4) * 2) }
        model.threads[target] = messages
        model.runStates[target] = RunState(startedAt: now.addingTimeInterval(-620), hasOutput: true, activity: .researching)
    }
}
