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
}

extension AppModel {
    /// After a turn of Home or a task: plans the heartbeat that checks on work the turn left
    /// unfinished, or says BotChu stopped checking in, as `Heartbeat.next` decides.
    func scheduleHeartbeat(after turn: Heartbeat.Turn, in target: ChatTarget) {
        pendingHeartbeats[target] = nil
        guard settings.heartbeat, bot(target.botID)?.isRemoteQueue == false else { return }
        switch Heartbeat.next(after: turn) {
        case .none:
            return
        case .gaveUp:
            append(ChatMessage(role: .note, text: Heartbeat.gaveUp), to: target)
            saveThread(target)
        case let .pulse(number, delay, stall):
            let pending = PendingHeartbeat(number: number, stall: stall, after: lastMessageID(target))
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
    /// waits for its running tasks too: what it said would go on is usually theirs.
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
            guard self.lastMessageID(target) == pending.after, self.messageQueues[target]?.messages.isEmpty != false,
                  !self.isRunning(target) else { return }
            self.send(Heartbeat.prompt(pending.stall, number: pending.number), to: target, heartbeat: pending.number)
        })
    }

    private func lastMessageID(_ target: ChatTarget) -> UUID? {
        thread(target).last { !$0.role.isNote }?.id
    }
}
