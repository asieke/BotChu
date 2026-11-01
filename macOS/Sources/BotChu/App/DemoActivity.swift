import Foundation
import BotChuCore

/// `BOTCHU_DEMO=activity` on throwaway data (`macOS/ui-review.sh`): the shown conversation becomes
/// a long agent run, in memory only, for checking the chat's activity cards. It explores the
/// BotChu sources (with failed reads and a file read twice), runs a build, explores logs, edits a
/// file, hands work to three sub-agents (one running, one done, one failed; the Sub-agents tab also
/// gets nested and earlier runs in every recorded state), and is exploring
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
        let turn = UUID()
        for (name, emoji, title, phase) in helpers {
            let id = UUID()
            let spawn = tool("Bash", "botchu-subagent spawn --agent '\(name)' --title '\(title)' --brief 'Look into it and report back.'",
                             output: id.uuidString.lowercased() + "\n", seconds: 2)
            messages.append(spawn)
            let helper = model.bots.first { $0.name == name } ?? Bot(name: name, emoji: emoji, workspace: bot.workspace)
            var run = SubagentRun(id: id, rootBotID: target.botID, rootTaskID: target.taskID, depth: 1, targetBot: helper, title: title,
                                  brief: "Look into it and report back.", workingDirectory: root,
                                  callerInvocationID: turn, phase: phase, createdAt: spawn.date.addingTimeInterval(0.4))
            let started = run.createdAt.addingTimeInterval(1)
            run.startedAt = started
            if phase != .running { run.finishedAt = started.addingTimeInterval(phase == .failed ? 41 : 272) }
            if phase == .completed { run.handoffOutput = "The chat stays responsive: 17 calm cards, no tool rows in the parent." }
            if phase == .failed { run.errorMessage = "Codex Dev exited with status 1 without replying." }
            // Where they work (#431): a branch on each row, a pull request on the finished one's.
            if phase != .failed { run.branch = phase == .running ? "fix/412-ui-latency" : "test/417-fan-out" }
            if phase == .completed { (run.pullRequest, run.pullRequestState) = (418, .open) }
            runs.append(run)
            var childThread = [ChatMessage(role: .user, text: run.brief)]
            for index in 0..<23 {
                childThread.append(ChatMessage(role: .tool, toolID: "c\(index)", toolName: index % 5 == 0 ? "Bash" : "Read",
                                               toolInput: index % 5 == 0 ? "rg -n onChange" : "\(sources)/BotChu/Chat/ChatView.swift",
                                               toolState: phase == .running && index == 22 ? .running : .done))
            }
            model.delegation.threads[id] = childThread
            if phase == .running { model.delegation.states[id] = RunState(hasOutput: true, activity: .researching) }
        }
        runs += nestedAndEarlierRuns(in: model, target: target, under: runs[0], turn: turn, root: root, now: now)
        model.delegation.records[target] = runs
        // `BOTCHU_SUBAGENT=<title>`: open that run's details, as the chat's Open does.
        if let title = ProcessInfo.processInfo.environment["BOTCHU_SUBAGENT"], let run = runs.first(where: { $0.title.hasPrefix(title) }) {
            SubagentFocus.shared.focus(run.id)
        }
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
        model.conversation(target).replace(messages)
        model.runStates[target] = RunState(startedAt: now.addingTimeInterval(-620), hasOutput: true, activity: .researching)
    }
}

extension DemoActivity {
    /// The rest of the Sub-agents tab's states (#194): beneath the running run, one done whose own
    /// helper failed; a run still preparing; and an earlier turn's runs, done, without a handoff and
    /// stopped by a restart, beside one recorded before runs kept their turn.
    fileprivate static func nestedAndEarlierRuns(in model: AppModel, target: ChatTarget, under parent: SubagentRun, turn: UUID,
                                                 root: String, now: Date) -> [SubagentRun] {
        let bot = model.bot(target.botID)
        func helper(_ name: String, _ emoji: String) -> Bot {
            model.bots.first { $0.name == name } ?? Bot(name: name, emoji: emoji, workspace: bot?.workspace ?? root)
        }
        func run(_ title: String, by helper: Bot, _ phase: SubagentPhase, parent: SubagentRun? = nil, turn: UUID?, ago: Double,
                 took: Double = 0) -> SubagentRun {
            var run = SubagentRun(rootBotID: target.botID, rootTaskID: target.taskID, parentSubagentID: parent?.id,
                                  depth: (parent?.depth ?? 0) + 1, targetBot: helper, title: title,
                                  brief: "\(title). Report what you find, with the evidence.", workingDirectory: root,
                                  callerInvocationID: turn, phase: phase, createdAt: now.addingTimeInterval(-ago))
            if phase != .preparing { run.startedAt = run.createdAt.addingTimeInterval(1) }
            if !phase.isActive { run.finishedAt = run.createdAt.addingTimeInterval(took) }
            return run
        }
        let duck = helper("QA Duck", "🦆"), owl = helper("Docs Owl", "🦉"), racoon = helper("IT Racoon", "🦝")
        var profile = run("Profile chat scroll with 17 sub-agent cards", by: duck, .completed, parent: parent, turn: parent.callerInvocationID,
                          ago: 400, took: 390)
        profile.handoffOutput = "Scrolling holds 60 fps; the sampler below failed, so stacks come from Instruments directly."
        var sampler = run("Sample main-thread stacks", by: owl, .failed, parent: profile, turn: parent.callerInvocationID, ago: 380, took: 72)
        sampler.errorMessage = "Codex Dev ended without a successful handoff (exit 1). stream disconnected before completion."
        model.delegation.threads[sampler.id] = [
            ChatMessage(role: .user, text: sampler.brief),
            ChatMessage(role: .assistant, text: "Started a time profile of the chat; collecting the trace now."),
        ]
        let preparing = run("Research structured sub-agent phases", by: owl, .preparing, turn: turn, ago: 12)
        model.delegation.states[preparing.id] = RunState(preparing: true)
        let yesterday = UUID()
        var docs = run("Compare Claude Code and Codex sub-agent APIs", by: owl, .completed, turn: yesterday, ago: 86_400, took: 435)
        docs.handoffOutput = "Claude Code's Task returns at once in the background; Codex has no sub-agent tool."
        let silent = run("Task tab overflow menu", by: duck, .completed, turn: yesterday, ago: 86_300, took: 122)
        var restarted = run("Pet posture sheet", by: racoon, .stopped, turn: yesterday, ago: 86_200, took: 291)
        restarted.interruption = SubagentInterruption(cause: .restart, toolCalls: 23, lastAction: "`swift test --filter PetTests`",
            workspace: SubagentWorkspaceState(branch: "feat/pet-posture", head: "3f9c2e1 Sketch the posture sheet", uncommitted: ["macOS/Sources/BotChu/Pets.swift"]))
        restarted.errorMessage = restarted.interruption?.outcome(for: restarted)
        var legacy = run("Research OpenRouter video models", by: owl, .completed, turn: nil, ago: 3 * 86_400, took: 760)
        legacy.handoffOutput = "Two models loop cleanly at 5 s; both need a still to start from."
        return [profile, sampler, preparing, docs, silent, restarted, legacy]
    }
}

/// `BOTCHU_DEMO=tasks` on throwaway data (`macOS/ui-review.sh`): the selected bot gets seven more
/// open tasks, in memory only, so its tabs show every state at once (#128): two working, one
/// starting, one making its worktree, one with news and its pull request, one the owner stopped
/// (#218), and one idle since yesterday, beside the seeded tasks (one finished with a pull request,
/// one failed); three have a summary. With `BOTCHU_INBOX=sample`, Home waits on the owner's input.
/// Nothing is saved and no CLI runs.
@MainActor
enum DemoTabs {
    static func install(in model: AppModel, botID: UUID) {
        guard let bot = model.bot(botID) else { return }
        let now = Date()
        let checkout = model.openTasks(of: botID).first?.checkout ?? bot.workspace
        func issue(_ number: Int, _ title: String, repo: String = "asieke/BotChu", pullRequest: Bool = false) -> BotTask.Work {
            BotTask.Work(number: number, title: title, url: URL(string: "https://github.com/\(repo)/\(pullRequest ? "pull" : "issues")/\(number)")!,
                         isPullRequest: pullRequest)
        }
        let samples: [(BotTask, RunState?, [ChatMessage], Bool)] = [
            (BotTask(for: bot, repo: "asieke/BotChu", checkout: checkout,
                     work: issue(113, "Show repository issues and their count in the Task Activity sidebar"), brief: ""),
             RunState(startedAt: now.addingTimeInterval(-252), hasOutput: true, activity: .coding), [], false),
            (BotTask(for: bot, repo: "asieke/GitChu", checkout: checkout, work: nil, brief: "Speed up the sync"),
             RunState(startedAt: now.addingTimeInterval(-107), hasOutput: true, activity: .testing), [], false),
            (BotTask(for: bot, repo: "asieke/BotChu", checkout: checkout, work: issue(109, "Load conversation history lazily at startup"), brief: ""),
             RunState(startedAt: now.addingTimeInterval(-4)), [], false),
            (BotTask(for: bot, repo: "asieke/BotChu", checkout: checkout,
                     work: issue(112, "Automatically attach the current BotChu screen to bug reports"), brief: ""),
             RunState(startedAt: now, preparing: true), [], false),
            (BotTask(for: bot, repo: "asieke/BotChu", checkout: checkout,
                     work: issue(105, "Please make the providers > allowance column aligned"), brief: ""),
             nil, [ChatMessage(role: .assistant, text: "Done: the allowance windows share one column grid. Opened PR #122.", date: now.addingTimeInterval(-360))], true),
            (BotTask(for: bot, repo: "asieke/BotChu", checkout: checkout, work: issue(118, "Answer Telegram before sub-agents finish"), brief: ""),
             nil, [ChatMessage(role: .user, text: "Work on issue #118.", date: now.addingTimeInterval(-900)),
                   ChatMessage(role: .assistant, text: "Reading the Telegram bridge first.", date: now.addingTimeInterval(-840)),
                   .stopNote(byOwner: true, date: now.addingTimeInterval(-800))], false),
            (BotTask(for: bot, repo: "octocat/Spoon-Knife", checkout: checkout, work: nil, brief: "Tidy the fork instructions"),
             nil, [ChatMessage(role: .assistant, text: "Read the instructions. Ready when you are.", date: now.addingTimeInterval(-90_000))], false),
        ]
        for (index, sample) in samples.enumerated() {
            var task = sample.0
            if index == 4 { task.pullRequest = 122 }
            // Some with a saved summary (#192), the others named as tasks from before are.
            task.summary = [0: "Issue count sidebar", 2: "Lazy history loading", 3: "Screen in bug reports"][index]
            let target = ChatTarget.task(task.id, of: botID)
            model.tasks[botID, default: []].append(task)
            model.conversation(target).replace(sample.2)
            if let run = sample.1 { model.runStates[target] = run }
            if sample.3 { model.unread.insert(target) }
        }
        // The seeded task that opened a pull request has news too.
        if let first = model.openTasks(of: botID).first { model.unread.insert(.task(first.id, of: botID)) }
    }
}
