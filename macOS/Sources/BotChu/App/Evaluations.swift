import Foundation
import BotChuCore

/// Run reviews (`RunEvaluator`): once a day, at the review time, a background review of each bot's
/// work since its last review, in a session without tools, whose justified notes go to the bot's
/// memory and whose other changes are proposals for the owner (#138). A turn's or sub-agent's end
/// only extends the work the next review covers: the turn, its receipt, the handoff and the queue
/// never wait for a review.
extension AppModel {
    func makeEvaluator(runner: RunEvaluator.Runner?) -> RunEvaluator {
        let evaluator = RunEvaluator(storage: storage, bot: { [weak self] id in self?.bot(id) },
                                     sharedMemoryPath: { [weak self] in self?.settings.sharedMemoryPath ?? "" },
                                     teamPath: { [weak self] in self?.settings.teamPath ?? "" })
        evaluator.runner = runner
        evaluator.isEnabled = { [weak self] in self?.settings.evaluateRuns ?? false }
        evaluator.isAccountBusy = { [weak self] id in self?.accountIsBusy(id) ?? true }
        evaluator.reviewTime = { [weak self] in self?.settings.reviewTime ?? .standard }
        evaluator.onChange = { [weak self] record in self?.evaluationChanged(record) }
        evaluator.onStateChange = { [weak self] _ in
            guard let self else { return }
            self.reviewStates = self.evaluator.states
        }
        return evaluator
    }

    /// Runs a review on this Mac with the account's command from Settings (`EvaluationCLI`).
    func liveEvaluationRunner() -> RunEvaluator.Runner {
        { [weak self] job in
            guard let launch = await self?.evaluationLaunch(for: job) else { throw EvaluationRunError("BotChu is closing") }
            return try await EvaluationCLI.run(job, command: launch.command, model: launch.model, log: launch.home)
        }
    }

    /// Whether a conversation's turn, a sub-agent or a scheduled job's run is on the account, which
    /// reviews wait for.
    func accountIsBusy(_ accountID: String) -> Bool {
        runStates.keys.contains { runSettings(of: $0)?.accountID == accountID }
            || (delegation?.all ?? []).contains { $0.phase.isActive && $0.accountID == accountID }
            || (jobs?.jobs ?? []).contains { $0.activeRun?.outcome == .running && $0.activeRun?.accountID == accountID }
    }

    /// Hands a conversation's finished turn, Home's or a task's, to run reviews, unless BotChu is
    /// quitting (which interrupts it): the turn joins the stretch of work its bot's next review
    /// covers, and nothing is built.
    func reviewTurn(_ target: ChatTarget, thread: [ChatMessage], turnStart: Int, accountID: String) {
        let start = min(max(0, turnStart), thread.count)
        guard !terminating, bot(target.botID) != nil, start < thread.count, let last = thread.last else { return }
        let prompt = thread[..<start].lastIndex { $0.role == .user } ?? start
        evaluator.turnEnded(ReviewConversation(botID: target.botID, taskID: target.taskID), prompt: thread[prompt].id, last: last.id,
                            accountID: accountID)
    }

    /// Hands a finished sub-agent attempt to run reviews: it joins the review of the bot it ran as.
    func evaluateSubagentRun(_ run: SubagentRun) {
        guard !terminating, bot(run.targetBotID) != nil, !run.phase.isActive else { return }
        evaluator.subagentEnded(run)
    }

    /// The reviews of a conversation, newest first: Home's are those about the bot's guidance,
    /// which cover all its work; a task's, those that covered its work.
    func evaluations(for target: ChatTarget) -> [EvaluationRecord] {
        let all = evaluationRecords.values
        let shown = target.taskID.map { id in all.filter { $0.covers(task: id) } } ?? all.filter { $0.botID == target.botID }
        return shown.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    /// Activity's summary line: the review under way or waiting and why, or when the next one is.
    func reviewStatus(for target: ChatTarget) -> ReviewStatus {
        // Read for observation: the line follows the records and the work waiting.
        _ = (evaluationRecords.count, reviewStates[target.botID])
        return evaluator.status(of: target.botID, task: target.taskID)
    }

    /// The reviews of the past week that brought no news, counted.
    func reviewCounts(for target: ChatTarget) -> ReviewCounts {
        ReviewCounts(evaluations(for: target), since: Date().addingTimeInterval(-7 * 86_400))
    }

    func canReviewNow(_ target: ChatTarget) -> Bool {
        _ = (evaluationRecords.count, reviewStates[target.botID])
        return evaluator.canReviewNow(target.botID, task: target.taskID)
    }

    func reviewNow(_ target: ChatTarget) {
        evaluator.reviewNow(target.botID, task: target.taskID, title: task(target)?.title)
    }

    func retryEvaluation(_ id: String) { evaluator.retry(id) }
    func revertEvaluation(_ id: String) { evaluator.revert(id) }

    /// Keeps the sidebar's records, and tells the bot's Home about a change made or proposed, or a
    /// review that failed (once per kind of failure until one succeeds); reviews that changed
    /// nothing or found no signal stay quiet.
    private func evaluationChanged(_ record: EvaluationRecord) {
        let before = evaluationRecords[record.id]?.phase
        evaluationRecords = evaluator.records
        guard record.phase != before, record.phase == .done || record.phase == .failed, bot(record.botID) != nil else { return }
        if record.phase == .failed, let kind = record.failure?.kind {
            guard noticedEvaluationFailures[record.botID] != kind else { return }
            noticedEvaluationFailures[record.botID] = kind
        } else {
            noticedEvaluationFailures[record.botID] = nil
        }
        guard let notice = record.notice else { return }
        append(ChatMessage(role: .note, text: notice), to: .home(record.botID))
        saveThread(.home(record.botID))
    }

    /// What a review runs with. Reviews run only on CLIs that need no OpenRouter key
    /// (`CommandBuilder.runsToolFree`), so the Keychain isn't read for them.
    private struct EvaluationLaunch: Sendable {
        var command: String
        var model: String
        var home: BotHome?
    }

    private func evaluationLaunch(for job: EvaluationJob) -> EvaluationLaunch {
        EvaluationLaunch(command: settings.command(for: job.account),
                         model: GenerationOptions.effectiveModel(job.model, kind: job.account.kind, openRouterDefault: settings.openRouterModel),
                         home: bot(job.botID).map { BotHome(workspace: $0.persistencePath) })
    }
}
