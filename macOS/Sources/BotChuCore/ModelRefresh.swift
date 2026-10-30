import Foundation

/// `botchu-models refresh` (#326): an agent asks BotChu to check model lists now, as Refresh models
/// does in a picker, such as when the owner asks for a model that came out since the day's check.
public struct ModelRefreshRequest: Equatable, Sendable {
    public static let kind = "modelRefresh"

    public var id: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    /// The profiles whose lists to check, by ID (`claude-personal`); none checks every list.
    public var accountIDs: [String]

    public init(id: UUID, invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil, parentSubagentID: UUID? = nil,
                accountIDs: [String] = []) {
        self.id = id
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID
        self.parentSubagentID = parentSubagentID
        self.accountIDs = accountIDs
    }

    public static func isRequest(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String == kind
    }

    public static func parse(_ data: Data) throws -> ModelRefreshRequest {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["kind"] as? String == kind else {
            throw InboxRequest.Problem("it isn't a request to check model lists")
        }
        func uuid(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
        guard let id = uuid("id"), let invocationID = uuid("invocationID"), let callerBotID = uuid("callerBotID") else {
            throw InboxRequest.Problem("it doesn't say which turn asks")
        }
        let accounts = object["accountIDs"] ?? []
        guard let accountIDs = accounts as? [String], accountIDs.count <= 64, accountIDs.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
            throw InboxRequest.Problem("its profiles aren't a list of profile IDs")
        }
        return ModelRefreshRequest(id: id, invocationID: invocationID, callerBotID: callerBotID,
                                   callerTaskID: uuid("callerTaskID"), parentSubagentID: uuid("parentSubagentID"), accountIDs: accountIDs)
    }

    /// Checks that the request comes from the turn whose mailbox it is in, as BotChu registered it.
    public func validate(_ caller: SubagentCallerContext) throws {
        guard invocationID == caller.invocationID, callerBotID == caller.botID, callerTaskID == caller.taskID,
              parentSubagentID == caller.parentSubagentID else {
            throw InboxRequest.Problem("the asking turn no longer matches this request; ask again from the active turn")
        }
    }
}

/// One profile's list after a check, as `botchu-models refresh` prints it.
public struct ModelRefreshEntry: Codable, Equatable, Sendable {
    public var accountID: String
    /// The profile's name, and its host's for a host's list.
    public var name: String
    /// The IDs a picker offers, in its order: the list read, or the starters while none has been.
    public var models: [String]
    /// The picker's footer line (`NativeCatalogStatus.summary`).
    public var status: String
    /// Why the check failed, if it did.
    public var failure: String?

    public init(accountID: String, name: String, models: [String], status: String, failure: String? = nil) {
        self.accountID = accountID
        self.name = name
        self.models = models
        self.status = status
        self.failure = failure
    }

    /// The most model IDs a line names; a provider's list can run to hundreds.
    static let shown = 40

    /// "Claude Personal (claude-personal): Checked just now · 13 models: opus, claude-opus-5-5, …"
    public var line: String {
        let reason = failure.map { " (\($0))" } ?? ""
        let more = models.count > Self.shown ? ", and \(models.count - Self.shown) more" : ""
        return "\(name) (\(accountID)): \(status)\(reason) · \(models.count) model\(models.count == 1 ? "" : "s"): "
            + models.prefix(Self.shown).joined(separator: ", ") + more
    }

    public static func text(_ entries: [ModelRefreshEntry]) -> String {
        let heading = "Checked \(entries.count) model list\(entries.count == 1 ? "" : "s"); every picker set to them shows them now:"
        return ([heading] + entries.map { "- " + $0.line }).joined(separator: "\n")
    }
}

/// BotChu's answer to `botchu-models refresh`, written into the asking turn's mailbox.
public struct ModelRefreshResult: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: String
    public var entries: [ModelRefreshEntry]?
    /// The lists as the command prints them.
    public var text: String?
    public var errorMessage: String?

    public init(id: UUID, entries: [ModelRefreshEntry]) {
        self.id = id
        kind = ModelRefreshRequest.kind
        self.entries = entries
        text = ModelRefreshEntry.text(entries)
    }

    public init(id: UUID, errorMessage: String) {
        self.id = id
        kind = ModelRefreshRequest.kind
        self.errorMessage = errorMessage
    }
}
