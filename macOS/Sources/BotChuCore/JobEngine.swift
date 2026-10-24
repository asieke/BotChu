import Foundation

/// Decides which job runs start, and keeps each job's state and history, with no process or UI of
/// its own: the app starts the runs it returns (`Launch`) and reports how they ended (`finish`).
/// The clock and the store are given, so tests run it with a fake clock and a fake store.
///
/// - An occurrence is reserved before its run starts: the job's `handledThrough` moves past it and
///   the run is recorded, waiting, in one save of `job.json`. When that save fails, nothing starts.
///   So a timer, a wake and a relaunch never start the same occurrence twice.
/// - A job never overlaps itself: an occurrence due while its run waits or runs is recorded
///   skipped. Runs of one agent wait for each other and for interactive work in its workspace
///   (`busy`), and at most `maxConcurrent` run at once.
/// - After a crash or quit, a run that was running is recorded interrupted, never run again; one
///   that was waiting never started, and is recorded skipped (`recover`).
public final class JobEngine {
    public struct Launch: Equatable, Sendable {
        public var job: Job
        public var run: JobRun
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case invalid(String)
        case busy
        case missing
        case storage(String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            case .busy: "This job already has a run waiting or running."
            case .missing: "This job is gone."
            case .storage(let message): message
            }
        }
    }

    /// Every agent's jobs.
    public private(set) var jobs: [Job]
    /// Why each job's last save failed, while it does.
    public private(set) var problems: [UUID: String] = [:]
    public var now: () -> Date
    public var maxConcurrent: Int
    public var grace: TimeInterval
    private let persist: (Job) throws -> Void
    private let erase: (Job) throws -> Void

    public init(jobs: [Job] = [], now: @escaping () -> Date = Date.init, maxConcurrent: Int = JobLimits.concurrentRuns,
                grace: TimeInterval = JobLimits.onTimeGrace, persist: @escaping (Job) throws -> Void,
                erase: @escaping (Job) throws -> Void = { _ in }) {
        self.jobs = jobs
        self.now = now
        self.maxConcurrent = maxConcurrent
        self.grace = grace
        self.persist = persist
        self.erase = erase
    }

    public func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }
    public func jobs(of botID: UUID) -> [Job] { jobs.filter { $0.botID == botID } }
    public var runningCount: Int { jobs.reduce(0) { $0 + $1.runs.filter { $0.outcome == .running }.count } }
    public func isRunning(botID: UUID) -> Bool { jobs.contains { $0.botID == botID && $0.runs.contains { $0.outcome == .running } } }

    // MARK: Loading

    /// Adds an agent's jobs as loaded, after recovering runs a quit or crash cut short; returns the
    /// runs recovered as interrupted, which Home hears of.
    @discardableResult
    public func load(_ loaded: [Job]) -> [Launch] {
        var interrupted: [Launch] = []
        for var job in loaded where !jobs.contains(where: { $0.id == job.id }) {
            var changed = false
            let at = now()
            for i in job.runs.indices where job.runs[i].outcome.isActive {
                if job.runs[i].outcome == .running {
                    job.runs[i].outcome = .interrupted
                    job.runs[i].summary = "BotChu quit or stopped during this run. It may have done part of its work, so it isn't run again."
                    interrupted.append(Launch(job: job, run: job.runs[i]))
                } else {
                    job.runs[i].outcome = .skipped
                    job.runs[i].summary = "BotChu quit before this run started."
                }
                job.runs[i].finishedAt = at
                changed = true
            }
            jobs.append(job)
            if changed { _ = commit(job) }
        }
        return interrupted.map { launch in Launch(job: self.job(launch.job.id) ?? launch.job, run: launch.run) }
    }

    /// Forgets an agent's jobs (its folder went with it). Returns the runs to stop.
    public func forget(botID: UUID) -> [JobRun] {
        let running = jobs(of: botID).flatMap { $0.runs.filter { $0.outcome == .running } }
        jobs.removeAll { $0.botID == botID }
        problems = problems.filter { id, _ in jobs.contains { $0.id == id } }
        return running
    }

    // MARK: Editing

    /// Saves a new job, or an edited one. A new schedule (or time zone) counts from now, so time
    /// before it is never made up; so does turning a paused job on.
    public func save(_ edited: Job) throws {
        if let problem = edited.problem { throw Problem.invalid(problem) }
        let at = now()
        var job = edited
        job.title = job.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whole seconds, as job.json keeps them, so an interval's times don't move after a relaunch.
        job.schedule.anchor = Date(timeIntervalSinceReferenceDate: job.schedule.anchor.timeIntervalSinceReferenceDate.rounded(.down))
        job.updatedAt = at
        if let old = self.job(job.id) {
            job.runs = old.runs
            job.failureStreak = old.failureStreak
            job.handledThrough = old.handledThrough
            job.pauseReason = old.pauseReason
            if old.schedule != job.schedule { job.handledThrough = max(old.handledThrough, at) }
            if !old.enabled, job.enabled { resume(&job, at: at) }
            if old.enabled, !job.enabled { cancelWaiting(&job, reason: "The job was paused before this run started.", at: at) }
        } else {
            job.handledThrough = at
            job.runs = []
            job.failureStreak = 0
            job.pauseReason = nil
        }
        try commitOrThrow(job)
    }

    /// Pauses or resumes a job. Pausing cancels a run waiting to start (a running one goes on, and
    /// can be stopped); resuming counts from now, so paused time is never made up.
    public func setEnabled(_ id: UUID, _ enabled: Bool) throws {
        guard var job = job(id) else { throw Problem.missing }
        guard job.enabled != enabled else { return }
        let at = now()
        job.enabled = enabled
        job.updatedAt = at
        if enabled { resume(&job, at: at) } else { cancelWaiting(&job, reason: "The job was paused before this run started.", at: at) }
        try commitOrThrow(job)
    }

    /// Deletes a job and its history. Returns its running run, for the app to stop.
    public func delete(_ id: UUID) throws -> JobRun? {
        guard let job = job(id) else { throw Problem.missing }
        do { try erase(job) } catch { throw Problem.storage("Couldn't delete “\(job.title)”: \(error.localizedDescription)") }
        jobs.removeAll { $0.id == id }
        problems[id] = nil
        return job.runs.last { $0.outcome == .running }
    }

    private func resume(_ job: inout Job, at: Date) {
        job.handledThrough = max(job.handledThrough, at)
        job.failureStreak = 0
        job.pauseReason = nil
    }

    private func cancelWaiting(_ job: inout Job, reason: String, at: Date) {
        for i in job.runs.indices where job.runs[i].outcome == .waiting {
            job.runs[i].outcome = .skipped
            job.runs[i].summary = reason
            job.runs[i].finishedAt = at
        }
    }

    // MARK: Running

    /// Reserves what is due now, and starts what can start. `busy` says whether interactive work
    /// (a Home turn, a sub-agent) uses an agent's workspace.
    public func tick(busy: (UUID) -> Bool) -> [Launch] {
        let at = now()
        for job in jobs where job.enabled {
            switch JobPlanner.decide(job, now: at, grace: grace) {
            case .none:
                continue
            case let .skip(occurrence, coalesced, reason):
                record(skipped: occurrence, coalesced: coalesced, reason: reason, in: job, at: at)
            case let .run(occurrence, trigger, coalesced):
                if let active = job.activeRun {
                    let reason = active.outcome == .running ? "Its previous run was still running." : "Its previous run was still waiting to start."
                    record(skipped: occurrence, coalesced: coalesced, reason: reason, in: job, at: at)
                } else {
                    var reserved = job
                    reserved.handledThrough = occurrence
                    reserved.runs.append(JobRun(trigger: trigger, scheduledFor: occurrence, timeZone: job.schedule.timeZone,
                                                reservedAt: at, coalesced: coalesced))
                    _ = commit(reserved)
                }
            }
        }
        return startWaiting(busy: busy)
    }

    /// Run Now: a run of its own, also for a paused job (which stays paused), unless the job has a
    /// run waiting or running already.
    public func runNow(_ id: UUID, busy: (UUID) -> Bool) throws -> [Launch] {
        guard var job = job(id) else { throw Problem.missing }
        guard job.activeRun == nil else { throw Problem.busy }
        job.runs.append(JobRun(trigger: .manual, scheduledFor: nil, timeZone: job.schedule.timeZone, reservedAt: now()))
        try commitOrThrow(job)
        return startWaiting(busy: busy)
    }

    /// Withdraws a run that hasn't started; one that has is stopped by the app, which then calls `finish`.
    public func cancel(_ runID: UUID) {
        guard var job = jobs.first(where: { $0.runs.contains { $0.id == runID && $0.outcome == .waiting } }),
              let i = job.runs.firstIndex(where: { $0.id == runID }) else { return }
        job.runs[i].outcome = .skipped
        job.runs[i].summary = "Stopped before it started."
        job.runs[i].finishedAt = now()
        _ = commit(job)
    }

    /// Notes what a run started on (`edit`), saving it.
    public func amend(_ runID: UUID, _ edit: (inout JobRun) -> Void) {
        guard var job = jobs.first(where: { $0.runs.contains { $0.id == runID } }),
              let i = job.runs.firstIndex(where: { $0.id == runID }) else { return }
        edit(&job.runs[i])
        _ = commit(job)
    }

    /// Records how a run ended, and returns the runs that can start now that it has. Failures in a
    /// row pause the job; a success resets the count. Nothing is retried on its own.
    public func finish(_ runID: UUID, outcome: JobOutcome, quiet: Bool = false, summary: String, busy: (UUID) -> Bool) -> [Launch] {
        guard var job = jobs.first(where: { $0.runs.contains { $0.id == runID } }),
              let i = job.runs.firstIndex(where: { $0.id == runID }), job.runs[i].outcome.isActive else { return startWaiting(busy: busy) }
        let at = now()
        job.runs[i].outcome = outcome
        job.runs[i].quiet = outcome == .succeeded && quiet
        job.runs[i].summary = summary
        job.runs[i].finishedAt = at
        switch outcome {
        case .succeeded:
            job.failureStreak = 0
        case .failed:
            job.failureStreak += 1
            if job.enabled, job.failureStreak >= JobLimits.pauseAfterFailures {
                job.enabled = false
                job.pauseReason = "Paused after \(job.failureStreak) failed runs in a row. Fix what failed, then Resume."
                cancelWaiting(&job, reason: "The job was paused before this run started.", at: at)
            }
        default:
            break
        }
        _ = commit(job)
        return startWaiting(busy: busy)
    }

    /// The waiting runs that can start, oldest first, marked running and saved before they are
    /// returned. A run whose save fails doesn't start, and is recorded failed.
    public func startWaiting(busy: (UUID) -> Bool) -> [Launch] {
        let waiting = jobs.flatMap { job in job.runs.filter { $0.outcome == .waiting }.map { (job.id, $0) } }
            .sorted { ($0.1.reservedAt, $0.1.id.uuidString) < ($1.1.reservedAt, $1.1.id.uuidString) }
        var launches: [Launch] = []
        for (jobID, run) in waiting {
            guard runningCount < maxConcurrent else { break }
            guard var job = job(jobID), let i = job.runs.firstIndex(where: { $0.id == run.id }) else { continue }
            // One run at a time in an agent's workspace, after any interactive work there.
            if isRunning(botID: job.botID) || busy(job.botID) { continue }
            job.runs[i].outcome = .running
            job.runs[i].startedAt = now()
            if commit(job) {
                launches.append(Launch(job: job, run: job.runs[i]))
            } else if var failed = self.job(jobID), let j = failed.runs.firstIndex(where: { $0.id == run.id }) {
                // Kept in memory only: the store is what failed.
                failed.runs[j].outcome = .failed
                failed.runs[j].summary = "Couldn't save the run before starting it, so it didn't start: \(problems[jobID] ?? "")"
                failed.runs[j].finishedAt = now()
                replace(failed)
            }
        }
        return launches
    }

    // MARK: Saving

    /// A skip is one record however many occurrences it covers; the same reason again right after
    /// updates that record, so a long run skipping a frequent schedule doesn't fill the history.
    private func record(skipped occurrence: Date, coalesced: Int, reason: String, in job: Job, at: Date) {
        var job = job
        job.handledThrough = occurrence
        if let last = job.runs.indices.last, job.runs[last].outcome == .skipped, job.runs[last].summary == reason,
           job.runs[last].trigger != .manual {
            job.runs[last].coalesced += 1 + coalesced
            job.runs[last].scheduledFor = occurrence
            job.runs[last].finishedAt = at
        } else {
            var run = JobRun(trigger: .scheduled, scheduledFor: occurrence, timeZone: job.schedule.timeZone, reservedAt: at,
                             outcome: .skipped, summary: reason, coalesced: coalesced)
            run.finishedAt = at
            job.runs.append(run)
        }
        _ = commit(job)
    }

    /// Saves the job and takes it as current; when the save fails, the job stays as it was saved
    /// last, and the failure is kept in `problems`.
    @discardableResult
    private func commit(_ job: Job) -> Bool {
        var job = job
        job.runs = Self.trimmed(job.runs)
        do {
            try persist(job)
            problems[job.id] = nil
            replace(job)
            return true
        } catch {
            problems[job.id] = "Couldn't save “\(job.title)”: \(error.localizedDescription)"
            return false
        }
    }

    private func commitOrThrow(_ job: Job) throws {
        guard commit(job) else { throw Problem.storage(problems[job.id] ?? "Couldn't save the job.") }
    }

    private func replace(_ job: Job) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.append(job) }
    }

    /// The newest `JobLimits.keptRuns` runs, and the last that succeeded even when it is older, so
    /// failures never erase the last good result. Runs waiting or running are always kept.
    static func trimmed(_ runs: [JobRun], keep: Int = JobLimits.keptRuns) -> [JobRun] {
        guard runs.count > keep else { return runs }
        let lastSuccess = runs.last { $0.outcome == .succeeded }?.id
        let recent = Set(runs.suffix(keep).map(\.id))
        return runs.filter { recent.contains($0.id) || $0.id == lastSuccess || $0.outcome.isActive }
    }
}
