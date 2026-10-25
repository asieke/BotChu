import Foundation
import Observation
import BotChuCore

/// Owns the short-lived delegation sessions. The selected conversation never owns a process:
/// requests are bound to the invocation that created them, even while the owner navigates away.
///
/// Each conversation's runs (`records[target]`) and each run's transcript and turn
/// (`threads[id]`, `states[id]`) are observed on their own, so a sub-agent streaming redraws only
/// the views that show it. Transcripts are saved off the main thread while they stream
/// (`SubagentArchive`); a run's start and end are saved at once.
@MainActor @Observable
final class SubagentRuntime {
    var error: String?
    /// Bots with a run under way, as the bot of its root conversation or as the bot it calls.
    /// Reassigned only when that changes, as runs start and end.
    private(set) var busyBots: Set<UUID> = []
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let root: URL
    @ObservationIgnored let namespace: UUID
    @ObservationIgnored let archive: SubagentArchive
    @ObservationIgnored fileprivate var roots: [ChatTarget: SubagentRoot] = [:]
    @ObservationIgnored fileprivate var lives: [UUID: SubagentLive] = [:]
    /// Each run's root conversation, so finding a run doesn't search every conversation's.
    @ObservationIgnored private var locations: [UUID: ChatTarget] = [:]
    @ObservationIgnored private var contexts: [UUID: Caller] = [:]
    @ObservationIgnored private var runners: [UUID: AgentRun] = [:]
    @ObservationIgnored private var preparations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var deliveries: [UUID: SubagentTransport] = [:]
    @ObservationIgnored private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rejections: [UUID: [UUID: SubagentResult]] = [:]
    /// What each Task request (`botchu-task create`) has come to so far, by request (#111).
    @ObservationIgnored private var handoffs: [UUID: TaskHandoffResult] = [:]
    @ObservationIgnored private var pendingFinishes: [UUID: (SubagentPhase, String?)] = [:]
    @ObservationIgnored private var requestCounts: [ChatTarget: Int] = [:]
    /// Runs whose end is being saved: still active until it is, so their caller waits for them.
    @ObservationIgnored private var finalizing: Set<UUID> = []
    /// Runs found unfinished after a relaunch, which are closed (once their transcript is read, off
    /// the main thread) and aren't reviewed, and those whose transcript is still being read.
    @ObservationIgnored private var restored: Set<UUID> = []
    @ObservationIgnored private var reading: Set<UUID> = []
    /// Finished runs' transcripts are read when shown (#109), and at most this many bytes of those
    /// not in the conversation shown stay in memory, the least recently read going first.
    nonisolated static let finishedThreadBytes = 16 << 20
    @ObservationIgnored private var budget = HistoryBudget<UUID>(limit: SubagentRuntime.finishedThreadBytes)

    /// How often a caller's mailbox is looked at, on this Mac and on a host.
    nonisolated static let localPoll: Duration = .milliseconds(250)
    nonisolated static let remotePoll: Duration = .milliseconds(750)
    /// How often its heartbeat is refreshed: well within `SubagentLimits.heartbeatTimeout`.
    nonisolated static let heartbeatInterval: TimeInterval = 2

    struct Caller {
        var id: UUID
        var target: ChatTarget
        var parent: UUID?
        var depth: Int
        var directory: String
        var hostID: UUID?
        var transport: SubagentTransport
        var environment: [String: String] = [:]
    }

    init(model: AppModel, root: URL, archive: SubagentArchive = SubagentArchive()) {
        self.model = model
        self.root = root
        self.archive = archive
        let namespaceURL = root.appendingPathComponent("namespace")
        namespace = (try? String(contentsOf: namespaceURL, encoding: .utf8)).flatMap(UUID.init(uuidString:)) ?? UUID()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try namespace.uuidString.write(to: namespaceURL, atomically: true, encoding: .utf8)
            _ = try SubagentHookInstaller.install(binDirectory: root == SubagentIPC.defaultRoot ? SubagentIPC.defaultBinDirectory : root.appendingPathComponent("bin"))
            try refreshRoster()
        } catch { self.error = "Couldn't prepare sub-agents: \(error.localizedDescription)" }
        restore()
    }

    /// Each conversation's runs, oldest first: `records[target]`, read and written like the
    /// dictionary it replaces. Reading one conversation's observes that conversation's alone.
    var records: SubagentRecords { SubagentRecords(runtime: self) }
    /// Each run's transcript, by run.
    var threads: SubagentThreads { SubagentThreads(runtime: self) }
    /// Each run's turn while it runs, by run.
    var states: SubagentStates { SubagentStates(runtime: self) }

    var roster: [BotRosterEntry] { (model?.bots ?? []).map { BotRosterEntry(bot: $0) } }
    /// Every conversation's runs. For the runtime's own work and tests: a view reads one
    /// conversation's (`records[target]`), which observes only that conversation.
    var all: [SubagentRun] { roots.values.flatMap(\.runs) }
    func run(_ id: UUID) -> SubagentRun? {
        locations[id].flatMap { target in root(target).runs.first { $0.id == id } }
    }
    func activeCount(_ target: ChatTarget, includeTasks: Bool = false) -> Int {
        let targets = includeTasks
            ? [ChatTarget.home(target.botID)] + (model?.tasks[target.botID] ?? []).map { .task($0.id, of: target.botID) }
            : [target]
        return targets.reduce(0) { count, target in count + root(target).runs.filter { $0.phase.isActive }.count }
    }
    func usesBot(_ id: UUID) -> Bool { busyBots.contains(id) }

    /// The runs a run delegated to, grouped once per change of its conversation's runs.
    func children(of id: UUID) -> [SubagentRun] {
        locations[id].map { root($0).children(of: id) } ?? []
    }

    /// In one conversation, the runs a run delegated to, or (for nil) the conversation's own.
    func children(of parent: UUID?, in target: ChatTarget) -> [SubagentRun] {
        root(target).children(of: parent)
    }

    fileprivate func root(_ target: ChatTarget) -> SubagentRoot {
        if let existing = roots[target] { return existing }
        let made = SubagentRoot()
        roots[target] = made
        return made
    }

    fileprivate func live(_ id: UUID) -> SubagentLive {
        if let existing = lives[id] { return existing }
        let made = SubagentLive()
        lives[id] = made
        return made
    }

    fileprivate func dropLive(_ id: UUID) {
        lives[id] = nil
    }

    /// Replaces a conversation's runs, and the index of where each run is.
    fileprivate func setRuns(_ runs: [SubagentRun], for target: ChatTarget) {
        let root = root(target)
        for run in root.runs where locations[run.id] == target { locations[run.id] = nil }
        root.runs = runs
        for run in runs { locations[run.id] = target }
        refreshBusyBots()
    }

    private func add(_ record: SubagentRun, to target: ChatTarget) {
        root(target).runs.append(record)
        locations[record.id] = target
        refreshBusyBots()
    }

    private func refreshBusyBots() {
        var busy: Set<UUID> = []
        for root in roots.values {
            for run in root.runs where run.phase.isActive {
                busy.insert(run.rootBotID)
                busy.insert(run.targetBotID)
            }
        }
        if busy != busyBots { busyBots = busy }
    }

    /// Runs under way, and requests admitted whose record is still being saved, so the limits
    /// count them while that save is awaited.
    private var activeRunCount: Int { admitting + roots.values.reduce(0) { $0 + $1.runs.filter { $0.phase.isActive }.count } }
    @ObservationIgnored private var admitting = 0

    func refreshRoster() throws {
        let ipc = SubagentIPC(root: root)
        try ipc.prepare()
        try ipc.writeRoster(roster)
        let data = try SubagentIPC.encode(roster)
        for caller in contexts.values {
            Task { try? await caller.transport.writeRoster(data: data) }
        }
    }

    func prepareCaller(target: ChatTarget, parent: UUID? = nil, directory: String,
                       machine: Machine, hostID: UUID?) async throws -> Caller {
        let id = UUID()
        let depth = parent.flatMap { run($0)?.depth } ?? 0
        let transport = SubagentTransport(machine: machine, namespace: namespace, invocationID: id, localRoot: root)
        var caller = Caller(id: id, target: target, parent: parent, depth: depth,
                            directory: directory, hostID: hostID, transport: transport)
        contexts[id] = caller
        if parent == nil { requestCounts[target] = 0 }
        do {
            let endpoint = try await transport.prepare(script: SubagentHookInstaller.script,
                                                        roster: SubagentIPC.encode(roster))
            guard contexts[id] != nil, !Task.isCancelled else {
                try? await transport.close()
                throw CancellationError()
            }
            caller.environment = [
                "BOTCHU_INVOCATION_ID": id.uuidString,
                "BOTCHU_CALLER_BOT_ID": target.botID.uuidString,
                "BOTCHU_CALLER_TASK_ID": target.taskID?.uuidString ?? "",
                "BOTCHU_CALLER_SUBAGENT_ID": parent?.uuidString ?? "",
                "BOTCHU_CALLER_DEPTH": String(depth),
                "BOTCHU_IPC_DIR": endpoint.ipcDirectory,
                "BOTCHU_BIN_DIR": endpoint.binDirectory,
            ]
            contexts[id] = caller
            startWatcher(caller)
            return caller
        } catch {
            contexts[id] = nil
            throw error
        }
    }

    /// Watches a caller's mailbox off the main actor: its files, or the SSH commands that reach
    /// them on a host, are read and written there, and only the requests it holds come here. The
    /// heartbeat is refreshed every `heartbeatInterval` (with the poll, on a host), and a run's
    /// status file is written only when its phase or activity changes.
    private func startWatcher(_ caller: Caller) {
        let id = caller.id
        let transport = caller.transport
        let pause = transport.machine.isRemote ? Self.remotePoll : Self.localPoll
        let heartbeatInterval = Self.heartbeatInterval
        watchers[id] = Task.detached(priority: .utility) { [weak self] in
            var lastHeartbeat: Date?
            var written: [UUID: SubagentStatus] = [:]
            while !Task.isCancelled {
                do {
                    let beat = lastHeartbeat.map { Date().timeIntervalSince($0) >= heartbeatInterval } ?? true
                    let envelopes = try await transport.poll(heartbeat: beat)
                    if beat { lastHeartbeat = Date() }
                    guard let self, !Task.isCancelled, let statuses = await self.take(envelopes, from: id) else { break }
                    for status in statuses {
                        if let last = written[status.id], last.phase == status.phase, last.activity == status.activity { continue }
                        try await transport.writeStatus(id: status.id, data: SubagentIPC.encode(status))
                        written[status.id] = status
                    }
                } catch {
                    guard let self, !Task.isCancelled, await self.isWatching(id) else { break }
                    await self.report("Sub-agent connection: \(error.localizedDescription)")
                }
                do { try await Task.sleep(for: pause) } catch { break }
            }
        }
    }

    /// Takes a caller's requests, then returns its runs' statuses; nil once the caller has ended.
    private func take(_ envelopes: [SubagentEnvelope], from id: UUID) async -> [SubagentStatus]? {
        guard let caller = contexts[id] else { return nil }
        for envelope in envelopes {
            await receive(envelope.data, filename: envelope.filename, from: caller)
        }
        guard contexts[id] != nil else { return nil }
        return root(caller.target).runs.filter { $0.callerInvocationID == id && $0.phase.isActive }.map { record in
            SubagentStatus(id: record.id, phase: record.phase, activity: lives[record.id]?.state?.activity.doing ?? "Preparing…")
        }
    }

    private func isWatching(_ id: UUID) -> Bool { contexts[id] != nil }

    private func report(_ message: String) {
        if error != message { error = message }
    }

    private func receive(_ data: Data, filename: String, from caller: Caller) async {
        // A file is acknowledged only after its admission or failure has been persisted.
        guard let fileID = UUID(uuidString: String(filename.dropLast(5))) else {
            try? await caller.transport.acknowledge(filename: filename)
            return
        }
        // A Task for a bot, not a run of this turn's (#111).
        if TaskHandoff.isHandoff(data) {
            await receiveHandoff(data, id: fileID, filename: filename, from: caller)
            return
        }
        if let rejected = rejections[caller.id]?[fileID] {
            do {
                try await caller.transport.writeResult(id: fileID, data: SubagentIPC.encode(rejected))
                try await caller.transport.acknowledge(filename: filename)
            } catch { self.error = "Couldn't acknowledge a rejected request: \(error.localizedDescription)" }
            return
        }
        do {
            let request = try SubagentIPC.decode(SubagentRequest.self, from: data)
            guard request.id == fileID, request.invocationID == caller.id,
                  contexts[caller.id] != nil else { throw DelegationFailure("This calling turn has ended or the request has the wrong invocation.") }
            try SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID, taskID: caller.target.taskID,
                parentSubagentID: caller.parent, depth: caller.depth, workingDirectory: caller.directory, hostID: caller.hostID).validate(request,
                    now: caller.transport.machine.isRemote ? request.createdAt : Date())
            if let existing = run(request.id) {
                guard existing.callerInvocationID == caller.id else { throw DelegationFailure("This request ID belongs to a different invocation.") }
                if !existing.phase.isActive {
                    deliveries[existing.id] = caller.transport
                    queueDelivery(existing)
                }
                do { try await caller.transport.acknowledge(filename: filename) }
                catch { self.error = "Couldn't acknowledge a sub-agent request: \(error.localizedDescription)" }
                return
            }
            guard caller.depth < SubagentLimits.maxDepth else { throw DelegationFailure("Maximum sub-agent depth reached.") }
            guard activeRunCount < 12 else { throw DelegationFailure("Twelve sub-agents are already running. Wait for one to finish before trying again.") }
            guard requestCounts[caller.target, default: 0] < 64 else { throw DelegationFailure("This turn has reached its limit of 64 delegations.") }
            guard !request.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.brief.utf8.count <= 128_000 else {
                throw DelegationFailure("Provide a nonempty brief smaller than 128 KB.")
            }
            guard let model else { throw DelegationFailure("BotChu is shutting down.") }
            let targetBot = try SubagentResolver.resolve(request.targetAgent, bots: model.bots)
            let mode = request.workspaceMode ?? .sharedCallerWorkspace
            let hostID = mode == .sharedCallerWorkspace ? caller.hostID : nil
            let directory = mode == .sharedCallerWorkspace ? caller.directory : targetBot.workspace
            var record = SubagentRun(id: request.id, rootBotID: caller.target.botID, rootTaskID: caller.target.taskID,
                                     parentSubagentID: caller.parent, depth: caller.depth + 1, targetBot: targetBot,
                                     title: String((request.title ?? request.brief).prefix(100)), brief: request.brief,
                                     workspaceMode: mode, workingDirectory: directory, hostID: hostID, phase: .preparing)
            record.callerInvocationID = caller.id
            record.callerHostID = caller.hostID
            // Admitted once its record is saved, off the main thread; the limits count it meanwhile.
            admitting += 1
            requestCounts[caller.target, default: 0] += 1
            do {
                try await archive.save(snapshot(record, messages: [ChatMessage(role: .user, text: request.brief)]))
                admitting -= 1
            } catch {
                admitting -= 1
                requestCounts[caller.target, default: 1] -= 1
                throw error
            }
            add(record, to: caller.target)
            live(record.id).messages = [ChatMessage(role: .user, text: request.brief)]
            live(record.id).state = RunState(preparing: true)
            deliveries[record.id] = caller.transport
            guard contexts[caller.id] != nil else { stop(record.id); return }
            preparations[record.id] = Task { [weak self] in await self?.launch(record.id, targetBot: targetBot, caller: caller) }
            // Admission is durable. A failed acknowledgement must not strand a preparing run;
            // the next poll recognizes its ID and retries the acknowledgement.
            do { try await caller.transport.acknowledge(filename: filename) }
            catch { self.error = "Couldn't acknowledge a sub-agent request: \(error.localizedDescription)" }
        } catch {
            let failed = SubagentResult(id: fileID, targetBotName: "Sub-agent", phase: .failed, errorMessage: error.localizedDescription)
            rejections[caller.id, default: [:]][fileID] = failed
            do {
                try await caller.transport.writeResult(id: fileID, data: SubagentIPC.encode(failed))
                try await caller.transport.acknowledge(filename: filename)
            } catch { self.error = "Couldn't deliver a sub-agent failure: \(error.localizedDescription)" }
        }
    }

    // MARK: Tasks handed to bots (#111)

    /// Takes a `botchu-task create` request: answers it at once (pending, or why not), then makes
    /// the Task outside the watcher's loop, so the caller's mailbox and heartbeat go on meanwhile, and
    /// writes how that went, then how the Task's first turn started, into the caller's mailbox. The
    /// Task goes on whatever becomes of the caller. A request seen again gets the same answer.
    private func receiveHandoff(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        if let known = handoffs[id] {
            await deliver(known, to: caller)
            try? await caller.transport.acknowledge(filename: filename)
            return
        }
        var result = TaskHandoffResult(id: id, phase: .pending)
        var accepted: TaskHandoff?
        do {
            let handoff = try TaskHandoff.parse(data)
            guard handoff.id == id else { throw TaskRequest.Problem(message: "the request's ID doesn't match its file") }
            try handoff.validate(SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID, taskID: caller.target.taskID,
                                                       parentSubagentID: caller.parent, depth: caller.depth,
                                                       workingDirectory: caller.directory, hostID: caller.hostID))
            guard contexts[caller.id] != nil else { throw TaskRequest.Problem(message: "the calling turn has ended") }
            guard requestCounts[caller.target, default: 0] < 64 else {
                throw TaskRequest.Problem(message: "this turn has reached its limit of 64 delegations")
            }
            requestCounts[caller.target, default: 0] += 1
            accepted = handoff
        } catch {
            result.phase = .failed
            result.errorMessage = Self.reason(error)
        }
        handoffs[id] = result
        await deliver(result, to: caller)
        try? await caller.transport.acknowledge(filename: filename)
        guard let handoff = accepted else { return }
        Task { [weak self] in await self?.handOff(handoff, from: caller) }
    }

    private func handOff(_ handoff: TaskHandoff, from caller: Caller) async {
        guard let model else { return }
        var result = TaskHandoffResult(id: handoff.id, phase: .failed)
        do {
            let made = try await model.handOffTask(handoff, from: caller.target, subagent: caller.parent.flatMap { run($0) })
            result = TaskHandoffResult(id: handoff.id, phase: made.unsaved == nil ? .created : .failed, targetBotID: made.bot.id,
                                       targetBotName: made.bot.name, taskID: made.task.id, taskTitle: made.task.title,
                                       existing: made.existing, errorMessage: made.unsaved)
        } catch {
            result.errorMessage = Self.reason(error)
        }
        handoffs[handoff.id] = result
        await deliver(result, to: caller)
        guard result.phase == .created, let taskID = result.taskID, let botID = result.targetBotID else { return }
        model.whenTaskStarts(.task(taskID, of: botID)) { [weak self] failure in
            guard let self, let created = self.handoffs[handoff.id] else { return }
            let started = created.starting(failure: failure)
            self.handoffs[handoff.id] = started
            Task { await self.deliver(started, to: caller) }
        }
    }

    /// Writes a Task request's answer; after the caller's turn has ended, quietly, as nothing waits.
    private func deliver(_ result: TaskHandoffResult, to caller: Caller) async {
        do { try await caller.transport.writeResult(id: result.id, data: SubagentIPC.encode(result)) }
        catch { if isWatching(caller.id) { report("Couldn't answer a task request: \(error.localizedDescription)") } }
    }

    private static func reason(_ error: Error) -> String {
        (error as? TaskRequest.Problem)?.message ?? error.localizedDescription
    }

    private func launch(_ id: UUID, targetBot: Bot, caller: Caller) async {
        guard var record = run(id), record.phase.isActive, let model else { return }
        do {
            let machine: Machine
            if let hostID = record.hostID {
                guard let host = model.settings.host(hostID) else { throw DelegationFailure("The sub-agent's host is no longer configured.") }
                machine = Machine(destination: host.destination)
            } else { machine = .thisMac }
            let target = ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID)
            let context = try await prepareCaller(target: target, parent: id, directory: record.workingDirectory,
                                                 machine: machine, hostID: record.hostID)
            guard run(id)?.phase.isActive == true, !Task.isCancelled else { endCaller(context.id); return }
            let account = record.account
            let key = account.kind == .pi && !machine.isRemote ? Keychain.get(Keychain.openRouterAccount) : nil
            if account.kind == .pi && !machine.isRemote && (key?.isEmpty ?? true) {
                throw DelegationFailure("Add your OpenRouter API key in BotChu Settings first.")
            }
            let prompt = BotContext.subagentPreamble(bot: targetBot, run: record,
                callerDescription: caller.parent.flatMap { run($0)?.targetBotName } ?? model.bot(target.botID)?.name ?? "Bot",
                memory: Workspace.read(targetBot.workspace + "/MEMORY.md"), sharedMemory: Workspace.read(model.settings.sharedMemoryPath),
                soul: Workspace.read(targetBot.workspace + "/SOUL.md"),
                instructions: Workspace.read(BotDocument.instructions.url(for: targetBot).path),
                team: Workspace.read(model.settings.teamPath), availableBots: roster, skills: model.activeSkills(of: targetBot))
            var invocation = CommandBuilder.invocation(kind: account.kind, prompt: prompt,
                model: GenerationOptions.effectiveModel(record.model, kind: account.kind, openRouterDefault: model.settings.openRouterModel),
                sessionID: nil, reasoningEffort: record.reasoningEffort, openRouterKey: key)
            invocation.environment.merge(context.environment) { _, new in new }
            let command = model.settings.host(record.hostID)?.command(for: account) ?? model.settings.command(for: account)
            let runner = machine.isRemote
                ? AgentRun(command: command, invocation: invocation, on: machine, folder: record.workingDirectory)
                : AgentRun(command: command, invocation: invocation, directory: URL(fileURLWithPath: record.workingDirectory))
            var assembler = ThreadAssembler()
            var finished = false
            var failure: String?
            var persistenceFailure: String?
            // Parsed off the main thread, in batches; the transcript is checkpointed off it too.
            runner.deliverEvents(parsedBy: StreamParsers.make(for: account.kind)) { [weak self, weak runner] events in
                guard let self, let runner, self.runners[id] === runner, self.run(id)?.phase.isActive == true else { return }
                let live = self.live(id)
                var state = live.state
                state?.hasOutput = true
                guard !events.isEmpty else {
                    if state != live.state { live.state = state }
                    return
                }
                var sessions: [String] = []
                var reported: String?
                live.update { messages in
                    for event in events {
                        switch event {
                        case .session(let session):
                            sessions.append(CommandBuilder.resumeID(kind: account.kind, invocation: invocation, reported: session))
                        case .model(let id): reported = id
                        case .finished: finished = true
                        case .failed(let reason): failure = reason
                        default: break
                        }
                        if let activity = BotActivity.next(after: event) { _ = state?.move(to: activity) }
                        state?.settle()
                        assembler.apply(event, to: &messages)
                    }
                }
                if state != live.state { live.state = state }
                for session in sessions { self.modify(id) { $0.sessionID = session } }
                if let reported, self.run(id)?.resolvedModel != reported {
                    self.modify(id) { $0.recordReportedModel(reported, requested: $0.model) }
                }
                guard let record = self.run(id) else { return }
                let failed: @MainActor (Error) -> Void = { [weak self] error in
                    guard let self, persistenceFailure == nil, self.run(id)?.phase.isActive == true else { return }
                    persistenceFailure = "Couldn't save the sub-agent transcript: \(error.localizedDescription)"
                    self.stop(id)
                }
                do {
                    self.archive.checkpoint(try self.snapshot(record, messages: live.messages), failed: failed)
                } catch {
                    failed(error)
                }
            }
            runner.onExit = { [weak self, weak runner] status, stderr in
                guard let self, let runner, self.runners[id] === runner else { return }
                self.runners[id] = nil
                self.endCaller(context.id)
                guard self.run(id)?.phase.isActive == true else { return }
                let live = self.live(id)
                live.update { messages in
                    assembler.apply(.textEnd, to: &messages)
                    ThreadAssembler.closeRunningTools(&messages)
                }
                let reply = live.messages.last(where: { $0.role == .assistant })?.text ?? ""
                let reason = persistenceFailure ?? failure ?? ((status != 0 || !finished || reply.isEmpty)
                    ? "\(account.name) ended without a successful handoff (exit \(status)). \(AppModel.lastLines(stderr))" : nil)
                self.finish(id, phase: persistenceFailure != nil ? .failed : runner.stopped ? .stopped : reason == nil ? .completed : .failed, error: reason)
            }
            record.phase = .running
            record.startedAt = Date()
            try await archive.save(snapshot(record, messages: live(id).messages))
            // Stopped while its start was being saved: its end is saved instead.
            guard run(id)?.phase.isActive == true, !finalizing.contains(id), !Task.isCancelled else { endCaller(context.id); return }
            replace(record)
            runners[id] = runner
            live(id).state = RunState()
            try runner.start()
            preparations[id] = nil
        } catch {
            for context in Array(contexts.values) where context.parent == id { endCaller(context.id) }
            runners[id] = nil
            finish(id, phase: error is CancellationError ? .stopped : .failed, error: error.localizedDescription)
        }
    }

    func stop(_ id: UUID) {
        for child in children(of: id) where child.phase.isActive { stop(child.id) }
        preparations.removeValue(forKey: id)?.cancel()
        // Revoke admissions immediately, even when the process takes time to honor Stop.
        for context in Array(contexts.values) where context.parent == id { endCaller(context.id) }
        if let runner = runners[id] {
            runner.stop()
            // Do not return the workspace to the caller until the child process actually exits.
            return
        }
        for context in Array(contexts.values) where context.parent == id { endCaller(context.id) }
        finish(id, phase: .stopped, error: "Stopped")
    }

    func stopRoot(_ target: ChatTarget) {
        for record in root(target).runs where record.phase.isActive { stop(record.id) }
        for context in Array(contexts.values) where context.target == target { endCaller(context.id) }
    }

    func stopBot(_ id: UUID) {
        for record in all where record.phase.isActive && (record.rootBotID == id || record.targetBotID == id) { stop(record.id) }
        for context in Array(contexts.values) where context.target.botID == id { endCaller(context.id) }
    }

    func endCaller(_ id: UUID) {
        guard let caller = contexts.removeValue(forKey: id) else { return }
        watchers.removeValue(forKey: id)?.cancel()
        rejections[id] = nil
        for record in root(caller.target).runs where record.callerInvocationID == id && record.phase.isActive { stop(record.id) }
        Task { try? await caller.transport.close() }
    }

    /// BotChu is quitting: what each run printed last goes into its transcript, and every
    /// checkpoint still waiting is written, so nothing streamed is lost. When the archive writes
    /// through the app's storage, quitting waits for it there (`AppModel.stopAll`).
    func stopAll() {
        for runner in Array(runners.values) { runner.flushOutput() }
        for record in all where record.phase.isActive { stop(record.id) }
        for id in Array(contexts.keys) { endCaller(id) }
        archive.flush(timeout: archive.storage === model?.storage ? 0 : model?.quitTimeout ?? AppModel.saveTimeout)
    }

    /// Ends a run once its worker and every descendant have exited. Its end is saved off the main
    /// thread, and the run stays active until it is: the handoff goes back only once its record is
    /// durable, and one that can't be saved goes back as a failure.
    private func finish(_ id: UUID, phase: SubagentPhase, error: String?) {
        guard var record = run(id), record.phase.isActive, !finalizing.contains(id) else { return }
        let working = children(of: id).filter { $0.phase.isActive }
        if !working.isEmpty {
            pendingFinishes[id] = (phase, error)
            for child in working { stop(child.id) }
            return
        }
        // A run found unfinished after a relaunch is closed once its transcript is read, so an empty
        // one is never saved over it.
        if reading.contains(id) {
            pendingFinishes[id] = (phase, error)
            return
        }
        pendingFinishes[id] = nil
        finalizing.insert(id)
        record.phase = phase
        record.finishedAt = Date()
        record.errorMessage = error
        let live = live(id)
        record.handoffOutput = live.messages.last(where: { $0.role == .assistant }).map { MemoryNotes.handoffText($0.text) }
        var messages = live.messages
        ThreadAssembler.closeRunningTools(&messages)
        if let error { messages.append(ChatMessage(role: phase == .stopped ? .note : .error, text: error)) }
        live.messages = messages
        live.state = nil
        preparations[id] = nil
        let reviewed = !restored.contains(id)
        // What the run asked to remember goes into the called bot's memory, which its Home hears
        // about; a save that fails waits to be tried again, and doesn't fail the handoff.
        if phase == .completed, let model, let targetBot = model.bot(record.targetBotID) {
            model.saveMemory(from: messages, of: targetBot, reportTo: .home(targetBot.id)) { [weak self] lines in
                self?.commit(record, messages: messages + lines, reviewed: reviewed)
            }
        } else {
            commit(record, messages: messages, reviewed: reviewed)
        }
    }

    /// Saves a finished run, then hands it back to its caller.
    private func commit(_ record: SubagentRun, messages: [ChatMessage], reviewed: Bool) {
        let id = record.id
        if lives[id] != nil { live(id).messages = messages }
        let done: @MainActor @Sendable (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            var record = record
            if let error {
                record.phase = .failed
                record.errorMessage = "Couldn't save the handoff: \(error.localizedDescription)"
                self.error = record.errorMessage
            }
            self.finalizing.remove(id)
            self.restored.remove(id)
            self.replace(record)
            self.queueDelivery(record)
            // A review of the attempt, in the background; the handoff doesn't wait for it.
            if reviewed { self.model?.evaluateSubagentRun(record, messages: messages) }
            for (parent, outcome) in self.pendingFinishes where !self.children(of: parent).contains(where: { $0.phase.isActive }) {
                self.finish(parent, phase: outcome.0, error: outcome.1)
            }
            self.model?.sendNextQueued(to: ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID))
        }
        do {
            archive.save(try snapshot(record, messages: messages), done: done)
        } catch {
            done(error)
        }
    }

    private func queueDelivery(_ record: SubagentRun) {
        guard deliveryTasks[record.id] == nil, let transport = deliveries[record.id] else { return }
        let payload = result(record)
        deliveryTasks[record.id] = Task { [weak self] in
            for attempt in 0..<6 {
                do {
                    try await transport.writeResult(id: record.id, data: SubagentIPC.encode(payload))
                    self?.deliveries[record.id] = nil
                    self?.deliveryTasks[record.id] = nil
                    return
                } catch {
                    self?.error = "Couldn't return a sub-agent handoff: \(error.localizedDescription)"
                    try? await Task.sleep(for: .milliseconds(250 * (1 << attempt)))
                }
            }
            // A live heartbeat without a deliverable result would strand call/wait. Closing the
            // mailbox makes the helper fail promptly; durable results are retried after relaunch.
            try? await transport.close()
            if let id = record.callerInvocationID { self?.endCaller(id) }
            self?.deliveryTasks[record.id] = nil
        }
    }

    private func result(_ record: SubagentRun) -> SubagentResult {
        SubagentResult(id: record.id, targetBotID: record.targetBotID, targetBotName: record.targetBotName,
                       phase: record.phase, handoffOutput: record.handoffOutput ?? "", errorMessage: record.errorMessage,
                       startedAt: record.startedAt, finishedAt: record.finishedAt ?? Date())
    }

    private func replace(_ record: SubagentRun) {
        let root = root(ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID))
        guard let index = root.runs.firstIndex(where: { $0.id == record.id }) else { return }
        let wasActive = root.runs[index].phase.isActive
        root.runs[index] = record
        if wasActive != record.phase.isActive { refreshBusyBots() }
    }
    private func modify(_ id: UUID, _ edit: (inout SubagentRun) -> Void) {
        guard var record = run(id) else { return }
        edit(&record)
        replace(record)
    }

    /// The run as it stands, with the folder of the bot that owns its records.
    private func snapshot(_ record: SubagentRun, messages: [ChatMessage]) throws -> SubagentArchive.Snapshot {
        guard let owner = model?.bot(record.rootBotID) else { throw DelegationFailure("The owning bot no longer exists.") }
        return SubagentArchive.Snapshot(record: record, messages: messages, home: BotHome(workspace: owner.workspace))
    }


    /// Every conversation's runs, from their records (also under closed tasks), without their
    /// transcripts: a finished run's handoff goes back from its record, and its transcript is read
    /// when it is shown. A run found unfinished is read off the main thread, then closed, once.
    private func restore() {
        guard let model else { return }
        for bot in model.bots {
            let home = BotHome(workspace: bot.workspace)
            for taskID in [nil] + (model.tasks[bot.id] ?? []).map({ Optional($0.id) }) {
                let target = ChatTarget(botID: bot.id, taskID: taskID)
                let runs = home.loadSubagents(taskID: taskID)
                guard !runs.isEmpty else { continue }
                setRuns(runs, for: target)
                for record in runs {
                    if let invocationID = record.callerInvocationID {
                        let destination = model.settings.host(record.callerHostID)?.destination
                        if record.callerHostID == nil || destination != nil {
                            deliveries[record.id] = SubagentTransport(machine: Machine(destination: destination), namespace: namespace,
                                                                    invocationID: invocationID, localRoot: root)
                        }
                    }
                    if record.phase.isActive {
                        restored.insert(record.id)
                        reading.insert(record.id)
                        let id = record.id
                        archive.storage.submit(home.subagentURL(id: id, taskID: taskID).path, label: "read",
                                               work: { home.loadSubagentThread(id: id, taskID: taskID) }) { [weak self] result in
                            guard let self, self.reading.remove(id) != nil, self.run(id)?.phase.isActive == true else { return }
                            let live = self.live(id)
                            if !live.isLoaded { live.messages = (try? result.get()) ?? [] }
                            self.pendingFinishes[id] = nil
                            self.finish(id, phase: .stopped, error: "BotChu restarted before this sub-agent finished.")
                        }
                    } else { queueDelivery(record) }
                }
            }
        }
    }

    /// A finished run's transcript, read when something shows it, off the main thread, after the
    /// writes asked for before in its folder.
    fileprivate func readThread(_ id: UUID) {
        let live = live(id)
        guard !live.isLoaded, !live.isReading, let record = run(id), !record.phase.isActive,
              let owner = model?.bot(record.rootBotID) else { return }
        live.isReading = true
        let home = BotHome(workspace: owner.workspace), taskID = record.rootTaskID
        archive.storage.submit(home.subagentURL(id: id, taskID: taskID).path, label: "read",
                               work: { home.loadSubagentThread(id: id, taskID: taskID) }) { [weak self, weak live] result in
            guard let self, let live, self.lives[id] === live else { return }
            live.isReading = false
            guard !live.isLoaded, case .success(let messages) = result else { return }
            live.messages = messages
            self.budget.use(id, bytes: HistoryBudget<UUID>.estimate(messages))
            self.trimThreads()
        }
    }

    /// Drops finished runs' transcripts read for showing, beyond `finishedThreadBytes`, except
    /// those of the conversation shown and runs under way; their counts stay.
    func trimThreads() {
        let shown = model?.selection.flatMap { model?.tab(of: $0) }
        for id in budget.overflow(pinned: { id in
            guard let record = self.run(id) else { return false }
            return record.phase.isActive || ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID) == shown
        }) {
            budget.remove(id)
            lives[id]?.unload()
        }
    }

    /// Removes a finished run and its descendants, each folder after any write of it, so nothing
    /// written later makes it again; the run leaves the inspector once its folder is gone.
    func clear(_ id: UUID) {
        guard let record = run(id), !record.phase.isActive, !finalizing.contains(id) else { return }
        let descendants = children(of: id)
        guard !descendants.contains(where: { $0.phase.isActive }) else { return }
        for child in descendants { clear(child.id) }
        guard let owner = model?.bot(record.rootBotID) else { return }
        archive.remove(id, taskID: record.rootTaskID, home: BotHome(workspace: owner.workspace)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.error = "Couldn't clear the sub-agent: \(error.localizedDescription)"
                return
            }
            self.root(ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID)).runs.removeAll { $0.id == id }
            self.locations[id] = nil
            self.lives[id] = nil
            self.budget.remove(id)
        }
    }
}

/// The runs delegated from one conversation (their root), observed apart from every other
/// conversation's, with their tree grouped once per change rather than on every draw.
@MainActor @Observable
final class SubagentRoot {
    @ObservationIgnored private var storage: [SubagentRun] = []
    @ObservationIgnored private var byParent: [UUID?: [SubagentRun]]?

    /// Oldest first; descendants beside the conversation's own.
    var runs: [SubagentRun] {
        get {
            access(keyPath: \.runs)
            return storage
        }
        set {
            withMutation(keyPath: \.runs) {
                storage = newValue
                byParent = nil
            }
        }
    }

    /// The runs a run delegated to; nil for the conversation's own.
    func children(of parent: UUID?) -> [SubagentRun] {
        access(keyPath: \.runs)
        if byParent == nil { byParent = Dictionary(grouping: storage, by: \.parentSubagentID) }
        return byParent?[parent] ?? []
    }
}

/// A run's transcript and turn as they stream in, observed apart from every other run's.
@MainActor @Observable
final class SubagentLive {
    var messages: [ChatMessage] = [] {
        didSet {
            isLoaded = true
            tally.update(messages)
            if tally.counts != counts { counts = tally.counts }
        }
    }
    /// Whether the transcript is in memory: a finished run's, restored after a relaunch, is read
    /// when shown (`SubagentRuntime.readThread`); one dropped again keeps its counts.
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private(set) var wasCounted = false
    @ObservationIgnored var isReading = false

    fileprivate func unload() {
        let kept = counts
        tally = ToolCallTally()
        messages = []
        counts = kept
        isLoaded = false
        wasCounted = true
    }
    /// Its tool calls, counted as they stream in (`ToolCallTally`), and observed apart from the
    /// transcript: a card showing only the counts isn't redrawn by every delta.
    private(set) var counts = ToolCounts()
    @ObservationIgnored private var tally = ToolCallTally()
    var state: RunState?

    /// Changes the transcript in place, without copying it.
    func update(_ change: (inout [ChatMessage]) -> Void) {
        change(&messages)
    }
}

/// `records[target]`: a conversation's runs, read and written like a dictionary.
@MainActor struct SubagentRecords {
    let runtime: SubagentRuntime

    subscript(target: ChatTarget) -> [SubagentRun]? {
        get { runtime.root(target).runs }
        nonmutating set { runtime.setRuns(newValue ?? [], for: target) }
    }
}

/// `threads[id]`: a run's transcript.
@MainActor struct SubagentThreads {
    let runtime: SubagentRuntime

    /// A finished run's transcript not in memory is read for whoever asks (empty meanwhile).
    subscript(id: UUID) -> [ChatMessage]? {
        get {
            let live = runtime.live(id)
            if !live.isLoaded { runtime.readThread(id) }
            return live.messages
        }
        nonmutating set {
            if let newValue { runtime.live(id).messages = newValue } else { runtime.dropLive(id) }
        }
    }

    /// Whether a run's transcript is in memory.
    func isLoaded(_ id: UUID) -> Bool { runtime.live(id).isLoaded }

    /// How many tool calls a run's transcript holds (read, the first time, when it isn't in memory).
    func counts(_ id: UUID) -> ToolCounts {
        let live = runtime.live(id)
        if !live.isLoaded, !live.wasCounted { runtime.readThread(id) }
        return live.counts
    }
}

/// `states[id]`: a run's turn, while it runs.
@MainActor struct SubagentStates {
    let runtime: SubagentRuntime

    subscript(id: UUID) -> RunState? {
        get { runtime.live(id).state }
        nonmutating set { runtime.live(id).state = newValue }
    }

    /// Whether no run is under way.
    var isEmpty: Bool { runtime.lives.values.allSatisfy { $0.state == nil } }
}

private struct DelegationFailure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
