import Foundation
import BotChuCore

/// Work one conversation hands to a bot with `botchu-task create` (#111), which goes on whatever
/// becomes of the conversation that asked: a turn in the repository's Project Area (#399 decision 9,
/// `postToArea`), or, for a repository on another computer, an independent Task under that bot
/// there. A sub-agent run (`SubagentRuntime`) is the other kind of handoff.
extension AppModel {
    struct Handoff {
        /// The bot whose area (or Task) it is.
        var bot: Bot
        /// The area, or the Task.
        var task: BotTask
        /// The same request posted it (or made the Task) before; nothing more was.
        var existing: Bool
        /// For a Task: why its record couldn't be saved (it is in the sidebar all the same). For an
        /// area: why the message couldn't be queued (nothing was posted).
        var unsaved: String?
        /// The message posted into the area; nil for a Task.
        var messageID: UUID?
    }

    /// Posts what `handoff` asks into the repository's area (`postToArea`), from the conversation
    /// that asked, `caller` (`subagent`, when a sub-agent run there asked), or finds the message the
    /// same request posted before (`TaskHandoff.key`); throws why it can't. A repository on another
    /// computer gets a Task of its own there, made and started as before areas. Returns once the
    /// message is queued (or the Task's record saved), with a receipt that opens the area or Task
    /// in `caller`.
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
        if let place = try areaRepository(of: handoff.request, checkouts: checkouts) {
            let link = AgentLink(botID: asking.id, name: subagent?.targetBotName ?? asking.name, taskID: caller.taskID)
            guard let posting = try await postToArea(handoff.request, repo: place.repo, checkout: place.checkout, for: owner,
                                                     from: link, id: AreaPost.messageID(key: key)) else {
                throw TaskRequest.Problem(message: "it couldn't be posted")
            }
            if !posting.existing, posting.unsaved == nil {
                postReceipt(posting.receipt, task: posting.area.id, of: posting.bot.id, in: caller)
            }
            return Handoff(bot: posting.bot, task: posting.area, existing: posting.existing, unsaved: posting.unsaved,
                           messageID: posting.messageID)
        }
        var task: BotTask
        do {
            task = try await plannedTask(handoff.request, for: owner, checkouts: checkouts, origin: .agent)
        } catch {
            // The same request, asked again meanwhile, may have made the task now working on it.
            if let task = made() { return Handoff(bot: named, task: task, existing: true) }
            throw error
        }
        // Looking up a host's name or a pull request's head can wait, and the same request may
        // have made it meanwhile. Nothing waits from here until the Task is recorded.
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
