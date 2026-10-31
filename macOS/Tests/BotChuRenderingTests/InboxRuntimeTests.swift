import Foundation
import Observation
import Testing
import BotChuCore
@testable import BotChu

/// A bot delivers to the owner's Inbox with `botchu-inbox send`, and the owner's reply goes back
/// into the conversation that sent it.
extension RenderingTests {
    @Test func inboxStatusRegroupsOncePerMutationAndNeverForRepeatedReads() async throws {
        let fixture = try InboxStatusFixture()
        defer { fixture.cleanUp() }
        let restored = Flag()
        withObservationTracking {
            _ = fixture.app.inbox.awaitingInput(fixture.targets[1])
        } onChange: { restored.set() }
        try await fixture.ready()
        let app = fixture.app, inbox = app.inbox!
        #expect(restored.value, "A conversation observed before load sees its restored questions")
        #expect(fixture.bots.count == 20 && fixture.targets.count == 100 && inbox.deliveries.count == 2_000)
        #expect(inbox.statusDerivations == 1, "Launch restore derives the whole Inbox once")
        expectInboxStatusMatchesSource(inbox)
        for _ in 0..<10 {
            for target in fixture.targets {
                _ = inbox.awaitingInput(target)
                _ = app.tabState(of: target)
            }
            _ = inbox.unreadCount
            _ = inbox.unfinishedCount
        }
        #expect(inbox.statusDerivations == 1, "1,000 status reads must not regroup")

        app.destination = .projects
        let target = fixture.targets[1], other = fixture.targets[6]
        let ownChanged = Flag(), otherChanged = Flag()
        withObservationTracking { _ = app.tabState(of: target) } onChange: { ownChanged.set() }
        withObservationTracking { _ = app.tabState(of: other) } onChange: { otherChanged.set() }
        var delivery = Delivery(botID: target.botID, taskID: target.taskID, title: "New question", purpose: .needsInput)
        var before = inbox.statusDerivations
        try await inbox.post(delivery)
        #expect(inbox.statusDerivations == before + 1)
        #expect(ownChanged.value && !otherChanged.value, "Only the receiving conversation observes a changed question")
        expectInboxStatusMatchesSource(inbox)

        // A row observes its own delivery's entry (#356): another delivery's Done leaves it alone.
        let neighbour = try #require(inbox.all.first { $0.id != delivery.id && !inbox.isDone($0.id) })
        let rowChanged = Flag(), neighbourChanged = Flag()
        withObservationTracking { _ = inbox.isUnread(delivery.id); _ = inbox.entry(delivery.id) } onChange: { rowChanged.set() }
        withObservationTracking { _ = inbox.isUnread(neighbour.id); _ = inbox.isDone(neighbour.id) } onChange: { neighbourChanged.set() }
        before = inbox.statusDerivations
        inbox.setDone(delivery.id, true)
        #expect(rowChanged.value && !neighbourChanged.value, "Only the Done delivery's row observes its Done")
        #expect(inbox.isDone(delivery.id) && !inbox.isUnread(delivery.id) && inbox.entry(delivery.id) == inbox.state[delivery.id])
        #expect(inbox.statusDerivations == before + 1)
        inbox.setDone(delivery.id, true)
        #expect(inbox.statusDerivations == before + 1, "No mutation for an unchanged Done value")
        expectInboxStatusMatchesSource(inbox)
        before = inbox.statusDerivations
        inbox.setDone(delivery.id, false)
        #expect(inbox.statusDerivations == before + 1)
        expectInboxStatusMatchesSource(inbox)

        before = inbox.statusDerivations
        inbox.markRead(delivery.id, false)
        #expect(inbox.statusDerivations == before + 1)
        expectInboxStatusMatchesSource(inbox)
        before = inbox.statusDerivations
        inbox.conversationShown(target)
        #expect(inbox.statusDerivations == before + 1, "Reading many deliveries is one mutation")
        expectInboxStatusMatchesSource(inbox)

        before = inbox.statusDerivations
        delivery.note = "Changed options"
        try await inbox.post(delivery)
        #expect(inbox.statusDerivations == before + 1)
        expectInboxStatusMatchesSource(inbox)
        before = inbox.statusDerivations
        inbox.forget(bot: target.botID)
        #expect(inbox.statusDerivations == before + 1, "Deleting a bot's deliveries is one mutation")
        #expect(inbox.awaitingInput(target).isEmpty && inbox.awaitingInputDates(target).isEmpty)
        expectInboxStatusMatchesSource(inbox)
    }

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
        #expect(delivery.question == Delivery.Question(text: "Which should I file?", choices: ["Answer first", "Hold"], recommended: "Answer first"))
        // Sent for review first, then updated to ask: it needs input.
        #expect(delivery.purpose == .needsInput && app.inbox.awaitingInput(home) == [delivery.id])
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
        #expect(InboxList.section(of: delivery, state: app.inbox.state, now: Date()) == .needsInput)
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

        let beforeAnswer = app.inbox.statusDerivations
        #expect(app.inbox.reply("Answer first", to: delivery.id))
        // While the queue takes it, nothing else goes.
        #expect(app.inbox.sending.contains(delivery.id))
        #expect(!app.inbox.reply("Hold", to: delivery.id))
        try await fixture.wait { !app.inbox.sending.contains(delivery.id) }
        #expect(app.inbox.isDone(delivery.id) && app.inbox.state.isAnswered(delivery) && !app.inbox.isUnread(delivery.id))
        #expect(app.inbox.failed[delivery.id] == nil && app.inbox.awaitingInput(home).isEmpty)
        #expect(app.inbox.statusDerivations == beforeAnswer + 1, "An accepted answer derives once")
        expectInboxStatusMatchesSource(app.inbox)
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
        expectInboxStatusMatchesSource(relaunched.inbox)
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
        // Still unresolved: first in the list, counted, and its conversation still waits on the owner.
        #expect(InboxList.section(of: delivery, state: app.inbox.state, now: Date()) == .needsInput)
        #expect(app.inbox.unfinishedCount == 1 && app.inbox.awaitingInput(home) == [delivery.id])

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

    /// `--update <id>` in a later turn replaces the delivery rather than adding one; sent again
    /// saying nothing new it stays Done, and changed it is unread and needs input again (#217).
    @Test func anUpdateInALaterTurnReplacesTheDeliveryAndOnlyAChangeAsksAgain() async throws {
        let fixture = try InboxFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.destination = .projects
        app.send("DELIVER", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let delivery = try #require(app.inbox.all.first)
        app.inbox.setDone(delivery.id, true)
        let id = delivery.id.uuidString.lowercased()

        app.send("UPDATE \(id) Second version", to: home)
        try await fixture.wait { !app.isRunning(home) }
        #expect(app.thread(home).last { $0.role == .assistant }?.text.contains("Updated to your owner's Inbox: Report") == true)
        #expect(app.inbox.all.count == 1 && app.inbox.delivery(delivery.id)?.updatedAt == delivery.updatedAt)
        #expect(app.inbox.isDone(delivery.id) && !app.inbox.isUnread(delivery.id) && app.inbox.awaitingInput(home).isEmpty)
        expectInboxStatusMatchesSource(app.inbox)

        app.send("UPDATE \(id) Third version: the options changed", to: home)
        try await fixture.wait { !app.isRunning(home) }
        let renewed = try #require(app.inbox.delivery(delivery.id))
        #expect(app.inbox.all.count == 1 && renewed.note == "Third version: the options changed" && renewed.sentAt == delivery.sentAt)
        #expect(!app.inbox.isDone(delivery.id) && app.inbox.isUnread(delivery.id) && app.inbox.awaitingInput(home) == [delivery.id])
        expectInboxStatusMatchesSource(app.inbox)
        #expect(app.thread(home).filter { $0.delivery == delivery.id }.count == 1, "One card")

        // Only a delivery this conversation sent can be updated.
        app.send("UPDATE \(UUID().uuidString.lowercased()) Elsewhere", to: home)
        try await fixture.wait { !app.isRunning(home) }
        #expect(app.thread(home).last { $0.role == .assistant }?.text.contains("Not delivered: this conversation sent no delivery") == true)
        app.send("UPDATE \(id) From the task", to: fixture.task)
        try await fixture.wait { !app.isRunning(fixture.task) }
        #expect(app.inbox.all.count == 1 && app.inbox.delivery(delivery.id)?.taskID == nil)
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
        first = run("botchu-inbox", "send", "--purpose", "review", "--title", "Report", "--note", "First version", "--file", "report.md")
        with open("report.md", "w") as handle: handle.write("# v2")
        second = run("botchu-inbox", "send", "--purpose", "needs-input", "--title", "Report", "--note", "Second version", "--file", "report.md",
                     "--issue", "asieke/BotChu#118", "--ask", "Which should I file?", "--choice", "Answer first", "--choice", "Hold",
                     "--recommend", "Answer first")
        with open("report.md", "w") as handle: handle.write("# edited after sending")
        answer = first + "\n---\n" + second
    elif brief.startswith("UPDATE "):
        _, ident, note = brief.split(" ", 2)
        with open("report.md", "w") as handle: handle.write("# v2")
        answer = run("botchu-inbox", "send", "--purpose", "needs-input", "--title", "Report", "--note", note, "--file", "report.md",
                     "--issue", "asieke/BotChu#118", "--ask", "Which should I file?", "--choice", "Answer first", "--choice", "Hold",
                     "--recommend", "Answer first", "--update", ident)
    elif brief == "HOLD":
        import time
        while not os.path.exists("release"): time.sleep(0.05)
        answer = "Released"
    elif brief == "DELIVER_VIA_SUBAGENT":
        answer = subprocess.run(["botchu-subagent", "call", "--agent", "Worker", "--brief", "SUB_DELIVER"], text=True,
                                stdout=subprocess.PIPE).stdout
    elif brief == "SUB_DELIVER":
        with open("research.md", "w") as handle: handle.write("# Findings")
        answer = run("botchu-inbox", "send", "--purpose", "fyi", "--title", "Research", "--note", "Findings", "--file", "research.md")
    else:
        answer = "Done"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}

/// Compare cached runtime reads with the uncached rules after a transition.
@MainActor func expectInboxStatusMatchesSource(_ inbox: InboxModel) {
    let deliveries = Array(inbox.deliveries.values)
    #expect(inbox.unreadCount == inbox.state.unreadCount(deliveries))
    #expect(inbox.unfinishedCount == inbox.state.unfinishedCount(deliveries))
    let expected = inbox.state.awaitingInput(deliveries)
    for origin in Set(deliveries.map(\.origin)) {
        let target = ChatTarget(botID: origin.botID, taskID: origin.taskID)
        #expect(inbox.awaitingInput(target) == expected[origin, default: []])
        #expect(inbox.awaitingInputDates(target) == expected[origin, default: []].compactMap { inbox.delivery($0)?.updatedAt })
    }
}
