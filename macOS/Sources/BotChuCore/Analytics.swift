import Foundation

// The analytics dashboard (#233): what BotChu did, over time, from the records it already keeps on
// this Mac. `Analytics.collect` reads them (changing nothing) into one snapshot of counts, durations
// and outcomes, attributed to bots, provider accounts and projects and bucketed into local calendar
// days; `AnalyticsDashboard` writes it into a page for the browser. The snapshot holds names and
// numbers only: no message, brief, prompt, reply, tool call, error text, title, path, command or
// credential. docs/analytics.md defines every metric, its source and its retention.

// MARK: The snapshot

/// Everything the dashboard shows, as it was when it was made.
public struct AnalyticsSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var generatedAt: Date
    /// The Mac's time zone (`America/New_York`), whose calendar days the records are bucketed in.
    public var timeZone: String
    /// The day it was made, in that zone (`2026-10-28`).
    public var today: String
    /// The names the records refer to by index.
    public var bots: [String]
    public var accounts: [AnalyticsAccount]
    /// Repositories as `owner/name` (or a checkout's folder name, for one not on GitHub).
    public var projects: [String]
    public var records: [AnalyticsRecord]
    public var tasks: [AnalyticsTask]
    /// Each profile's latest allowance reading: not a history, and not split by bot.
    public var allowance: [AnalyticsAllowance]
    /// Token use and cost, each only as reliable as its source (`AnalyticsMeasure.Provenance`).
    public var measures: [AnalyticsMeasure]
    public var coverage: AnalyticsCoverage
    public var priceSnapshotDate: String
    public var unpricedModelIDs: [String]
    public var prices: [AnalyticsModelPrice]

    public init(version: Int = Self.currentVersion, generatedAt: Date, timeZone: String, today: String, bots: [String] = [],
                accounts: [AnalyticsAccount] = [], projects: [String] = [], records: [AnalyticsRecord] = [], tasks: [AnalyticsTask] = [],
                allowance: [AnalyticsAllowance] = [], measures: [AnalyticsMeasure] = AnalyticsMeasure.unrecorded,
                coverage: AnalyticsCoverage = AnalyticsCoverage(), unpricedModelIDs: [String] = []) {
        self.version = version
        self.generatedAt = generatedAt
        self.timeZone = timeZone
        self.today = today
        self.bots = bots
        self.accounts = accounts
        self.projects = projects
        self.records = records
        self.tasks = tasks
        self.allowance = allowance
        self.measures = measures
        self.coverage = coverage
        self.priceSnapshotDate = ModelPricing.snapshotDate
        self.unpricedModelIDs = unpricedModelIDs
        self.prices = ModelPricing.catalog
    }

    /// The snapshot as JSON, dates in ISO 8601, keys sorted.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// A provider account (a CLI profile) as the records name it.
public struct AnalyticsAccount: Codable, Equatable, Sendable {
    public var name: String
    /// Its CLI family ("Claude Code", "Codex"), or "Unknown" for a profile BotChu no longer has.
    public var family: String

    public init(name: String, family: String) {
        self.name = name
        self.family = family
    }
}

/// How a turn or run ended, as BotChu saw it. Finished is not proof the work succeeded: the CLI ended
/// its turn without an error.
public enum AnalyticsOutcome: String, Codable, CaseIterable, Sendable {
    case finished, failed
    /// The owner stopped it (or, for a turn, BotChu stopped it to quit).
    case stopped
    /// A scheduled job's run that was running when BotChu quit or crashed.
    case interrupted
    /// Still under way when the snapshot was made: counted, with no duration yet.
    case inProgress
    /// A job's scheduled time that didn't run (missed, or due while its run was under way): listed,
    /// never counted as a run.
    case skipped

    /// Whether it ended, so its duration (when known) counts.
    public var ended: Bool { self != .inProgress && self != .skipped }
}

/// One turn of a conversation, one run of a scheduled job, or one sub-agent run.
public struct AnalyticsRecord: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A turn of a bot's Home conversation.
        case home
        /// A turn of a task's conversation (including the owner's turns in a job run's task after the run).
        case task
        /// A scheduled job's run, or a time it skipped.
        case job
        /// A sub-agent run (`botchu-subagent`), as the bot it ran as.
        case subagent
    }

    public var kind: Kind
    /// The local calendar day it started on (`yyyy-MM-dd`); a run that crosses midnight stays on that day.
    public var day: String
    public var outcome: AnalyticsOutcome
    /// From its start to its end; nil when not known (a time missing or out of order, or still under
    /// way), which is never counted as zero.
    public var seconds: Double?
    /// Index into `bots`: the conversation's bot, the job's agent, or the bot a sub-agent ran as.
    public var bot: Int
    /// Index into `accounts`; nil when the record doesn't say.
    public var account: Int?
    /// Index into `projects`; nil for work outside a repository (Home, job runs).
    public var project: Int?

    public var taskID: UUID?
    public var startedAt: Date?
    public var model: String?
    public var modelSource: UsageLedger.ModelSource?
    public var provider: AgentKind?
    public var providerID: String?
    /// Per-model counts, after cumulative differencing, for exact alternative-model estimates.
    public var models: [ModelUsage] = []
    /// False for cumulative deltas with an unknown baseline bucket; do not reprice a partial delta.
    public var canReprice = false
    public var tokens = AnalyticsTokens()
    public var cost: Double?
    public var costProvenance: AnalyticsMeasure.Provenance = .unavailable

    public init(kind: Kind, day: String, outcome: AnalyticsOutcome, seconds: Double?, bot: Int, account: Int?, project: Int?, taskID: UUID? = nil, startedAt: Date? = nil) {
        self.taskID = taskID
        self.startedAt = startedAt
        self.kind = kind
        self.day = day
        self.outcome = outcome
        self.seconds = seconds
        self.bot = bot
        self.account = account
        self.project = project
    }
}

/// A task as the dashboard counts it: when it started and what became of its latest turn. Job runs'
/// tasks are counted as job runs instead.
public struct AnalyticsTask: Codable, Equatable, Sendable {
    public enum Work: String, Codable, Sendable {
        case issue, pullRequest, review
        /// A brief, without an issue or pull request.
        case brief
    }

    public var day: String
    public var bot: Int
    public var account: Int?
    public var project: Int?
    public var work: Work
    public var origin: BotTask.Origin
    /// Not closed.
    public var open: Bool
    /// Its turns, retries included.
    public var turns: Int
    /// How its latest turn ended; nil before its first turn.
    public var latest: AnalyticsOutcome?
    public var id: UUID?
    public var workNumber: Int?

    public init(day: String, bot: Int, account: Int?, project: Int?, work: Work, origin: BotTask.Origin, open: Bool, turns: Int,
                latest: AnalyticsOutcome?, id: UUID? = nil, workNumber: Int? = nil) {
        self.day = day
        self.bot = bot
        self.account = account
        self.project = project
        self.work = work
        self.origin = origin
        self.open = open
        self.turns = turns
        self.id = id
        self.workNumber = workNumber
        self.latest = latest
    }
}

/// A profile's latest allowance reading, as its provider reported it (`usage.json`).
public struct AnalyticsAllowance: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case current
        /// Older than its background interval, or a later check failed.
        case stale
        /// No reading.
        case unavailable
    }

    public struct Window: Codable, Equatable, Sendable {
        /// "5-hour", "Weekly", "Gemini · 5-hour".
        public var title: String
        /// The share used when it was read; nil when not reported, or the window has reset since.
        public var usedPercent: Double?
        public var resetsAt: Date?
        /// It reset after it was read, so the share no longer applies.
        public var hasReset: Bool

        public init(title: String, usedPercent: Double?, resetsAt: Date?, hasReset: Bool) {
            self.title = title
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
            self.hasReset = hasReset
        }
    }

    public var account: String
    public var family: String
    public var status: Status
    public var readAt: Date?
    public var windows: [Window]

    public init(account: String, family: String, status: Status, readAt: Date?, windows: [Window]) {
        self.account = account
        self.family = family
        self.status = status
        self.readAt = readAt
        self.windows = windows
    }
}

/// Sums of reported buckets only. Nil means none was measured; subset buckets are never counted twice.
public struct AnalyticsTokens: Codable, Equatable, Sendable {
    public var uncachedInput: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var cacheWrite1h: Int?
    public var output: Int?
    public var reasoning: Int?

    public init(_ models: [ModelUsage] = []) {
        uncachedInput = Self.sum(models.map(\.uncachedInput))
        cacheRead = Self.sum(models.map(\.cacheRead))
        cacheWrite = Self.sum(models.map { $0.cacheWrite ?? $0.cacheWrite1h })
        cacheWrite1h = Self.sum(models.map(\.cacheWrite1h))
        output = Self.sum(models.map { $0.output ?? $0.reasoning })
        reasoning = Self.sum(models.map(\.reasoning))
    }

    public var total: Int? { Self.sum([uncachedInput, cacheRead, cacheWrite, output]) }
    public var allInput: Int? { Self.sum([uncachedInput, cacheRead, cacheWrite]) }
    public var cacheHitRate: Double? {
        guard let read = cacheRead, let input = allInput, input > 0 else { return nil }
        return Double(read) / Double(input)
    }

    static func sum(_ values: [Int?]) -> Int? {
        let known = values.compactMap { $0 }
        guard !known.isEmpty, known.allSatisfy({ $0 >= 0 }) else { return nil }
        var total = 0
        for value in known {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    var modelUsage: ModelUsage {
        ModelUsage(model: "", uncachedInput: uncachedInput, cacheRead: cacheRead, cacheWrite: cacheWrite,
                   cacheWrite1h: cacheWrite1h, output: output, reasoning: reasoning)
    }
}

/// A usage figure and how far it can be trusted: provider-reported (actual), worked out (estimated),
/// or not recorded at all (unavailable, which is never shown as zero).
public struct AnalyticsMeasure: Codable, Equatable, Sendable {
    public enum Provenance: String, Codable, Sendable {
        case actual, estimated, unpriced, unavailable
    }

    /// "tokens" or "cost".
    public var metric: String
    public var provenance: Provenance
    /// Nil unless `provenance` says where it came from.
    public var value: Double?
    public var note: String

    public init(metric: String, provenance: Provenance, value: Double? = nil, note: String) {
        self.metric = metric
        self.provenance = provenance
        self.value = provenance == .unavailable ? nil : value
        self.note = note
    }

    /// No matched, separately measured ledger usage in this selection.
    public static let unrecorded = [
        AnalyticsMeasure(metric: "tokens", provenance: .unavailable,
                         note: "No token counts were recorded for these turns or runs."),
        AnalyticsMeasure(metric: "cost", provenance: .unavailable,
                         note: "No cost was recorded for these turns or runs; provider allowance is separate."),
    ]
}

/// What the snapshot could and couldn't read, and what it leaves out on purpose.
public struct AnalyticsCoverage: Codable, Equatable, Sendable {
    /// Bots whose work was read.
    public var bots = 0
    /// Conversation transcripts read (Homes and tasks).
    public var conversations = 0
    /// Transcripts with lines BotChu couldn't read, and how many lines; their readable turns count.
    public var damagedConversations = 0
    public var unreadableLines = 0
    /// Task, job or sub-agent records that couldn't be read, and are left out.
    public var unreadableRecords = 0
    /// Bots in the index whose folder is missing (moved, deleted, or on a disconnected drive).
    public var missingBots = 0
    /// Remote queue bots, which run on another computer: left out.
    public var remoteQueueBots = 0
    /// Run review records (`evaluations/`): reviews of work, never counted as runs.
    public var runReviews = 0
    /// Job runs whose job is gone, read from their task's conversation instead.
    public var jobRunsFromTasks = 0
    /// The usage readings file couldn't be read.
    public var allowanceUnreadable = false
    public var unreadableUsageLines = 0
    public var unreadableUsageFiles = 0
    /// What the dashboard warns about (`described`), set as the snapshot is made.
    public var problems: [String] = []

    public init() {}

    /// What the counts above warn about, in sentences without names or paths.
    public var described: [String] {
        var problems: [String] = []
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        if missingBots > 0 {
            problems.append("\(count(missingBots, "bot's folder is", "bots' folders are")) missing, so its work isn't counted until the folder is back.")
        }
        if damagedConversations > 0 {
            problems.append("\(count(damagedConversations, "conversation has", "conversations have")) \(count(unreadableLines, "line", "lines")) BotChu couldn't read; only the turns it could read are counted.")
        }
        if unreadableRecords > 0 {
            problems.append("\(count(unreadableRecords, "task, job or sub-agent record", "task, job or sub-agent records")) couldn't be read and \(unreadableRecords == 1 ? "is" : "are") left out.")
        }
        if unreadableUsageLines > 0 || unreadableUsageFiles > 0 {
            problems.append("Usage ledger: \(unreadableUsageLines) unreadable lines and \(unreadableUsageFiles) unreadable files; readable usage still counts.")
        }
        if allowanceUnreadable {
            problems.append("The saved allowance readings couldn't be read.")
        }
        return problems
    }
}

/// A conversation that has a turn under way as the snapshot is made; the app knows which.
public typealias AnalyticsConversation = ReviewConversation

// MARK: Reading the records

/// What `Analytics.collect` reads: BotChu's data folder (`index.json`, `usage.json`), and what the
/// app knows that the files don't say.
public struct AnalyticsInput: Sendable {
    public var root: URL
    /// The accounts BotChu offers now, which name the ones the records use.
    public var accounts: [Account]
    /// Conversations with a turn under way.
    public var running: Set<AnalyticsConversation>
    public var now: Date
    public var zone: TimeZone

    public init(root: URL, accounts: [Account] = Accounts.all, running: Set<AnalyticsConversation> = [], now: Date = Date(),
                zone: TimeZone = .current) {
        self.root = root
        self.accounts = accounts
        self.running = running
        self.now = now
        self.zone = zone
    }
}

public enum Analytics {
    /// Reads every bot's records into a snapshot, changing nothing: a transcript with lines it can't
    /// read is read as far as it can be, never repaired or moved, and nothing is written.
    public static func collect(_ input: AnalyticsInput) -> AnalyticsSnapshot {
        var builder = AnalyticsBuilder(zone: input.zone, now: input.now, accounts: input.accounts)
        let loaded = Store(root: input.root).loadBots()
        builder.coverage.missingBots = loaded.missing.count
        for bot in loaded.bots where !bot.isRemoteQueue { builder.bot(bot.id, name: bot.name) }
        var ledgerEntries: [UsageLedger.Entry] = []
        var amendments: [UsageLedger.Amendment] = []
        for bot in loaded.bots where !bot.isRemoteQueue {
            do {
                let ledger = try UsageLedger.read(in: BotHome(workspace: bot.persistencePath))
                ledgerEntries += ledger.entries
                amendments += ledger.amendments
                builder.coverage.unreadableUsageLines += ledger.unreadableLines
                builder.coverage.unreadableUsageFiles += ledger.unreadableFiles
            } catch { builder.coverage.unreadableUsageFiles += 1 }
        }
        builder.addLedger(entries: ledgerEntries, amendments: amendments)
        for bot in loaded.bots {
            guard !bot.isRemoteQueue else {
                builder.coverage.remoteQueueBots += 1
                continue
            }
            builder.coverage.bots += 1
            read(bot, into: &builder, running: input.running)
        }
        builder.readAllowance(input.root.appendingPathComponent("usage.json"))
        return builder.snapshot()
    }

    private static func read(_ bot: Bot, into builder: inout AnalyticsBuilder, running: Set<AnalyticsConversation>) {
        let home = BotHome(workspace: bot.persistencePath)
        // Oldest first, as BotChu lists them.
        let tasks: [BotTask] = records(in: home.tasksURL, file: "task.json", builder: &builder) { try Store.decoder.decode(BotTask.self, from: $0) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        // A job copied in from another bot's folder isn't this bot's.
        let jobs: [Job] = records(in: home.jobsURL, file: "job.json", builder: &builder) { try Store.decoder.decode(Job.self, from: $0) }
            .filter { $0.botID == bot.id }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var runs: Set<UUID> = []
        for job in jobs {
            for run in job.runs {
                runs.insert(run.id)
                builder.add(run, of: bot.id)
            }
        }
        builder.addTurns(of: home.threadURL, bot: bot, task: nil, running: running.contains(AnalyticsConversation(botID: bot.id)))
        for task in tasks {
            let known = task.jobRun.map { runs.contains($0.runID) } ?? false
            builder.addTurns(of: home.taskThreadURL(task.id), bot: bot, task: task, running: running.contains(AnalyticsConversation(botID: bot.id, taskID: task.id)),
                             runRecorded: known)
        }
        for taskID in [nil] + tasks.map({ Optional($0.id) }) {
            let delegated: [SubagentRun] = records(in: home.subagentsURL(taskID: taskID), file: "run.json", builder: &builder) {
                try SubagentIPC.decode(SubagentRun.self, from: $0)
            }
            for run in delegated where run.rootTaskID == taskID {
                builder.add(run, project: taskID.flatMap { id in tasks.first { $0.id == id } }?.repo)
            }
        }
        let reviews = (try? FileManager.default.contentsOfDirectory(at: home.evaluationsURL, includingPropertiesForKeys: nil)) ?? []
        builder.coverage.runReviews += reviews.filter { $0.pathExtension == "json" }.count
    }

    /// The records in each folder of `folder` (`<id>/<file>`), and a count of those that can't be read.
    private static func records<T>(in folder: URL, file: String, builder: inout AnalyticsBuilder, decode: (Data) throws -> T) -> [T] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [T] = []
        for item in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let url = item.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url), let record = try? decode(data) {
                found.append(record)
            } else {
                builder.coverage.unreadableRecords += 1
            }
        }
        return found
    }

    /// A conversation's turns, split where a message from the owner (or another bot, Telegram or the
    /// Inbox) starts one: each from that message, or from the previous turn's end when it waited in
    /// the queue, to the last thing the bot did in it. BotChu's own lines (receipts, notes) don't count
    /// as work, except its Stopped note. A stretch in which the bot did nothing isn't a turn, unless it
    /// is the last one of a conversation `running` now. As run reviews read them (`ReviewSignals.turns`):
    /// a turn whose last word is an error failed; one with a Stopped note was stopped; the rest finished.
    public static func turns(_ messages: [ChatMessage], running: Bool) -> [AnalyticsTurn] {
        guard !messages.isEmpty else { return [] }
        var starts = messages.indices.filter { messages[$0].role == .user }
        if starts.first != 0 { starts.insert(0, at: 0) }
        var turns: [AnalyticsTurn] = []
        var previousEnd: Date?
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : messages.count
            let segment = messages[start..<end]
            let last = index == starts.count - 1
            let opened = messages[start].role == .user
            let work = segment.filter { $0.role == .assistant || $0.role == .tool || $0.role == .error }
            let stop = segment.last { $0.role == .note && ($0.stopped == true || $0.text == "Stopped") }
            if last && running && opened {
                turns.append(AnalyticsTurn(start: max(messages[start].date, previousEnd ?? .distantPast), end: nil, outcome: .inProgress, messageID: messages[start].id))
                break
            }
            guard !work.isEmpty || stop != nil else { continue }
            let finish = (work.map { $0.date.addingTimeInterval(max(0, $0.toolDuration ?? 0)) } + [stop?.date].compactMap { $0 }).max()!
            var begin = opened ? messages[start].date : (work.first?.date ?? finish)
            // A message that waited in the queue starts its turn when the turn before it ended.
            if let previousEnd, previousEnd > begin { begin = previousEnd }
            begin = min(begin, finish)
            let outcome: AnalyticsOutcome
            if stop != nil {
                outcome = .stopped
            } else if work.last(where: { $0.role == .assistant || $0.role == .error })?.role == .error {
                // Only the last word counts: a CLI reports errors it recovers from before its reply.
                outcome = .failed
            } else {
                outcome = .finished
            }
            turns.append(AnalyticsTurn(start: begin, end: finish, outcome: outcome, messageID: opened ? messages[start].id : nil))
            previousEnd = max(previousEnd ?? finish, finish)
        }
        return turns
    }

    /// The local calendar day of `date` in `zone`, as `yyyy-MM-dd`.
    public static func day(of date: Date, in zone: TimeZone) -> String {
        dayFormatter(zone).string(from: date)
    }

    static func dayFormatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// The calendar days from `from` through `through`, inclusive (`yyyy-MM-dd`); empty when `from`
    /// is later. Days are counted as dates, so a day with a daylight-saving change is still one day.
    public static func days(from: String, through: String) -> [String] {
        let formatter = dayFormatter(TimeZone(secondsFromGMT: 0)!)
        guard let first = formatter.date(from: from), let last = formatter.date(from: through), first <= last else { return [] }
        var days: [String] = []
        var day = first
        while day <= last, days.count < 100_000 {
            days.append(formatter.string(from: day))
            day = day.addingTimeInterval(86_400)
        }
        return days
    }

    /// From `start` to `end`, rounded to a tenth of a second; nil when either is missing or `end` is
    /// before `start` (a clock change, or a damaged record): unknown, not zero.
    public static func seconds(from start: Date?, to end: Date?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return (end.timeIntervalSince(start) * 10).rounded() / 10
    }
}

/// One turn of a conversation, as `Analytics.turns` splits it.
public struct AnalyticsTurn: Equatable, Sendable {
    public var start: Date
    /// Nil while it is under way.
    public var end: Date?
    public var outcome: AnalyticsOutcome

    public var messageID: UUID?

    public init(start: Date, end: Date?, outcome: AnalyticsOutcome, messageID: UUID? = nil) {
        self.messageID = messageID
        self.start = start
        self.end = end
        self.outcome = outcome
    }

    public var seconds: Double? { Analytics.seconds(from: start, to: end) }
}

/// Builds a snapshot record by record, naming each bot, account and project once.
public struct AnalyticsBuilder {
    public var coverage = AnalyticsCoverage()
    private let zone: TimeZone
    private let now: Date
    private let known: [Account]
    private let formatter: DateFormatter
    private var bots: [String] = []
    private var botIndex: [UUID: Int] = [:]
    private var accounts: [AnalyticsAccount] = []
    private var accountIndex: [String: Int] = [:]
    private var projects: [String] = []
    private var projectIndex: [String: Int] = [:]
    private var records: [AnalyticsRecord] = []
    private var tasks: [AnalyticsTask] = []
    private var allowance: [AnalyticsAllowance] = []
    private var ledger: [UsageLedger.Entry] = []
    private var usage: [UUID: TurnUsage] = [:]
    private var actualCosts: [UUID: Double] = [:]
    private var charged: Set<UUID> = []
    private var uncertainDeltas: Set<UUID> = []
    private var ledgerByMessage: [UUID: [Int]] = [:]
    private var ledgerByJob: [UUID: [Int]] = [:]
    private var ledgerBySubagent: [UUID: [Int]] = [:]
    private struct LegacyStart: Hashable { var bot: UUID; var task: UUID?; var second: Int }
    private var ledgerByStart: [LegacyStart: [Int]] = [:]

    public init(zone: TimeZone, now: Date, accounts: [Account] = Accounts.all) {
        self.zone = zone
        self.now = now
        known = accounts
        formatter = Analytics.dayFormatter(zone)
    }

    public func snapshot() -> AnalyticsSnapshot {
        var coverage = coverage
        coverage.problems = coverage.described
        let summary = AnalyticsSummary(records, from: "", through: "9999", tasks: tasks)
        let measures = [
            AnalyticsMeasure(metric: "tokens", provenance: summary.tokens.total == nil ? .unavailable : .actual,
                             value: summary.tokens.total.map(Double.init), note: AnalyticsMeasure.unrecorded[0].note),
            AnalyticsMeasure(metric: "cost", provenance: summary.costProvenance, value: summary.cost,
                             note: AnalyticsMeasure.unrecorded[1].note),
        ]
        let unpriced = Set(records.filter { $0.costProvenance == .unpriced }.flatMap { record in
            record.models.filter { model in
                guard let provider = record.provider else { return true }
                return ModelPricing.price(model, provider: provider, backend: record.providerID ?? (provider == .pi ? "unknown" : nil)) == nil
            }.map { $0.model.isEmpty ? "Unknown" : $0.model }
        }).sorted()
        return AnalyticsSnapshot(generatedAt: now, timeZone: zone.identifier, today: day(now), bots: bots, accounts: accounts,
                                 projects: projects, records: records, tasks: tasks, allowance: allowance, measures: measures, coverage: coverage, unpricedModelIDs: unpriced)
    }

    func day(_ date: Date) -> String { formatter.string(from: date) }

    /// The bot's index, named the first time it is seen.
    @discardableResult
    public mutating func bot(_ id: UUID, name: String) -> Int {
        if let index = botIndex[id] { return index }
        bots.append(name)
        botIndex[id] = bots.count - 1
        return bots.count - 1
    }

    /// The account's index: named as BotChu offers it now, else as its record saved it (`profile`,
    /// `recordedName`), else by its ID; nil for none.
    mutating func account(_ id: String?, profile: Account? = nil, recordedName: String? = nil) -> Int? {
        guard let id, !id.isEmpty else { return nil }
        if let index = accountIndex[id] { return index }
        let offered = known.first(where: { $0.id == id }) ?? (profile?.id == id ? profile : nil) ?? Accounts.all.first(where: { $0.id == id })
        accounts.append(AnalyticsAccount(name: offered?.name ?? recordedName ?? id, family: offered?.kind.displayName ?? "Unknown"))
        accountIndex[id] = accounts.count - 1
        return accounts.count - 1
    }

    /// The repository's index, matched whatever its case; nil for none.
    mutating func project(_ repo: String?) -> Int? {
        guard let repo = repo?.trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty else { return nil }
        let key = repo.lowercased()
        if let index = projectIndex[key] { return index }
        projects.append(repo)
        projectIndex[key] = projects.count - 1
        return projects.count - 1
    }

    /// A scheduled job's run: from when it started (else the time it was for, else when it was
    /// reserved) to when it finished, on the account it recorded as it started.
    public mutating func add(_ run: JobRun, of botID: UUID) {
        guard let agent = botIndex[botID] else { return }
        let outcome: AnalyticsOutcome = switch run.outcome {
        case .succeeded: .finished
        case .failed: .failed
        case .stopped: .stopped
        case .interrupted: .interrupted
        case .waiting, .running: .inProgress
        case .skipped: .skipped
        }
        let start = run.startedAt ?? run.scheduledFor ?? run.reservedAt
        records.append(AnalyticsRecord(kind: .job, day: day(start), outcome: outcome,
                                       seconds: outcome.ended ? Analytics.seconds(from: run.startedAt, to: run.finishedAt) : nil,
                                       bot: agent, account: account(run.accountID, recordedName: run.accountName), project: nil))
        applyUsage(to: records.count - 1, botID: botID, start: start, jobRunID: run.id)
    }

    /// A sub-agent run, as the bot it ran as (named as it was when delegated, if that bot is gone),
    /// on the account it recorded, in the project of the task it was delegated from.
    public mutating func add(_ run: SubagentRun, project repo: String?) {
        let ranAs = bot(run.targetBotID, name: run.targetBotName)
        let outcome: AnalyticsOutcome = switch run.phase {
        case .completed: .finished
        case .failed: .failed
        case .stopped: .stopped
        case .queued, .preparing, .running: .inProgress
        }
        records.append(AnalyticsRecord(kind: .subagent, day: day(run.startedAt ?? run.createdAt), outcome: outcome,
                                       seconds: outcome.ended ? Analytics.seconds(from: run.startedAt, to: run.finishedAt) : nil,
                                       bot: ranAs, account: account(run.accountID, profile: run.accountProfile), project: project(repo)))
        records[records.count - 1].taskID = run.rootTaskID
        applyUsage(to: records.count - 1, botID: run.targetBotID, start: run.startedAt ?? run.createdAt, subagentRunID: run.id)
    }

    /// A conversation's turns (`Analytics.turns`), read from its transcript as far as it can be read.
    /// A job run's task starts with the run itself, which its job's history counts (`runRecorded`), or,
    /// once the job is gone, is counted here as a job run.
    mutating func addTurns(of transcript: URL, bot: Bot, task: BotTask?, running: Bool, runRecorded: Bool = false) {
        let exists = FileManager.default.fileExists(atPath: transcript.path)
        guard exists || task != nil else { return }
        let read = TranscriptRead.read(transcript, keeping: false)
        if exists { coverage.conversations += 1 }
        if read.isDamaged {
            coverage.damagedConversations += 1
            coverage.unreadableLines += read.malformed + read.unsupported
        }
        add(turns: Analytics.turns(read.messages, running: running), bot: bot, task: task, runRecorded: runRecorded)
    }

    /// Adds a conversation's turns, and its task.
    public mutating func add(turns: [AnalyticsTurn], bot: Bot, task: BotTask?, runRecorded: Bool = false) {
        guard let owner = botIndex[bot.id] else { return }
        let accountRef = task.map { (id: $0.accountID, profile: $0.accountProfile) } ?? (id: bot.accountID, profile: bot.accountProfile)
        let onAccount = account(accountRef.id, profile: accountRef.profile)
        let inProject = project(task?.repo)
        var turns = turns
        if task?.jobRun != nil, !turns.isEmpty {
            let run = turns.removeFirst()
            if !runRecorded {
                coverage.jobRunsFromTasks += 1
                records.append(AnalyticsRecord(kind: .job, day: day(run.start), outcome: run.outcome, seconds: run.seconds, bot: owner,
                                               account: onAccount, project: nil))
                applyUsage(to: records.count - 1, botID: bot.id, taskID: task?.id, messageID: run.messageID, start: run.start, jobRunID: task?.jobRun?.runID)
            }
        }
        for turn in turns {
            records.append(AnalyticsRecord(kind: task == nil ? .home : .task, day: day(turn.start), outcome: turn.outcome, seconds: turn.seconds,
                                           bot: owner, account: onAccount, project: inProject))
            records[records.count - 1].taskID = task?.id
            applyUsage(to: records.count - 1, botID: bot.id, taskID: task?.id, messageID: turn.messageID, start: turn.start)
        }
        guard let task, task.jobRun == nil else { return }
        let work: AnalyticsTask.Work
        if task.review != nil {
            work = .review
        } else if let item = task.work {
            work = item.isPullRequest ? .pullRequest : .issue
        } else {
            work = .brief
        }
        tasks.append(AnalyticsTask(day: day(task.createdAt), bot: owner, account: onAccount, project: inProject, work: work, origin: task.origin,
                                   open: !task.isArchived, turns: turns.count, latest: turns.last?.outcome))
        tasks[tasks.count - 1].id = task.id
        tasks[tasks.count - 1].workNumber = task.work?.number
    }

    /// Prepare the complete ledger before joining retained transcripts. Even unmatched entries are
    /// needed as cumulative baselines; pruning a task must not charge its tokens to the next turn.
    public mutating func addLedger(entries: [UsageLedger.Entry], amendments: [UsageLedger.Amendment] = []) {
        var seen: Set<UUID> = []
        ledger = entries.enumerated().filter { seen.insert($0.element.id).inserted }
            .sorted { ($0.element.startedAt, $0.element.at, $0.offset) < ($1.element.startedAt, $1.element.at, $1.offset) }.map(\.element)
        usage = [:]; actualCosts = [:]; charged = []; uncertainDeltas = []
        ledgerByMessage = [:]; ledgerByJob = [:]; ledgerBySubagent = [:]; ledgerByStart = [:]
        for (index, entry) in ledger.enumerated() {
            for message in Set(entry.messageIDs + [entry.messageID].compactMap { $0 }) {
                ledgerByMessage[message, default: []].append(index)
            }
            if let run = entry.jobRunID, entry.kind == .job { ledgerByJob[run, default: []].append(index) }
            if let run = entry.subagentRunID { ledgerBySubagent[run, default: []].append(index) }
            if entry.messageID == nil && entry.messageIDs.isEmpty && entry.subagentRunID == nil {
                let key = LegacyStart(bot: entry.botID, task: entry.taskID, second: Int(entry.startedAt.timeIntervalSince1970.rounded(.down)))
                ledgerByStart[key, default: []].append(index)
            }
        }
        for amendment in amendments where amendment.actualCostUSD.isFinite && amendment.actualCostUSD >= 0 {
            actualCosts[amendment.amends] = amendment.actualCostUSD
        }
        struct Session: Hashable { var account: String; var provider: AgentKind; var backend: String?; var id: UUID }
        var baselines: [Session: TurnUsage] = [:]
        for entry in ledger {
            guard var value = entry.usage else { continue }
            if value.cumulative {
                guard let raw = entry.sessionID, let id = UUID(uuidString: raw) else { continue }
                let key = Session(account: entry.accountID, provider: entry.provider, backend: entry.providerID, id: id)
                let previous = baselines.updateValue(value, forKey: key)
                if let previous {
                    guard let delta = Self.delta(value, from: previous) else { continue }
                    value = delta.usage
                    if !delta.complete { uncertainDeltas.insert(entry.id) }
                } else if entry.resumed { continue }
            }
            guard value.models.allSatisfy({ model in Self.tokenKeys.allSatisfy { (model[keyPath: $0] ?? 0) >= 0 } }) else { continue }
            // Anonymous buckets are differenced before the invocation's requested-model fallback.
            for i in value.models.indices where value.models[i].model.isEmpty { value.models[i].model = entry.model ?? "" }
            usage[entry.id] = value
        }
    }

    private static let tokenKeys: [WritableKeyPath<ModelUsage, Int?>] = [\.uncachedInput, \.cacheRead, \.cacheWrite, \.cacheWrite1h, \.output, \.reasoning]

    private static func delta(_ current: TurnUsage, from previous: TurnUsage) -> (usage: TurnUsage, complete: Bool)? {
        var value = current
        var complete = true
        for i in value.models.indices {
            let older = previous.models.first { $0.model == value.models[i].model }
            for key in tokenKeys {
                guard let count = value.models[i][keyPath: key] else {
                    if older?[keyPath: key] != nil { complete = false }
                    continue
                }
                guard count >= 0 else { return nil }
                guard let before = older?[keyPath: key] else { value.models[i][keyPath: key] = nil; complete = false; continue }
                guard before >= 0, count >= before else { return nil }
                value.models[i][keyPath: key] = count - before
            }
        }
        if let cost = current.reportedCostUSD, let old = previous.reportedCostUSD {
            guard cost.isFinite, old.isFinite, old >= 0, cost >= old else { return nil }
            value.reportedCostUSD = cost - old
        } else { value.reportedCostUSD = nil }
        value.cumulative = false
        if previous.models.contains(where: { old in !current.models.contains(where: { $0.model == old.model }) }) { complete = false }
        return (value, complete)
    }

    private mutating func applyUsage(to index: Int, botID: UUID, taskID: UUID? = nil, messageID: UUID? = nil,
                                     start: Date, jobRunID: UUID? = nil, subagentRunID: UUID? = nil) {
        records[index].startedAt = start
        let candidates: [UsageLedger.Entry]
        if let subagentRunID {
            candidates = (ledgerBySubagent[subagentRunID] ?? []).map { ledger[$0] }
        } else if let jobRunID {
            candidates = (ledgerByJob[jobRunID] ?? []).map { ledger[$0] }
        } else {
            let exact = (messageID.flatMap { ledgerByMessage[$0] } ?? []).map { ledger[$0] }.filter {
                $0.botID == botID && $0.taskID == taskID && $0.subagentRunID == nil
            }
            // ISO8601 ledger times have second precision. Never use a nearby timestamp to override
            // a recorded prompt identity, nor pick arbitrarily when legacy candidates are ambiguous.
            if !exact.isEmpty { candidates = exact }
            else {
                let second = Int(start.timeIntervalSince1970.rounded(.down))
                candidates = (-1...1).flatMap { offset in
                    ledgerByStart[LegacyStart(bot: botID, task: taskID, second: second + offset)] ?? []
                }.map { ledger[$0] }.filter { abs($0.startedAt.timeIntervalSince(start)) < 1 }
            }
        }
        guard candidates.count == 1, let entry = candidates.first else { return }
        records[index].account = account(entry.accountID)
        records[index].model = entry.model
        records[index].modelSource = entry.modelSource
        records[index].provider = entry.provider
        records[index].providerID = entry.providerID
        if let messageID, let owner = entry.messageID, messageID != owner { return }
        guard charged.insert(entry.id).inserted else { return }
        let value = usage[entry.id]
        records[index].models = value?.models ?? []
        records[index].canReprice = value != nil && !uncertainDeltas.contains(entry.id)
        records[index].tokens = AnalyticsTokens(value?.models ?? [])
        if let actual = actualCosts[entry.id] {
            records[index].cost = actual
            records[index].costProvenance = .actual
        } else if let value {
            let prices = value.models.map { ModelPricing.price($0, provider: entry.provider,
                                                               backend: entry.providerID ?? (entry.provider == .pi ? "unknown" : nil)) }
            if !uncertainDeltas.contains(entry.id), !prices.isEmpty, prices.allSatisfy({ $0 != nil }) {
                let total = prices.compactMap { $0?.usd }.reduce(0, +)
                if total.isFinite { records[index].cost = total; records[index].costProvenance = .estimated }
            }
            if records[index].cost == nil, let reported = value.reportedCostUSD, reported.isFinite, reported >= 0 {
                records[index].cost = reported
                records[index].costProvenance = .estimated
            }
            if records[index].cost == nil, value.models.contains(where: \.hasReportedTokens) {
                records[index].costProvenance = .unpriced
            }
        }
    }

    /// Each profile's latest reading in `usage.json`, without its command or any text it came with.
    mutating func readAllowance(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([SavedUsage].self, from: data) else {
            coverage.allowanceUnreadable = true
            return
        }
        addAllowance(saved.map { (request: $0.request, state: $0.state) })
    }

    /// The latest state of each account (a profile's command or key may have changed since an older one).
    public mutating func addAllowance(_ states: [(request: UsageRequest, state: UsageState)]) {
        var latest: [String: (request: UsageRequest, state: UsageState)] = [:]
        for entry in states {
            let id = entry.request.account.id
            if let kept = latest[id], (kept.state.checkedAt ?? .distantPast) >= (entry.state.checkedAt ?? .distantPast) { continue }
            latest[id] = entry
        }
        allowance = latest.values.map { entry -> AnalyticsAllowance in
            let account = known.first(where: { $0.id == entry.request.account.id }) ?? entry.request.account
            let status: AnalyticsAllowance.Status = entry.state.reading == nil ? .unavailable
                : entry.state.isStale(at: now, interval: entry.request.backgroundInterval) ? .stale : .current
            let windows = (entry.state.reading?.windows ?? []).map { window in
                AnalyticsAllowance.Window(title: window.title, usedPercent: window.currentPercent(at: now), resetsAt: window.resetsAt,
                                          hasReset: window.hasReset(at: now))
            }
            return AnalyticsAllowance(account: account.name, family: account.kind.displayName, status: status,
                                      readAt: entry.state.reading?.readAt, windows: windows)
        }
        .sorted { ($0.account.lowercased(), $0.family) < ($1.account.lowercased(), $1.family) }
    }

    /// `usage.json` as `UsageCache` saves it.
    private struct SavedUsage: Decodable {
        var request: UsageRequest
        var state: UsageState
    }
}

// MARK: Summaries

/// The numbers the dashboard shows for a slice of the records: its runs and turns by outcome, failure
/// rate and durations. The dashboard's script works them out the same way in the browser.
public struct AnalyticsSummary: Equatable, Sendable {
    /// Turns and runs, without skipped job times.
    public var runs = 0
    public var outcomes: [AnalyticsOutcome: Int] = [:]
    public var skipped = 0
    /// Those that ended: finished, failed, stopped or interrupted.
    public var ended = 0
    /// Failed among those that ended; nil when none did.
    public var failureRate: Double?
    /// Ended ones with a known duration.
    public var timed = 0
    public var medianSeconds: Double?
    /// The known durations added up; unknown ones add nothing.
    public var totalSeconds: Double = 0

    public var tokens = AnalyticsTokens()
    public var cacheHitRate: Double?
    public var actualCost: Double?
    public var estimatedCost: Double?
    /// Known spend only. Coverage counts keep unpriced/unavailable records visible alongside it.
    public var cost: Double?
    public var costProvenance: AnalyticsMeasure.Provenance = .unavailable
    public var unpriced = 0
    public var unavailable = 0
    public var finishedTasks = 0
    public var costPerFinishedTask: Double?
    public var wastedCost: Double?

    public init(_ records: [AnalyticsRecord], from: String, through: String,
                kinds: Set<AnalyticsRecord.Kind> = Set(AnalyticsRecord.Kind.allCases), tasks: [AnalyticsTask] = [], where include: (AnalyticsRecord) -> Bool = { _ in true }) {
        var durations: [Double] = []
        let selected = records.filter { $0.day >= from && $0.day <= through && kinds.contains($0.kind) && include($0) && $0.outcome != .skipped }
        tokens = AnalyticsTokens(selected.map { $0.tokens.modelUsage })
        cacheHitRate = tokens.cacheHitRate
        func sum(_ values: [Double?]) -> Double? {
            let known = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }
            guard !known.isEmpty else { return nil }
            let total = known.reduce(0, +)
            return total.isFinite ? total : nil
        }
        actualCost = sum(selected.filter { $0.costProvenance == .actual }.map(\.cost))
        estimatedCost = sum(selected.filter { $0.costProvenance == .estimated }.map(\.cost))
        cost = sum([actualCost, estimatedCost])
        unpriced = selected.filter { $0.costProvenance == .unpriced }.count
        unavailable = selected.filter { $0.costProvenance == .unavailable }.count
        costProvenance = estimatedCost != nil ? .estimated : actualCost != nil ? .actual : unpriced > 0 ? .unpriced : .unavailable
        wastedCost = sum(selected.filter { [.failed, .stopped, .interrupted].contains($0.outcome) }.map(\.cost))
        let representedTasks = Set(selected.filter { $0.kind == .task || $0.kind == .subagent }.compactMap(\.taskID))
        let finished = Set(tasks.filter { $0.latest == .finished }.compactMap(\.id)).intersection(representedTasks)
        finishedTasks = finished.count
        let finishedSpend = sum(selected.filter { $0.taskID.map { finished.contains($0) } == true && ($0.kind == .task || $0.kind == .subagent) }.map(\.cost))
        costPerFinishedTask = finishedTasks > 0 ? finishedSpend.map { $0 / Double(finishedTasks) } : nil
        for record in records where record.day >= from && record.day <= through && kinds.contains(record.kind) && include(record) {
            guard record.outcome != .skipped else {
                skipped += 1
                continue
            }
            runs += 1
            outcomes[record.outcome, default: 0] += 1
            guard record.outcome.ended else { continue }
            ended += 1
            if let seconds = record.seconds { durations.append(seconds) }
        }
        failureRate = ended == 0 ? nil : Double(outcomes[.failed] ?? 0) / Double(ended)
        timed = durations.count
        medianSeconds = Self.median(durations)
        totalSeconds = durations.reduce(0, +)
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
