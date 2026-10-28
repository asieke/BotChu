import Foundation
import Testing
@testable import BotChuCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// The analytics dashboard (#233): turns, job runs and sub-agent runs read from BotChu's own records
/// into counts, durations and outcomes by local calendar day, with missing data, retries, stopped and
/// in-progress work and day boundaries; what the snapshot and its page leave out; and the page's file,
/// readable only by this user, loading nothing.
@Suite struct AnalyticsTests {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    let base = Self.at("2026-10-26T13:00:00Z")

    func message(_ role: ChatMessage.Role, _ text: String = "", at seconds: TimeInterval, tool: TimeInterval? = nil) -> ChatMessage {
        var message = ChatMessage(role: role, text: text, date: base.addingTimeInterval(seconds))
        if role == .tool {
            message.toolName = "Bash"
            message.toolInput = "ls"
            message.toolState = .done
            message.toolDuration = tool
        }
        return message
    }

    // MARK: Turns

    @Test func aConversationSplitsIntoTurnsWhereAMessageStartsOne() {
        let messages = [
            // The bot's introduction, asked for without a message of the owner's.
            message(.assistant, "Hi, I'm Product Fox.", at: 0),
            message(.user, "Triage the issues", at: 60),
            message(.tool, at: 70, tool: 50),
            message(.assistant, "Done.", at: 125),
            // BotChu's own lines afterwards (a receipt hours later) are no part of the turn.
            ChatMessage(role: .receipt, text: "GitChu #48 finished its turn", date: base.addingTimeInterval(7_200)),
            message(.user, "Fix #48", at: 7_300),
            message(.error, "Codex reconnecting", at: 7_310),
            message(.assistant, "Working on it", at: 7_320),
            message(.error, "You've hit your usage limit", at: 7_400),
            message(.user, "Try again", at: 7_500),
            message(.assistant, "Looking", at: 7_510),
            ChatMessage.stopNote(byOwner: true, date: base.addingTimeInterval(7_530)),
            // A new session note alone is no turn.
            ChatMessage(role: .note, text: "New session", date: base.addingTimeInterval(7_600)),
        ]
        let turns = Analytics.turns(messages, running: false)
        #expect(turns.map(\.outcome) == [.finished, .finished, .failed, .stopped])
        #expect(turns.map(\.seconds) == [0, 65, 100, 30])
        #expect(turns[1].start == base.addingTimeInterval(60))
        // The tool call's own duration ends its turn when it is the last thing done.
        let tool = Analytics.turns([message(.user, at: 0), message(.tool, at: 5, tool: 40)], running: false)
        #expect(tool == [AnalyticsTurn(start: base, end: base.addingTimeInterval(45), outcome: .finished, messageID: tool.first?.messageID)])
        #expect(Analytics.turns([], running: true).isEmpty)
    }

    @Test func aMessageThatWaitedInTheQueueStartsWhenTheTurnBeforeEnded() {
        // The follow-up was written at 0:20, while the first turn ran until 1:00, and went out after it.
        let turns = Analytics.turns([
            message(.user, "Build it", at: 0),
            message(.assistant, "Built.", at: 60),
            message(.user, "And test it", at: 20),
            message(.assistant, "Tested.", at: 90),
        ], running: false)
        #expect(turns.map(\.seconds) == [60, 30])
        #expect(turns[1].start == base.addingTimeInterval(60))
    }

    @Test func onlyARunningConversationsLastTurnIsInProgress() {
        let messages = [
            message(.user, "First", at: 0), message(.assistant, "One", at: 10),
            message(.user, "Second", at: 20), message(.tool, at: 25),
        ]
        let running = Analytics.turns(messages, running: true)
        #expect(running.map(\.outcome) == [.finished, .inProgress])
        #expect(running[1].seconds == nil && running[1].end == nil)
        // Just sent, before the bot has said anything.
        #expect(Analytics.turns(Array(messages.prefix(3)), running: true).map(\.outcome) == [.finished, .inProgress])
        // Not running: as saved, the last turn ended; a message nobody answered isn't a turn.
        #expect(Analytics.turns(messages, running: false).map(\.outcome) == [.finished, .finished])
        #expect(Analytics.turns(Array(messages.prefix(3)), running: false).map(\.outcome) == [.finished])
    }

    // MARK: Records

    func builder(now: Date? = nil) -> AnalyticsBuilder {
        AnalyticsBuilder(zone: Self.newYork, now: now ?? base.addingTimeInterval(86_400))
    }

    @Test func retriesCountEveryTurnAndTheTaskStandsByItsLatest() {
        let bot = Bot(name: "10x Engineer", accountID: "claude-dev", workspace: "/tmp/10x")
        var builder = builder()
        builder.bot(bot.id, name: bot.name)
        let task = BotTask(repo: "asieke/BotChu", checkout: "/tmp/BotChu", work: BotTask.Work(number: 48, isPullRequest: false, repo: "asieke/BotChu"),
                           origin: .home, accountID: "codex-work", createdAt: base)
        let turns = Analytics.turns([
            message(.user, "Fix #48", at: 0), message(.error, "Rate limited", at: 30),
            message(.user, "Retry", at: 100), message(.assistant, "Fixed.", at: 400),
        ], running: false)
        builder.add(turns: turns, bot: bot, task: task)
        var review = BotTask(repo: "asieke/botchu", checkout: "/tmp/BotChu", work: BotTask.Work(number: 50, isPullRequest: true, repo: "asieke/BotChu"),
                             createdAt: base, archivedAt: base, review: .review)
        review.accountID = "codex-work"
        builder.add(turns: [], bot: bot, task: review)
        let snapshot = builder.snapshot()
        #expect(snapshot.records.map(\.outcome) == [.failed, .finished])
        #expect(snapshot.records.map(\.seconds) == [30, 300])
        #expect(snapshot.records.allSatisfy { $0.kind == .task && $0.project == 0 && $0.account == 0 })
        // One project whatever the repository's case; the task's own account, by its name.
        #expect(snapshot.projects == ["asieke/BotChu"])
        #expect(snapshot.accounts == [AnalyticsAccount(name: "Codex Work", family: "Codex")])
        #expect(snapshot.tasks == [
            AnalyticsTask(day: "2026-10-26", bot: 0, account: 0, project: 0, work: .issue, origin: .home, open: true, turns: 2, latest: .finished, id: task.id, workNumber: 48),
            AnalyticsTask(day: "2026-10-26", bot: 0, account: 0, project: 0, work: .review, origin: .owner, open: false, turns: 0, latest: nil, id: review.id, workNumber: 50),
        ])
        let summary = AnalyticsSummary(snapshot.records, from: "2026-10-26", through: "2026-10-26")
        #expect(summary.runs == 2 && summary.ended == 2 && summary.outcomes[.failed] == 1)
        #expect(summary.failureRate == 0.5)
    }

    @Test func jobRunsCountOnceOnTheAccountTheyRecorded() throws {
        let agent = Bot(name: "Product Fox", accountID: "claude-personal", workspace: "/tmp/fox")
        var builder = builder()
        builder.bot(agent.id, name: agent.name)
        let job = Job(botID: agent.id, title: "Morning triage", prompt: "Triage", schedule: JobSchedule(timeZone: "America/New_York"))
        func run(_ outcome: JobOutcome, started: TimeInterval?, finished: TimeInterval?, account: String? = "codex-work",
                 name: String? = "Codex Work") -> JobRun {
            var run = JobRun(trigger: .scheduled, scheduledFor: base, timeZone: "America/New_York", reservedAt: base.addingTimeInterval(-5),
                             outcome: outcome)
            run.startedAt = started.map(base.addingTimeInterval)
            run.finishedAt = finished.map(base.addingTimeInterval)
            run.accountID = account
            run.accountName = name
            return run
        }
        let runs = [
            run(.succeeded, started: 10, finished: 610),
            run(.failed, started: 10, finished: nil),
            run(.stopped, started: 10, finished: 70),
            run(.interrupted, started: 10, finished: nil),
            run(.running, started: 10, finished: nil),
            run(.waiting, started: nil, finished: nil),
            run(.skipped, started: nil, finished: nil),
            // A run that never started, and one whose clock went backwards: unknown, never zero.
            run(.failed, started: nil, finished: 20),
            run(.succeeded, started: 600, finished: 10),
            // A profile that is gone, by the name it recorded; and one from before runs recorded theirs.
            run(.succeeded, started: 10, finished: 70, account: "profile-night", name: "Claude Night"),
            run(.succeeded, started: 10, finished: 70, account: nil, name: nil),
        ]
        for run in runs { builder.add(run, of: agent.id) }
        // A run of an agent BotChu doesn't have isn't counted.
        builder.add(run(.succeeded, started: 0, finished: 1), of: UUID())
        let snapshot = builder.snapshot()
        #expect(snapshot.records.map(\.outcome) == [.finished, .failed, .stopped, .interrupted, .inProgress, .inProgress, .skipped, .failed,
                                                    .finished, .finished, .finished])
        #expect(snapshot.records.map(\.seconds) == [600, nil, 60, nil, nil, nil, nil, nil, nil, 60, 60])
        #expect(snapshot.records.allSatisfy { $0.kind == .job && $0.project == nil && $0.day == "2026-10-26" })
        #expect(snapshot.records.map(\.account) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, nil])
        #expect(snapshot.accounts == [AnalyticsAccount(name: "Codex Work", family: "Codex"), AnalyticsAccount(name: "Claude Night", family: "Unknown")])
        let summary = AnalyticsSummary(snapshot.records, from: "2026-10-26", through: "2026-10-26")
        #expect(summary.runs == 10 && summary.skipped == 1)
        #expect(summary.outcomes == [.finished: 4, .failed: 2, .stopped: 1, .interrupted: 1, .inProgress: 2])
        #expect(summary.ended == 8 && summary.timed == 4)
        #expect(summary.medianSeconds == 60 && summary.totalSeconds == 780)
        #expect(summary.failureRate == 0.25)
        // A run's day is when it started, else the time it was for, else when it was reserved.
        var late = run(.succeeded, started: 60_000, finished: 60_100)
        late.scheduledFor = base
        var manual = run(.skipped, started: nil, finished: nil)
        manual.scheduledFor = nil
        manual.reservedAt = Self.at("2026-10-24T12:00:00Z")
        var dated = AnalyticsBuilder(zone: Self.newYork, now: base)
        dated.bot(agent.id, name: agent.name)
        dated.add(late, of: agent.id)
        dated.add(manual, of: agent.id)
        #expect(dated.snapshot().records.map(\.day) == ["2026-10-27", "2026-10-24"])

        // Its task's first turn is the run, which its job's history counts; the owner's turns after it are task turns.
        var recorded = runs[0]
        recorded.taskID = UUID()
        let task = JobTasks.task(for: agent, job: job, run: recorded, startedAt: base.addingTimeInterval(10))
        let transcript = Analytics.turns([
            message(.user, "Triage", at: 10), message(.assistant, "Nothing new.", at: 600),
            message(.user, "Look again", at: 4_000), message(.assistant, "Still nothing.", at: 4_060),
        ], running: false)
        var withTask = builder
        withTask.add(turns: transcript, bot: agent, task: task, runRecorded: true)
        let added = withTask.snapshot()
        #expect(added.records.count == snapshot.records.count + 1)
        #expect(added.records.last == AnalyticsRecord(kind: .task, day: "2026-10-26", outcome: .finished, seconds: 60, bot: 0, account: 2, project: nil, taskID: task.id, startedAt: base.addingTimeInterval(4_000)))
        #expect(added.tasks.isEmpty)
        #expect(added.coverage.jobRunsFromTasks == 0)
        // Once its job is gone, the run is read from its task.
        var orphaned = builder
        orphaned.add(turns: transcript, bot: agent, task: task, runRecorded: false)
        let read = orphaned.snapshot()
        #expect(read.records.suffix(2).map(\.kind) == [.job, .task])
        #expect(read.records.suffix(2).map(\.seconds) == [590, 60])
        #expect(read.coverage.jobRunsFromTasks == 1)
    }

    @Test func subAgentRunsCountForTheBotTheyRanAs() {
        let caller = Bot(name: "10x Engineer", accountID: "claude-dev", workspace: "/tmp/10x")
        let qa = Bot(name: "QA Duck", accountID: "codex-dev", workspace: "/tmp/qa")
        var builder = builder()
        builder.bot(caller.id, name: caller.name)
        func run(_ phase: SubagentPhase, created: TimeInterval = 0, started: TimeInterval?, finished: TimeInterval?, target: Bot) -> SubagentRun {
            var run = SubagentRun(rootBotID: caller.id, depth: 1, targetBot: target, title: "Review", brief: "Review #50", workingDirectory: "/tmp/10x",
                                  phase: phase, createdAt: base.addingTimeInterval(created))
            run.startedAt = started.map(base.addingTimeInterval)
            run.finishedAt = finished.map(base.addingTimeInterval)
            return run
        }
        builder.add(run(.completed, started: 5, finished: 125, target: qa), project: "asieke/BotChu")
        builder.add(run(.failed, started: 5, finished: 15, target: qa), project: nil)
        builder.add(run(.stopped, created: 60_000, started: nil, finished: 60_100, target: caller), project: nil)
        builder.add(run(.running, started: 5, finished: nil, target: qa), project: nil)
        builder.add(run(.queued, started: nil, finished: nil, target: qa), project: nil)
        let snapshot = builder.snapshot()
        // QA Duck was deleted since: it is named as it was when the run was delegated.
        #expect(snapshot.bots == ["10x Engineer", "QA Duck"])
        #expect(snapshot.records.map(\.bot) == [1, 1, 0, 1, 1])
        #expect(snapshot.records.map(\.outcome) == [.finished, .failed, .stopped, .inProgress, .inProgress])
        #expect(snapshot.records.map(\.seconds) == [120, 10, nil, nil, nil])
        #expect(snapshot.records.map(\.day) == ["2026-10-26", "2026-10-26", "2026-10-27", "2026-10-26", "2026-10-26"])
        #expect(snapshot.records.map(\.project) == [0, nil, nil, nil, nil])
        #expect(snapshot.records.map(\.account) == [0, 0, 1, 0, 0])
        #expect(snapshot.accounts.map(\.name) == ["Codex Dev", "Claude Dev"])
    }

    // MARK: Days

    @Test func workCountsOnTheLocalDayItStartedAcrossMidnightAndDaylightSaving() {
        let bot = Bot(name: "Night Owl", accountID: "claude-personal", workspace: "/tmp/owl")
        var builder = AnalyticsBuilder(zone: Self.newYork, now: Self.at("2026-11-02T12:00:00Z"))
        builder.bot(bot.id, name: bot.name)
        func turn(_ start: String, _ end: String) -> AnalyticsTurn { AnalyticsTurn(start: Self.at(start), end: Self.at(end), outcome: .finished) }
        builder.add(turns: [
            // 23:50 to 00:20 EDT, across midnight: on the day it started, with all of its time.
            turn("2026-10-27T03:50:00Z", "2026-10-27T04:20:00Z"),
            // 01:30 EST to 03:30 EDT, as the clocks spring forward: one hour.
            turn("2026-03-08T06:30:00Z", "2026-03-08T07:30:00Z"),
            // 01:50 EDT to 01:10 EST, as they fall back: twenty minutes.
            turn("2026-11-01T05:50:00Z", "2026-11-01T06:10:00Z"),
            // 01:30 EST, the second 01:30 of the day: the same day.
            turn("2026-11-01T06:30:00Z", "2026-11-01T06:31:00Z"),
            // 00:00 local exactly starts its day; 23:59:59 is the day before.
            turn("2026-10-28T04:00:00Z", "2026-10-28T04:01:00Z"),
            turn("2026-10-28T03:59:59Z", "2026-10-28T04:00:59Z"),
        ], bot: bot, task: nil)
        let snapshot = builder.snapshot()
        #expect(snapshot.records.map(\.day) == ["2026-10-26", "2026-03-08", "2026-11-01", "2026-11-01", "2026-10-28", "2026-10-27"])
        #expect(snapshot.records.map(\.seconds) == [1_800, 3_600, 1_200, 60, 60, 60])
        #expect(snapshot.timeZone == "America/New_York" && snapshot.today == "2026-11-02")
        #expect(AnalyticsSummary(snapshot.records, from: "2026-10-27", through: "2026-10-27").runs == 1)
        let night = AnalyticsSummary(snapshot.records, from: "2026-10-26", through: "2026-10-26")
        #expect(night.runs == 1 && night.totalSeconds == 1_800)
        #expect(AnalyticsSummary(snapshot.records, from: "2026-11-01", through: "2026-11-01").runs == 2)
        // Another zone puts the same work on other days.
        #expect(Analytics.day(of: Self.at("2026-10-27T03:50:00Z"), in: TimeZone(identifier: "Europe/Berlin")!) == "2026-10-27")
        // A range of days is counted in dates, so a day of 23 or 25 hours is one day.
        #expect(Analytics.days(from: "2026-03-07", through: "2026-03-09") == ["2026-03-07", "2026-03-08", "2026-03-09"])
        #expect(Analytics.days(from: "2026-10-31", through: "2026-11-02") == ["2026-10-31", "2026-11-01", "2026-11-02"])
        #expect(Analytics.days(from: "2026-12-30", through: "2027-01-01").count == 3)
        #expect(Analytics.days(from: "2026-02-28", through: "2026-03-01") == ["2026-02-28", "2026-03-01"])
        #expect(Analytics.days(from: "2026-11-02", through: "2026-11-01").isEmpty)
    }

    @Test func summariesLeaveUnknownDurationsOutAndNeverCountSkippedTimes() {
        func record(_ kind: AnalyticsRecord.Kind, _ outcome: AnalyticsOutcome, _ seconds: Double?, day: String = "2026-10-26", bot: Int = 0) -> AnalyticsRecord {
            AnalyticsRecord(kind: kind, day: day, outcome: outcome, seconds: seconds, bot: bot, account: nil, project: nil)
        }
        let records = [
            record(.home, .finished, 10), record(.task, .finished, 40), record(.task, .failed, nil), record(.job, .skipped, nil),
            record(.subagent, .inProgress, nil), record(.job, .finished, 20, bot: 1), record(.home, .finished, 1_000, day: "2026-10-25"),
        ]
        let all = AnalyticsSummary(records, from: "2026-10-26", through: "2026-10-26")
        #expect(all.runs == 5 && all.skipped == 1 && all.ended == 4 && all.timed == 3)
        #expect(all.medianSeconds == 20 && all.totalSeconds == 70)
        #expect(all.failureRate == 0.25)
        // Turns alone; one bot alone.
        let turns = AnalyticsSummary(records, from: "2026-10-26", through: "2026-10-26", kinds: [.home, .task])
        #expect(turns.runs == 3 && turns.medianSeconds == 25)
        let other = AnalyticsSummary(records, from: "2026-10-26", through: "2026-10-26", where: { $0.bot == 1 })
        #expect(other.runs == 1 && other.medianSeconds == 20)
        // Nothing ended: no rate and no median, rather than zeros.
        let none = AnalyticsSummary([record(.subagent, .inProgress, nil)], from: "2026-10-26", through: "2026-10-26")
        #expect(none.runs == 1 && none.failureRate == nil && none.medianSeconds == nil && none.timed == 0 && none.totalSeconds == 0)
        let empty = AnalyticsSummary([], from: "2026-01-01", through: "2026-12-31")
        #expect(empty.runs == 0 && empty.failureRate == nil && empty.medianSeconds == nil)
        #expect(AnalyticsSummary.median([3, 1, 2]) == 2 && AnalyticsSummary.median([4, 1, 2, 3]) == 2.5 && AnalyticsSummary.median([]) == nil)
        #expect(Analytics.seconds(from: base, to: base.addingTimeInterval(12.345)) == 12.3)
        #expect(Analytics.seconds(from: base, to: base) == 0)
        #expect(Analytics.seconds(from: base, to: base.addingTimeInterval(-1)) == nil)
        #expect(Analytics.seconds(from: nil, to: base) == nil)
    }

    @Test func tokensAndCostAreUnavailableRatherThanZero() throws {
        let measures = AnalyticsMeasure.unrecorded
        #expect(measures.map(\.metric) == ["tokens", "cost"])
        #expect(measures.allSatisfy { $0.provenance == .unavailable && $0.value == nil })
        // An unavailable figure keeps no value; an estimate says it is one.
        #expect(AnalyticsMeasure(metric: "cost", provenance: .unavailable, value: 0, note: "").value == nil)
        #expect(AnalyticsMeasure(metric: "cost", provenance: .estimated, value: 0.56, note: "").value == 0.56)
        let json = String(decoding: try AnalyticsSnapshot(generatedAt: base, timeZone: "UTC", today: "2026-10-26").encoded(), as: UTF8.self)
        #expect(json.contains(#""metric":"tokens","note":"#) && json.contains(#""provenance":"unavailable""#))
        #expect(!json.contains(#""value":0"#))
    }

    // MARK: Reading BotChu's folders

    /// BotChu's data folder with bots in it, in a temporary place.
    struct Folder {
        let root: URL
        var entries: [Store.Entry] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-analytics-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        mutating func add(_ name: String, accountID: String, remote: Bool = false) throws -> (bot: Bot, home: BotHome) {
            var bot = Bot(name: name, instructions: "SECRET-INSTRUCTIONS", accountID: accountID,
                          workspace: root.appendingPathComponent("bots/\(name)").path)
            if remote { bot.kind = .remoteQueue }
            let home = BotHome(workspace: bot.workspace)
            try home.save(bot)
            entries.append(Store.Entry(id: bot.id, workspace: bot.workspace))
            try Store(root: root).saveIndex(entries)
            return (bot, home)
        }

        /// Every file under the folder, with its contents.
        func files() -> [String: Data] {
            var files: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if let data = try? Data(contentsOf: url) { files[url.path] = data }
            }
            return files
        }
    }

    /// Bots, tasks, jobs and sub-agents with content in every field that could hold some; a bot
    /// whose folder is gone, a remote queue bot, a run review, damaged and unreadable files, and
    /// saved allowance readings.
    func filledFolder() async throws -> (folder: Folder, fox: Bot, qa: Bot, running: Set<AnalyticsConversation>, now: Date) {
        var folder = try Folder()
        let (fox, foxHome) = try folder.add("Product Fox", accountID: "claude-personal")
        let (qa, qaHome) = try folder.add("QA Duck", accountID: "codex-dev")
        _ = try folder.add("Danny", accountID: "claude-personal", remote: true)
        folder.entries.append(Store.Entry(id: UUID(), workspace: folder.root.appendingPathComponent("gone").path))
        try Store(root: folder.root).saveIndex(folder.entries)
        let now = base.addingTimeInterval(86_400)

        try foxHome.saveThread([
            message(.user, "SECRET-MESSAGE-TEXT", at: 0),
            message(.tool, at: 5, tool: 10),
            message(.assistant, "SECRET-REPLY sk-or-v1-0123456789abcdef0123456789abcdef", at: 30),
            message(.user, "Again", at: 100),
            message(.error, "SECRET-ERROR at /Users/alex/secret-path", at: 110),
        ])
        var task = BotTask(title: "SECRET-TITLE", repo: "asieke/BotChu", checkout: "/Users/alex/secret-checkout", branch: "feat/secret-branch",
                           folder: "/Users/alex/secret-worktree",
                           work: BotTask.Work(number: 48, title: "SECRET-ISSUE-TITLE", url: URL(string: "https://github.com/asieke/BotChu/issues/48")!,
                                              isPullRequest: false),
                           brief: "SECRET-BRIEF", accountID: "codex-work", sessionID: "SECRET-SESSION", createdAt: base)
        task.summary = "SECRET-SUMMARY"
        try foxHome.save(task)
        try foxHome.saveThread([message(.user, "SECRET-BRIEF", at: 200), message(.assistant, "Opened a PR", at: 260),
                                message(.user, "Also the docs", at: 300), message(.tool, at: 305)], task: task.id)
        // A transcript with a line BotChu can't read: read as far as it can be, and left as it is.
        let closed = BotTask(repo: "asieke/GitChu", checkout: "/tmp/GitChu", brief: "Speed up", accountID: "claude-personal",
                             createdAt: base.addingTimeInterval(-86_400), archivedAt: base)
        try foxHome.save(closed)
        let damaged = try BotHome.encodeThread([message(.user, "Go", at: -86_000), message(.assistant, "Gone", at: -85_940)]) + Data("not json\n".utf8)
        try damaged.write(to: foxHome.taskThreadURL(closed.id))
        // A task whose record can't be read.
        let unreadable = foxHome.taskURL(UUID())
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: unreadable.appendingPathComponent("task.json"))

        var job = Job(botID: fox.id, title: "SECRET-JOB-TITLE", prompt: "SECRET-JOB-PROMPT", schedule: JobSchedule(timeZone: "America/New_York"))
        var run = JobRun(trigger: .scheduled, scheduledFor: base, timeZone: "America/New_York", reservedAt: base, outcome: .succeeded,
                         summary: "SECRET-RUN-SUMMARY")
        run.startedAt = base.addingTimeInterval(1_000)
        run.finishedAt = base.addingTimeInterval(1_300)
        run.accountID = "codex-work"
        run.accountName = "Codex Work"
        let runTask = JobTasks.task(for: fox, job: job, run: run, startedAt: base.addingTimeInterval(1_000))
        run.taskID = runTask.id
        var skipped = JobRun(trigger: .scheduled, scheduledFor: base.addingTimeInterval(-86_400), timeZone: "America/New_York",
                             reservedAt: base, outcome: .skipped, summary: "Missed")
        skipped.accountID = nil
        job.runs = [skipped, run]
        try foxHome.save(job)
        try foxHome.save(runTask)
        try foxHome.saveThread([message(.user, "SECRET-JOB-PROMPT", at: 1_000), message(.assistant, "Report", at: 1_290)], task: runTask.id)

        var delegated = SubagentRun(rootBotID: fox.id, rootTaskID: task.id, depth: 1, targetBot: qa, title: "SECRET-SUBAGENT-TITLE",
                                    brief: "SECRET-SUBAGENT-BRIEF", workingDirectory: "/Users/alex/secret-dir", phase: .completed, createdAt: base)
        delegated.startedAt = base.addingTimeInterval(210)
        delegated.finishedAt = base.addingTimeInterval(250)
        delegated.handoffOutput = "SECRET-HANDOFF"
        try foxHome.saveSubagent(delegated)
        var failing = SubagentRun(rootBotID: qa.id, depth: 1, targetBot: fox, title: "Look", brief: "Look", workingDirectory: qa.workspace,
                                  phase: .failed, createdAt: base)
        failing.errorMessage = "SECRET-SUB-ERROR"
        try qaHome.saveSubagent(failing)

        try FileManager.default.createDirectory(at: foxHome.evaluationsURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: foxHome.evaluationURL("day-1"))

        // Allowance, saved as the app saves it: one current, one stale, one that couldn't be read.
        let night = Account(id: "profile-night", name: "Claude Night", kind: .claude, defaultCommand: "/Users/alex/secret-cmd/claude", symbol: "sparkle")
        let cache = UsageCache(fetch: { request, _ in
            if request.account.id == "muse" { throw UsageFailure("SECRET-USAGE-ERROR") }
            return ProviderUsage(windows: [
                UsageWindow(id: "5h", title: "5-hour", usedPercent: 42, resetsAt: now.addingTimeInterval(3_600), detail: "SECRET-DETAIL"),
                UsageWindow(id: "week", title: "Weekly", usedPercent: 90, resetsAt: now.addingTimeInterval(-60)),
            ], note: "SECRET-NOTE", readAt: request.account.id == "codex-dev" ? now.addingTimeInterval(-7_200) : now)
        }, file: folder.root.appendingPathComponent("usage.json"))
        _ = await cache.read(UsageRequest(account: night, command: night.defaultCommand), now: now)
        _ = await cache.read(UsageRequest(account: Accounts.account(id: "codex-dev"), command: "/Users/alex/secret-cmd/codex-dev"),
                             now: now.addingTimeInterval(-7_200))
        _ = await cache.read(UsageRequest(account: Accounts.account(id: "muse"), command: "muse"), now: now)

        return (folder, fox, qa, [AnalyticsConversation(botID: fox.id, taskID: task.id)], now)
    }

    @Test func collectReadsEveryBotsRecordsAndChangesNothing() async throws {
        let (folder, fox, _, running, now) = try await filledFolder()
        let night = Account(id: "profile-night", name: "Claude Night", kind: .claude, defaultCommand: "night", symbol: "sparkle")
        let before = folder.files()
        let snapshot = Analytics.collect(AnalyticsInput(root: folder.root, accounts: Accounts.all + [night], running: running, now: now,
                                                        zone: Self.newYork))
        #expect(folder.files() == before)
        #expect(snapshot.bots == ["Product Fox", "QA Duck"])
        #expect(snapshot.today == "2026-10-27" && snapshot.timeZone == "America/New_York" && snapshot.generatedAt == now)
        let byKind = Dictionary(grouping: snapshot.records, by: \.kind)
        // Home: a finished turn and a failed one, on the bot's own account.
        #expect(byKind[.home]?.map(\.outcome) == [.finished, .failed])
        #expect(byKind[.home]?.map(\.seconds) == [30, 10])
        // Tasks, oldest first: the closed one's readable turn counts; the open one's second turn is under way; the run's task adds nothing.
        #expect(byKind[.task]?.map(\.outcome) == [.finished, .finished, .inProgress])
        #expect(byKind[.task]?.map(\.day) == ["2026-10-25", "2026-10-26", "2026-10-26"])
        #expect(byKind[.task]?.map(\.seconds) == [60, 60, nil])
        #expect(byKind[.job]?.map(\.outcome) == [.skipped, .finished])
        #expect(byKind[.job]?.map(\.seconds) == [nil, 300])
        #expect(byKind[.subagent]?.map(\.outcome) == [.finished, .failed])
        #expect(byKind[.subagent]?.map(\.bot) == [1, 0])
        let project = try #require(snapshot.projects.firstIndex(of: "asieke/BotChu"))
        #expect(byKind[.subagent]?.first?.project == project)
        #expect(snapshot.tasks.map(\.turns) == [1, 2])
        #expect(snapshot.tasks.map(\.latest) == [.finished, .inProgress])
        #expect(snapshot.tasks.map(\.open) == [false, true])
        #expect(Set(snapshot.accounts.map(\.name)) == ["Claude Personal", "Codex Work", "Codex Dev"])
        // What it couldn't read, and what it left out on purpose.
        let coverage = snapshot.coverage
        #expect(coverage.bots == 2 && coverage.remoteQueueBots == 1 && coverage.missingBots == 1)
        #expect(coverage.conversations == 4)
        #expect(coverage.damagedConversations == 1 && coverage.unreadableLines == 1)
        #expect(coverage.unreadableRecords == 1 && coverage.runReviews == 1 && !coverage.allowanceUnreadable)
        #expect(coverage.problems.count == 3)
        #expect(coverage.problems.contains("1 bot's folder is missing, so its work isn't counted until the folder is back."))
        // Allowance: each profile's latest reading, by its name now.
        #expect(snapshot.allowance.map(\.account) == ["Claude Night", "Codex Dev", "Muse"])
        #expect(snapshot.allowance.map(\.status) == [.current, .stale, .unavailable])
        let windows = snapshot.allowance[0].windows
        #expect(windows.map(\.title) == ["5-hour", "Weekly"])
        #expect(windows.map(\.usedPercent) == [42, nil])
        #expect(windows.map(\.hasReset) == [false, true])
        #expect(snapshot.allowance[2].windows.isEmpty && snapshot.allowance[2].readAt == nil)

        // Nothing running: the task's last turn ended as saved.
        let idle = Analytics.collect(AnalyticsInput(root: folder.root, running: [], now: now, zone: Self.newYork))
        #expect(idle.records.filter { $0.kind == .task }.map(\.outcome) == [.finished, .finished, .finished])
        // Each bot's job runs are its own: a job copied into another bot's folder isn't counted again.
        try BotHome(workspace: folder.root.appendingPathComponent("bots/QA Duck").path)
            .save(BotHome(workspace: fox.workspace).loadJobs(of: fox.id)[0])
        #expect(Analytics.collect(AnalyticsInput(root: folder.root, now: now, zone: Self.newYork)).records.filter { $0.kind == .job }.count == 2)
    }

    @Test func noDataMakesAnEmptySnapshotAndPage() throws {
        let folder = try Folder()
        let snapshot = Analytics.collect(AnalyticsInput(root: folder.root, now: base, zone: Self.newYork))
        #expect(snapshot.records.isEmpty && snapshot.tasks.isEmpty && snapshot.allowance.isEmpty && snapshot.bots.isEmpty)
        #expect(snapshot.coverage.problems.isEmpty && snapshot.coverage.bots == 0)
        #expect(snapshot.measures == AnalyticsMeasure.unrecorded)
        let page = try AnalyticsDashboard.html(for: snapshot)
        #expect(page.contains("No activity recorded yet"))
        // A usage file that can't be read is said, not taken as no readings.
        try Data("[{".utf8).write(to: folder.root.appendingPathComponent("usage.json"))
        let unreadable = Analytics.collect(AnalyticsInput(root: folder.root, now: base, zone: Self.newYork))
        #expect(unreadable.coverage.allowanceUnreadable && unreadable.coverage.problems == ["The saved allowance readings couldn't be read."])
    }

    // MARK: What the snapshot and page leave out

    @Test func theSnapshotAndPageHoldNamesAndNumbersOnly() async throws {
        let (folder, _, _, running, now) = try await filledFolder()
        let snapshot = Analytics.collect(AnalyticsInput(root: folder.root, running: running, now: now, zone: Self.newYork))
        let json = String(decoding: try snapshot.encoded(), as: UTF8.self)
        let page = try AnalyticsDashboard.html(for: snapshot)
        for text in [json, page] {
            for secret in ["SECRET", "sk-or-v1", "/Users/alex", folder.root.path, "feat/secret", "Triage", "Opened a PR", "Missed", "github.com/asieke"] {
                #expect(!text.contains(secret), "\(secret) is in the dashboard")
            }
            for name in ["Product Fox", "QA Duck", "asieke/BotChu", "asieke/GitChu", "Codex Work", "Claude Night"] {
                #expect(text.contains(name), "\(name) is missing")
            }
        }
        // Remote queue bots are left out, by name too.
        #expect(!json.contains("Danny"))
    }

    @Test func thePageLoadsNothingAndItsDataCantBreakOutOfItsBlock() throws {
        var builder = builder()
        let hostile = "</script><script>alert(1)</script><!-- & \u{2028}"
        let bot = Bot(name: hostile, workspace: "/tmp/x")
        builder.bot(bot.id, name: hostile)
        builder.add(turns: [AnalyticsTurn(start: base, end: base.addingTimeInterval(5), outcome: .finished)], bot: bot,
                    task: BotTask(repo: "<img src=x onerror=alert(1)>", checkout: "/tmp/x", createdAt: base))
        let snapshot = builder.snapshot()
        let page = try AnalyticsDashboard.html(for: snapshot)
        // Two scripts: the data block and the page's own; no other markup from the data.
        #expect(page.components(separatedBy: "<script").count == 3)
        #expect(page.components(separatedBy: "</script>").count == 3)
        #expect(!page.contains("<img") && !page.contains("<!--") && !page.contains("\u{2028}"))
        // Nothing to load: no link, source, import or request, and a policy that allows none.
        #expect(page.contains(#"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'"#))
        // SVG fragment masks/paint servers refer only to this document and load nothing.
        let networkCheckedPage = page.replacingOccurrences(of: #"url\(#[A-Za-z0-9_-]+\)"#, with: "", options: .regularExpression)
        for pattern in ["<link", "src=\"", "src='", "url(", "@import", "fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "<iframe", "<form"] {
            #expect(!networkCheckedPage.replacingOccurrences(of: "<img src=x", with: "").contains(pattern), "\(pattern) is in the page")
        }
        // The only address is the SVG namespace, which names markup and is never loaded.
        let pattern = try NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^"'\s)]*"#)
        let addresses = pattern.matches(in: page, range: NSRange(page.startIndex..., in: page)).compactMap { Range($0.range, in: page).map { String(page[$0]) } }
        #expect(addresses == ["http://www.w3.org/2000/svg"])
        // The data block reads back as the snapshot.
        let start = try #require(page.range(of: #"<script type="application/json" id="botchu-analytics-data">"#))
        let end = try #require(page.range(of: "</script>", range: start.upperBound..<page.endIndex))
        let block = String(page[start.upperBound..<end.lowerBound])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(AnalyticsSnapshot.self, from: Data(block.utf8)) == snapshot)
        // The page reads data of its own version only.
        #expect(AnalyticsSnapshot.currentVersion == 2 && AnalyticsDashboard.script.contains("data.version !== 2"))
    }

    @Test func thePageIsWrittenForThisUserOnly() throws {
        let folder = try Folder()
        let page = AnalyticsDashboard.url(in: folder.root)
        // An earlier folder that others could read is closed first.
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try Data("old".utf8).write(to: page)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: page.path)
        let written = try AnalyticsDashboard.write(AnalyticsSnapshot(generatedAt: base, timeZone: "UTC", today: "2026-10-26"), into: folder.root)
        #expect(written == page)
        #expect(written.path.hasSuffix("/analytics/dashboard.html"))
        func permissions(_ url: URL) throws -> Int {
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            return try #require((value as? NSNumber)?.intValue ?? (value as? Int))
        }
        #expect(try permissions(page) == 0o600)
        #expect(try permissions(page.deletingLastPathComponent()) == 0o700)
        #expect(try String(contentsOf: page, encoding: .utf8).hasPrefix("<!doctype html>"))
        // Publishing reads the folder and writes the page there; one it can't write says why.
        let published = AnalyticsDashboard.publish(AnalyticsInput(root: folder.root, now: base, zone: Self.newYork))
        #expect(try published.get() == page)
        let blocked = try Folder()
        try Data().write(to: blocked.root.appendingPathComponent(AnalyticsDashboard.folderName))
        guard case .failure(let failure) = AnalyticsDashboard.publish(AnalyticsInput(root: blocked.root, now: base, zone: Self.newYork)) else {
            Issue.record("A page that couldn't be written was published")
            return
        }
        #expect(failure.message.hasPrefix("BotChu couldn't save the dashboard in its data folder"))
    }

    // MARK: The page's own numbers

    /// Two months of work by three bots, with every outcome, unknown durations and a skipped time.
    static func sample() -> AnalyticsSnapshot {
        let zone = newYork
        let now = at("2026-10-28T18:05:00Z")
        var builder = AnalyticsBuilder(zone: zone, now: now)
        let bots = [Bot(name: "Product Fox", accountID: "claude-personal", workspace: "/tmp/fox"),
                    Bot(name: "10x Engineer", accountID: "codex-work", workspace: "/tmp/10x"),
                    Bot(name: "QA Duck", accountID: "codex-dev", workspace: "/tmp/qa")]
        for bot in bots { builder.bot(bot.id, name: bot.name) }
        let repos = ["asieke/BotChu", "asieke/GitChu", "asieke/Shelf"]
        var seed: UInt64 = 233
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        let outcomes: [AnalyticsOutcome] = [.finished, .finished, .finished, .finished, .finished, .finished, .failed, .stopped]
        for day in 0..<60 {
            let start = now.addingTimeInterval(-Double(60 - day) * 86_400)
            for bot in bots where next(4) != 0 {
                var turns: [AnalyticsTurn] = []
                for n in 0..<(1 + next(5)) {
                    let begin = start.addingTimeInterval(Double(n * 3_600 + next(3_000)))
                    turns.append(AnalyticsTurn(start: begin, end: begin.addingTimeInterval(Double(20 + next(1_500))), outcome: outcomes[next(outcomes.count)]))
                }
                let repo = repos[next(repos.count)]
                let task = next(3) == 0 ? nil : BotTask(repo: repo, checkout: "/tmp/\(repo)", origin: next(2) == 0 ? .owner : .home,
                                                        accountID: bot.accountID, createdAt: start)
                builder.add(turns: turns, bot: bot, task: task)
                if next(5) == 0 {
                    let phases: [SubagentPhase] = [.completed, .completed, .failed, .stopped]
                    var run = SubagentRun(rootBotID: bot.id, rootTaskID: task?.id, depth: 1, targetBot: bots[next(3)], title: "", brief: "", workingDirectory: "/tmp",
                                          phase: phases[next(4)], createdAt: start)
                    run.startedAt = next(6) == 0 ? nil : start.addingTimeInterval(100)
                    run.finishedAt = start.addingTimeInterval(Double(200 + next(900)))
                    builder.add(run, project: task?.repo)
                }
            }
            let outcome: JobOutcome = day % 9 == 4 ? .skipped : day % 11 == 3 ? .interrupted : day % 7 == 2 ? .failed : .succeeded
            var run = JobRun(trigger: .scheduled, scheduledFor: start, timeZone: zone.identifier, reservedAt: start, outcome: outcome)
            if outcome != .skipped {
                run.startedAt = start.addingTimeInterval(20)
                run.finishedAt = outcome == .interrupted ? nil : start.addingTimeInterval(Double(120 + next(600)))
            }
            run.accountID = "codex-work"
            run.accountName = "Codex Work"
            builder.add(run, of: bots[0].id)
        }
        // Under way as the snapshot is made.
        builder.add(turns: [AnalyticsTurn(start: now.addingTimeInterval(-300), end: nil, outcome: .inProgress)], bot: bots[1],
                    task: BotTask(repo: repos[0], checkout: "/tmp", accountID: "codex-work", createdAt: now.addingTimeInterval(-400)))
        var running = JobRun(trigger: .manual, scheduledFor: nil, timeZone: zone.identifier, reservedAt: now, outcome: .running)
        running.startedAt = now.addingTimeInterval(-60)
        builder.add(running, of: bots[0].id)
        builder.addAllowance([
            (request: UsageRequest(account: Accounts.account(id: "claude-personal"), command: "claude"),
             state: UsageState(reading: ProviderUsage(windows: [
                UsageWindow(id: "5h", title: "5-hour", usedPercent: 37, resetsAt: now.addingTimeInterval(7_200), period: 18_000),
                UsageWindow(id: "w", title: "Weekly", usedPercent: 81, resetsAt: now.addingTimeInterval(200_000), period: 604_800),
             ], readAt: now.addingTimeInterval(-300)), checkedAt: now.addingTimeInterval(-300))),
            (request: UsageRequest(account: Accounts.account(id: "codex-work"), command: "codex"),
             state: UsageState(reading: ProviderUsage(windows: [UsageWindow(id: "5h", title: "5-hour", usedPercent: 12, resetsAt: now.addingTimeInterval(-60))],
                                                     readAt: now.addingTimeInterval(-20_000)), error: "Usage unavailable", checkedAt: now.addingTimeInterval(-600))),
            (request: UsageRequest(account: Accounts.account(id: "muse"), command: "muse"), state: UsageState(error: "x", checkedAt: now)),
        ])
        builder.coverage.damagedConversations = 1
        builder.coverage.unreadableLines = 2
        builder.coverage.runReviews = 12
        builder.coverage.bots = 3
        builder.coverage.conversations = 40
        var snapshot = builder.snapshot()
        // Deterministic usage enriches the browser fixture without changing its established
        // turn, run, duration or outcome totals. Some older records remain unavailable.
        for i in snapshot.records.indices where snapshot.records[i].outcome != .skipped {
            guard i % 13 != 0 else { continue }
            let bot = snapshot.records[i].bot
            let model = i % 17 == 0 ? "unlisted-model" : ["claude-opus-5-5", "gpt-6-astra", "gpt-6-luna"][bot % 3]
            let provider: AgentKind = bot == 0 ? .claude : .codex
            let modelUsage = ModelUsage(model: model, uncachedInput: 20_000 + i * 100,
                                        cacheRead: (bot == 0 ? 2_000 : 80_000) + i * 50,
                                        cacheWrite: bot == 0 ? 5_000 : 0, cacheWrite1h: 0,
                                        output: 3_000 + i * 20, reasoning: bot == 0 ? nil : 1_000)
            snapshot.records[i].model = model
            snapshot.records[i].modelSource = .reported
            snapshot.records[i].provider = provider
            snapshot.records[i].providerID = bot == 0 ? "anthropic" : "openai"
            snapshot.records[i].models = [modelUsage]
            snapshot.records[i].tokens = AnalyticsTokens([modelUsage])
            snapshot.records[i].canReprice = true
            if i % 5 == 0 {
                snapshot.records[i].cost = Double(1 + i % 20) / 10
                snapshot.records[i].costProvenance = .actual
            } else if let price = ModelPricing.price(modelUsage, provider: provider) {
                snapshot.records[i].cost = price.usd
                snapshot.records[i].costProvenance = .estimated
            } else { snapshot.records[i].costProvenance = .unpriced }
        }
        snapshot.unpricedModelIDs = ["unlisted-model"]
        let summary = AnalyticsSummary(snapshot.records, from: "", through: "9999", tasks: snapshot.tasks)
        snapshot.measures = [AnalyticsMeasure(metric: "tokens", provenance: .actual, value: summary.tokens.total.map(Double.init), note: "Sample reported tokens"),
                             AnalyticsMeasure(metric: "cost", provenance: summary.costProvenance, value: summary.cost, note: "Sample known spend")]
        return snapshot
    }

    @Test func theSampleCoversEveryCase() throws {
        let sample = Self.sample()
        let all = AnalyticsSummary(sample.records, from: "2026-01-01", through: sample.today)
        #expect(Set(sample.records.map(\.outcome)) == Set(AnalyticsOutcome.allCases))
        #expect(Set(sample.records.map(\.kind)) == Set(AnalyticsRecord.Kind.allCases))
        #expect(all.timed < all.ended && all.skipped > 0 && (all.outcomes[.inProgress] ?? 0) == 2)
        // What the page's script shows for all of it, in a browser.
        #expect(all.runs == 531 && all.skipped == 7 && all.ended == 529 && all.timed == 520)
        #expect(all.medianSeconds == 709 && all.totalSeconds == 383_742 && all.outcomes[.failed] == 71)
        #expect(sample.coverage.problems.count == 1)
        // `BOTCHU_ANALYTICS_SAMPLE=<file> swift test --filter AnalyticsTests` writes the sample's page, to look at in a browser.
        if let path = ProcessInfo.processInfo.environment["BOTCHU_ANALYTICS_SAMPLE"], !path.isEmpty {
            try Data(AnalyticsDashboard.html(for: sample).utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    #if canImport(JavaScriptCore)
    /// The page's script works out the numbers `AnalyticsSummary` does, from the same records.
    @Test func thePagesScriptWorksOutTheSameNumbers() throws {
        var sample = Self.sample()
        for i in sample.records.indices {
            sample.records[i].costProvenance = [.actual, .estimated, .unpriced, .unavailable][i % 4]
            if i % 4 < 2 { sample.records[i].cost = Double(i % 11) / 100 }
            if i % 4 != 3 {
                sample.records[i].tokens = AnalyticsTokens([ModelUsage(model: "test", uncachedInput: i, cacheRead: i * 2,
                                                                      cacheWrite: 0, cacheWrite1h: 0, output: i * 3, reasoning: i)])
            }
        }
        let context: JSContext = JSContext()
        context.evaluateScript(AnalyticsDashboard.script)
        #expect(context.exception == nil)
        let api = try #require(context.objectForKeyedSubscript("BotChuAnalytics"))
        let records = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample.records))
        let tasks = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample.tasks))
        let ranges = [("2026-01-01", sample.today), ("2026-10-01", "2026-10-15"), ("2026-10-28", "2026-10-28"), ("2027-01-01", "2027-01-31")]
        let kindSets: [Set<AnalyticsRecord.Kind>] = [Set(AnalyticsRecord.Kind.allCases), [.home, .task], [.job], [.subagent]]
        for (from, through) in ranges {
            for kinds in kindSets {
                let swift = AnalyticsSummary(sample.records, from: from, through: through, kinds: kinds, tasks: sample.tasks)
                let flags = Dictionary(uniqueKeysWithValues: AnalyticsRecord.Kind.allCases.map { ($0.rawValue, kinds.contains($0)) })
                let script = try #require(api.invokeMethod("summarize", withArguments: [records, from, through, flags, NSNull(), tasks]))
                for (key, expected) in [("actualCost", swift.actualCost), ("estimatedCost", swift.estimatedCost),
                                        ("cost", swift.cost), ("wastedCost", swift.wastedCost),
                                        ("cacheHitRate", swift.cacheHitRate), ("costPerFinishedTask", swift.costPerFinishedTask)] {
                    let value = script.forProperty(key)
                    #expect(value?.isNull == true ? expected == nil : abs((value?.toDouble() ?? -1) - (expected ?? -2)) < 0.000_001)
                }
                #expect(script.forProperty("costProvenance").toString() == swift.costProvenance.rawValue)
                #expect(script.forProperty("finishedTasks").toInt32() == Int32(swift.finishedTasks))
                #expect(script.forProperty("unpriced").toInt32() == Int32(swift.unpriced))
                #expect(script.forProperty("unavailable").toInt32() == Int32(swift.unavailable))
                for (key, expected) in [("uncachedInput", swift.tokens.uncachedInput), ("cacheRead", swift.tokens.cacheRead),
                                        ("cacheWrite", swift.tokens.cacheWrite), ("cacheWrite1h", swift.tokens.cacheWrite1h),
                                        ("output", swift.tokens.output), ("reasoning", swift.tokens.reasoning)] {
                    let value = script.forProperty("tokens").forProperty(key)
                    #expect(value?.isNull == true ? expected == nil : value?.toDouble() == expected.map(Double.init))
                }
                #expect(script.forProperty("runs").toInt32() == Int32(swift.runs))
                #expect(script.forProperty("skipped").toInt32() == Int32(swift.skipped))
                #expect(script.forProperty("ended").toInt32() == Int32(swift.ended))
                #expect(script.forProperty("timed").toInt32() == Int32(swift.timed))
                for outcome in AnalyticsOutcome.allCases where outcome != .skipped {
                    let count = script.forProperty("outcomes").forProperty(outcome.rawValue)
                    #expect((count?.isUndefined == true ? 0 : count?.toInt32() ?? 0) == Int32(swift.outcomes[outcome] ?? 0))
                }
                let median = script.forProperty("medianSeconds")
                #expect(median?.isNull == true ? swift.medianSeconds == nil : abs((median?.toDouble() ?? -1) - (swift.medianSeconds ?? -2)) < 0.001)
                let rate = script.forProperty("failureRate")
                #expect(rate?.isNull == true ? swift.failureRate == nil : abs((rate?.toDouble() ?? -1) - (swift.failureRate ?? -2)) < 0.000_001)
                #expect(abs((script.forProperty("totalSeconds").toDouble()) - swift.totalSeconds) < 0.001)
            }
        }
        let days = try #require(api.invokeMethod("days", withArguments: ["2026-10-31", "2026-11-02"])?.toArray() as? [String])
        #expect(days == Analytics.days(from: "2026-10-31", through: "2026-11-02"))
        let unavailable = try #require(api.invokeMethod("measureText", withArguments: [["metric": "tokens", "provenance": "unavailable", "value": 0] as [String: Any]]))
        #expect(unavailable.forProperty("value").toString() == "Unavailable")
        let estimate = try #require(api.invokeMethod("measureText", withArguments: [["metric": "cost", "provenance": "estimated", "value": 0.56] as [String: Any]]))
        #expect(estimate.forProperty("value").toString() == "≈ $0.56" && estimate.forProperty("detail").toString() == "Estimated")
        #expect(api.invokeMethod("formatDuration", withArguments: [NSNull()])?.toString() == "Unknown")
    }
    #endif
}

extension AnalyticsTests {
    func ledgerEntry(_ bot: Bot, prompt: ChatMessage, provider: AgentKind = .claude, model: String? = "claude-sonnet-4-5",
                     usage: TurnUsage? = nil, session: String? = nil, resumed: Bool = false) -> UsageLedger.Entry {
        UsageLedger.Entry(at: prompt.date.addingTimeInterval(10), startedAt: prompt.date, kind: .home, botID: bot.id,
                          messageID: prompt.id, accountID: provider == .claude ? "claude-personal" : "codex-work", provider: provider,
                          model: model, modelSource: .requested, outcome: .finished, usage: usage, sessionID: session, resumed: resumed)
    }

    @Test func ledgerOverridesSwitchedAccountsAndGroupsAcknowledgedPromptsWithoutDoubleCharging() throws {
        var folder = try Folder()
        let (bot, home) = try folder.add("Switched", accountID: "codex-work")
        let prompts = (0..<5).map { message(.user, "PRIVATE-PROMPT", at: Double($0 * 100)) }
        try home.saveThread(prompts.flatMap { [$0, ChatMessage(role: .assistant, text: "PRIVATE-REPLY", date: $0.date.addingTimeInterval(10))] })
        let session = UUID().uuidString
        var claude = ledgerEntry(bot, prompt: prompts[1], usage: TurnUsage(models: [ModelUsage(model: "claude-sonnet-4-5", uncachedInput: 100, cacheRead: 20, output: 10)]))
        claude.messageIDs.append(prompts[2].id)
        // Execution began well after the queued prompt; stable message identity must win.
        claude.startedAt = prompts[1].date.addingTimeInterval(27)
        let codex = ledgerEntry(bot, prompt: prompts[3], provider: .codex, model: "gpt-5", usage: TurnUsage(models: [ModelUsage(model: "", uncachedInput: 200, output: 30)], cumulative: true), session: session)
        let unknown = ledgerEntry(bot, prompt: prompts[4], provider: .muse, model: "unknown-model", usage: TurnUsage(models: [ModelUsage(model: "unknown-model", uncachedInput: 50, output: 5)]))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let directory = UsageLedger.directory(in: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        for entry in [claude, codex, unknown] { data += try encoder.encode(entry); data.append(10) }
        data += try encoder.encode(UsageLedger.Amendment(amends: claude.id, actualCostUSD: 0.23)); data.append(10)
        data += Data("torn line\n".utf8)
        try data.write(to: directory.appendingPathComponent("2026-10.jsonl"))
        let before = folder.files()
        let snapshot = Analytics.collect(AnalyticsInput(root: folder.root, now: base, zone: Self.newYork))
        #expect(folder.files() == before)
        #expect(snapshot.records.count == 5)
        let rows = snapshot.records
        #expect(rows[0].cost == nil && rows[0].costProvenance == .unavailable && rows[0].tokens.total == nil)
        #expect(snapshot.accounts[rows[1].account!].family == "Claude Code")
        #expect(snapshot.accounts[rows[3].account!].family == "Codex")
        #expect(rows[1].model == "claude-sonnet-4-5" && rows[1].cost == 0.23 && rows[1].costProvenance == .actual)
        #expect(rows[2].account == rows[1].account && rows[2].model == rows[1].model)
        #expect(rows[2].cost == nil && rows[2].tokens.total == nil && rows[2].costProvenance == .unavailable)
        #expect(rows[3].tokens.uncachedInput == 200 && rows[3].costProvenance == .estimated)
        #expect(rows[4].tokens.total == 55 && rows[4].cost == nil && rows[4].costProvenance == .unpriced)
        #expect(snapshot.unpricedModelIDs == ["unknown-model"] && snapshot.priceSnapshotDate == ModelPricing.snapshotDate)
        let summary = AnalyticsSummary(rows, from: "", through: "9999")
        #expect(summary.actualCost == 0.23 && summary.estimatedCost == rows[3].cost && summary.costProvenance == .estimated)
        #expect(summary.unpriced == 1 && summary.unavailable == 2 && summary.tokens.total == 415)
        #expect(snapshot.coverage.unreadableUsageLines == 1 && snapshot.coverage.problems.count == 1)
        let encoded = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for secret in ["PRIVATE-PROMPT", "PRIVATE-REPLY", session, prompts[1].id.uuidString, bot.workspace] { #expect(!encoded.contains(secret)) }
    }

    @Test(arguments: [AgentKind.codex, .antigravity])
    func cumulativeUsageDeltasRespectResumesMissingBucketsResetsAndModelSwitches(provider: AgentKind) {
        let bot = Bot(name: "Cumulative", accountID: "codex-work", workspace: "/tmp/cumulative")
        let prompts = (0..<7).map { message(.user, at: Double($0 * 100)) }
        let session = UUID().uuidString
        let counts = [100, 130, 180, 10, 25, 40, 60]
        var entries = prompts.enumerated().map { i, prompt in
            ledgerEntry(bot, prompt: prompt, provider: provider, model: i < 2 ? "gpt-5" : "gpt-5-mini",
                        usage: TurnUsage(models: [ModelUsage(model: "", uncachedInput: counts[i], cacheRead: i < 2 ? nil : counts[i], output: counts[i])], cumulative: true),
                        session: session, resumed: true)
        }
        entries[5].sessionID = nil
        entries[6].sessionID = "not-a-uuid"
        var builder = builder(); builder.bot(bot.id, name: bot.name)
        builder.addLedger(entries: entries.reversed())
        builder.add(turns: prompts.map { AnalyticsTurn(start: $0.date, end: $0.date.addingTimeInterval(10), outcome: .finished, messageID: $0.id) }, bot: bot, task: nil)
        let rows = builder.snapshot().records
        #expect(rows.map { $0.tokens.uncachedInput } == [nil, 30, 50, nil, 15, nil, nil])
        #expect(rows[2].models.first?.model == "gpt-5-mini")
        #expect(rows[2].tokens.cacheRead == nil && rows[4].tokens.cacheRead == 15)
        #expect(!rows[2].canReprice && rows[2].cost == nil && rows[2].costProvenance == .unpriced)
        #expect(rows[0].costProvenance == .unavailable && rows[3].costProvenance == .unavailable)
    }

    @Test func ledgerPricingPrecedenceAndBackendIsolationKeepZeroDistinctFromMissing() {
        let bot = Bot(name: "Pricing", accountID: "claude-personal", workspace: "/tmp/pricing")
        let prompts = (0..<5).map { message(.user, at: Double($0 * 100)) }
        let models = ["claude-sonnet-4-5", "anthropic/claude-sonnet-4.5", "private-model", "private-model", "claude-sonnet-4-5"]
        var entries = prompts.enumerated().map { i, prompt in
            ledgerEntry(bot, prompt: prompt, provider: i == 1 ? .pi : .claude, model: models[i],
                        usage: TurnUsage(models: [ModelUsage(model: models[i], uncachedInput: 100, output: 10)], reportedCostUSD: i == 2 ? 0 : 4))
        }
        entries[1].providerID = "private-backend"
        entries[3].usage?.reportedCostUSD = nil
        entries[4].usage = nil
        var builder = builder(); builder.bot(bot.id, name: bot.name)
        builder.addLedger(entries: entries, amendments: [.init(amends: entries[4].id, actualCostUSD: 0)])
        builder.add(turns: prompts.map { AnalyticsTurn(start: $0.date, end: $0.date, outcome: .finished, messageID: $0.id) }, bot: bot, task: nil)
        let rows = builder.snapshot().records
        #expect(rows[0].cost != 4 && rows[0].costProvenance == .estimated)
        #expect(rows[1].cost == 4 && rows[1].costProvenance == .estimated)
        #expect(rows[2].cost == 0 && rows[2].costProvenance == .estimated)
        #expect(rows[3].cost == nil && rows[3].costProvenance == .unpriced)
        #expect(rows[4].cost == 0 && rows[4].costProvenance == .actual && rows[4].tokens.total == nil)
        #expect(ModelPricing.price(ModelUsage(model: "anthropic/claude-sonnet-4.5", uncachedInput: 100), provider: .pi, providerID: "private-backend") == nil)
        #expect(ModelPricing.price(ModelUsage(model: "claude-sonnet-4-5", uncachedInput: 100), provider: .pi, providerID: "anthropic") != nil)
        #expect(!ModelPricing.catalog.isEmpty && ModelPricing.catalog.allSatisfy { !$0.model.isEmpty && !$0.source.isEmpty })
    }
}

extension AnalyticsTests {
    @Test func runIDsJoinRootOwnedSubagentsAndJobsAndFinishedTaskSpendIncludesDelegation() {
        let bot = Bot(name: "Caller", accountID: "claude-personal", workspace: "/tmp/caller")
        let target = Bot(name: "Target", accountID: "codex-work", workspace: "/tmp/target")
        let task = BotTask(repo: "asieke/BotChu", checkout: "/tmp/checkout", createdAt: base)
        let prompts = [message(.user, at: 0), message(.user, at: 100)]
        var turns = prompts.enumerated().map { index, prompt in
            var entry = ledgerEntry(bot, prompt: prompt)
            entry.kind = .task; entry.taskID = task.id; entry.outcome = index == 0 ? .failed : .finished
            return entry
        }
        var delegated = SubagentRun(rootBotID: bot.id, rootTaskID: task.id, depth: 1, targetBot: target,
                                    title: "SECRET", brief: "SECRET", workingDirectory: "/tmp/SECRET", phase: .completed, createdAt: base)
        delegated.startedAt = base; delegated.finishedAt = base.addingTimeInterval(20)
        let sub = UsageLedger.Entry(startedAt: base, kind: .subagent, botID: target.id, taskID: task.id,
                                    subagentRunID: delegated.id, accountID: "codex-dev", provider: .codex, model: "gpt-5", outcome: .finished)
        var job = JobRun(trigger: .manual, scheduledFor: nil, timeZone: "America/New_York", reservedAt: base, outcome: .succeeded)
        job.startedAt = base; job.finishedAt = base.addingTimeInterval(40)
        let jobEntry = UsageLedger.Entry(startedAt: base, kind: .job, botID: bot.id, jobRunID: job.id,
                                         accountID: "claude-dev", provider: .claude, model: "claude-sonnet-4-5", outcome: .finished)
        turns += [sub, jobEntry]
        var builder = builder(); builder.bot(bot.id, name: bot.name)
        builder.addLedger(entries: turns, amendments: turns.enumerated().map { .init(amends: $0.element.id, actualCostUSD: Double($0.offset + 1)) })
        builder.add(turns: prompts.enumerated().map { i, prompt in AnalyticsTurn(start: prompt.date, end: prompt.date.addingTimeInterval(10), outcome: i == 0 ? .failed : .finished, messageID: prompt.id) }, bot: bot, task: task)
        builder.add(delegated, project: task.repo)
        builder.add(job, of: bot.id)
        let snapshot = builder.snapshot()
        #expect(snapshot.records.map(\.cost) == [1, 2, 3, 4])
        #expect(snapshot.accounts[snapshot.records[2].account!].name == "Codex Dev")
        #expect(snapshot.records[2].taskID == task.id && snapshot.records[2].bot != snapshot.records[0].bot)
        let summary = AnalyticsSummary(snapshot.records, from: "", through: "9999", tasks: snapshot.tasks)
        #expect(summary.cost == 10 && summary.finishedTasks == 1 && summary.costPerFinishedTask == 6 && summary.wastedCost == 1)
        let delegatedOnly = AnalyticsSummary(snapshot.records, from: "", through: "9999", kinds: [.subagent], tasks: snapshot.tasks)
        #expect(delegatedOnly.finishedTasks == 1 && delegatedOnly.costPerFinishedTask == 3)
        let homeOnly = AnalyticsSummary(snapshot.records, from: "", through: "9999", kinds: [.home], tasks: snapshot.tasks)
        #expect(homeOnly.cost == nil && homeOnly.costPerFinishedTask == nil && homeOnly.wastedCost == nil)
    }

    @Test func anonymousLegacyTimeJoinIsUniqueAndNeverStealsAnIdentifiedPrompt() {
        let bot = Bot(name: "Legacy", accountID: "claude-personal", workspace: "/tmp/legacy")
        let prompt = message(.user, at: 0)
        var entry = ledgerEntry(bot, prompt: prompt, usage: TurnUsage(models: [ModelUsage(model: "claude-sonnet-4-5", output: 0)]))
        let turn = AnalyticsTurn(start: base.addingTimeInterval(0.7), end: base.addingTimeInterval(10), outcome: .finished)
        func build(_ entries: [UsageLedger.Entry]) -> AnalyticsRecord {
            var b = builder(); b.bot(bot.id, name: bot.name); b.addLedger(entries: entries)
            b.add(turns: [turn], bot: bot, task: nil)
            return b.snapshot().records[0]
        }
        #expect(build([entry]).cost == nil)
        entry.messageID = nil; entry.messageIDs = []
        #expect(build([entry]).cost == 0)
        var duplicate = entry; duplicate.id = UUID()
        #expect(build([entry, duplicate]).cost == nil)
    }
}

extension AnalyticsTests {
    @Test func cumulativeEntriesWithEqualSecondTimestampsKeepLedgerOrder() {
        let bot = Bot(name: "Fast", accountID: "codex-work", workspace: "/tmp/fast")
        let prompts = [message(.user, at: 0), message(.user, at: 0)]
        let session = UUID().uuidString
        var first = ledgerEntry(bot, prompt: prompts[0], provider: .codex, model: "gpt-5",
                                usage: TurnUsage(models: [ModelUsage(model: "", uncachedInput: 100, output: 10)], cumulative: true), session: session)
        var second = ledgerEntry(bot, prompt: prompts[1], provider: .codex, model: "gpt-5",
                                 usage: TurnUsage(models: [ModelUsage(model: "", uncachedInput: 150, output: 20)], cumulative: true), session: session, resumed: true)
        first.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var b = builder(); b.bot(bot.id, name: bot.name); b.addLedger(entries: [first, second])
        b.add(turns: prompts.map { AnalyticsTurn(start: $0.date, end: $0.date, outcome: .finished, messageID: $0.id) }, bot: bot, task: nil)
        #expect(b.snapshot().records.map { $0.tokens.uncachedInput } == [100, 50])
    }

    @Test func anUnpricedModelDoesNotTurnPricedCompanionModelsIntoUnpricedIDs() {
        let bot = Bot(name: "Mixed", accountID: "claude-personal", workspace: "/tmp/mixed")
        let prompt = message(.user, at: 0)
        let entry = ledgerEntry(bot, prompt: prompt, usage: TurnUsage(models: [
            ModelUsage(model: "claude-sonnet-4-5", uncachedInput: 100, output: 10),
            ModelUsage(model: "unknown-model", uncachedInput: 10, output: 1),
        ]))
        var b = builder(); b.bot(bot.id, name: bot.name); b.addLedger(entries: [entry])
        b.add(turns: [AnalyticsTurn(start: base, end: base, outcome: .finished, messageID: prompt.id)], bot: bot, task: nil)
        #expect(b.snapshot().records[0].cost == nil && b.snapshot().unpricedModelIDs == ["unknown-model"])
    }
}
