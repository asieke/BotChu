import Foundation
import Testing
@testable import BotChuCore

/// A scheduled job's run as a task of its agent (#146): the task a run starts as, what its tab and
/// context say, which earlier runs' tasks a new run closes, and which go with the runs the job's
/// history lets go.
@Suite struct JobTaskTests {
    let at = JobScheduleTests.at
    let en = Locale(identifier: "en_US")
    let agent = Bot(name: "Product Fox", emoji: "🦊", accountID: "codex-work", model: "gpt-6-luna", reasoningEffort: .medium,
                    workspace: "/Users/a/BOTS/product-fox")

    func job() -> Job {
        Job(botID: agent.id, title: "10x Product Analysis", prompt: "Deploy a sub-agent for each repo and recommend one feature.",
            schedule: JobSchedule(kind: .daily, hour: 6, minute: 6, timeZone: JobScheduleTests.newYork))
    }

    func run(_ trigger: JobTrigger = .scheduled, for scheduled: String? = "2026-10-26T10:06:00Z") -> JobRun {
        JobRun(trigger: trigger, scheduledFor: trigger == .manual ? nil : scheduled.map(at), timeZone: JobScheduleTests.newYork,
               reservedAt: at("2026-10-26T10:06:00Z"))
    }

    func task(of job: Job, run: JobRun, startedAt: String = "2026-10-26T10:06:20Z") -> BotTask {
        JobTasks.task(for: agent, job: job, run: run, startedAt: at(startedAt), locale: en)
    }

    @Test func aRunStartsAsATaskInTheAgentsWorkspace() throws {
        let job = job(), run = run()
        // On the job's own account, model and effort, as the run sees its agent.
        let settings = JobRunsOn(accountID: "claude-dev", model: "opus", reasoningEffort: .high).applied(to: agent)
        let task = JobTasks.task(for: settings, job: job, run: run, startedAt: at("2026-10-26T10:06:20Z"), locale: en)
        #expect(JobSchedule.plainText(task.title) == "10x Product Analysis · Oct 26 at 6:06 AM")
        #expect(task.brief == job.prompt)
        #expect(task.repo.isEmpty)
        #expect(task.folder == agent.workspace)
        #expect(task.checkout == agent.workspace)
        #expect(task.branch.isEmpty && task.work == nil && task.review == nil && !task.isRemote)
        #expect(task.accountID == "claude-dev" && task.model == "opus" && task.reasoningEffort == .high)
        #expect(task.sessionID == nil)
        #expect(task.origin == .owner)
        #expect(task.createdAt == at("2026-10-26T10:06:20Z"))
        #expect(!task.isArchived)
        let origin = try #require(task.jobRun)
        #expect(origin.jobID == job.id && origin.runID == run.id)
        #expect(origin.jobTitle == "10x Product Analysis")
        #expect(origin.trigger == .scheduled)
        #expect(origin.scheduledFor == at("2026-10-26T10:06:00Z"))
        #expect(origin.timeZone == JobScheduleTests.newYork)
        #expect(!origin.continued)

        // Saved with the task; tasks and runs from before have none.
        let decoded = try Store.decoder.decode(BotTask.self, from: Store.encoder.encode(task))
        #expect(decoded == task)
        var plain = BotTask(repo: "asieke/GitChu", checkout: "/Users/a/WORKSPACE/GitChu")
        plain.jobRun = nil
        let object = try #require(JSONSerialization.jsonObject(with: Store.encoder.encode(plain)) as? [String: Any])
        #expect(object["jobRun"] == nil)
        #expect(try Store.decoder.decode(BotTask.self, from: JSONSerialization.data(withJSONObject: object)).jobRun == nil)
        var withTask = run
        withTask.taskID = task.id
        #expect(try Store.decoder.decode(JobRun.self, from: Store.encoder.encode(withTask)).taskID == task.id)
        var old = try #require(JSONSerialization.jsonObject(with: Store.encoder.encode(run)) as? [String: Any])
        old["taskID"] = nil
        #expect(try Store.decoder.decode(JobRun.self, from: JSONSerialization.data(withJSONObject: old)).taskID == nil)
    }

    @Test func itsTabNamesTheJobAndTheTimeItWasFor() throws {
        let job = job()
        let scheduled = task(of: job, run: run())
        let origin = try #require(scheduled.jobRun)
        #expect(JobSchedule.plainText(JobTasks.when(origin, locale: en)) == "Oct 26 at 6:06 AM")
        #expect(JobSchedule.plainText(JobTasks.schedule(origin, locale: en)) == "Scheduled for Mon, Oct 26 at 6:06 AM EDT")
        // A caught-up run says how late it started; Run Now, when it started.
        let late = try #require(task(of: job, run: run(.catchUp), startedAt: "2026-10-26T12:21:00Z").jobRun)
        #expect(JobSchedule.plainText(JobTasks.when(late, locale: en)) == "Oct 26 at 6:06 AM · caught up")
        #expect(JobSchedule.plainText(JobTasks.schedule(late, locale: en)) == "Scheduled for Mon, Oct 26 at 6:06 AM EDT, run 2 h 15 min late")
        let manual = task(of: job, run: run(.manual), startedAt: "2026-10-26T13:13:00Z")
        let now = try #require(manual.jobRun)
        #expect(JobSchedule.plainText(manual.title) == "10x Product Analysis · Oct 26 at 9:13 AM")
        #expect(JobSchedule.plainText(JobTasks.when(now, locale: en)) == "Run Now · Oct 26 at 9:13 AM")
        #expect(JobSchedule.plainText(JobTasks.schedule(now, locale: en)) == "Run Now, Mon, Oct 26 at 9:13 AM EDT")

        // Its tab: the job, with a clock, and while idle the time it was for; no number.
        let tab = ConversationTab(task: scheduled, machine: nil, state: .idle(since: nil))
        #expect(tab.isJob && !tab.isReview && !tab.isHome)
        #expect(tab.name == "10x Product Analysis")
        #expect(tab.title == "10x Product Analysis")
        #expect(tab.numberText == nil)
        #expect(tab.subject == JobTasks.when(origin))
        #expect(tab.help(shortcut: "⌘2") == "\(JobTasks.when(origin))\nJob “10x Product Analysis” · This Mac · ⌘2")
        #expect(tab.spoken(at: Date()).hasPrefix("Run of job 10x Product Analysis, "))
        // A plain task's tab is as it was.
        #expect(!ConversationTab(task: BotTask(repo: "asieke/GitChu", checkout: "/tmp"), machine: nil, state: .idle(since: nil)).isJob)
    }

    @Test func aNewRunClosesItsJobsEarlierRunsUnlessTheOwnerTookOneOver() {
        let job = job(), other = Job(botID: agent.id, title: "Deploy check", prompt: "Check")
        let first = task(of: job, run: run())
        var taken = task(of: job, run: run())
        taken.jobRun?.continued = true
        var closed = task(of: job, run: run())
        closed.archivedAt = Date()
        let busy = task(of: job, run: run())
        let otherJobs = task(of: other, run: run())
        let plain = BotTask(repo: "asieke/GitChu", checkout: "/tmp")
        let new = task(of: job, run: run())
        let all = [first, taken, closed, busy, otherJobs, plain, new]
        #expect(JobTasks.superseded(by: new, among: all) { $0.id == busy.id } == [first.id])
        #expect(JobTasks.superseded(by: plain, among: all) { _ in false }.isEmpty)
    }

    @Test func runsTasksGoWithTheRunsTheHistoryLetsGo() {
        var job = job()
        let kept = run(), dropped = run()
        job.runs = [kept]
        let deleted = Job(botID: agent.id, title: "Gone", prompt: "x")
        func closed(_ task: BotTask) -> BotTask {
            var task = task
            task.archivedAt = Date()
            return task
        }
        let keptTask = closed(task(of: job, run: kept))
        let droppedTask = closed(task(of: job, run: dropped))
        var takenOver = closed(task(of: job, run: dropped))
        takenOver.jobRun?.continued = true
        let open = task(of: job, run: dropped)
        let ofDeletedJob = closed(task(of: deleted, run: dropped))
        var plain = BotTask(repo: "asieke/GitChu", checkout: "/tmp")
        plain.archivedAt = Date()
        let tasks = [keptTask, droppedTask, takenOver, open, ofDeletedJob, plain]
        #expect(JobTasks.expired(tasks, jobs: [job]) == [droppedTask.id])
        // A closed run's task is in its job's history while the history keeps its run; else among
        // the agent's closed tasks.
        #expect(JobTasks.inHistory(keptTask, jobs: [job]))
        #expect(!JobTasks.inHistory(takenOver, jobs: [job]))
        #expect(!JobTasks.inHistory(ofDeletedJob, jobs: [job]))
        #expect(!JobTasks.inHistory(plain, jobs: [job]))
    }

    @Test func itsContextIsTheJobsRunInTheWorkspace() throws {
        var task = task(of: job(), run: run())
        task.sessionID = nil
        let preamble = JobSchedule.plainText(BotContext.taskPreamble(bot: agent, task: task, memory: "", sharedMemory: "", history: []))
        #expect(preamble.contains("This task is a run of your scheduled job “10x Product Analysis” (Scheduled for Mon, Oct 26 at 6:06 AM EDT), in your workspace /Users/a/BOTS/product-fox, not in a repository"), "\(preamble)")
        #expect(preamble.contains("Your task is in the message below."))
        #expect(!preamble.contains("worktree of"))
        #expect(!preamble.contains("You started this task yourself"))
        let report = BotContext.taskReport(task, status: BotStatus.make(task: task, messages: [ChatMessage(role: .assistant, text: "Done.")], run: nil),
                                           pullRequest: nil, lastReply: "Done.")
        #expect(report.contains("(task \(task.id.uuidString.lowercased().prefix(8))), a run of your scheduled job “10x Product Analysis”: its last turn finished"))
        #expect(!report.contains(" in ,"))
        // The run's own context says it is a task the owner may open and continue.
        let job = job()
        var run = run()
        run.startedAt = at("2026-10-26T10:06:20Z")
        let context = JobLaunch.preamble(bot: agent, job: job, run: run, startedAt: at("2026-10-26T10:06:20Z"), memory: "", sharedMemory: "")
        #expect(context.contains("the run is a task of its own beside it, which your owner may open"))
    }
}
