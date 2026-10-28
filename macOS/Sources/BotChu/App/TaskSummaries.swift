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
