import Foundation
import BotChuCore

/// Requests that used to open a task's tab, posted as turns in their repository's Project Area
/// (#399 decision 9, `AreaPost`): `botchu-task create`, dispatch files, Telegram's `/task` and
/// Projects' actions.
extension AppModel {
    struct AreaPosting {
        /// The bot whose area got the request.
        var bot: Bot
        var area: BotTask
        /// The message posted; nil when there was nothing to post (the area was only opened).
        var messageID: UUID?
        /// The same request posted it before; nothing more was posted.
        var existing: Bool
        /// The bot asked, when another bot has the area and the request went there instead.
        var asked: Bot?
        /// Why the message couldn't be queued: nothing was posted.
        var unsaved: String?

        var target: ChatTarget { .task(area.id, of: bot.id) }

        /// What the conversation that asked hears of it.
        var receipt: String {
            asked.map { TaskReceipt.posted(in: area, of: bot.name, for: $0.name) } ?? TaskReceipt.posted(in: area, of: bot.name)
        }
    }

    /// The repository a request names and its main checkout on this Mac, when the request goes to
    /// its area; nil when it names another computer, or the owner keeps the repository on one: a
    /// task of its own there, as before areas.
    func areaRepository(of wanted: TaskRequest, checkouts: [RepoCheckout]) throws -> (repo: String, checkout: String)? {
        let found = try repository(named: wanted.repo, checkouts: checkouts).get()
        if let machine = wanted.machine, try host(named: machine).get() != nil { return nil }
        if let checkout = found.checkout { return (found.repo, checkout.path) }
        let location = location(of: found.repo)
        guard location.hostID == nil else { return nil }
        return (found.repo, (location.path as NSString).expandingTildeInPath)
    }

    /// Posts what `wanted` asks of `asked` (`AreaPost.text`) as a turn in the repository's area, under
    /// message ID `id`, from `requester` (nil for the owner): in `asked`'s own area, attached to it
    /// first when no bot has it, or else in the area of the bot that has it (#406's cameo turns will
    /// let `asked` answer there). A hidden area is shown again, without opening it. The repository is
    /// cloned into the area's folder first when it isn't there. A message with this ID posted before
    /// isn't posted again (`existing`). `claim`, asked just before posting with no wait after it,
    /// can still refuse (nil): a dispatch file taken, a Telegram chat still allowed. `work` is the
    /// issue or pull request already read, else it is looked up.
    func postToArea(_ wanted: TaskRequest, repo: String, checkout: String, for asked: Bot, from requester: AgentLink?,
                    id: UUID, work known: BotTask.Work? = nil, claim: (() -> Bool)? = nil) async throws -> AreaPosting? {
        if let problem = asked.taskOwnershipProblem { throw TaskRequest.Problem(message: problem) }
        var work = known
        if work == nil { work = await areaWork(wanted, repo: repo) }
        let text = AreaPost.text(brief: wanted.task, work: work, review: wanted.review, branch: wanted.branch)
        func placement() -> AreaPost.Placement {
            AreaPost.placement(repo: repo, for: asked.id, among: bots.map { ($0.id, tasks[$0.id, default: []]) })
        }
        func existingTarget(_ placement: AreaPost.Placement) -> ChatTarget? {
            switch placement {
            case .own(let area): .task(area, of: asked.id)
            case .owner(let botID, let area): .task(area, of: botID)
            case .attach: nil
            }
        }
        // What the area's transcript holds before this, for the same request posted before.
        let before = existingTarget(placement())
        var history: [ChatMessage]?
        if let before { history = await loadedThread(before) }
        let folder = ((before.flatMap { task($0)?.checkout } ?? checkout) as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: folder),
           case .failure(let failure) = await TaskWorktree.checkout(repo, at: folder) {
            throw TaskRequest.Problem(message: failure.step)
        }
        // Nothing waits from here until the message is queued.
        let now = placement()
        if let target = existingTarget(now), let area = task(target), let owner = bot(target.botID) {
            let thread = (target == before ? history ?? [] : []) + thread(target)
            if postingMessages.contains(id) || AreaPost.posted(id, thread: thread, queue: messageQueues[target]?.messages ?? []) {
                return AreaPosting(bot: owner, area: area, messageID: id, existing: true, asked: owner.id == asked.id ? nil : asked)
            }
        }
        if let claim, !claim() { return nil }
        let target: ChatTarget
        switch now {
        case .attach:
            guard let made = attachArea(repo: repo, to: asked.id, checkout: checkout, revealing: false) else {
                throw TaskRequest.Problem(message: "\(repo) couldn't be attached to \(asked.name)")
            }
            target = made
        case .own, .owner:
            target = existingTarget(now)!
            if task(target)?.isArchived == true { unhideArea(target, revealing: false) }
        }
        guard let area = task(target), let owner = bot(target.botID) else { throw TaskRequest.Problem(message: "the area is gone") }
        var posting = AreaPosting(bot: owner, area: area, messageID: nil, existing: false, asked: owner.id == asked.id ? nil : asked)
        guard !text.isEmpty else { return posting }
        posting.messageID = id
        postingMessages.insert(id)
        defer { postingMessages.remove(id) }
        let accepted: Bool = await withCheckedContinuation { continuation in
            var answered = false
            func answer(_ accepted: Bool) {
                guard !answered else { return }
                answered = true
                continuation.resume(returning: accepted)
            }
            if !send(text, to: target, id: id, fromAgent: requester, accepted: { answer($0) }) { answer(false) }
        }
        if !accepted { posting.unsaved = "Couldn't post it in \(area.title): \(owner.name)'s queue couldn't be saved." }
        return posting
    }

    /// The issue or pull request a request names, with its title from Projects or GitHub when it
    /// can be read.
    private func areaWork(_ wanted: TaskRequest, repo: String) async -> BotTask.Work? {
        guard let number = wanted.issue ?? wanted.pullRequest else { return nil }
        let pull = wanted.issue == nil
        if let item = openItems?.first(where: { $0.number == number && $0.isPullRequest == pull
            && $0.repo.caseInsensitiveCompare(repo) == .orderedSame }) {
            return item.work
        }
        if case .success(let found) = await workLookup(repo, number, pull) { return found.work }
        return BotTask.Work(number: number, isPullRequest: pull, repo: repo)
    }

    /// The conversation an `AgentLink` names, as a sentence does: "Fox's area BotChu", "Fox's task
    /// …" or "Fox's Home".
    func conversationName(of link: AgentLink) -> String {
        guard let taskID = link.taskID, let task = task(taskID, of: link.botID) else { return "\(link.name)'s Home" }
        return "\(link.name)'s \(task.isArea ? "area" : "task") \(task.title)"
    }

    /// Projects' Start Task, Fix With, Continue, Review and Fix All / Review All (#399 decision 9):
    /// what is asked (if anything) goes into the repository's area as the owner's message, from the
    /// bot chosen as `postToArea` places it, and the area opens. A repository kept on another
    /// computer opens New Task there instead, as before areas.
    func startInArea(repo: String, work: BotTask.Work? = nil, review: BotTask.Review? = nil, brief: String = "", with botID: UUID) {
        guard let asked = bot(botID), asked.canOwnTasks else { return }
        let location = location(of: repo)
        guard location.hostID == nil else {
            newTask(for: botID, repo: repo, work: work, purpose: review == .comment ? .comment : review == .review ? .review : .work, brief: brief)
            return
        }
        let wanted = TaskRequest(repo: repo, issue: work?.isPullRequest == false ? work?.number : nil,
                                 pullRequest: work?.isPullRequest == true ? work?.number : nil, task: brief, review: review)
        let checkout = (location.path as NSString).expandingTildeInPath
        Task {
            do {
                // Projects already read the issue or pull request it shows.
                guard let posting = try await postToArea(wanted, repo: repo, checkout: checkout, for: asked, from: nil, id: UUID(),
                                                         work: work) else { return }
                if posting.asked != nil, posting.messageID != nil, posting.unsaved == nil {
                    postReceipt(posting.receipt, task: nil, in: posting.target)
                }
                show(posting.target)
            } catch {
                note((error as? TaskRequest.Problem)?.message ?? error.localizedDescription, in: .home(botID))
            }
        }
    }
}
