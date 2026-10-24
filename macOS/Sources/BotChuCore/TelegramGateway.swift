import Foundation

/// A private Telegram chat allowed to reach BotChu, and the bot whose Home it reaches. Nothing
/// else can: a chat that isn't listed, a group, or a sender who isn't the chat's own user is
/// refused before BotChu reads, says or starts anything.
public struct TelegramChat: Codable, Hashable, Identifiable, Sendable {
    /// The private chat's ID, which is its user's Telegram ID.
    public var id: Int64
    /// The bot whose Home the chat reaches; nil until one is chosen.
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
    /// Text from an allowed chat for its bot's Home (none chosen when nil), under a BotChu message
    /// ID that is the same each time Telegram sends it.
    case message(chat: Int64, botID: UUID?, text: String, replyTo: Int64, id: UUID)
    /// /start or /help: the gateway says where messages go.
    case help(chat: Int64, botID: UUID?, replyTo: Int64)
    /// From an allowed chat, but not something the gateway passes on: it says so.
    case unsupported(chat: Int64, replyTo: Int64, edited: Bool)
    /// Not allowed: nothing is said or done.
    case refused(TelegramRefusal)
    case ignored

    public static func classify(_ update: TelegramUpdate, chats: [TelegramChat], bot: Int64) -> TelegramInbound {
        guard let message = update.message ?? update.editedMessage else { return .ignored }
        let chat = message.chat
        guard chat.type == "private", let sender = message.from, !sender.isBot, sender.id == chat.id,
              let allowed = chats.first(where: { $0.id == chat.id }) else {
            return .refused(TelegramRefusal(message))
        }
        let replyTo = message.messageID
        guard update.message != nil else { return .unsupported(chat: chat.id, replyTo: replyTo, edited: true) }
        guard let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unsupported(chat: chat.id, replyTo: replyTo, edited: false)
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

    /// What the turn that answered a message said: the replies after it up to the owner's next
    /// message, and whether the turn failed or was stopped (never the error's text, which stays in
    /// BotChu). Nil when the message isn't in the thread.
    public static func compose(after id: UUID, in thread: [ChatMessage], botName: String) -> String? {
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
            // Where the text breaks, unless that leaves a short message; a character longer than
            // the limit on its own still goes, alone.
            var cut = [paragraph, line, space].compactMap { $0 }.first { $0.units >= limit / 2 }?.index ?? end
            if cut == rest.startIndex { cut = rest.index(after: cut) }
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

    static func help(botName: String?, chosen: Bool) -> String {
        guard chosen else { return unrouted }
        guard let botName else { return unavailable }
        return "Messages here go to \(botName)'s Home conversation in BotChu, on your Mac, and its replies come back here. Text only. BotChu has to be running (and the Mac awake) for \(botName) to answer; messages sent meanwhile wait up to a day."
    }

    public static let unrouted = "This chat isn't connected to a bot yet. Choose one in BotChu ▸ Settings ▸ Telegram."
    public static let unavailable = "The bot this chat was connected to isn't in BotChu any more. Choose another in BotChu ▸ Settings ▸ Telegram."

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
    case failed(String)
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
            // Written to a running CLI, which takes it at its next tool call.
            if running, queue.isInFlight(id) { return .working }
            return .queued(paused: queue.isPaused)
        }
        return .gone(TelegramReply.withdrawn(botName))
    }
}

/// What the gateway needs from BotChu, which answers from its conversations.
public protocol TelegramApp: Sendable {
    /// The bot's name, or nil when it isn't there any more.
    func name(of botID: UUID) async -> String?
    /// Hands the owner's message to the bot's Home through its queue, under `id`.
    func deliver(_ text: String, id: UUID, to botID: UUID) async -> TelegramDelivery
    func progress(of id: UUID, for botID: UUID) async -> TelegramProgress
    /// A reply couldn't be sent to Telegram: BotChu says so in the conversation.
    func replyFailed(_ id: UUID, for botID: UUID, reason: String) async
    func gatewayChanged(_ status: TelegramGateway.Status) async
    func refused(_ chat: TelegramRefusal) async
}

/// A reply owed to a Telegram message handed to BotChu.
public struct TelegramPendingReply: Codable, Equatable, Sendable {
    /// The BotChu message.
    public var id: UUID
    public var botID: UUID
    public var chat: Int64
    /// The Telegram message it answers.
    public var replyTo: Int64
    /// How many of the reply's messages Telegram has taken: after a relaunch it goes on from the next.
    public var sent: Int

    public init(id: UUID, botID: UUID, chat: Int64, replyTo: Int64, sent: Int = 0) {
        self.id = id
        self.botID = botID
        self.chat = chat
        self.replyTo = replyTo
        self.sent = sent
    }
}

/// What the gateway keeps across relaunches (`telegram.json`, beside `index.json`): where its
/// updates are up to, and the replies it owes. No message text and no token.
public struct TelegramState: Codable, Equatable, Sendable {
    /// The bot the offset belongs to: another token's updates are numbered afresh.
    public var botUserID: Int64?
    /// The next update to ask for: one past the last handled.
    public var offset: Int64?
    public var pending: [TelegramPendingReply]

    public init(botUserID: Int64? = nil, offset: Int64? = nil, pending: [TelegramPendingReply] = []) {
        self.botUserID = botUserID
        self.offset = offset
        self.pending = pending
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
/// allowed chats' text to their bots' Homes, and sends back what each turn said.
///
/// An update counts as handled once what it started is saved: its message in the conversation's
/// queue (under an ID made from it, so a copy Telegram sends again is recognized), the reply it is
/// owed, and the offset past it. Replies go out once their turn ends, at least once: a send that
/// fails for a passing reason is tried again, with waits doubling up to five minutes. One that
/// never reached Telegram (offline) or that Telegram asked to wait with is tried until it goes; one
/// that may have reached it (a timeout, a server error, so it can arrive twice) up to
/// `Timing.sendAttempts` times. One Telegram refuses is reported in the conversation at once.
public actor TelegramGateway {
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
    private var state: TelegramState
    private var me: TelegramUser?
    private var typedAt: [Int64: Date] = [:]
    /// Failed tries at a reply's next message (`attempts` counts those that may have reached
    /// Telegram), and when to try again.
    private var retries: [UUID: (attempts: Int, waits: Int, at: Date)] = [:]
    /// Replies whose chat was told their message waits in a paused queue.
    private var toldPaused: Set<UUID> = []

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
                let error = error as? TelegramError ?? TelegramError(kind: .transient, reason: "The request to Telegram failed.")
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
            } catch let error as TelegramError where error.stopsGateway {
                await app.gatewayChanged(.stopped(reason: error.reason))
                return
            } catch {}
            do { try await sleep(timing.replyInterval) } catch { return }
        }
    }

    /// Asks Telegram which bot the token belongs to.
    @discardableResult
    public func connect() async throws -> TelegramUser {
        let me = try await client.me()
        if state.botUserID != me.id {
            state.botUserID = me.id
            state.offset = nil
            save()
        }
        self.me = me
        return me
    }

    /// Asks Telegram for the updates after the last one handled, and handles them in order.
    public func poll(timeout: Int? = nil) async throws {
        let me: TelegramUser
        if let known = self.me { me = known } else { me = try await connect() }
        let updates = try await client.updates(offset: state.offset, timeout: timeout ?? timing.pollSeconds)
        for update in updates.sorted(by: { $0.updateID < $1.updateID }) where update.updateID >= state.offset ?? .min {
            await handle(update, bot: me.id)
        }
    }

    private func handle(_ update: TelegramUpdate, bot: Int64) async {
        var answer: (chat: Int64, text: String, replyTo: Int64)?
        switch TelegramInbound.classify(update, chats: chats, bot: bot) {
        case .ignored:
            break
        case .refused(let refusal):
            await app.refused(refusal)
        case let .unsupported(chat, replyTo, edited):
            answer = (chat, TelegramReply.unsupported(edited: edited), replyTo)
        case let .help(chat, botID, replyTo):
            var name: String?
            if let botID { name = await app.name(of: botID) }
            answer = (chat, TelegramReply.help(botName: name, chosen: botID != nil), replyTo)
        case let .message(chat, botID, text, replyTo, id):
            guard let botID else {
                answer = (chat, TelegramReply.unrouted, replyTo)
                break
            }
            switch await app.deliver(text, id: id, to: botID) {
            case .queued(let busy):
                expect(TelegramPendingReply(id: id, botID: botID, chat: chat, replyTo: replyTo))
                if busy, let name = await app.name(of: botID) { answer = (chat, TelegramReply.busy(name), replyTo) }
            case .duplicate:
                // Taken before a crash saved the offset: the reply may still be owed.
                expect(TelegramPendingReply(id: id, botID: botID, chat: chat, replyTo: replyTo))
            case .unavailable:
                answer = (chat, TelegramReply.unavailable, replyTo)
            case .failed(let reason):
                answer = (chat, TelegramReply.notTaken(reason), replyTo)
            }
        }
        state.offset = update.updateID + 1
        save()
        // The gateway's own words get one try: they say nothing the conversation needs.
        if let answer { try? await client.send(answer.text, to: answer.chat, replyingTo: answer.replyTo) }
    }

    /// Sends the replies whose turns have ended, and shows "typing…" while a turn is under way.
    public func flushReplies() async throws {
        for pending in state.pending {
            if let retry = retries[pending.id], retry.at > now() { continue }
            switch await app.progress(of: pending.id, for: pending.botID) {
            case .queued(let paused):
                guard paused else {
                    toldPaused.remove(pending.id)
                    continue
                }
                if !toldPaused.contains(pending.id), let name = await app.name(of: pending.botID) {
                    toldPaused.insert(pending.id)
                    try? await client.send(TelegramReply.paused(name), to: pending.chat, replyingTo: pending.replyTo)
                }
            case .working:
                try await showTyping(in: pending.chat)
            case .answered(let text), .gone(let text):
                try await send(text, for: pending)
            }
        }
    }

    private func showTyping(in chat: Int64) async throws {
        if let last = typedAt[chat], now().timeIntervalSince(last) < timing.typingInterval { return }
        typedAt[chat] = now()
        do {
            try await client.typing(in: chat)
        } catch let error as TelegramError where error.stopsGateway {
            throw error
        } catch {}
    }

    private func send(_ text: String, for pending: TelegramPendingReply) async throws {
        let messages = TelegramReply.messages(text)
        var sent = pending.sent
        while sent < messages.count {
            do {
                // The first message replies to the owner's, so it's clear what it answers.
                try await client.send(messages[sent], to: pending.chat, replyingTo: sent == 0 ? pending.replyTo : nil)
            } catch let error as TelegramError {
                if error.stopsGateway { throw error }
                let retry = retries[pending.id] ?? (0, 0, now())
                let attempts = retry.attempts + (error.kind == .transient ? 1 : 0)
                if error.kind == .refused || attempts >= timing.sendAttempts {
                    finish(pending.id)
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
                save()
            }
        }
        finish(pending.id)
    }

    private func expect(_ reply: TelegramPendingReply) {
        guard !state.pending.contains(where: { $0.id == reply.id }) else { return }
        state.pending.append(reply)
    }

    private func finish(_ id: UUID) {
        state.pending.removeAll { $0.id == id }
        retries[id] = nil
        toldPaused.remove(id)
        save()
    }

    /// A state that can't be saved costs no duplicate turn: a message Telegram sends again is
    /// recognized by its ID.
    private func save() {
        try? state.save(to: stateURL)
    }
}
