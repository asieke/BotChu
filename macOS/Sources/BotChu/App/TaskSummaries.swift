import Foundation
import BotChuCore

/// A new task's summary (#192): asked for once, in the background, as the task starts, on the
/// Quick tasks profile and model of Settings ▸ General (`TaskSummary`). Nothing is asked until
/// they are chosen, for a task from before, or at launch; a summary that doesn't come leaves the
/// task named as before.
extension AppModel {
    /// Asks for a new task's summary, now or once its issue's title is looked up.
    func summarizeNewTask(_ target: ChatTarget) {
        guard let id = target.taskID, settings.quickTasks != nil, let task = task(target), task.summary == nil, task.jobRun == nil else { return }
        summariesWanted.insert(id)
        summarizeIfReady(target)
    }

    /// Asks for the summary of a new task waiting for one once it has something to summarize, after
    /// the summaries asked for before it.
    func summarizeIfReady(_ target: ChatTarget) {
        guard !storageMovePending else { return }
        guard let id = target.taskID, summariesWanted.contains(id), let task = task(target), TaskSummary.source(of: task) != nil else { return }
        summariesWanted.remove(id)
        guard !terminating, let quick = settings.quickTasks, let job = TaskSummary.job(for: task, botID: target.botID, quick: quick) else { return }
        let runner = summaryRunner ?? liveSummaryRunner()
        let previous = lastSummaryRun
        let run = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let summary = await TaskSummary.run(job, with: runner)
            self?.saveSummary(summary, of: target)
        }
        summaryRuns[id] = run
        lastSummaryRun = run
    }

    private func saveSummary(_ summary: String?, of target: ChatTarget) {
        guard let id = target.taskID else { return }
        summaryRuns[id] = nil
        guard let summary, !terminating, let i = taskIndex(target), tasks[target.botID]?[i].summary == nil else { return }
        tasks[target.botID]?[i].summary = summary
        saveTask(tasks[target.botID]![i], of: target.botID)
    }

    /// Runs a summary on this Mac with the profile's command from Settings, logged in its bot's turn
    /// log as a "task summary" (a title made again, as `what` says).
    private func liveSummaryRunner(what: String = "task summary") -> RunEvaluator.Runner {
        { [weak self] job in
            guard let launch = await self?.summaryLaunch(for: job) else { throw EvaluationRunError("BotChu is closing") }
            return try await EvaluationCLI.run(job, command: launch.command, model: launch.model, log: launch.home, what: what)
        }
    }

    private func summaryLaunch(for job: EvaluationJob) -> (command: String, model: String, home: BotHome?) {
        (settings.command(for: job.account), job.model, bot(job.botID).map { BotHome(workspace: $0.persistencePath) })
    }
}

/// A task's Rename… and Regenerate Title (#236), in its tab's and its tile's menu: the label on its
/// tab's second line (`BotTask.summary`), saved in its `task.json`, the owner's own words or made
/// again from its brief and its own latest messages on the Quick tasks profile, never another
/// account. Its issue, branch, folder, session, draft and the tab shown stay as they are.
extension AppModel {
    /// Rename…: asks for the task's title, starting from the one its tab shows.
    func askToRename(_ target: ChatTarget) {
        guard let task = task(target) else { return }
        renamingText = TaskSummary.displayedLabel(of: task)
        renamingTask = target
    }

    /// Saves the title the owner typed, when it is one (`TaskSummary.manualLabel`); else nothing
    /// changes. A title being made again meanwhile is let go, so it can't replace this one.
    @discardableResult
    func renameTask(_ target: ChatTarget, to text: String) -> Bool {
        guard let id = target.taskID, let label = TaskSummary.manualLabel(text), let i = taskIndex(target) else { return false }
        stopMakingTitle(id)
        summariesWanted.remove(id)
        if titleNotice?.taskID == id { titleNotice = nil }
        tasks[target.botID]?[i].summary = label
        saveTask(tasks[target.botID]![i], of: target.botID)
        return true
    }

    /// Whether the task's title is being made again; its menu says so, and asks nothing more.
    func isRegeneratingTitle(_ target: ChatTarget) -> Bool {
        guard let id = target.taskID else { return false }
        return titleRequests.isPending(id)
    }

    /// Regenerate Title: makes the task's title again, in the background, from its brief and its own
    /// latest messages, unless that is under way already. Without a Quick tasks profile and model,
    /// it says where to choose them, and asks no other account.
    func regenerateTitle(_ target: ChatTarget) {
        guard !storageMovePending else { return }
        guard let id = target.taskID, let task = task(target), !task.isArchived, !terminating else { return }
        guard let quick = settings.quickTasks else {
            titleNotice = TaskTitleNotice(botID: target.botID, taskID: id, kind: .notConfigured)
            return
        }
        guard let ticket = titleRequests.begin(id) else { return }
        if titleNotice?.taskID == id { titleNotice = nil }
        let runner = summaryRunner ?? liveSummaryRunner(what: "task title")
        let run = Task { [weak self] in
            guard let self else { return }
            await self.makeTitle(ticket, of: target, quick: quick, runner: runner)
        }
        titleRuns[id] = run
    }

    private func stopMakingTitle(_ id: UUID) {
        titleRequests.supersede(id)
        titleRuns.removeValue(forKey: id)?.cancel()
    }

    /// Reads the task's conversation (from disk, when it isn't in memory) and asks for its title.
    private func makeTitle(_ ticket: TaskTitleRequests.Ticket, of target: ChatTarget, quick: QuickTasks,
                           runner: @escaping RunEvaluator.Runner) async {
        let thread = await loadedThread(target)
        let outcome: TaskSummary.TitleOutcome
        if Task.isCancelled {
            outcome = .failed("Stopped")
        } else if let thread, let task = task(target),
                  let job = TaskSummary.titleJob(for: task, messages: thread, botID: target.botID, quick: quick) {
            outcome = await TaskSummary.title(job, with: runner)
        } else {
            outcome = .failed("There is nothing to name the task from yet")
        }
        saveTitle(outcome, ticket: ticket, of: target)
    }

    /// Saves a title made again, or says why none came, unless the task was renamed meanwhile (or
    /// closed, or is gone): the old title stays either way when none came.
    private func saveTitle(_ outcome: TaskSummary.TitleOutcome, ticket: TaskTitleRequests.Ticket, of target: ChatTarget) {
        guard titleRequests.finish(ticket) else { return }
        titleRuns[ticket.taskID] = nil
        guard !terminating, let i = taskIndex(target), let task = tasks[target.botID]?[i], !task.isArchived else { return }
        switch outcome {
        case .named(let label):
            summariesWanted.remove(ticket.taskID)
            tasks[target.botID]?[i].summary = label
            saveTask(tasks[target.botID]![i], of: target.botID)
        case .failed(let reason):
            titleNotice = TaskTitleNotice(botID: target.botID, taskID: ticket.taskID, kind: .failed(reason))
        }
    }
}

/// A conversation's context on the Activity tab (#320): two to four sentences on what it is about,
/// asked for on the Quick tasks profile, never another account, as each turn ends and at most every
/// two minutes while one runs (`ConversationContextRequests`), one at a time per conversation, and
/// saved beside its transcript for the next launch. Without a Quick tasks profile nothing is asked,
/// and the tab shows no card.
extension AppModel {
    /// The conversation's context to show; nil without a Quick tasks profile, or until there is one.
    func context(of target: ChatTarget) -> ConversationContext? {
        guard settings.quickTasks != nil else { return nil }
        return conversation(target).context
    }

    /// Reads the context saved beside the conversation's transcript, once, so it shows at once after
    /// a relaunch while the transcript is still the one it was made from. A newer one made meanwhile stays.
    func readContext(_ target: ChatTarget) {
        guard settings.quickTasks != nil, let bot = bot(target.botID), !bot.isRemoteQueue,
              target.taskID == nil || task(target) != nil else { return }
        let state = conversation(target)
        guard !state.contextRead else { return }
        state.contextRead = true
        let home = BotHome(workspace: bot.persistencePath), taskID = target.taskID
        storage.submit(home.conversationLane(task: taskID), label: "read context", work: { home.readContext(task: taskID) }) { [weak self] result in
            guard let self, case .success(let saved?) = result, self.bot(target.botID) != nil,
                  target.taskID == nil || self.task(target) != nil else { return }
            let state = self.conversation(target)
            if state.context.map({ $0.madeAt < saved.madeAt }) ?? true { state.context = saved }
        }
    }

    /// Asks for the conversation's context when it is due: as a turn ends (`turnEnded`), or while one
    /// runs, once it has run two minutes since it started and since the last ask. Nothing is asked
    /// without a Quick tasks profile, for a remote queue bot or a closed task, or while BotChu moves
    /// its storage or quits.
    func refreshContext(_ target: ChatTarget, turnEnded: Bool, now: Date = Date()) {
        guard !storageMovePending, !terminating, settings.quickTasks != nil, let bot = bot(target.botID), !bot.isRemoteQueue else { return }
        if target.taskID != nil, task(target)?.isArchived != false { return }
        let ticket: ConversationContextRequests<ChatTarget>.Ticket?
        if turnEnded {
            ticket = contextRequests.turnEnded(target, now: now)
        } else if let started = runStates[target]?.startedAt {
            ticket = contextRequests.tick(target, turnStarted: started, now: now)
        } else {
            ticket = nil
        }
        if let ticket { askForContext(ticket) }
    }

    /// Lets go of the conversation's context under way: its task closed, or it or its bot deleted.
    func stopContext(_ target: ChatTarget) {
        contextRequests.cancel(target)
        contextRuns.removeValue(forKey: target)?.cancel()
    }

    /// Asks for the context from the conversation's latest messages in memory, with the stamp of
    /// the saved transcript when it holds all of them, read in the conversation's lane after its saves.
    private func askForContext(_ ticket: ConversationContextRequests<ChatTarget>.Ticket) {
        let target = ticket.key
        let state = conversation(target)
        guard let quick = settings.quickTasks, let bot = bot(target.botID), state.isLoaded,
              let job = ConversationContext.job(key: target.taskID?.uuidString ?? "home-\(target.botID.uuidString)",
                                                messages: state.messages, task: task(target), botName: bot.name,
                                                running: runStates[target] != nil, botID: target.botID, quick: quick) else {
            endContext(ticket, with: nil)
            return
        }
        let saved = state.isSaved, storage = storage
        let home = BotHome(workspace: bot.persistencePath), taskID = target.taskID
        let runner = summaryRunner ?? liveSummaryRunner(what: "conversation context")
        contextRuns[target] = Task { [weak self] in
            let stamp: FileStamp? = saved ? (try? await storage.perform(home.conversationLane(task: taskID), label: "context stamp") {
                FileStamp.of(home.transcriptURL(task: taskID))
            }) ?? nil : nil
            let text = Task.isCancelled ? nil : await ConversationContext.run(job, with: runner)
            self?.endContext(ticket, with: text.map { ConversationContext(text: $0, madeAt: Date(), stamp: stamp) })
        }
    }

    /// Shows and saves a context that came, unless its conversation was let go meanwhile; a failure,
    /// or a reply that isn't one, leaves the card as it was. Asks again when a turn ended meanwhile.
    private func endContext(_ ticket: ConversationContextRequests<ChatTarget>.Ticket, with context: ConversationContext?) {
        let target = ticket.key
        let (keep, next) = contextRequests.finish(ticket, now: Date())
        if !contextRequests.isAsking(target) { contextRuns[target] = nil }
        if keep, let context, !terminating, let bot = bot(target.botID), target.taskID == nil || task(target) != nil {
            conversation(target).context = context
            // One made from words not saved yet is for this launch only: the saved one no longer matches either.
            if context.stamp != nil {
                let home = BotHome(workspace: bot.persistencePath), taskID = target.taskID
                storage.submit(home.conversationLane(task: taskID), label: "context", work: { try home.writeContext(context, task: taskID) })
            }
        }
        if let next { askForContext(next) }
    }
}
