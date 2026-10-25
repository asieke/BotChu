import Foundation

/// The scheduled job run a task is (#146). Each run of a job starts as a new task of its agent,
/// beside its other tasks, whose conversation is the run: in the agent's workspace (a job's run
/// isn't in a repository), on the run's account, model and effort, with the job's instructions as
/// its brief. Saved with the task, so the task says which job and time it came from after the job
/// changes or goes.
public struct JobTaskOrigin: Codable, Hashable, Sendable {
    public var jobID: UUID
    public var runID: UUID
    /// The job's title when the run started.
    public var jobTitle: String
    public var trigger: JobTrigger
    /// The time it ran for; nil for Run Now.
    public var scheduledFor: Date?
    public var startedAt: Date
    /// The job's time zone when it ran.
    public var timeZone: String
    /// The owner wrote in it, so it is theirs now: the job's next run doesn't close it, and it
    /// doesn't go when the job's history lets its run go.
    public var continued: Bool

    public init(job: Job, run: JobRun, startedAt: Date) {
        jobID = job.id
        runID = run.id
        jobTitle = job.title
        trigger = run.trigger
        scheduledFor = run.scheduledFor
        self.startedAt = startedAt
        timeZone = run.timeZone
        continued = false
    }

    /// The saved zone; one this Mac doesn't know is read as UTC, as a job's is.
    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)! }
}

/// How a job's runs become tasks (#146), and how they leave the agent's Tasks again: a job keeps one
/// open task there, its latest run's, and its runs' tasks go with the runs its history lets go,
/// unless the owner took one over by writing in it.
public enum JobTasks {
    /// The task a run starts as. `settings` is the agent as the run sees it (`Job.runSettings`: the
    /// job's account, model and effort, or the agent's), whose workspace the task works in.
    public static func task(for settings: Bot, job: Job, run: JobRun, startedAt: Date, locale: Locale = .current) -> BotTask {
        let origin = JobTaskOrigin(job: job, run: run, startedAt: startedAt)
        var task = BotTask(for: settings, repo: "", checkout: settings.workspace, work: nil, brief: job.prompt,
                           title: title(origin, locale: locale))
        task.folder = settings.workspace
        task.jobRun = origin
        task.createdAt = startedAt
        return task
    }

    /// "Morning triage · Oct 24, 9:00 AM": the job and the time it was for (when it started, for
    /// Run Now), in the job's time zone.
    public static func title(_ origin: JobTaskOrigin, locale: Locale = .current) -> String {
        "\(origin.jobTitle) · \(format(origin.scheduledFor ?? origin.startedAt, in: origin.zone, template: "MMMd jmm", locale: locale))"
    }

    /// What a run's tab says it is about: "Oct 24, 9:00 AM", "Oct 24, 9:00 AM · caught up" or
    /// "Run Now · Oct 24, 9:13 AM".
    public static func when(_ origin: JobTaskOrigin, locale: Locale = .current) -> String {
        let time = format(origin.scheduledFor ?? origin.startedAt, in: origin.zone, template: "MMMd jmm", locale: locale)
        switch origin.trigger {
        case .scheduled: return time
        case .catchUp: return "\(time) · caught up"
        case .manual: return "Run Now · \(time)"
        }
    }

    /// Where the run came from, in full, as its chat and status say it: "Scheduled for Fri, Oct 24,
    /// 9:00 AM EDT", with how late a caught-up run started, or "Run Now, Fri, Oct 24, 9:13 AM EDT".
    public static func schedule(_ origin: JobTaskOrigin, locale: Locale = .current) -> String {
        let full = { (date: Date) in format(date, in: origin.zone, template: "EEE MMM d jmm z", locale: locale) }
        guard let scheduled = origin.scheduledFor else { return "Run Now, \(full(origin.startedAt))" }
        var line = "Scheduled for \(full(scheduled))"
        if origin.trigger == .catchUp {
            line += ", run \(JobWords.duration(max(0, origin.startedAt.timeIntervalSince(scheduled)))) late"
        }
        return line
    }

    /// The tasks of the job's earlier runs that the new run's task closes, so the job keeps one open
    /// task in its agent's Tasks: open ones of the same job, which the owner didn't take over and
    /// which aren't `busy` (running, shown, or holding a draft or queued messages, as the app tells).
    public static func superseded(by new: BotTask, among tasks: [BotTask], busy: (BotTask) -> Bool) -> [UUID] {
        guard let job = new.jobRun?.jobID else { return [] }
        return tasks.filter { task in
            guard task.id != new.id, !task.isArchived, let origin = task.jobRun, origin.jobID == job, !origin.continued else { return false }
            return !busy(task)
        }.map(\.id)
    }

    /// The run tasks that go with their runs once the job's history doesn't keep them: closed, not
    /// taken over by the owner, of one of `jobs` (the agent's). A deleted job's tasks stay, as the
    /// tasks a job asked for do.
    public static func expired(_ tasks: [BotTask], jobs: [Job]) -> [UUID] {
        tasks.filter { task in
            guard task.isArchived, let origin = task.jobRun, !origin.continued,
                  let job = jobs.first(where: { $0.id == origin.jobID }) else { return false }
            return !job.runs.contains { $0.id == origin.runID }
        }.map(\.id)
    }

    /// Whether a closed run task is found in its job's history, which keeps its run, rather than
    /// among its agent's closed tasks.
    public static func inHistory(_ task: BotTask, jobs: [Job]) -> Bool {
        guard let origin = task.jobRun, let job = jobs.first(where: { $0.id == origin.jobID }) else { return false }
        return job.runs.contains { $0.id == origin.runID }
    }

    static func format(_ date: Date, in zone: TimeZone, template: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
