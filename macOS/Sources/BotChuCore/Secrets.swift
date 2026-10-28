import Foundation

/// `botchu-secret ask` (#266): a turn asks its owner for a key or password, BotChu shows a secure
/// field for it, and the helper puts what the owner pastes where the bot said, never printing it,
/// so it stays out of the conversation. BotChu holds no copy: the value goes into the asking turn's
/// mailbox, which the helper reads and deletes at once.
public struct SecretRequest: Equatable, Sendable {
    public static let kind = "secret"
    /// What the owner can paste: up to 64 KB.
    public static let maxValueBytes = 65_536
    public static let maxDestinations = 8
    /// How long the popup waits for the owner, in seconds, by default and at most.
    public static let defaultWait: TimeInterval = 600
    public static let waitRange: ClosedRange<TimeInterval> = 10...3600

    public var id: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    /// What is asked for: "Stripe sandbox key".
    public var title: String
    /// Why, or where to find it, in the bot's words.
    public var note: String?
    public var destinations: [SecretDestination]
    /// How long the helper waits for the owner; the popup closes then.
    public var wait: TimeInterval

    public init(id: UUID, invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil, parentSubagentID: UUID? = nil,
                title: String, note: String? = nil, destinations: [SecretDestination], wait: TimeInterval = SecretRequest.defaultWait) {
        self.id = id
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID
        self.parentSubagentID = parentSubagentID
        self.title = title
        self.note = note
        self.destinations = destinations
        self.wait = wait
    }

    public static func isRequest(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String == kind
    }

    public static func parse(_ data: Data) throws -> SecretRequest {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["kind"] as? String == kind else {
            throw InboxRequest.Problem("it isn't a request for a secret")
        }
        func uuid(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
        guard let id = uuid("id"), let invocationID = uuid("invocationID"), let callerBotID = uuid("callerBotID") else {
            throw InboxRequest.Problem("it doesn't say which turn asks")
        }
        let title = (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw InboxRequest.Problem("say what you ask for in 1–200 characters (--title)") }
        let note = (object["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note?.count ?? 0) <= 2000 else { throw InboxRequest.Problem("the note must be at most 2000 characters") }
        let destinations = try (object["destinations"] as? [[String: Any]] ?? []).map(SecretDestination.init(json:))
        guard (1...maxDestinations).contains(destinations.count) else {
            throw InboxRequest.Problem("say where it goes: 1–\(maxDestinations) of --env-file, --file and --pipe")
        }
        let wait = (object["wait"] as? NSNumber)?.doubleValue ?? defaultWait
        guard waitRange.contains(wait) else { throw InboxRequest.Problem("--wait must be 10–3600 seconds") }
        return SecretRequest(id: id, invocationID: invocationID, callerBotID: callerBotID, callerTaskID: uuid("callerTaskID"),
                             parentSubagentID: uuid("parentSubagentID"), title: title, note: note?.isEmpty == false ? note : nil,
                             destinations: destinations, wait: wait)
    }

    /// Checks that the request comes from the turn whose mailbox it is in, as BotChu registered it.
    public func validate(_ caller: SubagentCallerContext) throws {
        guard invocationID == caller.invocationID, callerBotID == caller.botID, callerTaskID == caller.taskID,
              parentSubagentID == caller.parentSubagentID else {
            throw InboxRequest.Problem("the asking turn no longer matches this request; ask again from the active turn")
        }
    }

    /// What is saved of what the owner pasted: without the spaces and line breaks around it, which
    /// a copied key often brings along; nil when nothing is left or it is too long.
    public static func cleaned(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > maxValueBytes ? nil : trimmed
    }
}

/// Where the helper puts a secret: a variable in a dotenv file, a file of its own, or a command's
/// standard input (`vercel env add NAME production`, `gh secret set NAME`). Paths are absolute, as
/// the helper resolved them, so the popup shows exactly what is written.
public enum SecretDestination: Equatable, Sendable {
    case env(name: String, path: String)
    case file(path: String)
    case pipe(command: String)

    init(json object: [String: Any]) throws {
        let path = object["path"] as? String ?? ""
        switch object["type"] as? String {
        case "env":
            let name = object["name"] as? String ?? ""
            guard Self.isVariableName(name) else { throw InboxRequest.Problem("--name must be a variable name such as API_KEY") }
            guard path.hasPrefix("/") else { throw InboxRequest.Problem("an --env-file has no absolute path") }
            self = .env(name: name, path: path)
        case "file":
            guard path.hasPrefix("/") else { throw InboxRequest.Problem("a --file has no absolute path") }
            self = .file(path: path)
        case "pipe":
            let command = (object["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, command.count <= 2000 else { throw InboxRequest.Problem("a --pipe command must have 1–2000 characters") }
            self = .pipe(command: command)
        default:
            throw InboxRequest.Problem("a destination is neither --env-file, --file nor --pipe")
        }
    }

    public static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 128 else { return false }
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        return letters.contains(first) && name.unicodeScalars.allSatisfy { letters.contains($0) || ("0"..."9").contains($0) }
    }

    /// The destination as the popup lists it, with the home folder as `~`: `STRIPE_KEY in ~/kids/.env`.
    public func label(home: String = NSHomeDirectory()) -> String {
        func short(_ path: String) -> String {
            path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        switch self {
        case .env(let name, let path): return "\(name) in \(short(path))"
        case .file(let path): return short(path)
        case .pipe(let command): return command
        }
    }
}

/// BotChu's answer to `botchu-secret ask`, written into the asking turn's mailbox: what the owner
/// pasted, or that they cancelled, or why there is no popup. The helper deletes it once read.
public struct SecretResult: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: UUID
    public var kind: String
    public var value: String?
    public var cancelled: Bool?
    public var errorMessage: String?

    public init(id: UUID, value: String) {
        self.id = id
        kind = SecretRequest.kind
        self.value = value
    }

    public init(id: UUID, cancelled: Bool) {
        self.id = id
        kind = SecretRequest.kind
        self.cancelled = cancelled
    }

    public init(id: UUID, errorMessage: String) {
        self.id = id
        kind = SecretRequest.kind
        self.errorMessage = errorMessage
    }

    /// Never the value, so a logged result can't leak it.
    public var description: String {
        "SecretResult(\(id.uuidString.lowercased()), \(value != nil ? "value" : cancelled == true ? "cancelled" : errorMessage ?? "empty"))"
    }

    public var debugDescription: String { description }
}

/// The helper stopped waiting for its answer (interrupted, or killed by its tool's timeout), so the
/// popup it opened closes, and nothing the owner might still paste is written anywhere.
public struct SecretWithdrawal: Equatable, Sendable {
    public static let kind = "secretWithdrawal"

    public var id: UUID
    public var request: UUID
    public var invocationID: UUID

    public init(id: UUID, request: UUID, invocationID: UUID) {
        self.id = id
        self.request = request
        self.invocationID = invocationID
    }

    public static func isWithdrawal(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String == kind
    }

    public static func parse(_ data: Data) throws -> SecretWithdrawal {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["kind"] as? String == kind,
              let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
              let request = (object["request"] as? String).flatMap(UUID.init(uuidString:)),
              let invocationID = (object["invocationID"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw InboxRequest.Problem("it isn't a withdrawn secret request")
        }
        return SecretWithdrawal(id: id, request: request, invocationID: invocationID)
    }
}
