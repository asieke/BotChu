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

    /// #77: a message the CLI took stays apart from unsent ones, so recovery never sends it again.
    @Test func takenMessagesAreNeverSentAgainAndGoBackIntoTheTranscript() {
        let start = ChatMessage(role: .user, text: "Fix the build")
        let steer = ChatMessage(role: .user, text: "Also run the tests")
        let later = ChatMessage(role: .user, text: "Then update the README")
        var queue = MessageQueue()
        queue.enqueue(steer)
        queue.enqueue(later)
        queue.markInFlight(steer.id)
        let taken = queue.acknowledge()
        #expect(taken == steer)
        #expect(queue.taken == [steer])
        #expect(queue.next == later)
        // A transcript that doesn't hold it keeps it taken; one that does lets it go.
        queue.saved([start])
        #expect(queue.taken == [steer])
        queue.saved([start, steer])
        #expect(queue.taken.isEmpty)

        // BotChu stopped between writing the taken and the pending messages: it is in both.
        let both = MessageQueue(saved: [steer, later], taken: [steer, steer], delivered: [start])
        #expect(both.taken == [steer])
        #expect(both.messages == [later])
        #expect(both.next == later)
        let restored = both.restoringTaken(into: [start])
        #expect(restored.map(\.id).prefix(2) == [start.id, steer.id])
        #expect(restored.count == 3)
        #expect(restored.last?.role == .note)
        #expect(restored.last?.text.hasPrefix("The bot took this message before BotChu could save") == true)
        // Saved in the transcript, but not the queue after it: nothing to restore.
        let delivered = MessageQueue(saved: [later], taken: [steer], delivered: [start, steer])
        #expect(delivered.taken.isEmpty)
        #expect(delivered.restoringTaken(into: [start, steer]).map(\.id) == [start.id, steer.id])
    }

    /// #77: saving the transcript fails (its file is locked) while saving the queue works. The
    /// message the CLI took stays in the saved queue, the rest pause, and a relaunch puts it back
    /// into the transcript once it can be saved, without sending it again. Home and a task.
    @Test(arguments: [false, true]) func takenFollowUpSurvivesAFailedTranscriptSaveAndARelaunch(inTask: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = BotHome(workspace: root.path)
        let task: UUID? = inTask ? UUID() : nil
        let file = task.map(home.taskThreadURL) ?? home.threadURL
        func lock(_ locked: Bool) throws { try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: file.path) }
        func savedTranscript() -> [ChatMessage] { task.map { home.loadThread(task: $0) } ?? home.loadThread() }
        defer {
            try? lock(false)
            try? FileManager.default.removeItem(at: root)
        }
        let earlier = [ChatMessage(role: .user, text: "Fix the build"), ChatMessage(role: .assistant, text: "On it")]
        var queue = MessageQueue()
        #expect(home.checkpoint(earlier, queue: &queue, task: task).saved)
        let steer = ChatMessage(role: .user, text: "Also run the tests")
        let later = ChatMessage(role: .user, text: "Then update the README")
        queue.enqueue(steer)
        queue.enqueue(later)
        try home.saveQueue(queue, task: task)
        queue.markInFlight(steer.id)
        let taken = queue.acknowledge()
        #expect(taken == steer)

        try lock(true)
        let failed = home.checkpoint(earlier + [steer], queue: &queue, task: task)
        #expect(!failed.saved)
        #expect(failed.failures.map(\.item) == [.conversation(paused: true)])
        #expect(failed.failures.first?.file == file)
        let message = try #require(failed.failures.first?.message)
        #expect(message.hasPrefix("Couldn't save this conversation ("))
        #expect(message.contains("thread.jsonl"))
        #expect(message.contains("aren't sent again. Pending messages wait for Send next."))
        #expect(!message.contains(".."))
        #expect(queue.taken == [steer])
        #expect(queue.isPaused)
        #expect(queue.next == nil)
        // Both durable copies: the transcript as last saved, and the queue with the taken message.
        #expect(savedTranscript().map(\.id) == earlier.map(\.id))
        #expect(home.loadQueuedMessages(task: task).map(\.id) == [later.id])
        #expect(home.loadQueuePaused(task: task))
        #expect(home.loadQueue(delivered: savedTranscript(), task: task).taken.map(\.id) == [steer.id])

        // Relaunch while the transcript still can't be saved: neither lost nor sent again.
        var transcript = savedTranscript()
        var relaunch = home.recoverQueue(transcript: &transcript, task: task)
        #expect(relaunch.queue.taken.map(\.id) == [steer.id])
        #expect(relaunch.queue.messages.map(\.id) == [later.id])
        #expect(relaunch.queue.next == nil)
        #expect(relaunch.failures.map(\.item) == [.conversation(paused: true)])
        #expect(Array(transcript.map(\.id).prefix(3)) == (earlier + [steer]).map(\.id))
        #expect(savedTranscript().map(\.id) == earlier.map(\.id))
        #expect(home.loadQueue(delivered: savedTranscript(), task: task).taken.map(\.id) == [steer.id])

        // Once it can be saved, the next relaunch puts the message back into the transcript, once,
        // and leaves only the unsent message, still paused, to send.
        try lock(false)
        transcript = savedTranscript()
        relaunch = home.recoverQueue(transcript: &transcript, task: task)
        #expect(relaunch.failures.isEmpty)
        #expect(transcript.map(\.role) == [.user, .assistant, .user, .note])
        #expect(Array(transcript.map(\.id).prefix(3)) == (earlier + [steer]).map(\.id))
        #expect(savedTranscript().map(\.id) == transcript.map(\.id))
        #expect(relaunch.queue.taken.isEmpty)
        #expect(relaunch.queue.messages.map(\.id) == [later.id])
        #expect(relaunch.queue.isPaused)
        #expect(!FileManager.default.fileExists(atPath: (task.map(home.taskURL) ?? home.url).appendingPathComponent("taken.jsonl").path))
        transcript = savedTranscript()
        let again = home.recoverQueue(transcript: &transcript, task: task)
        #expect(again.queue.taken.isEmpty)
        #expect(transcript.map(\.id) == savedTranscript().map(\.id))
    }

    /// #77: the next transcript save that works, such as the one at the turn's end, takes the
    /// message out of the saved queue; a failure with nothing taken doesn't touch the queue.
    @Test func laterSavedTranscriptReleasesTheTakenMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = BotHome(workspace: root.path)
        func lock(_ locked: Bool) throws { try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: home.threadURL.path) }
        defer {
            try? lock(false)
            try? FileManager.default.removeItem(at: root)
        }
        let earlier = [ChatMessage(role: .user, text: "Fix the build")]
        var queue = MessageQueue()
        #expect(home.checkpoint(earlier, queue: &queue).saved)
        try lock(true)
        let untouched = home.checkpoint(earlier, queue: &queue)
        #expect(!untouched.saved)
        #expect(untouched.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.queueURL().path))

        let steer = ChatMessage(role: .user, text: "Also run the tests")
        queue.enqueue(steer)
        queue.markInFlight(steer.id)
        _ = queue.acknowledge()
        let failed = home.checkpoint(earlier + [steer], queue: &queue)
        // Nothing left to pause.
        #expect(failed.failures.map(\.item) == [.conversation(paused: false)])
        #expect(failed.failures.first?.message.contains("Send next") == false)
        #expect(!home.loadQueuePaused())
        #expect(home.loadQueue(delivered: home.loadThread()).taken.map(\.id) == [steer.id])

        try lock(false)
        let reply = ChatMessage(role: .assistant, text: "Tests pass")
        let later = home.checkpoint(earlier + [steer, reply], queue: &queue)
        #expect(later.saved)
        #expect(later.failures.isEmpty)
        #expect(queue.taken.isEmpty)
        #expect(home.loadThread().map(\.id) == (earlier + [steer, reply]).map(\.id))
        #expect(home.loadQueue(delivered: []).taken.isEmpty)
        #expect(home.loadQueuedMessages().isEmpty)
    }

    /// #77: when the queue can't be saved either, that is said too.
    @Test func failedQueueSaveIsReportedWithItsFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = BotHome(workspace: root.path)
        let task = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        var queue = MessageQueue()
        let steer = ChatMessage(role: .user, text: "Also run the tests")
        queue.enqueue(steer)
        queue.markInFlight(steer.id)
        _ = queue.acknowledge()
        // Neither file can be written: each is a folder.
        try FileManager.default.createDirectory(at: home.taskThreadURL(task), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.taskURL(task).appendingPathComponent("taken.jsonl"), withIntermediateDirectories: true)
        let failed = home.checkpoint([steer], queue: &queue, task: task)
        #expect(failed.failures.map(\.item) == [.conversation(paused: false), .pendingMessages])
        #expect(failed.failures.last?.file == home.queueURL(task: task))
        #expect(failed.failures.last?.message.hasPrefix("Couldn't save pending messages (") == true)
        #expect(queue.taken == [steer])
    }

    /// #107: a message is sent only once a saved queue holds it, and one starting a turn shows in the
    /// conversation, stays saved in the queue until a saved transcript holds it, and can't be taken back.
    @Test func unsavedAndStartingMessagesAreHeldBackUntilTheirSavesAreDone() {
        let first = ChatMessage(role: .user, text: "Start")
        let second = ChatMessage(role: .user, text: "Then this")
        var queue = MessageQueue()
        queue.enqueue(first, unsaved: true)
        queue.enqueue(second)
        #expect(queue.next == second, "Not sent before a saved queue holds it")
        queue.accepted(first.id)
        #expect(queue.next == first)
        queue.deliver(first.id)
        #expect(queue.pending == [second], "It shows in the conversation now, not the queue")
        #expect(queue.messages == [first, second], "Still saved with the queue")
        #expect(queue.next == second)
        queue.remove(first.id)
        #expect(queue.messages.contains(first), "Starting a turn: it can't be taken back")
        // Its transcript couldn't be saved: it waits again, first.
        queue.undeliver(first.id)
        #expect(queue.next == first)
        queue.deliver(first.id)
        // A transcript that doesn't hold it leaves it; one that does takes it out of the queue.
        queue.saved([ChatMessage(role: .note, text: "Other")])
        #expect(queue.delivering == [first.id])
        queue.saved([first])
        #expect(queue.messages == [second])
        #expect(queue.delivering.isEmpty)
    }

    @Test func aRemovalThatCantBeSavedPutsTheMessageBackWhereItWas() {
        let messages = ["one", "two", "three"].map { ChatMessage(role: .user, text: $0) }
        var queue = MessageQueue()
        for message in messages { queue.enqueue(message) }
        queue.remove(messages[1].id)
        queue.restore(messages[1], at: 1)
        #expect(queue.messages == messages)
        queue.restore(messages[1], at: 0)
        #expect(queue.messages == messages, "Never twice")
    }
}
