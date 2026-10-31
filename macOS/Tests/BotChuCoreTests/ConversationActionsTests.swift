import Foundation
import Testing
@testable import BotChuCore

@Suite @MainActor struct ConversationActionsTests {
    // Replaces HistoryLoadingTests.changesToAConversationNotInMemoryWaitForItAndKeepItsHistory (#391).
    @Test func deferredReceiptAndNoteFollowHistoryAndKeepTheirSaveOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = BotHome(workspace: folder.path)
        let original = ChatMessage(role: .user, text: "Earlier history")
        try home.saveThread([original])
        let actions = ConversationActions()
        var history = HistoryState.clean
        var loaded = false, unread = false
        var messages: [ChatMessage] = [], writes: [[String]] = []
        func save() {
            writes.append(messages.map(\.text))
            try! home.saveThread(messages)
        }
        func append(_ text: String, role: ChatMessage.Role) {
            if actions.later(needs: .history, history: history, loaded: loaded, { append(text, role: role) }) { return }
            messages.append(ChatMessage(role: role, text: text))
            save()
        }
        append("Receipt", role: .receipt)
        // postJobReceipt announces news immediately; reading its history must not clear it.
        unread = true
        append("Note", role: .note)
        #expect(actions.needsRead(history: history, loaded: loaded))
        let began = history.begin(load: true, recover: false)
        let ticket = try #require(began)
        actions.drain { (history, loaded) }
        #expect(writes.isEmpty)
        #expect(home.loadThread().map(\.id) == [original.id])
        messages = home.loadThread()
        loaded = true
        let finished = history.finish(ticket, loaded: true, recovered: false)
        #expect(finished)
        actions.drain { (history, loaded) }
        #expect(writes == [["Earlier history", "Receipt"], ["Earlier history", "Receipt", "Note"]])
        #expect(home.loadThread().map(\.text) == ["Earlier history", "Receipt", "Note"])
        #expect(unread && actions.waiting.isEmpty)
    }

    // Replaces sendsStopAndQueueEditsBeforeRecoveryKeepTheirOrderAndStartNothingStopped (#391).
    @Test func recoveryHoldsQueueChangesButAReadDoesNot() throws {
        let actions = ConversationActions()
        var history = HistoryState.clean
        let began = history.begin(load: true, recover: true)
        let ticket = try #require(began)
        var events: [String] = []
        for name in ["remove", "send", "stop"] {
            #expect(actions.later(needs: .recovery, history: history, loaded: false, { events.append(name) }))
        }
        actions.drain { (history, false) }
        #expect(events.isEmpty)
        let finished = history.finish(ticket, loaded: false, recovered: true)
        #expect(finished)
        _ = history.begin(load: true, recover: false)
        actions.drain { (history, false) }
        #expect(events == ["remove", "send", "stop"])
        #expect(!actions.later(needs: .recovery, history: history, loaded: false, {}))
        #expect(actions.later(needs: .history, history: history, loaded: false, {}))
        #expect(!actions.needsRead(history: history, loaded: false))
    }

    @Test func reentrantChangesGoBeforeWaitingPeersAndRecheckReadiness() throws {
        let actions = ConversationActions()
        var history = HistoryState.clean
        var events: [String] = []
        actions.later(needs: .history, history: history, loaded: false, {
            events.append("first")
            _ = history.begin(load: false, recover: true)
            actions.later(needs: .history, history: history, loaded: true, { events.append("nested") })
            #expect(!actions.drain { (history, true) })
        })
        actions.later(needs: .history, history: history, loaded: false, { events.append("second") })
        history = .created
        actions.drain { (history, true) }
        #expect(events == ["first"])
        history.took(loaded: true, recovered: true)
        actions.drain { (history, true) }
        #expect(events == ["first", "nested", "second"])
        #expect(actions.waiting.isEmpty)
    }

    // Replaces aMessageSentShowsAtOnceAndTheThreadTakesItOnlyWithItsTurn's Stop/save-failure cases (#391).
    @Test func stopAndFailedSaveWithdrawOnlyTheAppropriatePreview() {
        let message = ChatMessage(role: .user, text: "Sent"), newer = ChatMessage(role: .user, text: "Newer")
        var queue = MessageQueue()
        queue.enqueue(message, unsaved: true)
        var preview: ChatMessage? = message
        SendingPreview.clear(preview) { preview = nil }
        queue.pause()
        #expect(preview == nil && queue.messages.map(\.id) == [message.id] && queue.next == nil)
        // Failed save takes it out of the queue and chat; it never became transcript history.
        preview = message
        SendingPreview.clear(preview, matching: message.id) { preview = nil }
        queue.remove(message.id)
        #expect(preview == nil && queue.messages.isEmpty)
        preview = newer
        SendingPreview.clear(preview, matching: message.id) { preview = nil }
        #expect(preview?.id == newer.id)
        SendingPreview.clear(preview, matching: newer.id) { preview = nil }
        #expect(preview == nil)
    }

    @Test func deletionCancelsWaitingWorkWithoutRunningIt() {
        let actions = ConversationActions()
        var cancelled = 0, ran = false
        actions.later(needs: .history, history: .clean, loaded: false, { ran = true }, cancel: { cancelled += 1 })
        actions.cancel()
        actions.drain { (.created, true) }
        #expect(cancelled == 1 && !ran && actions.waiting.isEmpty)
    }
}
