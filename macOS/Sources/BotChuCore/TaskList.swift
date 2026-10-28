import Foundation

/// `botchu-task list --mine` (#262): a turn asks BotChu for its own bot's open Tasks, and BotChu
/// answers with them as the bot's Tasks column shows them, in its order, from its live run state.
/// "Mine" is the bot whose turn asks: a sub-agent run's own bot, not the conversation that called it.
public struct TaskListRequest: Equatable, Sendable {
    public static let kind = "taskList"

    public var id: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?

    public init(id: UUID, invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil, parentSubagentID: UUID? = nil) {
        self.id = id
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID
        self.parentSubagentID = parentSubagentID
    }

    public static func isRequest(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String == kind
    }

    public static func parse(_ data: Data) throws -> TaskListRequest {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["kind"] as? String == kind else {
            throw InboxRequest.Problem("it isn't a request for the Tasks list")
        }
        func uuid(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
        guard let id = uuid("id"), let invocationID = uuid("invocationID"), let callerBotID = uuid("callerBotID") else {
            throw InboxRequest.Problem("it doesn't say which turn asks")
        }
        return TaskListRequest(id: id, invocationID: invocationID, callerBotID: callerBotID,
                               callerTaskID: uuid("callerTaskID"), parentSubagentID: uuid("parentSubagentID"))
    }

    /// Checks that the request comes from the turn whose mailbox it is in, as BotChu registered it.
    public func validate(_ caller: SubagentCallerContext) throws {
        guard invocationID == caller.invocationID, callerBotID == caller.botID, callerTaskID == caller.taskID,
              parentSubagentID == caller.parentSubagentID else {
            throw InboxRequest.Problem("the asking turn no longer matches this request; ask again from the active turn")
        }
    }
}

/// One open Task as its row in the Tasks column shows it (`ConversationTab`), with where it works.
public struct TaskListEntry: Codable, Equatable, Sendable {
    public var id: UUID
    /// The row's first line: "BotChu #113", or a job's run's job.
    public var title: String
    /// Its second line: the saved summary, else what it is about.
    public var summary: String
    /// Its state as the row says it: "Idle", "Running a tool…", "Finished · PR #12", "Needs input".
    public var state: String
    /// A turn is under way, or about to start.
    public var running: Bool
    /// The row's time: a running turn's elapsed time ("4:12"), else how long ago it was last active ("2m").
    public var time: String?
    /// When the running turn started, else when it was last active.
    public var since: Date?
    public var repo: String
    /// The issue it works on, unless it works on a pull request.
    public var issue: Int?
    /// The pull request it continues or reviews, else the one it opened.
    public var pullRequest: Int?
    public var review: Bool
    public var branch: String
    /// The host it works on; nil on this Mac.
    public var machine: String?

    public init(task: BotTask, tab: ConversationTab, at now: Date = Date()) {
        id = task.id
        title = tab.title
        summary = tab.label
        state = tab.status
        running = tab.state.kind.isActive
        time = tab.state.time(at: now)
        since = tab.state.since
        repo = task.repo
        let work = task.work
        issue = work.flatMap { $0.isPullRequest ? nil : $0.number }
        pullRequest = work.flatMap { $0.isPullRequest ? $0.number : nil } ?? task.pullRequest
        review = task.review != nil
        branch = task.branch
        machine = tab.machine
    }

    /// The row in one line: `BotChu #113 · Fix the sync · Running a tool… for 4:12 · issue #113 ·
    /// PR #120 · feat/113-fix-sync · on omarchy · <id>`.
    public var line: String {
        let when = time.map { running ? "for \($0)" : $0 == "now" ? "just now" : "\($0) ago" }
        let links = [issue.map { "issue #\($0)" }, pullRequest.map { (review ? "reviews PR #" : "PR #") + "\($0)" }].compactMap { $0 }
        return ([title, summary, [state, when].compactMap { $0 }.joined(separator: " ")] + links
                + [branch.isEmpty ? nil : branch, machine.map { "on \($0)" }, id.uuidString.lowercased()].compactMap { $0 })
            .joined(separator: " · ")
    }

    /// What `botchu-task list --mine` prints: a heading with the count the column's heading shows,
    /// then a row per Task.
    public static func text(botName: String, entries: [TaskListEntry]) -> String {
        guard !entries.isEmpty else { return "\(botName) has no open Tasks." }
        let heading = "\(botName) has \(entries.count) open Task\(entries.count == 1 ? "" : "s"), as BotChu's sidebar lists them:"
        return ([heading] + entries.enumerated().map { "\($0.offset + 1). \($0.element.line)" }).joined(separator: "\n")
    }
}

/// BotChu's answer to `botchu-task list --mine`, written into the asking turn's mailbox.
public struct TaskListResult: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: String
    public var botID: UUID?
    public var botName: String?
    public var tasks: [TaskListEntry]?
    /// The list as the command prints it.
    public var text: String?
    public var errorMessage: String?

    public init(id: UUID, botID: UUID, botName: String, tasks: [TaskListEntry]) {
        self.id = id
        kind = TaskListRequest.kind
        self.botID = botID
        self.botName = botName
        self.tasks = tasks
        text = TaskListEntry.text(botName: botName, entries: tasks)
    }

    public init(id: UUID, errorMessage: String) {
        self.id = id
        kind = TaskListRequest.kind
        self.errorMessage = errorMessage
    }
}

extension Sequence where Element == BotTask {
    /// The tasks the bot's Tasks column lists: those not closed (archived), in their order.
    public var open: [BotTask] { filter { !$0.isArchived } }
}
