import Foundation
import Testing
@testable import BotChuCore

/// `botchu-task list --mine` (#262): a bot's open Tasks as its Tasks column shows them.
@Suite struct TaskListTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let all: (working: BotTask, review: BotTask, finished: BotTask, closed: BotTask)

    init() { all = Self.tasks(closedAt: now) }

    /// Four tasks of a bot's: working on an issue, reviewing a pull request on a host, finished
    /// with a pull request, and one closed in the sidebar.
    static func tasks(closedAt now: Date) -> (working: BotTask, review: BotTask, finished: BotTask, closed: BotTask) {
        let issueURL = URL(string: "https://github.com/asieke/BotChu/issues/262")!
        var working = BotTask(repo: "asieke/BotChu", checkout: "/repo", branch: "feat/262-task-list",
                              work: BotTask.Work(number: 262, title: "botchu-task list --mine", url: issueURL, isPullRequest: false))
        working.summary = "Task list command"
        let pullURL = URL(string: "https://github.com/asieke/BotChu/pull/120")!
        let review = BotTask(repo: "asieke/BotChu", checkout: "/repo",
                             work: BotTask.Work(number: 120, title: "Fix the sync", url: pullURL, isPullRequest: true),
                             hostID: UUID(), hostName: "omarchy", review: .review)
        let finished = BotTask(repo: "asieke/GitChu", checkout: "/gitchu", branch: "chore/speed-sync", brief: "Speed up the sync",
                               pullRequest: 77)
        let closed = BotTask(repo: "asieke/BotChu", checkout: "/repo", brief: "Old work", archivedAt: now)
        return (working, review, finished, closed)
    }

    func entries() -> [TaskListEntry] {
        let states: [UUID: (TabState, String?)] = [
            all.working.id: (.working(.working, since: now.addingTimeInterval(-252)), nil),
            all.review.id: (.idle(since: now.addingTimeInterval(-120)), "omarchy"),
            all.finished.id: (.news(pullRequest: 77, at: now.addingTimeInterval(-30)), nil),
            all.closed.id: (.idle(since: nil), nil),
        ]
        return [all.working, all.review, all.finished, all.closed].open.map { task in
            let (state, machine) = states[task.id]!
            return TaskListEntry(task: task, tab: ConversationTab(task: task, machine: machine, state: state), at: now)
        }
    }

    @Test func closedTasksAreLeftOutAndTheRestKeepTheirOrder() {
        let open = [all.working, all.closed, all.review, all.finished].open
        #expect(open.map(\.id) == [all.working.id, all.review.id, all.finished.id])
        #expect(entries().count == 3)
        #expect(TaskListEntry.text(botName: "10x Engineer Bot", entries: entries()).hasPrefix("10x Engineer Bot has 3 open Tasks,"))
    }

    @Test func eachTaskReadsAsItsRowInTheSidebar() throws {
        let rows = entries()
        let working = rows[0], review = rows[1], finished = rows[2]
        #expect(working.title == "BotChu #262" && working.summary == "Task list command")
        #expect(working.state == "Running a tool…" && working.running && working.time == "4:12")
        #expect(working.since == now.addingTimeInterval(-252))
        #expect(working.issue == 262 && working.pullRequest == nil && working.branch == "feat/262-task-list" && working.machine == nil)
        #expect(working.line == "BotChu #262 · Task list command · Running a tool… for 4:12 · issue #262 · feat/262-task-list · "
                + all.working.id.uuidString.lowercased())

        #expect(review.title == "BotChu #120" && review.summary == "Fix the sync" && review.state == "Idle" && !review.running)
        #expect(review.issue == nil && review.pullRequest == 120 && review.review && review.machine == "omarchy")
        #expect(review.line == "BotChu #120 · Fix the sync · Idle 2m ago · reviews PR #120 · on omarchy · "
                + all.review.id.uuidString.lowercased())

        #expect(finished.title == "GitChu" && finished.summary == "Speed up the sync" && finished.state == "Finished · PR #77")
        #expect(finished.line == "GitChu · Speed up the sync · Finished · PR #77 just now · PR #77 · chore/speed-sync · "
                + all.finished.id.uuidString.lowercased())

        let text = TaskListEntry.text(botName: "Fox", entries: rows)
        #expect(text.split(separator: "\n").map(String.init) == [
            "Fox has 3 open Tasks, as BotChu's sidebar lists them:", "1. " + working.line, "2. " + review.line, "3. " + finished.line])
        #expect(TaskListEntry.text(botName: "Fox", entries: Array(rows.prefix(1))).hasPrefix("Fox has 1 open Task,"))
        #expect(TaskListEntry.text(botName: "Fox", entries: []) == "Fox has no open Tasks.")
        // The state a sidebar shows while a turn waits on its worktree, without a time.
        let preparing = TaskListEntry(task: all.working, tab: ConversationTab(task: all.working, machine: nil, state: .preparing), at: now)
        #expect(preparing.state == "Making the worktree…" && preparing.running && preparing.time == nil && preparing.since == nil)
    }

    @Test func requestsAreReadAndCheckedAgainstTheAskingTurn() throws {
        let id = UUID(), invocation = UUID(), bot = UUID(), task = UUID(), subagent = UUID()
        let fields: [String: Any] = ["kind": "taskList", "id": id.uuidString.lowercased(), "invocationID": invocation.uuidString,
                                     "callerBotID": bot.uuidString, "callerTaskID": task.uuidString, "parentSubagentID": subagent.uuidString]
        let data = try JSONSerialization.data(withJSONObject: fields)
        #expect(TaskListRequest.isRequest(data) && !TaskHandoff.isHandoff(data) && !InboxRequest.isDelivery(data))
        let request = try TaskListRequest.parse(data)
        #expect(request == TaskListRequest(id: id, invocationID: invocation, callerBotID: bot, callerTaskID: task, parentSubagentID: subagent))
        let caller = SubagentCallerContext(invocationID: invocation, botID: bot, taskID: task, parentSubagentID: subagent, depth: 1, workingDirectory: "/")
        try request.validate(caller)
        var other = caller
        other.parentSubagentID = nil
        #expect(throws: InboxRequest.Problem.self) { try request.validate(other) }
        var missing = fields
        missing["callerBotID"] = nil
        #expect(throws: InboxRequest.Problem.self) { try TaskListRequest.parse(JSONSerialization.data(withJSONObject: missing)) }
        #expect(!TaskListRequest.isRequest(Data(#"{"kind":"task"}"#.utf8)))

        let result = TaskListResult(id: id, botID: bot, botName: "Fox", tasks: entries())
        #expect(try SubagentIPC.decode(TaskListResult.self, from: SubagentIPC.encode(result)) == result)
    }

    @Test func agentsAreToldHowToListTheirTasks() {
        let section = BotContext.subagentsSection(availableBots: [BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))])
        #expect(section.contains("`botchu-task list --mine` lists your own open Tasks as BotChu's sidebar shows them"))
        #expect(section.contains("(`--json` for the same fields)"))
    }

    // MARK: The helper

    @Test func theHelperAsksForTheCallersTasksAndPrintsThem() throws {
        let fixture = try ListFixture()
        let subagent = UUID()
        let started = try fixture.start(["list", "--mine"], subagent: subagent)
        defer { if started.0.isRunning { started.0.terminate() } }
        let asked = try fixture.request()
        let request = try TaskListRequest.parse(asked.data)
        #expect(request.invocationID == fixture.invocationID && request.callerBotID == fixture.botID)
        #expect(request.callerTaskID == nil && request.parentSubagentID == subagent)
        let rows = entries()
        try fixture.answer(TaskListResult(id: request.id, botID: fixture.botID, botName: "Fox", tasks: rows))
        let finished = fixture.finish(started)
        #expect(finished.code == 0, "\(finished.error)")
        #expect(finished.output == TaskListEntry.text(botName: "Fox", entries: rows) + "\n")
        // It tidies its answer away.
        #expect(!FileManager.default.fileExists(atPath: fixture.ipc.resultURL(request.id).path))
    }

    @Test func theHelperPrintsTheSameFieldsAsJSON() throws {
        let fixture = try ListFixture()
        let started = try fixture.start(["list", "--mine", "--json"])
        defer { if started.0.isRunning { started.0.terminate() } }
        let request = try TaskListRequest.parse(try fixture.request().data)
        let rows = entries()
        try fixture.answer(TaskListResult(id: request.id, botID: fixture.botID, botName: "Fox", tasks: rows))
        let finished = fixture.finish(started)
        #expect(finished.code == 0, "\(finished.error)")
        let printed = try #require(JSONSerialization.jsonObject(with: Data(finished.output.utf8)) as? [String: Any])
        let bot = try #require(printed["bot"] as? [String: Any])
        #expect(bot["name"] as? String == "Fox" && bot["id"] as? String == fixture.botID.uuidString.lowercased())
        let tasks = try #require(printed["tasks"] as? [[String: Any]])
        #expect(tasks.count == 3)
        let first = tasks[0]
        #expect(first["title"] as? String == "BotChu #262" && first["summary"] as? String == "Task list command")
        #expect(first["state"] as? String == "Running a tool…" && first["running"] as? Bool == true && first["time"] as? String == "4:12")
        #expect(first["issue"] as? Int == 262 && first["branch"] as? String == "feat/262-task-list" && first["since"] is String)
        #expect(first["id"] as? String == rows[0].id.uuidString.lowercased())
        #expect(tasks[1]["pullRequest"] as? Int == 120 && tasks[1]["machine"] as? String == "omarchy" && tasks[1]["review"] as? Bool == true)
    }

    @Test func theHelperSaysWhyThereIsNoListAndKeepsTheBotsList() throws {
        let fixture = try ListFixture()
        let started = try fixture.start(["list", "--mine"])
        defer { if started.0.isRunning { started.0.terminate() } }
        let asked = try fixture.request()
        let request = try TaskListRequest.parse(asked.data)
        #expect(fixture.ipc.removeRequest(asked.file))
        try fixture.answer(TaskListResult(id: request.id, errorMessage: "the asking turn has ended"))
        let failed = fixture.finish(started)
        #expect(failed.code == 1 && failed.error.contains("No Tasks list: the asking turn has ended"))

        // Without --mine, `list` lists the bots that can own Tasks, as before.
        var specialist = Bot(name: "Duck", workspace: "/tmp/duck")
        specialist.role = .specialist
        try fixture.ipc.writeRoster([BotRosterEntry(bot: Bot(name: "Worker", title: "Builds things", workspace: "/tmp/worker")),
                                     BotRosterEntry(bot: specialist)])
        let roster = fixture.finish(try fixture.start(["list"]))
        #expect(roster.code == 0 && roster.output.contains("worker — Worker — Builds things") && !roster.output.contains("Duck"))
        #expect(fixture.ipc.pendingRequests().isEmpty)
        let json = fixture.finish(try fixture.start(["list", "--json"]))
        #expect(json.code == 1 && json.error.contains("use it with --mine"))
    }
}

/// A mailbox and the helper as a turn has them, with the app's side played by the test.
private final class ListFixture {
    let root: URL
    let ipc: SubagentIPC
    let bin: URL
    let botID = UUID()
    let invocationID = UUID()

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-task-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.resolvingSymlinksInPath()
        ipc = SubagentIPC(root: root.appendingPathComponent("mailbox"))
        bin = root.appendingPathComponent("bin")
        try SubagentHookInstaller.install(binDirectory: bin)
        try ipc.prepare()
        try ipc.writeHeartbeat()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start(_ arguments: [String], subagent: UUID? = nil) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = bin.appendingPathComponent("botchu-task")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                               "BOTCHU_IPC_DIR": ipc.root.path, "BOTCHU_INVOCATION_ID": invocationID.uuidString,
                               "BOTCHU_CALLER_BOT_ID": botID.uuidString, "BOTCHU_CALLER_DEPTH": subagent == nil ? "0" : "1",
                               "BOTCHU_CALLER_SUBAGENT_ID": subagent?.uuidString ?? "", "BOTCHU_WAIT_TIMEOUT_SECONDS": "5"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        return (process, out, err)
    }

    func finish(_ started: (Process, Pipe, Pipe)) -> (code: Int32, output: String, error: String) {
        started.0.waitUntilExit()
        return (started.0.terminationStatus,
                String(decoding: started.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: started.2.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// The request the helper wrote, once it has.
    func request() throws -> (file: URL, data: Data) {
        let deadline = Date().addingTimeInterval(3)
        while ipc.pendingRequests().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return try #require(ipc.pendingRequests().first)
    }

    func answer(_ result: TaskListResult) throws {
        try SubagentIPC.encode(result).write(to: ipc.resultURL(result.id), options: .atomic)
    }
}
