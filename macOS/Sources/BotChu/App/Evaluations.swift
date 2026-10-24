import Foundation
import BotChuCore

/// Run reviews (`RunEvaluator`): after a task turn or a sub-agent run, a background review of what
/// went well and what didn't, whose justified lessons go to the bot's memory or instructions. The
/// turn, its receipt, the handoff and the queue never wait for it.
extension AppModel {
    func makeEvaluator(runner: RunEvaluator.Runner?) -> RunEvaluator {
        let evaluator = RunEvaluator(workspace: { [weak self] id in self?.bot(id)?.workspace },
                                     sharedMemoryPath: { [weak self] in self?.settings.sharedMemoryPath ?? "" },
                                     teamPath: { [weak self] in self?.settings.teamPath ?? "" })
        evaluator.runner = runner
        evaluator.isEnabled = { [weak self] in self?.settings.evaluateRuns ?? false }
        evaluator.isAccountBusy = { [weak self] id in self?.accountIsBusy(id) ?? true }
        evaluator.onChange = { [weak self] record in self?.evaluationChanged(record) }
        return evaluator
    }

    /// Runs a review on this Mac with the account's command from Settings (`EvaluationCLI`).
    func liveEvaluationRunner() -> RunEvaluator.Runner {
        { [weak self] job in
            guard let launch = await self?.evaluationLaunch(for: job) else { throw EvaluationRunError("BotChu is closing") }
            if let problem = launch.problem { throw EvaluationRunError(problem) }
            return try await EvaluationCLI.run(job, command: launch.command, model: launch.model, openRouterKey: launch.key, log: launch.home)
        }
    }

    /// Whether a conversation's turn or a sub-agent runs on the account, which reviews wait for.
    func accountIsBusy(_ accountID: String) -> Bool {
        runStates.keys.contains { runSettings(of: $0)?.accountID == accountID }
            || (delegation?.all ?? []).contains { $0.phase.isActive && $0.accountID == accountID }
    }

    /// Hands a task's finished turn over for review, unless BotChu is quitting (which interrupts it).
    func evaluateTaskTurn(_ target: ChatTarget, thread: [ChatMessage], turnStart: Int, stopped: Bool, failure: String?) {
        guard !terminating, let bot = bot(target.botID), let task = task(target) else { return }
        let machine = task.isRemote ? "\(machineName(task.hostID, fallback: task.hostName)) over SSH" : "This Mac"
        guard let request = EvaluationRequest.taskTurn(task, of: bot, thread: thread, turnStart: turnStart,
                                                       ending: stopped ? .stopped : failure == nil ? .finished : .failed,
                                                       error: failure, machine: machine) else { return }
        evaluator.enqueue(request)
    }

    /// Hands a finished sub-agent attempt over for review, about the bot it ran as.
    func evaluateSubagentRun(_ run: SubagentRun, messages: [ChatMessage]) {
        guard !terminating, let bot = bot(run.targetBotID) else { return }
        let caller = run.parentSubagentID.flatMap { delegation?.run($0)?.targetBotName } ?? self.bot(run.rootBotID)?.name ?? "a bot"
        guard let request = EvaluationRequest.subagent(run, bot: bot, messages: messages, caller: caller) else { return }
        evaluator.enqueue(request)
    }

    /// The reviews the status sidebar lists, newest first: Home's are those about the bot's
    /// guidance; a task's, those of its turns and of the sub-agents it delegated.
    func evaluations(for target: ChatTarget) -> [EvaluationRecord] {
        let all = evaluationRecords.values
        let shown = target.taskID.map { id in all.filter { $0.subject.taskID == id } } ?? all.filter { $0.botID == target.botID }
        return shown.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    func retryEvaluation(_ id: String) { evaluator.retry(id) }
    func revertEvaluation(_ id: String) { evaluator.revert(id) }

    /// Keeps the sidebar's records, and tells the bot's Home about a change made or proposed, or a
    /// review that failed (once per kind of failure until one succeeds); no-change reviews stay quiet.
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

    private struct EvaluationLaunch: Sendable {
        var command: String
        var model: String
        var key: String?
        var home: BotHome?
        var problem: String?
    }

    private func evaluationLaunch(for job: EvaluationJob) -> EvaluationLaunch {
        let key = job.account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil
        return EvaluationLaunch(
            command: settings.command(for: job.account),
            model: GenerationOptions.effectiveModel(job.model, kind: job.account.kind, openRouterDefault: settings.openRouterModel),
            key: key, home: bot(job.botID).map { BotHome(workspace: $0.workspace) },
            problem: job.account.kind == .pi && (key?.isEmpty ?? true) ? "No OpenRouter API key: add it in BotChu ▸ Settings" : nil)
    }
}
