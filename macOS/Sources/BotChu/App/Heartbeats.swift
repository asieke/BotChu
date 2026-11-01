import Foundation
import BotChuCore

/// A heartbeat a conversation waits to send (`Heartbeat`, #261).
struct PendingHeartbeat {
    let id = UUID()
    let number: Int
    let stall: Heartbeat.Stall
    /// The conversation's last message (BotChu's notes aside) when the heartbeat was planned: once
    /// there is a newer one, the conversation has moved on without it.
    let after: UUID?
    /// The failure a retry follows (`.failed`).
    var error: String? = nil
    /// After a usage limit reset (`.limitReset`, #442): whether the conversation's own turn had
    /// paused, and the runs BotChu resumed.
    var turnPaused = false
    var resumed: [SubagentRun] = []
}

extension AppModel {
    /// After a turn of Home or a task: plans the heartbeat that checks on work the turn left
    /// unfinished, retries a failed turn once, pauses one that hit a usage limit until it resets,
    /// or says BotChu stopped checking in, as `Heartbeat.next` decides. `error` is a failed turn's.
    func scheduleHeartbeat(after turn: Heartbeat.Turn, in target: ChatTarget, error: String? = nil) {
        pendingHeartbeats[target] = nil
        endLimitPause(target)
        guard settings.heartbeat, bot(target.botID)?.isRemoteQueue == false else { return }
        switch Heartbeat.next(after: turn) {
        case .none:
            return
        case .gaveUp:
            append(ChatMessage(role: .note, text: Heartbeat.gaveUp), to: target)
            saveThread(target)
        case let .paused(until, resume):
            append(ChatMessage(role: .note, text: UsageLimit.pausedText(until: until)), to: target)
            saveThread(target)
            limitPauses.pause(.init(botID: target.botID, taskID: target.taskID, resetsAt: until, resumeAt: resume))
            saveLimitPauses()
            scheduleLimitWake()
        case let .pulse(number, delay, stall):
            let pending = PendingHeartbeat(number: number, stall: stall, after: lastMessageID(target), error: error)
            pendingHeartbeats[target] = pending
            wake(pending, in: target, after: delay)
        }
    }

    private func wake(_ pending: PendingHeartbeat, in target: ChatTarget, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendHeartbeat(pending.id, to: target)
        }
    }

    /// Sends the heartbeat the conversation still waits to send, once nothing runs there. A Home
    /// waits for its running tasks too: what it said would go on is usually theirs. After a usage
    /// limit reset it goes out even when the conversation moved on meanwhile, after any messages
    /// waiting in its queue, since the runs it names wait for it to collect them.
    private func sendHeartbeat(_ id: UUID, to target: ChatTarget) {
        guard let pending = pendingHeartbeats[target], pending.id == id else { return }
        guard settings.heartbeat, bot(target.botID) != nil, target.taskID == nil || task(target)?.isArchived == false else {
            pendingHeartbeats[target] = nil
            return
        }
        let tasksRun = target.taskID == nil && openTasks(of: target.botID).contains { isRunning(.task($0.id, of: target.botID)) }
        if isRunning(target) || tasksRun {
            wake(pending, in: target, after: 60)
            return
        }
        hydrate(target, then: { [weak self] in
            guard let self, self.pendingHeartbeats[target]?.id == id else { return }
            self.pendingHeartbeats[target] = nil
            guard !self.isRunning(target) else { return }
            if pending.stall == .limitReset {
                self.send(Heartbeat.limitPrompt(turnPaused: pending.turnPaused, resumed: pending.resumed), to: target, heartbeat: pending.number)
                return
            }
            guard self.lastMessageID(target) == pending.after, self.messageQueues[target]?.messages.isEmpty != false else { return }
            self.send(Heartbeat.prompt(pending.stall, number: pending.number, error: pending.error), to: target, heartbeat: pending.number)
        })
    }

    private func lastMessageID(_ target: ChatTarget) -> UUID? {
        thread(target).last { !$0.role.isNote }?.id
    }

    // MARK: Usage limits (#442)

    static let limitPausesFile = "limit-pauses.json"
    private static let limitPauseWrites = DispatchQueue(label: "BotChu.limit-pauses", qos: .utility)

    /// A message to a conversation whose turn paused on a usage limit starts a turn of its own,
    /// which pauses again if the limit still holds.
    func endLimitPause(_ target: ChatTarget) {
        guard limitPauses.clear(botID: target.botID, taskID: target.taskID) else { return }
        saveLimitPauses()
        scheduleLimitWake()
    }

    /// A run paused on a usage limit, also one BotChu resumed before that hit it again.
    func runPaused(_ id: UUID) {
        limitTried.remove(id)
        scheduleLimitWake()
    }

    private func saveLimitPauses() {
        let book = limitPauses, url = store.root.appendingPathComponent(Self.limitPausesFile)
        Self.limitPauseWrites.async { try? book.save(url) }
    }

    /// Plans the wake for the next paused turn or run (`LimitResume`), on the wall clock, so a Mac
    /// asleep at the reset carries on once it wakes. Called when a pause starts or ends, and once
    /// the runs are restored after a launch.
    func scheduleLimitWake() {
        guard settings.heartbeat, let next = LimitResume.nextWake(book: limitPauses, runs: delegation?.all ?? [], tried: limitTried) else { return }
        let token = UUID()
        limitWakeToken = token
        let delay = max(5, next.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay) { [weak self] in
            guard let self, self.limitWakeToken == token else { return }
            self.carryOnAfterLimits()
        }
    }

    /// The limits that paused turns and runs have reset: each conversation's paused runs are
    /// resumed in their worktrees with their sessions, then the conversation hears one heartbeat
    /// naming them. A run is tried once per launch; why it couldn't resume shows beside Resume.
    private func carryOnAfterLimits() {
        limitWakeToken = nil
        guard settings.heartbeat, let delegation else {
            if !settings.heartbeat, !limitPauses.entries.isEmpty {
                limitPauses = LimitPauseBook()
                saveLimitPauses()
            }
            return
        }
        limitPauses.prune { botID, taskID in bot(botID) != nil && (taskID.map { task($0, of: botID)?.isArchived == false } ?? true) }
        let due = LimitResume.due(book: &limitPauses, runs: delegation.all, tried: limitTried, now: Date().addingTimeInterval(1))
        saveLimitPauses()
        for item in due {
            // What runs beneath a resumed run is its own to resume.
            for id in item.runs { limitTried.formUnion([id] + delegation.descendantIDs(of: id)) }
            let target = ChatTarget(botID: item.botID, taskID: item.taskID)
            Task { [weak self] in
                guard let self else { return }
                let resumed = await delegation.resumePaused(item.runs)
                self.queueLimitHeartbeat(target, turnPaused: item.turnPaused, resumed: resumed)
            }
        }
        scheduleLimitWake()
    }

    private func queueLimitHeartbeat(_ target: ChatTarget, turnPaused: Bool, resumed: [SubagentRun]) {
        guard turnPaused || !resumed.isEmpty, settings.heartbeat, bot(target.botID)?.isRemoteQueue == false,
              target.taskID == nil || task(target)?.isArchived == false else { return }
        let pending = PendingHeartbeat(number: 1, stall: .limitReset, after: nil, turnPaused: turnPaused, resumed: resumed)
        pendingHeartbeats[target] = pending
        wake(pending, in: target, after: 0)
    }
}
