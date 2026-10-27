import Foundation

/// A private Telegram chat allowed to reach BotChu, and the bot whose Home it reaches unless it
/// chooses another with `@` (#114). Nothing else can: a chat that isn't listed, a group, or a sender
/// who isn't the chat's own user is refused before BotChu reads, says or starts anything.
public struct TelegramChat: Codable, Hashable, Identifiable, Sendable {
    /// The private chat's ID, which is its user's Telegram ID.
    public var id: Int64
    /// The bot whose Home the chat reaches until it chooses another; nil until one is chosen.
    public var botID: UUID?
    /// Who it is, as Telegram named them when the chat was allowed.
    public var label: String

    public init(id: Int64, botID: UUID? = nil, label: String = "") {
        self.id = id
        self.botID = botID
        self.label = label
    }
}

/// A chat the gateway refused, which Settings shows (in memory only) so the owner can allow their
/// own without looking up its ID.
public struct TelegramRefusal: Equatable, Identifiable, Sendable {
    /// The chat's ID.
    public let id: Int64
    public let name: String
    /// Only a private chat, from its own user, can be allowed.
    public let isPrivate: Bool

    public init(id: Int64, name: String, isPrivate: Bool) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
    }

    init(_ message: TelegramMessage) {
        let chat = message.chat
        let person = [chat.firstName, chat.lastName].compactMap { $0 }.joined(separator: " ")
        var name = "Chat \(chat.id)"
        if let title = chat.title {
            name = title
        } else if !person.isEmpty {
            name = person
            if let username = chat.username { name += " (@\(username))" }
        } else if let username = chat.username {
            name = "@\(username)"
        }
        self.init(id: chat.id, name: name,
                  isPrivate: chat.type == "private" && message.from?.id == chat.id && message.from?.isBot == false)
    }
}

/// What the gateway does with one update.
public enum TelegramInbound: Equatable, Sendable {
    /// Text from an allowed chat whose bot in Settings is `botID` (none chosen when nil), under a
    /// BotChu message ID that is the same each time Telegram sends it. It goes to that bot's Home,
    /// or where its address words and the chat's choices send it (`TelegramAddress`).
    case message(chat: Int64, botID: UUID?, text: String, replyTo: Int64, id: UUID)
    /// A choice from the gateway's own `@`/`#` list, sent through it by the chat (inline mode): it
    /// may only choose a bot or a repository.
    case chosen(chat: Int64, botID: UUID?, text: String, replyTo: Int64)
    /// What an allowed chat's user types after the bot's username in their chat with it.
    case suggest(chat: Int64, botID: UUID?, query: String, id: String)
    /// /start or /help: the gateway says where messages go.
    case help(chat: Int64, botID: UUID?, replyTo: Int64)
    /// One page of the last reply delivered to this chat, without starting another turn.
    case details(chat: Int64, botID: UUID?, page: Int?, replyTo: Int64)
    /// From an allowed chat, but not something the gateway passes on: it says so.
    case unsupported(chat: Int64, replyTo: Int64, edited: Bool)
    case forwarded(chat: Int64, replyTo: Int64)
    /// Not allowed: nothing is said or done.
    case refused(TelegramRefusal)
    case ignored

    public static func classify(_ update: TelegramUpdate, chats: [TelegramChat], bot: Int64) -> TelegramInbound {
        if let query = update.inlineQuery {
            // Typed anywhere else, or by anyone else, it is offered nothing: the lists name the
            // owner's bots and repositories.
            guard query.chatType == "sender", !query.from.isBot, let allowed = chats.first(where: { $0.id == query.from.id }) else {
                return .ignored
            }
            return .suggest(chat: allowed.id, botID: allowed.botID, query: query.query, id: query.id)
        }
        guard let message = update.message ?? update.editedMessage else { return .ignored }
        let chat = message.chat
        guard chat.type == "private", let sender = message.from, !sender.isBot, sender.id == chat.id,
              let allowed = chats.first(where: { $0.id == chat.id }) else {
            return .refused(TelegramRefusal(message))
        }
        let replyTo = message.messageID
        let chosen = message.isViaBot && message.viaBotID == bot
        guard !message.isForwarded, !message.isViaBot || chosen else { return .forwarded(chat: chat.id, replyTo: replyTo) }
        guard update.message != nil else { return .unsupported(chat: chat.id, replyTo: replyTo, edited: true) }
        guard let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unsupported(chat: chat.id, replyTo: replyTo, edited: false)
        }
        if chosen { return .chosen(chat: chat.id, botID: allowed.botID, text: text, replyTo: replyTo) }
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.first?.split(separator: "@").first?.lowercased() == "/details" {
            let page = words.count == 1 ? 1 : words.count == 2 ? Int(words[1]) : nil
            return .details(chat: chat.id, botID: allowed.botID, page: page, replyTo: replyTo)
        }
        if let word = text.split(whereSeparator: \.isWhitespace).first?.split(separator: "@").first,
           ["/start", "/help"].contains(word.lowercased()) {
            return .help(chat: chat.id, botID: allowed.botID, replyTo: replyTo)
        }
        return .message(chat: chat.id, botID: allowed.botID, text: text, replyTo: replyTo,
                        id: messageID(bot: bot, chat: chat.id, message: replyTo))
    }

    /// The BotChu message ID of a Telegram message: the same each time Telegram sends it, so a
    /// conversation can't take it twice, and unlike any other bot's, chat's or message's.
    public static func messageID(bot: Int64, chat: Int64, message: Int64) -> UUID {
        let key = Array("telegram:\(bot):\(chat):\(message)".utf8)
        func hash(_ basis: UInt64) -> UInt64 { key.reduce(basis) { ($0 ^ UInt64($1)) &* 0x100000001b3 } }
        var bytes = withUnsafeBytes(of: hash(0xcbf29ce484222325).bigEndian, Array.init)
            + withUnsafeBytes(of: hash(0x6c62272e07bb0142).bigEndian, Array.init)
        bytes[6] = bytes[6] & 0x0F | 0x80 // version 8: made up, not random
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// What goes back to Telegram: a turn's reply, in messages within Telegram's limit, and the
/// gateway's own words.
public enum TelegramReply {
    /// Telegram's limit for one message, which it counts in UTF-16 code units.
    public static let limit = 4096
    /// A longer reply is cut after this many messages, saying the rest is in BotChu.
    public static let maxMessages = 8

    /// The final answer's useful sentences, caveats and decisions, up to the owner's next message.
    /// Raw errors and tool events never leave BotChu. Nil when the message isn't in the thread.
    public static func compose(after id: UUID, in thread: [ChatMessage], botName: String) -> String? {
        guard let index = thread.lastIndex(where: { $0.id == id }) else { return nil }
        return TelegramPresentation.summary(Array(thread[(index + 1)...].prefix { $0.role != .user }), botName: botName)
    }

    /// Full assistant text for an explicit /details request, and for finishing a multipart reply
    /// already in flight before concise replies were installed. Tools, notes and raw errors stay local.
    public static func full(after id: UUID, in thread: [ChatMessage], botName: String) -> String? {
        guard let index = thread.lastIndex(where: { $0.id == id }) else { return nil }
        let turn = thread[(index + 1)...].prefix { $0.role != .user }
        var parts = turn.filter { $0.role == .assistant }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // A CLI reports errors it recovers from (a reconnect) before its reply: only the last word counts.
        if turn.last(where: { $0.role == .assistant || $0.role == .error })?.role == .error {
            parts.append("⚠️ \(botName) couldn't finish this turn. What went wrong is in BotChu.")
        } else if turn.contains(where: { $0.role == .note && $0.text == "Stopped" }) {
            parts.append("⏹ Stopped in BotChu.")
        } else if parts.isEmpty {
            parts.append("\(botName) finished without a written reply. What it did is in BotChu.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The text in messages Telegram takes: split where a paragraph, line or word ends, never
    /// inside a character, and cut after `max` messages.
    public static func messages(_ text: String, limit: Int = limit, max: Int = maxMessages) -> [String] {
        let pieces = split(text, limit: limit)
        guard pieces.count > max, max > 0 else { return pieces }
        let note = "… The rest of this reply is in BotChu."
        var kept = Array(pieces.prefix(max))
        kept[max - 1] = (split(kept[max - 1], limit: limit - note.utf16.count - 2).first ?? "") + "\n\n" + note
        return kept
    }

    static func split(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var pieces: [String] = []
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while rest.utf16.count > limit {
            var units = 0
            var end = rest.startIndex
            var paragraph: (index: String.Index, units: Int)?
            var line: (index: String.Index, units: Int)?
            var space: (index: String.Index, units: Int)?
            var afterNewline = false
            var index = rest.startIndex
            while index < rest.endIndex {
                let character = rest[index]
                guard units + character.utf16.count <= limit else { break }
                units += character.utf16.count
                index = rest.index(after: index)
                end = index
                if character.isNewline {
                    if afterNewline { paragraph = (index, units) }
                    line = (index, units)
                } else if character.isWhitespace {
                    space = (index, units)
                }
                afterNewline = character.isNewline
            }
            // A single grapheme can exceed Telegram's limit (thousands of combining accents).
            // Replace it with one bounded character rather than losing the entire reply.
            let cut = [paragraph, line, space].compactMap { $0 }.first { $0.units >= limit / 2 }?.index ?? end
            if cut == rest.startIndex {
                pieces.append("�")
                rest = rest.dropFirst()
                continue
            }
            let piece = trimmingTrailingWhitespace(rest[..<cut])
            if !piece.isEmpty { pieces.append(piece) }
            rest = rest[cut...].drop { $0.isNewline }
        }
        let last = trimmingTrailingWhitespace(rest)
        if !last.isEmpty { pieces.append(last) }
        return pieces
    }

    private static func trimmingTrailingWhitespace(_ text: Substring) -> String {
        var text = text
        while text.last?.isWhitespace == true { text.removeLast() }
        return String(text)
    }

    static func help(botName: String?, chosen: Bool, repo: String? = nil) -> String {
        guard chosen else { return unrouted }
        guard let botName else { return unavailable }
        let next = repo.map { " #\($0) goes with your next message." } ?? ""
        return "Messages here go to \(botName)'s Home conversation in BotChu, on your Mac, and concise replies come back here. /details shows the last reply in full, one page at a time. Text only. BotChu has to be running (and the Mac awake) for \(botName) to answer; messages sent meanwhile wait up to a day.\(next)\n\n" + choosing
    }

    /// How a chat chooses (#114).
    static let choosing = "To talk to another bot, start a message with @ and its name: it stays chosen until you choose another. Start with #owner/repo to name a repository for that message, and with /task to make it a task of its own there. With inline mode on, type the bot's @username, then @ or #, to choose from a list."

    public static let unrouted = "This chat isn't connected to a bot yet. Start a message with @ and a bot's name, or choose one in BotChu ▸ Settings ▸ Telegram."
    public static let unavailable = "The bot this chat was connected to isn't in BotChu any more. Choose another in BotChu ▸ Settings ▸ Telegram."
    static let forwarded = "Forwarded messages and messages sent via another bot aren't taken. Write your own text message instead."
    static let tooManyWaiting = "Too many messages are waiting for replies. Wait for a reply, then send this message again."

    static func unsupported(edited: Bool) -> String {
        edited
            ? "Edits don't reach the bot: it has the message as first sent. Send a new message instead."
            : "Only text reaches the bot from Telegram. Send this as a text message, or attach it in BotChu."
    }

    static func busy(_ botName: String) -> String {
        "⏳ \(botName) is in the middle of a turn. Your message is queued and goes to it as soon as it can take it."
    }

    static func paused(_ botName: String) -> String {
        "⏸ \(botName)'s queue is paused in BotChu (after a Stop or a failed turn), so this message waits there. Resume it in BotChu with Send next."
    }

    static func notTaken(_ reason: String) -> String { "BotChu couldn't take this message: \(reason)" }

    public static func withdrawn(_ botName: String) -> String {
        "This message was taken out of \(botName)'s queue in BotChu before it was sent."
    }
}

/// How BotChu took a message handed to a bot's Home.
public enum TelegramDelivery: Equatable, Sendable {
    /// In its queue; `busy` when it waits for a turn under way.
    case queued(busy: Bool)
    /// Already in the conversation or its queue: Telegram sent it again.
    case duplicate
    /// The bot isn't there any more.
    case unavailable
    /// The gateway stopped or this chat no longer reaches that bot. Nothing was handed over.
    case discarded
    case failed(String)
}

public enum TelegramAuthorization: Sendable {
    case allowed
    case revoked
    case stopped
}

/// Where a message handed to a conversation stands.
public enum TelegramProgress: Equatable, Sendable {
    /// Still in its queue; `paused` when the queue waits for the owner.
    case queued(paused: Bool)
    /// Its turn is under way.
    case working
    /// Its turn ended (or the owner's next message closed it): what it said.
    case answered(String)
    /// Neither queued nor in the conversation any more: why, for the chat.
    case gone(String)

    public static func of(_ id: UUID, thread: [ChatMessage], queue: MessageQueue?, running: Bool, botName: String) -> TelegramProgress {
        if let index = thread.lastIndex(where: { $0.id == id }) {
            let closed = thread[(index + 1)...].contains { $0.role == .user }
            if running, !closed { return .working }
            return .answered(TelegramReply.compose(after: id, in: thread, botName: botName) ?? "")
        }
        if let queue, queue.messages.contains(where: { $0.id == id }) {
            // Written to a running CLI, which takes it when its current step ends.
            if running, queue.isInFlight(id) { return .working }
            return .queued(paused: queue.isPaused)
        }
        return .gone(TelegramReply.withdrawn(botName))
    }
}

/// How BotChu took a task asked for from Telegram with `/task` (#114).
public enum TelegramTaskStart: Equatable, Sendable {
    /// Recorded under its bot and starting; `unsaved` says why its record couldn't be saved.
    case started(title: String, unsaved: String?)
    /// Telegram sent the request again: the task it made before.
    case duplicate(title: String)
    case unavailable
    case discarded
    case failed(String)
}

/// What the gateway needs from BotChu, which answers from its conversations.
public protocol TelegramApp: Sendable {
    /// Current settings and gateway generation, checked again at each delivery/send boundary:
    /// whether the chat is still allowed with `botID` as its bot in Settings (`mapped` for work
    /// another bot took).
    func authorization(for chat: Int64, botID: UUID?) async -> TelegramAuthorization
    /// The bot's name, or nil when it isn't there any more.
    func name(of botID: UUID) async -> String?
    /// The bots and repositories `@` and `#` choose from.
    func directory() async -> TelegramDirectory
    /// Hands the owner's message to the bot's Home through its queue, under `id`, with the
    /// repository it names (`references`). `mapped` is the chat's bot in Settings.
    func deliver(_ text: String, references: [MessageReference], id: UUID, to botID: UUID, from chat: Int64,
                 mapped: UUID?) async -> TelegramDelivery
    /// Makes a task of its own for `botID` in `repo`, under the ID `id`, and starts it.
    func startTask(_ brief: String, in repo: String, id: UUID, for botID: UUID, from chat: Int64, mapped: UUID?) async -> TelegramTaskStart
    func progress(of id: UUID, for botID: UUID) async -> TelegramProgress
    /// Full assistant text from this accepted message's turn only, never tool output or raw errors.
    func fullReply(of id: UUID, for botID: UUID) async -> String?
    /// A reply couldn't be sent to Telegram: BotChu says so in the conversation.
    func replyFailed(_ id: UUID, for botID: UUID, reason: String) async
    func gatewayChanged(_ status: TelegramGateway.Status) async
    func refused(_ chat: TelegramRefusal) async
}

/// A reply owed to a Telegram message handed to BotChu.
public struct TelegramPendingReply: Codable, Equatable, Sendable {
    /// The BotChu message.
    public var id: UUID
    /// The bot that took it, whose reply it is.
    public var botID: UUID
    public var chat: Int64
    /// The Telegram message it answers.
    public var replyTo: Int64
    /// How many of the reply's messages Telegram has taken: after a relaunch it goes on from the next.
    public var sent: Int
    /// The chat's bot in Settings when the message was taken: the reply is owed only while Settings
    /// still gives the chat that bot. The same as `botID` unless the chat chose another with `@`.
    public var mapped: UUID?
    /// Zero belongs to the old multipart format. Keep its part offsets meaningful on upgrade.
    public var presentationVersion: Int = 1

    public init(id: UUID, botID: UUID, chat: Int64, replyTo: Int64, sent: Int = 0) {
        self.init(id: id, botID: botID, chat: chat, replyTo: replyTo, sent: sent, mapped: botID)
    }

    public init(id: UUID, botID: UUID, chat: Int64, replyTo: Int64, sent: Int = 0, mapped: UUID?) {
        self.id = id
        self.botID = botID
        self.chat = chat
        self.replyTo = replyTo
        self.sent = sent
        self.mapped = mapped
    }

    enum CodingKeys: String, CodingKey { case id, botID, chat, replyTo, sent, mapped, presentationVersion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        botID = try container.decode(UUID.self, forKey: .botID)
        chat = try container.decode(Int64.self, forKey: .chat)
        replyTo = try container.decode(Int64.self, forKey: .replyTo)
        sent = try container.decode(Int.self, forKey: .sent)
        // Saved before #114, a reply's bot was always the chat's bot in Settings.
        mapped = container.contains(.mapped) ? try container.decodeIfPresent(UUID.self, forKey: .mapped) : botID
        presentationVersion = try container.decodeIfPresent(Int.self, forKey: .presentationVersion) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(botID, forKey: .botID)
        try container.encode(chat, forKey: .chat)
        try container.encode(replyTo, forKey: .replyTo)
        try container.encode(sent, forKey: .sent)
        try container.encode(mapped, forKey: .mapped)
        try container.encode(presentationVersion, forKey: .presentationVersion)
    }
}

/// What the gateway keeps across relaunches (`telegram.json`, beside `index.json`): where its
/// updates are up to, the replies it owes, and what each chat chose with `@` and `#`. No message
/// text and no token.
public struct TelegramState: Codable, Equatable, Sendable {
    /// The Telegram bot the offset, pending replies and choices belong to.
    public var botUserID: Int64?
    /// The next update to ask for: one past the last handled.
    public var offset: Int64?
    public var pending: [TelegramPendingReply]
    public var selections: [TelegramSelection]
    /// The last successfully delivered answer for each allowed chat, IDs only; /details reads Home.
    public var details: [TelegramPendingReply]

    public init(botUserID: Int64? = nil, offset: Int64? = nil, pending: [TelegramPendingReply] = [], selections: [TelegramSelection] = [], details: [TelegramPendingReply] = []) {
        self.botUserID = botUserID
        self.offset = offset
        self.pending = pending
        self.selections = selections
        self.details = details
    }

    enum CodingKeys: String, CodingKey { case botUserID, offset, pending, selections, details }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        botUserID = try container.decodeIfPresent(Int64.self, forKey: .botUserID)
        offset = try container.decodeIfPresent(Int64.self, forKey: .offset)
        pending = try container.decode([TelegramPendingReply].self, forKey: .pending)
        selections = try container.decodeIfPresent([TelegramSelection].self, forKey: .selections) ?? []
        details = try container.decodeIfPresent([TelegramPendingReply].self, forKey: .details) ?? []
    }

    public static func load(from url: URL) -> TelegramState {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TelegramState.self, from: $0) } ?? TelegramState()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The Telegram gateway: it long-polls Telegram (`getUpdates`, so no server or webhook), hands
/// allowed chats' text to their bots' Homes, and sends back what each turn said. A chat can choose
/// another bot with `@`, a repository with `#`, and ask for a task of its own with `/task` (#114),
/// typed or chosen from the lists it answers inline queries with.
///
/// An update counts as handled once what it started is saved: its message in the conversation's
/// queue (under an ID made from it, so a copy Telegram sends again is recognized), the reply it is
/// owed, and the offset past it. Replies go out once their turn ends, at least once: a send that
/// fails for a passing reason is tried again, with waits doubling up to five minutes. One that
/// never reached Telegram (offline) or that Telegram asked to wait with is tried until it goes; one
/// that may have reached it (a timeout, a server error, so it can arrive twice) up to
/// `Timing.sendAttempts` times. One Telegram refuses is reported in the conversation at once.
public actor TelegramGateway {
    public static let pendingLimitPerChat = 10
    public static let pendingLimit = 100
    static let overflowNoticeInterval: Double = 60
    static let saveFailure = "BotChu couldn't save Telegram's progress. Check storage space and permissions."
    /// A local write failure never counts as an uncertain Telegram send or consumes its retries.
    enum CheckpointError: Error { case cannotSave }
    public enum Status: Equatable, Sendable {
        case connecting
        /// The bot's username (or name).
        case connected(String)
        case retrying(reason: String, seconds: Int)
        /// Until the owner changes something: a refused token, or another program reading the bot.
        case stopped(reason: String)
    }

    public struct Timing: Sendable {
        /// How long a `getUpdates` waits for a message.
        public var pollSeconds = 25
        /// How often replies are looked for.
        public var replyInterval: Double = 1
        /// Telegram shows "typing…" for five seconds.
        public var typingInterval: Double = 4.5
        /// Tries at each message of a reply that may have reached Telegram before it is reported
        /// as not sent; tries that can't have reached it aren't counted.
        public var sendAttempts = 6

        public init() {}
        public static let standard = Timing()
    }

    private let client: TelegramClient
    private let chats: [TelegramChat]
    private let app: any TelegramApp
    private let stateURL: URL
    private let timing: Timing
    private let sleep: @Sendable (Double) async throws -> Void
    private let now: @Sendable () -> Date
    private var state: TelegramState { didSet { needsSave = true } }
    private var needsSave = false
    private var me: TelegramUser?
    private var typedAt: [Int64: Date] = [:]
    /// Failed tries at a reply's next message (`attempts` counts those that may have reached
    /// Telegram), and when to try again.
    private var retries: [UUID: (attempts: Int, waits: Int, at: Date)] = [:]
    /// Replies whose chat was told their message waits in a paused queue.
    private var toldPaused: Set<UUID> = []
    private var overflowAt: [Int64: Date] = [:]
    /// Shared by replies, notices and typing, across every chat. Only one outgoing request can
    /// be in flight, so a second request cannot slip past a 429 while its response is awaited.
    private var sending = false
    private var outgoingAfter = Date.distantPast

    public init(token: String, chats: [TelegramChat], app: any TelegramApp, stateURL: URL,
                transport: any TelegramTransport = URLSessionTelegramTransport(), timing: Timing = .standard,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        client = TelegramClient(token: token, transport: transport)
        self.chats = chats
        self.app = app
        self.stateURL = stateURL
        self.timing = timing
        self.sleep = sleep
        self.now = now
        state = TelegramState.load(from: stateURL)
    }

    public var savedState: TelegramState { state }

    /// Seconds to wait after `failures` failures in a row: doubling from `base`, at most `cap`.
    public static func backoff(after failures: Int, base: Double = 1, cap: Double = 60) -> Double {
        min(cap, base * pow(2, Double(min(max(0, failures - 1), 30))))
    }

    /// Polls and replies until cancelled, or until something only the owner can fix stops it.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pollLoop() }
            group.addTask { await self.replyLoop() }
            await group.next()
            group.cancelAll()
        }
    }

    private func pollLoop() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                if me == nil {
                    await app.gatewayChanged(.connecting)
                    let me = try await connect()
                    await app.gatewayChanged(.connected(me.username.map { "@\($0)" } ?? me.firstName))
                }
                // After a failure, a quick look, so the status recovers as soon as Telegram answers.
                try await poll(timeout: failures > 0 ? 0 : timing.pollSeconds)
                if failures > 0, let me {
                    failures = 0
                    await app.gatewayChanged(.connected(me.username.map { "@\($0)" } ?? me.firstName))
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                let error = error as? TelegramError ?? TelegramError(kind: .transient,
                    reason: error is CheckpointError ? Self.saveFailure : "The request to Telegram failed.")
                coolDown(after: error)
                if error.stopsGateway {
                    await app.gatewayChanged(.stopped(reason: error.reason))
                    return
                }
                failures += 1
                let wait = error.retryAfter ?? Self.backoff(after: failures)
                await app.gatewayChanged(.retrying(reason: error.reason, seconds: Int(wait.rounded(.up))))
                do { try await sleep(wait) } catch { return }
            }
        }
    }

    private func replyLoop() async {
        while !Task.isCancelled {
            do {
                try await flushReplies()
            } catch is CancellationError {
                return
            } catch let error as TelegramError where error.stopsGateway {
                await app.gatewayChanged(.stopped(reason: error.reason))
                return
            } catch is CheckpointError {
                await app.gatewayChanged(.retrying(reason: Self.saveFailure, seconds: Int(timing.replyInterval.rounded(.up))))
            } catch {}
            do { try await sleep(timing.replyInterval) } catch { return }
        }
    }

    /// Asks Telegram which bot the token belongs to.
    @discardableResult
    public func connect() async throws -> TelegramUser {
        try Task.checkCancellation()
        let me = try await client.me()
        try Task.checkCancellation()
        if state.botUserID != me.id {
            // Both offsets and reply obligations belong to the Telegram identity, not the token
            // text. Rotating its token preserves them; switching to another bot discards them.
            state = TelegramState(botUserID: me.id)
            retries.removeAll()
            toldPaused.removeAll()
            typedAt.removeAll()
        }
        // A chat removed, or given another bot in Settings, sets aside what it chose.
        let chats = chats
        if state.selections.contains(where: { choice in !chats.contains { $0.id == choice.chat && $0.botID == choice.mapped } }) {
            state.selections.removeAll { choice in !chats.contains { $0.id == choice.chat && $0.botID == choice.mapped } }
        }
        state.details.removeAll { reply in !chats.contains { $0.id == reply.chat && $0.botID == reply.mapped } }
        try save()
        self.me = me
        return me
    }

    /// Asks Telegram for the updates after the last one handled, and handles them in order.
    public func poll(timeout: Int? = nil) async throws {
        try Task.checkCancellation()
        let me: TelegramUser
        if let known = self.me { me = known } else { me = try await connect() }
        // getUpdates with a higher offset acknowledges earlier updates at Telegram. Never make
        // that request until the reply obligations and offset are durably saved.
        try save()
        try Task.checkCancellation()
        let updates = try await client.updates(offset: state.offset, timeout: timeout ?? timing.pollSeconds)
        for update in updates.sorted(by: { $0.updateID < $1.updateID }) where update.updateID >= state.offset ?? .min {
            try Task.checkCancellation()
            try await handle(update, me: me)
        }
    }

    private func handle(_ update: TelegramUpdate, me: TelegramUser) async throws {
        try Task.checkCancellation()
        try save()
        var answer: (chat: Int64, text: String, replyTo: Int64)?
        var suggestions: (query: String, chat: Int64, items: TelegramSuggestions)?
        switch TelegramInbound.classify(update, chats: chats, bot: me.id) {
        case .ignored:
            break
        case .refused(let refusal):
            await app.refused(refusal)
        case let .unsupported(chat, replyTo, edited):
            answer = (chat, TelegramReply.unsupported(edited: edited), replyTo)
        case let .forwarded(chat, replyTo):
            answer = (chat, TelegramReply.forwarded, replyTo)
        case let .help(chat, botID, replyTo):
            guard try await authorized(chat, botID: botID) else { break }
            let choice = selection(for: chat, mapped: botID)
            var name: String?
            if let recipient = choice.recipient { name = await app.name(of: recipient) }
            answer = (chat, choice.botID != nil && name == nil ? TelegramReply.chosenGone(choice.botName)
                : TelegramReply.help(botName: name, chosen: choice.recipient != nil, repo: choice.repo), replyTo)
        case let .details(chat, botID, page, replyTo):
            guard try await authorized(chat, botID: botID) else { break }
            answer = (chat, await details(for: chat, mapped: botID, page: page), replyTo)
        case let .suggest(chat, botID, query, id):
            guard try await authorized(chat, botID: botID) else { break }
            let directory = await app.directory()
            try Task.checkCancellation()
            suggestions = (id, chat, TelegramSuggestions.answer(query, in: directory, username: me.username,
                                                                current: selection(for: chat, mapped: botID).recipient))
        case let .chosen(chat, botID, text, replyTo):
            guard try await authorized(chat, botID: botID) else { break }
            // An ID no message of the chat's can have: a choice never reaches a conversation.
            let routed = try await route(text, chat: chat, mapped: botID, replyTo: replyTo, id: UUID(), chosen: true, username: me.username)
            if let choice = routed.selection { choose(choice) }
            answer = routed.answer.map { (chat, $0, replyTo) }
        case let .message(chat, botID, text, replyTo, id):
            guard try await authorized(chat, botID: botID) else { break }
            let routed = try await route(text, chat: chat, mapped: botID, replyTo: replyTo, id: id, chosen: false, username: me.username)
            if let choice = routed.selection { choose(choice) }
            answer = routed.answer.map { (chat, $0, replyTo) }
        }
        // A delivery already accepted before cancellation must still be checkpointed; the next
        // update and any outgoing notice below must not run after cancellation.
        state.offset = update.updateID + 1
        try save()
        try Task.checkCancellation()
        // The gateway's own words get one try: they say nothing the conversation needs.
        if let answer {
            _ = try await notice(answer.text, chat: answer.chat, botID: chats.first { $0.id == answer.chat }?.botID,
                                 replyTo: answer.replyTo)
        }
        if let suggestions {
            try await suggest(suggestions.items, for: suggestions.query, chat: suggestions.chat,
                              botID: chats.first { $0.id == suggestions.chat }?.botID)
        }
    }

    private func details(for chat: Int64, mapped: UUID?, page: Int?) async -> String {
        guard let page, page > 0 else { return "Use /details or /details 2 for a page of the last reply." }
        guard let reply = state.details.last(where: { $0.chat == chat && $0.mapped == mapped }) else {
            return "No delivered reply is available yet. Ask a bot something first."
        }
        guard let text = await app.fullReply(of: reply.id, for: reply.botID), let name = await app.name(of: reply.botID) else {
            return "That reply is no longer available. Check the bot's Home in BotChu."
        }
        let pages = TelegramReply.split(TelegramPresentation.plainText(text), limit: 3_500)
        guard page <= pages.count else { return "That reply has \(pages.count) page(s). Use /details to start at page 1." }
        // A bot's name is user-editable. Bound it so even pathological names cannot split a page.
        let heading = TelegramPresentation.displayName(name) + " — reply details (\(page)/\(pages.count))"
        let next = page < pages.count ? "\n\nNext: /details \(page + 1)" : ""
        return heading + "\n\n" + pages[page - 1] + next
    }

    /// Where an allowed chat's text goes (#114), and what the chat chooses with it: the answer for
    /// the chat, and the chat's choices to keep once the update is checkpointed (nil when they don't
    /// change). Address words that name no bot or repository send nothing, and a message for a
    /// chosen bot that isn't there any more goes nowhere else. A `chosen` message, from the
    /// gateway's own list, may only choose.
    private func route(_ text: String, chat: Int64, mapped: UUID?, replyTo: Int64, id: UUID, chosen: Bool,
                       username: String?) async throws -> (answer: String?, selection: TelegramSelection?) {
        var choice = selection(for: chat, mapped: mapped)
        var address = TelegramAddress(body: text)
        var directory = TelegramDirectory()
        if chosen || choice.repo != nil || TelegramAddress.mayAddress(text) {
            directory = await app.directory()
            try Task.checkCancellation()
            switch TelegramAddress.parse(text, in: directory, username: username) {
            case .success(let parsed): address = parsed
            case .failure(let problem): return (problem.message, nil)
            }
        }
        if chosen, !address.isSelection { return (TelegramReply.forwarded, nil) }
        if let bot = address.bot {
            choice.botID = bot.id
            choice.botName = bot.name
        }
        if address.isSelection {
            if let repo = address.repo { choice.repo = repo }
            var recipient: String?
            if let botID = choice.recipient { recipient = await app.name(of: botID) }
            let bot = address.bot.map { bot in
                String(directory.word(for: bot).dropFirst()) + (bot.title.isEmpty ? "" : " (\(bot.title))")
            }
            return (TelegramReply.selected(bot: bot, repo: address.repo, recipient: recipient), choice)
        }
        guard let botID = choice.recipient else { return (TelegramReply.unrouted, nil) }
        let unavailable = choice.botID == nil ? TelegramReply.unavailable : TelegramReply.chosenUnavailable(choice.botName)
        // A repository goes with one message: this one's, else the one the chat chose for it.
        let repo = address.repo ?? choice.repo
        choice.repo = nil
        if address.isTask {
            guard let repo else { return (TelegramReply.taskNeedsRepository, nil) }
            guard !address.body.isEmpty else { return (TelegramReply.taskNeedsBrief, nil) }
            try Task.checkCancellation()
            switch await app.startTask(address.body, in: repo, id: id, for: botID, from: chat, mapped: mapped) {
            case .started(let title, let unsaved):
                let name = await app.name(of: botID) ?? choice.botName ?? "its bot"
                return ([TelegramReply.taskStarted(title, bot: name, repo: repo), unsaved].compactMap { $0 }.joined(separator: " "), choice)
            case .duplicate(let title):
                return (TelegramReply.taskAlreadyStarted(title), choice)
            case .unavailable:
                return (unavailable, nil)
            case .failed(let reason):
                return (TelegramReply.taskNotStarted(reason), nil)
            case .discarded:
                throw CancellationError()
            }
        }
        guard !address.body.isEmpty else { return (TelegramReply.nothingToSend, nil) }
        if !state.pending.contains(where: { $0.id == id }),
           state.pending.count >= Self.pendingLimit || state.pending.filter({ $0.chat == chat }).count >= Self.pendingLimitPerChat {
            if overflowAt[chat].map({ now().timeIntervalSince($0) >= Self.overflowNoticeInterval }) ?? true {
                overflowAt[chat] = now()
                return (TelegramReply.tooManyWaiting, nil)
            }
            return (nil, nil)
        }
        var body = address.body
        var references: [MessageReference] = []
        if let repo {
            let reference = directory.reference(to: repo)
            body = reference.label + " " + body
            references = [reference]
        }
        try Task.checkCancellation()
        switch await app.deliver(body, references: references, id: id, to: botID, from: chat, mapped: mapped) {
        case .queued(let busy):
            expect(TelegramPendingReply(id: id, botID: botID, chat: chat, replyTo: replyTo, mapped: mapped))
            var answer: String?
            if busy, let name = await app.name(of: botID) { answer = TelegramReply.busy(name) }
            return (answer, choice)
        case .duplicate:
            // Taken before a crash saved the offset: the reply may still be owed.
            expect(TelegramPendingReply(id: id, botID: botID, chat: chat, replyTo: replyTo, mapped: mapped))
            return (nil, choice)
        case .unavailable:
            return (unavailable, nil)
        case .failed(let reason):
            return (TelegramReply.notTaken(reason), nil)
        case .discarded:
            throw CancellationError()
        }
    }

    /// What the chat chose, while Settings gives it the bot it had then.
    private func selection(for chat: Int64, mapped: UUID?) -> TelegramSelection {
        state.selections.first { $0.chat == chat && $0.mapped == mapped } ?? TelegramSelection(chat: chat, mapped: mapped)
    }

    private func choose(_ choice: TelegramSelection) {
        var selections = state.selections.filter { $0.chat != choice.chat }
        if !choice.isEmpty { selections.append(choice) }
        if selections != state.selections { state.selections = selections }
    }

    /// Sends the replies whose turns have ended, and shows "typing…" while a turn is under way.
    public func flushReplies() async throws {
        try Task.checkCancellation()
        // Startup cannot send saved replies until getMe establishes which Telegram bot owns them.
        guard me != nil else { return }
        try save()
        for pending in state.pending {
            guard try await authorized(pending.chat, botID: pending.mapped) else {
                try finish(pending.id)
                continue
            }
            if let retry = retries[pending.id], retry.at > now() { continue }
            let progress = await app.progress(of: pending.id, for: pending.botID)
            guard try await authorized(pending.chat, botID: pending.mapped) else {
                try finish(pending.id)
                continue
            }
            switch progress {
            case .queued(let paused):
                guard paused else {
                    toldPaused.remove(pending.id)
                    continue
                }
                if !toldPaused.contains(pending.id), let name = await app.name(of: pending.botID) {
                    if try await notice(TelegramReply.paused(name), chat: pending.chat, botID: pending.mapped, replyTo: pending.replyTo) {
                        toldPaused.insert(pending.id)
                    }
                }
            case .working:
                try await showTyping(for: pending)
            case .answered(let text):
                // Upgrade an unsent obligation before its first send, so a crash after that
                // send cannot resume a new digest using the old multipart answer's offsets.
                if pending.presentationVersion == 0, pending.sent == 0,
                   let i = state.pending.firstIndex(where: { $0.id == pending.id }) {
                    state.pending[i].presentationVersion = 1
                    try save()
                }
                // A bot the chat chose with @ says who it is: the chat's own bot in Settings doesn't.
                var reply = text
                let legacy = pending.presentationVersion == 0 && pending.sent > 0
                if legacy, let full = await app.fullReply(of: pending.id, for: pending.botID) { reply = full }
                if pending.botID != pending.mapped, let name = await app.name(of: pending.botID) {
                    reply = "\(legacy ? name : TelegramPresentation.displayName(name)):\n" + reply
                }
                try await send(reply, for: pending, keepDetails: true)
            case .gone(let text):
                try await send(text, for: pending)
            }
        }
    }

    private func showTyping(for pending: TelegramPendingReply) async throws {
        if let last = typedAt[pending.chat], now().timeIntervalSince(last) < timing.typingInterval { return }
        do {
            if try await outgoing(nil, chat: pending.chat, botID: pending.mapped) { typedAt[pending.chat] = now() }
        } catch let error as TelegramError where !error.stopsGateway {}
    }

    private func send(_ text: String, for pending: TelegramPendingReply, keepDetails: Bool = false) async throws {
        let messages = TelegramReply.messages(text)
        var sent = pending.sent
        while sent < messages.count {
            guard try await authorized(pending.chat, botID: pending.mapped) else {
                try finish(pending.id)
                return
            }
            try save()
            do {
                // The first message replies to the owner's, so it's clear what it answers.
                guard try await outgoing(messages[sent], chat: pending.chat, botID: pending.mapped,
                                         replyTo: sent == 0 ? pending.replyTo : nil) else { return }
            } catch let error as TelegramError {
                if error.stopsGateway { throw error }
                let retry = retries[pending.id] ?? (0, 0, now())
                let attempts = retry.attempts + (error.kind == .transient ? 1 : 0)
                if error.kind == .refused || attempts >= timing.sendAttempts {
                    try finish(pending.id)
                    try Task.checkCancellation()
                    await app.replyFailed(pending.id, for: pending.botID, reason: error.kind == .refused
                        ? error.reason : "Telegram didn't take it after \(attempts) tries. \(error.reason)")
                } else {
                    let wait = error.retryAfter ?? Self.backoff(after: retry.waits + 1, base: 5, cap: 300)
                    retries[pending.id] = (attempts, retry.waits + 1, now().addingTimeInterval(wait))
                }
                return
            }
            sent += 1
            retries[pending.id] = nil
            if let i = state.pending.firstIndex(where: { $0.id == pending.id }) {
                state.pending[i].sent = sent
                try save()
            }
        }
        if keepDetails {
            state.details.removeAll { $0.chat == pending.chat }
            state.details.append(pending)
        }
        try finish(pending.id)
    }

    /// Current mapping as well as the gateway's snapshot: revoked replies are discarded, while
    /// stopping a gateway preserves valid replies for the next run.
    private func authorized(_ chat: Int64, botID: UUID?) async throws -> Bool {
        try Task.checkCancellation()
        guard let allowed = chats.first(where: { $0.id == chat }), allowed.botID == botID else { return false }
        let authorization = await app.authorization(for: chat, botID: botID)
        try Task.checkCancellation()
        switch authorization {
        case .allowed: return true
        case .revoked: return false
        case .stopped: throw CancellationError()
        }
    }

    /// Nil text means typing. Notices are best effort; replies remain pending when another
    /// request is in flight or Telegram's shared cooldown has not expired.
    private func outgoing(_ text: String?, chat: Int64, botID: UUID?, replyTo: Int64? = nil) async throws -> Bool {
        guard try await authorized(chat, botID: botID), !sending, now() >= outgoingAfter else { return false }
        try save()
        sending = true
        defer { sending = false }
        do {
            if let text {
                try await client.send(text, to: chat, replyingTo: replyTo)
            } else {
                try await client.typing(in: chat)
            }
            return true
        } catch let error as TelegramError {
            coolDown(after: error)
            throw error
        }
    }

    /// The answer to an inline query: best effort, like a notice, since the owner's next keystroke
    /// asks again.
    private func suggest(_ suggestions: TelegramSuggestions, for query: String, chat: Int64, botID: UUID?) async throws {
        guard try await authorized(chat, botID: botID), !sending, now() >= outgoingAfter else { return }
        try save()
        sending = true
        defer { sending = false }
        do {
            try await client.answer(query, with: suggestions)
        } catch let error as TelegramError {
            coolDown(after: error)
            if error.stopsGateway { throw error }
        }
    }

    private func notice(_ text: String, chat: Int64, botID: UUID?, replyTo: Int64) async throws -> Bool {
        do {
            for part in TelegramReply.messages(text) {
                guard try await outgoing(part, chat: chat, botID: botID, replyTo: replyTo) else { return false }
            }
            return true
        } catch let error as TelegramError where !error.stopsGateway {
            return false
        }
    }

    private func coolDown(after error: TelegramError) {
        if let wait = error.retryAfter { outgoingAfter = max(outgoingAfter, now().addingTimeInterval(wait)) }
    }

    private func expect(_ reply: TelegramPendingReply) {
        guard !state.pending.contains(where: { $0.id == reply.id }) else { return }
        state.pending.append(reply)
    }

    private func finish(_ id: UUID) throws {
        state.pending.removeAll { $0.id == id }
        retries[id] = nil
        toldPaused.remove(id)
        try save()
    }

    /// Keep unsaved progress in memory and retry before polling or sending anything else. Never
    /// expose filesystem errors (which may contain paths) in status or conversation text.
    private func save() throws {
        guard needsSave else { return }
        do {
            try state.save(to: stateURL)
            needsSave = false
        } catch {
            throw CheckpointError.cannotSave
        }
    }
}
