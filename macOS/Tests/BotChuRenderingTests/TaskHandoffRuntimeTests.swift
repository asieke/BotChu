import Foundation
import Testing
import BotChuCore
@testable import BotChu

/// #111: a conversation hands an independent Task to another bot with `botchu-task create` (or a
/// dispatch file naming it), unlike a sub-agent run, which stays a child of the conversation.
extension RenderingTests {
    @Test func homeHandsATaskToAnIdleBotThatGoesOnAfterTheTurnEnds() async throws {
        let fixture = try HandoffFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.send("HAND_OFF", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let task = try #require(app.tasks[fixture.worker.id]?.first)
        let target = ChatTarget.task(task.id, of: fixture.worker.id)
        // One Task, under the bot it was handed to, on that bot's account, in a worktree of its own.
        #expect(app.tasks[fixture.worker.id]?.count == 1 && app.tasks[fixture.fox.id]?.map(\.title) == ["Intake"])
        #expect(app.openTasks(of: fixture.worker.id).map(\.id) == [task.id])
        #expect(task.origin == .agent && task.accountID == fixture.worker.accountID && task.title == "Batch")
        #expect(task.requestedBy?.botID == fixture.fox.id && task.requestedBy?.taskID == nil)
        #expect(task.requestedBy?.conversation == "Fox's Home")
        #expect(app.task(target)?.folder.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(app.thread(target).first { $0.role == .user }?.text == "WORK")
        // The asking turn has ended and the Task still works: it isn't the turn's child.
        #expect(app.isRunning(target))
        #expect((app.delegation.records[home] ?? []).isEmpty)
        // The asking conversation heard who got it, its IDs and that it started, and can open it.
        let reply = try #require(app.thread(home).last { $0.role == .assistant }?.text)
        #expect(reply.contains("Status: started") && reply.contains(task.id.uuidString) && reply.contains(fixture.worker.id.uuidString))
        let receipt = try #require(app.thread(home).first { $0.role == .receipt })
        #expect(receipt.taskID == task.id && receipt.taskBotID == fixture.worker.id)
        #expect(receipt.text == "Handed Batch to Worker as a new task")
        // The destination's Home never ran and never got the brief.
        #expect(app.bot(fixture.worker.id)?.sessionID == "worker-home-session")
        #expect(!app.thread(.home(fixture.worker.id)).contains { $0.role == .user || $0.text.contains("WORK") })

        try Data().write(to: fixture.root.appendingPathComponent("release-work"))
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.thread(target).last { $0.role == .assistant }?.text == "WORK-DONE")
        await app.storage.settle()
        let saved = try #require(BotHome(workspace: fixture.worker.workspace).loadTasks().first { $0.id == task.id })
        #expect(saved.requestedBy == task.requestedBy && saved.origin == .agent)
    }

    @Test func aTaskAskingAgainGetsTheSameTaskAndFailuresSaySo() async throws {
        let fixture = try HandoffFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("HAND_OFF_TWICE", to: fixture.foxTask)
        try await fixture.wait { !app.isRunning(fixture.foxTask) }
        let tasks = try #require(app.tasks[fixture.worker.id])
        #expect(tasks.count == 1)
        let task = try #require(tasks.first)
        #expect(task.requestedBy?.taskID == fixture.foxTask.taskID && task.requestedBy?.conversation == "Fox's task Intake")
        let replies = try #require(app.thread(fixture.foxTask).last { $0.role == .assistant }?.text).components(separatedBy: "---")
        #expect(replies.count == 2 && replies.allSatisfy { $0.contains(task.id.uuidString) && $0.contains("EXIT=0") })
        #expect(replies[1].contains("no second Task was made"))
        #expect(app.thread(fixture.foxTask).filter { $0.role == .receipt && $0.taskID == task.id }.count == 1)

        // In a later turn too, after its answer was lost.
        app.send("HAND_OFF_TWICE", to: fixture.foxTask)
        try await fixture.wait { !app.isRunning(fixture.foxTask) }
        #expect(app.tasks[fixture.worker.id]?.count == 1)

        // A bot or repository BotChu can't find: why, no Task, and the same command can be run again.
        app.send("HAND_OFF_UNKNOWN", to: fixture.foxTask)
        try await fixture.wait { !app.isRunning(fixture.foxTask) }
        let unknown = try #require(app.thread(fixture.foxTask).last { $0.role == .assistant }?.text)
        #expect(unknown.contains("No BotChu agent matches ‘missing-bot’") && unknown.contains("botchu-task list"))
        #expect(unknown.contains("No Task was created") && unknown.contains("EXIT=1"))
        app.send("HAND_OFF_NO_REPO", to: fixture.foxTask)
        try await fixture.wait { !app.isRunning(fixture.foxTask) }
        let nowhere = try #require(app.thread(fixture.foxTask).last { $0.role == .assistant }?.text)
        #expect(nowhere.contains("fixture/nowhere isn't one of your GitHub repositories") && nowhere.contains("EXIT=1"))
        #expect(app.tasks[fixture.worker.id]?.count == 1 && app.tasks[fixture.fox.id]?.count == 1)
    }

    @Test func aTaskOnAHostHandsATaskToABotOnThisMac() async throws {
        let fixture = try HandoffFixture(remote: true)
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("HAND_OFF", to: fixture.foxTask)
        try await fixture.wait { !app.isRunning(fixture.foxTask) }
        let task = try #require(app.tasks[fixture.worker.id]?.first)
        #expect(task.hostID == nil && task.checkout == fixture.checkout)
        #expect(task.requestedBy?.taskID == fixture.foxTask.taskID)
        let reply = try #require(app.thread(fixture.foxTask).last { $0.role == .assistant }?.text)
        #expect(reply.contains("Status: started") && reply.contains(task.id.uuidString))
        #expect(app.isRunning(.task(task.id, of: fixture.worker.id)))
    }

    /// The original failure: a request written into another bot's dispatch folder waited for that
    /// bot's Home to run. Now any turn's end (or any running turn) takes it.
    @Test func dispatchRequestsNoLongerWaitForTheirBotsHome() async throws {
        let fixture = try HandoffFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("DISPATCH_FILE", to: fixture.foxTask)
        try await fixture.wait { !app.isRunning(fixture.foxTask) }
        try await fixture.wait { app.tasks[fixture.worker.id]?.isEmpty == false }
        let task = try #require(app.tasks[fixture.worker.id]?.first)
        #expect(task.origin == .home && task.brief == "WORK")
        #expect(app.bot(fixture.worker.id)?.sessionID == "worker-home-session")

        // A request naming another bot hands it the task, and the asking Home can open it.
        app.send("DISPATCH_AGENT", to: .home(fixture.fox.id))
        try await fixture.wait { !app.isRunning(.home(fixture.fox.id)) }
        try await fixture.wait { app.tasks[fixture.worker.id]?.count == 2 }
        let handed = try #require(app.tasks[fixture.worker.id]?.last)
        #expect(handed.origin == .agent && handed.requestedBy?.botID == fixture.fox.id && handed.title == "project · Second")
        let receipt = try #require(app.thread(.home(fixture.fox.id)).last { $0.role == .receipt })
        #expect(receipt.taskID == handed.id && receipt.taskBotID == fixture.worker.id)
        #expect(app.tasks[fixture.fox.id]?.count == 1)
    }

    /// The batch journey: one Task for the destination bot, whose parallel workers are its own
    /// sub-agent runs; the asking turn ends while they work, and stopping the Task stops them.
    @Test func aBatchHandoffIsOneTaskWhoseWorkersAreItsOwnSubagents() async throws {
        let fixture = try HandoffFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.send("HAND_OFF_BATCH", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let task = try #require(app.tasks[fixture.worker.id]?.first)
        let target = ChatTarget.task(task.id, of: fixture.worker.id)
        try await fixture.wait { (app.delegation.records[target] ?? []).filter { $0.phase == .running }.count == 2 }
        #expect(app.tasks[fixture.worker.id]?.count == 1)
        #expect((app.delegation.records[home] ?? []).isEmpty)
        #expect(app.isRunning(target))
        app.stop(target)
        try await fixture.wait { !app.isRunning(target) && (app.delegation.records[target] ?? []).allSatisfy { !$0.phase.isActive } }
        #expect(app.delegation.records[target]?.count == 2)
        #expect(app.delegation.records[target]?.allSatisfy { $0.phase == .stopped } == true)
        #expect(app.task(target) != nil)
    }
}

@MainActor private final class HandoffFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-task-handoff-\(UUID().uuidString)")
    let domain = "local.BotChu.TaskHandoffTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let fox: Bot
    let worker: Bot
    let app: AppModel
    /// A task of Fox's, which asks for Tasks too.
    let foxTask: ChatTarget
    let checkout: String
    let originalSSH: String

    init(remote: Bool = false) throws {
        originalSSH = Machine.ssh
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        fox = Bot(name: "Fox", accountID: "codex-dev", workspace: root.appendingPathComponent("fox").path)
        worker = Bot(name: "Worker", accountID: "codex-work", workspace: root.appendingPathComponent("worker").path,
                     sessionID: "worker-home-session", sessionAccountID: "codex-work")
        try BotHome(workspace: fox.workspace).save(fox)
        try BotHome(workspace: worker.workspace).save(worker)
        // The repository the Tasks work in, checked out in the repositories folder.
        checkout = root.appendingPathComponent("repos/project").path
        for arguments in [["git", "init", "-q", "-b", "main", checkout],
                          ["git", "-C", checkout, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                           "commit", "-q", "--allow-empty", "-m", "Initial"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            git.arguments = arguments
            try git.run()
            git.waitUntilExit()
        }
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        for account in [fox.accountID, worker.accountID] { settings.commands[account] = "/usr/bin/python3 \(Shell.quote(script.path))" }
        var host: SSHHost?
        if remote {
            let remoteHome = root.appendingPathComponent("remote-home")
            try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
            let ssh = root.appendingPathComponent("ssh")
            // A stand-in ssh that runs here, with a HOME (and so a mailbox) of the host's own.
            try """
                #!/bin/sh
                while [ $# -gt 0 ]; do
                  case $1 in -o|-p|-i|-l|-F) shift 2 ;; -*) shift ;; *) break ;; esac
                done
                shift
                export HOME=\(Shell.quote(remoteHome.path))
                exec /bin/sh -c "$*"

                """.write(to: ssh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
            Machine.ssh = ssh.path
            host = SSHHost(nickname: "Far Mac", destination: "fixture-host", reposFolder: root.path,
                           commands: [fox.accountID: "/usr/bin/python3 \(Shell.quote(script.path))"])
            settings.hosts = [host!]
        }
        var task = BotTask(for: fox, repo: "fixture/project", checkout: checkout, work: nil, brief: "Intake", title: "Intake", host: host)
        let folder = root.appendingPathComponent("fox-worktree")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        task.folder = folder.path
        try BotHome(workspace: fox.workspace).save(task)
        foxTask = .task(task.id, of: fox.id)
        try store.saveIndex([Store.Entry(id: fox.id, workspace: fox.workspace), Store.Entry(id: worker.id, workspace: worker.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
        // Your repositories as gh would list them, read just now.
        app.repositories = [GitHubLookup.Repo(nameWithOwner: "fixture/project")]
        app.repositoriesReadAt = Date()
    }

    func wait(seconds: Int = 30, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 40) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out: \(app.thread(foxTask).map(\.text)) / \(app.thread(.home(fox.id)).map(\.text)) / \(app.tasks[worker.id]?.map(\.title) ?? [])")
        throw CocoaError(.executableLoad)
    }

    func cleanUp() {
        app.stopAll()
        Machine.ssh = originalSSH
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, os, re, subprocess, sys, time
    root = os.path.dirname(os.path.abspath(__file__))
    def emit(value): print(json.dumps(value), flush=True)
    def run(*args):
        result = subprocess.run(list(args), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout + result.stderr + "EXIT=" + str(result.returncode)
    def spawn(brief):
        return subprocess.run(["botchu-subagent", "spawn", "--agent", "Worker", "--brief", brief], text=True,
                              stdout=subprocess.PIPE).stdout.strip()
    def request(folder, name, value):
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, name), "w") as handle: json.dump(value, handle)
    def hold(name):
        while not os.path.exists(os.path.join(root, name)): time.sleep(.05)
    prompt = sys.argv[-1]
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if int(os.environ.get("BOTCHU_CALLER_DEPTH", "0")):
        brief = re.search(r"<handoff_brief>\s*(.*?)\s*</handoff_brief>", prompt, re.S).group(1)
    else:
        brief = prompt.splitlines()[-1]
    create = ["botchu-task", "create", "--agent", "Worker", "--repo", "fixture/project", "--wait", "20"]
    if brief == "HAND_OFF":
        answer = run(*create, "--title", "Batch", "--brief", "WORK")
    elif brief == "HAND_OFF_TWICE":
        answer = run(*create, "--brief", "WORK") + "\n---\n" + run(*create, "--brief", "WORK")
    elif brief == "HAND_OFF_UNKNOWN":
        answer = run("botchu-task", "create", "--agent", "missing-bot", "--repo", "fixture/project", "--brief", "WORK")
    elif brief == "HAND_OFF_NO_REPO":
        answer = run("botchu-task", "create", "--agent", "Worker", "--repo", "fixture/nowhere", "--brief", "WORK")
    elif brief == "HAND_OFF_BATCH":
        answer = run(*create, "--brief", "FANOUT")
    elif brief == "DISPATCH_FILE":
        request(os.path.join(root, "worker", ".botchu", "dispatch"), "from-fox.json", {"repo": "fixture/project", "task": "WORK"})
        answer = "Written"
    elif brief == "DISPATCH_AGENT":
        request(os.path.join(root, "fox", ".botchu", "dispatch"), "for-worker.json",
                {"repo": "fixture/project", "task": "Second", "agent": "worker"})
        answer = "Written"
    elif brief in ("WORK", "Second"):
        hold("release-work")
        answer = "WORK-DONE"
    elif brief == "FANOUT":
        answer = run("botchu-subagent", "wait", spawn("LEAF"), spawn("LEAF"))
    elif brief == "LEAF":
        hold("release-leaf")
        answer = "HANDOFF-LEAF"
    else:
        answer = "Done"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}
