import Foundation

/// A durable per-bot journal. A completed entry is retained as both the acknowledgement receipt
/// and the source for rebuilding Home after a crash between the journal and transcript saves.
public actor RemoteQueue {
    public static let capacity = 10
    public struct Entry: Codable, Equatable, Sendable {
        public var message: ChatMessage
        public var reply: ChatMessage?
    }
    public struct Snapshot: Sendable {
        public var entries: [Entry]
        public var lastPoll: Date?
        public var pending: Int { entries.filter { $0.reply == nil }.count }
        public var firstPending: ChatMessage? { entries.first { $0.reply == nil }?.message }
        public var messages: [ChatMessage]
        public func online(at now: Date = Date()) -> Bool {
            lastPoll.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 120 } ?? false
        }
    }
    public enum Failure: Error, Equatable {
        case full, emptyText, unknownMessage, invalidReply, wrongBot, invalidJournal
    }
    /// A file a reply brings, before it is saved beside the journal.
    public struct IncomingFile: Sendable {
        public var name: String
        public var type: String?
        public var data: Data
        public init(name: String, type: String? = nil, data: Data) { self.name = name; self.type = type; self.data = data }
    }
    private struct Journal: Codable {
        var botID: UUID
        var entries: [Entry]
        var order: [UUID]
    }
    private let file: URL
    /// Where files are kept: the journal's folder, the bot's `.botchu`.
    private nonisolated let home: BotHome
    private var journal: Journal
    private var lastPoll: Date?

    public init(botID: UUID, file: URL) throws {
        self.file = file
        home = BotHome(url: file.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: file.path) {
            journal = try Store.decoder.decode(Journal.self, from: Data(contentsOf: file))
            guard journal.botID == botID else { throw Failure.wrongBot }
            let ids = journal.entries.flatMap { [$0.message.id] + ($0.reply.map { [$0.id] } ?? []) }
            guard Set(ids).count == ids.count, journal.order.count == ids.count, Set(journal.order) == Set(ids),
                  journal.entries.allSatisfy({ $0.message.role == .user && ($0.reply == nil || $0.reply?.role == .assistant || $0.reply?.role == .error) })
            else { throw Failure.invalidJournal }
        } else {
            journal = Journal(botID: botID, entries: [], order: [])
        }
    }

    public func snapshot() -> Snapshot {
        let messages = Dictionary(uniqueKeysWithValues: journal.entries.flatMap { [$0.message] + ($0.reply.map { [$0] } ?? []) }.map { ($0.id, $0) })
        return Snapshot(entries: journal.entries, lastPoll: lastPoll, messages: journal.order.compactMap { messages[$0] })
    }

    /// Polling and health checks need no copy of the conversation or completed replies.
    public func status() -> (pending: Int, lastPoll: Date?) {
        (journal.entries.lazy.filter { $0.reply == nil }.count, lastPoll)
    }

    /// `files` are already saved in the bot's folder (`BotHome.saveFile`).
    @discardableResult public func enqueue(_ text: String, files: [FileAttachment] = [], id: UUID = UUID(), at date: Date = Date()) throws -> ChatMessage {
        if let existing = journal.entries.first(where: { $0.message.id == id }) { return existing.message }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { throw Failure.emptyText }
        guard journal.entries.filter({ $0.reply == nil }).count < Self.capacity else { throw Failure.full }
        var message = ChatMessage(id: id, role: .user, text: text, date: date)
        message.files = files.isEmpty ? nil : files
        var next = journal
        next.entries.append(Entry(message: message))
        next.order.append(message.id)
        try commit(next)
        return message
    }

    public func next(at now: Date = Date()) -> ChatMessage? {
        lastPoll = now
        return journal.entries.first { $0.reply == nil }?.message
    }

    /// A file of a message still waiting for its reply, and where it is kept; answered messages'
    /// files can't be read through the queue any more.
    public func waitingFile(_ id: UUID) -> (file: FileAttachment, url: URL)? {
        for entry in journal.entries where entry.reply == nil {
            if let file = entry.message.documents.first(where: { $0.id == id }) { return (file, home.fileURL(file)) }
        }
        return nil
    }

    /// The stable reply ID is generated and saved once. Retries with an already-answered request
    /// are no-ops, including a retry whose text differs; the first accepted answer wins.
    /// A reply's files are saved before the journal names them, and removed again if it can't.
    @discardableResult public func reply(to id: UUID, text: String?, error: String?, files: [IncomingFile] = [],
                                         at now: Date = Date()) throws -> Bool {
        guard let i = journal.entries.firstIndex(where: { $0.message.id == id }) else { throw Failure.unknownMessage }
        if journal.entries[i].reply != nil { return false }
        guard (text != nil) != (error != nil), let value = text ?? error,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (error == nil && !files.isEmpty),
              error == nil || files.isEmpty, files.count <= FileAttachment.maximumCount,
              files.allSatisfy({ !$0.data.isEmpty && $0.data.count <= FileAttachment.maximumBytes }) else { throw Failure.invalidReply }
        var saved: [FileAttachment] = []
        do {
            for file in files { saved.append(try home.saveFile(file.data, name: file.name, type: file.type)) }
            var reply = ChatMessage(role: error == nil ? .assistant : .error, text: value, date: now)
            reply.files = saved.isEmpty ? nil : saved
            var next = journal
            next.entries[i].reply = reply
            next.order.append(reply.id)
            try commit(next)
        } catch {
            saved.forEach(home.removeFile)
            throw error
        }
        return true
    }

    private func commit(_ next: Journal) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Store.encoder.encode(next).write(to: file, options: .atomic)
        journal = next
    }
}

public struct RemoteQueueRequest: Sendable {
    public var method: String
    public var path: String
    public var authorization: String?
    public var body: Data
    public init(method: String, path: String, authorization: String? = nil, body: Data = Data()) {
        self.method = method; self.path = path; self.authorization = authorization; self.body = body
    }
}

public struct RemoteQueueResponse: Sendable {
    public var status: Int
    public var body: Data
    public var retryAfter: Int?
    public var contentType = "application/json"
    public init(_ status: Int, body: Data = Data(), retryAfter: Int? = nil) {
        self.status = status; self.body = body; self.retryAfter = retryAfter
    }
    public static func json<T: Encodable>(_ status: Int, _ value: T) -> Self {
        Self(status, body: (try? Store.encoder.encode(value)) ?? Data())
    }
}

/// Authentication precedes routing, queue reads and decoding. Responses never echo credentials,
/// request bodies or file errors. Each endpoint instance binds its token to one bot's journal.
public actor RemoteQueueEndpoint {
    private nonisolated let credential: Credential
    public nonisolated let queue: RemoteQueue
    public init(queue: RemoteQueue, token: String) { self.queue = queue; credential = Credential(token) }
    public nonisolated func replaceToken(_ token: String) { credential.replace(token) }
    public nonisolated func isAuthorized(_ authorization: String?) -> Bool { credential.matches(authorization) }

    public func handle(_ request: RemoteQueueRequest) async -> RemoteQueueResponse {
        // Recheck after the upload, so rotating a token also invalidates partially sent requests.
        guard isAuthorized(request.authorization) else { return .init(401) }
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/queue/next"):
                guard let message = await queue.next() else { return .init(204) }
                let files = message.documents.map { NextFile(id: $0.id, name: $0.name, type: $0.type, size: $0.size) }
                return .json(200, Next(id: message.id, text: message.text, sent_at: message.date, files: files.isEmpty ? nil : files))
            case ("GET", let path) where path.hasPrefix(Self.filesPath):
                guard let id = UUID(uuidString: String(path.dropFirst(Self.filesPath.count))),
                      let found = await queue.waitingFile(id), let data = try? Data(contentsOf: found.url) else { return .init(404) }
                var response = RemoteQueueResponse(200, body: data)
                response.contentType = found.file.type.flatMap(Self.headerSafe) ?? "application/octet-stream"
                return response
            case ("GET", "/v1/health"):
                return .json(200, Health(ok: true, pending: await queue.status().pending))
            case ("POST", "/v1/queue/reply"):
                guard let reply = try? Store.decoder.decode(Reply.self, from: request.body) else { return .init(400) }
                let files = (reply.files ?? []).map { RemoteQueue.IncomingFile(name: $0.name, type: $0.type.flatMap(Self.headerSafe), data: $0.data) }
                try await queue.reply(to: reply.id, text: reply.text, error: reply.error, files: files)
                return .json(200, Accepted(ok: true))
            default: return .init(404)
            }
        } catch RemoteQueue.Failure.unknownMessage { return .init(404) }
        catch RemoteQueue.Failure.invalidReply { return .init(400) }
        catch { return .init(503) }
    }

    /// A waiting message's files are read one at a time, as `<filesPath><file id>`.
    public static let filesPath = "/v1/queue/files/"
    /// A MIME type as a header value: printable ASCII only, so a reply can't add header lines.
    private static func headerSafe(_ type: String) -> String? {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 127 && trimmed.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) ? trimmed : nil
    }
    private struct Next: Encodable { var id: UUID; var text: String; var sent_at: Date; var files: [NextFile]? }
    private struct NextFile: Encodable { var id: UUID; var name: String; var type: String?; var size: Int }
    private struct Reply: Decodable { var id: UUID; var text: String?; var error: String?; var files: [ReplyFile]? }
    /// `data` is base64, as JSON carries bytes.
    private struct ReplyFile: Decodable { var name: String; var type: String?; var data: Data }
    private struct Health: Encodable { var ok: Bool; var pending: Int }
    private struct Accepted: Encodable { var ok: Bool }
    /// Only this small locked value crosses executors synchronously. The transport can reject
    /// headers without waiting behind JSON decoding, journal I/O or the main actor.
    private final class Credential: @unchecked Sendable {
        private let lock = NSLock()
        private var expected: [UInt8]
        init(_ token: String) { expected = token.isEmpty ? [] : Array(("Bearer " + token).utf8) }
        func replace(_ token: String) {
            lock.lock(); defer { lock.unlock() }
            expected = token.isEmpty ? [] : Array(("Bearer " + token).utf8)
        }
        func matches(_ authorization: String?) -> Bool {
            let actual = Array((authorization ?? "").utf8)
            lock.lock(); defer { lock.unlock() }
            guard !expected.isEmpty, actual.count == expected.count else { return false }
            var difference: UInt8 = 0
            for i in actual.indices { difference |= actual[i] ^ expected[i] }
            return difference == 0
        }
    }
}

/// Global admission budget: a reverse proxy makes peer-IP throttling unreliable. Call with a
/// monotonic timestamp; backward clock values never create more capacity.
public struct RemoteQueueRateLimiter: Sendable {
    private let burst: Double
    private let perSecond: Double
    private var available: Double
    private var previous: TimeInterval
    public init(burst: Int = 20, perSecond: Double = 2, now: TimeInterval) {
        self.burst = Double(max(1, burst)); self.perSecond = max(0.01, perSecond)
        available = Double(max(1, burst)); previous = now
    }
    /// Nil admits one request; otherwise the caller should send Retry-After with this value.
    public mutating func admit(at now: TimeInterval) -> Int? {
        available = min(burst, available + max(0, now - previous) * perSecond)
        previous = max(now, previous)
        guard available >= 1 else { return max(1, Int(ceil((1 - available) / perSecond))) }
        available -= 1
        return nil
    }
}

/// A bounded, one-request-per-connection HTTP/1.1 decoder. No chunked transfer or pipelining:
/// pollers send Content-Length, and every response closes the connection.
public struct RemoteQueueHTTP {
    public static let maximumBody = 16 * 1024 * 1024
    public static let maximumHeader = 16 * 1024
    public struct Header: Sendable {
        public var method: String
        public var path: String
        public var authorization: String?
        public var contentLength: Int
        public var byteCount: Int
    }
    public enum HeaderDecode { case incomplete, header(Header), invalid }
    public enum Decode { case incomplete, request(RemoteQueueRequest), invalid }
    /// Headers are parsed once, before any body read or allocation is authorized.
    public static func decodeHeader(_ data: Data) -> HeaderDecode {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: delimiter) else { return data.count >= maximumHeader ? .invalid : .incomplete }
        guard boundary.upperBound <= maximumHeader, let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, !first[0].isEmpty, first[1].hasPrefix("/"),
              first[0].utf8.allSatisfy(isTokenByte), first[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte), headers[name] == nil,
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 < 127) }) else { return .invalid }
            headers[name] = value.trimmingCharacters(in: .whitespaces)
        }
        let lengthText = headers["content-length"] ?? "0"
        guard headers["transfer-encoding"] == nil,
              !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(lengthText) else { return .invalid }
        return .header(Header(method: String(first[0]), path: String(first[1]), authorization: headers["authorization"],
                              contentLength: length, byteCount: boundary.upperBound))
    }

    public static func decode(_ data: Data) -> Decode {
        let header: Header
        switch decodeHeader(data) {
        case .incomplete: return .incomplete
        case .invalid: return .invalid
        case .header(let value): header = value
        }
        guard header.contentLength <= maximumBody else { return .invalid }
        let end = header.byteCount + header.contentLength
        guard data.count >= end else { return .incomplete }
        return .request(RemoteQueueRequest(method: header.method, path: header.path, authorization: header.authorization,
                                          body: Data(data[header.byteCount..<end])))
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    public static func encode(_ response: RemoteQueueResponse) -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Content Too Large", 429: "Too Many Requests", 503: "Service Unavailable"][response.status] ?? "Error"
        let retry = response.retryAfter.map { "Retry-After: \(max(1, $0))\r\n" } ?? ""
        var data = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nContent-Type: \(response.contentType)\r\nCache-Control: no-store\r\n\(retry)Connection: close\r\n\r\n".utf8)
        data.append(response.body)
        return data
    }
}
