import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// #109: a launch reads what the first window needs, not every conversation's history; a
/// conversation is read when it is shown or something needs it; and what is asked of one meanwhile
/// waits for it, in order, so nothing is lost, sent twice or written over a full transcript.
extension RenderingTests {
    @Test func aLaunchReadsTheShownConversationAndRecoveryAloneAndNoArchivedHistory() async throws {
        let fixture = try HistoryFixture(closedTasks: 2, children: true)
        defer { fixture.cleanUp() }
        // Nothing is read while the model is made: the shown Home is read after, off the main thread.
        let shown = try #require(fixture.lane(fixture.home(0)))
        fixture.gate.close(shown)
        let app = fixture.launch()
        #expect(fixture.decodedFiles.keys.allSatisfy { $0 == fixture.interruptedThread.path })
        #expect(!app.conversation(fixture.home(0)).isLoaded)
        fixture.gate.open(shown)
        await app.storage.settle()
        let read = Set(fixture.decodedFiles.keys)
        // The shown Home, and the run a relaunch interrupted, which is closed, once.
        #expect(read == [fixture.transcript(fixture.home(0)), fixture.interruptedThread.path])
        #expect(app.conversation(fixture.home(0)).isLoaded)
        #expect(app.thread(fixture.home(0)).count == fixture.messages[fixture.home(0)])
        #expect(app.delegation.run(fixture.interrupted)?.phase == .stopped)
        #expect(app.delegation.run(fixture.finished)?.phase == .completed)
        #expect(fixture.counts.repairs == 0)
        #expect(fixture.counts.copies == 0)
        // Every other open conversation's sidebar status comes from its digest.
        for target in fixture.open where target != fixture.home(0) {
            #expect(!app.conversation(target).isLoaded)
            #expect(app.status(of: target)?.messageCount == (fixture.messages[target] ?? 0) / 3 * 2)
        }
        let launched = fixture.counts.bytesRead
        app.stopAll()

        // Ten times the closed tasks' history: a launch reads no more of it.
        try fixture.addClosedTasks(18)
        HistoryCounters.shared.reset(under: fixture.root)
        let again = fixture.launch()
        await again.storage.settle()
        #expect(Set(fixture.decodedFiles.keys) == [fixture.transcript(fixture.home(0))])
        #expect(fixture.counts.bytesRead < launched)
        again.stopAll()
    }

    @Test func aConversationShownIsReadOffTheMainThreadWithASpinnerMeanwhile() async throws {
        _ = NSApplication.shared
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        let target = fixture.task(0, 0)
        let lane = try #require(fixture.lane(target))
        fixture.gate.close(lane)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(UserDefaults(suiteName: fixture.domain)!))
        window.makeKeyAndOrderFront(nil)
        app.show(target)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Shown at once, not as an empty conversation, and typing and switching go on meanwhile.
        #expect(!app.conversation(target).isLoaded)
        #expect(app.thread(target).isEmpty)
        app.drafts[target] = "typed while it loads"
        app.show(fixture.home(1))
        app.show(target)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!app.conversation(target).isLoaded)
        fixture.gate.open(lane)
        try await fixture.wait { app.conversation(target).isLoaded }
        #expect(app.thread(target).map(\.id) == fixture.disk(target).map(\.id))
        #expect(app.drafts[target] == "typed while it loads")
    }

    @Test func changesToAConversationNotInMemoryWaitForItAndKeepItsHistory() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        let home = fixture.home(1)
        let before = fixture.disk(home)
        #expect(!app.conversation(home).isLoaded)
        fixture.gate.close(try #require(fixture.lane(home)))
        app.postJobReceipt("Morning triage found two issues.", job: UUID(), run: UUID(), to: home.botID)
        app.note("A note from BotChu", in: home)
        // Nothing is written over the full transcript meanwhile.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.disk(home).map(\.id) == before.map(\.id))
        fixture.gate.open(try #require(fixture.lane(home)))
        await app.storage.settle()
        let saved = fixture.disk(home)
        #expect(saved.count == before.count + 2)
        #expect(Array(saved.prefix(before.count)).map(\.id) == before.map(\.id))
        #expect(saved.suffix(2).map(\.text) == ["Morning triage found two issues.", "A note from BotChu"])
        #expect(app.thread(home).map(\.id) == saved.map(\.id))
        #expect(app.unread.contains(home))
    }

    @Test func sendsStopAndQueueEditsBeforeRecoveryKeepTheirOrderAndStartNothingStopped() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let target = fixture.task(0, 1)
        // Left queued when BotChu quit: one to withdraw before recovery, one to keep.
        let withdrawn = ChatMessage(role: .user, text: "withdraw me")
        let kept = ChatMessage(role: .user, text: "keep me")
        try fixture.botHome(0).saveQueue(MessageQueue(saved: [withdrawn, kept]), task: target.taskID)
        let lane = try #require(fixture.lane(target))
        fixture.gate.close(lane)
        let app = fixture.launch()
        defer { app.stopAll() }
        #expect(app.messageQueues[target] == nil)
        app.removeQueuedMessage(withdrawn.id, from: target)
        #expect(app.send("sent before recovery", to: target))
        app.stop(target)
        fixture.gate.open(lane)
        await app.storage.settle()
        try await Task.sleep(for: .milliseconds(300))
        // Stop withdrew automatic delivery: no turn ran, and the queue is paused, in order.
        #expect(!fixture.ran(target))
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["keep me", "sent before recovery"])
        #expect(app.messageQueues[target]?.isPaused == true)
        #expect(fixture.botHome(0).loadQueuedMessages(task: target.taskID).map(\.text) == ["keep me", "sent before recovery"])
        // Sent next, each goes once, after the whole history.
        app.resumeQueuedMessages(to: target)
        try await fixture.wait { app.thread(target).last?.text == "reply:sent before recovery" }
        let disk = fixture.disk(target)
        #expect(disk.filter { $0.role == .user }.suffix(2).map(\.text) == ["keep me", "sent before recovery"])
        #expect(try fixture.calls(target).count == 2)
        #expect(disk.count >= (fixture.messages[target] ?? 0) + 4)
    }

    @Test func queuedMessagesOfAnUnopenedTaskGoOutAfterItsOwnRecovery() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let target = fixture.task(1, 0)
        let waiting = ChatMessage(role: .user, text: "left queued")
        try fixture.botHome(1).saveQueue(MessageQueue(saved: [waiting]), task: target.taskID)
        let lane = try #require(fixture.lane(target))
        fixture.gate.close(lane)
        let app = fixture.launch()
        defer { app.stopAll() }
        // Others are recovered; this one waits for its own recovery, even though it isn't shown.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.ran(target))
        fixture.gate.open(lane)
        try await fixture.wait { app.thread(target).last?.text == "reply:left queued" }
        #expect(try fixture.calls(target).count == 1)
        #expect(app.thread(target).prefix(fixture.messages[target] ?? 0).map(\.id) == fixture.initial[target]?.map(\.id))
    }

    @Test func aLateReadIsDroppedWhenItsBotIsDeletedAndReadAgainWhereItMoved() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        // Moved while its Home is being read: read again where it is now.
        let home = fixture.home(1)
        let lane = try #require(fixture.lane(home))
        fixture.gate.close(lane)
        app.show(home)
        let moved = fixture.root.appendingPathComponent("moved-bot").path
        var bot = try #require(app.bot(home.botID))
        bot.workspace = moved
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { fixture.gate.open(lane) }
        app.update(bot)
        #expect(app.bot(home.botID)?.workspace == moved)
        try await fixture.wait { app.conversation(home).isLoaded }
        #expect(app.thread(home).map(\.id) == fixture.initial[home]?.map(\.id))
        #expect(BotHome(workspace: moved).loadThread().count == fixture.messages[home])

        // Deleted while a task is being read: nothing is made again in its folder.
        let task = fixture.task(0, 1)
        let taskLane = try #require(fixture.lane(task))
        fixture.gate.close(taskLane)
        app.show(task)
        app.note("late", in: task)
        let folder = try #require(app.bot(task.botID)).workspace
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { fixture.gate.open(taskLane) }
        app.delete(task.botID)
        await app.storage.settle()
        #expect(app.conversations[task] == nil)
        #expect(!FileManager.default.fileExists(atPath: BotHome(workspace: folder).url.path))
    }

    @Test func inactiveHistoriesLeaveMemoryAndComeBackWithTheirDraftQueueAndSession() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        app.historyBudget = HistoryBudget(limit: 1)
        let first = fixture.task(0, 0), second = fixture.task(0, 1)
        _ = await app.loadedThread(first)
        app.show(first)
        app.drafts[first] = "half written"
        var queue = MessageQueue(saved: [ChatMessage(role: .user, text: "queued and paused")])
        queue.pause()
        app.messageQueues[first] = queue
        let session = app.task(first)?.sessionID
        // Shown elsewhere, the first leaves memory; its digest stays.
        app.show(second)
        try await fixture.wait { app.conversation(second).isLoaded }
        #expect(!app.conversation(first).isLoaded)
        #expect(app.status(of: first)?.messageCount == (fixture.messages[first] ?? 0) / 3 * 2)
        #expect(app.drafts[first] == "half written")
        #expect(app.messageQueues[first]?.messages.map(\.text) == ["queued and paused"])
        // A conversation with a turn under way stays.
        app.runStates[second] = RunState(hasOutput: true)
        app.show(first)
        try await fixture.wait { app.conversation(first).isLoaded }
        #expect(app.conversation(second).isLoaded)
        app.runStates[second] = nil
        // Back again: the same history, in order, and the same session.
        #expect(app.thread(first).map(\.id) == fixture.initial[first]?.map(\.id))
        #expect(app.task(first)?.sessionID == session)
        #expect(app.drafts[first] == "half written")
    }

    @Test func homeReportsOnItsTasksFromTheirDigestsWithoutReadingThem() async throws {
        let fixture = try HistoryFixture(bots: 1, openTasks: 4)
        defer { fixture.cleanUp() }
        // One task has no index yet, as before #109: it is made again, off the main thread.
        try FileManager.default.removeItem(at: fixture.botHome(0).indexURL(task: fixture.task(0, 3).taskID))
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        let home = fixture.home(0)
        app.send("How are the tasks going?", to: home)
        try await fixture.wait { app.thread(home).last?.text.hasPrefix("reply:") == true }
        let prompt = try #require(try fixture.calls(home).last?.last)
        for index in 0..<4 {
            let task = try #require(app.task(fixture.task(0, index)))
            #expect(prompt.contains("“\(task.title)”"))
            #expect(prompt.contains("Its last reply: “Answer \((fixture.turns - 1)) of \(task.title)”"))
            #expect(!app.conversation(fixture.task(0, index)).isLoaded)
        }
        // No task's transcript went into memory; the one without an index was read once, for it.
        #expect(Set(fixture.decodedFiles.keys) == [fixture.transcript(home), fixture.transcript(fixture.task(0, 3))])
        #expect(fixture.botHome(0).readDigest(task: fixture.task(0, 3).taskID) != nil)
    }

    @Test func telegramRecognizesARepeatedMessageInAHomeNotYetRead() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let home = fixture.home(1)
        let id = try #require(fixture.initial[home]?.first(where: { $0.role == .user })?.id)
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        #expect(!app.conversation(home).isLoaded)
        app.telegram.readToken = { "123:AAFakeTokenForTestsOnly" }
        app.telegram.transport = BridgeTelegramStandIn([])
        fixture.settings.telegramChats = [TelegramChat(id: 42, botID: home.botID)]
        fixture.settings.telegramEnabled = true
        app.telegram.restart()
        // The settings' own restart, as the gateway observes them.
        try await Task.sleep(for: .milliseconds(100))
        let connection = app.telegram.connection()
        #expect(await connection.deliver("Question 0", id: id, to: home.botID, from: 42) == .duplicate)
        #expect(app.conversation(home).isLoaded)
        #expect(app.messageQueues[home]?.messages.isEmpty ?? true)
        #expect(!fixture.ran(home))
        fixture.settings.telegramEnabled = false
    }
}

/// Stops reads and recoveries of chosen conversations until opened, as a slow disk would.
final class LaneGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var closed: Set<String> = []

    func close(_ lane: String) {
        condition.lock()
        closed.insert(lane)
        condition.unlock()
    }

    func open(_ lane: String) {
        condition.lock()
        closed.remove(lane)
        condition.broadcast()
        condition.unlock()
    }

    func pass(_ work: StorageQueue.Work) {
        guard ["read", "recover"].contains(work.label) else { return }
        condition.lock()
        while closed.contains(work.lane) { condition.wait() }
        condition.unlock()
    }
}

/// Bots with Homes, open and closed tasks and sub-agents on disk, written as BotChu writes them
/// (with their indexes), and a stand-in Codex that answers each message.
@MainActor final class HistoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-history-\(UUID().uuidString)")
    let domain = "local.BotChu.HistoryTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let gate = LaneGate()
    let turns = 12
    private(set) var bots: [Bot] = []
    private(set) var openTasks: [[BotTask]] = []
    private(set) var initial: [ChatTarget: [ChatMessage]] = [:]
    var messages: [ChatTarget: Int] { initial.mapValues(\.count) }
    var open: [ChatTarget] { bots.indices.flatMap { b in [home(b)] + openTasks[b].indices.map { task(b, $0) } } }
    private(set) var interrupted = UUID()
    private(set) var finished = UUID()
    private(set) var interruptedThread = URL(fileURLWithPath: "/")
    private(set) var app: AppModel?

    init(bots count: Int = 2, openTasks perBot: Int = 2, closedTasks: Int = 1, children: Bool = false) throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        let script = root.appendingPathComponent("cli.py")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        settings.commands["codex-dev"] = "/usr/bin/python3 \(Shell.quote(script.path))"
        var entries: [Store.Entry] = []
        for b in 0..<count {
            let bot = Bot(name: "Bot \(b)", accountID: "codex-dev", workspace: root.appendingPathComponent("bot-\(b)").path)
            let home = BotHome(workspace: bot.workspace)
            try home.save(bot)
            bots.append(bot)
            entries.append(Store.Entry(id: bot.id, workspace: bot.workspace))
            try write(Self.thread(turns, title: "Home \(b)"), to: .home(bot.id), task: nil)
            var tasks: [BotTask] = []
            for t in 0..<perBot {
                var task = BotTask(for: bot, repo: "fixture/repo-\(b)-\(t)", checkout: root.path, work: nil, brief: "Open \(b).\(t)")
                task.folder = root.appendingPathComponent("work-\(b)-\(t)").path
                task.createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(t))
                try FileManager.default.createDirectory(atPath: task.folder!, withIntermediateDirectories: true)
                try home.save(task)
                try write(Self.thread(turns, title: task.title), to: .task(task.id, of: bot.id), task: task.id)
                tasks.append(task)
            }
            openTasks.append(tasks)
            try addClosedTasks(closedTasks, to: b)
        }
        try store.saveIndex(entries)
        if children { try addChildren() }
    }

    /// A finished sub-agent under the first Home and one under an open task, and one a relaunch
    /// interrupted, under a closed task.
    private func addChildren() throws {
        let home = botHome(0)
        let helper = Bot(name: "Helper", workspace: root.appendingPathComponent("helper").path)
        guard let closed = home.loadTasks().first(where: \.isArchived) else { throw CocoaError(.fileNoSuchFile) }
        for (taskID, phase) in [(nil, SubagentPhase.completed), (openTasks[0][0].id, .completed), (closed.id, .running)] as [(UUID?, SubagentPhase)] {
            var run = SubagentRun(rootBotID: bots[0].id, rootTaskID: taskID, depth: 1, targetBot: helper, title: "Child", brief: "Look",
                                  workingDirectory: bots[0].workspace, phase: phase)
            run.startedAt = .now
            if phase == .completed {
                run.finishedAt = .now
                run.handoffOutput = "Done."
                finished = run.id
            } else {
                interrupted = run.id
                interruptedThread = home.subagentURL(id: run.id, taskID: taskID).appendingPathComponent("thread.jsonl")
            }
            try home.saveSubagent(run)
            try home.saveSubagentThread(Self.thread(4, title: "child"), id: run.id, taskID: taskID)
        }
    }

    func addClosedTasks(_ count: Int, to b: Int = 0) throws {
        let home = botHome(b)
        for c in 0..<count {
            var task = BotTask(for: bots[b], repo: "fixture/closed-\(b)-\(c)-\(UUID().uuidString.prefix(4))", checkout: root.path, work: nil,
                               brief: "Closed \(c)")
            task.archivedAt = .now
            try home.save(task)
            try home.writeTranscript(Self.thread(turns * 2, title: task.title), task: task.id)
        }
    }

    private func write(_ thread: [ChatMessage], to target: ChatTarget, task: UUID?) throws {
        try botHome(bots.firstIndex { $0.id == target.botID }!).writeTranscript(thread, task: task)
        initial[target] = thread
    }

    func launch() -> AppModel {
        HistoryCounters.shared.reset(under: root)
        let made = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") },
                            storage: StorageQueue(before: gate.pass))
        app = made
        return made
    }

    func home(_ b: Int) -> ChatTarget { .home(bots[b].id) }
    func task(_ b: Int, _ t: Int) -> ChatTarget { .task(openTasks[b][t].id, of: bots[b].id) }
    func botHome(_ b: Int) -> BotHome { BotHome(workspace: app?.bot(bots[b].id)?.workspace ?? bots[b].workspace) }
    func lane(_ target: ChatTarget) -> String? {
        guard let b = bots.firstIndex(where: { $0.id == target.botID }) else { return nil }
        return botHome(b).conversationLane(task: target.taskID)
    }
    func transcript(_ target: ChatTarget) -> String {
        botHome(bots.firstIndex { $0.id == target.botID }!).transcriptURL(task: target.taskID).path
    }
    func disk(_ target: ChatTarget) -> [ChatMessage] {
        let home = botHome(bots.firstIndex { $0.id == target.botID }!)
        return target.taskID.map { home.loadThread(task: $0) } ?? home.loadThread()
    }
    var counts: HistoryCounters.Counts { HistoryCounters.shared.counts(under: root) }
    var decodedFiles: [String: Int] { HistoryCounters.shared.decodedFiles(under: root) }

    private func folder(_ target: ChatTarget) -> URL {
        URL(fileURLWithPath: app?.task(target)?.folder ?? app?.bot(target.botID)?.workspace ?? root.path)
    }
    func calls(_ target: ChatTarget) throws -> [[String]] {
        let text = try String(contentsOf: folder(target).appendingPathComponent("calls.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }
    func ran(_ target: ChatTarget) -> Bool { FileManager.default.fileExists(atPath: folder(target).appendingPathComponent("calls.jsonl").path) }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting")
        throw CocoaError(.executableLoad)
    }

    func cleanUp() {
        app?.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    /// `turns` of a question, a read and an answer, each third message the bot's reply.
    static func thread(_ turns: Int, title: String) -> [ChatMessage] {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return (0..<turns).flatMap { turn -> [ChatMessage] in
            let at = start.addingTimeInterval(Double(turn) * 30)
            return [ChatMessage(role: .user, text: "Question \(turn)", date: at),
                    ChatMessage(role: .tool, date: at.addingTimeInterval(1), toolID: "t\(turn)", toolName: "Read", toolInput: "/tmp/f\(turn)",
                                toolOutput: String(repeating: "output line\n", count: 20), toolState: .done),
                    ChatMessage(role: .assistant, text: "Answer \(turn) of \(title)", date: at.addingTimeInterval(2))]
        }
    }

    static let script = #"""
    import json, sys
    def emit(value):
        print(json.dumps(value), flush=True)
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    emit({"type":"thread.started", "thread_id":"history-session"})
    prompt = sys.argv[-1]
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":"reply:" + prompt.splitlines()[-1]}})
    emit({"type":"turn.completed"})
    """#
}
