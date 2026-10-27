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
    /// log as a "task summary".
    private func liveSummaryRunner() -> RunEvaluator.Runner {
        { [weak self] job in
            guard let launch = await self?.summaryLaunch(for: job) else { throw EvaluationRunError("BotChu is closing") }
            return try await EvaluationCLI.run(job, command: launch.command, model: launch.model, log: launch.home, what: "task summary")
        }
    }

    private func summaryLaunch(for job: EvaluationJob) -> (command: String, model: String, home: BotHome?) {
        (settings.command(for: job.account), job.model, bot(job.botID).map { BotHome(workspace: $0.persistencePath) })
    }
}
