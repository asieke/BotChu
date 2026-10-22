import Foundation
import Observation
import BotChuCore

/// Owns the short-lived delegation sessions. The selected conversation never owns a process:
/// requests are bound to the invocation that created them, even while the owner navigates away.
@MainActor @Observable
final class SubagentRuntime {
    var records: [ChatTarget: [SubagentRun]] = [:]
    var threads: [UUID: [ChatMessage]] = [:]
    var states: [UUID: RunState] = [:]
    var error: String?
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let root: URL
    @ObservationIgnored let namespace: UUID
    @ObservationIgnored private var contexts: [UUID: Caller] = [:]
    @ObservationIgnored private var runners: [UUID: AgentRun] = [:]
    @ObservationIgnored private var preparations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var deliveries: [UUID: SubagentTransport] = [:]
    @ObservationIgnored private var deliveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var rejections: [UUID: [UUID: SubagentResult]] = [:]
    @ObservationIgnored private var pendingFinishes: [UUID: (SubagentPhase, String?)] = [:]
    @ObservationIgnored private var requestCounts: [ChatTarget: Int] = [:]

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

    init(model: AppModel, root: URL) {
        self.model = model
        self.root = root
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

    var roster: [BotRosterEntry] { (model?.bots ?? []).map { BotRosterEntry(bot: $0) } }
    var all: [SubagentRun] { records.values.flatMap { $0 } }
    func run(_ id: UUID) -> SubagentRun? { all.first { $0.id == id } }
    func activeCount(_ target: ChatTarget, includeTasks: Bool = false) -> Int {
        all.filter { $0.rootBotID == target.botID && (includeTasks || $0.rootTaskID == target.taskID) && $0.phase.isActive }.count
    }
    func usesBot(_ id: UUID) -> Bool {
        all.contains { $0.phase.isActive && ($0.rootBotID == id || $0.targetBotID == id) }
    }

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

    private func startWatcher(_ caller: Caller) {
        watchers[caller.id] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await caller.transport.heartbeat()
                    let envelopes = try await caller.transport.poll()
                    guard let self, self.contexts[caller.id] != nil, !Task.isCancelled else { break }
                    for envelope in envelopes {
                        await self.receive(envelope.data, filename: envelope.filename, from: caller)
                    }
                    for record in self.all where record.callerInvocationID == caller.id && record.phase.isActive {
                        let status = SubagentStatus(id: record.id, phase: record.phase,
                                                   activity: self.states[record.id]?.activity.doing ?? "Preparing…")
                        try await caller.transport.writeStatus(id: record.id, data: SubagentIPC.encode(status))
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.contexts[caller.id] != nil else { break }
                    self.error = "Sub-agent connection: \(error.localizedDescription)"
                }
                do { try await Task.sleep(for: .milliseconds(caller.transport.machine.isRemote ? 750 : 250)) }
                catch { break }
            }
        }
    }

    private func receive(_ data: Data, filename: String, from caller: Caller) async {
        // A file is acknowledged only after its admission or failure has been persisted.
        guard let fileID = UUID(uuidString: String(filename.dropLast(5))) else {
            try? await caller.transport.acknowledge(filename: filename)
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
            guard all.filter({ $0.phase.isActive }).count < 12 else { throw DelegationFailure("Twelve sub-agents are already running. Wait for one to finish before trying again.") }
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
            try persist(record, messages: [ChatMessage(role: .user, text: request.brief)])
            records[caller.target, default: []].append(record)
            threads[record.id] = [ChatMessage(role: .user, text: request.brief)]
            states[record.id] = RunState(preparing: true)
            deliveries[record.id] = caller.transport
            requestCounts[caller.target, default: 0] += 1
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
                soul: Workspace.read(targetBot.workspace + "/SOUL.md"), availableBots: roster)
            var invocation = CommandBuilder.invocation(kind: account.kind, prompt: prompt,
                model: GenerationOptions.effectiveModel(record.model, kind: account.kind, openRouterDefault: model.settings.openRouterModel),
                sessionID: nil, reasoningEffort: record.reasoningEffort, openRouterKey: key)
            invocation.environment.merge(context.environment) { _, new in new }
            let command = model.settings.host(record.hostID)?.command(for: account) ?? model.settings.command(for: account)
            let runner = machine.isRemote
                ? AgentRun(command: command, invocation: invocation, on: machine, folder: record.workingDirectory)
                : AgentRun(command: command, invocation: invocation, directory: URL(fileURLWithPath: record.workingDirectory))
            var parser = StreamParsers.make(for: account.kind)
            var assembler = ThreadAssembler()
            var finished = false
            var failure: String?
            var persistenceFailure: String?
            runner.onLines = { [weak self, weak runner] lines in
                guard let self, let runner, self.runners[id] === runner, self.run(id)?.phase.isActive == true else { return }
                var messages = self.threads[id] ?? []
                self.states[id]?.hasOutput = true
                for line in lines {
                    for event in parser.parse(line: line) {
                        switch event {
                        case .session(let session):
                            self.modify(id) { $0.sessionID = CommandBuilder.resumeID(kind: account.kind, invocation: invocation, reported: session) }
                        case .finished: finished = true
                        case .failed(let reason): failure = reason
                        default: break
                        }
                        if let activity = BotActivity.next(after: event) { _ = self.states[id]?.move(to: activity) }
                        self.states[id]?.settle()
                        assembler.apply(event, to: &messages)
                    }
                }
                self.threads[id] = messages
                if let record = self.run(id) {
                    do { try self.persist(record, messages: messages) }
                    catch {
                        if persistenceFailure == nil {
                            persistenceFailure = "Couldn't save the sub-agent transcript: \(error.localizedDescription)"
                            self.stop(id)
                        }
                    }
                }
            }
            runner.onExit = { [weak self, weak runner] status, stderr in
                guard let self, let runner, self.runners[id] === runner else { return }
                self.runners[id] = nil
                self.endCaller(context.id)
                guard self.run(id)?.phase.isActive == true else { return }
                var messages = self.threads[id] ?? []
                assembler.apply(.textEnd, to: &messages)
                ThreadAssembler.closeRunningTools(&messages)
                self.threads[id] = messages
                let reply = messages.last(where: { $0.role == .assistant })?.text ?? ""
                let reason = persistenceFailure ?? failure ?? ((status != 0 || !finished || reply.isEmpty)
                    ? "\(account.name) ended without a successful handoff (exit \(status)). \(AppModel.lastLines(stderr))" : nil)
                self.finish(id, phase: persistenceFailure != nil ? .failed : runner.stopped ? .stopped : reason == nil ? .completed : .failed, error: reason)
            }
            record.phase = .running
            record.startedAt = Date()
            try persist(record, messages: threads[id] ?? [])
            replace(record)
            runners[id] = runner
            states[id] = RunState()
            try runner.start()
            preparations[id] = nil
        } catch {
            for context in Array(contexts.values) where context.parent == id { endCaller(context.id) }
            runners[id] = nil
            finish(id, phase: error is CancellationError ? .stopped : .failed, error: error.localizedDescription)
        }
    }

    func stop(_ id: UUID) {
        for child in all where child.parentSubagentID == id && child.phase.isActive { stop(child.id) }
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
        for record in all where record.rootBotID == target.botID && record.rootTaskID == target.taskID && record.phase.isActive { stop(record.id) }
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
        for record in all where record.callerInvocationID == id && record.phase.isActive { stop(record.id) }
        Task { try? await caller.transport.close() }
    }

    func stopAll() {
        for record in all where record.phase.isActive { stop(record.id) }
        for id in Array(contexts.keys) { endCaller(id) }
    }

    private func finish(_ id: UUID, phase: SubagentPhase, error: String?) {
        guard var record = run(id), record.phase.isActive else { return }
        let children = all.filter { $0.parentSubagentID == id && $0.phase.isActive }
        if !children.isEmpty {
            pendingFinishes[id] = (phase, error)
            for child in children { stop(child.id) }
            return
        }
        pendingFinishes[id] = nil
        record.phase = phase
        record.finishedAt = Date()
        record.errorMessage = error
        record.handoffOutput = threads[id]?.last(where: { $0.role == .assistant }).map { MemoryNotes.handoffText($0.text) }
        var messages = threads[id] ?? []
        ThreadAssembler.closeRunningTools(&messages)
        if let error { messages.append(ChatMessage(role: phase == .stopped ? .note : .error, text: error)) }
        threads[id] = messages
        states[id] = nil
        preparations[id] = nil
        do {
            if phase == .completed, let targetBot = model?.bot(record.targetBotID) {
                let notes = MemoryNotes.remembered(in: messages)
                try MemoryNotes.append(notes, toMemoryAt: targetBot.workspace + "/MEMORY.md")
            }
            try persist(record, messages: messages)
        }
        catch {
            record.phase = .failed
            record.errorMessage = "Couldn't save the handoff: \(error.localizedDescription)"
            self.error = record.errorMessage
        }
        replace(record)
        queueDelivery(record)
        for (parent, outcome) in pendingFinishes where !all.contains(where: { $0.parentSubagentID == parent && $0.phase.isActive }) {
            finish(parent, phase: outcome.0, error: outcome.1)
        }
        model?.sendNextQueued(to: ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID))
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
        let target = ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID)
        if let index = records[target]?.firstIndex(where: { $0.id == record.id }) { records[target]?[index] = record }
    }
    private func modify(_ id: UUID, _ edit: (inout SubagentRun) -> Void) {
        guard var record = run(id) else { return }
        edit(&record)
        replace(record)
    }
    private func persist(_ record: SubagentRun, messages: [ChatMessage]) throws {
        guard let owner = model?.bot(record.rootBotID) else { throw DelegationFailure("The owning bot no longer exists.") }
        let home = BotHome(workspace: owner.workspace)
        try home.saveSubagentThread(messages, id: record.id, taskID: record.rootTaskID)
        try home.saveSubagent(record)
    }

    private func restore() {
        guard let model else { return }
        for bot in model.bots {
            let home = BotHome(workspace: bot.workspace)
            for taskID in [nil] + (model.tasks[bot.id] ?? []).map({ Optional($0.id) }) {
                let target = ChatTarget(botID: bot.id, taskID: taskID)
                records[target] = home.loadSubagents(taskID: taskID)
                for record in records[target] ?? [] {
                    threads[record.id] = home.loadSubagentThread(id: record.id, taskID: taskID)
                    if let invocationID = record.callerInvocationID {
                        let destination = model.settings.host(record.callerHostID)?.destination
                        if record.callerHostID == nil || destination != nil {
                            deliveries[record.id] = SubagentTransport(machine: Machine(destination: destination), namespace: namespace,
                                                                    invocationID: invocationID, localRoot: root)
                        }
                    }
                    if record.phase.isActive {
                        finish(record.id, phase: .stopped, error: "BotChu restarted before this sub-agent finished.")
                    } else { queueDelivery(record) }
                }
            }
        }
    }

    func clear(_ id: UUID) {
        guard let record = run(id), !record.phase.isActive else { return }
        let children = all.filter { $0.parentSubagentID == id }
        guard !children.contains(where: { $0.phase.isActive }) else { return }
        for child in children { clear(child.id) }
        guard let owner = model?.bot(record.rootBotID) else { return }
        let home = BotHome(workspace: owner.workspace)
        do {
            try home.removeSubagent(id: id, taskID: record.rootTaskID)
            let target = ChatTarget(botID: record.rootBotID, taskID: record.rootTaskID)
            records[target]?.removeAll { $0.id == id }
            threads[id] = nil
        } catch { self.error = "Couldn't clear the sub-agent: \(error.localizedDescription)" }
    }
}

private struct DelegationFailure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
