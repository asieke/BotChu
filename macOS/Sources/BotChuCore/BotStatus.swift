import Foundation

/// A turn in progress: when it started and whether its CLI has printed anything yet.
public struct RunState: Equatable, Sendable {
    public var startedAt: Date
    public var hasOutput: Bool

    public init(startedAt: Date = Date(), hasOutput: Bool = false) {
        self.startedAt = startedAt
        self.hasOutput = hasOutput
    }
}

/// What the status sidebar shows about a bot, derived from the bot, its thread and its run.
public struct BotStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
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

    public static func make(bot: Bot, messages: [ChatMessage], run: RunState?) -> BotStatus {
        let lastError: String? = {
            guard let last = messages.last(where: { $0.role != .note }), last.role == .error else { return nil }
            return last.text
        }()
        let phase: Phase
        if let run {
            phase = run.hasOutput ? .working : .starting
        } else {
            phase = lastError == nil ? .idle : .failed
        }
        let session: Session
        if let id = bot.resumableSessionID {
            session = .continuing(id: id)
        } else {
            session = .startsNew(accountChanged: bot.sessionID != nil && bot.sessionAccountID != bot.accountID)
        }
        return BotStatus(
            phase: phase,
            runStartedAt: run?.startedAt,
            session: session,
            messageCount: messages.filter { $0.role == .user || $0.role == .assistant }.count,
            toolCallCount: messages.filter { $0.role == .tool }.count,
            lastActivity: messages.last(where: { $0.role != .note })?.date,
            lastError: run == nil ? lastError : nil)
    }
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
