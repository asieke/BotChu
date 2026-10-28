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
    @Test func pinningAnUnsavedExplorationKeepsTheSelectedCallInPlace() throws {
        let state = ConversationState(), model = TranscriptModel()
        let calls = (0..<600).map(BrowsingFixture.read)
        state.replace(calls)
        var items = model.items(for: state.displayMessages, root: nil, epoch: state.epoch)
        model.scrolled(top: 0, height: 800, width: 640)
        let inputs = TranscriptViewport.Inputs(width: 640, density: 2, dark: false, epoch: state.epoch)
        _ = model.plan(items, from: 0, inputs: inputs) { _, _ in .init(split: .calls) }
        model.follow(.openedCard)
        model.scrolled(top: model.viewport.plan.total * 0.75, height: 800, width: 640)
        _ = model.plan(items, from: 0, inputs: inputs) { _, _ in .init(split: .calls) }
        let top = try #require(model.viewport.visibleTop)
        let row = try #require(model.viewport.plan.rows.first { $0.top + $0.height > top })
        let selected = calls[row.part].id, offset = row.top - top
        model.toggleExpanded(selected)
        // A burst can exceed the browsing limit before its first checkpoint. Pinning the view
        // then changes a group's first resident call just as a disk page does.
        state.pinDisplay()
        items = model.items(for: state.displayMessages, root: nil, epoch: state.epoch)
        _ = model.plan(items, from: 0, inputs: .init(width: 640, density: 2, dark: false, epoch: state.epoch)) { _, _ in .init(split: .calls) }
        let moved = try #require(model.viewport.plan.rows.first { BrowsingFixture.messages(in: $0, items: items).contains(selected) })
        let corrected = model.viewport.correction ?? top
        #expect(abs(moved.top - corrected - offset) < 0.5)
        #expect(model.isExpanded(selected))
        #expect(state.displayMessages.count == PagedTranscript.browsingLimit)
        #expect(state.messages.count == calls.count, "Unsaved output is still retained for its checkpoint")
    }

    @Test func aSubagentReaderKeepsItsPageWhenTheActiveTailIsTrimmed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-subagent-page-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        let run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: Bot(name: "Worker", workspace: root.path),
                              title: "Paged", brief: "Work", workingDirectory: root.path)
        let live = SubagentLive()
        live.messages = (0..<1_000).map { ChatMessage(role: .assistant, text: "Reply \($0)") }
        let first = SubagentArchive.Snapshot(record: run, messages: live.messages, home: home)
        try SubagentArchive.writeToDisk(first)
        live.saved(first)
        live.pinDisplay()
        live.update { $0[0].text += " updated before its checkpoint" }
        let selected = live.displayMessages
        live.update { $0 += (0..<1_000).map { ChatMessage(role: .assistant, text: "More \($0)") } }
        let next = SubagentArchive.Snapshot(record: run, messages: live.messages, home: home,
                                            start: live.historyStart, base: live.base)
        try SubagentArchive.writeToDisk(next)
        live.saved(next)
        #expect(live.messages.count == PagedTranscript.residentLimit)
        #expect(live.displayMessages == selected)
        #expect(live.hasLaterPage)
        let end = live.displayStart + live.displayMessages.count
        live.browseLater(try home.loadSubagentHistory(id: run.id, before: end + PagedTranscript.pageSize, limit: PagedTranscript.pageSize))
        #expect(live.displayMessages.contains { $0.id == selected.last?.id })
        #expect(live.displayMessages.count <= PagedTranscript.browsingLimit)
        #expect(home.loadSubagentThread(id: run.id).count == 2_000)
    }

    @Test func anEarlyRunningToolDoesNotPinCompletedPayloadAndItsLateResultKeepsItsPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-pending-page-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        let state = ConversationState()
        state.start()
        var assembler = ThreadAssembler()
        state.stream { assembler.apply(.toolStarted(id: "slow", name: "Bash", input: "slow command", arguments: nil), to: &$0) }
        let tool = try #require(state.messages.first)
        for i in 0..<5_000 { state.append(ChatMessage(role: .assistant, text: "Completed \(i)")) }
        let snapshot = state.snapshot
        try home.writeTranscript(snapshot)
        state.saved(state.revision, snapshot: snapshot)
        #expect(state.messages.count == PagedTranscript.residentLimit)
        #expect(state.snapshot.pending.map(\.message.id) == [tool.id])
        #expect(state.summary.toolCallCount == 1)
        let before = home.loadThread().map(\.id)
        state.stream { assembler.apply(.toolFinished(id: "slow", name: "Bash", output: "late result", isError: false, exitCode: 0), to: &$0) }
        let finished = state.snapshot
        try home.writeTranscript(finished)
        state.saved(state.revision, snapshot: finished)
        #expect(state.snapshot.pending.isEmpty)
        #expect(state.messages.count == PagedTranscript.residentLimit)
        let saved = home.loadThread()
        #expect(saved.map(\.id) == before)
        #expect(saved.first?.id == tool.id)
        #expect(saved.first?.toolOutput == "late result")
        #expect(saved.first?.toolState == .done)
    }

    @Test func pagingKeepsActiveAndBrowsedPayloadBoundedWithStableMessageAnchors() async throws {
        let fixture = try HistoryFixture(bots: 1, openTasks: 1, closedTasks: 0)
        defer { fixture.cleanUp() }
        let target = fixture.home(0), home = fixture.botHome(0)
        let messages = (0..<5_000).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "Message \($0): copy this complete text", date: Date(timeIntervalSince1970: 1_800_000_000)) }
        try home.saveThread(messages)
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        let state = app.conversation(target)
        #expect(state.messages == Array(messages.suffix(PagedTranscript.residentLimit)))
        #expect(state.summary.messageCount == 5_000)
        let transcript = TranscriptModel()
        var items = transcript.items(for: state.displayMessages, root: nil, epoch: state.epoch)
        transcript.windowStart = 0
        let anchor = try #require(items.first?.id)
        await withCheckedContinuation { done in app.pageEarlier(target) { done.resume() } }
        items = transcript.items(for: state.displayMessages, root: nil, epoch: state.epoch)
        #expect(items.contains { $0.id == anchor })
        #expect(items[transcript.windowStart ?? 0].id == anchor)
        for _ in 0..<12 {
            await withCheckedContinuation { done in app.pageEarlier(target) { done.resume() } }
            #expect(state.displayMessages.count <= PagedTranscript.browsingLimit)
            #expect(state.messages.count <= PagedTranscript.residentLimit)
        }
        // Forward scrolling requests the next page without jumping to the newest conversation.
        let earlierEnd = state.displayStart + state.displayMessages.count
        let forwardAnchor = state.displayMessages[state.displayMessages.count - 10].id
        await withCheckedContinuation { done in app.pageLater(target) { done.resume() } }
        #expect(state.displayStart + state.displayMessages.count == earlierEnd + PagedTranscript.pageSize)
        #expect(state.displayMessages.contains { $0.id == forwardAnchor })
        #expect(state.displayMessages.count <= PagedTranscript.browsingLimit)
        let old = state.displayMessages
        let displayEpoch = state.epoch
        // Appending/saving while an old page is selected leaves its IDs and selectable text alone.
        for i in 0..<1_000 { state.append(ChatMessage(role: .assistant, text: "Live \(i)")) }
        app.saveThread(target)
        await app.storage.settle()
        #expect(state.messages.count <= PagedTranscript.residentLimit)
        #expect(state.displayMessages == old)
        #expect(state.epoch == displayEpoch, "Saving an unrelated tail must not invalidate the reader's measured page")
        #expect(old.first?.text == messages[state.displayStart].text)
        let requested = try #require(await app.loadedThread(target))
        #expect(requested.count == 6_000)
        #expect(Array(requested.prefix(5_000)) == messages)
        #expect(state.messages.count <= PagedTranscript.residentLimit)
        state.showLatest()
        transcript.follow(.jumped)
        let latest = transcript.items(for: state.displayMessages, root: nil, epoch: state.epoch)
        #expect(transcript.windowStart == nil)
        #expect(latest.last?.id == state.messages.last?.id)
        #expect(state.displayMessages.last?.text == "Live 999")
        #expect(home.loadThread().map(\.id) == requested.map(\.id))
    }

    @Test func aLaunchReadsTheShownConversationAndRecoveryAloneAndNoArchivedHistory() async throws {
        let fixture = try HistoryFixture(closedTasks: 2, children: true)
        defer { fixture.cleanUp() }
        // A closed task's queue stays as it is: it is recovered, and sent, only once the task opens again.
        let closed = try #require(fixture.closed.first)
        let queued = ChatMessage(role: .user, text: "for when it opens again")
        try fixture.botHome(0).saveQueue(MessageQueue(saved: [queued]), task: closed.taskID)
        let closedQueue = try Data(contentsOf: fixture.botHome(0).queueURL(task: closed.taskID))
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
        #expect(app.thread(fixture.home(0)).count == min(fixture.messages[fixture.home(0)] ?? 0, PagedTranscript.residentLimit))
        #expect(app.delegation.run(fixture.interrupted)?.phase == .stopped)
        #expect(app.delegation.run(fixture.finished)?.phase == .completed)
        #expect(fixture.counts.repairs == 0)
        #expect(fixture.counts.copies == 0)
        // Every other open conversation's sidebar status comes from its digest.
        for target in fixture.open where target != fixture.home(0) {
            #expect(!app.conversation(target).isLoaded)
            #expect(app.status(of: target)?.messageCount == (fixture.messages[target] ?? 0) / 3 * 2)
        }
        #expect(app.messageQueues[closed] == nil)
        #expect(try Data(contentsOf: fixture.botHome(0).queueURL(task: closed.taskID)) == closedQueue)
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

    @Test func stopWithdrawsATurnWaitingForItsConversationToBeRead() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.cleanUp() }
        let app = fixture.launch()
        defer { app.stopAll() }
        await app.storage.settle()
        let target = fixture.task(0, 0)
        let lane = try #require(fixture.lane(target))
        fixture.gate.close(lane)
        #expect(app.send("hold on", to: target))
        #expect(app.isRunning(target))
        // Queued and saved, its turn waits for the conversation to be read.
        try await fixture.wait { app.messageQueues[target]?.next?.text == "hold on" && app.runStates[target]?.preparing == true }
        app.stop(target)
        #expect(!app.isRunning(target))
        fixture.gate.open(lane)
        await app.storage.settle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.ran(target))
        #expect(!app.isRunning(target))
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["hold on"])
        #expect(app.messageQueues[target]?.isPaused == true)
        // Sent next, it goes once, after the whole history.
        app.resumeQueuedMessages(to: target)
        try await fixture.wait { app.thread(target).last?.text == "reply:hold on" }
        #expect(try fixture.calls(target).count == 1)
        #expect(fixture.disk(target).prefix(fixture.messages[target] ?? 0).map(\.id) == fixture.initial[target]?.map(\.id))
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
        #expect(fixture.disk(target).prefix(fixture.messages[target] ?? 0).map(\.id) == fixture.initial[target]?.map(\.id))
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
        #expect(await connection.deliver("Question 0", references: [], id: id, to: home.botID, from: 42, mapped: home.botID) == .duplicate)
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
    private(set) var closed: [ChatTarget] = []
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
            closed.append(.task(task.id, of: bots[b].id))
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
