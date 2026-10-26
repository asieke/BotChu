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
    private struct Journal: Codable {
        var botID: UUID
        var entries: [Entry]
        var order: [UUID]
    }
    private let file: URL
    private var journal: Journal
    private var lastPoll: Date?

    public init(botID: UUID, file: URL) throws {
        self.file = file
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

    @discardableResult public func enqueue(_ text: String, id: UUID = UUID(), at date: Date = Date()) throws -> ChatMessage {
        if let existing = journal.entries.first(where: { $0.message.id == id }) { return existing.message }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.emptyText }
        guard journal.entries.filter({ $0.reply == nil }).count < Self.capacity else { throw Failure.full }
        let message = ChatMessage(id: id, role: .user, text: text, date: date)
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

    /// The stable reply ID is generated and saved once. Retries with an already-answered request
    /// are no-ops, including a retry whose text differs; the first accepted answer wins.
    @discardableResult public func reply(to id: UUID, text: String?, error: String?, at now: Date = Date()) throws -> Bool {
        guard let i = journal.entries.firstIndex(where: { $0.message.id == id }) else { throw Failure.unknownMessage }
        if journal.entries[i].reply != nil { return false }
        guard (text != nil) != (error != nil), let value = text ?? error,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidReply }
        var next = journal
        next.entries[i].reply = ChatMessage(role: error == nil ? .assistant : .error, text: value, date: now)
        next.order.append(next.entries[i].reply!.id)
        try commit(next)
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
    public init(_ status: Int, body: Data = Data()) { self.status = status; self.body = body }
    public static func json<T: Encodable>(_ status: Int, _ value: T) -> Self {
        Self(status, body: (try? Store.encoder.encode(value)) ?? Data())
    }
}

/// Authentication precedes routing, queue reads and decoding. Responses never echo credentials,
/// request bodies or file errors. Each endpoint instance binds its token to one bot's journal.
public actor RemoteQueueEndpoint {
    private var token: String
    public let queue: RemoteQueue
    public init(queue: RemoteQueue, token: String) { self.queue = queue; self.token = token }
    public func replaceToken(_ token: String) { self.token = token }

    public func handle(_ request: RemoteQueueRequest) async -> RemoteQueueResponse {
        guard !token.isEmpty, Self.matches(request.authorization ?? "", "Bearer " + token) else { return .init(401) }
        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/queue/next"):
                guard let message = await queue.next() else { return .init(204) }
                return .json(200, Next(id: message.id, text: message.text, sent_at: message.date))
            case ("GET", "/v1/health"):
                return .json(200, Health(ok: true, pending: await queue.snapshot().pending))
            case ("POST", "/v1/queue/reply"):
                guard let reply = try? Store.decoder.decode(Reply.self, from: request.body) else { return .init(400) }
                try await queue.reply(to: reply.id, text: reply.text, error: reply.error)
                return .json(200, Accepted(ok: true))
            default: return .init(404)
            }
        } catch RemoteQueue.Failure.unknownMessage { return .init(404) }
        catch RemoteQueue.Failure.invalidReply { return .init(400) }
        catch { return .init(503) }
    }

    private struct Next: Encodable { var id: UUID; var text: String; var sent_at: Date }
    private struct Reply: Decodable { var id: UUID; var text: String?; var error: String? }
    private struct Health: Encodable { var ok: Bool; var pending: Int }
    private struct Accepted: Encodable { var ok: Bool }
    private static func matches(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8), bb = Array(b.utf8)
        guard aa.count == bb.count else { return false }
        var difference: UInt8 = 0
        for i in aa.indices { difference |= aa[i] ^ bb[i] }
        return difference == 0
    }
}

/// A bounded, one-request-per-connection HTTP/1.1 decoder. No chunked transfer or pipelining:
/// pollers send Content-Length, and every response closes the connection.
public struct RemoteQueueHTTP {
    public static let maximumBody = 16 * 1024 * 1024
    public enum Decode { case incomplete, request(RemoteQueueRequest), invalid }
    public static func decode(_ data: Data) -> Decode {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: delimiter) else { return data.count > 16_384 ? .invalid : .incomplete }
        guard boundary.lowerBound <= 16_384, let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { return .invalid }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), (0...maximumBody).contains(length) else { return .invalid }
        let end = boundary.upperBound + length
        guard data.count >= end else { return .incomplete }
        return .request(RemoteQueueRequest(method: String(first[0]), path: String(first[1]), authorization: headers["authorization"],
                                          body: Data(data[boundary.upperBound..<end])))
    }

    public static func encode(_ response: RemoteQueueResponse) -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 503: "Service Unavailable"][response.status] ?? "Error"
        var data = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(response.body)
        return data
    }
}
