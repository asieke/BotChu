import Foundation

// MARK: What a daily review covers

/// A conversation a run review covers: a bot's Home, or one of its tasks.
public struct ReviewConversation: Codable, Hashable, Sendable {
    /// The bot whose conversation it is.
    public var botID: UUID
    /// Nil for the bot's Home.
    public var taskID: UUID?

    public init(botID: UUID, taskID: UUID? = nil) {
        self.botID = botID
        self.taskID = taskID
    }
}

/// One conversation's work since it was last reviewed, as the daily review of one bot sees it
/// (#138): the conversation's own finished turns, when it is that bot's, and the finished sub-agent
/// runs delegated from it that ran as that bot. Its turns are read from the saved transcript, from
/// after the last message reviewed (its cursor) to the end of the last finished turn, so a review
/// sees nothing twice and misses nothing between two reviews, and a turn still running when a
/// review starts waits for the next one.
public struct ReviewStretch: Codable, Equatable, Sendable {
    public var conversation: ReviewConversation
    /// The last message reviewed, and its turn's end, where the stretch starts when the transcript
    /// no longer holds that message; nil before the conversation's first review.
    public var cursor: UUID?
    public var cursorDate: Date?
    /// Where the stretch starts before a first review: the prompt of the first turn handed over,
    /// or the first message of a per-turn review folded into it (`RunEvaluator.load`).
    public var from: UUID?
    /// The last message of the last finished turn, and when that turn ended, where the stretch ends
    /// when the transcript no longer holds that message; nil while it holds none of the
    /// conversation's own turns.
    public var through: UUID?
    public var throughDate: Date?
    /// Finished sub-agent runs delegated from the conversation that ran as the bot the review is about.
    public var subagents: [UUID]
    /// When its oldest unreviewed work ended, or the last Retry of a review of it: work left
    /// unreviewed for `RunEvaluator.Limits.skipAfter` from then is skipped.
    public var since: Date

    public init(conversation: ReviewConversation, cursor: UUID? = nil, cursorDate: Date? = nil, from: UUID? = nil, through: UUID? = nil,
                throughDate: Date? = nil, subagents: [UUID] = [], since: Date) {
        self.conversation = conversation
        self.cursor = cursor
        self.cursorDate = cursorDate
        self.from = from
        self.through = through
        self.throughDate = throughDate
        self.subagents = subagents
        self.since = since
    }

    public var hasTurns: Bool { throughDate != nil }
    public var hasWork: Bool { hasTurns || !subagents.isEmpty }

    /// Where its turns are in the conversation's saved transcript: after the cursor (or from its
    /// first turn's prompt) through the end of its last finished turn; empty without turns.
    public func range(in transcript: [ChatMessage]) -> Range<Int> {
        guard let throughDate else { return 0..<0 }
        let end: Int
        if let through, let index = transcript.lastIndex(where: { $0.id == through }) {
            end = index + 1
        } else {
            end = (transcript.lastIndex { $0.date <= throughDate } ?? -1) + 1
        }
        let start: Int
        if let cursor, let index = transcript.lastIndex(where: { $0.id == cursor }) {
            start = index + 1
        } else if let from, let index = transcript.lastIndex(where: { $0.id == from }) {
            // From the prompt of the turn it is in.
            start = transcript[...index].lastIndex { $0.role == .user } ?? index
        } else if let cursorDate {
            start = transcript.firstIndex { $0.date > cursorDate } ?? transcript.count
        } else if from != nil {
            // Its first message is gone (the transcript was rewritten): its last turn, at least.
            start = transcript[..<end].lastIndex { $0.role == .user } ?? end
        } else {
            start = 0
        }
        return min(start, end)..<end
    }

    /// The stretch once a review has covered `coverage`, or nil when nothing is left of it. The
    /// cursor only moves forward, and work handed over while the review ran stays for the next one.
    public func advanced(past coverage: ReviewCoverage) -> ReviewStretch? {
        var stretch = self
        if let reviewed = coverage.throughDate, reviewed >= (cursorDate ?? .distantPast) {
            stretch.cursor = coverage.through
            stretch.cursorDate = reviewed
            stretch.from = nil
            // A turn that ended after the review read the stretch stays.
            let newer = (throughDate ?? .distantPast) > reviewed || (through != nil && coverage.through != nil && through != coverage.through)
            if !newer {
                stretch.through = nil
                stretch.throughDate = nil
            }
            stretch.since = max(since, reviewed)
        }
        stretch.subagents.removeAll { coverage.subagents.contains($0) }
        return stretch.hasWork ? stretch : nil
    }

    /// The stretch without its turns up to `last`, which ended while reviews were off and are
    /// never reviewed; nil when nothing is left of it.
    func dropping(through last: UUID, at date: Date) -> ReviewStretch? {
        var stretch = self
        stretch.cursor = last
        stretch.cursorDate = date
        stretch.from = nil
        stretch.through = nil
        stretch.throughDate = nil
        return stretch.hasWork ? stretch : nil
    }

    /// All of it, as a review covering it records it.
    func coverage(title: String = "", signal: Bool = false) -> ReviewCoverage {
        ReviewCoverage(conversation: conversation, title: title, through: through, throughDate: throughDate, subagents: subagents, signal: signal)
    }
}

/// What a review covered of one conversation's stretch, so that once it has reviewed it the
/// stretch's cursor moves past exactly that (`ReviewStretch.advanced`), and a task's Activity can
/// list the reviews that covered it.
public struct ReviewCoverage: Codable, Equatable, Sendable {
    public var conversation: ReviewConversation
    /// The conversation as the review named it: "Home", or the task's title.
    public var title: String
    public var through: UUID?
    public var throughDate: Date?
    public var subagents: [UUID]
    /// Whether it had signal (`ReviewSignals`), so the review saw more than its header lines.
    public var signal: Bool

    public init(conversation: ReviewConversation, title: String, through: UUID?, throughDate: Date?, subagents: [UUID], signal: Bool) {
        self.conversation = conversation
        self.title = title
        self.through = through
        self.throughDate = throughDate
        self.subagents = subagents
        self.signal = signal
    }
}

/// A bot's run reviews between launches: the stretches of work waiting for its next review, and
/// the last review time it handled. Saved in its `.botchu/run-reviews.json`.
public struct ReviewState: Codable, Equatable, Sendable {
    public var stretches: [ReviewStretch]
    public var handled: ReviewTime.Handled?

    public init(stretches: [ReviewStretch] = [], handled: ReviewTime.Handled? = nil) {
        self.stretches = stretches
        self.handled = handled
    }

    /// The conversations with work waiting, for `taskID` alone when given.
    public func unreviewed(task taskID: UUID? = nil) -> [ReviewStretch] {
        stretches.filter { $0.hasWork && (taskID == nil || $0.conversation.taskID == taskID) }
    }

    /// Keeps `stretch` in the place of the conversation's, or adds it.
    mutating func upsert(_ stretch: ReviewStretch) {
        if let index = stretches.firstIndex(where: { $0.conversation == stretch.conversation }) {
            stretches[index] = stretch
        } else {
            stretches.append(stretch)
        }
    }
}

extension BotHome {
    public var reviewStateURL: URL { url.appendingPathComponent("run-reviews.json") }

    public func loadReviewState() -> ReviewState? {
        (try? Data(contentsOf: reviewStateURL)).flatMap { try? Store.decoder.decode(ReviewState.self, from: $0) }
    }

    /// Saves it only into an existing `.botchu/`: a bot folder that is gone isn't made again.
    public func save(_ state: ReviewState) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        try Store.encoder.encode(state).write(to: reviewStateURL, options: .atomic)
    }

    /// A task's saved record, or nil when it can't be read.
    public func loadTask(_ id: UUID) -> BotTask? {
        (try? Data(contentsOf: taskURL(id).appendingPathComponent("task.json"))).flatMap { try? Store.decoder.decode(BotTask.self, from: $0) }
    }

    /// A sub-agent run's saved record, beside its root conversation.
    public func loadSubagent(_ id: UUID, taskID: UUID?) -> SubagentRun? {
        (try? Data(contentsOf: subagentURL(id: id, taskID: taskID).appendingPathComponent("run.json")))
            .flatMap { try? SubagentIPC.decode(SubagentRun.self, from: $0) }
    }
}

// MARK: When

/// When daily run reviews are due: a time of day in the Mac's time zone, 04:00 unless the owner
/// sets another in Settings ▸ Run reviews. Its occurrences and missed days come from `JobSchedule`
/// and `JobPlanner`: a time missed while BotChu was closed or the Mac asleep is due once, at the
/// first chance afterwards. Each occurrence handled is kept with the calendar day it was for, so
/// changing the Mac's time zone or a daylight-saving change never makes one day due twice.
public struct ReviewTime: Codable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public static let standard = ReviewTime(hour: 4, minute: 0)

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    /// The last occurrence handled, and its calendar day ("2026-10-25") in the zone it was handled in.
    public struct Handled: Codable, Equatable, Sendable {
        public var occurrence: Date
        public var day: String

        public init(occurrence: Date, day: String) {
            self.occurrence = occurrence
            self.day = day
        }
    }

    public enum Due: Equatable, Sendable {
        case none
        /// An occurrence for a day already reviewed (the Mac's time zone moved west): handled, with nothing due.
        case handled(Handled)
        /// The day's reviews are due; `missed` earlier occurrences went by since the last one handled.
        case review(Handled, missed: Int)
    }

    public func schedule(in zone: TimeZone) -> JobSchedule {
        JobSchedule(kind: .daily, hour: hour, minute: minute, anchor: .distantPast, timeZone: zone.identifier)
    }

    /// What is due at `now`, after `handled`: only the latest occurrence since, however many were missed.
    public func due(now: Date, in zone: TimeZone, after handled: Handled) -> Due {
        let decision = JobPlanner.decide(schedule(in: zone), handledThrough: handled.occurrence, missedRuns: .runOnce,
                                         catchUpWindow: .infinity, now: now)
        guard case .run(let occurrence, _, let missed) = decision else { return .none }
        let next = Handled(occurrence: occurrence, day: Self.day(of: occurrence, in: zone))
        return next.day > handled.day ? .review(next, missed: missed) : .handled(next)
    }

    /// The occurrence a bot's first review counts from: the latest at or before `date`, so that
    /// its first review is at the next one.
    public func handled(atOrBefore date: Date, in zone: TimeZone) -> Handled {
        let occurrence = schedule(in: zone).latest(atOrBefore: date, after: .distantPast) ?? date
        return Handled(occurrence: occurrence, day: Self.day(of: occurrence, in: zone))
    }

    /// When the next review is due after `date`: the first occurrence after the last handled, on a later day.
    public func next(after date: Date, in zone: TimeZone, handled: Handled?) -> Date? {
        let schedule = schedule(in: zone)
        var cursor = max(date, handled?.occurrence ?? date)
        for _ in 0..<3 {
            guard let occurrence = schedule.next(after: cursor) else { return nil }
            if Self.day(of: occurrence, in: zone) > (handled?.day ?? "") { return occurrence }
            cursor = occurrence
        }
        return nil
    }

    static func day(of date: Date, in zone: TimeZone) -> String {
        let parts = JobSchedule.gmt.dateComponents([.year, .month, .day], from: JobSchedule.civilDay(of: date, in: zone))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Such as "Sat, Oct 25", for a review's title.
    public static func dayText(_ date: Date, in zone: TimeZone, locale: Locale = .current) -> String {
        format(date, "EEEMMMd", zone: zone, locale: locale)
    }

    /// Such as "04:00" or "4:00 AM", as the locale writes a time.
    public static func timeText(_ date: Date, in zone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func format(_ date: Date, _ template: String, zone: TimeZone, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

// MARK: Signal

/// A turn of a conversation, or a sub-agent run, as a daily review's signal gate and snapshot see it.
public struct ReviewSegment: Sendable {
    public var messages: [ChatMessage]
    /// The sub-agent run it is; nil for a turn.
    public var run: SubagentRun?
    public var ending: RunEnding
    /// Why it failed, as its transcript or record says.
    public var error: String?
    public var start: Date
    public var end: Date
    public var toolCalls: Int
    public var failedToolCalls: Int
    /// In a task, the owner's messages after its brief.
    public var steering: Int
    /// For a sub-agent run, the bot that delegated it.
    public var caller: String?
}

/// What in a stretch of work is worth a review, worked out from its transcript and sub-agent runs
/// without a model call (#138): a failed turn or run (a handoff that couldn't be saved fails its
/// run), a run the owner stopped, the owner steering a task after its brief, and many failed tool
/// calls, many tool calls or a long time at work, by `RunEvaluator.Limits`. "Used a tool" is true
/// of nearly every run, so it isn't one.
public struct ReviewSignals: Equatable, Sendable {
    public var failures = 0
    public var stops = 0
    public var steering = 0
    public var toolCalls = 0
    public var failedToolCalls = 0
    /// The turns' and runs' time at work, each from its first message to its last.
    public var time: TimeInterval = 0

    public init(failures: Int = 0, stops: Int = 0, steering: Int = 0, toolCalls: Int = 0, failedToolCalls: Int = 0, time: TimeInterval = 0) {
        self.failures = failures
        self.stops = stops
        self.steering = steering
        self.toolCalls = toolCalls
        self.failedToolCalls = failedToolCalls
        self.time = time
    }

    public init(_ segments: [ReviewSegment]) {
        for segment in segments {
            if segment.ending == .failed { failures += 1 }
            if segment.ending == .stopped { stops += 1 }
            steering += segment.steering
            toolCalls += segment.toolCalls
            failedToolCalls += segment.failedToolCalls
            time += max(0, segment.end.timeIntervalSince(segment.start))
        }
    }

    public func hasSignal(_ limits: RunEvaluator.Limits) -> Bool { !words(limits).isEmpty }

    /// The signals in words, as a conversation's header gives them; empty without signal.
    public func words(_ limits: RunEvaluator.Limits) -> [String] {
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var words: [String] = []
        if failures > 0 { words.append(count(failures, "failed turn or run", "failed turns or runs")) }
        if stops > 0 { words.append(count(stops, "run stopped", "runs stopped")) }
        if steering > 0 { words.append(steering == 1 ? "the owner steered once" : "the owner steered \(steering) times") }
        if failedToolCalls >= limits.failedToolCalls { words.append(count(failedToolCalls, "failed tool call", "failed tool calls")) }
        if toolCalls >= limits.toolCalls { words.append(count(toolCalls, "tool call", "tool calls")) }
        if time >= limits.turnTime { words.append(JobWords.duration(time) + " at work") }
        return words
    }

    /// A conversation stretch's turns, split where the owner wrote: `opening` is the id of a
    /// task's first message, its brief, after which every owner message steers; nil for Home, whose
    /// owner messages are new requests, not steering.
    public static func turns(_ messages: ArraySlice<ChatMessage>, task: Bool, opening: UUID?) -> [ReviewSegment] {
        var starts = messages.indices.filter { messages[$0].role == .user }
        if starts.first != messages.startIndex, !messages.isEmpty { starts.insert(messages.startIndex, at: 0) }
        return starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : messages.endIndex
            let turn = Array(messages[start..<end])
            var segment = segment(turn, run: nil)
            segment.steering = task ? turn.filter { $0.role == .user && $0.id != opening }.count : 0
            if turn.contains(where: \.isStopNote) {
                segment.ending = .stopped
            } else if let last = turn.last(where: { $0.role == .assistant || $0.role == .error }), last.role == .error {
                // Only the last word counts: a CLI reports errors it recovers from before its reply.
                segment.ending = .failed
                segment.error = last.text
            }
            return segment
        }
    }

    /// A finished sub-agent run; nil while it runs.
    public static func run(_ run: SubagentRun, messages: [ChatMessage]) -> ReviewSegment? {
        var segment = segment(messages, run: run)
        switch run.phase {
        case .completed: segment.ending = .finished
        case .failed: segment.ending = .failed
        case .stopped: segment.ending = .stopped
        case .queued, .preparing, .running: return nil
        }
        segment.error = run.errorMessage
        // Its record's times when it has both; else its transcript's.
        if let started = run.startedAt, let finished = run.finishedAt {
            segment.start = started
            segment.end = max(started, finished)
        }
        return segment
    }

    private static func segment(_ messages: [ChatMessage], run: SubagentRun?) -> ReviewSegment {
        let tools = messages.filter { $0.role == .tool }
        let failed = tools.filter { tool in
            switch tool.toolState ?? .done {
            case .failed: true
            case .done: (tool.toolExitCode ?? 0) != 0
            case .running, .interrupted: false
            }
        }
        let start = messages.first?.date ?? .distantPast
        let end = messages.map { $0.date.addingTimeInterval($0.toolDuration ?? 0) }.max() ?? start
        return ReviewSegment(messages: messages, run: run, ending: .finished, error: nil, start: start, end: max(start, end),
                             toolCalls: tools.count, failedToolCalls: failed.count, steering: 0, caller: nil)
    }
}

// MARK: The day's snapshot

/// What a bot's daily review (or a Review now) is about, gathered on the main actor: the bot, and
/// each stretch of its work with where to read it. `ReviewDay.build` reads the rest off it.
public struct ReviewDayInput: Sendable {
    public struct Source: Sendable {
        public var stretch: ReviewStretch
        /// The folder of the bot whose conversation it is, which holds its transcript and its
        /// sub-agents' runs; nil once that bot is gone, and its work with it.
        public var workspace: String?
        /// That bot's name.
        public var owner: String

        public init(stretch: ReviewStretch, workspace: String?, owner: String) {
            self.stretch = stretch
            self.workspace = workspace
            self.owner = owner
        }
    }

    public var botID: UUID
    public var botName: String
    /// The bot's own folder, for its memory as the review starts.
    public var workspace: String
    public var sources: [Source]
    public var zone: TimeZone

    public init(botID: UUID, botName: String, workspace: String, sources: [Source], zone: TimeZone = .current) {
        self.botID = botID
        self.botName = botName
        self.workspace = workspace
        self.sources = sources
        self.zone = zone
    }
}

/// A bot's day of work as its review sees it, read from the saved transcripts and sub-agent runs
/// off the main actor: one snapshot, grouped by conversation, those with signal first and newest
/// first within each group, within `RunEvaluator.Limits.snapshotCharacters`. Each conversation has
/// a header line (what it is, and its signal), and each turn and sub-agent run one (how it ended,
/// its tool calls, its time); header lines are never left out, long passages are shortened first,
/// and a conversation without signal gives only its header lines. Labels, redaction and evidence
/// are as in a run's snapshot (`EvaluationSnapshot`), numbered across the day.
public struct ReviewDay: Sendable {
    public var snapshot: EvaluationSnapshot
    /// What it covered of each stretch, signal or not: every cursor moves past it once it is reviewed.
    public var coverage: [ReviewCoverage]
    public var hasSignal: Bool
    /// The bot's memory notes as the review starts, without any that look like secrets.
    public var memory: [String]

    struct Block {
        var title: String
        var short: String
        var header: String
        var brief: String?
        var segments: [ReviewSegment]
        var opening: (id: UUID, label: String)?
        var signals: ReviewSignals
        var signal: Bool
        var latest: Date
    }

    public static func build(_ input: ReviewDayInput, limits: RunEvaluator.Limits) -> ReviewDay {
        var blocks: [Block] = []
        var coverage: [ReviewCoverage] = []
        for source in input.sources {
            let block = Self.block(source, input: input, limits: limits)
            coverage.append(source.stretch.coverage(title: block?.short ?? "", signal: block?.signal ?? false))
            if let block, !block.segments.isEmpty { blocks.append(block) }
        }
        // Signal first, then newest first.
        blocks.sort { ($0.signal ? 1 : 0, $0.latest) > ($1.signal ? 1 : 0, $1.latest) }
        let memory = MemoryNotes.bullets(in: Workspace.read(MemoryFile.bot(workspace: input.workspace).path)).filter { !MemoryNotes.isSecret($0) }
        return ReviewDay(snapshot: snapshot(of: blocks, input: input, limits: limits), coverage: coverage,
                         hasSignal: blocks.contains(where: \.signal), memory: memory)
    }

    private static func block(_ source: ReviewDayInput.Source, input: ReviewDayInput, limits: RunEvaluator.Limits) -> Block? {
        guard let workspace = source.workspace else { return nil }
        let stretch = source.stretch, home = BotHome(workspace: workspace)
        let task = stretch.conversation.taskID.flatMap(home.loadTask)
        if stretch.conversation.taskID != nil, task == nil { return nil }
        let taskID = stretch.conversation.taskID
        var segments: [ReviewSegment] = []
        var opening: (id: UUID, label: String)?
        if stretch.hasTurns {
            let transcript = task.map { home.loadThread(task: $0.id) } ?? home.loadThread()
            let first = task == nil ? nil : transcript.first(where: { $0.role == .user })
            if let first { opening = (first.id, task?.origin == .home ? "Brief (from the bot's Home)" : "Owner") }
            segments += ReviewSignals.turns(transcript[stretch.range(in: transcript)], task: task != nil, opening: first?.id)
        }
        for id in stretch.subagents {
            guard let run = home.loadSubagent(id, taskID: taskID),
                  var segment = ReviewSignals.run(run, messages: home.loadSubagentThread(id: id, taskID: taskID)) else { continue }
            segment.caller = run.parentSubagentID.flatMap { home.loadSubagent($0, taskID: taskID)?.targetBotName } ?? source.owner
            segments.append(segment)
        }
        segments.sort { $0.start < $1.start }
        let signals = ReviewSignals(segments)
        let signal = signals.hasSignal(limits)
        let own = stretch.conversation.botID == input.botID
        let owner = EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine(source.owner), 120)
        let title: String, short: String
        if let task {
            let machine = task.hostName.map { "\(EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine($0), 80)) over SSH" }
                ?? (task.isRemote ? "another computer over SSH" : "This Mac")
            let place = "the task “\(EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine(task.title), 200))”"
                + (task.jobRun == nil ? " in \(EvaluationSnapshot.quoted(task.repo, 200))" : ", a scheduled job's run")
                + (task.work.map { task.review == nil ? ", on \($0.reference)" : ", reviewing \($0.reference)" } ?? "")
                + ", on \(machine), \(task.isArchived ? "closed" : "open")"
            title = own ? place : "sub-agent runs as \(EvaluationSnapshot.quoted(input.botName, 120)), delegated by \(owner) from \(place)"
            short = (own ? "" : "\(source.owner)'s ") + "“\(EvaluationSnapshot.oneLine(task.title))”"
        } else {
            title = own ? "\(owner)'s Home" : "sub-agent runs as \(EvaluationSnapshot.quoted(input.botName, 120)), delegated by \(owner) from its Home"
            short = own ? "Home" : "\(source.owner)'s Home"
        }
        let brief = task?.brief.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Block(title: title, short: short, header: signal ? "signal: " + signals.words(limits).joined(separator: ", ") : "no signal",
                     brief: own && signal && !brief.isEmpty ? brief : nil, segments: segments, opening: opening, signals: signals,
                     signal: signal, latest: segments.map(\.end).max() ?? stretch.since)
    }

    /// The snapshot's text: every header line, and the passages of conversations with signal,
    /// shortened tier by tier until the day fits, then left out from the middle of each run.
    private static func snapshot(of blocks: [Block], input: ReviewDayInput, limits: RunEvaluator.Limits) -> EvaluationSnapshot {
        let budget = limits.snapshotCharacters
        let withSignal = blocks.filter(\.signal).count
        let head = [
            "Day: \(EvaluationSnapshot.quoted(input.botName, 120))'s work since its last review: \(blocks.count) conversation\(blocks.count == 1 ? "" : "s"), \(withSignal) with signal (a failure, a stop, the owner steering, or a long run). Conversations with signal come first, newest first; one without signal is given by its header lines alone.",
            "Each turn and sub-agent run starts with a header line saying how it ended, as BotChu saw it. A finished turn doesn't show the work succeeded; judge from the evidence. A stopped run is neither a failure nor finished work; don't continue it.",
            "[M#] are messages and [T#] tool calls, numbered across the day, oldest first in each conversation.",
        ].joined(separator: "\n")
        var tools = 0, failed = 0
        for block in blocks {
            tools += block.signals.toolCalls
            failed += block.signals.failedToolCalls
        }
        var best: Rendered?
        for passages in EvaluationSnapshot.Passages.tiers {
            let rendered = render(blocks, head: head, passages: passages, zone: input.zone)
            best = rendered
            if rendered.length <= budget { break }
        }
        guard var rendered = best else {
            return EvaluationSnapshot(text: head, evidence: [:], toolCalls: tools, failedToolCalls: failed, sources: [:])
        }
        if rendered.length > budget {
            // Each run's passages get a share of what the header lines leave, by their length.
            let fixed = rendered.parts.reduce(0) { $0 + $1.fixed.count + 1 }
            let items = rendered.parts.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.line.count + 1 } }
            let room = max(0, budget - fixed)
            for index in rendered.parts.indices where !rendered.parts[index].items.isEmpty {
                let size = rendered.parts[index].items.reduce(0) { $0 + $1.line.count + 1 }
                let share = items == 0 ? 0 : room * size / items
                let kept = EvaluationSnapshot.bounded(rendered.parts[index].items.map(\.line), within: max(share, 80))
                rendered.parts[index].kept = kept.indices
            }
        }
        var lines: [String] = []
        var evidence: [String: String] = [:], sources: [String: String] = [:]
        func add(_ item: Rendered.Item) {
            lines.append(item.line)
            let first = item.line.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            evidence[item.label] = EvaluationSnapshot.clip(first, EvaluationSnapshot.maxEvidenceCharacters)
            sources[item.label] = item.source
        }
        for part in rendered.parts {
            lines.append(part.fixed)
            guard let kept = part.kept else {
                for item in part.items { add(item) }
                continue
            }
            let skipped = part.items.count - kept.compactMap { $0 }.count
            for index in kept {
                if let index { add(part.items[index]) } else {
                    lines.append("[… \(skipped) message\(skipped == 1 ? "" : "s") and tool calls left out …]")
                }
            }
        }
        return EvaluationSnapshot(text: lines.joined(separator: "\n"), evidence: evidence, toolCalls: tools, failedToolCalls: failed, sources: sources)
    }

    /// The day as lines: each part a header (or the brief) that is always kept, and the labelled
    /// items under it, which may be shortened or left out.
    struct Rendered {
        struct Item {
            var label: String
            var line: String
            var source: String
        }
        struct Part {
            var fixed: String
            var items: [Item] = []
            /// The items kept, nil for all, with nil standing for the line saying how many were left out.
            var kept: [Int?]?
        }
        var parts: [Part]
        var length: Int { parts.reduce(0) { $0 + $1.fixed.count + 1 + $1.items.reduce(0) { $0 + $1.line.count + 1 } } }
    }

    private static func render(_ blocks: [Block], head: String, passages: EvaluationSnapshot.Passages, zone: TimeZone) -> Rendered {
        var parts = [Rendered.Part(fixed: head)]
        var messages = 0, tools = 0
        for (number, block) in blocks.enumerated() {
            parts.append(Rendered.Part(fixed: "Conversation \(number + 1): \(block.title) · \(block.header)"))
            if let brief = block.brief {
                parts.append(Rendered.Part(fixed: "Brief:\n    \(EvaluationSnapshot.quoted(brief, passages.brief))"))
            }
            var turn = 0
            for segment in block.segments {
                var part = Rendered.Part(fixed: header(segment, turn: &turn, zone: zone))
                if block.signal {
                    let brief = segment.run?.brief.trimmingCharacters(in: .whitespacesAndNewlines) ?? block.brief ?? ""
                    if segment.run != nil, !brief.isEmpty {
                        // A sub-agent's brief, given once under its header.
                        part.fixed += "\nBrief (from \(EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine(segment.caller ?? "its caller"), 120))):\n    "
                            + EvaluationSnapshot.quoted(brief, passages.brief)
                    }
                    let opening = segment.run == nil ? block.opening : segment.messages.first(where: { $0.role == .user }).map { message in
                        (message.id, "Brief (from \(EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine(segment.caller ?? "its caller"), 120)))")
                    }
                    for item in EvaluationSnapshot.items(segment.messages, brief: brief, opening: opening, passages: passages) {
                        let label: String
                        if item.tool {
                            tools += 1
                            label = "T\(tools)"
                        } else {
                            messages += 1
                            label = "M\(messages)"
                        }
                        part.items.append(Rendered.Item(label: label, line: "[\(label)] \(item.text)", source: block.short))
                    }
                }
                parts.append(part)
            }
        }
        return Rendered(parts: parts)
    }

    /// A turn's or sub-agent run's header line: what it was and when, how it ended, its tool calls and its time.
    private static func header(_ segment: ReviewSegment, turn: inout Int, zone: TimeZone) -> String {
        let when = ReviewTime.format(segment.start, "MMMdHHmm", zone: zone, locale: Locale(identifier: "en_US_POSIX"))
        let what: String
        if let run = segment.run {
            let place = run.workspaceMode == .sharedCallerWorkspace ? "in the caller's workspace" : "in its own folder"
            what = "Sub-agent run “\(EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine(run.title), 200))” of \(EvaluationSnapshot.quoted(run.targetBotName, 120)), "
                + "delegated by \(EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine(segment.caller ?? "its caller"), 120)) at depth \(run.depth), \(place), \(when)"
        } else {
            turn += 1
            what = "Turn \(turn), \(when)"
        }
        let ending = switch segment.ending {
        case .finished: "finished"
        case .stopped: "stopped"
        case .failed: "failed: " + EvaluationSnapshot.quoted(EvaluationSnapshot.oneLine(EvaluationSnapshot.redacted(segment.error ?? "no reason given")), 300)
        }
        let calls = segment.toolCalls == 0 ? "no tool calls"
            : "\(segment.toolCalls) tool call\(segment.toolCalls == 1 ? "" : "s")" + (segment.failedToolCalls > 0 ? " (\(segment.failedToolCalls) failed)" : "")
        let time = segment.end.timeIntervalSince(segment.start) < 60 ? "under a minute" : JobWords.duration(segment.end.timeIntervalSince(segment.start))
        return "\(what) · \(ending) · \(calls) · \(time)"
    }
}
