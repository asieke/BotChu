import Foundation

/// Work one conversation hands to a bot with `botchu-task create` (#111), as it reaches BotChu
/// through the conversation's mailbox, beside its sub-agent requests. Unlike a sub-agent run
/// (`SubagentRequest`), it goes on whatever becomes of the conversation that asked for it: as a turn
/// in the repository's Project Area (`AreaPost`), or, for a repository on another computer, as an
/// independent Task of that bot's there.
public struct TaskHandoff: Equatable, Sendable {
    /// The `kind` that tells a handoff from a sub-agent request in the mailbox.
    public static let kind = "task"

    public var id: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    /// The Task asked for, as a dispatch file asks for it, with `agent` naming the bot that gets it.
    public var request: TaskRequest

    public init(id: UUID = UUID(), invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil,
                parentSubagentID: UUID? = nil, request: TaskRequest) {
        self.id = id
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID
        self.parentSubagentID = parentSubagentID
        self.request = request
    }

    /// Whether a mailbox request asks for a Task rather than a sub-agent run.
    public static func isHandoff(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String == kind
    }

    /// Reads a handoff: the caller's identifiers, and under `task` the fields of a dispatch file.
    public static func parse(_ data: Data) throws -> TaskHandoff {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["kind"] as? String == kind else {
            throw TaskRequest.Problem(message: "it isn't a task request")
        }
        func uuid(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
        guard let id = uuid("id"), let invocationID = uuid("invocationID"), let callerBotID = uuid("callerBotID"),
              let fields = object["task"] as? [String: Any] else {
            throw TaskRequest.Problem(message: "it doesn't say which turn asked for the task")
        }
        let request = try TaskRequest.parse(JSONSerialization.data(withJSONObject: fields))
        guard request.agent != nil else { throw TaskRequest.Problem(message: "name the bot that gets the task (--agent)") }
        guard request.task.count <= SubagentLimits.maxBriefCharacters else {
            throw TaskRequest.Problem(message: "the brief is longer than \(SubagentLimits.maxBriefCharacters) characters")
        }
        return TaskHandoff(id: id, invocationID: invocationID, callerBotID: callerBotID, callerTaskID: uuid("callerTaskID"),
                           parentSubagentID: uuid("parentSubagentID"), request: request)
    }

    /// Checks that the handoff comes from the turn whose mailbox it is in, as BotChu registered it.
    public func validate(_ caller: SubagentCallerContext) throws {
        guard invocationID == caller.invocationID, callerBotID == caller.botID, callerTaskID == caller.taskID,
              parentSubagentID == caller.parentSubagentID else {
            throw TaskRequest.Problem(message: "the calling turn no longer matches this request; ask again from the active turn")
        }
    }

    /// What makes the same handoff, asked for again from the same conversation (after a timeout or
    /// a lost answer, in this turn or a later one), recognizable: the conversation, the bot it goes
    /// to and everything it asks for. A sub-agent working in the conversation asks as it does.
    public func key(for targetBotID: UUID) -> String {
        let fields: [String] = [
            callerBotID.uuidString, callerTaskID?.uuidString ?? "home", targetBotID.uuidString,
            request.repo.lowercased(), request.issue.map(String.init) ?? "", request.pullRequest.map(String.init) ?? "",
            request.review?.rawValue ?? "", request.branch ?? "", request.title ?? "", request.machine?.lowercased() ?? "",
            request.task.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        // FNV-1a, 64 bits: stable across launches, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in fields.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// How a handoff is going, as BotChu writes it into the caller's mailbox
/// (`results/<request id>.result.json`), again whenever it changes. `botchu-task create` prints it.
public struct TaskHandoffResult: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// BotChu has the request and is making the Task.
        case pending
        /// The Task is recorded under its bot; its first turn is on its way (its worktree being made).
        case created
        /// The Task's first turn has started.
        case started
        /// The Task is recorded, but its first turn couldn't start: `errorMessage` says why.
        case startFailed
        /// No Task was made, and asking again is safe: `errorMessage` says why.
        case failed
    }

    public var id: UUID
    public var kind: String
    public var phase: Phase
    public var targetBotID: UUID?
    public var targetBotName: String?
    public var taskID: UUID?
    public var taskTitle: String?
    /// The Task the same request made before (`TaskHandoff.key`), rather than a new one.
    public var existing: Bool
    /// For a failed request: `taskID` is the open Task, of `targetBotID`, already working on what
    /// was asked (its pull request's branch), to continue in instead; no Task was made (#215).
    public var alreadyWorking: Bool
    /// The request was posted as a turn in a Project Area (#399): `taskID` and `taskTitle` are the
    /// area's, of `targetBotID`, and `started` means that turn started. Nil for a Task.
    public var area: Bool?
    public var errorMessage: String?
    public var updatedAt: Date

    public init(id: UUID, phase: Phase, targetBotID: UUID? = nil, targetBotName: String? = nil, taskID: UUID? = nil,
                taskTitle: String? = nil, existing: Bool = false, alreadyWorking: Bool = false, area: Bool = false,
                errorMessage: String? = nil, updatedAt: Date = Date()) {
        self.id = id
        kind = TaskHandoff.kind
        self.phase = phase
        self.targetBotID = targetBotID
        self.targetBotName = targetBotName
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.existing = existing
        self.alreadyWorking = alreadyWorking
        self.area = area ? true : nil
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    /// The same result with its Task's start as it turned out: nil for started, else why not.
    public func starting(failure: String?) -> TaskHandoffResult {
        var next = self
        next.phase = failure == nil ? .started : .startFailed
        next.errorMessage = failure
        next.updatedAt = Date()
        return next
    }
}
