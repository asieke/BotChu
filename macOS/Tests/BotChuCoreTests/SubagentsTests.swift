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
                               "BOTCHU_WAIT_TIMEOUT_SECONDS": "2",
                               // This Mac's own load would stretch the heartbeat limit (#368); tests set it.
                               "BOTCHU_LOAD_AVERAGE": "0"].merging(environment) { _, new in new }
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

    /// Runs for the Sub-agents tab's tests: each started by a turn (`turn`) or, as older records
    /// were, without one; `minute` after a fixed start.
    private struct Batch {
        let bot = Bot(name: "QA Bot", workspace: "/test")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }

        func run(_ title: String, _ phase: SubagentPhase, minute: Double, parent: SubagentRun? = nil, turn: UUID? = nil,
                 handoff: String? = nil) -> SubagentRun {
            var run = SubagentRun(rootBotID: bot.id, parentSubagentID: parent?.id, depth: (parent?.depth ?? 0) + 1, targetBot: bot,
                                  title: title, brief: title, workingDirectory: "/test", callerInvocationID: turn ?? parent?.callerInvocationID,
                                  phase: phase, createdAt: start.addingTimeInterval(minute * 60))
            if !phase.isActive {
                run.finishedAt = run.createdAt.addingTimeInterval(30)
                run.handoffOutput = handoff ?? (phase == .completed ? "Done: \(title)" : nil)
            }
            return run
        }
    }

    @Test func tabListsTurnsUnderWayFirstAndFoldsFinishedTreesAtOnce() {
        let batch = Batch()
        let earlier = UUID(), now = UUID()
        let audit = batch.run("Audit", .completed, minute: 0, turn: earlier)
        let lint = batch.run("Lint", .stopped, minute: 1, turn: earlier)
        let build = batch.run("Build", .running, minute: 10, turn: now)
        let checks = batch.run("Checks", .completed, minute: 11, parent: build)
        let docs = batch.run("Docs", .completed, minute: 12, turn: now)
        let review = batch.run("Review", .preparing, minute: 13, turn: now)
        let overview = SubagentOverview(runs: [audit, lint, build, checks, docs, review], calendar: batch.calendar)

        // The turn under way leads, its trees still under way in the order delegated; a finished
        // run beneath one under way stays in that run's tree. Its finished tree folds at once.
        #expect(overview.visible.map(\.key) == [.invocation(now)])
        #expect(overview.visible.first?.isUnderWay == true)
        #expect(overview.visible.first?.roots.map(\.title) == ["Build", "Review"])
        #expect(!overview.isFinished(checks.id) && overview.root(of: checks.id) == build.id)
        // Finished: newest turn first, counting the runs the conversation started.
        #expect(overview.finished.map(\.key) == [.invocation(now), .invocation(earlier)])
        #expect(overview.finished.map { $0.roots.map(\.title) } == [["Docs"], ["Audit", "Lint"]])
        #expect(overview.finishedCount == 3)
        #expect(overview.isFinished(docs.id) && overview.isFinished(lint.id))

        // When Build's tree ends, it moves into Finished with its nested run, without waiting.
        var ended = build
        ended.phase = .completed
        ended.finishedAt = build.createdAt.addingTimeInterval(60)
        let after = SubagentOverview(runs: [audit, lint, ended, checks, docs, review], calendar: batch.calendar)
        #expect(after.visible.first?.roots.map(\.title) == ["Review"])
        #expect(after.finished.first?.roots.map(\.title) == ["Build", "Docs"])
        #expect(after.isFinished(checks.id) && after.finishedCount == 4)

        #expect(SubagentOverview(runs: []).visible.isEmpty && SubagentOverview(runs: []).finished.isEmpty)
    }

    @Test func aFailureAnywhereKeepsItsTreeInViewOpenDownToIt() {
        let batch = Batch()
        let turn = UUID()
        // A batch: one implementer done whose helper's helper failed, one failed, one under way.
        let solve184 = batch.run("Solve #184", .completed, minute: 0, turn: turn)
        let profile = batch.run("Profile retries", .completed, minute: 1, parent: solve184)
        let guidance = batch.run("URLSession guidance", .failed, minute: 2, parent: profile)
        let solve185 = batch.run("Solve #185", .failed, minute: 3, turn: turn)
        let solve186 = batch.run("Solve #186", .completed, minute: 4, turn: turn)
        let runs = [solve184, profile, guidance, solve185, solve186]
        let overview = SubagentOverview(runs: runs, calendar: batch.calendar)

        #expect(overview.visible.first?.roots.map(\.title) == ["Solve #184", "Solve #185"])
        #expect(overview.visible.first?.isUnderWay == false)
        #expect(overview.finished.first?.roots.map(\.title) == ["Solve #186"])
        // The path to the failed grandchild says so at each level; the failure itself doesn't count itself.
        #expect(overview.failedBelow(solve184.id) == 1 && overview.failedBelow(profile.id) == 1)
        #expect(overview.failedBelow(guidance.id) == 0 && overview.failedBelow(solve185.id) == 0)
        #expect(overview.ancestors(of: guidance.id) == [profile.id, solve184.id])
        #expect(overview.isInTree(guidance.id, of: solve184.id) && !overview.isInTree(solve186.id, of: solve184.id))
        // Reading a failure changes nothing it is computed from: it stays until cleared.
        #expect(SubagentOverview(runs: runs, calendar: batch.calendar) == overview)
        #expect(SubagentOverview(runs: runs.filter { $0.id != guidance.id }, calendar: batch.calendar).isFinished(solve184.id))
    }

    @Test func olderRecordsGroupByDayAndOrphansHeadTheirOwnTree() {
        let batch = Batch()
        // Records saved before the turn was: no invocation, grouped by the day they were made.
        let monday = batch.run("Monday's audit", .completed, minute: 0)
        let mondayLate = batch.run("Monday's docs", .stopped, minute: 300)
        let tuesday = batch.run("Tuesday's tests", .failed, minute: 24 * 60)
        // A run whose parent was cleared heads its own tree rather than vanishing.
        var orphan = batch.run("Orphan", .completed, minute: 24 * 60 + 5)
        orphan.parentSubagentID = UUID()
        orphan.depth = 2
        let overview = SubagentOverview(runs: [monday, mondayLate, tuesday, orphan], calendar: batch.calendar)
        let mondayKey = SubagentOverview.GroupKey.day(batch.calendar.startOfDay(for: monday.createdAt))
        let tuesdayKey = SubagentOverview.GroupKey.day(batch.calendar.startOfDay(for: tuesday.createdAt))
        #expect(overview.visible.map(\.key) == [tuesdayKey])
        #expect(overview.finished.map(\.key) == [tuesdayKey, mondayKey])
        #expect(overview.finished.map { $0.roots.map(\.title) } == [["Orphan"], ["Monday's audit", "Monday's docs"]])
        #expect(overview.finished.last?.date == monday.createdAt)

        // A malformed tree that loops is listed once and never recurses forever.
        var a = batch.run("A", .completed, minute: 0)
        var b = batch.run("B", .completed, minute: 1)
        a.parentSubagentID = b.id
        b.parentSubagentID = a.id
        let looped = SubagentOverview(runs: [a, b], calendar: batch.calendar)
        #expect(looped.visible.isEmpty && looped.finished.isEmpty)
        #expect(looped.ancestors(of: a.id).isEmpty)
    }

    @Test func captionsSayTheDayAndTimeOfTheTurn() {
        let batch = Batch()
        let locale = Locale(identifier: "en_US")
        let now = batch.start.addingTimeInterval(3 * 86_400 + 15 * 3600)
        func group(_ date: Date, turn: Bool) -> SubagentOverview.Group {
            .init(key: turn ? .invocation(UUID()) : .day(batch.calendar.startOfDay(for: date)), date: date, roots: [], isUnderWay: false)
        }
        let today = batch.calendar.startOfDay(for: now).addingTimeInterval(11 * 3600 + 120)
        let caption = { (date: Date, turn: Bool) in SubagentOverview.caption(group(date, turn: turn), now: now, calendar: batch.calendar, locale: locale) }
        #expect(caption(today, true).hasPrefix("Today, 11:02"))
        #expect(caption(today.addingTimeInterval(-86_400 + 5 * 3600 + 8 * 60), true).hasPrefix("Yesterday, 4:10"))
        #expect(caption(today.addingTimeInterval(-2 * 86_400), false) == "Saturday, Jan 16")
        #expect(caption(today.addingTimeInterval(-2 * 86_400), true).hasPrefix("Saturday, Jan 16, 11:02"))
        #expect(caption(today.addingTimeInterval(-400 * 86_400), false) == "Sunday, Dec 14, 2025")
    }

    @Test func rowsSayOnlyWhatWasRecorded() {
        let batch = Batch()
        let queued = batch.run("Q", .queued, minute: 0)
        var preparing = batch.run("P", .preparing, minute: 0)
        var running = batch.run("R", .running, minute: 0)
        running.startedAt = running.createdAt.addingTimeInterval(5)
        let done = batch.run("D", .completed, minute: 0)
        let empty = batch.run("E", .completed, minute: 0, handoff: "  \n")
        var failed = batch.run("F", .failed, minute: 0)
        failed.errorMessage = "exit 1"
        var stopped = batch.run("S", .stopped, minute: 0)
        stopped.errorMessage = "Stopped"
        var restarted = stopped
        restarted.errorMessage = "BotChu restarted before this sub-agent finished."

        #expect(SubagentRowState(queued).word == "Queued" && SubagentRowState(queued).isLive)
        // A preparing run's turn defaults to thinking; it still reads Preparing.
        #expect(SubagentRowState(preparing, activity: .thinking).word == "Preparing")
        #expect(SubagentRowState(preparing).since == preparing.createdAt)
        preparing.phase = .running
        #expect(SubagentRowState(preparing).word == "Working")
        #expect(SubagentRowState(running, activity: .researching).word == "Reading files…")
        #expect(SubagentRowState(running).since == running.startedAt)
        #expect(SubagentRowState(running, activity: .coding, stopping: true).kind == .stopping)
        #expect(SubagentRowState(done, stopping: true).kind == .done)
        #expect(SubagentRowState(done).word == "Done" && SubagentRowState(done).ended == done.finishedAt)
        #expect(SubagentRowState(empty).kind == .noHandoff && SubagentRowState(empty).word == "No handoff")
        #expect(SubagentRowState(failed).kind == .failed && !SubagentRowState(failed).isLive)
        #expect(SubagentRowState(stopped).word == "Stopped")
        #expect(SubagentRowState.stopReason(stopped) == nil)
        #expect(SubagentRowState.stopReason(restarted) == "BotChu restarted before this sub-agent finished.")
        #expect(SubagentRowState.stopReason(failed) == nil)
        // Every recorded phase has its own word; none is blocked, accepted or a percentage.
        let words = SubagentPhase.allCases.map { phase in
            var run = batch.run("X", phase, minute: 0)
            run.handoffOutput = phase == .completed ? "ok" : nil
            return SubagentRowState(run, activity: .working).word
        }
        #expect(words == ["Queued", "Preparing", "Running a tool…", "Done", "Failed", "Stopped"])
    }

    /// #430: the details' card shows the run's bot acting out what the run does, as the status
    /// sidebar would, and its last tool call while it runs.
    @Test func theCardsPetAndLiveActionFollowTheRun() {
        let batch = Batch()
        let running = batch.run("R", .running, minute: 0)
        #expect(SubagentRowState(running, activity: .coding).activity == .coding)
        #expect(SubagentRowState(running).activity == .thinking)
        #expect(SubagentRowState(batch.run("Q", .queued, minute: 0)).activity == .idle)
        #expect(SubagentRowState(batch.run("D", .completed, minute: 0)).activity == .done)
        #expect(SubagentRowState(batch.run("E", .completed, minute: 0, handoff: " ")).activity == .idle)
        #expect(SubagentRowState(batch.run("F", .failed, minute: 0)).activity == .failed)
        #expect(SubagentRowState(batch.run("S", .stopped, minute: 0)).activity == .idle)

        let read = ChatMessage(role: .tool, toolName: "Read", toolInput: "/repo/macOS/Sources/ChatView.swift", toolState: .running)
        let test = ChatMessage(role: .tool, toolName: "Bash", toolInput: "swift test --filter PetTests", toolState: .done)
        #expect(SubagentRowState.liveAction([ChatMessage(role: .assistant, text: "Looking."), read], root: "/repo") == "Reading ChatView.swift")
        #expect(SubagentRowState.liveAction([read, test, ChatMessage(role: .assistant, text: "Ran it.")]) == "Ran swift test --filter PetTests")
        #expect(SubagentRowState.liveAction([ChatMessage(role: .assistant, text: "Hi")]) == nil)
    }

    @Test func navigationComesBackToWhereTheListWas() {
        let parent = UUID(), child = UUID(), other = UUID(), task = UUID()
        var navigation = SubagentNavigation()
        let place = SubagentNavigation.Mark(opened: parent, anchor: .run(other), fraction: 0.4)
        navigation.push(.run(parent), from: place)
        navigation.push(.run(parent), from: nil)
        #expect(navigation.path == [.run(parent)])
        let inDetails = SubagentNavigation.Mark(opened: child, anchor: .block("sub-agents"), fraction: 0.1)
        navigation.push(.run(child), from: inDetails)
        #expect(navigation.top == .run(child))
        #expect(navigation.back() == inDetails)
        #expect(navigation.back() == place)
        #expect(navigation.back() == nil && navigation.path.isEmpty)

        // The chat's Open goes straight to a run, nested or finished, from wherever the tab was;
        // Back returns to the list as it was, with no row to reveal.
        navigation.push(.task(task), from: place)
        navigation.push(.run(parent), from: nil)
        navigation.open(child, from: nil)
        #expect(navigation.path == [.run(child)])
        #expect(navigation.back() == .init(anchor: .run(other), fraction: 0.4))
        navigation.open(child, from: place)
        #expect(navigation.back()?.opened == nil)

        // A cleared run's details close.
        navigation.push(.run(parent), from: place)
        navigation.push(.run(child), from: nil)
        navigation.prune { $0 != .run(parent) && $0 != .run(child) }
        #expect(navigation.path.isEmpty)
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

    /// #368: a loaded Mac writes its heartbeat late. With the load above 100, a helper waiting on a
    /// run still going keeps waiting, then says BotChu is busy, never that it stopped responding.
    @Test func aLoadedMacsLateHeartbeatDoesNotFailAWaitWhileTheRunGoes() throws {
        let fixture = try SubagentFixture()
        let id = UUID()
        try fixture.ipc.writeStatus(SubagentStatus(id: id, phase: .running, activity: "Testing"))
        // 60 s late, written by BotChu on a Mac at load 120 on 14 CPUs: the limit is 30 s × 8.6.
        func beat(age: TimeInterval, load: Double, cpus: Int = 14) throws {
            let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-age))
            try Data(#"{"updatedAt":"\#(stamp)","closed":false,"load":\#(load),"cpus":\#(cpus)}"#.utf8).write(to: fixture.ipc.heartbeatURL)
        }
        try beat(age: 60, load: 120)
        let loaded = try fixture.run(["wait", id.uuidString])
        #expect(!loaded.error.contains("no longer responding"))
        #expect(loaded.error.contains("Timed out waiting"))
        // The helper's own load counts too, for a mailbox whose heartbeat says nothing of it.
        try fixture.ipc.writeHeartbeat(now: Date().addingTimeInterval(-60))
        let cpus = ProcessInfo.processInfo.activeProcessorCount
        let here = try fixture.run(["wait", id.uuidString], environment: ["BOTCHU_LOAD_AVERAGE": String(10 * cpus)])
        #expect(!here.error.contains("no longer responding") && here.error.contains("Timed out waiting"))
        // Later than even that: BotChu is busy and the run goes on; a distinct exit says to wait again.
        try beat(age: 100, load: 0)
        let busy = try fixture.run(["wait", id.uuidString], environment: ["BOTCHU_HEARTBEAT_TIMEOUT_SECONDS": "1", "BOTCHU_WAIT_TIMEOUT_SECONDS": "20"])
        #expect(busy.code == 75)
        #expect(busy.error.contains("BotChu is busy") && busy.error.contains("\(id.uuidString.lowercased()) still going"))
        #expect(busy.error.contains("botchu-subagent wait \(id.uuidString.lowercased()) again"))
        // A run BotChu last said nothing about, or a heartbeat half an hour old, is BotChu gone.
        let unknown = try fixture.run(["wait", UUID().uuidString], environment: ["BOTCHU_HEARTBEAT_TIMEOUT_SECONDS": "1"])
        #expect(unknown.code == 1 && unknown.error.contains("no longer responding"))
        try beat(age: 1_900, load: 400)
        let gone = try fixture.run(["wait", id.uuidString])
        #expect(gone.code == 1 && gone.error.contains("no longer responding"))
    }

    @Test func aClosedMailboxSaysItsTurnEnded() throws {
        let fixture = try SubagentFixture()
        try Data(#"{"updatedAt":"1970-01-01T00:00:00Z","closed":true}"#.utf8).write(to: fixture.ipc.heartbeatURL)
        let waited = try fixture.run(["wait", UUID().uuidString])
        #expect(waited.code == 1 && waited.error.contains("mailbox is closed: its turn has ended"))
        let spawned = try fixture.run(["spawn", "--agent", "QA", "--brief", "Check"])
        #expect(spawned.code == 1 && fixture.ipc.pendingRequests().isEmpty)
    }

    @Test func anInterruptedResultSaysSo() throws {
        let fixture = try SubagentFixture()
        let id = UUID()
        try fixture.ipc.writeResult(SubagentResult(id: id, targetBotName: "QA Bot", phase: .stopped, handoffOutput: "Halfway there",
            errorMessage: "The owner stopped it after 3 tool calls in 40s. Workspace: /tmp/x.", interrupted: true))
        let waited = try fixture.run(["wait", id.uuidString])
        #expect(waited.code == 1)
        #expect(waited.output.contains("Halfway there"))
        #expect(waited.output.contains("Interrupted: The owner stopped it after 3 tool calls in 40s."))
        #expect(waited.output.contains("Status: interrupted"))
        #expect(!waited.output.contains("Error:"))
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

    @Test func aCallerAwaitsAResultUntilItIsWrittenOrItsHeartbeatCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-ipc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = UUID(), id = UUID(), other = UUID()
        let transport = SubagentTransport(namespace: UUID(), invocationID: invocation, localRoot: root)
        let mailbox = SubagentIPC(root: root).mailbox(invocation)
        #expect(!mailbox.awaitsResult(id), "No mailbox, no caller")
        #expect(try await transport.prepare(script: "", roster: Data("[]".utf8)).ipcDirectory == mailbox.root.path)
        #expect(mailbox.awaitsResult(id))
        try await transport.writeResult(id: id, data: Data("{}".utf8))
        #expect(!mailbox.awaitsResult(id))
        #expect(mailbox.awaitsResult(other))
        try await transport.close()
        #expect(!mailbox.awaitsResult(other))
    }

    @Test func pruningDeletesOnlyMailboxesWhoseHeartbeatIsADayOld() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-ipc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ipc = SubagentIPC(root: root)
        try ipc.writeRoster([])
        func mailbox(closed: Bool, hours: Double) throws -> String {
            let folder = root.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("results"), withIntermediateDirectories: true)
            let heartbeat = folder.appendingPathComponent("heartbeat.json")
            try Data("{\"closed\":\(closed)}".utf8).write(to: heartbeat)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hours * 3_600)], ofItemAtPath: heartbeat.path)
            return folder.lastPathComponent
        }
        _ = try mailbox(closed: true, hours: 25)
        // A caller BotChu never closed (a crash, or quitting) is just as gone a day later.
        _ = try mailbox(closed: false, hours: 25)
        let recent = try mailbox(closed: true, hours: 1), live = try mailbox(closed: false, hours: 0)
        // A host's namespace, when the host is this Mac, holds mailboxes but no heartbeat of its own.
        let namespace = root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: namespace.appendingPathComponent(UUID().uuidString.lowercased()), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: namespace.path)
        #expect(ipc.prune() == 2)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            == [recent, live, namespace.lastPathComponent, "requests", "results", "status", "roster.json"])
    }
}
