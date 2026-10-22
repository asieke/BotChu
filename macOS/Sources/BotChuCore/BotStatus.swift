import Foundation

/// A turn in progress: when it started, whether its CLI has printed anything yet, and what the
/// bot is doing now (from the turn's events). A task's first turn waits while BotChu makes its
/// worktree (`preparing`).
public struct RunState: Equatable, Sendable {
    public var startedAt: Date
    public var hasOutput: Bool
    public var preparing: Bool
    public private(set) var activity: BotActivity
    public private(set) var activitySince: Date
    /// Thinking, waiting until the tool's activity has shown for `minimumShow`.
    public private(set) var pending: BotActivity?

    /// Most tool calls take a moment; their animation shows at least this long, so it can be seen.
    public static let minimumShow: TimeInterval = 2.5

    public init(startedAt: Date = Date(), hasOutput: Bool = false, preparing: Bool = false, activity: BotActivity = .thinking) {
        self.startedAt = startedAt
        self.hasOutput = hasOutput
        self.preparing = preparing
        self.activity = activity
        activitySince = startedAt
    }

    /// Moves to `next`. Going back to thinking from a tool's activity waits until that activity has
    /// shown for `minimumShow`; then this returns how long to wait before calling `settle`.
    public mutating func move(to next: BotActivity, at now: Date = Date()) -> TimeInterval? {
        if next == activity {
            pending = nil
            return nil
        }
        let shown = now.timeIntervalSince(activitySince)
        if next == .thinking, activity != .thinking, shown < Self.minimumShow {
            pending = next
            return Self.minimumShow - shown
        }
        activity = next
        activitySince = now
        pending = nil
        return nil
    }

    /// Takes the activity that was waiting, once its time has come.
    public mutating func settle(at now: Date = Date()) {
        guard let pending, now.timeIntervalSince(activitySince) >= Self.minimumShow - 0.05 else { return }
        activity = pending
        activitySince = now
        self.pending = nil
    }
}

/// What the status sidebar shows about a bot or one of its tasks, derived from its settings, its
/// thread and its run.
public struct BotStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// BotChu is making a task's worktree, before its turn starts.
        case preparing
        /// A turn started, and its CLI has printed nothing yet.
        case starting
        case working
        /// The last turn ended in an error.
        case failed
    }

    public enum Session: Equatable, Sendable {
        /// The next message continues this CLI session.
        case continuing(id: String)
        /// The next message starts a session; `accountChanged` when the last one was on another account.
        case startsNew(accountChanged: Bool)
    }

    public var phase: Phase
    public var runStartedAt: Date?
    public var session: Session
    /// Messages from the owner and the bot.
    public var messageCount: Int
    public var toolCallCount: Int
    public var lastActivity: Date?
    public var lastError: String?
    /// What the bot's pet shows: the turn's activity, else a short reaction (`greeting`, `done`),
    /// else `failed` after a failed turn, else `idle`.
    public var activity: BotActivity
    /// For a bot whose Home is idle while tasks work (`working(on:)`): the task's title, or how many.
    public var workingOn: String?

    public static func make(bot: Bot, messages: [ChatMessage], run: RunState?, reaction: BotActivity? = nil) -> BotStatus {
        make(settings: bot, messages: messages, run: run, reaction: reaction)
    }

    public static func make(task: BotTask, messages: [ChatMessage], run: RunState?, reaction: BotActivity? = nil) -> BotStatus {
        make(settings: task, messages: messages, run: run, reaction: reaction)
    }

    static func make(settings: some RunSettings, messages: [ChatMessage], run: RunState?, reaction: BotActivity?) -> BotStatus {
        let lastError: String? = {
            guard let last = messages.last(where: { !$0.role.isNote }), last.role == .error else { return nil }
            return last.text
        }()
        let phase: Phase
        if let run {
            phase = run.preparing ? .preparing : run.hasOutput ? .working : .starting
        } else {
            phase = lastError == nil ? .idle : .failed
        }
        let session: Session
        if let id = settings.resumableSessionID {
            session = .continuing(id: id)
        } else {
            session = .startsNew(accountChanged: settings.sessionID != nil && settings.sessionAccountID != settings.accountID)
        }
        return BotStatus(
            phase: phase,
            runStartedAt: run?.startedAt,
            session: session,
            messageCount: messages.filter { $0.role == .user || $0.role == .assistant }.count,
            toolCallCount: messages.filter { $0.role == .tool }.count,
            lastActivity: messages.last(where: { !$0.role.isNote })?.date,
            lastError: run == nil ? lastError : nil,
            activity: run?.activity ?? reaction ?? (phase == .failed ? .failed : .idle))
    }

    /// A compact elapsed timer, clamped at zero if the clock moves backwards.
    public static func formatElapsed(from start: Date, to now: Date = Date()) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// The bot as its sidebar row shows it: its Home's status, but while Home is idle and
    /// tasks work, working on them, with the newest turn's activity.
    public func working(on tasks: [(title: String, run: RunState)]) -> BotStatus {
        guard !phase.isActive, let newest = tasks.max(by: { $0.run.startedAt < $1.run.startedAt }) else { return self }
        var status = self
        status.phase = newest.run.preparing ? .preparing : newest.run.hasOutput ? .working : .starting
        status.runStartedAt = tasks.map(\.run.startedAt).min()
        status.lastError = nil
        status.activity = newest.run.activity
        status.workingOn = tasks.count == 1 ? newest.title : "\(tasks.count) tasks"
        return status
    }
}

extension BotStatus.Phase {
    /// A turn is under way, or about to start.
    public var isActive: Bool { self == .preparing || self == .starting || self == .working }
}

/// A bot's `MEMORY.md` as the status sidebar shows it: what it holds beyond the seeded heading.
public struct MemorySnapshot: Equatable, Sendable {
    public var exists: Bool
    public var modified: Date?
    /// The file's text after the heading and description BotChu seeds it with.
    public var body: String
    /// List items in the body, the usual shape of a saved fact.
    public var entryCount: Int

    public static let missing = MemorySnapshot(exists: false, modified: nil, body: "", entryCount: 0)

    public static func read(bot: Bot, fileManager: FileManager = .default) -> MemorySnapshot {
        let path = (bot.workspace as NSString).appendingPathComponent(BotContext.memoryFile)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .missing }
        let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return parse(text, bot: bot, modified: modified)
    }

    static func parse(_ text: String, bot: Bot, modified: Date?) -> MemorySnapshot {
        let seed = BotContext.seedMemory(bot: bot)
        var body = text.hasPrefix(seed) ? String(text.dropFirst(seed.count)) : text
        // A file whose seed was edited still starts with its own heading.
        if body.hasPrefix("# ") {
            body = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = body.split(separator: "\n").filter { line in
            let trimmed = line.drop(while: { $0 == " " })
            return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
        }.count
        return MemorySnapshot(exists: true, modified: modified, body: body, entryCount: entries)
    }
}
