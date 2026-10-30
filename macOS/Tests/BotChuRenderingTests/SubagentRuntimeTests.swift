import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func aReservedSubagentStoppedBeforeLaunchHasOneUnmeasuredLedgerEntry() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let runtime = fixture.app.delegation!
        var record = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID,
            depth: 1, targetBot: fixture.worker, title: "Reserved", brief: "Never launched",
            workingDirectory: fixture.folder.path, phase: .queued, createdAt: Date(timeIntervalSince1970: 1_793_145_600))
        record.model = "reserved-model"
        runtime.records[fixture.target] = [record]
        runtime.stop(record.id)
        runtime.stop(record.id)
        try await fixture.wait { runtime.all.first?.phase == .stopped }
        await runtime.archive.storage.settle()
        let ledger = try UsageLedger.read(in: BotHome(workspace: fixture.parent.persistencePath))
        let saved = try #require(ledger.entries.first)
        #expect(ledger.entries.count == 1 && saved.subagentRunID == record.id && saved.botID == fixture.worker.id)
        #expect(saved.startedAt == record.createdAt && saved.outcome == .stopped && saved.usage == nil)
        #expect(saved.accountID == record.accountID && saved.model == "reserved-model" && saved.modelSource == .requested)
    }

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
        await fixture.app.storage.settle()
        let ledger = try UsageLedger.read(in: BotHome(workspace: fixture.parent.persistencePath))
        let delegatedUsage = try #require(ledger.entries.first { $0.kind == .subagent })
        #expect(delegatedUsage.botID == fixture.worker.id && delegatedUsage.taskID == fixture.target.taskID)
        #expect(delegatedUsage.subagentRunID == fixture.app.delegation.all.first?.id)
        #expect(delegatedUsage.accountID == "codex-work" && delegatedUsage.outcome == .finished)
        #expect(ledger.entries.filter { $0.kind == .task }.count == 1)
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

    @Test func localMailboxStatusesFollowLateInstalledActivityWithoutRequests() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let runtime = fixture.app.delegation!
        let caller = try await runtime.prepareCaller(target: fixture.target, directory: fixture.folder.path,
                                                     machine: .thisMac, hostID: nil)
        defer { runtime.endCaller(caller.id) }
        let directory = URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!)
        var record = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID,
            depth: 1, targetBot: fixture.worker, title: "Observed", brief: "Observed",
            workingDirectory: fixture.folder.path, callerInvocationID: caller.id, phase: .preparing)
        runtime.records[fixture.target] = [record]
        let statusURL = directory.appendingPathComponent("status/\(record.id.uuidString.lowercased()).status.json")
        func status() -> SubagentStatus? {
            (try? Data(contentsOf: statusURL)).flatMap { try? SubagentIPC.decode(SubagentStatus.self, from: $0) }
        }
        try await fixture.wait { status()?.activity == "Preparing…" }
        // Observation first saw a record without a RunState. Installing it later must be tracked.
        runtime.states[record.id] = RunState(hasOutput: true, activity: .browsing)
        try await fixture.wait { status()?.activity == BotActivity.browsing.doing }
        record.phase = .running
        runtime.records[fixture.target] = [record]
        try await fixture.wait { status()?.phase == .running }
        let written = try Data(contentsOf: statusURL)
        record.title = "Unrelated title change"
        runtime.records[fixture.target] = [record]
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: statusURL) == written, "Unchanged status is not rewritten")
        runtime.states[record.id] = RunState(hasOutput: true, activity: .coding)
        try await fixture.wait { status()?.activity == BotActivity.coding.doing }
        #expect(try await caller.transport.poll().isEmpty)
        record.phase = .completed
        runtime.records[fixture.target] = [record]
        runtime.endCaller(caller.id)
        let heartbeat = directory.appendingPathComponent("heartbeat.json")
        try await fixture.wait { (try? String(contentsOf: heartbeat, encoding: .utf8))?.contains("1970") == true }
        let closed = try Data(contentsOf: heartbeat)
        try await Task.sleep(for: .seconds(2.2))
        #expect(try Data(contentsOf: heartbeat) == closed, "No heartbeat reopens a completed caller")
    }

    @Test func heartbeatContinuesWhileAdmissionWaitsForDurableStorage() async throws {
        let fixture = try SubagentFixture()
        let gate = MailboxStorageGate()
        defer { gate.release(); fixture.cleanUp() }
        let app = fixture.app
        let storage = StorageQueue(before: { work in if work.label == "save" { gate.wait() } })
        app.delegation = SubagentRuntime(model: app, root: app.delegation.root, archive: SubagentArchive(storage: storage))
        let caller = try await app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path,
                                                           machine: .thisMac, hostID: nil)
        defer { app.delegation.endCaller(caller.id) }
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        let request = SubagentRequest(invocationID: caller.id, callerBotID: fixture.parent.id,
            callerTaskID: fixture.target.taskID, depth: 0, targetAgent: "Worker", brief: "LEAF")
        try SubagentIPC.encode(request).write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { gate.entered }
        let heartbeat = ipc.root.appendingPathComponent("heartbeat.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: heartbeat.path)
        try await Task.sleep(for: .seconds(2.3))
        let updated = try FileManager.default.attributesOfItem(atPath: heartbeat.path)[.modificationDate] as? Date
        #expect((updated ?? .distantPast) > Date(timeIntervalSinceNow: -3))
        #expect(FileManager.default.fileExists(atPath: ipc.requestURL(request.id).path), "No acknowledgment before persistence")
        #expect(app.delegation.all.isEmpty)
        gate.release()
        try await fixture.wait { FileManager.default.fileExists(atPath: ipc.resultURL(request.id).path) }
        #expect(app.delegation.all.map(\.id) == [request.id])
    }

    @Test func finishingALocalMailboxDrainsBatchesAfterAnInFlightDeliveryExactlyOnce() async throws {
        let fixture = try SubagentFixture()
        let gate = MailboxStorageGate()
        defer { gate.release(); fixture.cleanUp() }
        let app = fixture.app
        let storage = StorageQueue(before: { work in if work.label == "delivery" { gate.wait() } })
        app.inbox = InboxModel(model: app, root: fixture.store.root, storage: storage)
        let caller = try await app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path,
                                                           machine: .thisMac, hostID: nil)
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        var ids: [UUID] = []
        for index in 0..<40 {
            let id = UUID()
            ids.append(id)
            let data = try JSONSerialization.data(withJSONObject: [
                "kind": "inbox", "id": id.uuidString, "invocationID": caller.id.uuidString,
                "callerBotID": fixture.parent.id.uuidString, "callerTaskID": fixture.target.taskID!.uuidString,
                "delivery": ["title": "Delivery \(index)", "note": "Saved exactly once", "purpose": "completed"]
            ])
            try data.write(to: ipc.requestURL(id), options: .atomic)
        }
        try await fixture.wait { gate.entered }
        #expect(app.inbox.all.isEmpty)
        let finish = Task { await app.delegation.finishCaller(caller.id) }
        // Give finishCaller time to cancel the watcher while its first receive is still saving.
        try await Task.sleep(for: .milliseconds(100))
        gate.release()
        await finish.value
        #expect(app.inbox.all.count == 40)
        #expect(Set(app.inbox.all.map(\.title)).count == 40)
        #expect(app.delegation.error == nil)
        #expect(try await caller.transport.poll().isEmpty)
        for id in ids {
            let result = try SubagentIPC.decode(InboxResult.self, from: Data(contentsOf: ipc.resultURL(id)))
            #expect(result.deliveryID != nil && result.errorMessage == nil)
        }
        #expect(InboxFolder(home: fixture.home).load().count == 40)
    }

    @Test func stoppingDuringSessionPreparationPreventsHomeTaskAndChildLaunches() async throws {
        let gate = SessionPreparationTestGate()
        let storage = StorageQueue(before: { work in if work.label == "session-preparation" { gate.wait() } })
        let fixture = try SubagentFixture(storage: storage)
        defer { gate.release(); fixture.cleanUp() }
        let app = fixture.app
        // Home and task share the bot's preparation lane; Stop stays immediate while it waits.
        for target in [ChatTarget.home(fixture.parent.id), fixture.target] {
            _ = await app.loadedThread(target)
            app.drafts[target] = "LEAF"
            app.send("LEAF", to: target)
        }
        try await fixture.wait { gate.started }
        let typedAt = Date()
        app.drafts[fixture.target] = "Typing still works"
        let typed = Date().timeIntervalSince(typedAt)
        let stoppedAt = Date()
        app.stop(.home(fixture.parent.id))
        app.stop(fixture.target)
        let stopped = Date().timeIntervalSince(stoppedAt)
        #expect(app.drafts[fixture.target] == "Typing still works")
        #expect(!app.isRunning(fixture.target) && !app.isRunning(.home(fixture.parent.id)))
        gate.release()
        await storage.settle()
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.bot(fixture.parent.id)?.sessionID == nil && app.task(fixture.target)?.sessionID == nil)
        #expect(!app.thread(fixture.target).contains { $0.role == .assistant })
        print("session preparation: draft edit \(typed * 1_000) ms; Stop \(stopped * 1_000) ms while file work waits")

        // A child has its own identity and the same cancellation boundary.
        gate.reset()
        let caller = try await app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path, machine: .thisMac, hostID: nil)
        defer { app.delegation.endCaller(caller.id) }
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        let request = SubagentRequest(invocationID: caller.id, callerBotID: fixture.parent.id, callerTaskID: fixture.target.taskID,
                                     depth: 0, targetAgent: "Worker", brief: "LEAF")
        try SubagentIPC.encode(request).write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { gate.started }
        app.delegation.stop(request.id)
        gate.release()
        try await fixture.wait { app.delegation.run(request.id)?.phase == .stopped }
        await storage.settle()
        #expect(app.delegation.run(request.id)?.sessionID == nil)
        #expect(app.delegation.run(request.id)?.phase == .stopped)
    }

    @Test func toolPolicyChangedDuringPreparationAppliesToTheLaunch() async throws {
        let gate = SessionPreparationTestGate()
        let storage = StorageQueue(before: { work in if work.label == "session-preparation" { gate.wait() } })
        let fixture = try SubagentFixture(storage: storage)
        defer { gate.release(); fixture.cleanUp() }
        let app = fixture.app
        let command = fixture.root.appendingPathComponent("gh")
        try "#!/bin/sh\necho UNBLOCKED\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        // Match the real locator: the temporary directory can contain /var -> /private/var.
        let location = ToolLocation(path: command.path, realPath: try #require(ToolLocator.realPath(command.path)))
        app.tools.locate = { _ in (catalog: ["gh": [location]], declared: [:]) }
        _ = await app.loadedThread(fixture.target)
        app.drafts[fixture.target] = "POLICY_CHECK"
        app.send("POLICY_CHECK", to: fixture.target)
        try await fixture.wait { gate.started }
        app.tools.change { $0.enforcedSince = Date() }
        gate.release()
        try await fixture.wait { !app.isRunning(fixture.target) && app.task(fixture.target)?.sessionID != nil }
        #expect(app.thread(fixture.target).last(where: { $0.role == .assistant })?.text == "TOOL-BLOCKED")
    }

    @Test func resumedTurnsRefreshContextAndPreparationFailureDoesNotStartCLI() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        let target = fixture.target
        _ = await app.loadedThread(target)
        app.drafts[target] = "LEAF"
        app.send("LEAF", to: target)
        try await fixture.wait { !app.isRunning(target) && app.task(target)?.sessionID != nil }
        let first = app.sessionPreparation.statistics.prepared
        // The stand-in captures every prompt next to the CLI, including resumed turns.
        let instructions = fixture.parent.workspace + "/INSTRUCTIONS.md"
        try "REFRESHED-SESSION-INSTRUCTIONS".write(toFile: instructions, atomically: true, encoding: .utf8)
        app.drafts[target] = "LEAF"
        app.send("LEAF", to: target)
        try await fixture.wait { !app.isRunning(target) && app.thread(target).filter { $0.role == .assistant }.count == 2 }
        #expect(app.sessionPreparation.statistics.prepared > first)
        let prompts = try String(contentsOf: fixture.root.appendingPathComponent("session-prompts.txt"), encoding: .utf8)
        #expect(prompts.contains("REFRESHED-SESSION-INSTRUCTIONS"))

        let agents = fixture.parent.workspace + "/AGENTS.md"
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: agents)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: agents) }
        try "ANOTHER-EDIT".write(toFile: instructions, atomically: true, encoding: .utf8)
        app.drafts[target] = "LEAF"
        app.send("LEAF", to: target)
        try await fixture.wait { !app.isRunning(target) && app.thread(target).last?.role == .error }
        #expect(app.thread(target).last?.text.contains("Couldn't prepare the turn") == true)
        #expect(app.thread(target).filter { $0.role == .assistant }.count == 2)
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

    @Test func restartRedeliversALocalHandoffOnlyWhileItsCallerWaits() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let waiting = UUID(), ended = UUID(), answered = UUID(), old = UUID()
        var mailboxes: [UUID: URL] = [:]
        for invocation in [waiting, ended, answered, old] {
            let transport = SubagentTransport(namespace: fixture.app.delegation.namespace, invocationID: invocation,
                                             localRoot: fixture.app.delegation.root)
            mailboxes[invocation] = URL(fileURLWithPath: try await transport.prepare(script: "", roster: Data("[]".utf8)).ipcDirectory)
            if invocation == ended || invocation == old { try await transport.close() }
        }
        func record(_ title: String, _ phase: SubagentPhase, caller: UUID) throws -> (run: SubagentRun, result: URL) {
            var run = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                  title: title, brief: title, workingDirectory: fixture.folder.path, phase: phase)
            run.callerInvocationID = caller
            if !phase.isActive {
                run.handoffOutput = title
                run.finishedAt = .now
            }
            try fixture.home.saveSubagent(run)
            return (run, mailboxes[caller]!.appendingPathComponent("results/\(run.id.uuidString.lowercased()).result.json"))
        }
        let open = try record("WAITING", .completed, caller: waiting)
        let interrupted = try record("INTERRUPTED", .running, caller: waiting)
        let closed = try record("ENDED", .completed, caller: ended)
        let delivered = try record("DELIVERED", .completed, caller: answered)
        try Data("EARLIER".utf8).write(to: delivered.result)
        // A caller that ended more than a day ago: its mailbox is deleted, and nothing is written to it.
        let stale = try record("STALE", .completed, caller: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)],
                                              ofItemAtPath: mailboxes[old]!.appendingPathComponent("heartbeat.json").path)
        let restored = AppModel(store: fixture.store, settings: fixture.settings)
        defer { restored.stopAll() }
        await restored.storage.settle()
        try await fixture.wait {
            FileManager.default.fileExists(atPath: open.result.path) && FileManager.default.fileExists(atPath: interrupted.result.path)
        }
        #expect(try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: open.result)).handoffOutput == "WAITING")
        #expect(try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: interrupted.result)).phase == .stopped)
        #expect(!FileManager.default.fileExists(atPath: closed.result.path))
        #expect(try Data(contentsOf: delivered.result) == Data("EARLIER".utf8))
        #expect(!FileManager.default.fileExists(atPath: mailboxes[old]!.path))
        #expect(restored.delegation.run(stale.run.id)?.phase == .completed)
        #expect(restored.delegation.run(interrupted.run.id)?.phase == .stopped)
        #expect(restored.delegation.error == nil)
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
        let checkpoint = fixture.home.loadSubagentThread(id: run.id, taskID: fixture.target.taskID)
        #expect(checkpoint.count == 1)
        #expect(checkpoint.first?.id == app.delegation.threads[run.id]?.first?.id,
                "Admission and launch keep the same brief message")
        app.stopAll()
        let saved = fixture.home.loadSubagentThread(id: run.id, taskID: fixture.target.taskID)
        #expect(saved.filter { $0.role == .tool }.count == 101)
        #expect(saved.filter { $0.role == .user }.map(\.id) == checkpoint.map(\.id))
        #expect(Set(saved.map(\.id)).count == saved.count)
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

    /// The tab leads with runs under way and failures, and folds trees that ended without one into
    /// Finished at once, also while the tab shows them. The chat's Open shows a finished run's
    /// details directly, leaving Finished folded, and Back returns to the list as it was (#194).
    @Test func subagentsTabFoldsFinishedTreesAtOnceAndOpenShowsDetails() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let turn = UUID()
        func run(_ title: String, _ phase: SubagentPhase, turn: UUID = turn) -> SubagentRun {
            var run = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                  title: title, brief: "Report back on \(title.lowercased()).", workingDirectory: fixture.folder.path,
                                  callerInvocationID: turn, phase: phase)
            run.startedAt = .now.addingTimeInterval(-90)
            if !phase.isActive { run.finishedAt = .now }
            if phase == .completed { run.handoffOutput = "\(title): done." }
            if phase == .failed { run.errorMessage = "exit 1" }
            return run
        }
        var live = run("Build the app", .running)
        // An earlier turn's failure, under its caption.
        let failed = run("Audit the parser", .failed, turn: UUID())
        let finished = ["Check the docs", "Review the tests"].map { run($0, .completed) }
        let tab = SubagentTabState(target: fixture.target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        window.contentView = NSHostingView(rootView: SubagentsInspectorContent(target: fixture.target, state: tab)
            .environment(fixture.app).padding().frame(width: 340))
        func height(snapshot: String? = nil) async throws -> CGFloat {
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
        let running = try await height()
        // Finished runs add one folded heading, not a row each; the failure stays in view, one row.
        fixture.app.delegation.records[fixture.target] = [live, failed] + finished
        let withFinished = try await height(snapshot: "subagents-folded")
        #expect(withFinished > running + 30 && withFinished - running < 120)
        // A run that ends while the tab shows it moves into Finished at once.
        live.phase = .completed
        live.finishedAt = .now
        live.handoffOutput = "The app builds."
        fixture.app.delegation.records[fixture.target] = [live, failed] + finished
        let justFinished = try await height(snapshot: "subagents-just-finished")
        #expect(justFinished + 30 < withFinished)
        #expect(SubagentOverview(runs: fixture.app.delegation.records[fixture.target] ?? []).finishedCount == 3)
        #expect(tab.showsFinished[fixture.target] == nil)

        // The chat's Open on a finished run shows its details, handoff first, without opening Finished.
        SubagentFocus.shared.focus(finished[1].id)
        let details = try await height(snapshot: "subagents-details")
        #expect(tab.navigation.path == [.run(finished[1].id)])
        #expect(details > justFinished + 100)
        tab.back()
        #expect(abs(try await height() - justFinished) < 2)
        #expect(tab.navigation.path.isEmpty && tab.showsFinished[fixture.target] == nil)
        // Reading a failure doesn't resolve it: its row is still above Finished after Back.
        tab.push(.run(failed.id), opened: failed.id)
        try await Task.sleep(for: .milliseconds(150))
        tab.back()
        #expect(abs(try await height() - justFinished) < 2)
        #expect(SubagentOverview(runs: fixture.app.delegation.records[fixture.target] ?? []).visible.first?.roots.map(\.id) == [failed.id])
    }

    /// Back from a row's details returns to the list where it was; when the run ended meanwhile,
    /// Finished opens and the list scrolls only as far as it takes to show its row (#194).
    @Test func backReturnsToTheListWhereItWasAndRevealsAFinishedRun() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let turn = UUID()
        var runs = (0..<14).map { index in
            var run = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                  title: "Running \(index)", brief: "Keep going.", workingDirectory: fixture.folder.path,
                                  callerInvocationID: turn, phase: .running)
            run.startedAt = .now
            return run
        }
        fixture.app.delegation.records[fixture.target] = runs
        let defaults = UserDefaults(suiteName: fixture.domain)!
        defaults.set("subagents", forKey: InspectorTab.storageKey)
        let tab = SubagentTabState(target: fixture.target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InspectorPanel {
            EmptyView()
        } content: { _ in
            SubagentsInspectorContent(target: fixture.target, state: tab)
        } actions: {
            EmptyView()
        }.environment(fixture.app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content))
        func scrollTo(_ y: CGFloat) async throws {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(200))
        }
        func inView(_ id: UUID) -> Bool {
            guard let frame = tab.frames[.run(id)] else { return false }
            return frame.minY >= -1 && frame.maxY <= scroll.documentVisibleRect.height + 1
        }
        try await scrollTo(220)
        let place = scroll.documentVisibleRect.minY
        #expect(place > 200)
        let opened = try #require(runs.first { inView($0.id) && (tab.frames[.run($0.id)]?.minY ?? 0) > 60 })

        // Unchanged: the list comes back where it was, the opened row tinted.
        tab.push(.run(opened.id), opened: opened.id)
        try await Task.sleep(for: .milliseconds(300))
        // The details start at the top (the area's own 4 pt inset above them).
        #expect(scroll.documentVisibleRect.minY < 6)
        tab.back()
        try await Task.sleep(for: .milliseconds(400))
        #expect(abs(scroll.documentVisibleRect.minY - place) < 3)
        #expect(inView(opened.id) && tab.highlighted == opened.id)

        // Ended meanwhile: Finished opens, and its row comes into view.
        tab.push(.run(opened.id), opened: opened.id)
        try await Task.sleep(for: .milliseconds(300))
        let index = try #require(runs.firstIndex { $0.id == opened.id })
        runs[index].phase = .completed
        runs[index].finishedAt = .now
        runs[index].handoffOutput = "Done."
        fixture.app.delegation.records[fixture.target] = runs
        try await Task.sleep(for: .milliseconds(200))
        #expect(tab.navigation.path == [.run(opened.id)], "The details stay open as the run ends")
        tab.back()
        try await Task.sleep(for: .milliseconds(500))
        #expect(tab.showsFinished[fixture.target] == true)
        #expect(inView(opened.id))
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("subagents-back-revealed"))
        }
    }

    /// Rows stay readable at the tab's narrow widths: deep nesting, long activity words and timers
    /// past an hour fit without the tab growing wider, in light and dark (#194).
    @Test func subagentRowsFitNarrowWidths() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let turn = UUID()
        func run(_ title: String, _ phase: SubagentPhase, parent: SubagentRun? = nil, hours: Double = 0) -> SubagentRun {
            var run = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, parentSubagentID: parent?.id,
                                  depth: (parent?.depth ?? 0) + 1, targetBot: fixture.worker, title: title, brief: title,
                                  workingDirectory: fixture.folder.path, callerInvocationID: turn, phase: phase)
            run.startedAt = .now.addingTimeInterval(-hours * 3600 - 75)
            if !phase.isActive { run.finishedAt = .now }
            return run
        }
        let root = run("Solve the remote queue retries and the inspector width clamp in one batch", .running, hours: 1.2)
        let child = run("Profile retry backoff under load", .running, parent: root, hours: 1.1)
        let grandchild = run("URLSession retry guidance for Funnel, from Apple's documentation", .running, parent: child, hours: 1)
        let failed = run("Check thread export for secrets", .failed, parent: root)
        fixture.app.delegation.records[fixture.target] = [root, child, grandchild, failed]
        for id in [root.id, child.id, grandchild.id] {
            fixture.app.delegation.states[id] = RunState(hasOutput: true, activity: .browsing)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [240, 272, 320] as [CGFloat] {
                window.contentView = NSHostingView(rootView: SubagentsInspectorContent(target: fixture.target)
                    .environment(fixture.app).frame(width: width).background(Palette.sidebar))
                try await Task.sleep(for: .milliseconds(200))
                let size = try #require(window.contentView?.fittingSize)
                #expect(size.width <= width + 0.5, "\(width) pt")
                // Each row is at least 44 pt: its title two lines at most, then its state, whole.
                #expect(size.height > 4 * 44 && size.height < 4 * 90, "\(width) pt: \(size.height)")
                if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
                    window.setContentSize(size)
                    try await Task.sleep(for: .milliseconds(100))
                    DevHooks.snapshot(into: URL(fileURLWithPath: path)
                        .appendingPathComponent("subagents-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light")"))
                }
            }
        }
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

/// Blocks a storage lane, never the main actor, until the test releases durable admission.
private final class MailboxStorageGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false
    private var released = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return blocked }
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        blocked = true
        while !released { condition.wait() }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
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

    init(remote: Bool = false, storage: StorageQueue = .shared) throws {
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
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") }, storage: storage)
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
    with open(os.path.join(os.path.dirname(__file__), "session-prompts.txt"), "a") as output:
        output.write(prompt + "\n")
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if depth:
        assert "WORKER-SOUL" in prompt
        brief = re.search(r"<handoff_brief>\s*(.*?)\s*</handoff_brief>", prompt, re.S).group(1)
    else:
        brief = prompt.splitlines()[-1]
    if brief == "POLICY_CHECK":
        try:
            result = subprocess.run([os.path.join(os.path.dirname(__file__), "gh")], capture_output=True)
            answer = "TOOL-BLOCKED" if result.returncode else "UNBLOCKED"
        except OSError:
            answer = "TOOL-BLOCKED"
    elif brief == "REMOTE_WORKSPACES":
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

/// Holds only a storage worker, never MainActor. Shared by the session-preparation runtime tests.
final class SessionPreparationTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var started: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }
    func wait() {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(20)
        while !released && condition.wait(until: deadline) {}
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
    func reset() {
        condition.lock()
        entered = false
        released = false
        condition.unlock()
    }
}
