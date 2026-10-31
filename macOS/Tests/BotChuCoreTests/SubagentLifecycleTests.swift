import Foundation
import Testing
@testable import BotChuCore

@Suite @MainActor struct SubagentLifecycleTests {
    private func tree(host: UUID? = nil) -> [SubagentRun] {
        let bot = Bot(name: "Worker", workspace: "/worker")
        let parent = SubagentRun(rootBotID: bot.id, depth: 1, targetBot: bot, title: "Parent", brief: "Work",
                                 workingDirectory: "/repo/parent", hostID: host, phase: .running)
        let child = SubagentRun(rootBotID: bot.id, parentSubagentID: parent.id, depth: 2, targetBot: bot,
                                title: "Child", brief: "Work", workingDirectory: "/repo/child", hostID: host, phase: .preparing)
        let nested = SubagentRun(rootBotID: bot.id, parentSubagentID: child.id, depth: 3, targetBot: bot,
                                 title: "Nested", brief: "Work", workingDirectory: "/repo/nested", hostID: host, phase: .running)
        return [parent, child, nested]
    }

    private func stop(_ initial: [SubagentRun]) -> [SubagentArchive.Snapshot] {
        var records = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })
        var causes: [UUID: SubagentInterruption.Cause] = [:]
        var snapshots: [SubagentArchive.Snapshot] = []
        SubagentStopTree.stopRoot(initial) { id, cause in
            SubagentStopTree.stop(id, cause: cause, recordCause: { id, cause in
                if records[id]?.phase.isActive == true && causes[id] == nil { causes[id] = cause }
            }, exiting: { _ in false }, children: { id in
                initial.filter { $0.parentSubagentID == id && records[$0.id]?.phase.isActive == true }.map(\.id)
            }, stopRun: { id in
                guard var record = records[id], record.phase.isActive else { return }
                record.phase = .stopped
                record.errorMessage = "Stopped"
                var messages = [ChatMessage(role: .assistant, text: "Work so far")]
                SubagentTerminalOutcome.apply(to: &record, messages: &messages, toolCalls: 2, cause: causes[id],
                                               workspace: .init(branch: "work", uncommitted: ["src.swift"]))
                records[id] = record
                snapshots.append(.init(record: record, messages: messages, home: BotHome(workspace: "/unused")))
            })
        }
        return snapshots
    }

    // Replaces stoppingAParentStopsNestedRunsAndLeavesNoActiveChildren (#391).
    @Test func stoppingTreeFinishesChildrenFirstWithEachCauseAndWorkspace() {
        let initial = tree(), snapshots = stop(initial)
        #expect(snapshots.map(\.record.id) == initial.reversed().map(\.id))
        #expect(snapshots.allSatisfy { $0.record.phase == .stopped })
        for snapshot in snapshots {
            let record = snapshot.record
            #expect(record.interruption?.cause == (record.parentSubagentID == nil ? .owner : .parentStopped))
            #expect(snapshot.messages.last?.role == .note)
            #expect(snapshot.messages.last?.text == record.errorMessage)
            #expect(record.errorMessage?.contains(record.workingDirectory) == true)
            #expect(record.errorMessage?.contains("src.swift") == true)
            #expect(record.errorMessage != "Stopped")
        }
    }

    // Replaces stoppingAnSSHParentStopsItsNestedWorkersAndSavesTheirTerminalState (#391).
    @Test func hostTreePersistsEveryTerminalRecordAndTranscript() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = BotHome(workspace: folder.path), host = UUID(), archive = SubagentArchive()
        let initial = tree(host: host)
        for var snapshot in stop(initial) {
            snapshot.home = home
            try await archive.save(snapshot)
        }
        let saved = home.loadSubagents()
        #expect(Set(saved.map(\.id)) == Set(initial.map(\.id)))
        #expect(saved.allSatisfy { $0.phase == .stopped && $0.hostID == host })
        for record in saved {
            #expect(record.interruption?.cause == (record.parentSubagentID == nil ? .owner : .parentStopped))
            #expect(home.loadSubagentThread(id: record.id).last?.text == record.errorMessage)
        }
    }

    @Test func exitingRunRecordsCauseButWaitsForItsWorkspaceBeforeStoppingChildren() {
        let initial = tree()
        var recorded: [UUID] = [], stopped: [UUID] = []
        SubagentStopTree.stop(initial[0].id, recordCause: { id, _ in recorded.append(id) }, exiting: { _ in true },
                             children: { _ in initial.dropFirst().map(\.id) }, stopRun: { stopped.append($0) })
        #expect(recorded == [initial[0].id] && stopped.isEmpty)
    }

    @Test func completedAndSaveFailedRunsKeepTheirExistingOutcomeRules() {
        var record = tree()[0], messages: [ChatMessage] = []
        record.phase = .completed
        record.interruption = .init(cause: .owner)
        SubagentTerminalOutcome.apply(to: &record, messages: &messages, toolCalls: 0, cause: nil, workspace: nil)
        #expect(record.interruption == nil && messages.isEmpty)
        record.phase = .failed
        record.startedAt = Date()
        record.errorMessage = "Couldn't save the sub-agent transcript: disk full"
        SubagentTerminalOutcome.apply(to: &record, messages: &messages, toolCalls: 0, cause: .owner, workspace: nil)
        #expect(record.interruption == nil && messages.last?.role == .error)
        #expect(messages.last?.text == record.errorMessage)
    }
}

@Suite @MainActor struct SubagentResumeTransactionTests {
    @MainActor private final class Fixture {
        var current: SubagentRun?
        var events: [String] = []
        var processes: Result<[Int32], SubagentLiveness.Problem> = .success([])
        var finalizing = false, running = false, preparing = false, callerAlive = true
        var failLoad = false, failSave = false
        var afterLoad: (() -> Void)?, afterSave: (() -> Void)?
        var checkedIDs: [UUID] = []
        let descendant = UUID()
        var saved: SubagentArchive.Snapshot?
        var history: [ChatMessage] = []
        let home: BotHome
        init(home: BotHome = BotHome(workspace: "/unused")) {
            self.home = home
            let bot = Bot(name: "Worker", workspace: "/worker")
            current = SubagentRun(rootBotID: bot.id, depth: 1, targetBot: bot, title: "Work", brief: "Work", workingDirectory: "/repo", phase: .stopped)
        }
        func run(persist: Bool = false) async -> String? {
            let id = current!.id
            return await SubagentResumeTransaction.run(ids: [id, descendant], place: "worker-host", processes: { ids in
                self.events.append("liveness"); self.checkedIDs = ids
                return self.processes
            }, workspace: {
                self.events.append("workspace")
                return .init(branch: "work")
            }, load: {
                self.events.append("load")
                if self.failLoad { throw CocoaError(.fileReadCorruptFile) }
                if persist { self.history = try self.home.loadSubagentHistory(id: id).messages }
                self.afterLoad?()
            }, validate: { stage in
                self.events.append(stage == .loaded ? "validate-loaded" : "validate-saved")
                return SubagentResumeTransaction.problem(current: self.current, finalizing: stage == .loaded && self.finalizing,
                    running: self.running, preparing: self.preparing, callerAlive: self.callerAlive)
            }, prepare: { workspace in
                self.events.append("snapshot")
                var resumed = self.current!
                resumed.phase = .preparing
                let delta = SubagentResume.delta(for: resumed, workspace: workspace, interruptedChildren: [], session: false)
                return SubagentArchive.Snapshot(record: resumed, messages: self.history + [.init(role: .user, text: delta)], home: self.home)
            }, save: { snapshot in
                self.events.append("save")
                #expect(self.current?.phase == .stopped)
                if self.failSave { throw CocoaError(.fileWriteOutOfSpace) }
                if persist { try await SubagentArchive().save(snapshot) }
                self.saved = snapshot
                self.afterSave?()
            }, replace: { snapshot in
                self.events.append("replace")
                #expect(self.saved?.record.id == snapshot.record.id)
                self.current = snapshot.record
            })
        }
    }

    // Replaces resumingARestartCutRunContinuesItsSessionInItsWorktree (#391).
    @Test func resumeChecksDescendantsLoadsAndSavesBeforeReplacing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let f = Fixture(home: BotHome(workspace: folder.path)), id = f.current!.id
        let original = ChatMessage(role: .assistant, text: "Earlier work")
        try await SubagentArchive().save(.init(record: f.current!, messages: [original], home: f.home))
        #expect(await f.run(persist: true) == nil)
        #expect(f.checkedIDs == [id, f.descendant])
        #expect(f.events == ["liveness", "workspace", "load", "validate-loaded", "snapshot", "save", "validate-saved", "replace"])
        #expect(f.current?.phase == .preparing)
        #expect(f.home.loadSubagents().first?.phase == .preparing)
        #expect(f.home.loadSubagentThread(id: id).first?.id == original.id)
        #expect(f.home.loadSubagentThread(id: id).last?.text.contains("work") == true)
    }

    // Replaces resumeWaitsForAStillRunningCLIAndFallsBackToANewSession's liveness guard (#391).
    @Test func liveOrUncheckableDescendantNeverLoadsOrSaves() async {
        let live = Fixture()
        live.processes = .success([42])
        #expect(await live.run()?.contains("worker-host (pid 42)") == true)
        #expect(live.events == ["liveness"] && live.saved == nil)
        let unknown = Fixture()
        unknown.processes = .failure(.init(message: "Host unavailable."))
        #expect(await unknown.run() == "Host unavailable. Resume it again once it can be checked.")
        #expect(unknown.events == ["liveness"])
    }

    @Test func loadAndSaveFailuresNeverReplace() async {
        let load = Fixture(); load.failLoad = true
        #expect(await load.run()?.hasPrefix("Couldn't read its transcript:") == true)
        #expect(load.events == ["liveness", "workspace", "load"])
        let save = Fixture(); save.failSave = true
        #expect(await save.run()?.hasPrefix("Couldn't save it:") == true)
        #expect(!save.events.contains("replace") && save.current?.phase == .stopped)
    }

    @Test func everyStaleRunGuardIsRecheckedAfterLoadAndSave() async {
        for stage in [SubagentResumeTransaction.Stage.loaded, .saved] {
            for mutation in 0..<5 {
                let f = Fixture()
                let change: () -> Void = { [unowned f] in
                    switch mutation {
                    case 0: f.current = nil
                    case 1: f.current?.phase = .completed
                    case 2: f.running = true
                    case 3: f.preparing = true
                    default: f.callerAlive = false
                    }
                }
                if stage == .loaded { f.afterLoad = change } else { f.afterSave = change }
                #expect(await f.run() == (mutation == 4 ? "The asking turn has ended." : "It changed while it was being resumed."))
                #expect(!f.events.contains("replace"))
                #expect(f.saved == nil || stage == .saved)
            }
        }
        let f = Fixture(); f.afterLoad = { [unowned f] in f.finalizing = true }
        #expect(await f.run() == "It changed while it was being resumed.")
        #expect(f.saved == nil)
    }
}
