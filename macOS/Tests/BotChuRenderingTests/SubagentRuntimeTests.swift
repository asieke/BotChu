import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_TEST_REAL_DELEGATION"] == "1"))
    func realCodexTurnReceivesAClaudeSubagentHandoff() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        fixture.settings.commands = [:]
        var worker = fixture.worker
        worker.selectAccount(Accounts.account(id: "claude-dev"))
        fixture.app.update(worker)
        fixture.app.send("Use your shell to run exactly: botchu-subagent call --agent Worker --brief 'Reply with HANDOFF-REAL-OK, without tools or any files.' Then repeat the returned handoff. Do not edit files or do any other task.", to: fixture.target)
        try await fixture.wait(seconds: 180) { !fixture.app.isRunning(fixture.target) }
        let runs = fixture.app.delegation.records[fixture.target] ?? []
        #expect(runs.count == 1)
        #expect(runs.first?.accountID == "claude-dev")
        #expect(runs.first?.phase == .completed)
        #expect(runs.first?.handoffOutput?.contains("HANDOFF-REAL-OK") == true)
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("HANDOFF-REAL-OK") == true)
    }

    @Test func handoffsAndTaskReceiptsNeverWaitForRunReviews() async throws {
        let fixture = try SubagentFixture()
        let gate = ReviewGate()
        defer {
            Task { await gate.release() }
            fixture.cleanUp()
        }
        let reviewed = ReviewedKeys()
        fixture.app.evaluator.limits.delay = 0
        // One tool call is signal enough here, so that each review asks its model.
        fixture.app.evaluator.limits.toolCalls = 1
        fixture.app.evaluator.runner = { job in
            reviewed.add(job.key)
            await gate.wait()
            return #"<evaluation>{"summary": "Fine", "changes": []}</evaluation>"#
        }
        fixture.app.send("REVIEWED_PARENT", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }

        // The handoff came back, the turn ended and its receipt reached Home; their ends only
        // extended the work each bot's next review covers (#138), and added no review.
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("HANDOFF-REVIEWED") == true)
        #expect(fixture.app.delegation.all.map(\.phase) == [.completed])
        #expect(fixture.app.thread(.home(fixture.parent.id)).contains { $0.role == .receipt })
        #expect(fixture.app.evaluator.records.isEmpty)
        let conversation = ReviewConversation(botID: fixture.parent.id, taskID: fixture.target.taskID)
        try await fixture.wait { fixture.app.reviewStates[fixture.parent.id]?.unreviewed().isEmpty == false }
        let worker = fixture.app.reviewStates[fixture.worker.id]?.unreviewed() ?? []
        #expect(worker.map(\.conversation) == [conversation])
        #expect(worker.first?.subagents.count == 1 && worker.first?.hasTurns == false, "The sub-agent joins the review of the bot it ran as")
        let parent = fixture.app.reviewStates[fixture.parent.id]?.unreviewed() ?? []
        #expect(parent.map(\.conversation) == [conversation])
        #expect(parent.first?.subagents.isEmpty == true && parent.first?.hasTurns == true, "The caller's review covers its own turn")

        // Asked for now, each is about its own bot, on that bot's own account, one at a time.
        #expect(fixture.app.canReviewNow(.home(fixture.worker.id)) && fixture.app.canReviewNow(fixture.target))
        fixture.app.reviewNow(.home(fixture.worker.id))
        fixture.app.reviewNow(fixture.target)
        try await fixture.wait { fixture.app.evaluator.records.values.contains { $0.phase == .running && $0.snapshot != nil } }
        let records = Array(fixture.app.evaluator.records.values)
        #expect(records.count == 2)
        let workerReview = try #require(records.first { $0.botID == fixture.worker.id })
        #expect(workerReview.subject.kind == .day && workerReview.accountID == "codex-work")
        let taskReview = try #require(records.first { $0.botID == fixture.parent.id })
        #expect(taskReview.subject.kind == .task && taskReview.subject.taskID == fixture.target.taskID && taskReview.accountID == "codex-dev")
        #expect(records.filter { $0.phase == .running }.count == 1, "One at a time")

        await gate.release()
        try await fixture.wait { fixture.app.evaluator.records.values.allSatisfy { $0.phase == .done } }
        // Nothing reviews a review, and a review that changed nothing says nothing in Home.
        #expect(reviewed.keys.sorted() == [workerReview.id, taskReview.id].sorted())
        #expect(fixture.app.evaluator.records.count == 2)
        #expect(!fixture.app.thread(.home(fixture.parent.id)).contains { $0.role == .note && $0.text.hasPrefix("Reviewed") })
        #expect(!fixture.app.thread(.home(fixture.worker.id)).contains { $0.role == .note && $0.text.hasPrefix("Reviewed") })
        // The task's Activity lists the reviews that covered it; the worker's Home, its own.
        #expect(fixture.app.evaluations(for: fixture.target).map(\.id).sorted() == [workerReview.id, taskReview.id].sorted())
        #expect(fixture.app.evaluations(for: .home(fixture.worker.id)).map(\.id) == [workerReview.id])
        #expect(fixture.app.reviewStatus(for: fixture.target) == .upToDate)

        // After a relaunch, the status sidebar lists them again, from the bots' folders.
        let relaunched = AppModel(store: fixture.store, settings: fixture.settings)
        defer { relaunched.stopAll() }
        #expect(relaunched.evaluations(for: fixture.target).map(\.id).sorted() == [workerReview.id, taskReview.id].sorted())
        #expect(relaunched.evaluations(for: fixture.target).allSatisfy { $0.phase == .done && $0.outcome == .noChange })
    }

    @Test func replayingARejectedRequestCannotAdmitWorkAfterTheRosterChanges() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let caller = try await fixture.app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path, machine: .thisMac, hostID: nil)
        defer { fixture.app.delegation.endCaller(caller.id) }
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        let request = SubagentRequest(invocationID: caller.id, callerBotID: fixture.parent.id, callerTaskID: fixture.target.taskID,
                                     depth: 0, targetAgent: "Future", brief: "LEAF")
        let data = try SubagentIPC.encode(request)
        try data.write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { FileManager.default.fileExists(atPath: ipc.resultURL(request.id).path) }
        var renamed = fixture.worker
        renamed.name = "Future"
        fixture.app.update(renamed)
        // Recreate an unacknowledged file after the original failed outcome was returned.
        try data.write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { !FileManager.default.fileExists(atPath: ipc.requestURL(request.id).path) }
        let result = try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: ipc.resultURL(request.id)))
        #expect(result.phase == .failed)
        #expect(fixture.app.delegation.all.isEmpty)
    }

    /// #107: a run's end is saved off the main thread, slowly here, and its handoff goes back only
    /// once its record is on disk; meanwhile the run counts as active for its caller.
    @Test func aHandoffGoesBackOnlyOnceItsRecordIsSaved() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        let slow = StorageQueue(before: { work in if work.label == "save" { Thread.sleep(forTimeInterval: 0.3) } })
        app.delegation = SubagentRuntime(model: app, root: app.delegation.root, archive: SubagentArchive(storage: slow))
        let caller = try await app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path, machine: .thisMac, hostID: nil)
        defer { app.delegation.endCaller(caller.id) }
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        let request = SubagentRequest(invocationID: caller.id, callerBotID: fixture.parent.id, callerTaskID: fixture.target.taskID,
                                     depth: 0, targetAgent: "Worker", brief: "LEAF")
        try SubagentIPC.encode(request).write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { FileManager.default.fileExists(atPath: ipc.resultURL(request.id).path) }
        // Delivered only after the completed record is durable.
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).first?.phase == .completed)
        let result = try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: ipc.resultURL(request.id)))
        #expect(result.phase == .completed)
        #expect(result.handoffOutput == "HANDOFF-LEAF")
        #expect(app.delegation.run(request.id)?.phase == .completed)
    }

    @Test func transcriptWriteFailureWaitsForTheWorkerToExitBeforeReturningFailure() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let caller = try await fixture.app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path, machine: .thisMac, hostID: nil)
        defer { fixture.app.delegation.endCaller(caller.id) }
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        let request = SubagentRequest(invocationID: caller.id, callerBotID: fixture.parent.id, callerTaskID: fixture.target.taskID,
                                     depth: 0, targetAgent: "Worker", brief: "SAVE_FAILURE")
        try SubagentIPC.encode(request).write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("waiting-for-save").path) }
        let transcript = fixture.home.subagentURL(id: request.id, taskID: fixture.target.taskID).appendingPathComponent("thread.jsonl")
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.createDirectory(at: transcript, withIntermediateDirectories: true)
        try Data().write(to: fixture.folder.appendingPathComponent("fail-ready"))
        try await fixture.wait { FileManager.default.fileExists(atPath: ipc.resultURL(request.id).path) }
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("child-exited").path))
        let result = try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: ipc.resultURL(request.id)))
        #expect(result.phase == .failed)
        #expect(!fixture.app.isRunning(fixture.target))
    }

    @Test func sshDelegationUsesHostCommandsForSharedWorkAndLocalCommandsForBotHome() async throws {
        let fixture = try SubagentFixture(remote: true)
        defer { fixture.cleanUp() }
        fixture.app.send("REMOTE_WORKSPACES", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        let records = fixture.app.delegation.records[fixture.target] ?? []
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.phase == .completed })
        let shared = try #require(records.first { $0.workspaceMode == .sharedCallerWorkspace })
        let ownHome = try #require(records.first { $0.workspaceMode == .subagentHomeWorkspace })
        #expect(shared.hostID == fixture.host?.id)
        #expect(shared.workingDirectory == fixture.folder.path)
        let sharedLocation = try #require(shared.handoffOutput).split(separator: "|").map(String.init)
        try #require(sharedLocation.count == 4)
        #expect(URL(fileURLWithPath: sharedLocation[1]).resolvingSymlinksInPath().path == fixture.folder.resolvingSymlinksInPath().path)
        #expect(sharedLocation[2] == "remote")
        #expect(shared.handoffOutput?.contains(fixture.root.appendingPathComponent("remote-home").path) == true)
        #expect(ownHome.hostID == nil)
        #expect(ownHome.workingDirectory == fixture.worker.workspace)
        let homeLocation = try #require(ownHome.handoffOutput).split(separator: "|").map(String.init)
        try #require(homeLocation.count == 4)
        #expect(URL(fileURLWithPath: homeLocation[1]).resolvingSymlinksInPath().path == URL(fileURLWithPath: fixture.worker.workspace).resolvingSymlinksInPath().path)
        #expect(homeLocation[2] == "local")
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("LOCATION|") == true)
        #expect(fixture.app.bot(fixture.worker.id)?.sessionID == "worker-home-session")
    }

    @Test func sshHandoffRetriesAResultWriteThatLosesItsConnection() async throws {
        let fixture = try SubagentFixture(remote: true)
        defer { fixture.cleanUp() }
        try Data().write(to: fixture.root.appendingPathComponent("fail-result-once"))
        fixture.app.send("NEST", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("fail-result-once").path))
        #expect(fixture.app.delegation.all.count == 1)
        #expect(fixture.app.delegation.all.first?.phase == .completed)
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("HANDOFF-LEAF") == true)
    }

    @Test func sshHelperPreparationFailureDoesNotStartOrStrandAConversation() async throws {
        let fixture = try SubagentFixture(remote: true)
        defer { fixture.cleanUp() }
        try Data().write(to: fixture.root.appendingPathComponent("fail-transport"))
        fixture.app.send("NEST", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(fixture.app.delegation.all.isEmpty)
        #expect(fixture.app.thread(fixture.target).last?.role == .error)
        #expect(fixture.app.thread(fixture.target).last?.text.contains("python3 unavailable") == true)
    }

    @Test func stoppingAnSSHParentStopsItsNestedWorkersAndSavesTheirTerminalState() async throws {
        let fixture = try SubagentFixture(remote: true)
        defer { fixture.cleanUp() }
        fixture.app.send("STOP_TREE", to: fixture.target)
        try await fixture.wait { fixture.app.delegation.all.filter { $0.phase == .running }.count == 2 }
        fixture.app.stop(fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) && fixture.app.delegation.all.allSatisfy { !$0.phase.isActive } }
        #expect(fixture.app.delegation.all.count == 2)
        #expect(fixture.app.delegation.all.allSatisfy { $0.phase == .stopped })
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).allSatisfy { $0.phase == .stopped })
    }

    @Test func sshSubagentSavesRememberedNotesToItsOwnBotOnTheMac() async throws {
        let fixture = try SubagentFixture(remote: true)
        defer { fixture.cleanUp() }
        fixture.app.send("REMOTE_MEMORY", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(fixture.app.delegation.all.first?.phase == .completed)
        #expect(Workspace.read(fixture.worker.workspace + "/MEMORY.md").contains("REMOTE-LESSON"))
        #expect(!Workspace.read(fixture.parent.workspace + "/MEMORY.md").contains("REMOTE-LESSON"))
    }

    @Test func aTaskTurnSavesItsNotesReportsAFailedSaveAndRetriesIt() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let memory = fixture.parent.workspace + "/MEMORY.md"
        fixture.app.send("FIRST", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        let before = Workspace.read(memory)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: memory)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: memory) }

        fixture.app.send("TASK_MEMORY", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        let thread = fixture.app.thread(fixture.target)
        #expect(thread.contains { $0.role == .error && $0.text.hasPrefix("Couldn't save 1 note to Parent's memory (MEMORY.md): ") })
        #expect(thread.last?.role == .note && thread.last?.text == "Saved to the shared memory: “SHARED-LESSON”")
        #expect(Workspace.read(fixture.settings.sharedMemoryPath).contains("\n- SHARED-LESSON\n"))
        #expect(Workspace.read(memory) == before)
        #expect(fixture.app.unsavedMemory[fixture.parent.id] == 1)

        // The next turn hears that the note wasn't saved, and BotChu tries it again after that turn.
        fixture.app.send("MEMORY_REPORT", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text == "MEMORY-REPORTED")
        #expect(fixture.app.unsavedMemory[fixture.parent.id] == 1)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: memory)
        fixture.app.retryMemory(for: fixture.target)
        await fixture.app.storage.settle()
        #expect(fixture.app.thread(fixture.target).last?.text == "Saved to Parent's memory: “TASK-LESSON”")
        #expect(Workspace.read(memory).components(separatedBy: "\n").filter { $0 == "- TASK-LESSON" }.count == 1)
        #expect(fixture.app.unsavedMemory[fixture.parent.id] == 0)
    }

    @Test func restartRedeliversCompletedAndInterruptedHandoffsToTheRemoteMailbox() async throws {
        let fixture = try SubagentFixture(remote: true)
        defer { fixture.cleanUp() }
        let invocation = UUID(), host = try #require(fixture.host)
        let transport = SubagentTransport(machine: Machine(destination: host.destination), namespace: fixture.app.delegation.namespace,
                                         invocationID: invocation, localRoot: fixture.app.delegation.root)
        let endpoint = try await transport.prepare(script: SubagentHookInstaller.script, roster: SubagentIPC.encode([] as [BotRosterEntry]))
        var completed = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                   title: "Saved handoff", brief: "Already completed", workingDirectory: fixture.folder.path,
                                   hostID: host.id, phase: .completed)
        completed.callerInvocationID = invocation
        completed.callerHostID = host.id
        completed.handoffOutput = "DURABLE-REMOTE-HANDOFF"
        completed.finishedAt = .now
        var interrupted = completed
        interrupted.id = UUID()
        interrupted.phase = .running
        interrupted.handoffOutput = nil
        interrupted.finishedAt = nil
        try fixture.home.saveSubagent(completed)
        try fixture.home.saveSubagent(interrupted)
        let restored = AppModel(store: fixture.store, settings: fixture.settings)
        defer { restored.stopAll() }
        let results = URL(fileURLWithPath: endpoint.ipcDirectory).appendingPathComponent("results")
        let completedFile = results.appendingPathComponent("\(completed.id.uuidString.lowercased()).result.json")
        let interruptedFile = results.appendingPathComponent("\(interrupted.id.uuidString.lowercased()).result.json")
        try await fixture.wait {
            FileManager.default.fileExists(atPath: completedFile.path) && FileManager.default.fileExists(atPath: interruptedFile.path)
        }
        let final = try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: completedFile))
        let stopped = try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: interruptedFile))
        #expect(final.phase == .completed)
        #expect(final.handoffOutput == "DURABLE-REMOTE-HANDOFF")
        #expect(stopped.phase == .stopped)
        #expect(restored.delegation.all.allSatisfy { !$0.phase.isActive })
    }

    @Test func subagentFanoutReturnsNestedHandoffsToTheCallingTask() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("FANOUT", to: fixture.target)
        try await fixture.wait { !app.isRunning(fixture.target) }
        let runs = app.delegation.records[fixture.target] ?? []
        #expect(runs.count == 3)
        #expect(runs.allSatisfy { $0.phase == .completed })
        #expect(runs.filter { $0.parentSubagentID != nil }.count == 1)
        #expect(runs.map(\.depth).sorted() == [1, 1, 2])
        #expect(runs.allSatisfy { $0.workingDirectory == fixture.folder.path && $0.accountID == "codex-work" })
        #expect(app.delegation.records[.home(fixture.parent.id)]?.isEmpty != false)
        #expect(app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("HANDOFF-LEAF") == true)
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).count == 3)
        for run in runs {
            #expect(fixture.home.loadSubagentThread(id: run.id, taskID: fixture.target.taskID).contains { $0.role == .assistant })
        }
        // The target's Home session and its transcript are untouched by delegation.
        #expect(app.bot(fixture.worker.id)?.sessionID == "worker-home-session")
        #expect(app.thread(.home(fixture.worker.id)).isEmpty)
    }

    @Test func stoppingAParentStopsNestedRunsAndLeavesNoActiveChildren() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("STOP_TREE", to: fixture.target)
        try await fixture.wait { app.delegation.all.filter { $0.phase == .running }.count == 2 }
        app.stop(fixture.target)
        try await fixture.wait { !app.isRunning(fixture.target) }
        #expect(app.delegation.all.count == 2)
        #expect(app.delegation.all.allSatisfy { $0.phase == .stopped })
        #expect(app.delegation.states.isEmpty)
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).allSatisfy { $0.phase == .stopped })
    }

    /// #145: Antigravity printed a sub-agent's handoff and the end of its turn, then never exited
    /// (and ignored Stop), so the run stayed running until BotChu restarted. Its handoff now goes
    /// back a short while after the turn ended, completed, with a note saying why it took so long.
    @Test func aWorkerThatNeverExitsAfterItsReplyStillHandsOff() async throws {
        let limit = AgentRun.defaultLingerLimit
        AgentRun.defaultLingerLimit = 1
        defer { AgentRun.defaultLingerLimit = limit }
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let caller = try await fixture.app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path, machine: .thisMac, hostID: nil)
        defer { fixture.app.delegation.endCaller(caller.id) }
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        let request = SubagentRequest(invocationID: caller.id, callerBotID: fixture.parent.id, callerTaskID: fixture.target.taskID,
                                     depth: 0, targetAgent: "Worker", brief: "LINGER")
        try SubagentIPC.encode(request).write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { FileManager.default.fileExists(atPath: ipc.resultURL(request.id).path) }
        let result = try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: ipc.resultURL(request.id)))
        #expect(result.phase == .completed)
        #expect(result.handoffOutput == "HANDOFF-LINGER")
        let thread = fixture.home.loadSubagentThread(id: request.id, taskID: fixture.target.taskID)
        #expect(thread.last?.role == .note)
        #expect(thread.last?.text == "Codex Work didn't exit after its reply, so BotChu ended it.")
    }

    /// Stop ends a worker whose CLI ignores SIGINT and SIGTERM (#145), so the tree stops.
    @Test func stoppingAParentEndsAWorkerThatIgnoresInterruptAndTerminate() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("STUBBORN_TREE", to: fixture.target)
        try await fixture.wait { app.delegation.all.contains { $0.phase == .running } }
        try await Task.sleep(for: .milliseconds(500))
        app.stop(fixture.target)
        try await fixture.wait { !app.isRunning(fixture.target) && app.delegation.all.allSatisfy { !$0.phase.isActive } }
        #expect(app.delegation.all.count == 1)
        #expect(app.delegation.all.allSatisfy { $0.phase == .stopped })
    }

    @Test func subagentDepthAndUnknownNamesFailWithoutHangingTheCaller() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        fixture.app.send("DEPTH", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(fixture.app.delegation.all.count == 3)
        #expect(fixture.app.delegation.all.map(\.depth).sorted() == [1, 2, 3])
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.lowercased().contains("depth") == true)
        fixture.app.send("UNKNOWN", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("missing-bot") == true)
    }

    /// #46: a streaming sub-agent's transcript is checkpointed off the main thread, a few times a
    /// second at most, and its output doesn't invalidate what views of other conversations read.
    @Test func aStreamingSubagentIsCheckpointedAndLeavesOtherConversationsAlone() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        let writes = ArchiveWrites()
        app.delegation = SubagentRuntime(model: app, root: app.delegation.root,
                                         archive: SubagentArchive(interval: 0.2) { try writes.record($0) })
        app.send("STREAM_PARENT", to: fixture.target)
        try await fixture.wait { app.delegation.all.first.map { (app.delegation.threads[$0.id]?.count ?? 0) >= 2 } ?? false }
        let run = try #require(app.delegation.all.first)
        let home = ChatTarget.home(fixture.parent.id)
        let otherChanged = Flag(), ownChanged = Flag()
        withObservationTracking {
            _ = app.isRunning(home)
            _ = app.delegation.records[home]
            _ = app.status(of: home)
            _ = app.thread(home)
            _ = app.isBusy(fixture.worker.id)
        } onChange: { otherChanged.set() }
        withObservationTracking { _ = app.delegation.threads[run.id] } onChange: { ownChanged.set() }
        let before = writes.count
        let started = Date()
        try Data().write(to: fixture.folder.appendingPathComponent("stream-go"))
        try await fixture.wait { (app.delegation.threads[run.id]?.count ?? 0) >= 102 }
        let elapsed = Date().timeIntervalSince(started)
        #expect(ownChanged.value)
        #expect(!otherChanged.value)
        // 100 tool calls, but at most one write per interval, not one per batch of output.
        #expect(writes.count - before <= Int(elapsed / 0.2) + 2)
        try Data().write(to: fixture.folder.appendingPathComponent("stream-done"))
        try await fixture.wait { !app.isRunning(fixture.target) }
        #expect(app.delegation.run(run.id)?.phase == .completed)
        #expect(fixture.home.loadSubagentThread(id: run.id, taskID: fixture.target.taskID).filter { $0.role == .tool }.count == 101)
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).first?.phase == .completed)
    }

    /// #46: quitting writes what a streaming sub-agent said since its last checkpoint.
    @Test func quittingKeepsWhatAStreamingSubagentSaid() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.delegation = SubagentRuntime(model: app, root: app.delegation.root, archive: SubagentArchive(interval: 600))
        app.send("STREAM_PARENT", to: fixture.target)
        try await fixture.wait { app.delegation.all.first.map { (app.delegation.threads[$0.id]?.count ?? 0) >= 2 } ?? false }
        let run = try #require(app.delegation.all.first)
        try Data().write(to: fixture.folder.appendingPathComponent("stream-go"))
        try await fixture.wait { (app.delegation.threads[run.id]?.count ?? 0) >= 102 }
        // Nothing streamed is written yet: not once per batch.
        #expect(fixture.home.loadSubagentThread(id: run.id, taskID: fixture.target.taskID).count == 1)
        app.stopAll()
        #expect(fixture.home.loadSubagentThread(id: run.id, taskID: fixture.target.taskID).filter { $0.role == .tool }.count == 101)
    }

    @Test func subagentTreesGroupChildrenOnce() throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let parent = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                 title: "Parent", brief: "Parent", workingDirectory: fixture.folder.path, phase: .completed)
        let children = (0..<3).map { index in
            SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, parentSubagentID: parent.id, depth: 2,
                        targetBot: fixture.worker, title: "Child \(index)", brief: "Child", workingDirectory: fixture.folder.path, phase: .completed)
        }
        fixture.app.delegation.records[fixture.target] = [parent] + children
        #expect(fixture.app.delegation.children(of: nil, in: fixture.target).map(\.id) == [parent.id])
        #expect(fixture.app.delegation.children(of: parent.id).map(\.title) == ["Child 0", "Child 1", "Child 2"])
        #expect(fixture.app.delegation.run(children[1].id)?.title == "Child 1")
        fixture.app.delegation.records[fixture.target] = [parent]
        #expect(fixture.app.delegation.children(of: parent.id).isEmpty)
        #expect(fixture.app.delegation.run(children[1].id) == nil)
    }

    @Test func restartMarksPersistedSubagentsStoppedAndInspectorRendersTheirTree() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        var parent = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID,
                                 depth: 1, targetBot: fixture.worker, title: "Audit changes", brief: "Inspect the task's changes",
                                 workingDirectory: fixture.folder.path, phase: .running)
        parent.startedAt = .now.addingTimeInterval(-30)
        let child = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, parentSubagentID: parent.id,
                               depth: 2, targetBot: fixture.worker, title: "Run checks", brief: "Verify the audit",
                               workingDirectory: fixture.folder.path, phase: .completed)
        try fixture.home.saveSubagent(parent)
        try fixture.home.saveSubagent(child)
        let restored = AppModel(store: fixture.store, settings: fixture.settings)
        defer { restored.stopAll() }
        // Stopped once that is saved, off the main thread (#107).
        await restored.storage.settle()
        #expect(restored.delegation.run(parent.id)?.phase == .stopped)
        #expect(restored.delegation.run(child.id)?.phase == .completed)
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).allSatisfy { !$0.phase.isActive })
        let defaults = UserDefaults(suiteName: fixture.domain)!
        defaults.set("subagents", forKey: InspectorTab.storageKey)
        restored.show(fixture.target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: TaskInspector(target: fixture.target).environment(restored).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.contentView?.fittingSize.width ?? 0 <= 380)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("subagents"))
        }
        // Recreate with a live run to check automatic expansion and bounded streaming content.
        restored.delegation.records[fixture.target] = [parent, child]
        restored.delegation.states[parent.id] = RunState(hasOutput: true, activity: .testing)
        restored.delegation.threads[parent.id] = [
            ChatMessage(role: .tool, toolName: "Run tests", toolInput: "swift test", toolState: .running),
            ChatMessage(role: .assistant, text: "Checking the changed files and test results."),
        ]
        window.contentView = NSHostingView(rootView: TaskInspector(target: fixture.target).environment(restored).defaultAppStorage(defaults))
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.contentView?.fittingSize.width ?? 0 <= 380)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("subagents-expanded"))
        }
        parent.phase = .stopped
        restored.delegation.records[fixture.target] = [parent, child]
        restored.delegation.states[parent.id] = nil
        restored.delegation.clear(parent.id)
        await restored.storage.settle()
        #expect(restored.delegation.all.isEmpty)
    }

    /// The tab leads with runs under way and folds the rest into Finished. A run that finishes while
    /// the tab shows it stays in view, and the chat's Open brings a finished one back out.
    @Test func subagentsTabFoldsFinishedRunsAndOpenBringsOneOut() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        func run(_ title: String, _ phase: SubagentPhase) -> SubagentRun {
            var run = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                  title: title, brief: "Report back on \(title.lowercased()).", workingDirectory: fixture.folder.path,
                                  phase: phase)
            run.startedAt = .now.addingTimeInterval(-90)
            if !phase.isActive { run.finishedAt = .now }
            return run
        }
        var live = run("Build the app", .running)
        let finished = ["Audit the parser", "Check the docs", "Review the tests"].enumerated().map { index, title in
            run(title, index == 0 ? .failed : .completed)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        // The tab's height: in a new view, as showing the tab again makes one, or in the same view after a change.
        func height(fresh: Bool, snapshot: String? = nil) async throws -> CGFloat {
            if fresh {
                window.contentView = NSHostingView(rootView: SubagentsInspectorContent(target: fixture.target)
                    .environment(fixture.app).padding().frame(width: 340))
            }
            try await Task.sleep(for: .milliseconds(200))
            let size = window.contentView?.fittingSize ?? .zero
            if let snapshot, let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(100))
                DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent(snapshot))
            }
            return size.height
        }

        fixture.app.delegation.records[fixture.target] = [live]
        let running = try await height(fresh: true)
        // Finished runs add one folded row, not a card each.
        fixture.app.delegation.records[fixture.target] = [live] + finished
        let withFinished = try await height(fresh: true, snapshot: "subagents-folded")
        #expect(withFinished > running && withFinished - running < 40)
        // A run that finishes while the tab shows it stays where it was, now with its handoff.
        live.phase = .completed
        live.finishedAt = .now
        live.handoffOutput = "The app builds."
        fixture.app.delegation.records[fixture.target] = [live] + finished
        let justFinished = try await height(fresh: false, snapshot: "subagents-just-finished")
        #expect(justFinished > withFinished)
        // Shown again, it is folded with the others.
        let folded = try await height(fresh: true)
        #expect(folded + 60 < justFinished)
        // The chat's Open on a finished run brings it out above the folded rest, opened: in the tab
        // as it shows, and in a new one, as when Open switches to the tab.
        SubagentFocus.shared.focus(finished[1].id)
        let opened = try await height(fresh: false, snapshot: "subagents-opened")
        #expect(opened > folded + 60)
        SubagentFocus.shared.focus(finished[2].id)
        let openedAnew = try await height(fresh: true)
        #expect(openedAnew > folded + 60)
    }

    /// Open scrolls the status sidebar to a finished run it brings out below the fold.
    @Test func openScrollsToAFinishedRunBelowTheFold() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        func run(_ title: String, _ phase: SubagentPhase) -> SubagentRun {
            var run = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                  title: title, brief: "Keep going.", workingDirectory: fixture.folder.path, phase: phase)
            run.startedAt = .now
            if !phase.isActive { run.finishedAt = .now }
            return run
        }
        let done = run("Done last", .completed)
        fixture.app.delegation.records[fixture.target] = (0..<3).map { run("Running \($0)", .running) } + [done]
        let defaults = UserDefaults(suiteName: fixture.domain)!
        defaults.set("subagents", forKey: InspectorTab.storageKey)
        fixture.app.show(fixture.target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: TaskInspector(target: fixture.target).environment(fixture.app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content))
        #expect(scroll.documentVisibleRect.minY < 1)
        SubagentFocus.shared.focus(done.id)
        try await Task.sleep(for: .milliseconds(500))
        // Three running cards, opened, come first; the finished one is now below them, in view.
        #expect(scroll.documentVisibleRect.minY > 200)
    }
}

/// Counts the sub-agent archive's writes, then writes them.
private final class ArchiveWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return written
    }
    func record(_ snapshot: SubagentArchive.Snapshot) throws {
        lock.lock()
        written += 1
        lock.unlock()
        try SubagentArchive.writeToDisk(snapshot)
    }
}

@MainActor private final class SubagentFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-subagent-runtime-\(UUID().uuidString)")
    let domain = "local.BotChu.SubagentTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let parent: Bot
    let worker: Bot
    let home: BotHome
    let app: AppModel
    let target: ChatTarget
    let folder: URL
    let host: SSHHost?
    let originalSSH: String

    init(remote: Bool = false) throws {
        originalSSH = Machine.ssh
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        parent = Bot(name: "Parent", accountID: "codex-dev", workspace: root.appendingPathComponent("parent").path)
        worker = Bot(name: "Worker", instructions: "Use the worker persona", accountID: "codex-work", workspace: root.appendingPathComponent("worker").path,
                     sessionID: "worker-home-session", sessionAccountID: "codex-work")
        home = BotHome(workspace: parent.workspace)
        try home.save(parent)
        try BotHome(workspace: worker.workspace).save(worker)
        try "WORKER-SOUL".write(toFile: worker.workspace + "/SOUL.md", atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        for account in [parent.accountID, worker.accountID] { settings.commands[account] = "/usr/bin/python3 \(Shell.quote(script.path)) --machine local" }
        if remote {
            let remoteHome = root.appendingPathComponent("remote-home")
            try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
            let ssh = root.appendingPathComponent("ssh")
            // Its HOME, helper, mailbox and captured stdin all belong to this isolated fixture.
            try """
                #!/bin/sh
                while [ $# -gt 0 ]; do
                  case $1 in -o|-p|-i|-l|-F) shift 2 ;; -*) shift ;; *) break ;; esac
                done
                shift
                export HOME=\(Shell.quote(remoteHome.path))
                incoming=$(/usr/bin/mktemp \(Shell.quote(root.appendingPathComponent("ssh-input.XXXXXX").path)))
                /bin/cat > "$incoming"
                if [ -f \(Shell.quote(root.appendingPathComponent("fail-result-once").path)) ] && /usr/bin/grep -q 'results' "$incoming"; then
                  /bin/rm \(Shell.quote(root.appendingPathComponent("fail-result-once").path))
                  echo 'Connection dropped during result delivery' >&2
                  exit 255
                fi
                case "$*" in
                  *'exec python3 -c'*)
                    if [ -f \(Shell.quote(root.appendingPathComponent("fail-transport").path)) ]; then
                      echo 'python3 unavailable on test host' >&2
                      exit 127
                    fi ;;
                esac
                exec /bin/sh -c "$*" < "$incoming"

                """.write(to: ssh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
            Machine.ssh = ssh.path
            let commands = Dictionary(uniqueKeysWithValues: [parent.accountID, worker.accountID].map {
                ($0, "/usr/bin/python3 \(Shell.quote(script.path)) --machine remote")
            })
            host = SSHHost(nickname: "Isolated test host", destination: "fixture-host", reposFolder: root.path, commands: commands)
            settings.hosts = [host!]
        } else { host = nil }
        var task = BotTask(for: parent, repo: "fixture/repo", checkout: root.path, work: nil, brief: "Test delegation", host: host)
        folder = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        task.folder = folder.path
        try home.save(task)
        target = .task(task.id, of: parent.id)
        try store.saveIndex([Store.Entry(id: parent.id, workspace: parent.workspace), Store.Entry(id: worker.id, workspace: worker.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
    }

    func wait(seconds: Int = 20, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 40) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out: \(app.thread(target).map(\.text)) / \(app.delegation.all.map { "\($0.title): \($0.phase) \($0.errorMessage ?? "")" })")
        throw CocoaError(.executableLoad)
    }
    func cleanUp() {
        app.stopAll()
        Machine.ssh = originalSSH
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, os, re, signal, subprocess, sys, time
    def emit(value): print(json.dumps(value), flush=True)
    def helper(*args):
        result = subprocess.run(["botchu-subagent", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout + result.stderr
    depth = int(os.environ["BOTCHU_CALLER_DEPTH"])
    prompt = sys.argv[-1]
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if depth:
        assert "WORKER-SOUL" in prompt
        brief = re.search(r"<handoff_brief>\s*(.*?)\s*</handoff_brief>", prompt, re.S).group(1)
    else:
        brief = prompt.splitlines()[-1]
    if brief == "REMOTE_WORKSPACES":
        shared = helper("call", "--agent", "Worker", "--workspace", "shared", "--brief", "LOCATION")
        own = helper("call", "--agent", "Worker", "--workspace", "bot_home", "--brief", "LOCATION")
        answer = shared + "\n" + own
    elif brief == "REMOTE_MEMORY":
        answer = helper("call", "--agent", "Worker", "--brief", "REMEMBER")
    elif brief == "REMEMBER":
        answer = "Handoff Report: complete. <remember>REMOTE-LESSON</remember>"
    elif brief == "TASK_MEMORY":
        answer = "That's my default now.\n<remember>\n- TASK-LESSON\n</remember>\n<remember scope=\"shared\">\n- SHARED-LESSON\n</remember>"
    elif brief == "MEMORY_REPORT":
        reported = "<memory_updates>" in prompt and "Couldn't save 1 note to your MEMORY.md" in prompt
        answer = "MEMORY-REPORTED" if reported else "NO-MEMORY-REPORT"
    elif brief == "LOCATION":
        machine = sys.argv[sys.argv.index("--machine") + 1]
        answer = "LOCATION|" + os.getcwd() + "|" + machine + "|" + os.environ["HOME"]
    elif brief == "FANOUT":
        one = helper("spawn", "--agent", "Worker", "--brief", "NEST").strip()
        two = helper("spawn", "--agent", "Worker", "--brief", "LEAF").strip()
        answer = helper("wait", one, two)
    elif brief == "NEST":
        answer = helper("call", "--agent", "Worker", "--brief", "LEAF")
    elif brief == "STOP_TREE":
        answer = helper("call", "--agent", "Worker", "--brief", "STOP_CHILD")
    elif brief == "STOP_CHILD":
        answer = helper("call", "--agent", "Worker", "--brief", "BLOCK")
    elif brief == "SAVE_FAILURE":
        def stop_after_cleanup(signum, frame):
            time.sleep(.4)
            open("child-exited", "w").close()
            sys.exit(130)
        signal.signal(signal.SIGINT, stop_after_cleanup)
        open("waiting-for-save", "w").close()
        while not os.path.exists("fail-ready"): time.sleep(.01)
        emit({"type":"item.completed", "item":{"type":"agent_message", "text":"Cannot persist this reply"}})
        while True: time.sleep(.1)
    elif brief == "BLOCK":
        while True: time.sleep(.1)
    elif brief == "LINGER":
        # Antigravity in #145: the handoff and the end of its turn, then it never exits and ignores Stop.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        emit({"type":"item.completed", "item":{"type":"agent_message", "text":"HANDOFF-LINGER"}})
        emit({"type":"turn.completed"})
        while True: time.sleep(.1)
    elif brief == "STUBBORN_TREE":
        answer = helper("call", "--agent", "Worker", "--brief", "STUBBORN")
    elif brief == "STUBBORN":
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(.1)
    elif brief == "STREAM_PARENT":
        answer = helper("call", "--agent", "Worker", "--brief", "STREAM_CHILD")
    elif brief == "STREAM_CHILD":
        def shell(i):
            emit({"type":"item.completed", "item":{"id":"item_%d" % i, "type":"command_execution", "command":"echo %d" % i,
                  "aggregated_output":"x" * 256, "exit_code":0, "status":"completed"}})
        shell(0)
        while not os.path.exists("stream-go"): time.sleep(.01)
        for i in range(1, 101):
            shell(i)
            time.sleep(.005)
        while not os.path.exists("stream-done"): time.sleep(.01)
        answer = "HANDOFF-STREAM"
    elif brief == "REVIEWED_PARENT":
        emit({"type":"item.completed", "item":{"id":"item_parent", "type":"command_execution", "command":"git status",
              "aggregated_output":"clean", "exit_code":0, "status":"completed"}})
        answer = helper("call", "--agent", "Worker", "--brief", "REVIEWED_CHILD").strip()
    elif brief == "REVIEWED_CHILD":
        emit({"type":"item.completed", "item":{"id":"item_child", "type":"command_execution", "command":"swift test",
              "aggregated_output":"passed", "exit_code":0, "status":"completed"}})
        answer = "HANDOFF-REVIEWED"
    elif brief == "DEPTH":
        answer = helper("call", "--agent", "Worker", "--brief", "DEPTH")
    elif brief == "UNKNOWN":
        answer = helper("call", "--agent", "missing-bot", "--brief", "LEAF")
    else:
        answer = "HANDOFF-LEAF"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}

/// Holds a stand-in run review until the test lets it go.
private actor ReviewGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// The runs a stand-in run review was asked about.
private final class ReviewedKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ key: String) { lock.withLock { list.append(key) } }
    var keys: [String] { lock.withLock { list } }
}
