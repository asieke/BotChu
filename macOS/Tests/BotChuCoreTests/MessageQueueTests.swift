import Foundation
import Testing
@testable import BotChuCore

@Suite struct MessageQueueTests {
    @Test func followUpsKeepOrderAndDoNotBecomeTranscriptUntilDelivered() {
        let first = ChatMessage(role: .user, text: "Also check the tests")
        let second = ChatMessage(role: .user, text: "Then update the README")
        var queue = MessageQueue()
        queue.enqueue(first)
        queue.enqueue(second)
        queue.finishTurn(stopped: false, failed: false)
        #expect(queue.next == first)
        queue.remove(first.id)
        #expect(queue.next == second)
        queue.remove(second.id)
        #expect(queue.next == nil)
    }

    @Test func stopAndFailureKeepPendingTextUntilExplicitlyResumed() {
        let message = ChatMessage(role: .user, text: "Follow up")
        for failed in [false, true] {
            var queue = MessageQueue()
            queue.enqueue(message)
            queue.finishTurn(stopped: !failed, failed: failed)
            #expect(queue.next == nil)
            #expect(queue.messages == [message])
            queue.resume()
            #expect(queue.next == message)
        }
    }

    @Test func recoveryPausesOnlyWhenThePauseWasSavedAndReconcilesDeliveredMessages() {
        let sent = ChatMessage(role: .user, text: "Already sent")
        let unsent = ChatMessage(role: .user, text: "Still waiting")
        let delivered = [sent, ChatMessage(role: .assistant, text: "Reply")]
        // #43: after a relaunch (every deploy restarts BotChu), recovered messages used to wait
        // for "Send next" forever. They go out on their own unless Stop or a failure paused them.
        let recovered = MessageQueue(saved: [sent, unsent], delivered: delivered)
        #expect(recovered.messages == [unsent])
        #expect(!recovered.isPaused)
        #expect(recovered.next == unsent)
        var paused = MessageQueue(saved: [sent, unsent], delivered: delivered, paused: true)
        #expect(paused.isPaused)
        #expect(paused.next == nil)
        paused.enqueue(ChatMessage(role: .user, text: "One more"))
        #expect(paused.next == unsent)
        #expect(!MessageQueue(saved: [sent], delivered: delivered, paused: true).isPaused)
    }

    /// #43: a turn the stream reported finished must not pause the queue because of an error it
    /// recovered from earlier (Codex reconnects) or a nonzero exit after it finished.
    @Test func onlyTheErrorATurnEndsWithCountsAsItsFailure() {
        var parser = CodexParser()
        var outcome = TurnOutcome()
        for line in [
            #"{"type":"thread.started","thread_id":"t"}"#,
            #"{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion)"}"#,
            #"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"Done"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ] {
            for event in parser.parse(line: line) { outcome.record(event) }
        }
        #expect(outcome.ended)
        #expect(outcome.failure(stopped: false, exitError: nil) == nil)
        // The exit status after a finished stream is not consulted at all.
        #expect(outcome.failure(stopped: false, exitError: "Codex exited with status 1") == nil)

        var failed = TurnOutcome()
        failed.record(.finished)
        failed.record(.failed("Usage limit reached"))
        #expect(failed.failure(stopped: false, exitError: nil) == "Usage limit reached")
        #expect(failed.failure(stopped: true, exitError: nil) == nil)

        // A stream that never ended fails with what BotChu reported about the exit.
        #expect(TurnOutcome().failure(stopped: false, exitError: "exited with status 1") == "exited with status 1")

        // A follow-up taken after the result is answered as more of the run, which must end again.
        var steered = TurnOutcome()
        steered.record(.finished)
        steered.record(.inputTaken)
        #expect(!steered.ended)
    }

    @Test func pausedQueueIsSavedBesideItsMessages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        let task = UUID()
        let message = ChatMessage(role: .user, text: "After Stop")
        try home.saveQueuedMessages([message], paused: true, task: task)
        #expect(home.loadQueuePaused(task: task))
        #expect(!home.loadQueuePaused())
        try home.saveQueuedMessages([message], task: task)
        #expect(!home.loadQueuePaused(task: task))
        // An empty queue has nothing to pause.
        try home.saveQueuedMessages([], paused: true)
        #expect(!home.loadQueuePaused())
    }

    @Test func followUpsInFlightLeaveTheQueueOnlyWhenTheCLITakesThem() {
        let first = ChatMessage(role: .user, text: "Also check the tests")
        let second = ChatMessage(role: .user, text: "And the README")
        var queue = MessageQueue()
        queue.enqueue(first)
        queue.enqueue(second)
        queue.markInFlight(first.id)
        // Written to the CLI: it can't be edited or removed, and isn't written again.
        #expect(queue.isInFlight(first.id))
        #expect(queue.next == second)
        queue.remove(first.id)
        #expect(queue.messages == [first, second])
        queue.markInFlight(second.id)
        #expect(queue.next == nil)
        let taken = queue.acknowledge()
        #expect(taken == first)
        #expect(queue.messages == [second])
        // The run ends before the CLI takes the second: it waits for the next turn, once.
        queue.finishTurn(stopped: false, failed: false)
        #expect(queue.inFlight.isEmpty)
        #expect(queue.next == second)
        let none = queue.acknowledge()
        #expect(none == nil)
        #expect(queue.messages == [second])
    }

    @Test func inputLedgerClosesTheCLIInputOnlyWhenNothingWrittenIsUntaken() {
        var ledger = InputLedger()
        // Nothing is written before the CLI shows it echoes, by echoing the prompt.
        #expect(!ledger.acceptsFollowUps)
        let prompt = ledger.taken()
        #expect(!prompt)
        #expect(ledger.acceptsFollowUps)
        ledger.wrote()
        ledger.wrote()
        let first = ledger.taken()
        #expect(first)
        // The turn ends with one follow-up untaken: the CLI takes it as its next turn.
        let closesEarly = ledger.turnEnded()
        #expect(!closesEarly)
        #expect(ledger.acceptsFollowUps)
        let second = ledger.taken()
        #expect(second)
        let closes = ledger.turnEnded()
        #expect(closes)
        #expect(!ledger.acceptsFollowUps)
        let stray = ledger.taken()
        #expect(!stray)

        // A CLI that never echoes is closed at the end of its turn and given no follow-ups.
        var silent = InputLedger()
        let silentCloses = silent.turnEnded()
        #expect(silentCloses)
        #expect(!silent.acceptsFollowUps)
    }

    @Test func enqueueIgnoresDuplicateAndEmptyMessages() {
        let message = ChatMessage(role: .user, text: "Never mind")
        var queue = MessageQueue()
        queue.enqueue(message)
        queue.enqueue(message)
        queue.enqueue(ChatMessage(role: .user, text: "  \n"))
        #expect(queue.messages.count == 1)
        queue.remove(message.id)
        #expect(queue.messages.isEmpty)
    }

    @Test func queuesStayWithTheirConversationAndMoveWithTheirBot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.appendingPathComponent("before").path)
        let task = UUID(), otherTask = UUID()
        let homeMessage = ChatMessage(role: .user, text: "Home")
        let taskMessage = ChatMessage(role: .user, text: "Task")
        try home.saveQueuedMessages([homeMessage])
        try home.saveQueuedMessages([taskMessage], task: task)
        #expect(home.loadQueuedMessages().map(\.id) == [homeMessage.id])
        #expect(home.loadQueuedMessages(task: task).map(\.id) == [taskMessage.id])
        #expect(home.loadQueuedMessages(task: otherTask).isEmpty)
        #expect(home.loadThread().isEmpty)
        let destination = root.appendingPathComponent("after").path
        try home.move(toWorkspace: destination)
        #expect(BotHome(workspace: destination).loadQueuedMessages(task: task).map(\.id) == [taskMessage.id])
    }
}
