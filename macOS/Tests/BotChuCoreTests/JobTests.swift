import Foundation
import Testing
@testable import BotChuCore

/// Scheduled jobs (#87): schedule math in a job's own time zone, due-run decisions, reservation,
/// recovery and persistence, with a fake clock and store; no CLI runs.
@Suite struct JobScheduleTests {
    static let newYork = "America/New_York"

    static func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    /// ICU puts a narrow no-break space before AM and PM.
    static func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func dailyRunsAtItsTimeInItsOwnZone() {
        let newYork = JobSchedule(kind: .daily, hour: 9, minute: 0, timeZone: Self.newYork)
        #expect(newYork.next(after: Self.at("2026-10-23T14:00:00Z")) == Self.at("2026-10-24T13:00:00Z"))
        // The same job saved in London runs at London's nine, wherever the Mac is.
        let london = JobSchedule(kind: .daily, hour: 9, minute: 0, timeZone: "Europe/London")
        #expect(london.next(after: Self.at("2026-10-23T14:00:00Z")) == Self.at("2026-10-24T08:00:00Z"))
        // London's clocks go back at 01:00 UTC on Oct 25: that morning, nine is 09:00 UTC.
        #expect(london.next(after: Self.at("2026-10-25T08:30:00Z")) == Self.at("2026-10-25T09:00:00Z"))
        // The zone travels with the saved job.
        let decoded = try? JSONDecoder().decode(JobSchedule.self, from: JSONEncoder().encode(london))
        #expect(decoded?.zone.identifier == "Europe/London")
        #expect(Self.plain(newYork.summary(locale: Locale(identifier: "en_US"))) == "Every day at 9:00 AM")
        #expect(newYork.zoneLabel(at: Self.at("2026-10-24T13:00:00Z")) == "America/New_York (EDT)")
    }

    @Test func aTimeTheClockSkipsRunsWhenItJumps() {
        // March 8, 2026: New York's clocks jump from 2:00 to 3:00, so 2:30 never happens.
        let schedule = JobSchedule(kind: .daily, hour: 2, minute: 30, timeZone: Self.newYork)
        let jump = Self.at("2026-03-08T07:00:00Z")
        #expect(schedule.next(after: Self.at("2026-03-07T12:00:00Z")) == jump)
        #expect(schedule.next(after: jump) == Self.at("2026-03-09T06:30:00Z"))
        #expect(schedule.latest(atOrBefore: Self.at("2026-03-08T12:00:00Z"), after: Self.at("2026-03-07T12:00:00Z")) == jump)
    }

    @Test func aTimeTheClockRepeatsRunsOnce() {
        // November 1, 2026: 1:30 happens twice in New York, at 05:30 and 06:30 UTC.
        let schedule = JobSchedule(kind: .daily, hour: 1, minute: 30, timeZone: Self.newYork)
        let first = Self.at("2026-11-01T05:30:00Z")
        #expect(schedule.next(after: Self.at("2026-10-31T12:00:00Z")) == first)
        #expect(schedule.next(after: first) == Self.at("2026-11-02T06:30:00Z"))
        #expect(schedule.next(after: Self.at("2026-11-01T06:00:00Z")) == Self.at("2026-11-02T06:30:00Z"))
        var job = Job(botID: UUID(), title: "Night", prompt: "Check", schedule: schedule, createdAt: Self.at("2026-10-31T12:00:00Z"))
        job.handledThrough = first
        #expect(JobPlanner.decide(job, now: Self.at("2026-11-01T06:31:00Z")) == .none)
    }

    @Test func weekdaysAndChosenDays() {
        let weekdays = JobSchedule(kind: .weekdays, hour: 9, minute: 0, timeZone: Self.newYork)
        // Friday afternoon, then Monday morning.
        #expect(weekdays.next(after: Self.at("2026-10-23T14:00:00Z")) == Self.at("2026-10-26T13:00:00Z"))
        #expect(Self.plain(weekdays.summary(locale: Locale(identifier: "en_US"))) == "Weekdays at 9:00 AM")
        let chosen = JobSchedule(kind: .days, hour: 9, minute: 0, days: [6, 2, 4], timeZone: Self.newYork)
        #expect(chosen.next(after: Self.at("2026-10-26T14:00:00Z")) == Self.at("2026-10-28T13:00:00Z"))
        let summary = Self.plain(chosen.summary(locale: Locale(identifier: "en_US")))
        #expect(summary.hasPrefix("Mon, Wed"), "\(summary)")
        #expect(summary.hasSuffix("Fri at 9:00 AM"), "\(summary)")
        #expect(chosen.upcoming(after: Self.at("2026-10-26T14:00:00Z"), count: 3)
            == [Self.at("2026-10-28T13:00:00Z"), Self.at("2026-10-30T13:00:00Z"), Self.at("2026-11-02T14:00:00Z")])
    }

    @Test func intervalsStayTrueDurationsFromTheirStart() {
        let anchor = Self.at("2026-10-24T13:00:00Z")
        let every45 = JobSchedule(kind: .interval, every: 45, unit: .minutes, anchor: anchor, timeZone: Self.newYork)
        #expect(every45.next(after: Self.at("2026-10-24T12:00:00Z")) == anchor)
        #expect(every45.next(after: anchor) == Self.at("2026-10-24T13:45:00Z"))
        #expect(every45.next(after: Self.at("2026-10-24T13:50:00Z")) == Self.at("2026-10-24T14:30:00Z"))
        #expect(every45.latest(atOrBefore: Self.at("2026-10-24T13:44:59Z"), after: Self.at("2026-10-24T12:00:00Z")) == anchor)
        #expect(every45.latest(atOrBefore: Self.at("2026-10-24T12:59:00Z"), after: Self.at("2026-10-24T12:00:00Z")) == nil)
        #expect(every45.summary() == "Every 45 minutes")
        // Across New York's fall-back night, every 90 minutes stays 90 minutes apart.
        let every90 = JobSchedule(kind: .interval, every: 90, unit: .minutes, anchor: Self.at("2026-11-01T04:00:00Z"), timeZone: Self.newYork)
        let dates = every90.upcoming(after: Self.at("2026-11-01T04:00:00Z"), count: 4)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) == 5_400 })
        #expect(every90.count(after: Self.at("2026-11-01T04:00:00Z"), before: Self.at("2026-11-01T08:30:00Z")) == 2)
    }

    @Test func refusesSchedulesItCantKeep() {
        #expect(JobSchedule(kind: .interval, every: 4, unit: .minutes).problem != nil)
        #expect(JobSchedule(kind: .interval, every: 5, unit: .minutes).problem == nil)
        #expect(JobSchedule(kind: .days, days: []).problem == "Choose at least one day.")
        #expect(JobSchedule(kind: .daily, timeZone: "Mars/Olympus").problem == "Choose a time zone.")
        #expect(Job(botID: UUID(), title: " ", prompt: "x").problem == "Give the job a title.")
        #expect(Job(botID: UUID(), title: "T", prompt: "").problem == "Say what the job should do.")
    }
}

@Suite struct JobPlannerTests {
    let at = JobScheduleTests.at
    /// Weekdays and weekends alike at 9:00 in New York.
    func job(handled: String, missed: MissedRunPolicy = .runOnce, window: TimeInterval = JobLimits.defaultCatchUpWindow) -> Job {
        var job = Job(botID: UUID(), title: "Triage", prompt: "Triage issues",
                      schedule: JobSchedule(kind: .daily, hour: 9, minute: 0, timeZone: JobScheduleTests.newYork),
                      missedRuns: missed, catchUpWindow: window, createdAt: at(handled))
        job.handledThrough = at(handled)
        return job
    }

    @Test func runsOnTime() {
        #expect(JobPlanner.decide(job(handled: "2026-10-23T14:00:00Z"), now: at("2026-10-24T13:02:00Z"))
            == .run(occurrence: at("2026-10-24T13:00:00Z"), trigger: .scheduled, coalesced: 0))
        #expect(JobPlanner.decide(job(handled: "2026-10-23T14:00:00Z"), now: at("2026-10-24T12:59:00Z")) == .none)
    }

    @Test func missedRunsFoldIntoOneCatchUp() {
        // Closed for three days: one late run, for this morning, and two mornings folded into it.
        #expect(JobPlanner.decide(job(handled: "2026-10-21T14:00:00Z"), now: at("2026-10-24T19:00:00Z"))
            == .run(occurrence: at("2026-10-24T13:00:00Z"), trigger: .catchUp, coalesced: 2))
    }

    @Test func catchUpHasAWindow() {
        let late = JobPlanner.decide(job(handled: "2026-10-23T14:00:00Z", window: 3600), now: at("2026-10-24T15:00:00Z"))
        guard case let .skip(occurrence, coalesced, reason) = late else { Issue.record("\(late)"); return }
        #expect(occurrence == at("2026-10-24T13:00:00Z"))
        #expect(coalesced == 0)
        #expect(reason.contains("catch-up window (1 h)"))
        #expect(JobPlanner.decide(job(handled: "2026-10-23T14:00:00Z", window: 3 * 3600), now: at("2026-10-24T15:00:00Z"))
            == .run(occurrence: at("2026-10-24T13:00:00Z"), trigger: .catchUp, coalesced: 0))
    }

    @Test func skipMissedRunsSkipsThem() {
        let decision = JobPlanner.decide(job(handled: "2026-10-22T14:00:00Z", missed: .skip), now: at("2026-10-24T15:00:00Z"))
        guard case let .skip(_, coalesced, reason) = decision else { Issue.record("\(decision)"); return }
        #expect(coalesced == 1)
        #expect(reason.contains("skips missed runs"))
        // On time is on time, whatever the policy.
        #expect(JobPlanner.decide(job(handled: "2026-10-23T14:00:00Z", missed: .skip), now: at("2026-10-24T13:01:00Z"))
            == .run(occurrence: at("2026-10-24T13:00:00Z"), trigger: .scheduled, coalesced: 0))
    }

    /// The editor's one missed-runs picker (#232): each choice says what happens, sets the policy
    /// and window the planner reads, and Skip keeps the window for when it runs them again.
    @Test func missedRunsAreOneChoiceThatSaysWhatHappens() {
        var edited = job(handled: "2026-10-23T14:00:00Z", window: 6 * 3600)
        #expect(MissedRunChoice(edited) == .runLatest(within: 6 * 3600))
        #expect(MissedRunChoice(edited).label == "Run latest missed run if within 6 hours")
        #expect(MissedRunChoice.choices(including: 6 * 3600).map(\.label) == [
            "Run latest missed run if within 1 hour", "Run latest missed run if within 6 hours",
            "Run latest missed run if within 1 day", "Run latest missed run if within 7 days", "Skip missed runs",
        ])
        MissedRunChoice.skip.apply(to: &edited)
        #expect(edited.missedRuns == .skip && edited.catchUpWindow == 6 * 3600)
        #expect(MissedRunChoice(edited) == .skip)
        let skipped = JobPlanner.decide(edited, now: at("2026-10-24T15:00:00Z"))
        guard case .skip = skipped else { Issue.record("\(skipped)"); return }
        MissedRunChoice.runLatest(within: 3600).apply(to: &edited)
        #expect(edited.missedRuns == .runOnce && edited.catchUpWindow == 3600)
        // A window saved elsewhere stays a choice, in order, as words.
        let custom = MissedRunChoice.choices(including: 3 * 3600)
        #expect(custom.count == 6 && custom[1] == .runLatest(within: 3 * 3600))
        #expect(custom[1].label == "Run latest missed run if within 3 hours")
        #expect(MissedRunChoice.runLatest(within: 90 * 60).label == "Run latest missed run if within 1 h 30 min")
        #expect(MissedRunChoice.choices(including: JobLimits.defaultCatchUpWindow).count == 5)
        // A window without limit, saved elsewhere, stays a choice that says so.
        #expect(MissedRunChoice.choices(including: .infinity).dropLast().last == .runLatest(within: .infinity))
        #expect(MissedRunChoice.runLatest(within: .infinity).label == "Run latest missed run, however late")
    }

    @Test func pausedJobsAndClockChanges() {
        var paused = job(handled: "2026-10-23T14:00:00Z")
        paused.enabled = false
        #expect(JobPlanner.decide(paused, now: at("2026-10-24T13:01:00Z")) == .none)
        #expect(paused.nextRun(now: at("2026-10-24T13:01:00Z")) == nil)
        // It ran at nine; the clock set back to eight runs nothing again, and next is tomorrow.
        let ran = job(handled: "2026-10-24T13:00:00Z")
        #expect(JobPlanner.decide(ran, now: at("2026-10-24T12:00:00Z")) == .none)
        #expect(ran.nextRun(now: at("2026-10-24T12:00:00Z")) == at("2026-10-25T13:00:00Z"))
        // Set forward two days: missed time, run once.
        #expect(JobPlanner.decide(ran, now: at("2026-10-26T15:00:00Z"))
            == .run(occurrence: at("2026-10-26T13:00:00Z"), trigger: .catchUp, coalesced: 1))
    }
}

/// The scheduler's state machine, with a clock and a store the test controls.
@Suite struct JobEngineTests {
    let at = JobScheduleTests.at

    final class FakeStore {
        var saved: [UUID: Job] = [:]
        var erased: [UUID] = []
        var failing = false
        func persist(_ job: Job) throws {
            if failing { throw CocoaError(.fileWriteNoPermission) }
            saved[job.id] = job
        }
    }

    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    func engine(_ jobs: [Job] = [], clock: Clock, store: FakeStore, max: Int = 2) -> JobEngine {
        JobEngine(jobs: jobs, now: { clock.now }, maxConcurrent: max, persist: store.persist, erase: { store.erased.append($0.id) })
    }

    func daily(_ bot: UUID = UUID(), hour: Int = 9, created: String = "2026-10-23T14:00:00Z") -> Job {
        Job(botID: bot, title: "Triage \(hour)", prompt: "Triage", schedule: JobSchedule(kind: .daily, hour: hour, minute: 0, timeZone: JobScheduleTests.newYork),
            createdAt: at(created))
    }

    func idle(_: UUID) -> Bool { false }

    @Test func reservesBeforeStartingAndNeverTwice() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        try engine.save(daily())
        let id = try #require(engine.jobs.first?.id)
        clock.now = at("2026-10-24T13:00:30Z")
        let launches = engine.tick(busy: idle)
        #expect(launches.count == 1)
        #expect(launches.first?.run.trigger == .scheduled)
        #expect(launches.first?.run.scheduledFor == at("2026-10-24T13:00:00Z"))
        // Saved, as running, with the occurrence handled, before the app starts it.
        #expect(store.saved[id]?.handledThrough == at("2026-10-24T13:00:00Z"))
        #expect(store.saved[id]?.runs.last?.outcome == .running)
        // Repeated timers and a wake don't start it again.
        #expect(engine.tick(busy: idle).isEmpty)
        clock.now = at("2026-10-24T13:03:00Z")
        #expect(engine.tick(busy: idle).isEmpty)
        // BotChu crashes; on the next launch the run is interrupted and not run again.
        let relaunched = self.engine(clock: clock, store: store)
        let interrupted = relaunched.load(Array(store.saved.values))
        #expect(interrupted.map(\.run.id) == launches.map(\.run.id))
        #expect(relaunched.job(id)?.runs.last?.outcome == .interrupted)
        #expect(store.saved[id]?.runs.last?.outcome == .interrupted)
        #expect(relaunched.tick(busy: idle).isEmpty)
        #expect(relaunched.job(id)?.nextRun(now: clock.now) == at("2026-10-25T13:00:00Z"))
    }

    @Test func aRunWaitingWhenBotChuQuitIsSkippedNotRun() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        try engine.save(daily())
        clock.now = at("2026-10-24T13:00:30Z")
        #expect(engine.tick(busy: { _ in true }).isEmpty)
        let relaunched = self.engine(clock: clock, store: store)
        #expect(relaunched.load(Array(store.saved.values)).isEmpty)
        #expect(relaunched.jobs.first?.runs.last?.outcome == .skipped)
        #expect(relaunched.jobs.first?.runs.last?.summary == "BotChu quit before this run started.")
        #expect(relaunched.tick(busy: idle).isEmpty)
    }

    @Test func aFailedSaveStartsNothing() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        try engine.save(daily())
        let id = try #require(engine.jobs.first?.id)
        clock.now = at("2026-10-24T13:00:30Z")
        store.failing = true
        #expect(engine.tick(busy: idle).isEmpty)
        #expect(engine.problems[id]?.hasPrefix("Couldn't save “Triage 9”") == true)
        #expect(engine.job(id)?.runs.isEmpty == true)
        #expect(engine.job(id)?.handledThrough == at("2026-10-23T14:00:00Z"))
        #expect(throws: JobEngine.Problem.self) { try engine.setEnabled(id, false) }
        // Once the store works again, the occurrence (still on time) starts.
        store.failing = false
        clock.now = at("2026-10-24T13:02:00Z")
        #expect(engine.tick(busy: idle).count == 1)
        #expect(engine.problems[id] == nil)
    }

    @Test func waitsForItsAgentsWorkspaceAndASlot() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store, max: 2)
        let bot = UUID(), other = UUID(), third = UUID()
        for job in [daily(bot), daily(bot, hour: 9), daily(other), daily(third)] { try engine.save(job) }
        clock.now = at("2026-10-24T13:00:30Z")
        // The agent's Home is mid-turn: its runs wait; the others take the two slots.
        let first = engine.tick(busy: { $0 == bot })
        #expect(Set(first.map(\.job.botID)) == [other, third])
        #expect(engine.jobs(of: bot).allSatisfy { $0.activeRun?.outcome == .waiting })
        // A slot frees, and Home is done: one of the agent's runs starts, the other still waits for it.
        let next = engine.finish(first[0].run.id, outcome: .succeeded, summary: "Done", busy: idle)
        #expect(next.count == 1)
        #expect(next.first?.job.botID == bot)
        #expect(engine.jobs(of: bot).filter { $0.activeRun?.outcome == .waiting }.count == 1)
        let last = engine.finish(next[0].run.id, outcome: .succeeded, quiet: true, summary: "Nothing", busy: idle)
        #expect(last.first?.job.botID == bot)
        #expect(engine.jobs(of: bot).flatMap(\.runs).first { $0.id == next[0].run.id }?.quiet == true)
    }

    @Test func neverOverlapsItself() throws {
        let clock = Clock(at("2026-10-24T13:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        var job = daily()
        job.schedule = JobSchedule(kind: .interval, every: 5, unit: .minutes, anchor: at("2026-10-24T13:00:00Z"), timeZone: JobScheduleTests.newYork)
        try engine.save(job)
        clock.now = at("2026-10-24T13:05:10Z")
        #expect(engine.tick(busy: idle).count == 1)
        clock.now = at("2026-10-24T13:10:10Z")
        #expect(engine.tick(busy: idle).isEmpty)
        clock.now = at("2026-10-24T13:15:10Z")
        #expect(engine.tick(busy: idle).isEmpty)
        let runs = try #require(engine.jobs.first?.runs)
        // One running run, and one skip record for both occurrences it ran over.
        #expect(runs.map(\.outcome) == [.running, .skipped])
        #expect(runs[1].summary == "Its previous run was still running.")
        #expect(runs[1].coalesced == 1)
        #expect(runs[1].scheduledFor == at("2026-10-24T13:15:00Z"))
        #expect(throws: JobEngine.Problem.busy) { _ = try engine.runNow(job.id, busy: idle) }
    }

    @Test func pausingCancelsWhatWaitsAndResumingDoesNotMakeUpTime() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        try engine.save(daily())
        let id = try #require(engine.jobs.first?.id)
        clock.now = at("2026-10-24T13:00:30Z")
        #expect(engine.tick(busy: { _ in true }).isEmpty)
        try engine.setEnabled(id, false)
        #expect(engine.job(id)?.runs.last?.outcome == .skipped)
        #expect(engine.job(id)?.runs.last?.summary == "The job was paused before this run started.")
        #expect(engine.tick(busy: idle).isEmpty)
        // Resumed three days later: no catch-up for the paused mornings.
        clock.now = at("2026-10-27T15:00:00Z")
        try engine.setEnabled(id, true)
        #expect(engine.tick(busy: idle).isEmpty)
        #expect(engine.job(id)?.nextRun(now: clock.now) == at("2026-10-28T13:00:00Z"))
    }

    @Test func runNowRunsAPausedJobWithoutResumingIt() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        var job = daily()
        job.enabled = false
        try engine.save(job)
        let launches = try engine.runNow(job.id, busy: idle)
        #expect(launches.first?.run.trigger == .manual)
        #expect(launches.first?.run.scheduledFor == nil)
        #expect(engine.job(job.id)?.enabled == false)
        #expect(engine.isRunning(botID: job.botID))
        _ = engine.finish(launches[0].run.id, outcome: .stopped, summary: "Stopped.", busy: idle)
        #expect(!engine.isRunning(botID: job.botID))
    }

    @Test func failuresInARowPauseTheJob() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        let job = daily()
        try engine.save(job)
        func run(_ outcome: JobOutcome) throws {
            let launch = try #require(try engine.runNow(job.id, busy: idle).first)
            _ = engine.finish(launch.run.id, outcome: outcome, summary: outcome.rawValue, busy: idle)
        }
        try run(.failed)
        try run(.failed)
        try run(.succeeded)
        #expect(engine.job(job.id)?.failureStreak == 0)
        for _ in 0..<3 { try run(.failed) }
        #expect(engine.job(job.id)?.enabled == false)
        #expect(engine.job(job.id)?.pauseReason == "Paused after 3 failed runs in a row. Fix what failed, then Resume.")
        // The last good result is still there.
        #expect(engine.job(job.id)?.lastSuccess?.summary == "succeeded")
        try engine.setEnabled(job.id, true)
        #expect(engine.job(job.id)?.pauseReason == nil)
        #expect(engine.job(job.id)?.failureStreak == 0)
    }

    @Test func historyIsBoundedButKeepsTheLastSuccess() {
        var runs = [JobRun(trigger: .manual, scheduledFor: nil, timeZone: "UTC", reservedAt: Date(), outcome: .succeeded, summary: "good")]
        runs += (0..<60).map { JobRun(trigger: .manual, scheduledFor: nil, timeZone: "UTC", reservedAt: Date(), outcome: .failed, summary: "\($0)") }
        let kept = JobEngine.trimmed(runs)
        #expect(kept.count == JobLimits.keptRuns + 1)
        #expect(kept.first?.summary == "good")
        #expect(kept.last?.summary == "59")
    }

    @Test func editingAScheduleCountsFromNow() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        var job = daily()
        try engine.save(job)
        clock.now = at("2026-10-24T15:00:00Z")
        job.schedule.hour = 10
        try engine.save(job)
        // Ten o'clock this morning passed before the change: not made up.
        #expect(engine.tick(busy: idle).isEmpty)
        #expect(engine.job(job.id)?.nextRun(now: clock.now) == at("2026-10-25T14:00:00Z"))
        #expect(throws: JobEngine.Problem.invalid("Give the job a title.")) {
            var untitled = job
            untitled.title = ""
            try engine.save(untitled)
        }
    }

    @Test func deletingAndForgettingAnAgent() throws {
        let clock = Clock(at("2026-10-23T14:00:00Z")), store = FakeStore()
        let engine = engine(clock: clock, store: store)
        let bot = UUID()
        let job = daily(bot), other = daily(bot, hour: 10)
        try engine.save(job)
        try engine.save(other)
        let running = try engine.runNow(job.id, busy: idle)
        #expect(try engine.delete(job.id)?.id == running.first?.run.id)
        #expect(store.erased == [job.id])
        #expect(engine.job(job.id) == nil)
        // A deleted job's run ending changes nothing.
        #expect(engine.finish(running[0].run.id, outcome: .succeeded, summary: "x", busy: idle).isEmpty)
        #expect(engine.forget(botID: bot).isEmpty)
        #expect(engine.jobs.isEmpty)
    }
}

@Suite struct JobStorageTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-jobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func jobsAndTranscriptsMoveWithTheAgent() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Duck", workspace: root.appendingPathComponent("duck").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        // Whole seconds, as job.json keeps them.
        let made = JobScheduleTests.at("2026-10-23T14:00:00Z")
        var job = Job(botID: bot.id, title: "Triage", prompt: "Triage", schedule: JobSchedule(kind: .weekdays, anchor: made, timeZone: "America/New_York"),
                      createdAt: made)
        var run = JobRun(trigger: .manual, scheduledFor: nil, timeZone: "America/New_York", reservedAt: made, outcome: .succeeded, summary: "Found two")
        run.accountID = "claude-dev"
        job.runs = [run]
        try home.save(job)
        try home.saveJobThread([ChatMessage(role: .assistant, text: "Found two")], job: job.id, run: run.id)
        // A job copied from another agent's folder never runs as this one.
        try home.save(Job(botID: UUID(), title: "Not mine", prompt: "x"))
        #expect(home.loadJobs(of: bot.id).map(\.title) == ["Triage"])

        let moved = root.appendingPathComponent("moved").path
        try home.move(toWorkspace: moved)
        let there = BotHome(workspace: moved)
        let loaded = there.loadJobs(of: bot.id)
        #expect(loaded == [job])
        #expect(there.loadJobThread(job: job.id, run: run.id).map(\.text) == ["Found two"])
        #expect(!home.hasJob(job.id))
        #expect(there.hasJob(job.id))
    }

    @Test func savingPrunesTranscriptsOfRunsNoLongerKept() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        var job = Job(botID: UUID(), title: "T", prompt: "P")
        let old = JobRun(trigger: .manual, scheduledFor: nil, timeZone: "UTC", reservedAt: Date(), outcome: .failed)
        let new = JobRun(trigger: .manual, scheduledFor: nil, timeZone: "UTC", reservedAt: Date(), outcome: .succeeded)
        job.runs = [old, new]
        try home.save(job)
        for run in [old, new] { try home.saveJobThread([ChatMessage(role: .assistant, text: "x")], job: job.id, run: run.id) }
        job.runs = [new]
        try home.save(job)
        #expect(!FileManager.default.fileExists(atPath: home.jobRunThreadURL(job: job.id, run: old.id).path))
        #expect(FileManager.default.fileExists(atPath: home.jobRunThreadURL(job: job.id, run: new.id).path))
        try home.removeJob(job.id)
        #expect(home.loadJobs(of: job.botID).isEmpty)
    }

    @Test func aJobFileThatCantBeWrittenStopsTheRun() throws {
        let root = try folder()
        let home = BotHome(workspace: root.path)
        let clock = JobEngineTests.Clock(JobScheduleTests.at("2026-10-23T14:00:00Z"))
        let engine = JobEngine(now: { clock.now }, persist: home.save)
        let job = Job(botID: UUID(), title: "Locked", prompt: "P",
                      schedule: JobSchedule(kind: .daily, hour: 9, timeZone: "America/New_York"), createdAt: clock.now)
        try engine.save(job)
        let file = home.jobURL(job.id).appendingPathComponent("job.json")
        func lock(_ locked: Bool) throws { try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: file.path) }
        try lock(true)
        defer {
            try? lock(false)
            try? FileManager.default.removeItem(at: root)
        }
        clock.now = JobScheduleTests.at("2026-10-24T13:00:30Z")
        #expect(engine.tick(busy: { _ in false }).isEmpty)
        #expect(engine.problems[job.id] != nil)
        try lock(false)
        #expect(engine.tick(busy: { _ in false }).count == 1)
        #expect(home.loadJobs(of: job.botID).first?.runs.last?.outcome == .running)
    }
}

@Suite struct JobRunTests {
    let at = JobScheduleTests.at

    func bot() -> Bot {
        var bot = Bot(name: "QA Duck", title: "A Duck that QAs", accountID: "claude-dev", workspace: "/tmp/duck")
        bot.sessionID = "home-session-1234"
        bot.sessionAccountID = "claude-dev"
        return bot
    }

    @Test func aRunStartsAFreshSessionOfItsOwn() {
        let bot = bot()
        let invocation = JobLaunch.invocation(for: bot, prompt: "Run the job", openRouterDefault: "", openRouterKey: "sk-or-secret")
        #expect(!invocation.arguments.contains("home-session-1234"))
        #expect(!invocation.arguments.contains("--resume"))
        #expect(invocation.input == nil)
        #expect(invocation.environment["OPENROUTER_API_KEY"] == nil)
    }

    @Test func itsContextIsTheAgentAndTheRunNotHome() {
        let bot = bot()
        let job = Job(botID: bot.id, title: "Morning issue triage", prompt: "Triage new issues",
                      schedule: JobSchedule(kind: .weekdays, hour: 9, minute: 0, timeZone: JobScheduleTests.newYork))
        var run = JobRun(trigger: .catchUp, scheduledFor: at("2026-10-23T13:00:00Z"), timeZone: JobScheduleTests.newYork,
                         reservedAt: at("2026-10-23T18:14:00Z"), coalesced: 1)
        run.startedAt = at("2026-10-23T18:14:00Z")
        let text = JobSchedule.plainText(JobLaunch.preamble(bot: bot, job: job, run: run, startedAt: at("2026-10-23T18:14:00Z"),
                                                            memory: "- Owner likes tables", sharedMemory: "", instructions: "Review pull requests."))
        #expect(text.contains("You are QA Duck — A Duck that QAs"))
        #expect(text.contains("“Morning issue triage”"))
        #expect(text.contains("Owner likes tables"))
        #expect(text.contains("Review pull requests."))
        #expect(text.contains("Fri, Oct 23 at 9:00 AM EDT"), "\(text)")
        #expect(text.contains("5 h 14 min late"))
        #expect(text.contains("1 earlier time was missed"))
        #expect(text.contains(JobResult.quietMarker))
        #expect(text.contains("This is not your Home conversation"))
        #expect(!text.contains("<recent_conversation>"))
        #expect(!text.contains("<home_conversation>"))
        let manual = JobRun(trigger: .manual, scheduledFor: nil, timeZone: JobScheduleTests.newYork, reservedAt: at("2026-10-23T18:14:00Z"))
        #expect(JobLaunch.preamble(bot: bot, job: job, run: manual, startedAt: at("2026-10-23T18:14:00Z"), memory: "", sharedMemory: "")
            .contains("Your owner started this run with Run Now"))
    }

    /// A scheduled run reaches other bots and the owner's Inbox as a turn does (#170), and its
    /// context says how its report gets there.
    @Test func itsContextTeachesTheInboxAndHowItsReportReachesIt() {
        let bot = bot()
        let job = Job(botID: bot.id, title: "10x Product Analysis", prompt: "Recommend features",
                      schedule: JobSchedule(kind: .daily, hour: 6, minute: 0, timeZone: JobScheduleTests.newYork))
        let run = JobRun(trigger: .scheduled, scheduledFor: at("2026-10-26T10:00:00Z"), timeZone: JobScheduleTests.newYork, reservedAt: Date())
        let roster = [BotRosterEntry(bot: bot), BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))]
        let text = JobSchedule.plainText(JobLaunch.preamble(bot: bot, job: job, run: run, startedAt: at("2026-10-26T10:00:05Z"),
                                                            memory: "", sharedMemory: "", availableBots: roster))
        for expected in ["botchu-inbox send --purpose", "botchu-subagent call", "--ask", "names the delivery it answers",
                         "your report reaches their Inbox, linked to this run's task", "BotChu delivers your final reply there when you sent nothing",
                         "you send nothing to their Inbox", JobResult.quietMarker] {
            #expect(text.contains(expected), "Missing \(expected)")
        }
        #expect(!text.contains("You are a sub-agent run"))
        #expect(text.hasSuffix("The job's instructions follow.\n</botchu_job_context>"))
    }

    /// A finding the run sent nothing of goes to the Inbox as its task's, with the whole reply and
    /// the run's ID, so delivering it again never adds another; nothing else does (#170).
    @Test func aFindingItSentNothingOfIsItsReport() {
        let job = Job(botID: UUID(), title: "10x Product Analysis", prompt: "x", schedule: JobSchedule(kind: .daily, timeZone: JobScheduleTests.newYork))
        var run = JobRun(trigger: .scheduled, scheduledFor: at("2026-10-26T10:00:00Z"), timeZone: JobScheduleTests.newYork, reservedAt: Date())
        run.taskID = UUID()
        let finding = JobResult.Classified(outcome: .succeeded, quiet: false, summary: "20 recommendations")
        #expect(JobReport.isDue(finding, delivered: false))
        #expect(!JobReport.isDue(finding, delivered: true))
        #expect(!JobReport.isDue(JobResult.Classified(outcome: .succeeded, quiet: true, summary: "Nothing to report."), delivered: false))
        for outcome in [JobOutcome.failed, .stopped, .interrupted] {
            #expect(!JobReport.isDue(JobResult.Classified(outcome: outcome, quiet: false, summary: "x"), delivered: false))
        }
        let reply = "## 20 recommendations\n\n1. Saved searches\n2. Bulk close\n\n<remember>- Owner likes tables</remember>"
        let delivery = JobReport.delivery(job: job, run: run, reply: reply, at: at("2026-10-26T10:06:20Z"))
        #expect(delivery?.id == run.id && delivery?.botID == job.botID && delivery?.taskID == run.taskID)
        #expect(delivery?.title == "10x Product Analysis")
        #expect(delivery?.note == "## 20 recommendations\n\n1. Saved searches\n2. Bulk close")
        #expect(delivery?.sentAt == at("2026-10-26T10:06:20Z") && delivery?.files.isEmpty == true && delivery?.question == nil)
        // A finding that asks nothing of the owner (#217).
        #expect(delivery?.purpose == .fyi)
        #expect(JobReport.delivery(job: job, run: run, reply: "<remember>- private</remember>") == nil)
        // A reply too long for a note is cut at a character, within the limit.
        let long = try! #require(JobReport.delivery(job: job, run: run, reply: String(repeating: "é", count: InboxRequest.maxNoteBytes))).note
        #expect(long.utf8.count <= InboxRequest.maxNoteBytes && long.hasSuffix("é…"))
    }

    /// A report waiting for the Inbox is kept with its run; runs saved before reports went there
    /// read as waiting for nothing, so none is delivered late.
    @Test func aReportWaitingForTheInboxIsSavedWithItsRun() throws {
        var run = JobRun(trigger: .manual, scheduledFor: nil, timeZone: JobScheduleTests.newYork, reservedAt: at("2026-10-26T10:00:00Z"))
        run.outcome = .succeeded
        run.reportPending = true
        let data = try Store.encoder.encode(run)
        #expect(try Store.decoder.decode(JobRun.self, from: data).reportPending == true)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["reportPending"] = nil
        let older = try Store.decoder.decode(JobRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.reportPending == nil && older.outcome == .succeeded)
    }

    @Test func quietEmptyAndFailedResults() {
        func classify(_ reply: String?, failure: String? = nil, status: Int32 = 0, finished: Bool = true, stopped: Bool = false,
                      timedOut: Bool = false) -> JobResult.Classified {
            JobResult.classify(reply: reply, failure: failure, status: status, finished: finished, stopped: stopped, timedOut: timedOut,
                               timeLimit: 1800, accountName: "Claude Dev")
        }
        #expect(classify("Checked 12 issues.\n\nNOTHING_TO_REPORT") == JobResult.Classified(outcome: .succeeded, quiet: true, summary: "Checked 12 issues."))
        #expect(classify("NOTHING_TO_REPORT") == JobResult.Classified(outcome: .succeeded, quiet: true, summary: "Nothing to report."))
        #expect(classify("Two new bugs:\n- #12 crash\n- #13 typo") == JobResult.Classified(outcome: .succeeded, quiet: false, summary: "Two new bugs: - #12 crash - #13 typo"))
        // Empty output is never mistaken for a quiet success.
        #expect(classify("  ").outcome == .failed)
        #expect(classify(nil).summary.contains("finished without a reply"))
        #expect(classify("partial", status: 1, finished: false).outcome == .failed)
        #expect(classify("Done", status: 1).outcome == .succeeded)
        #expect(classify("partial", finished: false).outcome == .failed)
        #expect(classify("x", stopped: true) == JobResult.Classified(outcome: .stopped, quiet: false, summary: "Stopped."))
        #expect(classify("x", stopped: true, timedOut: true).summary == "Stopped after its time limit of 30 min. It may have done part of its work.")
        #expect(classify(nil, failure: "API Error: 429 rate limit exceeded").summary.hasSuffix("— Claude Dev is out of allowance for now; it runs again at its next time, or Run Now once it resets."))
        #expect(classify(nil, failure: "Invalid API key · Please run /login").summary.hasSuffix("— Sign in to Claude Dev in Terminal, then Run Now."))
        #expect(classify(nil, status: 127, finished: false).summary.contains("Check Claude Dev's command in Settings."))
        #expect(JobFailure.explain("Couldn't save the run: disk full", accountName: "A").hasSuffix("writable and its disk has space."))
        #expect(JobFailure.explain("getaddrinfo ENOTFOUND api.anthropic.com", accountName: "A").hasSuffix("Check the network connection, then Run Now."))
    }

    @Test func homeHearsOfFindingsAndFailuresOnly() {
        var run = JobRun(trigger: .scheduled, scheduledFor: at("2026-10-23T13:00:00Z"), timeZone: JobScheduleTests.newYork, reservedAt: Date())
        let job = Job(botID: UUID(), title: "Triage", prompt: "x", schedule: JobSchedule(kind: .daily, timeZone: JobScheduleTests.newYork))
        let expected: [JobOutcome: Bool] = [.waiting: false, .running: false, .succeeded: true, .failed: true, .stopped: false, .skipped: false, .interrupted: true]
        for (outcome, receipt) in expected {
            run.outcome = outcome
            #expect(run.needsReceipt == receipt, "\(outcome)")
        }
        run.outcome = .succeeded
        run.quiet = true
        #expect(!run.needsReceipt)
        run.outcome = .failed
        run.summary = "Boom"
        #expect(JobSchedule.plainText(JobReceipt.text(job: job, run: run, locale: Locale(identifier: "en_US"))) == "Job “Triage” failed · 9:00 AM: Boom")
    }
}

extension JobSchedule {
    static func plainText(_ text: String) -> String { JobScheduleTests.plain(text) }
}

/// A job's own account, model and effort (#132): none runs it on its agent's, as before; the choice
/// is saved with it, older jobs read as none, and a choice BotChu can't run falls back to the agent's,
/// saying why, never to another provider.
@Suite struct JobRunsOnTests {
    static let research = Account(id: "custom-research", name: "Research", kind: .codex, defaultCommand: "codex-research", symbol: "terminal")

    func agent() -> Bot {
        Bot(name: "QA Duck", accountID: "claude-dev", model: "opus", reasoningEffort: .high, workspace: "/tmp/duck")
    }

    @Test func aJobWithoutItsOwnRunsOnItsAgentsAsTheyAreThen() {
        var agent = agent()
        let job = Job(botID: agent.id, title: "Triage", prompt: "Triage")
        #expect(job.runsOn == nil)
        #expect(job.runSettings(agent: agent, accounts: Accounts.all).settings == agent)
        #expect(job.runSettings(agent: agent, accounts: Accounts.all).unavailable == nil)
        // It follows the agent's later changes.
        agent.selectAccount(Accounts.account(id: "codex-work"))
        agent.selectModel("gpt-6-astra")
        let settings = job.runSettings(agent: agent, accounts: Accounts.all).settings
        #expect(settings.accountID == "codex-work")
        #expect(settings.model == "gpt-6-astra")
        #expect(JobLaunch.invocation(for: settings, prompt: "Run", openRouterDefault: "", openRouterKey: nil).arguments
            == JobLaunch.invocation(for: agent, prompt: "Run", openRouterDefault: "", openRouterKey: nil).arguments)
    }

    @Test func aRunUsesTheJobsAccountModelAndEffort() {
        let agent = agent()
        var job = Job(botID: agent.id, title: "Triage", prompt: "Triage")
        job.selectAccount(Accounts.account(id: "codex-work"), agent: agent)
        job.selectModel("gpt-6-astra", agent: agent)
        job.selectReasoningEffort(.ultra, agent: agent, openRouterDefault: "")
        #expect(job.runsOn == JobRunsOn(accountID: "codex-work", model: "gpt-6-astra", reasoningEffort: .ultra))
        let (settings, unavailable) = job.runSettings(agent: agent, accounts: Accounts.all)
        #expect(unavailable == nil)
        #expect(settings.account.id == "codex-work")
        // Still the agent, apart from what it runs on.
        #expect(settings.id == agent.id)
        #expect(settings.workspace == agent.workspace)
        let arguments = JobLaunch.invocation(for: settings, prompt: "Run the job", openRouterDefault: "", openRouterKey: nil).arguments
        #expect(arguments.starts(with: ["exec", "--json"]))
        #expect(arguments.contains("-m"))
        #expect(arguments.contains("gpt-6-astra"))
        #expect(arguments.contains("model_reasoning_effort=\"ultra\""))
        #expect(!arguments.contains("opus"))
        #expect(JobLaunch.startNote(account: settings.account, agent: agent.name, unavailable: unavailable) == "Started on Codex Work")
    }

    @Test func effortsFollowTheChosenAccountAndModel() {
        let agent = agent()
        var job = Job(botID: agent.id, title: "Triage", prompt: "Triage")
        // Changing the model alone keeps the agent's account, and an effort the model takes.
        job.selectModel("sonnet", agent: agent)
        #expect(job.runsOn == JobRunsOn(accountID: "claude-dev", model: "sonnet", reasoningEffort: .high))
        // Haiku takes no effort: the effort goes, and none can be chosen.
        job.selectModel("haiku", agent: agent)
        #expect(job.runsOn?.reasoningEffort == nil)
        job.selectReasoningEffort(.high, agent: agent, openRouterDefault: "")
        #expect(job.runsOn?.reasoningEffort == nil)
        // Ultra is Codex's, not Claude Code's.
        job.selectModel("opus", agent: agent)
        job.selectReasoningEffort(.ultra, agent: agent, openRouterDefault: "")
        #expect(job.runsOn?.reasoningEffort == nil)
        job.selectReasoningEffort(.max, agent: agent, openRouterDefault: "")
        #expect(job.runsOn?.reasoningEffort == .max)
        // Another account of the same CLI keeps the model and effort; another CLI clears them.
        job.selectAccount(Accounts.account(id: "claude-work"), agent: agent)
        #expect(job.runsOn == JobRunsOn(accountID: "claude-work", model: "opus", reasoningEffort: .max))
        job.selectAccount(Accounts.account(id: "openrouter"), agent: agent)
        #expect(job.runsOn == JobRunsOn(accountID: "openrouter", model: "", reasoningEffort: nil))
        // OpenRouter's effort applies to the default model from Settings.
        job.selectReasoningEffort(.off, agent: agent, openRouterDefault: "anthropic/claude-sonnet-4.5")
        #expect(job.runsOn?.reasoningEffort == .off)
        // Choosing the agent's again drops the job's own choice.
        job.selectAccount(nil, agent: agent)
        #expect(job.runsOn == nil)
    }

    @Test func theChoiceIsSavedWithTheJobAndOlderJobsReadAsTheAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = agent()
        let home = BotHome(workspace: root.path)
        let made = JobScheduleTests.at("2026-10-23T14:00:00Z")
        var job = Job(botID: agent.id, title: "Research digest", prompt: "Summarize", schedule: JobSchedule(anchor: made, timeZone: "UTC"),
                      createdAt: made)
        job.selectAccount(Self.research, agent: agent)
        job.selectModel("gpt-6-luna", agent: agent)
        job.selectReasoningEffort(.medium, agent: agent, openRouterDefault: "")
        #expect(job.runsOn == JobRunsOn(accountID: Self.research.id, accountProfile: Self.research, model: "gpt-6-luna", reasoningEffort: .medium))
        try home.save(job)
        #expect(home.loadJobs(of: agent.id) == [job])
        // A job with none saves none, so its file is as it was before jobs had their own.
        var plain = job
        plain.runsOn = nil
        let text = String(decoding: try Store.encoder.encode(plain), as: UTF8.self)
        #expect(!text.contains("runsOn"))

        // job.json as BotChu saved it before #132.
        let old = """
        {"botID":"\(agent.id.uuidString)","catchUpWindow":604800,"createdAt":"2026-10-23T14:00:00Z","enabled":true,
         "failureStreak":0,"handledThrough":"2026-10-23T14:00:00Z","id":"5A1B2C3D-0000-4000-8000-0000000000AA",
         "missedRuns":"runOnce","prompt":"Triage","runs":[],"schedule":{"anchor":"2026-10-23T14:00:00Z","days":[],"every":1,
         "hour":9,"kind":"daily","minute":0,"timeZone":"America/New_York","unit":"hours"},"timeLimit":1800,"title":"Triage",
         "updatedAt":"2026-10-23T14:00:00Z"}
        """
        let decoded = try Store.decoder.decode(Job.self, from: Data(old.utf8))
        #expect(decoded.title == "Triage")
        #expect(decoded.runsOn == nil)
        #expect(decoded.runSettings(agent: agent, accounts: Accounts.all).settings == agent)
    }

    @Test func aGoneAccountFallsBackToTheAgentsSayingSo() {
        let agent = agent()
        var job = Job(botID: agent.id, title: "Research digest", prompt: "Summarize")
        job.selectAccount(Self.research, agent: agent)
        job.selectModel("gpt-6-luna", agent: agent)
        // While the profile is in Providers, runs use it, with its current details.
        let renamed = Account(id: Self.research.id, name: "Research (new login)", kind: .codex, defaultCommand: "codex-research-2", symbol: "terminal")
        let present = job.runSettings(agent: agent, accounts: Accounts.all + [renamed])
        #expect(present.unavailable == nil)
        #expect(present.settings.account == renamed)
        #expect(present.settings.model == "gpt-6-luna")
        // Once it's gone, runs use the agent's: its account, model and effort, never the first
        // account BotChu offers (Claude Personal) or the job's model on another CLI.
        let gone = job.runSettings(agent: agent, accounts: Accounts.all)
        #expect(gone.unavailable == .account(name: "Research"))
        #expect(gone.settings == agent)
        #expect(gone.settings.account.id == "claude-dev")
        #expect(job.runsOn?.accountID == Self.research.id, "The choice stays, so it works again if the profile comes back")
        #expect(JobLaunch.startNote(account: gone.settings.account, agent: agent.name, unavailable: gone.unavailable)
            == "Started on Claude Dev. Research is no longer in Providers, so this job runs on QA Duck's account, model and effort.")
        // A choice saved without its profile still names what it was.
        let bare = JobRunsOn(accountID: "custom-gone")
        #expect(bare.unavailable(accounts: Accounts.all) == .account(name: "custom-gone"))
    }

    @Test func aModelOpenRouterNoLongerListsFallsBackToTheAgents() {
        let agent = agent()
        let catalog = [CatalogModel(id: "anthropic/claude-sonnet-4.5", name: "Anthropic: Claude Sonnet 4.5"),
                       CatalogModel(id: "openai/gpt-6", name: "OpenAI: GPT-6")]
        var job = Job(botID: agent.id, title: "Digest", prompt: "Summarize")
        job.selectAccount(Accounts.account(id: "openrouter"), agent: agent)
        job.selectModel("retired/model-1", agent: agent)
        let gone = job.runSettings(agent: agent, accounts: Accounts.all, catalog: catalog)
        #expect(gone.unavailable == .model("retired/model-1"))
        #expect(gone.settings == agent)
        #expect(gone.unavailable?.explanation(agent: agent.name)
            == "OpenRouter no longer lists retired/model-1, so this job runs on QA Duck's account, model and effort.")
        // While the catalog isn't known, the model is used as chosen.
        #expect(job.runSettings(agent: agent, accounts: Accounts.all).settings.model == "retired/model-1")
        job.selectModel("openai/gpt-6", agent: agent)
        #expect(job.runSettings(agent: agent, accounts: Accounts.all, catalog: catalog).unavailable == nil)
        // The default from Settings is the agent's too, so it's never the job's to lose.
        job.selectModel("", agent: agent)
        #expect(job.runSettings(agent: agent, accounts: Accounts.all, catalog: catalog).unavailable == nil)
        // A CLI's own models and custom IDs aren't in any catalog: they run as chosen.
        job.selectAccount(Accounts.account(id: "codex-dev"), agent: agent)
        job.selectModel("gpt-custom-preview", agent: agent)
        #expect(job.runSettings(agent: agent, accounts: Accounts.all, catalog: catalog).unavailable == nil)
    }
}
