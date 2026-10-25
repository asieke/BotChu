import Foundation
import Testing
@testable import BotChuCore

/// A mailbox and the helper, as a turn has them, with the app's side played by the test (#111).
private final class HandoffFixture {
    let root: URL
    let ipc: SubagentIPC
    let bin: URL
    let botID = UUID()
    let invocationID = UUID()

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.resolvingSymlinksInPath()
        ipc = SubagentIPC(root: root.appendingPathComponent("mailbox"))
        bin = root.appendingPathComponent("bin")
        try SubagentHookInstaller.install(binDirectory: bin)
        try ipc.prepare()
        try ipc.writeHeartbeat()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start(_ command: String, _ arguments: [String]) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = bin.appendingPathComponent(command)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                               "BOTCHU_IPC_DIR": ipc.root.path, "BOTCHU_INVOCATION_ID": invocationID.uuidString,
                               "BOTCHU_CALLER_BOT_ID": botID.uuidString, "BOTCHU_CALLER_DEPTH": "0",
                               "BOTCHU_WAIT_TIMEOUT_SECONDS": "2"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        return (process, out, err)
    }

    func finish(_ started: (Process, Pipe, Pipe)) -> (code: Int32, output: String, error: String) {
        started.0.waitUntilExit()
        return (started.0.terminationStatus,
                String(decoding: started.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: started.2.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func run(_ command: String, _ arguments: [String]) throws -> (code: Int32, output: String, error: String) {
        finish(try start(command, arguments))
    }

    /// The request the helper wrote, once it has.
    func request() throws -> (file: URL, data: Data) {
        let deadline = Date().addingTimeInterval(3)
        while ipc.pendingRequests().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return try #require(ipc.pendingRequests().first)
    }

    func answer(_ result: TaskHandoffResult) throws {
        try SubagentIPC.encode(result).write(to: ipc.resultURL(result.id), options: .atomic)
    }
}

@Suite struct TaskHandoffTests {
    @Test func theHelperAsksForATaskAndReportsItsCreationThenItsStart() throws {
        let fixture = try HandoffFixture()
        let brief = "Fix #106–#110 with 'quotes'; $(touch injected) `touch injected`\nthen merge"
        let started = try fixture.start("botchu-task", ["create", "--agent", "10x Engineer Bot", "--repo", "asieke/BotChu",
                                                       "--title", "Speed audit", "--brief", brief, "--wait", "10"])
        defer { if started.0.isRunning { started.0.terminate() } }
        let pending = try fixture.request()
        #expect(TaskHandoff.isHandoff(pending.data))
        let handoff = try TaskHandoff.parse(pending.data)
        #expect(handoff.invocationID == fixture.invocationID && handoff.callerBotID == fixture.botID)
        #expect(handoff.callerTaskID == nil && handoff.parentSubagentID == nil)
        #expect(handoff.request.agent == "10x Engineer Bot" && handoff.request.repo == "asieke/BotChu")
        #expect(handoff.request.title == "Speed audit" && handoff.request.task == brief.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("injected").path))
        // A Task request is never taken for a sub-agent run's.
        #expect((try? SubagentIPC.decode(SubagentRequest.self, from: pending.data)) == nil)

        let bot = UUID(), task = UUID()
        let created = TaskHandoffResult(id: handoff.id, phase: .created, targetBotID: bot, targetBotName: "10x Engineer Bot",
                                        taskID: task, taskTitle: "BotChu · Speed audit")
        try fixture.answer(TaskHandoffResult(id: handoff.id, phase: .pending))
        Thread.sleep(forTimeInterval: 0.4)
        try fixture.answer(created)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(started.0.isRunning, "created isn't started: it waits for the first turn")
        try fixture.answer(created.starting(failure: nil))
        let finished = fixture.finish(started)
        #expect(finished.code == 0, "\(finished.error)")
        #expect(finished.output.contains("Task: BotChu · Speed audit (\(task.uuidString))"))
        #expect(finished.output.contains("Agent: 10x Engineer Bot (\(bot.uuidString))"))
        #expect(finished.output.contains("Status: started"))
        #expect(finished.output.contains("Request: \(handoff.id.uuidString.lowercased())"))
        #expect(finished.error.contains("pending") && finished.error.contains("created"))
    }

    @Test func theHelperTellsPendingCreatedAndFailedApartAndRefusesTheOtherKind() throws {
        let fixture = try HandoffFixture()
        // Only created when its wait ends: created, still starting, and a success.
        let waiting = try fixture.start("botchu-task", ["create", "--agent", "Worker", "--repo", "fixture/project", "--issue", "12", "--wait", "0.5"])
        let asked = try fixture.request()
        let first = try TaskHandoff.parse(asked.data)
        #expect(fixture.ipc.removeRequest(asked.file))
        #expect(first.request.issue == 12 && first.request.task.isEmpty)
        try fixture.answer(TaskHandoffResult(id: first.id, phase: .created, targetBotID: UUID(), targetBotName: "Worker",
                                             taskID: UUID(), taskTitle: "project #12", existing: true))
        let created = fixture.finish(waiting)
        #expect(created.code == 0)
        #expect(created.output.contains("Status: created") && created.output.contains("no second Task was made"))

        // A request BotChu hasn't answered is pending, and says how to check it again.
        let unanswered = UUID().uuidString.lowercased()
        let pending = try fixture.run("botchu-task", ["status", unanswered])
        #expect(pending.code == 0 && pending.output.contains("Status: pending") && pending.output.contains("botchu-task status \(unanswered)"))

        // Failed: no Task, the reason, and that asking again is safe.
        let failedID = UUID()
        try fixture.answer(TaskHandoffResult(id: failedID, phase: .failed, errorMessage: "No BotChu agent matches ‘missing’. Run botchu-task list."))
        let failed = try fixture.run("botchu-task", ["status", failedID.uuidString])
        #expect(failed.code == 1)
        #expect(failed.output.contains("botchu-task list") && failed.output.contains("No Task was created"))

        // Its first turn couldn't start: the Task is there to open, and it isn't a success.
        let startFailedID = UUID(), taskID = UUID()
        try fixture.answer(TaskHandoffResult(id: startFailedID, phase: .startFailed, targetBotID: UUID(), targetBotName: "Worker",
                                             taskID: taskID, taskTitle: "project · Fix", errorMessage: "Couldn't make the worktree"))
        let startFailed = try fixture.run("botchu-task", ["status", startFailedID.uuidString])
        #expect(startFailed.code == 1 && startFailed.output.contains(taskID.uuidString) && startFailed.output.contains("Couldn't make the worktree"))

        // Neither command passes for the other.
        let wrongWait = try fixture.run("botchu-subagent", ["wait", startFailedID.uuidString])
        #expect(wrongWait.code == 1 && wrongWait.error.contains("is a Task, not a sub-agent run"))
        let runID = UUID()
        try fixture.ipc.writeResult(SubagentResult(id: runID, targetBotName: "Worker", phase: .completed, handoffOutput: "Done"))
        let wrongStatus = try fixture.run("botchu-task", ["status", runID.uuidString])
        #expect(wrongStatus.code == 1 && wrongStatus.error.contains("isn't a Task request"))

        // A Task needs something to do; nothing is asked for without it.
        for arguments in [["create", "--agent", "Worker", "--repo", "fixture/project"],
                          ["create", "--agent", " ", "--repo", "fixture/project", "--brief", "Go"],
                          ["create", "--agent", "Worker", "--repo", "fixture/project", "--brief", "Go", "--comment"]] {
            let refused = try fixture.run("botchu-task", arguments)
            #expect(refused.code != 0)
        }
        #expect(fixture.ipc.pendingRequests().isEmpty)
        try fixture.ipc.writeRoster([BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))])
        let roster = try fixture.run("botchu-task", ["list"])
        #expect(roster.code == 0 && roster.output.contains("worker — Worker"))
    }

    @Test func handoffsAreReadCheckedAndRecognizedWhenAskedAgain() throws {
        let caller = UUID(), invocation = UUID(), task = UUID(), target = UUID()
        func data(_ fields: [String: Any], kind: String = "task", taskID: UUID? = nil) throws -> Data {
            var object: [String: Any] = ["kind": kind, "id": UUID().uuidString, "invocationID": invocation.uuidString,
                                         "callerBotID": caller.uuidString, "task": fields]
            if let taskID { object["callerTaskID"] = taskID.uuidString }
            return try JSONSerialization.data(withJSONObject: object)
        }
        let handoff = try TaskHandoff.parse(data(["agent": "Worker", "repo": "fixture/project", "task": "Go", "pr": "#7"], taskID: task))
        #expect(handoff.callerTaskID == task && handoff.request.pullRequest == 7 && handoff.request.agent == "Worker")
        // The Task's bot is required, and the dispatch file's own rules apply.
        #expect(throws: TaskRequest.Problem.self) { try TaskHandoff.parse(data(["repo": "fixture/project", "task": "Go"])) }
        #expect(throws: TaskRequest.Problem.self) { try TaskHandoff.parse(data(["agent": "Worker", "repo": "fixture/project"])) }
        #expect(throws: TaskRequest.Problem.self) { try TaskHandoff.parse(data(["agent": "Worker", "repo": "x", "task": "Go"], kind: "run")) }
        #expect(!TaskHandoff.isHandoff(try SubagentIPC.encode(SubagentRequest(invocationID: invocation, callerBotID: caller,
                                                                               targetAgent: "Worker", brief: "Go"))))

        // Only the turn whose mailbox it is in can ask.
        let context = SubagentCallerContext(invocationID: invocation, botID: caller, taskID: task, workingDirectory: "/work")
        try handoff.validate(context)
        var other = context
        other.taskID = nil
        #expect(throws: TaskRequest.Problem.self) { try handoff.validate(other) }
        other = context
        other.invocationID = UUID()
        #expect(throws: TaskRequest.Problem.self) { try handoff.validate(other) }

        // The same request from the same conversation, in another turn, is the same Task; anything
        // else asks for another.
        var again = handoff
        again.id = UUID()
        again.invocationID = UUID()
        again.parentSubagentID = UUID()
        again.request.task = "  Go \n"
        #expect(again.key(for: target) == handoff.key(for: target))
        #expect(handoff.key(for: target) == handoff.key(for: target))
        for change in [{ (h: inout TaskHandoff) in h.request.task = "Go now" }, { $0.callerTaskID = nil }, { $0.callerBotID = UUID() },
                       { $0.request.title = "Other" }, { $0.request.repo = "fixture/other" }, { $0.request.machine = "Far Mac" }] {
            var changed = handoff
            change(&changed)
            #expect(changed.key(for: target) != handoff.key(for: target))
        }
        #expect(handoff.key(for: UUID()) != handoff.key(for: target))
    }

    @Test func aHandedOffTaskKeepsWhoAskedAndItsBotHearsIt() throws {
        let worker = Bot(name: "Worker", accountID: "codex-work", workspace: "/tmp/worker")
        var task = BotTask(for: worker, repo: "fixture/project", checkout: "/tmp/project", work: nil, brief: "Fix it", origin: .agent)
        task.requestedBy = BotTask.Requester(name: "Product Fox", botID: UUID(), taskID: UUID(), conversation: "Product Fox's task Intake",
                                             key: "abc")
        let decoded = try JSONDecoder().decode(BotTask.self, from: JSONEncoder().encode(task))
        #expect(decoded == task && decoded.origin == .agent && decoded.requestedBy?.conversation == "Product Fox's task Intake")
        // Tasks saved before have no requester.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BotTask(for: worker, repo: "r", checkout: "/c",
                                                                                                    work: nil, brief: "b"))) as? [String: Any])
        object["requestedBy"] = nil
        #expect(try JSONDecoder().decode(BotTask.self, from: JSONSerialization.data(withJSONObject: object)).requestedBy == nil)

        let preamble = BotContext.taskPreamble(bot: worker, task: task, memory: "", sharedMemory: "", history: [])
        #expect(preamble.contains("Product Fox handed this task to you, from Product Fox's task Intake"))
        #expect(preamble.contains("The task is your own"))
        #expect(TaskReceipt.handedOff(task, to: "Worker") == "Handed project · Fix it to Worker as a new task")

        // Dispatch files can name the bot too.
        let request = try TaskRequest.parse(Data(#"{"repo": "fixture/project", "task": "Go", "agent": "10x-engineer-bot"}"#.utf8))
        #expect(request.agent == "10x-engineer-bot")
        #expect(try TaskRequest.parse(Data(#"{"repo": "fixture/project", "task": "Go"}"#.utf8)).agent == nil)
    }

    @Test func agentsAreToldBothWaysToHandOffWorkInTheSameTerms() throws {
        let roster = [BotRosterEntry(bot: Bot(name: "Worker", title: "Builds things", workspace: "/tmp/worker"))]
        let section = BotContext.subagentsSection(availableBots: roster)
        for text in ["### Task: `botchu-task create`", "### Sub-agent run: `botchu-subagent`", "new task @bot", "new subagent @bot",
                     "a tab beside its chat", "Sub-agents inspector", "botchu-task create --agent", "botchu-subagent call --agent",
                     "never a second one", "spawns a sub-agent run per issue", "outstanding children stop"] {
            #expect(section.contains(text), "Missing \(text)")
        }
        let bot = Bot(name: "Fox", workspace: "/tmp/fox")
        let agents = BotContext.agentsFile(bot: bot, sharedMemoryPath: "/shared", availableBots: roster)
        #expect(agents.contains("`agent` (optional)") && agents.contains("botchu-task create"))
        #expect(SubagentHookInstaller.commands == ["botchu-subagent", "botchu-task", "botchu-inbox"])
    }

    @Test func everyTurnsMailboxHasBothCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-handoff-mailbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SubagentTransport(machine: .thisMac, namespace: UUID(), invocationID: UUID(), localRoot: root)
        let endpoint = try await transport.prepare(script: SubagentHookInstaller.script, roster: Data("[]".utf8))
        for command in SubagentHookInstaller.commands {
            let path = (endpoint.binDirectory as NSString).appendingPathComponent(command)
            #expect(FileManager.default.isExecutableFile(atPath: path), "\(command)")
        }
    }
}
