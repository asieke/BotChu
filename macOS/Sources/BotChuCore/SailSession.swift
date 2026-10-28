import Foundation

/// A Sail conversation as BotChu keeps it: every item sent and received, since each request
/// carries the whole conversation, and the submission still out, if any. The submission is saved
/// before it is sent and again once Sail has named its response, so a run that ends while Sail
/// works (Stop, a quit, a crash) leaves what the next run needs to pick the response up rather
/// than pay for it twice.
public struct SailSession: Codable, Equatable, Sendable {
    public var id: String
    public var items: [SailJSON]
    public var pending: SailPending?
    public var updatedAt: Date

    public init(id: String, items: [SailJSON] = [], pending: SailPending? = nil, updatedAt: Date = Date()) {
        self.id = id
        self.items = items
        self.pending = pending
        self.updatedAt = updatedAt
    }

    /// Function calls at the end of the conversation without an output: the run ended while
    /// running them, or before it could.
    public var unansweredCalls: [SailFunctionCall] {
        var answered = Set<String>()
        var calls: [SailFunctionCall] = []
        for item in items {
            switch item["type"]?.string {
            case "function_call":
                if let id = item["call_id"]?.string, let name = item["name"]?.string {
                    calls.append(SailFunctionCall(callID: id, name: name, arguments: item["arguments"]?.string ?? "{}"))
                }
            case "function_call_output":
                if let id = item["call_id"]?.string { answered.insert(id) }
            default:
                break
            }
        }
        return calls.filter { !answered.contains($0.callID) }
    }
}

/// A submission Sail may be working on.
public struct SailPending: Codable, Equatable, Sendable {
    /// Sent with every attempt of this submission, also from a later run.
    public var idempotencyKey: String
    /// The exact body, so a later run sends the same submission with the same key.
    public var body: SailJSON
    public var model: String
    /// Set once Sail has answered the submission.
    public var responseID: String?
    /// The status last seen (`SailStatus.raw`).
    public var status: String
    public var submittedAt: Date

    public init(idempotencyKey: String, body: SailJSON, model: String, responseID: String? = nil, status: String = "submitting",
                submittedAt: Date = Date()) {
        self.idempotencyKey = idempotencyKey
        self.body = body
        self.model = model
        self.responseID = responseID
        self.status = status
        self.submittedAt = submittedAt
    }
}

/// One file per session, readable only by its owner: conversations stay on this Mac, and no key
/// is ever written.
public struct SailSessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/BotChu/sail/sessions` (on Linux, its XDG equivalent).
    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("BotChu/sail/sessions", isDirectory: true)
    }

    /// Whether `id` can name a session file: letters, digits, `-` and `_` only.
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    public func url(for id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    public func load(_ id: String) throws -> SailSession? {
        guard Self.isValid(id) else { throw SailFailure(.malformed, "“\(id)” isn't a Sail session id BotChu made.") }
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SailSession.self, from: Data(contentsOf: file))
    }

    public func save(_ session: SailSession) throws {
        guard Self.isValid(session.id) else { throw SailFailure(.malformed, "“\(session.id)” isn't a Sail session id BotChu made.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let file = url(for: session.id)
        try encoder.encode(session).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
