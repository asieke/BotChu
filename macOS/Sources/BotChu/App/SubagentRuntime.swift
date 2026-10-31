import Foundation
import UniformTypeIdentifiers
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
    let sensitiveInput = SensitiveInputRuntime()
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
    /// Status observation includes caller lifetime, releasing its one-shot registrations even
    /// when a turn ends without ever delegating (and therefore without changing any run).
    private var contexts: [UUID: Caller] = [:]
    @ObservationIgnored private var runners: [UUID: AgentRun] = [:]
    @ObservationIgnored private var usageCaptures: [UUID: (capture: UsageLedger.Capture, home: BotHome)] = [:]
    @ObservationIgnored private var preparations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [UUID: MailboxTasks] = [:]
    @ObservationIgnored private var deliveries: [UUID: SubagentTransport] = [:]
    @ObservationIgnored private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rejections: [UUID: [UUID: SubagentResult]] = [:]
    /// What each Task request (`botchu-task create`) has come to so far, by request (#111).
    @ObservationIgnored private var handoffs: [UUID: TaskHandoffResult] = [:]
    /// What each delivery (`botchu-inbox send`) came to, by request.
    @ObservationIgnored private var inboxResults: [UUID: InboxResult] = [:]
    /// The deliveries each caller's are being taken, by request, so none is taken twice at once.
    @ObservationIgnored private var receiving: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var messageResults: [UUID: AgentMessageResult] = [:]
    @ObservationIgnored private var pendingFinishes: [UUID: (SubagentPhase, String?)] = [:]
    @ObservationIgnored private var requestCounts: [ChatTarget: Int] = [:]
    /// Runs whose end is being saved: still active until it is, so their caller waits for them.
    @ObservationIgnored private var finalizing: Set<UUID> = []
    /// Runs found unfinished after a relaunch, which are closed and aren't reviewed.
    @ObservationIgnored private var restored: Set<UUID> = []
    /// What stopped each run being stopped, until it ends (#368); the first cause stands.
    @ObservationIgnored private var stopCauses: [UUID: SubagentInterruption.Cause] = [:]
    /// Runs whose CLI has exited and whose workspace is being read before they end: Stop waits.
    @ObservationIgnored private var exiting: Set<UUID> = []
    /// Interrupted runs being checked before they're relaunched (#368): a second Resume is refused.
    private(set) var resuming: Set<UUID> = []
    /// Why the owner's last Resume of a run didn't relaunch it, shown beside its Resume.
    private(set) var resumeProblems: [UUID: String] = [:]
    /// The runs of other conversations each caller resumed or collects (Home a task's run), so their
    /// statuses reach its mailbox and its end stops them as it stops its own.
    @ObservationIgnored private var attached: [UUID: Set<UUID>] = [:]
    /// Finished runs' transcripts are read when shown (#109), and at most this many bytes of those
    /// not in the conversation shown stay in memory, the least recently read going first.
    nonisolated static let finishedThreadBytes = 16 << 20
    @ObservationIgnored private var budget = HistoryBudget<UUID>(limit: SubagentRuntime.finishedThreadBytes)

    /// Hosts retain their existing polling cadence; local mailboxes use directory hints.
    nonisolated static let remotePoll: Duration = .milliseconds(750)
    /// How often its heartbeat is refreshed: well within `SubagentLimits.heartbeatTimeout`.
    nonisolated static let heartbeatInterval: TimeInterval = 2

    private struct MailboxTasks {
        var requests: Task<Void, Never>
        var heartbeat: Task<Void, Never>?
        var status: Task<Void, Never>?
        var updates: AsyncStream<[SubagentStatus]>.Continuation?

        func cancel() {
            requests.cancel()
            heartbeat?.cancel()
            status?.cancel()
            updates?.finish()
        }

        func settleWrites() async {
            await heartbeat?.value
            await status?.value
        }
    }

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
            _ = try SubagentHookInstaller.install(binDirectory: SubagentIPC(root: root).binDirectory)
            try refreshRoster()
        } catch { self.error = "Couldn't prepare sub-agents: \(error.localizedDescription)" }
        restore()
    }

    deinit {
        for watcher in watchers.values { watcher.cancel() }
    }

    /// Each conversation's runs, oldest first: `records[target]`, read and written like the
    /// dictionary it replaces. Reading one conversation's observes that conversation's alone.
    var records: SubagentRecords { SubagentRecords(runtime: self) }
    /// Each run's transcript, by run.
    var threads: SubagentThreads { SubagentThreads(runtime: self) }
    /// Each run's turn while it runs, by run.
    var states: SubagentStates { SubagentStates(runtime: self) }

    /// Every bot; remote queue bots are marked (`BotRosterEntry.remote`), to be messaged rather than delegated to.
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

    /// Waits for what is being written of the conversation's runs, before its folder moves.
    func settleRuns(of target: ChatTarget) {
        guard let owner = model?.bot(target.botID) else { return }
        let home = BotHome(workspace: owner.workspace)
        for run in root(target).runs { archive.storage.sync(home.subagentURL(id: run.id, taskID: run.rootTaskID).path, label: "move") {} }
    }

    /// The conversation's runs, as its area moved to another bot (`AppModel.moveArea`): they are
    /// that bot's conversation's now.
    func moveRuns(from old: ChatTarget, to new: ChatTarget) {
        let runs = root(old).runs.map { run -> SubagentRun in
            var run = run
            run.rootBotID = new.botID
            return run
        }
        setRuns([], for: old)
        roots[old] = nil
        setRuns(runs, for: new)
    }

    /// The main checkout a run starts in when it is a shared child of a repository's Project Area.
    private func areaCheckout(of record: SubagentRun) -> String? {
        guard record.workspaceMode == .sharedCallerWorkspace, let area = model?.task(ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID)),
              area.area?.kind == .repo, record.workingDirectory == area.checkout else { return nil }
        return area.checkout
    }

    fileprivate func root(_ target: ChatTarget) -> SubagentRoot {
        if let existing = roots[target] { return existing }
        let made = SubagentRoot()
        roots[target] = made
        return made
    }

    func live(_ id: UUID) -> SubagentLive {
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
        if parent == nil {
            requestCounts[target] = 0
            model?.inbox?.turnStarts(target)
        }
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

    /// Local request scans, heartbeats and status delivery have independent lifetimes, so a
    /// quiet mailbox (or slow admission) cannot hold up liveness or activity updates.
    private func startWatcher(_ caller: Caller) {
        guard !caller.transport.machine.isRemote else { startRemoteWatcher(caller); return }
        let id = caller.id, transport = caller.transport
        let requests = Task.detached(priority: .utility) { [weak self] in
            guard let watcher = transport.watchRequests() else { return }
            defer { watcher.cancel() }
            for await _ in watcher.changes {
                guard !Task.isCancelled else { break }
                do {
                    try await transport.drainRequests { [weak self] envelopes in
                        guard let self, !Task.isCancelled else { return false }
                        return await self.take(envelopes, from: id) != nil
                    }
                } catch {
                    guard let self, !Task.isCancelled, await self.isWatching(id) else { break }
                    await self.report("Sub-agent connection: \(error.localizedDescription)")
                }
            }
        }
        // Ahead of other background work: a loaded Mac starves this first, and a late heartbeat
        // makes a caller's helper give up on runs still going (#368).
        let heartbeat = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                do {
                    try await transport.heartbeat()
                } catch {
                    guard let self, !Task.isCancelled, await self.isWatching(id) else { break }
                    await self.report("Sub-agent connection: \(error.localizedDescription)")
                }
                do { try await Task.sleep(for: .seconds(Self.heartbeatInterval)) } catch { break }
            }
        }
        let updates = AsyncStream<[SubagentStatus]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let status = Task.detached(priority: .utility) { [weak self] in
            var written: [UUID: SubagentStatus] = [:]
            for await statuses in updates.stream {
                guard !Task.isCancelled else { break }
                do {
                    for status in statuses {
                        if let last = written[status.id], last.phase == status.phase, last.activity == status.activity { continue }
                        try await transport.writeStatus(id: status.id, data: SubagentIPC.encode(status))
                        written[status.id] = status
                    }
                } catch {
                    guard let self, !Task.isCancelled, await self.isWatching(id) else { break }
                    await self.report("Sub-agent connection: \(error.localizedDescription)")
                    // Retain retries after a transient write failure, even if activity is quiet.
                    do { try await Task.sleep(for: .seconds(Self.heartbeatInterval)) } catch { break }
                    if let current = await self.statuses(for: id) { updates.continuation.yield(current) }
                }
            }
        }
        watchers[id] = MailboxTasks(requests: requests, heartbeat: heartbeat, status: status, updates: updates.continuation)
        observeStatuses(id, updates: updates.continuation)
    }

    private func observeStatuses(_ id: UUID, updates: AsyncStream<[SubagentStatus]>.Continuation) {
        guard contexts[id] != nil else { updates.finish(); return }
        let current = withObservationTracking {
            statuses(for: id) ?? []
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeStatuses(id, updates: updates) }
        }
        updates.yield(current)
    }

    /// SSH retains its independent connection, poll cadence and combined heartbeat round trip.
    private func startRemoteWatcher(_ caller: Caller) {
        let id = caller.id
        let transport = caller.transport
        let pause = Self.remotePoll
        let heartbeatInterval = Self.heartbeatInterval
        let task = Task.detached(priority: .utility) { [weak self] in
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
        watchers[id] = MailboxTasks(requests: task)
    }

    /// Takes a caller's requests, then returns its runs' statuses; nil once the caller has ended.
    private func take(_ envelopes: [SubagentEnvelope], from id: UUID) async -> [SubagentStatus]? {
        guard let caller = contexts[id] else { return nil }
        for envelope in envelopes {
            if !caller.transport.machine.isRemote, Task.isCancelled { break }
            await receive(envelope.data, filename: envelope.filename, from: caller)
        }
        return statuses(for: id)
    }

    private func statuses(for id: UUID) -> [SubagentStatus]? {
        guard let caller = contexts[id] else { return nil }
        let elsewhere = (attached[id] ?? []).compactMap { run($0) }
        return (root(caller.target).runs + elsewhere).filter { $0.callerInvocationID == id && $0.phase.isActive }.map { record in
            SubagentStatus(id: record.id, phase: record.phase, activity: live(record.id).state?.activity.doing ?? "Preparing…")
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
        if SensitiveInputRequest.isRequest(data) {
            await receiveSensitiveInput(data, id: fileID, filename: filename, from: caller)
            return
        }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
           object["kind"] == "secretCancel" {
            if object["invocationID"].flatMap(UUID.init(uuidString:)) == caller.id,
               object["id"].flatMap(UUID.init(uuidString:)) == fileID,
               let requestID = object["requestID"].flatMap(UUID.init(uuidString:)) {
                sensitiveInput.cancel(requestID, invocationID: caller.id)
            }
            try? await caller.transport.acknowledge(filename: filename)
            return
        }
        // A Task for a bot, not a run of this turn's (#111).
        if TaskHandoff.isHandoff(data) {
            await receiveHandoff(data, id: fileID, filename: filename, from: caller)
            return
        }
        // A delivery to the owner's Inbox, as the conversation at the top of the chain.
        if InboxRequest.isDelivery(data) {
            await receiveDelivery(data, id: fileID, filename: filename, from: caller)
            return
        }
        // A message to a remote queue bot, whose reply comes back to the conversation at the top.
        if AgentMessageRequest.isMessage(data) {
            await receiveMessage(data, id: fileID, filename: filename, from: caller)
            return
        }
        // The asking bot's own open Tasks, as its Tasks column shows them (#262).
        if TaskListRequest.isRequest(data) {
            await receiveTaskList(data, id: fileID, filename: filename, from: caller)
            return
        }
        // Model lists checked now, as Refresh models does (#326).
        if ModelRefreshRequest.isRequest(data) {
            await receiveModelRefresh(data, id: fileID, filename: filename, from: caller)
            return
        }
        // An interrupted run relaunched, or runs of an earlier turn collected (#368).
        if SubagentResumeRequest.isRequest(data) {
            await receiveResume(data, id: fileID, filename: filename, from: caller)
            return
        }
        if SubagentAttachRequest.isRequest(data) {
            await receiveAttach(data, id: fileID, filename: filename, from: caller)
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
            let targetBot = try SubagentResolver.resolve(request.targetAgent, bots: model.bots.filter { !$0.isRemoteQueue })
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
            let brief = ChatMessage(role: .user, text: request.brief)
            do {
                try await archive.save(snapshot(record, messages: [brief]))
                admitting -= 1
            } catch {
                admitting -= 1
                requestCounts[caller.target, default: 1] -= 1
                throw error
            }
            add(record, to: caller.target)
            // Admission and launch refer to the same persisted message. A fresh ID here would
            // make the paged archive preserve both briefs when it reconciles the next save.
            live(record.id).messages = [brief]
            live(record.id).state = RunState(preparing: true)
            deliveries[record.id] = caller.transport
            guard contexts[caller.id] != nil else { stop(record.id); return }
            preparations[record.id] = Task { [weak self] in await self?.launch(record.id, targetBot: targetBot) }
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

    // MARK: Deliveries to the Inbox

    /// Takes a `botchu-inbox send` request: the delivery is the caller's conversation's (the top of
    /// the chain), crediting the sub-agent's bot when a sub-agent sent it and the bots it names. Its
    /// answer, written into the caller's mailbox, says what became of it; asking again gets the same.
    private func receiveDelivery(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        if let known = inboxResults[id] {
            try? await caller.transport.writeResult(id: id, data: SubagentIPC.encode(known))
            try? await caller.transport.acknowledge(filename: filename)
            return
        }
        guard receiving[caller.id, default: []].insert(id).inserted else { return }
        defer { receiving[caller.id]?.remove(id) }
        var result: InboxResult
        do {
            guard let model, let inbox = model.inbox else { throw InboxRequest.Problem("BotChu is shutting down") }
            let request = try InboxRequest.parse(data)
            guard request.id == id else { throw InboxRequest.Problem("the request's ID doesn't match its file") }
            try request.validate(SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID, taskID: caller.target.taskID,
                                                       parentSubagentID: caller.parent, depth: caller.depth,
                                                       workingDirectory: caller.directory, hostID: caller.hostID))
            guard contexts[caller.id] != nil else { throw InboxRequest.Problem("the sending turn has ended") }
            let subagent = caller.parent.flatMap { run($0) }.map { Delivery.Credit(botID: $0.targetBotID, name: $0.targetBotName) }
            var credits = subagent.map { [$0] } ?? []
            for name in request.credits {
                let bot = try SubagentResolver.resolve(name, bots: model.bots.filter { !$0.isRemoteQueue }, list: "botchu-subagent list")
                credits.append(Delivery.Credit(botID: bot.id, name: bot.name))
            }
            var seen: Set<UUID> = [caller.target.botID]
            credits = credits.filter { seen.insert($0.botID).inserted }
            let received = try await inbox.receive(request, in: caller.target, credits: credits,
                                                   subagent: subagent.flatMap { $0.botID == caller.target.botID ? nil : $0 },
                                                   transport: caller.transport)
            result = InboxResult(id: id, deliveryID: received.delivery.id, updated: received.updated)
        } catch {
            result = InboxResult(id: id, errorMessage: (error as? InboxRequest.Problem)?.message ?? error.localizedDescription)
        }
        inboxResults[id] = result
        do {
            try await caller.transport.writeResult(id: id, data: SubagentIPC.encode(result))
            try await caller.transport.acknowledge(filename: filename)
        } catch { if !Task.isCancelled, isWatching(caller.id) { report("Couldn't answer a delivery: \(error.localizedDescription)") } }
    }

    // MARK: Messages to remote bots

    /// Takes a `botchu-message send` request: copies its staged files into the remote bot's folder
    /// and queues it there as the conversation's (the top of the chain), whose reply comes back to
    /// it (`RemoteQueueBridge.forward`). The request's ID is the message's, so asking again queues
    /// nothing more.
    private func receiveMessage(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        if let known = messageResults[id] {
            try? await caller.transport.writeResult(id: id, data: SubagentIPC.encode(known))
            try? await caller.transport.acknowledge(filename: filename)
            return
        }
        var result: AgentMessageResult
        do {
            guard let model, let sender = model.bot(caller.target.botID) else { throw InboxRequest.Problem("BotChu is shutting down") }
            let request = try AgentMessageRequest.parse(data)
            guard request.id == id else { throw InboxRequest.Problem("the request's ID doesn't match its file") }
            try request.validate(SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID, taskID: caller.target.taskID,
                                                       parentSubagentID: caller.parent, depth: caller.depth,
                                                       workingDirectory: caller.directory, hostID: caller.hostID))
            guard contexts[caller.id] != nil else { throw InboxRequest.Problem("the sending turn has ended") }
            let remote = try SubagentResolver.resolve(request.agent, bots: model.bots.filter(\.isRemoteQueue), list: "botchu-message list")
            let home = BotHome(workspace: remote.persistencePath)
            var files: [FileAttachment] = []
            do {
                for file in request.files {
                    let contents = try await caller.transport.readStaged(file.staged, request: request.id, limit: FileAttachment.maximumBytes)
                    files.append(try home.saveFile(contents, name: file.name, type: Self.mimeType(of: file.name)))
                }
                try await model.remoteQueue.send(request.text, files: files, id: request.id, to: remote.id,
                                                 from: AgentLink(botID: sender.id, name: sender.name, taskID: caller.target.taskID))
            } catch {
                files.forEach(home.removeFile)
                throw error
            }
            try? await caller.transport.removeStaged(request: request.id)
            result = AgentMessageResult(id: id, targetBotName: remote.name)
        } catch {
            result = AgentMessageResult(id: id, errorMessage: (error as? InboxRequest.Problem)?.message ?? error.localizedDescription)
        }
        messageResults[id] = result
        do {
            try await caller.transport.writeResult(id: id, data: SubagentIPC.encode(result))
            try await caller.transport.acknowledge(filename: filename)
        } catch { if isWatching(caller.id) { report("Couldn't answer a message: \(error.localizedDescription)") } }
    }

    // MARK: Sensitive input (#266)

    private func receiveSensitiveInput(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        func respond(_ status: SensitiveInputResult.Status, reason: SensitiveInputResult.Reason? = nil) async {
            try? await caller.transport.writeResult(id: id,
                data: SubagentIPC.encode(SensitiveInputResult(id: id, status: status, reason: reason)))
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let request: SensitiveInputRequest
            do { request = try decoder.decode(SensitiveInputRequest.self, from: data) }
            catch { throw SensitiveInputResult.Reason.malformedRequest }
            guard request.id == id else { throw SensitiveInputResult.Reason.requestIDMismatch }
            guard contexts[caller.id] != nil, let model else { throw SensitiveInputResult.Reason.turnEnded }
            guard !caller.transport.machine.isRemote else { throw SensitiveInputResult.Reason.notLocal }
            do {
                try request.validate(caller: SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID,
                    taskID: caller.target.taskID, parentSubagentID: caller.parent, depth: caller.depth,
                    workingDirectory: caller.directory, hostID: caller.hostID))
            } catch let error as SensitiveInputError {
                throw error.rejectionReason
            }
            let excludedDirectory = root.path
            guard !SensitiveInputDestination.isWithin(request.destination, directory: excludedDirectory) else {
                throw SensitiveInputResult.Reason.excludedDestination
            }
            do { try await Task.detached { try SensitiveInputDestination.check(request.destination) }.value }
            catch { throw SensitiveInputResult.Reason.unavailableDestination }
            let botID = caller.parent.flatMap { run($0) }?.targetBotID ?? caller.target.botID
            guard let bot = model.bot(botID) else { throw SensitiveInputResult.Reason.unknownBot }
            do { try await caller.transport.acknowledge(filename: filename) }
            catch { throw SensitiveInputResult.Reason.ackFailed }
            guard contexts[caller.id] != nil else { throw SensitiveInputResult.Reason.turnEnded }
            sensitiveInput.enqueue(request, botName: bot.name, reject: { reason in
                Task { await respond(.rejected, reason: reason) }
            }) { status in
                Task { await respond(status) }
            }
        } catch {
            // Only allowlisted codes cross the IPC boundary; never underlying errors or values.
            await respond(.rejected, reason: (error as? SensitiveInputResult.Reason) ?? .invalidRequest)
            try? await caller.transport.acknowledge(filename: filename)
        }
    }

    // MARK: The asking bot's Tasks (#262)

    /// Takes a `botchu-task list --mine` request: answers with the open Tasks of the bot whose turn
    /// asks (a sub-agent run's own bot), as its Tasks column lists them now. It changes nothing, so
    /// asking again just answers again.
    private func receiveTaskList(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        var result: TaskListResult
        do {
            guard let model else { throw InboxRequest.Problem("BotChu is shutting down") }
            let request = try TaskListRequest.parse(data)
            guard request.id == id else { throw InboxRequest.Problem("the request's ID doesn't match its file") }
            try request.validate(SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID, taskID: caller.target.taskID,
                                                       parentSubagentID: caller.parent, depth: caller.depth,
                                                       workingDirectory: caller.directory, hostID: caller.hostID))
            guard contexts[caller.id] != nil else { throw InboxRequest.Problem("the asking turn has ended") }
            let botID = caller.parent.flatMap { run($0) }?.targetBotID ?? caller.target.botID
            guard let bot = model.bot(botID) else { throw InboxRequest.Problem("the asking bot is no longer in BotChu") }
            result = TaskListResult(id: id, botID: bot.id, botName: bot.name, tasks: model.taskList(of: bot.id))
        } catch {
            result = TaskListResult(id: id, errorMessage: (error as? InboxRequest.Problem)?.message ?? error.localizedDescription)
        }
        do {
            try await caller.transport.writeResult(id: id, data: SubagentIPC.encode(result))
            try await caller.transport.acknowledge(filename: filename)
        } catch { if isWatching(caller.id) { report("Couldn't answer a Tasks list request: \(error.localizedDescription)") } }
    }

    // MARK: Model lists (#326)

    /// Takes a `botchu-models refresh` request: checks the lists it names, or every one, as Refresh
    /// models does, outside the watcher's loop so the caller's mailbox goes on meanwhile, then answers
    /// with each list as its picker shows it. Asking again checks again.
    private func receiveModelRefresh(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        let request: ModelRefreshRequest
        do {
            guard model != nil else { throw InboxRequest.Problem("BotChu is shutting down") }
            request = try ModelRefreshRequest.parse(data)
            guard request.id == id else { throw InboxRequest.Problem("the request's ID doesn't match its file") }
            try request.validate(SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID, taskID: caller.target.taskID,
                                                       parentSubagentID: caller.parent, depth: caller.depth,
                                                       workingDirectory: caller.directory, hostID: caller.hostID))
            guard contexts[caller.id] != nil else { throw InboxRequest.Problem("the asking turn has ended") }
        } catch {
            await answer(ModelRefreshResult(id: id, errorMessage: (error as? InboxRequest.Problem)?.message ?? error.localizedDescription), to: caller)
            try? await caller.transport.acknowledge(filename: filename)
            return
        }
        try? await caller.transport.acknowledge(filename: filename)
        Task { [weak self] in
            guard let result = await self?.model?.refreshModelLists(request) else { return }
            await self?.answer(result, to: caller)
        }
    }

    private func answer(_ result: ModelRefreshResult, to caller: Caller) async {
        do { try await caller.transport.writeResult(id: result.id, data: SubagentIPC.encode(result)) }
        catch { if isWatching(caller.id) { report("Couldn't answer a model list request: \(error.localizedDescription)") } }
    }

    private static func mimeType(of name: String) -> String? {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
    }

    // MARK: Tasks handed to bots (#111)

    /// Takes a `botchu-task create` request: answers it at once (pending, or why not), then posts it
    /// into the repository's area (or makes the Task) outside the watcher's loop, so the caller's
    /// mailbox and heartbeat go on meanwhile, and writes how that went, then how its turn started,
    /// into the caller's mailbox. It goes on whatever becomes of the caller. A request seen again
    /// gets the same answer.
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
        var message: UUID?
        do {
            let made = try await model.handOffTask(handoff, from: caller.target, subagent: caller.parent.flatMap { run($0) })
            result = TaskHandoffResult(id: handoff.id, phase: made.unsaved == nil ? .created : .failed, targetBotID: made.bot.id,
                                       targetBotName: made.bot.name, taskID: made.task.id, taskTitle: made.task.title,
                                       existing: made.existing, area: made.task.isArea, errorMessage: made.unsaved)
            message = made.messageID
        } catch {
            result.errorMessage = Self.reason(error)
            // Turned away from a Task already working on it: that Task, to continue in (#215).
            if let working = (error as? TaskRequest.Problem)?.working {
                result.alreadyWorking = true
                result.taskID = working.taskID
                result.taskTitle = working.title
                result.targetBotID = working.botID
                result.targetBotName = model.bot(working.botID)?.name
            }
        }
        handoffs[handoff.id] = result
        await deliver(result, to: caller)
        guard result.phase == .created, let taskID = result.taskID, let botID = result.targetBotID else { return }
        let report: (String?) -> Void = { [weak self] failure in
            guard let self, let created = self.handoffs[handoff.id] else { return }
            let started = created.starting(failure: failure)
            self.handoffs[handoff.id] = started
            Task { await self.deliver(started, to: caller) }
        }
        // An area's turn on the request: the one that takes its message.
        if let message { model.whenMessageStarts(message, in: .task(taskID, of: botID), report) }
        else { model.whenTaskStarts(.task(taskID, of: botID), report) }
    }

    /// Writes a Task request's answer; after the caller's turn has ended, quietly, as nothing waits.
    private func deliver(_ result: TaskHandoffResult, to caller: Caller) async {
        do { try await caller.transport.writeResult(id: result.id, data: SubagentIPC.encode(result)) }
        catch { if isWatching(caller.id) { report("Couldn't answer a task request: \(error.localizedDescription)") } }
    }

    private static func reason(_ error: Error) -> String {
        (error as? TaskRequest.Problem)?.message ?? error.localizedDescription
    }

    /// Starts a run's CLI. A resumed run (`resume`, the delta it starts with) continues its session
    /// where its account can (`session`), or starts a new one with its brief and the delta.
    private func launch(_ id: UUID, targetBot: Bot, resume delta: String? = nil, session: Bool = true) async {
        guard var record = run(id), record.phase.isActive, let model else { return }
        let chosenModel = record.effectiveModel(openRouterDefault: model.settings.openRouterModel, sailDefault: model.settings.sailModel)
        if let owner = model.bot(record.rootBotID) {
            usageCaptures[id] = (UsageLedger.Capture(.init(startedAt: record.startedAt ?? record.createdAt, kind: .subagent,
                botID: record.targetBotID, taskID: record.rootTaskID, subagentRunID: id,
                accountID: record.accountID, provider: record.account.kind, providerID: record.resolvedProvider,
                remote: record.hostID != nil, usesLegacyOpenRouterKey: record.usesLegacyOpenRouterKey(remote: record.hostID != nil),
                model: chosenModel.isEmpty ? nil : chosenModel, modelSource: chosenModel.isEmpty ? .unreported : .requested,
                outcome: .failed)), BotHome(workspace: owner.persistencePath))
        }
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
            await model.preparePiModels(for: record)
            guard run(id)?.phase.isActive == true, !Task.isCancelled else { endCaller(context.id); return }
            let key = record.usesLegacyOpenRouterKey(remote: machine.isRemote) ? model.openRouterKey() : nil
            let command = record.runtimeAdapter.command(local: model.settings.command(for: account),
                host: model.settings.host(record.hostID)?.command(for: account), remote: machine.isRemote)
            let readinessProblem = await record.runtimeAdapter.readiness(command: command, provider: record.provider, model: chosenModel,
                machine: machine, folder: record.workingDirectory, environment: machine.isRemote ? [:] : account.runtimeEnvironment.merging(key.map { ["OPENROUTER_API_KEY": $0] } ?? [:]) { _, value in value })
            guard run(id)?.phase.isActive == true, !Task.isCancelled else { endCaller(context.id); return }
            if let problem = readinessProblem { throw DelegationFailure(problem) }
            let sailKey = account.kind == .sail && !machine.isRemote ? Keychain.get(Keychain.sailAccount) : nil
            if account.kind == .sail, let problem = SailLaunch.problem(remote: machine.isRemote, key: sailKey) {
                throw DelegationFailure(problem)
            }
            record.phase = .running
            record.startedAt = Date()
            recordGitFacts(&record, messages: live(id).messages)
            usageCaptures[id]?.capture.started(at: record.startedAt!)
            try await archive.save(snapshot(record, messages: live(id).messages))
            // Stopped while its start was being saved: its end is saved instead.
            guard run(id)?.phase.isActive == true, !finalizing.contains(id), !Task.isCancelled else { endCaller(context.id); return }
            // Tool policy is always live, never part of the reusable identity snapshot.
            let prepared = try await model.prepareSessionForLaunch(of: targetBot.id, kind: account.kind, remote: machine.isRemote,
                current: { self.run(id)?.phase.isActive == true && !self.finalizing.contains(id) })
            let snapshot = prepared.context
            guard run(id)?.phase.isActive == true, !Task.isCancelled,
                  let currentBot = model.bot(targetBot.id) else { endCaller(context.id); return }
            let preamble = BotContext.subagentPreamble(bot: currentBot, run: record,
                callerDescription: record.parentSubagentID.flatMap { run($0)?.targetBotName } ?? model.bot(target.botID)?.name ?? "Bot",
                memory: snapshot.memory, sharedMemory: snapshot.sharedMemory, soul: snapshot.soul,
                instructions: snapshot.instructions, team: snapshot.team, availableBots: roster, skills: snapshot.skills,
                tools: machine.isRemote ? nil : model.tools.instructions(),
                areaCheckout: areaCheckout(of: record))
            // A resumed run continues its session with the delta alone, or starts anew with both (#368).
            let continued = delta != nil && session ? record.resumableSessionID : nil
            let prompt = delta.map { continued != nil ? $0 : preamble + "\n\n" + $0 } ?? preamble
            var invocation = record.invocation(prompt: prompt, model: chosenModel, sessionID: continued, remote: machine.isRemote,
                openRouterKey: key, sailKey: sailKey, catalog: model.nativeModels(for: record))
            invocation.environment.merge(context.environment) { _, new in new }
            invocation.toolProfile = prepared.toolProfile
            let runner = machine.isRemote
                ? AgentRun(command: command, invocation: invocation, on: machine, folder: record.workingDirectory)
                : AgentRun(command: command, invocation: invocation, directory: URL(fileURLWithPath: record.workingDirectory))
            var stream = TurnStream(account: account, invocation: invocation, usage: usageCaptures[id]?.capture)
            var persistenceFailure: String?
            let toolsAtLaunch = live(id).counts.tools
            // Parsed off the main thread, in batches; the transcript is checkpointed off it too.
            runner.deliverEvents(parsedBy: stream.parser()) { [weak self, weak runner] events in
                guard let self, let runner, self.runners[id] === runner, self.run(id)?.phase.isActive == true else { return }
                let live = self.live(id)
                var state = live.state
                // After Stop, the CLI's last word is about the interruption, which the run's outcome says.
                var input: InputLedger?
                let batch = stream.apply(events, state: &state, stopped: runner.stopped, ledger: &input, followUp: { nil }, in: live.update)
                if state != live.state { live.state = state }
                guard let batch else { return }
                batch.settle { [weak self, weak runner] in
                    guard let self, let runner, self.runners[id] === runner else { return }
                    self.live(id).state?.settle()
                }
                for session in batch.sessions { self.modify(id) { $0.sessionID = session; $0.sessionAccountID = account.id; $0.sessionScope = record.executionScope } }
                if let reported = batch.reportedModel, self.run(id)?.resolvedModel != reported {
                    self.modify(id) { $0.recordReportedModel(reported, requested: $0.model) }
                }
                guard let record = self.run(id) else { return }
                let failed: @MainActor (Error) -> Void = { [weak self] error in
                    guard let self, persistenceFailure == nil, self.run(id)?.phase.isActive == true else { return }
                    persistenceFailure = "Couldn't save the sub-agent transcript: \(error.localizedDescription)"
                    self.stop(id)
                }
                do {
                    self.archive.checkpoint(try self.snapshot(record, messages: live.messages), saved: { [weak live] snapshot in
                        live?.saved(snapshot)
                    }, failed: failed)
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
                    stream.close(&messages)
                    if runner.lingered { messages.append(stream.lingerNote) }
                }
                let reply = live.messages.last(where: { $0.role == .assistant })?.text ?? live.lastReply ?? ""
                // A CLI that BotChu ended for staying on after its turn (#145) exits by a signal; its handoff stands.
                let reason = persistenceFailure ?? stream.outcome.failure ?? ((status != 0 && !runner.lingered || !stream.outcome.ended || reply.isEmpty)
                    ? "\(account.name) ended without a successful handoff (exit \(status)). \(TurnStream.lastLines(stderr))" : nil)
                let phase: SubagentPhase = persistenceFailure != nil ? .failed : runner.stopped ? .stopped : reason == nil ? .completed : .failed
                guard phase != .completed, persistenceFailure == nil else { self.finish(id, phase: phase, error: reason); return }
                // A session killed mid-tool can't always be continued (a call without its result): the
                // resumed run starts a new one with its brief, once (#368).
                if let delta, SubagentResume.startsANewSession(continuedSession: continued != nil, failed: phase == .failed,
                                                               toolCallsSinceLaunch: live.counts.tools - toolsAtLaunch) {
                    if let pending = self.usageCaptures.removeValue(forKey: id) { pending.capture.finish(.failed, in: pending.home, queue: self.archive.storage) }
                    live.messages.append(ChatMessage(role: .note, text: "Its session couldn't be continued, so it starts a new one with its brief."))
                    self.preparations[id] = Task { [weak self] in await self?.launch(id, targetBot: targetBot, resume: delta, session: false) }
                    return
                }
                // Ended without a handoff: what it left in its workspace goes into its outcome (#368).
                self.exiting.insert(id)
                let directory = record.workingDirectory
                Task { [weak self] in
                    let workspace = await SubagentWorkspaceState.read(directory, on: machine)
                    guard let self else { return }
                    self.exiting.remove(id)
                    self.finish(id, phase: phase, error: reason, workspace: workspace)
                }
            }
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

    /// Stops a run and the runs it delegated to; `cause` is what its outcome says stopped it (#368).
    func stop(_ id: UUID, cause: SubagentInterruption.Cause = .owner) {
        SubagentStopTree.stop(id, cause: cause, recordCause: { id, cause in
            if self.stopCauses[id] == nil, self.run(id)?.phase.isActive == true { self.stopCauses[id] = cause }
        }, exiting: { self.exiting.contains($0) }, children: { self.children(of: $0).filter { $0.phase.isActive }.map(\.id) }, stopRun: stopRun)
    }

    private func stopRun(_ id: UUID) {
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
        SubagentStopTree.stopRoot(root(target).runs) { stop($0, cause: $1) }
        for context in Array(contexts.values) where context.target == target { endCaller(context.id) }
    }

    func stopBot(_ id: UUID) {
        for record in all where record.phase.isActive && (record.rootBotID == id || record.targetBotID == id) { stop(record.id) }
        for context in Array(contexts.values) where context.target.botID == id { endCaller(context.id) }
    }

    /// Ends a caller once what it sent to the Inbox is in, so the end of its turn sees every delivery:
    /// those still in its mailbox (a helper that stopped waiting for its answer, or was stopped) are
    /// taken, and those being taken finish first. A job's run ends this way (#170).
    func finishCaller(_ id: UUID) async {
        guard let caller = contexts[id] else { return }
        let requests = watchers[id]?.requests
        requests?.cancel()
        // A cancelled receive may already be saving a delivery. Let it finish, then drain under
        // this uncancelled task so its durable result is acknowledged too. Liveness keeps running.
        if !caller.transport.machine.isRemote { await requests?.value }
        if caller.transport.machine.isRemote {
            _ = await takeFinalDeliveries((try? await caller.transport.poll()) ?? [], from: caller)
        } else {
            _ = try? await caller.transport.drainRequests { [weak self] envelopes in
                guard let self else { return false }
                return await self.takeFinalDeliveries(envelopes, from: caller)
            }
        }
        for _ in 0..<400 where contexts[id] != nil && !(receiving[id]?.isEmpty ?? true) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        endCaller(id)
    }

    private func takeFinalDeliveries(_ envelopes: [SubagentEnvelope], from caller: Caller) async -> Bool {
        let id = caller.id
        for envelope in envelopes where InboxRequest.isDelivery(envelope.data) {
            guard contexts[id] != nil, let fileID = UUID(uuidString: String(envelope.filename.dropLast(5))) else { continue }
            await receiveDelivery(envelope.data, id: fileID, filename: envelope.filename, from: caller)
        }
        return contexts[id] != nil
    }

    func endCaller(_ id: UUID) {
        guard let caller = contexts.removeValue(forKey: id) else { return }
        sensitiveInput.cancel(invocationID: id)
        let watcher = watchers.removeValue(forKey: id)
        watcher?.cancel()
        rejections[id] = nil
        receiving[id] = nil
        for record in root(caller.target).runs where record.callerInvocationID == id && record.phase.isActive { stop(record.id, cause: .parentEnded) }
        for runID in attached.removeValue(forKey: id) ?? [] where run(runID)?.callerInvocationID == id && run(runID)?.phase.isActive == true {
            stop(runID, cause: .parentEnded)
        }
        Task {
            // An in-flight local heartbeat must finish before writing the terminal heartbeat.
            await watcher?.settleWrites()
            try? await caller.transport.close()
        }
    }

    /// BotChu is quitting: what each run printed last goes into its transcript, and every
    /// checkpoint still waiting is written, so nothing streamed is lost. When the archive writes
    /// through the app's storage, quitting waits for it there (`AppModel.stopAll`).
    func stopAll() {
        for runner in Array(runners.values) { runner.flushOutput() }
        for pending in usageCaptures.values { pending.capture.finish(.stopped, in: pending.home, queue: archive.storage) }
        // Keep finished capture identities until each terminal callback consumes them; a run
        // cancelled before launch needs a fallback, but a flushed run must never get it twice.
        for record in all where record.phase.isActive { stop(record.id, cause: .restart) }
        for id in Array(contexts.keys) { endCaller(id) }
        archive.flush(timeout: archive.storage === model?.storage ? 0 : model?.quitTimeout ?? AppModel.saveTimeout)
    }

    /// Ends a run once its worker and every descendant have exited. Its end is saved off the main
    /// thread, and the run stays active until it is: the handoff goes back only once its record is
    /// durable, and one that can't be saved goes back as a failure.
    private func finish(_ id: UUID, phase: SubagentPhase, error: String?, workspace: SubagentWorkspaceState? = nil) {
        guard var record = run(id), record.phase.isActive, !finalizing.contains(id) else { return }
        let working = children(of: id).filter { $0.phase.isActive }
        if !working.isEmpty {
            pendingFinishes[id] = (phase, error)
            for child in working { stop(child.id, cause: phase == .stopped ? .parentStopped : .parentEnded) }
            return
        }
        pendingFinishes[id] = nil
        finalizing.insert(id)
        if let pending = usageCaptures.removeValue(forKey: id) {
            pending.capture.finish(phase == .completed ? .finished : phase == .stopped ? .stopped : .failed,
                                   in: pending.home, queue: archive.storage)
        } else if !restored.contains(id), let owner = model?.bot(record.rootBotID) {
            // Reserved runs can be stopped while admission is being saved, before launch creates
            // its capture. Their frozen profile still owns one explicitly unmeasured outcome.
            UsageLedger.append(.init(startedAt: record.startedAt ?? record.createdAt, kind: .subagent,
                botID: record.targetBotID, taskID: record.rootTaskID, subagentRunID: id,
                accountID: record.accountID, provider: record.account.kind, providerID: record.resolvedProvider,
                remote: record.hostID != nil, usesLegacyOpenRouterKey: record.usesLegacyOpenRouterKey(remote: record.hostID != nil),
                model: record.model.isEmpty ? nil : record.model, modelSource: record.model.isEmpty ? .unreported : .requested,
                outcome: phase == .stopped ? .stopped : phase == .completed ? .finished : .failed),
                in: BotHome(workspace: owner.persistencePath), queue: archive.storage)
        }
        record.phase = phase
        record.finishedAt = Date()
        record.errorMessage = error
        let live = live(id)
        record.handoffOutput = (live.messages.last(where: { $0.role == .assistant })?.text ?? live.lastReply).map(MemoryNotes.handoffText)
        var messages = live.messages
        SubagentTerminalOutcome.apply(to: &record, messages: &messages, toolCalls: live.counts.tools,
                                      cause: stopCauses.removeValue(forKey: id), workspace: workspace)
        recordGitFacts(&record, messages: messages)
        live.update { ThreadAssembler.closeRunningTools(&$0) }
        live.messages = messages
        live.state = nil
        preparations[id] = nil
        let reviewed = !restored.contains(id)
        // What the run asked to remember goes into the called bot's memory, which its Home hears
        // about; a save that fails waits to be tried again, and doesn't fail the handoff.
        if phase == .completed, let model, let targetBot = model.bot(record.targetBotID) {
            let start = live.historyStart, rootTaskID = record.rootTaskID
            let home = model.bot(record.rootBotID).map { BotHome(workspace: $0.workspace) }
            Task { [weak self, weak model] in
                guard let self, let model else { return }
                let prefix: [ChatMessage]
                if start > 0, let home {
                    prefix = (try? await archive.storage.perform(home.subagentURL(id: id, taskID: rootTaskID).path, label: "memory history") {
                        try home.loadSubagentHistory(id: id, taskID: rootTaskID, before: start, limit: start).messages
                    }) ?? []
                } else { prefix = [] }
                model.saveMemory(from: prefix + messages, of: targetBot, reportTo: .home(targetBot.id)) { [weak self] lines in
                    self?.commit(record, messages: messages + lines, reviewed: reviewed)
                }
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
            // The attempt joins the next run review of the bot it ran as; the handoff doesn't wait for one.
            if reviewed { self.model?.evaluateSubagentRun(record) }
            for (parent, outcome) in self.pendingFinishes where !self.children(of: parent).contains(where: { $0.phase.isActive }) {
                self.finish(parent, phase: outcome.0, error: outcome.1)
            }
            self.model?.sendNextQueued(to: ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID))
        }
        do {
            let snapshot = try snapshot(record, messages: messages)
            archive.save(snapshot) { [weak self] error in
                if error == nil { self?.lives[record.id]?.saved(snapshot) }
                done(error)
            }
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

    private func result(_ record: SubagentRun) -> SubagentResult { record.result }

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

    /// The worktree, branch and pull request its own transcript shows (#401), saved with each phase
    /// change. A run on this Mac has its `~` paths expanded.
    private func recordGitFacts(_ record: inout SubagentRun, messages: [ChatMessage]) {
        record.recordGitFacts(from: messages, home: record.hostID == nil ? NSHomeDirectory() : nil)
    }

    /// The run as it stands, with the folder of the bot that owns its records.
    private func snapshot(_ record: SubagentRun, messages: [ChatMessage]) throws -> SubagentArchive.Snapshot {
        guard let owner = model?.bot(record.rootBotID) else { throw DelegationFailure("The owning bot no longer exists.") }
        let live = lives[record.id]
        return SubagentArchive.Snapshot(record: record, messages: messages, home: BotHome(workspace: owner.workspace),
                                        start: live?.historyStart ?? 0, base: live?.base, pending: Array(live?.pending.values ?? [:].values))
    }


    /// What a relaunch finds: every conversation's runs, the transcripts of those left unfinished,
    /// and the runs whose caller on this Mac still waits for their handoff.
    private struct Restored: Sendable {
        var runs: [(target: ChatTarget, runs: [SubagentRun])] = []
        var threads: [UUID: [ChatMessage]] = [:]
        var awaiting: Set<UUID> = []
    }

    /// Every conversation's runs, from their records (also under closed tasks), read off the main
    /// thread in one pass, after the mailboxes that ended a day ago are deleted. A finished run's
    /// handoff goes back from its record while its caller still waits for it (a host's, always),
    /// and its transcript is read when it is shown. A run found unfinished is closed, once.
    private func restore() {
        guard let model else { return }
        let homes = model.bots.map { bot in
            (home: BotHome(workspace: bot.persistencePath), botID: bot.id,
             taskIDs: [nil] + (model.tasks[bot.id] ?? []).map { Optional($0.id) })
        }
        let ipc = SubagentIPC(root: root)
        archive.storage.submit(root.path, label: "restore", work: {
            ipc.prune()
            var found = Restored()
            for (home, botID, taskIDs) in homes {
                for taskID in taskIDs {
                    let runs = home.loadSubagents(taskID: taskID)
                    guard !runs.isEmpty else { continue }
                    found.runs.append((ChatTarget(botID: botID, taskID: taskID), runs))
                    for record in runs {
                        if record.phase.isActive { found.threads[record.id] = home.loadSubagentThread(id: record.id, taskID: taskID) }
                        if record.callerHostID == nil, let invocationID = record.callerInvocationID,
                           ipc.mailbox(invocationID).awaitsResult(record.id) {
                            found.awaiting.insert(record.id)
                        }
                    }
                }
            }
            return found
        }) { [weak self] result in
            if case .success(let found) = result { self?.restore(found) }
        }
    }

    private func restore(_ found: Restored) {
        guard let model, !model.terminating else { return }
        var interrupted: [SubagentRun] = []
        for (target, runs) in found.runs {
            // A run admitted while they were read stays as it is.
            let admitted = root(target).runs
            let restoring = runs.filter { run in !admitted.contains { $0.id == run.id } }
            setRuns(restoring + admitted, for: target)
            for record in restoring {
                if let invocationID = record.callerInvocationID {
                    let destination = model.settings.host(record.callerHostID)?.destination
                    if found.awaiting.contains(record.id) || destination != nil {
                        deliveries[record.id] = SubagentTransport(machine: Machine(destination: destination), namespace: namespace,
                                                                invocationID: invocationID, localRoot: root)
                    }
                }
                if record.phase.isActive { interrupted.append(record) } else { queueDelivery(record) }
            }
        }
        // Deepest first, so a parent closes once its children have, with the same reason.
        for record in interrupted.sorted(by: { $0.depth > $1.depth }) {
            restored.insert(record.id)
            let messages = found.threads[record.id] ?? []
            live(record.id).load(HistoryLoad(messages: messages, digest: ThreadDigest(messages), bytes: 0, reindexed: false))
            stopCauses[record.id] = .restart
            finish(record.id, phase: .stopped, error: "BotChu restarted before this sub-agent finished.")
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
                               work: { try home.loadSubagentHistory(id: id, taskID: taskID) }) { [weak self, weak live] result in
            guard let self, let live, self.lives[id] === live else { return }
            live.isReading = false
            guard !live.isLoaded, case .success(let history) = result else { return }
            live.load(history)
            self.budget.use(id, bytes: HistoryBudget<UUID>.estimate(history.messages))
            self.trimThreads()
        }
    }

    func pageEarlier(_ id: UUID, done: @escaping @MainActor () -> Void) {
        let live = live(id)
        guard !live.isReading, live.displayStart > 0, let record = run(id), let owner = model?.bot(record.rootBotID) else { return }
        live.isReading = true
        let home = BotHome(workspace: owner.workspace), end = live.displayStart
        archive.storage.submit(home.subagentURL(id: id, taskID: record.rootTaskID).path, label: "page",
                               work: { try home.loadSubagentHistory(id: id, taskID: record.rootTaskID, before: end, limit: PagedTranscript.pageSize) }) { [weak live] result in
            guard let live else { return }
            live.isReading = false
            guard live.displayStart == end, case .success(let page) = result else { return }
            live.browse(page)
            done()
        }
    }

    func pageLater(_ id: UUID, done: @escaping @MainActor () -> Void) {
        let live = live(id)
        guard !live.isReading, live.hasLaterPage, let page = live.browsing,
              let record = run(id), let owner = model?.bot(record.rootBotID) else { return }
        let home = BotHome(workspace: owner.workspace), end = page.start + page.messages.count
        if end >= live.historyStart {
            let messages = Array(live.messages.dropFirst(end - live.historyStart).prefix(PagedTranscript.pageSize))
            live.browseLater(HistoryLoad(messages: messages, digest: ThreadDigest([]), bytes: 0, reindexed: false, start: end))
            done()
            return
        }
        live.isReading = true
        archive.storage.submit(home.subagentURL(id: id, taskID: record.rootTaskID).path, label: "page",
                               work: { try home.loadSubagentHistory(id: id, taskID: record.rootTaskID,
                                        before: end + PagedTranscript.pageSize, limit: PagedTranscript.pageSize) }) { [weak live] result in
            guard let live else { return }
            live.isReading = false
            guard live.browsing?.start == page.start, case .success(let later) = result else { return }
            live.browseLater(later)
            done()
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
        guard let record = run(id), !record.phase.isActive, !finalizing.contains(id), !resuming.contains(id) else { return }
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

// MARK: Resuming interrupted runs (#368)

extension SubagentRuntime {
    /// The owner's Resume: relaunches the run with no caller waiting; its handoff stays with it until a
    /// turn collects it (`botchu-subagent wait <id>`). Why it didn't relaunch shows beside Resume.
    func resumeByOwner(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            let problem = await self.resume(id)
            if self.resumeProblems[id] != problem { self.resumeProblems[id] = problem }
        }
    }

    func isResuming(_ id: UUID) -> Bool { resuming.contains(id) }

    /// Relaunches an interrupted run with its brief, its session where its account can continue it,
    /// and its workspace, once no CLI of it or of the runs it started still runs; `caller` is the turn
    /// that asked, which then gets its handoff (nil for the owner's Resume). The one way a run that
    /// ended becomes active again. Returns why not.
    @discardableResult fileprivate func resume(_ id: UUID, by caller: Caller? = nil) async -> String? {
        guard let model, let record = run(id) else { return "That sub-agent run is gone." }
        if let problem = SubagentResume.problem(resuming: record) { return problem }
        guard !resuming.contains(id), !finalizing.contains(id), !exiting.contains(id), runners[id] == nil, preparations[id] == nil else {
            return "It is being resumed already."
        }
        // Its last result is still being handed back, which would clear where the next one goes.
        guard deliveryTasks[id] == nil else { return "It is still handing back its last result; resume it in a moment." }
        guard let targetBot = model.bot(record.targetBotID) else { return "\(record.targetBotName) is no longer in BotChu." }
        let machine: Machine
        if let hostID = record.hostID {
            guard let host = model.settings.host(hostID) else { return "Its host is no longer configured." }
            machine = Machine(destination: host.destination)
        } else { machine = .thisMac }
        resuming.insert(id)
        defer { resuming.remove(id) }
        return await SubagentResumeTransaction.run(ids: [id] + descendants(of: id).map(\.id), place: machine.destination ?? "this Mac",
            processes: { await SubagentLiveness.processes(marked: $0, on: machine) },
            workspace: { await SubagentWorkspaceState.read(record.workingDirectory, on: machine) },
            load: {
                guard let owner = model.bot(record.rootBotID) else { throw SubagentResumeTransaction.Problem("Its conversation's bot is no longer in BotChu.") }
                let live = self.live(id)
                if !live.isLoaded {
                    let home = BotHome(workspace: owner.workspace), taskID = record.rootTaskID
                    let history = try await self.archive.storage.perform(home.subagentURL(id: id, taskID: taskID).path, label: "resume") {
                        try home.loadSubagentHistory(id: id, taskID: taskID)
                    }
                    if !live.isLoaded { live.load(history) }
                }
            }, validate: { stage in
                SubagentResumeTransaction.problem(current: self.run(id), finalizing: stage == .loaded && self.finalizing.contains(id),
                    running: self.runners[id] != nil, preparing: self.preparations[id] != nil,
                    callerAlive: caller.map { self.contexts[$0.id] != nil } ?? true)
            }, prepare: { workspace in
                // The transaction just validated this record, with no suspension before this snapshot.
                let current = self.run(id)!
                let delta = SubagentResume.delta(for: current, workspace: workspace,
                    interruptedChildren: self.children(of: id).filter(\.isResumable), session: current.resumableSessionID != nil)
                var resumed = current
                resumed.phase = .preparing
                resumed.startedAt = nil
                resumed.finishedAt = nil
                resumed.errorMessage = nil
                resumed.handoffOutput = nil
                if let caller {
                    resumed.callerInvocationID = caller.id
                    resumed.callerHostID = caller.hostID
                }
                let by = caller.map { caller in caller.parent.flatMap { self.run($0)?.targetBotName } ?? model.bot(caller.target.botID)?.name ?? "its caller" } ?? "the owner"
                let messages = self.live(id).messages + [ChatMessage(role: .note, text: "Resumed by \(by)."), ChatMessage(role: .user, text: delta)]
                self.recordGitFacts(&resumed, messages: messages)
                return (snapshot: try self.snapshot(resumed, messages: messages), delta: delta)
            }, save: { try await self.archive.save($0.snapshot) }, replace: { prepared in
                let live = self.live(id)
                live.messages = prepared.snapshot.messages
                self.replace(prepared.snapshot.record)
                self.resumeProblems[id] = nil
                self.deliveries[id] = caller?.transport
                if let caller, ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID) != caller.target {
                    self.attached[caller.id, default: []].insert(id)
                }
                live.state = RunState(preparing: true)
                self.preparations[id] = Task { [weak self] in await self?.launch(id, targetBot: targetBot, resume: prepared.delta) }
            })
    }

    /// Every run beneath this one.
    fileprivate func descendants(of id: UUID) -> [SubagentRun] {
        var found: [SubagentRun] = [], next = [id], seen: Set<UUID> = [id]
        while let current = next.popLast(), found.count < 256 {
            for child in children(of: current) where seen.insert(child.id).inserted {
                found.append(child)
                next.append(child.id)
            }
        }
        return found
    }

    fileprivate func context(_ caller: Caller) -> SubagentCallerContext {
        SubagentCallerContext(invocationID: caller.id, botID: caller.target.botID, taskID: caller.target.taskID,
                              parentSubagentID: caller.parent, depth: caller.depth, workingDirectory: caller.directory, hostID: caller.hostID)
    }

    /// Takes a `botchu-subagent resume <id>` request: from the turn that may (`SubagentResume`), it
    /// relaunches the run, whose handoff then comes to that turn; the answer says whether it did.
    /// It's taken at once and answered once the run's checks are done, so the mailbox goes on meanwhile.
    fileprivate func receiveResume(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        let named = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["runID"] as? String
        let runID = named.flatMap(UUID.init(uuidString:)) ?? id
        let request: SubagentResumeRequest
        do {
            request = try SubagentResumeRequest.parse(data)
            guard request.id == id else { throw InboxRequest.Problem("the request's ID doesn't match its file") }
            try request.validate(context(caller), now: caller.transport.machine.isRemote ? nil : Date())
            guard contexts[caller.id] != nil else { throw InboxRequest.Problem("the asking turn has ended") }
        } catch {
            await answer(SubagentResumeAnswer(id: id, runID: runID, refused: (error as? InboxRequest.Problem)?.message ?? error.localizedDescription), to: caller)
            try? await caller.transport.acknowledge(filename: filename)
            return
        }
        try? await caller.transport.acknowledge(filename: filename)
        Task { [weak self] in
            guard let self else { return }
            let problem: String?
            if let record = self.run(runID), let refused = SubagentResume.problem(collecting: record, by: self.context(caller)) ?? SubagentResume.problem(resuming: record) {
                problem = refused
            } else if self.run(runID) == nil {
                problem = "No sub-agent run \(runID.uuidString.lowercased()) that this turn can resume or collect."
            } else {
                problem = await self.resume(runID, by: caller)
            }
            await self.answer(problem.map { SubagentResumeAnswer(id: id, runID: runID, refused: $0) }
                              ?? SubagentResumeAnswer(id: id, runID: runID, resumed: true), to: caller)
        }
    }

    fileprivate func answer(_ answer: SubagentResumeAnswer, to caller: Caller) async {
        do { try await caller.transport.writeResult(id: answer.id, data: SubagentIPC.encode(answer)) }
        catch { if isWatching(caller.id) { report("Couldn't answer a resume request: \(error.localizedDescription)") } }
    }

    /// Takes the runs a later turn's `botchu-subagent wait` names that its mailbox knows nothing of:
    /// each one this turn may collect (`SubagentResume`) sends its handoff here, now if it has ended,
    /// else when it does; any other gets a failure saying so, in this mailbox alone.
    fileprivate func receiveAttach(_ data: Data, id: UUID, filename: String, from caller: Caller) async {
        if let request = try? SubagentAttachRequest.parse(data), request.id == id,
           (try? request.validate(context(caller), now: caller.transport.machine.isRemote ? nil : Date())) != nil,
           contexts[caller.id] != nil {
            for runID in request.runIDs { await attach(runID, to: caller) }
        }
        try? await caller.transport.acknowledge(filename: filename)
    }

    private func attach(_ runID: UUID, to caller: Caller) async {
        func fail(_ message: String) async {
            let failed = SubagentResult(id: runID, targetBotName: "Sub-agent", phase: .failed, errorMessage: message)
            try? await caller.transport.writeResult(id: runID, data: SubagentIPC.encode(failed))
        }
        guard let record = run(runID), SubagentResume.problem(collecting: record, by: context(caller)) == nil else {
            await fail("No sub-agent run \(runID.uuidString.lowercased()) that this turn can resume or collect.")
            return
        }
        if record.callerInvocationID == caller.id { return }
        guard record.phase.isActive || finalizing.contains(runID) else {
            try? await caller.transport.writeResult(id: runID, data: SubagentIPC.encode(record.result))
            return
        }
        if let waiting = record.callerInvocationID, contexts[waiting] != nil {
            await fail("\(runID.uuidString.lowercased()) is under way, and the turn that started it waits for it.")
            return
        }
        modify(runID) {
            $0.callerInvocationID = caller.id
            $0.callerHostID = caller.hostID
        }
        deliveries[runID] = caller.transport
        if ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID) != caller.target { attached[caller.id, default: []].insert(runID) }
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
            if let reply = messages.last(where: { $0.role == .assistant })?.text { lastReply = reply }
            tally.update(messages)
            let total = ToolCounts(tools: prefixCounts.tools + tally.counts.tools, shell: prefixCounts.shell + tally.counts.shell)
            if total != counts { counts = total }
        }
    }
    @ObservationIgnored private(set) var lastReply: String?
    private(set) var historyStart = 0
    @ObservationIgnored private(set) var pending: [UUID: PagedTranscript.Pending] = [:]
    @ObservationIgnored private(set) var base: [ChatMessage] = []
    @ObservationIgnored private var prefixCounts = ToolCounts()
    private(set) var browsing: HistoryLoad?
    var displayMessages: [ChatMessage] {
        let tail = messages
        guard let browsing else { return tail }
        let latest = Dictionary(tail.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return browsing.messages.map { latest[$0.id] ?? pending[$0.id]?.message ?? $0 }
    }
    var displayStart: Int { browsing?.start ?? historyStart }
    var hasLaterPage: Bool { browsing.map { $0.start + $0.messages.count < historyStart + messages.count } ?? false }

    func load(_ history: HistoryLoad) {
        historyStart = history.start
        lastReply = history.digest.lastReply
        prefixCounts = ToolCounts(tools: history.prefix.summary.toolCallCount, shell: history.prefix.shellCount)
        messages = history.messages
        base = messages
    }

    func browse(_ history: HistoryLoad) {
        var page = history
        page.messages = Array((page.messages + displayMessages).prefix(PagedTranscript.browsingLimit))
        browsing = page
    }

    func pinDisplay() {
        guard browsing == nil, !messages.isEmpty else { return }
        let shown = Array(messages.suffix(PagedTranscript.browsingLimit))
        browsing = HistoryLoad(messages: shown, digest: ThreadDigest([]), bytes: 0, reindexed: false,
                               start: historyStart + messages.count - shown.count)
    }

    func showLatest() { browsing = nil }

    func browseLater(_ page: HistoryLoad) {
        guard var current = browsing else { return }
        let end = current.start + current.messages.count
        current.messages += page.messages.dropFirst(max(0, end - page.start))
        let drop = max(0, current.messages.count - PagedTranscript.browsingLimit)
        current.messages.removeFirst(drop)
        current.start += drop
        browsing = current
    }

    func saved(_ snapshot: SubagentArchive.Snapshot) {
        for update in snapshot.pending {
            guard var current = pending[update.message.id] else { continue }
            current.base = update.message
            if let index = browsing?.messages.firstIndex(where: { $0.id == update.message.id }) {
                browsing?.messages[index] = update.message
            }
            pending[update.message.id] = current.message == update.message && current.message.toolState != .running ? nil : current
        }
        guard historyStart == snapshot.start else { return }
        base = snapshot.messages
        let safe = min(snapshot.messages.count, messages.count) - PagedTranscript.residentLimit
        let keep = max(0, safe)
        guard keep > 0, messages.prefix(keep).elementsEqual(snapshot.messages.prefix(keep)) else { return }
        if var page = browsing {
            let committed = Dictionary(messages.prefix(keep).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            page.messages = page.messages.map { committed[$0.id] ?? $0 }
            browsing = page
        }
        for (offset, message) in messages.prefix(keep).enumerated() where message.toolState == .running {
            pending[message.id] = .init(position: historyStart + offset, message: message)
        }
        let counts = ToolCounts(messages: Array(messages.prefix(keep)))
        prefixCounts.tools += counts.tools
        prefixCounts.shell += counts.shell
        historyStart += keep
        base.removeFirst(keep)
        messages.removeFirst(keep)
    }

    /// Whether the transcript is in memory: a finished run's, restored after a relaunch, is read
    /// when shown (`SubagentRuntime.readThread`); one dropped again keeps its counts.
    @ObservationIgnored private(set) var isLoaded = false
    @ObservationIgnored private(set) var wasCounted = false
    @ObservationIgnored var isReading = false

    fileprivate func unload() {
        let kept = counts
        tally = ToolCallTally()
        prefixCounts = ToolCounts()
        base = []
        pending = [:]
        browsing = nil
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
        if pending.isEmpty { change(&messages) }
        else {
            let held = pending.values.sorted { $0.position < $1.position }
            var working = held.map(\.message) + messages
            change(&working)
            let ids = Set(held.map { $0.message.id })
            for message in working where ids.contains(message.id) {
                if let prior = pending[message.id]?.message {
                    prefixCounts.shell += ToolCounts(messages: [message]).shell - ToolCounts(messages: [prior]).shell
                }
                pending[message.id]?.message = message
            }
            messages = working.filter { !ids.contains($0.id) }
        }
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
