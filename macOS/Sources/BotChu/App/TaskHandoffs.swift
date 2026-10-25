import Foundation
import BotChuCore

/// Tasks one conversation hands to a bot with `botchu-task create` (#111): an independent Task under
/// that bot, a tab beside its chat, on its identity and account, which goes on whatever becomes of
/// the conversation that asked. A sub-agent run (`SubagentRuntime`) is the other kind of handoff.
extension AppModel {
    struct Handoff {
        var bot: Bot
        var task: BotTask
        /// The Task the same request made before, rather than a new one.
        var existing: Bool
        /// Why the new Task's record couldn't be saved; it is in the sidebar all the same.
        var unsaved: String?
    }

    /// Makes the Task `handoff` asks for under the bot it names and starts it, or finds the one the
    /// same request made before (`TaskHandoff.key`); throws why it can't. Returns once the Task's
    /// record is saved (or couldn't be), with a receipt that opens it in `caller`, the conversation
    /// that asked (`subagent`, when a sub-agent run there asked).
    func handOffTask(_ handoff: TaskHandoff, from caller: ChatTarget, subagent: SubagentRun?) async throws -> Handoff {
        let named = try resolveTaskBot(handoff.request.agent ?? "")
        let key = handoff.key(for: named.id)
        func made() -> BotTask? { tasks[named.id]?.first { $0.requestedBy?.key == key } }
        if let task = made() { return Handoff(bot: named, task: task, existing: true) }
        let root = settings.expandedReposRoot
        // Off the main thread: the first look into ~/Desktop or ~/Documents waits on macOS's question.
        let checkouts = await Task.detached { Repositories.scan(root: root) }.value
        await loadRepositories()
        // The same request, asked again meanwhile, may have made it.
        if let task = made() { return Handoff(bot: named, task: task, existing: true) }
        guard let owner = bot(named.id), let asking = bot(caller.botID) else {
            throw TaskRequest.Problem(message: "the bot was deleted meanwhile")
        }
        var task = try await plannedTask(handoff.request, for: owner, checkouts: checkouts, origin: .agent)
        // Looking up a host's name can wait, and the same request may have made it meanwhile.
        if let task = made() { return Handoff(bot: named, task: task, existing: true) }
        let place = caller.taskID.flatMap { self.task($0, of: caller.botID) }.map { "\(asking.name)'s task \($0.title)" }
            ?? "\(asking.name)'s Home"
        task.requestedBy = BotTask.Requester(name: subagent?.targetBotName ?? asking.name, botID: asking.id, taskID: caller.taskID,
                                             subagentID: subagent?.id, conversation: subagent == nil ? place : "a sub-agent run in \(place)",
                                             key: key)
        let failure: String? = await withCheckedContinuation { continuation in
            startTask(task, for: owner.id, show: false) { continuation.resume(returning: $0?.localizedDescription) }
        }
        postReceipt(TaskReceipt.handedOff(task, to: owner.name), task: task.id, of: owner.id, in: caller)
        return Handoff(bot: owner, task: task, existing: false,
                       unsaved: failure.map { "\(task.title) is in BotChu under \(owner.name), but its record couldn't be saved: \($0)" })
    }
}
