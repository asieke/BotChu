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

    @Test func recoveryPausesAndReconcilesMessagesSavedBeforeQueueRemoval() {
        let sent = ChatMessage(role: .user, text: "Already sent")
        let unsent = ChatMessage(role: .user, text: "Still waiting")
        var queue = MessageQueue(saved: [sent, unsent], delivered: [sent, ChatMessage(role: .assistant, text: "Reply")])
        #expect(queue.messages == [unsent])
        #expect(queue.isPaused)
        #expect(queue.next == nil)
        queue.enqueue(ChatMessage(role: .user, text: "One more"))
        #expect(queue.next == unsent)
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
