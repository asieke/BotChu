import Foundation

/// What carries the Telegram gateway's requests: an ephemeral URLSession in the app, a stand-in in
/// tests. A request's address holds the bot token, so nothing that carries one is logged, cached on
/// disk or put into an error.
public protocol TelegramTransport: Sendable {
    /// The response's body and HTTP status.
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTelegramTransport: TelegramTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Why a request to Telegram failed, in words safe to show: never the token.
public struct TelegramError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Telegram refused the token: revoked, mistyped, or not a token at all.
        case unauthorized
        /// Another program reads this bot's updates, or the bot has a webhook.
        case conflict
        /// Too many requests: Telegram says how long to wait.
        case rateLimited(seconds: Int)
        /// The request didn't leave this Mac, or didn't reach Telegram: trying again can't send
        /// anything twice.
        case offline
        /// Telegram's servers, a timeout or a dropped connection: worth trying again, though
        /// Telegram may have taken a message it didn't confirm.
        case transient
        /// Telegram won't take this request, such as a message to a chat that blocked the bot.
        case refused
    }

    public let kind: Kind
    public let reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    /// Whether the gateway must stop until the owner changes something.
    public var stopsGateway: Bool { kind == .unauthorized || kind == .conflict }

    /// How long Telegram asked to wait, when it did.
    public var retryAfter: Double? {
        if case .rateLimited(let seconds) = kind { return Double(max(1, seconds)) }
        return nil
    }
}

public struct TelegramUser: Decodable, Equatable, Sendable {
    public let id: Int64
    public let isBot: Bool
    public let firstName: String
    public let lastName: String?
    public let username: String?

    enum CodingKeys: String, CodingKey {
        case id, username
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

public struct TelegramChatInfo: Decodable, Equatable, Sendable {
    public let id: Int64
    /// "private", "group", "supergroup" or "channel".
    public let type: String
    public let title: String?
    public let username: String?
    public let firstName: String?
    public let lastName: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title, username
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

public struct TelegramMessage: Decodable, Equatable, Sendable {
    public let messageID: Int64
    public let from: TelegramUser?
    public let chat: TelegramChatInfo
    /// Nil for anything but a text message: a photo, a file, a voice note, a sticker…
    public let text: String?
    /// Presence is enough to refuse these messages, including unknown origin variants. Never
    /// interpret third-party forwarded or inline-bot content as the owner's instruction.
    public let isForwarded: Bool
    public let isViaBot: Bool
    /// The bot an inline result was sent through, when Telegram says which: the gateway's own bot
    /// for a choice from its `@`/`#` list (#114).
    public let viaBotID: Int64?

    enum CodingKeys: String, CodingKey {
        case from, chat, text
        case messageID = "message_id"
        case forwardOrigin = "forward_origin"
        case forwardFrom = "forward_from", forwardFromChat = "forward_from_chat"
        case forwardFromMessageID = "forward_from_message_id", forwardSignature = "forward_signature"
        case forwardSenderName = "forward_sender_name", forwardDate = "forward_date"
        case isAutomaticForward = "is_automatic_forward", viaBot = "via_bot"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decode(Int64.self, forKey: .messageID)
        from = try container.decodeIfPresent(TelegramUser.self, forKey: .from)
        chat = try container.decode(TelegramChatInfo.self, forKey: .chat)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        isForwarded = [CodingKeys.forwardOrigin, .forwardFrom, .forwardFromChat, .forwardFromMessageID,
                       .forwardSignature, .forwardSenderName, .forwardDate, .isAutomaticForward].contains { container.contains($0) }
        isViaBot = container.contains(.viaBot)
        viaBotID = (try? container.decodeIfPresent(TelegramUser.self, forKey: .viaBot))?.id
    }
}

/// What someone types after the bot's username in a message box (inline mode), sent while they
/// type when the bot has inline mode on in BotFather.
public struct TelegramInlineQuery: Decodable, Equatable, Sendable {
    public let id: String
    public let from: TelegramUser
    /// Up to 256 characters.
    public let query: String
    /// "sender" for the private chat between its sender and this bot; nil when Telegram doesn't say.
    public let chatType: String?

    enum CodingKeys: String, CodingKey {
        case id, from, query
        case chatType = "chat_type"
    }
}

/// One update from `getUpdates`. A message it can't read is left out rather than failing the
/// whole batch, so one odd update can't hold up the ones after it.
public struct TelegramUpdate: Decodable, Equatable, Sendable {
    public let updateID: Int64
    public let message: TelegramMessage?
    public let editedMessage: TelegramMessage?
    public let inlineQuery: TelegramInlineQuery?

    enum CodingKeys: String, CodingKey {
        case message
        case updateID = "update_id"
        case editedMessage = "edited_message"
        case inlineQuery = "inline_query"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updateID = try container.decode(Int64.self, forKey: .updateID)
        message = try? container.decodeIfPresent(TelegramMessage.self, forKey: .message)
        editedMessage = try? container.decodeIfPresent(TelegramMessage.self, forKey: .editedMessage)
        inlineQuery = try? container.decodeIfPresent(TelegramInlineQuery.self, forKey: .inlineQuery)
    }
}

/// The few Bot API methods the gateway uses, as JSON POSTs to `api.telegram.org`.
public struct TelegramClient: Sendable {
    private let token: String
    private let transport: any TelegramTransport

    public init(token: String, transport: any TelegramTransport = URLSessionTelegramTransport()) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    /// Whether it looks like a token from BotFather (the bot's number, a colon, then letters,
    /// digits, `_` and `-`), checked before it goes into an address.
    public static func isPlausibleToken(_ token: String) -> Bool {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts[0].allSatisfy { $0.isASCII && $0.isNumber }
            && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    public func me() async throws -> TelegramUser {
        try await call("getMe", [:], timeout: 30)
    }

    /// The updates from `offset` on, waiting up to `timeout` seconds for one (long polling).
    public func updates(offset: Int64?, timeout: Int) async throws -> [TelegramUpdate] {
        var parameters: [String: Any] = ["timeout": timeout, "allowed_updates": ["message", "edited_message", "inline_query"]]
        if let offset { parameters["offset"] = offset }
        return try await call("getUpdates", parameters, timeout: TimeInterval(timeout + 15))
    }

    /// Sends plain text (no parse mode, so nothing in a reply can break its formatting), without
    /// link previews, as a reply to `message` when given.
    public func send(_ text: String, to chat: Int64, replyingTo message: Int64? = nil) async throws {
        var parameters: [String: Any] = ["chat_id": chat, "text": text, "link_preview_options": ["is_disabled": true]]
        if let message { parameters["reply_parameters"] = ["message_id": message, "allow_sending_without_reply": true] }
        let _: Sent = try await call("sendMessage", parameters, timeout: 30)
    }

    /// Answers an inline query with `suggestions`, as articles whose message is plain text, for its
    /// sender alone and never cached, and a note above them (pressing it sends `/start help`).
    public func answer(_ query: String, with suggestions: TelegramSuggestions) async throws {
        let results: [[String: Any]] = suggestions.items.enumerated().map { index, item in
            var result: [String: Any] = ["type": "article", "id": String(index), "title": item.title,
                                         "input_message_content": ["message_text": item.message, "link_preview_options": ["is_disabled": true]]]
            if !item.description.isEmpty { result["description"] = item.description }
            return result
        }
        var parameters: [String: Any] = ["inline_query_id": query, "results": results, "cache_time": 0, "is_personal": true]
        if let note = suggestions.note { parameters["button"] = ["text": note, "start_parameter": "help"] }
        let _: Bool = try await call("answerInlineQuery", parameters, timeout: 15)
    }

    /// Telegram's "typing…" in the chat, for about five seconds.
    public func typing(in chat: Int64) async throws {
        let _: Bool = try await call("sendChatAction", ["chat_id": chat, "action": "typing"], timeout: 15)
    }

    private struct Sent: Decodable {
        let message_id: Int64
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let ok: Bool
        let result: Value?
        let error_code: Int?
        let description: String?
        let parameters: Parameters?
        struct Parameters: Decodable { let retry_after: Int? }
    }

    private func call<Value: Decodable>(_ method: String, _ parameters: [String: Any], timeout: TimeInterval) async throws -> Value {
        guard Self.isPlausibleToken(token), let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TelegramError(kind: .unauthorized, reason: "The saved bot token isn't one from BotFather. Replace it in Settings.")
        }
        guard let body = try? JSONSerialization.data(withJSONObject: parameters) else {
            throw TelegramError(kind: .refused, reason: "BotChu couldn't write the request.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let status: Int
        do {
            (data, status) = try await transport.send(request)
        } catch let error as URLError {
            // Its description and user info hold the address, and with it the token: only its code is used.
            if error.code == .cancelled { throw CancellationError() }
            throw TelegramError(kind: Self.unreached.contains(error.code) ? .offline : .transient, reason: Self.describe(error.code))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TelegramError(kind: .transient, reason: "The request to Telegram failed.")
        }
        let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data)
        if let envelope, envelope.ok, let result = envelope.result { return result }
        let said = envelope?.description.map(redact) ?? "HTTP status \(status)"
        switch envelope?.error_code ?? status {
        case 401, 404:
            throw TelegramError(kind: .unauthorized, reason: "Telegram refused the bot token (revoked or mistyped: \(said)). Replace it in Settings.")
        case 409:
            throw TelegramError(kind: .conflict, reason: "Another program is reading this bot's messages, or the bot has a webhook (\(said)). Stop it, then turn the gateway on again.")
        case 429:
            let seconds = envelope?.parameters?.retry_after ?? 5
            throw TelegramError(kind: .rateLimited(seconds: seconds), reason: "Telegram asked to slow down.")
        case 400, 403:
            throw TelegramError(kind: .refused, reason: "Telegram refused it: \(said).")
        case 200:
            throw TelegramError(kind: .transient, reason: "Telegram's answer couldn't be read.")
        default:
            throw TelegramError(kind: .transient, reason: "Telegram couldn't answer (\(said)).")
        }
    }

    /// Telegram's own words, minus the token should they ever hold it.
    private func redact(_ text: String) -> String {
        guard !token.isEmpty else { return text }
        var text = text.replacingOccurrences(of: token, with: "…")
        if let secret = token.split(separator: ":").last, secret.count >= 8 { text = text.replacingOccurrences(of: secret, with: "…") }
        return text
    }

    /// Failures before a request reached Telegram.
    static let unreached: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff,
                                                .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost]

    static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            "This Mac is offline."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            "Couldn't reach api.telegram.org."
        case .networkConnectionLost:
            "The connection to Telegram was lost."
        case .timedOut:
            "Telegram didn't answer in time."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            "Couldn't make a secure connection to Telegram."
        default:
            "The request to Telegram failed (error \(code.rawValue))."
        }
    }
}
