import Foundation
import Testing
@testable import BotChuCore

private final class SubagentFixture {
    let root: URL
    let ipc: SubagentIPC
    let helper: URL
    let botID = UUID()
    let invocationID = UUID()
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-subagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.resolvingSymlinksInPath()
        ipc = SubagentIPC(root: root.appendingPathComponent("mailbox with spaces"))
        helper = try SubagentHookInstaller.install(binDirectory: root.appendingPathComponent("bin with spaces"))
        try ipc.prepare()
        try ipc.writeHeartbeat()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var bot: Bot { Bot(id: botID, name: "QA Bot", title: "Test specialist", instructions: "Verify the evidence", workspace: root.appendingPathComponent("home").path) }

    func start(_ arguments: [String], environment: [String: String] = [:]) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                               "BOTCHU_IPC_DIR": ipc.root.path, "BOTCHU_INVOCATION_ID": invocationID.uuidString,
                               "BOTCHU_CALLER_BOT_ID": botID.uuidString, "BOTCHU_CALLER_DEPTH": "0",
                               "BOTCHU_WAIT_TIMEOUT_SECONDS": "2"].merging(environment) { _, new in new }
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

    func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (code: Int32, output: String, error: String) {
        finish(try start(arguments, environment: environment))
    }
}

@Suite struct SubagentsTests {
    @Test func resolvesUUIDNameSlugAndRejectsAmbiguity() throws {
        let bot = Bot(name: "Café QA Bot", workspace: "/test")
        for query in [bot.id.uuidString.lowercased(), "CAFÉ QA BOT", "cafe-qa-bot", "  Café QA Bot  "] {
            #expect(try SubagentResolver.resolve(query, bots: [bot]).id == bot.id)
        }
        #expect(throws: SubagentError.self) { try SubagentResolver.resolve("missing", bots: [bot]) }
        #expect(throws: SubagentError.self) { try SubagentResolver.resolve("", bots: [bot]) }
        let collision = Bot(name: "Cafe QA Bot", workspace: "/other")
        #expect(throws: SubagentError.self) { try SubagentResolver.resolve("cafe-qa-bot", bots: [bot, collision]) }
        #expect(try SubagentResolver.resolve(bot.id.uuidString, bots: [bot, collision]).id == bot.id)
    }

    @Test func validatesRegisteredTurnAndLimits() throws {
        let fixture = try SubagentFixture()
        let caller = SubagentCallerContext(invocationID: fixture.invocationID, botID: fixture.botID, workingDirectory: fixture.root.path)
        let original = SubagentRequest(invocationID: fixture.invocationID, callerBotID: fixture.botID,
                                      targetAgent: "QA", brief: "Check the parser", createdAt: fixture.date)
        try caller.validate(original, now: fixture.date)
        var request = original
        request.invocationID = UUID()
        #expect(throws: SubagentError.self) { try caller.validate(request, now: fixture.date) }
        request = original
        request.callerBotID = UUID()
        #expect(throws: SubagentError.self) { try caller.validate(request, now: fixture.date) }
        request = original
        request.parentSubagentID = UUID()
        #expect(throws: SubagentError.self) { try caller.validate(request, now: fixture.date) }
        request = original
        request.depth = 1
        #expect(throws: SubagentError.self) { try caller.validate(request, now: fixture.date) }
        request = original
        request.brief = " \n"
        #expect(throws: SubagentError.self) { try caller.validate(request, now: fixture.date) }
        request.brief = String(repeating: "x", count: SubagentLimits.maxBriefCharacters + 1)
        #expect(throws: SubagentError.self) { try caller.validate(request, now: fixture.date) }
        #expect(throws: SubagentError.self) { try caller.validate(original, now: fixture.date.addingTimeInterval(301)) }
        var nested = caller
        nested.depth = SubagentLimits.maxDepth
        request = original
        request.depth = nested.depth
        #expect(throws: SubagentError.self) { try nested.validate(request, now: fixture.date) }
        request = original
        request.callerWorkingDirectory = "/untrusted/path"
        try caller.validate(request, now: fixture.date)
        #expect(caller.workingDirectory == fixture.root.path)
    }

    @Test func storesHomeTaskDescendantsAndStreamSnapshotsSeparately() throws {
        let fixture = try SubagentFixture()
        let home = BotHome(workspace: fixture.bot.workspace)
        let taskID = UUID()
        var run = SubagentRun(rootBotID: fixture.botID, depth: 1, targetBot: fixture.bot, title: "Home check",
                              brief: "Check", workingDirectory: fixture.root.path, createdAt: fixture.date)
        try home.saveSubagent(run)
        var child = SubagentRun(rootBotID: fixture.botID, rootTaskID: taskID, parentSubagentID: run.id, depth: 2,
                                targetBot: fixture.bot, title: "Task check", brief: "Inspect", workingDirectory: fixture.root.path,
                                callerInvocationID: fixture.invocationID, callerHostID: UUID(), createdAt: fixture.date)
        child.phase = .failed
        child.errorMessage = "Interrupted"
        child.finishedAt = fixture.date
        try home.saveSubagent(child)
        let initial = ChatMessage(role: .assistant, text: "Streaming", date: fixture.date)
        try home.appendSubagentMessages([initial], id: run.id)
        var finished = initial
        finished.text = "Streaming complete"
        try home.saveSubagentThread([finished], id: run.id)
        try home.appendSubagentMessages([initial], id: child.id, taskID: taskID)
        run.phase = .completed
        run.handoffOutput = finished.text
        run.finishedAt = fixture.date
        try home.saveSubagent(run)
        #expect(home.loadSubagents() == [run])
        #expect(home.loadSubagents(taskID: taskID) == [child])
        #expect(home.loadSubagentThread(id: run.id) == [finished])
        #expect(home.loadSubagentThread(id: child.id).isEmpty)
        #expect(home.loadSubagentThread(id: child.id, taskID: taskID) == [initial])
        #expect(home.loadThread().isEmpty)
        try home.removeSubagent(id: run.id)
        #expect(home.loadSubagents().isEmpty)
        #expect(home.loadSubagents(taskID: taskID) == [child])
    }

    @Test func tabListsRunsUnderWayFirstAndFoldsFinishedOnesNewestFirst() {
        let bot = Bot(name: "QA Bot", workspace: "/test")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func run(_ title: String, _ phase: SubagentPhase, minute: Double, parent: SubagentRun? = nil) -> SubagentRun {
            SubagentRun(rootBotID: bot.id, parentSubagentID: parent?.id, depth: parent == nil ? 1 : 2, targetBot: bot, title: title,
                        brief: title, workingDirectory: "/test", phase: phase, createdAt: start.addingTimeInterval(minute * 60))
        }
        let audit = run("Audit", .completed, minute: 0)
        let build = run("Build", .running, minute: 1)
        let checks = run("Checks", .completed, minute: 2, parent: build)
        let docs = run("Docs", .failed, minute: 3)
        let review = run("Review", .stopped, minute: 4)
        let runs = [audit, build, checks, docs, review]

        // A finished run beneath one under way stays in that run's tree.
        let sections = SubagentSections(runs)
        #expect(sections.current.map(\.title) == ["Build"])
        #expect(sections.finished.map(\.title) == ["Review", "Docs", "Audit"])
        #expect(sections.failedCount == 1)

        // Finished runs the tab keeps in view stay with those under way, in the order delegated.
        let kept = SubagentSections(runs, keeping: [audit.id, docs.id])
        #expect(kept.current.map(\.title) == ["Audit", "Build", "Docs"])
        #expect(kept.finished.map(\.title) == ["Review"])
        #expect(kept.failedCount == 0)
        #expect(SubagentSections([]) == SubagentSections([], keeping: [audit.id]))
        #expect(SubagentSections([]).current.isEmpty && SubagentSections([]).finished.isEmpty)
    }

    @Test func contextUsesTargetIdentityAndEnforcesDepthLimit() throws {
        let fixture = try SubagentFixture()
        let roster = [BotRosterEntry(bot: fixture.bot)]
        var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: fixture.bot, title: "Audit", brief: "Find defects",
                              workingDirectory: "/shared/project")
        let preamble = BotContext.subagentPreamble(bot: fixture.bot, run: run, callerDescription: "Caller on Task #41",
                                                   memory: "Target's memory", sharedMemory: "Shared context", soul: "Target's voice", availableBots: roster)
        for text in ["You are QA Bot", "Verify the evidence", "Target's memory", "Target's voice", "Caller on Task #41",
                     "Find defects", "Handoff Report", "<subagents>", "/shared/project", "outstanding children stop"] {
            #expect(preamble.contains(text), "Missing \(text)")
        }
        run.depth = 3
        let terminal = BotContext.subagentPreamble(bot: fixture.bot, run: run, callerDescription: "Caller", memory: "", sharedMemory: "", availableBots: roster)
        #expect(!terminal.contains("<subagents>"))
        #expect(terminal.contains("Maximum sub-agent recursion depth (3)"))
        #expect(!terminal.contains("botchu-subagent spawn"))
        #expect(BotContext.agentsFile(bot: fixture.bot, sharedMemoryPath: "/shared-memory", availableBots: roster).contains("qa-bot"))
        #expect(BotContext.sessionPreamble(bot: fixture.bot, memory: "", sharedMemory: "", history: [], availableBots: roster).contains("botchu-subagent call"))
        let task = BotTask(repo: "test/repo", checkout: "/test")
        #expect(BotContext.taskPreamble(bot: fixture.bot, task: task, memory: "", sharedMemory: "", history: [], availableBots: roster).contains("botchu-subagent wait"))
    }

    @Test func helperListsAndAtomicallySpawnsUnicodeAndShellCharacters() throws {
        let fixture = try SubagentFixture()
        try fixture.ipc.writeRoster([BotRosterEntry(bot: fixture.bot)])
        let list = try fixture.run(["list"])
        #expect(list.code == 0)
        #expect(list.output.contains("qa-bot") && list.output.contains(fixture.botID.uuidString))
        let brief = "Keep 'quotes' and \"double quotes\"; $(touch injected) `touch injected`\nCafé 🤖"
        let spawned = try fixture.run(["spawn", "--agent", "QA Bot", "--title", "Review", "--workspace", "bot_home", "--brief", brief])
        #expect(spawned.code == 0, "\(spawned.error)")
        let id = try #require(UUID(uuidString: spawned.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let files = fixture.ipc.pendingRequests()
        #expect(files.count == 1)
        let request = try SubagentIPC.decode(SubagentRequest.self, from: #require(files.first).data)
        #expect(request.id == id && request.invocationID == fixture.invocationID && request.callerBotID == fixture.botID)
        #expect(request.brief == brief && request.workspaceMode == .subagentHomeWorkspace)
        let reportedFolder = URL(fileURLWithPath: try #require(request.callerWorkingDirectory)).resolvingSymlinksInPath()
        #expect(reportedFolder == fixture.root.resolvingSymlinksInPath())
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("injected").path))
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.ipc.requestsURL.path)
        #expect(entries == [id.uuidString.lowercased() + ".json"])
    }

    @Test func helperCallWaitsForRealResultAndReturnsHandoff() throws {
        let fixture = try SubagentFixture()
        let started = try fixture.start(["call", "--agent", "QA Bot", "--brief", "Review"])
        defer { if started.0.isRunning { started.0.terminate() } }
        let deadline = Date().addingTimeInterval(1.5)
        while fixture.ipc.pendingRequests().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let pending = try #require(fixture.ipc.pendingRequests().first)
        let request = try SubagentIPC.decode(SubagentRequest.self, from: pending.data)
        try fixture.ipc.writeStatus(SubagentStatus(id: request.id, phase: .running, activity: "Testing parser"))
        try fixture.ipc.writeResult(SubagentResult(id: request.id, targetBotID: fixture.botID, targetBotName: "QA Bot", phase: .completed,
                                                 handoffOutput: "All 10 checks passed.\nNo defects found."))
        let finished = fixture.finish(started)
        #expect(finished.code == 0)
        #expect(finished.output.contains("=== Sub-agent: QA Bot") && finished.output.contains("All 10 checks passed."))
        #expect(fixture.ipc.removeRequest(pending.file))
        #expect(fixture.ipc.pendingRequests().isEmpty)
    }

    @Test func helperWaitCollectsEveryResultAndPropagatesFailure() throws {
        let fixture = try SubagentFixture()
        let ids = [UUID(), UUID(), UUID()]
        for (id, phase) in zip(ids, [SubagentPhase.completed, .failed, .stopped]) {
            try fixture.ipc.writeResult(SubagentResult(id: id, targetBotName: "Bot", phase: phase,
                                                     handoffOutput: "Report \(phase.rawValue)", errorMessage: phase == .failed ? "No such agent" : nil))
        }
        let waited = try fixture.run(["wait"] + ids.map(\.uuidString))
        #expect(waited.code == 1)
        for id in ids { #expect(waited.output.contains(id.uuidString.lowercased())) }
        #expect(waited.output.contains("No such agent"))
        #expect(waited.output.components(separatedBy: "=== Sub-agent:").count == 4)
    }

    @Test func helperStopsWaitingAfterAppDeathAndRejectsBadInput() throws {
        let fixture = try SubagentFixture()
        try fixture.ipc.writeHeartbeat(now: Date().addingTimeInterval(-60))
        let waited = try fixture.run(["wait", UUID().uuidString])
        #expect(waited.code == 1 && waited.error.contains("no longer responding"))
        let spawned = try fixture.run(["spawn", "--agent", "QA", "--brief", "Check"])
        #expect(spawned.code == 1 && fixture.ipc.pendingRequests().isEmpty)
        try fixture.ipc.writeHeartbeat()
        let invalid = try fixture.run(["wait", "../../outside"])
        #expect(invalid.code == 1 && invalid.error.contains("Invalid request or caller UUID"))
        let tooDeep = try fixture.run(["spawn", "--agent", "QA", "--brief", "Check"], environment: ["BOTCHU_CALLER_DEPTH": "3"])
        #expect(tooDeep.code == 1 && tooDeep.error.contains("Maximum sub-agent depth"))
        let unregistered = try fixture.run(["spawn", "--agent", "QA", "--brief", "Check"], environment: ["BOTCHU_INVOCATION_ID": ""])
        #expect(unregistered.code == 1 && unregistered.error.contains("Missing BOTCHU_INVOCATION_ID"))
        #expect(fixture.ipc.pendingRequests().isEmpty)
    }

    @Test func malformedRequestsAreBoundedAndTerminalResultsRequired() throws {
        let fixture = try SubagentFixture()
        let id = UUID()
        try Data(repeating: 65, count: SubagentLimits.maxRequestBytes + 1).write(to: fixture.ipc.requestURL(id))
        let pending = fixture.ipc.pendingRequests()
        #expect(pending.count == 1 && pending[0].data.isEmpty)
        #expect(!fixture.ipc.removeRequest(fixture.root.appendingPathComponent("outside.json")))
        #expect(throws: SubagentError.self) {
            try fixture.ipc.writeResult(SubagentResult(id: id, targetBotName: "QA", phase: .running))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.ipc.resultURL(id).path))
    }
}
