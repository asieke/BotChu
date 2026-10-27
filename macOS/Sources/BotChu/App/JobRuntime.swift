import AppKit
import Foundation
import Observation
import BotChuCore

/// The job editor, open for a new job (with its agent chosen) or an existing one.
struct JobEditorRequest: Identifiable {
    let id = UUID()
    var job: Job
    var isNew: Bool
}

/// A job's history, open on one of its runs.
struct JobHistoryRequest: Identifiable {
    let id = UUID()
    var jobID: UUID
    var runID: UUID?
}

/// Runs agents' scheduled jobs while BotChu is open and the Mac is awake: there is no background
/// helper or login item, so nothing runs while BotChu is quit or the Mac sleeps, and missed times
/// follow each job's policy when it is open again. `JobEngine` decides what starts; this starts each
/// run as a fresh CLI session of its agent's, in its workspace, apart from Home (its session,
/// queue, draft and receipts), as a new task of the agent's whose conversation is the run (#146),
/// with the helpers and mailbox a turn has (`SubagentRuntime.prepareCaller`), so it can reach other
/// bots and the owner's Inbox as its task (#170). A finding's report goes to the Inbox, and Home
/// hears only of findings and failures.
@MainActor @Observable
final class JobRuntime {
    /// Every agent's jobs, as the engine keeps them; reassigned after each change.
    private(set) var jobs: [Job] = []
    /// Why each job's last save failed, while it does.
    private(set) var problems: [UUID: String] = [:]
    var editor: JobEditorRequest?
    var history: JobHistoryRequest?
    /// The agent the Jobs view shows; nil for every agent.
    var agentFilter: UUID?
    /// How often due jobs are looked for, besides at a wake or a clock change.
    nonisolated static let tickInterval: TimeInterval = 20

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private(set) var engine: JobEngine!
    /// The transcripts of runs that never started, which have no task: their reason.
    @ObservationIgnored private var lives: [UUID: JobLive] = [:]
    /// The task conversation each run under way writes into (#146).
    @ObservationIgnored private var targets: [UUID: ChatTarget] = [:]
    /// Finished runs' transcripts until their last save is written, so their history shows them.
    @ObservationIgnored private var saving: [UUID: [ChatMessage]] = [:]
    @ObservationIgnored private var runners: [UUID: AgentRun] = [:]
    /// Runs whose helpers and mailbox are being prepared, before their CLI starts.
    @ObservationIgnored private var preparing: [UUID: Task<Void, Never>] = [:]
    /// Runs whose report is being saved in the Inbox, and those whose report couldn't be, as noted.
    @ObservationIgnored private var reporting: Set<UUID> = []
    @ObservationIgnored private var failedReports: Set<UUID> = []
    @ObservationIgnored private var timedOut: Set<UUID> = []
    @ObservationIgnored private var quitting = false
    /// False in a review copy with sample jobs: nothing starts, not even with Run Now.
    @ObservationIgnored private let runs: Bool
    /// Why the owner's last action on each job didn't work (beside the engine's save failures).
    @ObservationIgnored private var notes: [UUID: String] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// `runs: false` loads the jobs without ever starting one (review screens with sample jobs).
    init(model: AppModel, now: @escaping () -> Date = Date.init, runs: Bool = true) {
        self.model = model
        self.runs = runs
        engine = makeEngine(jobs: [], now: now)
        var interrupted: [JobEngine.Launch] = []
        for bot in model.bots where !bot.isRemoteQueue { interrupted += engine.load(BotHome(workspace: bot.persistencePath).loadJobs(of: bot.id)) }
        refresh()
        for launch in interrupted {
            deliver(launch.job, run: launch.run)
            if let target = target(of: launch.run.id, in: launch.job) {
                model.note("Interrupted: BotChu quit or stopped while this run was going, so it may have done part of its work. It isn't run again.", in: target)
            }
        }
        guard runs else { return }
        loadCatalog(for: jobs)
        deliverPendingReports()
        // Nothing starts before every job is loaded; then due jobs, at once and on each tick.
        DispatchQueue.main.async { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        for (center, name) in [(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
                               (NotificationCenter.default, Notification.Name.NSSystemClockDidChange)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }))
        }
    }

    func jobs(of botID: UUID) -> [Job] { jobs.filter { $0.botID == botID } }
    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }
    /// Whether one of the agent's jobs is running, in its workspace.
    func isRunning(botID: UUID) -> Bool { jobs.contains { $0.botID == botID && $0.activeRun?.outcome == .running } }
    func live(_ runID: UUID) -> JobLive? { lives[runID] }

    /// The task conversation a run is (#146), while its task is there; nil for runs from before runs
    /// were tasks, and for those that never started. A task the run's record lost (a crash before
    /// its save) is found by the run it names.
    func target(of runID: UUID, in job: Job) -> ChatTarget? {
        if let target = targets[runID] { return target }
        let saved = job.runs.first(where: { $0.id == runID })?.taskID.flatMap { model?.task($0, of: job.botID) }
        guard let task = saved ?? model?.tasks[job.botID]?.first(where: { $0.jobRun?.runID == runID }) else { return nil }
        return .task(task.id, of: job.botID)
    }

    /// The run under way in a task's conversation.
    func runID(in target: ChatTarget) -> UUID? { targets.first { $0.value == target }?.key }

    /// Opens a run: its task, closed or open, else its job's history at the run.
    func open(run runID: UUID, of jobID: UUID) {
        guard let job = job(jobID), let target = target(of: runID, in: job) else { return showHistory(jobID, run: runID) }
        history = nil
        model?.openTask(target)
    }

    /// What a job's runs use: its own account, model and effort, or its agent's, with why.
    func runSettings(of job: Job, agent: Bot) -> (settings: Bot, unavailable: JobRunsOn.Unavailable?) {
        job.runSettings(agent: agent, accounts: model?.settings.accounts ?? Accounts.all, catalog: model?.modelCatalog.models ?? [])
    }

    /// Why a job's runs are on its agent's when it has a choice of its own, as its row and history say.
    func fallback(of job: Job) -> String? {
        guard let bot = model?.bot(job.botID), let unavailable = runSettings(of: job, agent: bot).unavailable else { return nil }
        return unavailable.explanation(agent: bot.name)
    }

    /// OpenRouter's catalog, when a job runs on a model of its own there: what tells a run that its
    /// model is gone.
    private func loadCatalog(for jobs: [Job]) {
        guard runs, let model else { return }
        let accounts = model.settings.accounts
        guard jobs.contains(where: { job in
            job.runsOn.map { runsOn in !runsOn.model.isEmpty && accounts.first { $0.id == runsOn.accountID }?.kind == .pi } ?? false
        }) else { return }
        Task { await model.modelCatalog.load() }
    }

    /// A run's transcript: its task's conversation (read once it is in memory), or for a run from
    /// before runs were tasks as saved.
    func thread(of run: UUID, in job: Job) -> [ChatMessage] {
        if let target = target(of: run, in: job) { return model?.thread(target) ?? [] }
        if let live = lives[run] { return live.messages }
        if let saved = saving[run] { return saved }
        guard let bot = model?.bot(job.botID) else { return [] }
        return BotHome(workspace: bot.persistencePath).loadJobThread(job: job.id, run: run)
    }

    // MARK: Owner actions

    func newJob(for botID: UUID?) {
        guard let model, let botID = botID ?? model.bots.first(where: { !$0.isRemoteQueue })?.id, model.bot(botID)?.isRemoteQueue == false else { return }
        var schedule = JobSchedule()
        // Intervals start at the next whole hour.
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.end ?? Date()
        schedule.anchor = hour
        editor = JobEditorRequest(job: Job(botID: botID, schedule: schedule), isNew: true)
    }

    func edit(_ id: UUID) {
        guard let job = job(id) else { return }
        editor = JobEditorRequest(job: job, isNew: false)
    }

    func showHistory(_ id: UUID, run: UUID? = nil) {
        history = JobHistoryRequest(jobID: id, runID: run)
    }

    /// Saves a new or edited job; throws why it couldn't.
    func save(_ job: Job) throws {
        defer { refresh() }
        guard model?.bot(job.botID)?.isRemoteQueue == false else { throw JobEngine.Problem.invalid("Choose an agent.") }
        // A job stays with the agent that owns it, with its history in that agent's folder.
        if let old = self.job(job.id), old.botID != job.botID { throw JobEngine.Problem.invalid("A job stays with its agent.") }
        try engine.save(job)
        notes[job.id] = nil
        loadCatalog(for: [job])
        tick()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        do { try engine.setEnabled(id, enabled) } catch { notes[id] = error.localizedDescription }
        refresh()
        if enabled { tick() }
    }

    func runNow(_ id: UUID) {
        do { launch(try engine.runNow(id, busy: busy)) } catch { notes[id] = error.localizedDescription }
        refresh()
    }

    /// Stops a run: one under way stops its CLI; one waiting doesn't start. The job keeps its schedule.
    func stop(run runID: UUID) {
        if runners[runID] != nil || preparing[runID] != nil {
            halt(runID)
        } else {
            engine.cancel(runID)
            refresh()
        }
    }

    /// Stops a run under way: its CLI, or its start while its helpers are prepared.
    private func halt(_ runID: UUID) {
        if let runner = runners[runID] { return runner.stop() }
        guard let preparation = preparing.removeValue(forKey: runID) else { return }
        preparation.cancel()
        if let target = targets[runID] { model?.conversation(target).append(.stopNote(byOwner: !quitting)) }
        finish(runID, outcome: .stopped, summary: "Stopped.")
    }

    func delete(_ id: UUID) {
        do {
            if let running = try engine.delete(id) { halt(running.id) }
            if history?.jobID == id { history = nil }
        } catch { notes[id] = error.localizedDescription }
        refresh()
    }

    // MARK: Agents

    /// An agent is being deleted: its runs stop, and its jobs go with its folder.
    func removeBot(_ botID: UUID) {
        for run in engine.forget(botID: botID) { halt(run.id) }
        if agentFilter == botID { agentFilter = nil }
        if let history, job(history.jobID)?.botID == botID { self.history = nil }
        refresh()
    }

    /// BotChu is quitting: each run's transcript is saved as it stands (quitting waits for it), and
    /// its CLI stopped. The next launch records the run interrupted (`JobEngine.load`) and tells its
    /// agent's Home.
    func stopAll() {
        quitting = true
        timer?.invalidate()
        for (runID, preparation) in preparing {
            preparation.cancel()
            if let target = targets[runID] { model?.saveUnfinishedTurn(target) }
        }
        preparing = [:]
        for (runID, runner) in runners {
            runner.flushOutput()
            if let target = targets[runID] {
                model?.saveUnfinishedTurn(target)
            } else if let job = jobs.first(where: { $0.runs.contains { $0.id == runID } }) {
                saveThread(runID, of: job)
            }
            runner.stop()
        }
    }

    // MARK: Running

    /// Interactive work in an agent's workspace: a Home turn, a turn of one of its jobs' runs' tasks
    /// (#146), or a sub-agent working there.
    private func busy(_ botID: UUID) -> Bool {
        guard let model, let bot = model.bot(botID) else { return true }
        let folder = AppModel.standardized(bot.workspace)
        return model.isRunning(.home(botID))
            || model.openTasks(of: botID).contains { $0.jobRun != nil && model.isRunning(.task($0.id, of: botID)) }
            || model.delegation.all.contains { $0.phase.isActive && AppModel.standardized($0.workingDirectory) == folder }
    }

    func tick() {
        guard !quitting else { return }
        launch(engine.tick(busy: busy))
        deliverPendingReports()
        refresh()
        // The same tick, wake and clock change make the daily run reviews due (#138).
        model?.evaluator.pump()
    }

    private func launch(_ launches: [JobEngine.Launch]) {
        for launch in launches {
            guard runs else {
                finish(launch.run.id, outcome: .failed, summary: "This review copy of BotChu runs no jobs.")
                continue
            }
            start(launch)
        }
    }

    /// Starts a run as a new task of its agent's (#146), whose conversation it writes into: the job's
    /// instructions as its first message, then its CLI's output as it streams, live in the task's tab.
    private func start(_ launch: JobEngine.Launch) {
        let job = launch.job, runID = launch.run.id
        guard let model, let bot = model.bot(job.botID), BotHome(workspace: bot.persistencePath).exists else {
            return finish(runID, outcome: .failed, summary: "The agent's folder is missing, so the run didn't start.")
        }
        // The job's own account, model and effort, or its agent's.
        let (agent, unavailable) = runSettings(of: job, agent: bot)
        let account = agent.account
        let startedAt = launch.run.startedAt ?? Date()
        let task = JobTasks.task(for: agent, job: job, run: launch.run, startedAt: startedAt)
        guard let target = model.startJobTask(task, for: bot.id) else {
            return finish(runID, outcome: .failed, summary: "The agent is gone, so the run didn't start.")
        }
        targets[runID] = target
        let modelChoice = GenerationOptions.effectiveModel(agent.model, kind: account.kind, openRouterDefault: model.settings.openRouterModel)
        engine.amend(runID) {
            $0.taskID = task.id
            $0.accountID = account.id
            $0.accountName = account.name
            $0.model = modelChoice
            $0.reasoningEffort = agent.reasoningEffort
        }
        let conversation = model.conversation(target)
        conversation.append(ChatMessage(role: .note, text: JobLaunch.startNote(account: account, agent: bot.name, unavailable: unavailable)))
        conversation.append(ChatMessage(role: .user, text: job.prompt))
        conversation.run = RunState(startedAt: startedAt)
        model.saveThread(target)
        refresh()
        let key = account.kind == .pi ? model.openRouterKey() : nil
        if account.kind == .pi, key?.isEmpty ?? true {
            return finish(runID, outcome: .failed, summary: "Add your OpenRouter API key in BotChu ▸ Settings first.")
        }
        let preamble = JobLaunch.preamble(
            bot: bot, job: job, run: launch.run, startedAt: startedAt, memory: Workspace.read((bot.workspace as NSString).appendingPathComponent(BotContext.memoryFile)),
            sharedMemory: Workspace.read(model.settings.sharedMemoryPath), soul: Workspace.read((bot.workspace as NSString).appendingPathComponent(BotContext.soulFile)),
            instructions: Workspace.read(BotDocument.instructions.url(for: bot).path), team: Workspace.read(model.settings.teamPath),
            skills: model.activeSkills(of: bot), availableBots: model.delegation.roster, locale: .current)
        let prompt = BotContext.prompt(for: job.prompt, preamble: preamble)
        // Its helpers and mailbox first, as a turn's in its task, so `botchu-inbox send` and the
        // others work in it (#170); its CLI starts once they are ready.
        preparing[runID] = Task { [weak self] in
            let caller: SubagentRuntime.Caller
            do {
                caller = try await model.delegation.prepareCaller(target: target, directory: bot.workspace, machine: .thisMac, hostID: nil)
            } catch {
                guard let self, !Task.isCancelled, self.preparing.removeValue(forKey: runID) != nil else { return }
                return self.finish(runID, outcome: .failed, summary: "Couldn't prepare the run's helpers: \(error.localizedDescription)")
            }
            guard let self, !Task.isCancelled, self.preparing.removeValue(forKey: runID) != nil, !self.quitting else {
                return model.delegation.endCaller(caller.id)
            }
            var invocation = JobLaunch.invocation(for: agent, prompt: prompt, openRouterDefault: model.settings.openRouterModel, openRouterKey: key)
            invocation.environment.merge(caller.environment) { _, new in new }
            self.run(launch, prompt: prompt, invocation: invocation, caller: caller, account: account, agent: agent, target: target)
        }
    }

    /// Runs a prepared run's CLI, streaming into its task's conversation, and ends the run when it exits.
    private func run(_ launch: JobEngine.Launch, prompt: String, invocation: Invocation, caller: SubagentRuntime.Caller,
                     account: Account, agent: Bot, target: ChatTarget) {
        let job = launch.job, runID = launch.run.id
        guard let model, let bot = model.bot(job.botID) else {
            model?.delegation.endCaller(caller.id)
            return finish(runID, outcome: .failed, summary: "The agent is gone, so the run didn't start.")
        }
        let conversation = model.conversation(target)
        let startedAt = launch.run.startedAt ?? Date()
        let command = model.settings.command(for: account)
        let runner = AgentRun(command: command, invocation: invocation, directory: URL(fileURLWithPath: bot.workspace, isDirectory: true))
        var assembler = ThreadAssembler()
        var outcome = TurnOutcome()
        var lastSave = Date()
        let home = BotHome(workspace: bot.persistencePath)
        let what = "job “\(job.title)” run"

        runner.deliverEvents(parsedBy: StreamParsers.make(for: account.kind)) { [weak self, weak runner] events in
            guard let self, let runner, self.runners[runID] === runner, let model = self.model else { return }
            var state = conversation.run
            if state?.hasOutput == false { state?.hasOutput = true }
            var session: String?
            var reported: String?
            var settles: [TimeInterval] = []
            conversation.stream { messages in
                for event in events {
                    outcome.record(event)
                    switch event {
                    case .session(let id): session = CommandBuilder.resumeID(kind: account.kind, invocation: invocation, reported: id)
                    case .model(let id): reported = id
                    default: break
                    }
                    if let activity = BotActivity.next(after: event), activity != state?.activity || state?.pending != nil,
                       let wait = state?.move(to: activity) {
                        settles.append(wait)
                    }
                    assembler.apply(event, to: &messages)
                }
            }
            if state != conversation.run { conversation.run = state }
            for wait in settles {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak runner] in
                    guard let runner, self?.runners[runID] === runner else { return }
                    conversation.run?.settle()
                }
            }
            if session != nil || reported != nil {
                self.engine.amend(runID) { run in
                    if let session { run.sessionID = session }
                    if let reported { run.reportedModel = reported }
                }
                self.refresh()
                // The task resumes the run's session when the owner writes in it.
                if let session { model.recordSession(session, accountID: account.id, for: target) }
                if let reported { model.recordReportedModel(reported, requested: agent.model, accountID: account.id, for: target) }
            }
            // A crash loses at most a few seconds of the transcript.
            if Date().timeIntervalSince(lastSave) > 5 {
                lastSave = Date()
                model.saveThread(target)
            }
        }
        runner.onExit = { [weak self, weak runner] status, stderr in
            guard let self, let runner, self.runners[runID] === runner else { return }
            self.runners[runID] = nil
            // Quitting: the next launch records it interrupted.
            guard !self.quitting else { return }
            conversation.stream { messages in
                assembler.apply(.textEnd, to: &messages)
                ThreadAssembler.closeRunningTools(&messages)
            }
            let messages = conversation.messages
            let timedOut = self.timedOut.remove(runID) != nil
            let result = JobResult.classify(reply: messages.last(where: { $0.role == .assistant })?.text,
                                            failure: outcome.ended ? outcome.failure : nil, status: status,
                                            finished: outcome.ended && outcome.failure == nil, stopped: runner.stopped,
                                            timedOut: timedOut, timeLimit: job.timeLimit, accountName: account.name, stderr: stderr)
            if result.outcome == .stopped { conversation.append(.stopNote(byOwner: true)) }
            self.model?.log(TurnLog.ended(at: Date(), startedAt: startedAt, status: status, stopped: runner.stopped,
                                          toolCalls: messages.filter { $0.role == .tool }.count,
                                          error: result.outcome == .failed ? result.summary : nil, stderr: stderr, what: what), in: home)
            let reply = messages.last(where: { $0.role == .assistant })?.text
            // What it sent to the Inbox is all in before it ends (#170): those deliveries' cards follow
            // its reply, as a turn's do, and a finding it sent nothing of goes there as its report.
            Task { [weak self] in
                await self?.model?.delegation.finishCaller(caller.id)
                guard let self, !self.quitting, let model = self.model else { return }
                let cards = model.inbox.takeCards(for: target)
                for card in cards { conversation.append(card) }
                model.inbox.turnEnded(target)
                let report = JobReport.isDue(result, delivered: !cards.isEmpty) ? reply : nil
                let finish: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self else { return }
                    self.finish(runID, outcome: result.outcome, quiet: result.quiet, summary: result.summary, report: report)
                    // Tasks the run asked for start now, as Home's do after its turns.
                    self.model?.takeDispatches(for: job.botID)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.model?.takeDispatches(for: job.botID) }
                }
                // What the run asked to remember goes into the agent's memory, as for its other sessions,
                // saved off the main thread, and the task hears how it went; the run ends once that is done.
                guard result.outcome == .succeeded, let bot = model.bot(job.botID) else { return finish() }
                model.saveMemory(from: messages, of: bot, reportTo: target) { lines in
                    for line in lines { conversation.append(line) }
                    finish()
                }
            }
        }
        do {
            model.log(TurnLog.started(at: startedAt, account: account, command: command, arguments: invocation.arguments,
                                      prompt: prompt, resuming: nil, what: what), in: home)
            try runner.start()
            runners[runID] = runner
            DispatchQueue.main.asyncAfter(deadline: .now() + job.timeLimit) { [weak self, weak runner] in
                guard let self, let runner, self.runners[runID] === runner else { return }
                self.timedOut.insert(runID)
                runner.stop()
            }
        } catch {
            model.delegation.endCaller(caller.id)
            finish(runID, outcome: .failed, summary: JobFailure.explain("Couldn't start \(account.name): \(error.localizedDescription)", accountName: account.name))
        }
    }

    /// Records how a run ended, saves its transcript (its task's conversation, which is idle again),
    /// delivers its `report` to the Inbox, tells Home when it should hear, and starts what waited for it.
    private func finish(_ runID: UUID, outcome: JobOutcome, quiet: Bool = false, summary: String, report: String? = nil) {
        // Its task is idle before the engine looks for what to start next, so a run waiting for the
        // agent isn't held up by it.
        let target = targets.removeValue(forKey: runID)
        if let target, let model, model.task(target) != nil {
            let conversation = model.conversation(target)
            if outcome == .failed, conversation.messages.last?.role != .error {
                conversation.append(ChatMessage(role: .error, text: summary))
            }
            conversation.run = nil
            model.saveThread(target)
        }
        // Waiting for the Inbox until it is there, so a save that fails is tried again.
        if report != nil { engine.amend(runID) { $0.reportPending = true } }
        let next = engine.finish(runID, outcome: outcome, quiet: quiet, summary: summary, busy: busy)
        // Run reviews on its account wait a while after it.
        if let accountID = engine.jobs.lazy.flatMap(\.runs).first(where: { $0.id == runID })?.accountID { model?.evaluator.accountActivity(accountID) }
        let job = engine.jobs.first(where: { $0.runs.contains { $0.id == runID } })
        if let job, target == nil {
            if lives[runID] == nil, outcome == .failed {
                // It never started: its transcript is the reason.
                let live = JobLive()
                live.messages = [ChatMessage(role: .error, text: summary)]
                lives[runID] = live
            }
            saveThread(runID, of: job)
            if let live = lives[runID] { saving[runID] = live.messages }
        }
        let run = job?.runs.first(where: { $0.id == runID })
        if let job, let run { deliver(job, run: run) }
        if let job, let run, let report { deliverReport(report, of: job, run: run) }
        if let target { model?.endJobRun(in: target, news: run?.needsReceipt ?? false) }
        lives[runID] = nil
        refresh()
        launch(next)
        refresh()
    }

    /// A finding, a failure or an interrupted run, as one line in its agent's Home with Open Run.
    private func deliver(_ job: Job, run: JobRun) {
        guard run.needsReceipt else { return }
        model?.postJobReceipt(JobReceipt.text(job: job, run: run), job: job.id, run: run.id, to: job.botID)
    }

    /// Puts a run's report in the owner's Inbox as its task's delivery (`JobReport`). Until it is
    /// saved there the run says it waits (`JobRun.reportPending`), and a save that fails is noted in
    /// the task once and tried again at each tick and launch.
    private func deliverReport(_ reply: String, of job: Job, run: JobRun) {
        guard let model, !reporting.contains(run.id) else { return }
        guard let delivery = JobReport.delivery(job: job, run: run, reply: reply) else {
            engine.amend(run.id) { $0.reportPending = nil }
            return
        }
        reporting.insert(run.id)
        Task { [weak self] in
            var failure: Error?
            do { try await model.inbox.post(delivery) } catch { failure = error }
            guard let self else { return }
            self.reporting.remove(run.id)
            if let failure {
                guard self.failedReports.insert(run.id).inserted, let target = self.target(of: run.id, in: job) else { return }
                model.append(ChatMessage(role: .error, text: "Couldn't deliver the report to your Inbox: \(failure.localizedDescription). BotChu tries again."), to: target)
                model.saveThread(target)
            } else {
                self.failedReports.remove(run.id)
                self.engine.amend(run.id) { $0.reportPending = nil }
                self.refresh()
            }
        }
    }

    /// Tries again the reports waiting for the Inbox, read from their tasks' conversations.
    private func deliverPendingReports() {
        guard runs, let model else { return }
        for job in jobs {
            for run in job.runs where run.reportPending == true && !reporting.contains(run.id) {
                guard let target = target(of: run.id, in: job) else {
                    // Its task is gone, and the report with it.
                    engine.amend(run.id) { $0.reportPending = nil }
                    continue
                }
                reporting.insert(run.id)
                Task { [weak self] in
                    let thread = await model.loadedThread(target)
                    guard let self else { return }
                    self.reporting.remove(run.id)
                    guard let reply = thread?.last(where: { $0.role == .assistant })?.text, let job = self.job(job.id),
                          let run = job.runs.first(where: { $0.id == run.id }) else { return }
                    self.deliverReport(reply, of: job, run: run)
                }
            }
        }
    }

    /// Saves the run's transcript as it is now, off the main thread, in its own lane: a newer state
    /// takes the place of one not written yet, and none is written twice. A failure is noted on the job.
    private func saveThread(_ runID: UUID, of job: Job) {
        guard let live = lives[runID], let model, let bot = model.bot(job.botID) else { return }
        let home = BotHome(workspace: bot.persistencePath), jobID = job.id, messages = live.messages
        model.storage.replace(home.jobRunLane(job: jobID, run: runID), slot: "transcript", value: messages,
                              write: { try home.saveJobThread($0, job: jobID, run: runID) }) { [weak self] result in
            guard let self else { return }
            if self.saving[runID] == messages { self.saving[runID] = nil }
            guard case .failure(let error) = result, (error as? StorageQueue.Failure) == nil, self.engine.job(jobID) != nil else { return }
            self.notes[jobID] = "Couldn't save the run's transcript: \(error.localizedDescription)"
            self.refresh()
        }
    }

    // MARK: Storage

    private func write(_ job: Job) throws {
        guard let bot = model?.bot(job.botID) else { throw JobEngine.Problem.invalid("The job's agent is gone.") }
        let home = BotHome(workspace: bot.persistencePath)
        // A folder that went away (unmounted, moved outside BotChu) doesn't keep firing jobs from memory.
        guard home.exists else {
            throw JobEngine.Problem.storage("\((bot.workspace as NSString).abbreviatingWithTildeInPath) doesn't hold \(bot.name) any more")
        }
        try home.save(job)
    }

    private func erase(_ job: Job) throws {
        guard let bot = model?.bot(job.botID) else { return }
        try BotHome(workspace: bot.persistencePath).removeJob(job.id)
    }

    private func refresh() {
        if jobs != engine.jobs {
            jobs = engine.jobs
            pruneRunTasks()
        }
        notes = notes.filter { engine.job($0.key) != nil }
        let merged = engine.problems.merging(notes) { saving, _ in saving }
        if merged != problems { problems = merged }
    }

    /// The closed runs' tasks whose runs the history let go go with them (`JobTasks.expired`).
    private func pruneRunTasks() {
        guard let model else { return }
        for botID in Set(jobs.map(\.botID)) {
            let expired = JobTasks.expired(model.tasks[botID, default: []], jobs: jobs(of: botID))
            if !expired.isEmpty { model.removeJobTasks(expired, of: botID) }
        }
    }

    /// Sample jobs for a throwaway review, taken as they are (`DevHooks.sampleJobs`): a waiting run
    /// stays waiting, to be seen, where a launch would record it skipped.
    func addSamples(_ samples: [Job]) {
        engine = makeEngine(jobs: engine.jobs + samples.filter { job($0.id) == nil }, now: engine.now)
        refresh()
    }

    private func makeEngine(jobs: [Job], now: @escaping () -> Date) -> JobEngine {
        JobEngine(jobs: jobs, now: now, persist: { [weak self] job in try MainActor.assumeIsolated { try self?.write(job) } },
                  erase: { [weak self] job in try MainActor.assumeIsolated { try self?.erase(job) } })
    }

    /// Clears what the owner was told about a job's last action.
    func clearProblem(_ id: UUID) {
        notes[id] = nil
        refresh()
    }
}

/// A run's transcript and activity as they stream in, observed apart from every other run's.
@MainActor @Observable
final class JobLive {
    var messages: [ChatMessage] = []
    var state: RunState?

    func update(_ change: (inout [ChatMessage]) -> Void) {
        change(&messages)
    }
}
