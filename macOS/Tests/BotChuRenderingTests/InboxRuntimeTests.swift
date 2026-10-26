import Foundation
import Testing
import BotChuCore
@testable import BotChu

/// A bot delivers to the owner's Inbox with `botchu-inbox send`, and the owner's reply goes back
/// into the conversation that sent it.
extension RenderingTests {
    @Test func aDeliveryArrivesWithItsCopiesAndACardAfterTheReply() async throws {
        let fixture = try InboxFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.destination = .projects
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let delivery = try #require(app.inbox.all.first)
        #expect(app.inbox.all.count == 1, "The same title again in the turn updates it")
        #expect(delivery.botID == fixture.fox.id && delivery.taskID == nil && delivery.title == "Report")
        #expect(delivery.note == "Second version" && delivery.credits.isEmpty)
        #expect(delivery.question == Delivery.Question(text: "Which should I file?", choices: ["Answer first", "Hold"]))
        #expect(delivery.links == [Delivery.Link(repo: "asieke/BotChu", number: 118, isPullRequest: false)])
        #expect(delivery.files.map(\.name) == ["report.md"] && delivery.files.first?.kind == .document)
        let copy = InboxFolder(home: BotHome(workspace: fixture.fox.workspace)).fileURL("report.md", of: delivery.id)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "# v2")
        // The helper said what became of each send.
        let reply = try #require(app.thread(home).last { $0.role == .assistant }?.text)
        #expect(reply.contains("Delivered to your owner's Inbox: Report") && reply.contains("Updated to your owner's Inbox: Report"))
        #expect(reply.contains("Delivery: \(delivery.id.uuidString)"))
        // Its card follows the reply, once.
        #expect(app.thread(home).last?.delivery == delivery.id && app.thread(home).last?.role == .note)
        #expect(app.thread(home).filter { $0.delivery == delivery.id }.count == 1)

        // One unread state: reading the delivery clears its conversation's dot, and the reverse.
        #expect(app.inbox.unreadCount == 1 && app.unread.contains(home))
        #expect(InboxList.section(of: delivery, state: app.inbox.state, now: Date()) == .needsYou)
        app.inbox.markRead(delivery.id)
        #expect(app.inbox.unreadCount == 0 && !app.unread.contains(home))
        app.inbox.markRead(delivery.id, false)
        app.show(home)
        #expect(app.inbox.unreadCount == 0)

        // Saved beside the index, and read again at launch.
        await app.storage.settle()
        #expect(InboxState.load(from: fixture.store.root)[delivery.id].read)
    }

    @Test func anAnswerGoesOnceToItsConversationIsDoneAndOpensIt() async throws {
        let fixture = try InboxFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.destination = .projects
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let delivery = try #require(app.inbox.all.first)
        // Read in the Inbox.
        app.destination = .inbox
        app.inbox.isShowing = true
        app.inbox.selected = delivery.id

        #expect(app.inbox.reply("Answer first", to: delivery.id))
        // While the queue takes it, nothing else goes.
        #expect(app.inbox.sending.contains(delivery.id))
        #expect(!app.inbox.reply("Hold", to: delivery.id))
        try await fixture.wait { !app.inbox.sending.contains(delivery.id) }
        #expect(app.inbox.isDone(delivery.id) && app.inbox.state.isAnswered(delivery) && !app.inbox.isUnread(delivery.id))
        #expect(app.inbox.failed[delivery.id] == nil)
        // Its conversation opened.
        #expect(app.destination == nil && app.isShown(home))

        try await fixture.wait { app.thread(home).contains { $0.text.hasPrefix("GOT-REPLY") } }
        try await fixture.wait { !app.isRunning(home) }
        // The bot read which delivery it answers; the owner's message shows as typed, once.
        let sent = app.thread(home).filter { $0.role == .user && $0.delivery == delivery.id }
        #expect(sent.map(\.text) == ["Answer first"])
        #expect(app.thread(home).last { $0.role == .assistant }?.text == "GOT-REPLY \(delivery.id.uuidString.lowercased()) Answer first")
        // The bot's answer doesn't bring it back out of Done.
        #expect(app.inbox.isDone(delivery.id) && !app.inbox.isUnread(delivery.id))

        // After a relaunch it is still answered and Done.
        await app.storage.settle()
        app.stopAll()
        let relaunched = AppModel(store: fixture.store, settings: fixture.settings,
                                  usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
        defer { relaunched.stopAll() }
        try await fixture.wait { relaunched.inbox.isLoaded && relaunched.inbox.delivery(delivery.id) != nil }
        #expect(relaunched.inbox.isDone(delivery.id) && relaunched.inbox.state.isAnswered(delivery))
        #expect(!relaunched.inbox.state.needsAnswer(delivery))
    }

    @Test func anAnswerToATaskGoesToTheTaskAndOpensItAgainWhenClosed() async throws {
        let fixture = try InboxFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, task = fixture.task
        app.destination = .projects
        app.send("DELIVER", to: task)
        try await fixture.wait { !app.isRunning(task) }
        let delivery = try #require(app.inbox.all.first)
        #expect(delivery.taskID == task.taskID)
        app.closeTask(task)
        #expect(app.task(task)?.isArchived == true)

        app.inbox.isShowing = true
        app.inbox.selected = delivery.id
        #expect(app.inbox.reply("Hold", to: delivery.id))
        try await fixture.wait { !app.inbox.sending.contains(delivery.id) }
        #expect(app.inbox.isDone(delivery.id))
        #expect(app.task(task)?.isArchived == false && app.isShown(task))
        try await fixture.wait { app.thread(task).contains { $0.text.hasPrefix("GOT-REPLY") } }
        #expect(!app.thread(.home(fixture.fox.id)).contains { $0.delivery == delivery.id && $0.role == .user })
    }

    @Test func anAnswerToABusyConversationWaitsInItsQueueAlreadyDone() async throws {
        let fixture = try InboxFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.destination = .projects
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let delivery = try #require(app.inbox.all.first)
        app.send("HOLD", to: home)
        try await fixture.wait { app.isRunning(home) }

        // Answered from its card in the chat, which is shown: nothing else opens.
        app.show(home)
        #expect(app.inbox.reply("Hold, but say so", to: delivery.id))
        try await fixture.wait { !app.inbox.sending.contains(delivery.id) }
        #expect(app.inbox.isDone(delivery.id))
        #expect(app.messageQueues[home]?.pending.map(\.delivery) == [delivery.id])
        try fixture.release()
        try await fixture.wait { app.thread(home).contains { $0.text.hasPrefix("GOT-REPLY") } }
        try await fixture.wait { !app.isRunning(home) }
        #expect(app.thread(home).filter { $0.delivery == delivery.id && $0.role == .user }.count == 1)
        #expect(app.inbox.isDone(delivery.id))
    }

    @Test func anAnswerTheQueueCantTakeKeepsTheDraftAndCanBeSentAgain() async throws {
        let fixture = try InboxFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.destination = .projects
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let delivery = try #require(app.inbox.all.first)
        app.destination = .inbox
        app.inbox.isShowing = true
        app.inbox.selected = delivery.id

        // A folder where the queue's file goes: it can't be saved.
        await app.storage.settle()
        let queue = BotHome(workspace: fixture.fox.workspace).queueURL()
        try? FileManager.default.removeItem(at: queue)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        app.inbox.drafts[delivery.id] = "Answer first, please"
        #expect(app.inbox.reply("Answer first, please", to: delivery.id))
        try await fixture.wait { !app.inbox.sending.contains(delivery.id) }
        #expect(app.inbox.failed[delivery.id] == "Answer first, please")
        #expect(app.inbox.drafts[delivery.id] == "Answer first, please")
        #expect(!app.inbox.isDone(delivery.id) && app.inbox.state.needsAnswer(delivery))
        #expect(app.destination == .inbox && app.inbox.selected == delivery.id)

        // Sent again once it can be saved.
        try FileManager.default.removeItem(at: queue)
        #expect(app.inbox.reply("Answer first, please", to: delivery.id))
        #expect(app.inbox.failed[delivery.id] == nil)
        try await fixture.wait { !app.inbox.sending.contains(delivery.id) }
        #expect(app.inbox.isDone(delivery.id) && app.inbox.drafts[delivery.id] == nil && app.isShown(home))
        app.resumeQueuedMessages(to: home)
        try await fixture.wait { app.thread(home).contains { $0.text.hasPrefix("GOT-REPLY") } }
        #expect(app.thread(home).filter { $0.delivery == delivery.id && $0.role == .user }.map(\.text) == ["Answer first, please"])
    }

    @Test func aSubagentsDeliveryIsItsCallersAndCreditsIt() async throws {
        let fixture = try InboxFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.send("DELIVER_VIA_SUBAGENT", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let delivery = try #require(app.inbox.all.first)
        #expect(delivery.botID == fixture.fox.id && delivery.taskID == nil && delivery.title == "Research")
        #expect(delivery.credits == [Delivery.Credit(botID: fixture.worker.id, name: "Worker")])
        #expect(delivery.files.first?.credit == Delivery.Credit(botID: fixture.worker.id, name: "Worker"))
        #expect(app.thread(home).contains { $0.delivery == delivery.id && $0.role == .note })
        #expect(!app.thread(.home(fixture.worker.id)).contains { $0.delivery != nil })
        // Shown as it arrived, it is read.
        #expect(app.inbox.unreadCount == 0)
    }
}

@MainActor private final class InboxFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-runtime-\(UUID().uuidString)")
    let domain = "local.BotChu.InboxRuntimeTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let fox: Bot
    let worker: Bot
    /// A task of Fox's, run in its own folder.
    let task: ChatTarget
    let app: AppModel

    init() throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        fox = Bot(name: "Fox", accountID: "codex-dev", workspace: root.appendingPathComponent("fox").path)
        worker = Bot(name: "Worker", accountID: "codex-work", workspace: root.appendingPathComponent("worker").path)
        try BotHome(workspace: fox.workspace).save(fox)
        try BotHome(workspace: worker.workspace).save(worker)
        var made = BotTask(for: fox, repo: "fixture/repo", checkout: root.path, work: nil, brief: "Test")
        made.folder = root.appendingPathComponent("task").path
        try FileManager.default.createDirectory(atPath: made.folder!, withIntermediateDirectories: true)
        try BotHome(workspace: fox.workspace).save(made)
        task = .task(made.id, of: fox.id)
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        for account in [fox.accountID, worker.accountID] { settings.commands[account] = "/usr/bin/python3 \(Shell.quote(script.path))" }
        try store.saveIndex([Store.Entry(id: fox.id, workspace: fox.workspace), Store.Entry(id: worker.id, workspace: worker.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
    }

    func wait(seconds: Int = 30, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 40) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out: \(app.thread(.home(fox.id)).map(\.text))")
        throw CocoaError(.executableLoad)
    }

    /// Lets Home's HOLD turn end.
    func release() throws {
        try Data().write(to: URL(fileURLWithPath: fox.workspace).appendingPathComponent("release"))
    }

    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, os, re, subprocess, sys
    def emit(value): print(json.dumps(value), flush=True)
    def run(*args):
        result = subprocess.run(list(args), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout + result.stderr + "EXIT=" + str(result.returncode)
    prompt = sys.argv[-1]
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if int(os.environ.get("BOTCHU_CALLER_DEPTH", "0")):
        brief = re.search(r"<handoff_brief>\s*(.*?)\s*</handoff_brief>", prompt, re.S).group(1)
    else:
        brief = prompt.splitlines()[-1]
    reply = re.search(r"\[Your owner's reply from the Inbox to your delivery “[^”]*” \(([0-9a-f-]+)\)\]", prompt)
    if reply:
        answer = "GOT-REPLY " + reply.group(1) + " " + brief
    elif brief == "DELIVER":
        with open("report.md", "w") as handle: handle.write("# v1")
        first = run("botchu-inbox", "send", "--title", "Report", "--note", "First version", "--file", "report.md")
        with open("report.md", "w") as handle: handle.write("# v2")
        second = run("botchu-inbox", "send", "--title", "Report", "--note", "Second version", "--file", "report.md",
                     "--issue", "asieke/BotChu#118", "--ask", "Which should I file?", "--choice", "Answer first", "--choice", "Hold")
        with open("report.md", "w") as handle: handle.write("# edited after sending")
        answer = first + "\n---\n" + second
    elif brief == "HOLD":
        import time
        while not os.path.exists("release"): time.sleep(0.05)
        answer = "Released"
    elif brief == "DELIVER_VIA_SUBAGENT":
        answer = subprocess.run(["botchu-subagent", "call", "--agent", "Worker", "--brief", "SUB_DELIVER"], text=True,
                                stdout=subprocess.PIPE).stdout
    elif brief == "SUB_DELIVER":
        with open("research.md", "w") as handle: handle.write("# Findings")
        answer = run("botchu-inbox", "send", "--title", "Research", "--note", "Findings", "--file", "research.md")
    else:
        answer = "Done"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}
