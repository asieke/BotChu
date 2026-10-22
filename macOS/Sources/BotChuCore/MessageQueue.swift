import Foundation

/// Follow-ups for one conversation. Only delivered messages belong in its transcript; queued
/// messages keep their IDs when delivered so recovery cannot send them twice.
public struct MessageQueue: Equatable, Sendable {
    public private(set) var messages: [ChatMessage]
    public private(set) var isPaused: Bool

    /// Recovered messages wait for the owner. A crash between saving the transcript and saving
    /// the queue may leave an already-delivered message in both files.
    public init(saved: [ChatMessage] = [], delivered: [ChatMessage] = []) {
        let sent = Set(delivered.map(\.id))
        messages = saved.filter { $0.role == .user && !sent.contains($0.id) }
        isPaused = !messages.isEmpty
    }

    public var next: ChatMessage? { isPaused ? nil : messages.first }

    public mutating func enqueue(_ message: ChatMessage) {
        guard message.role == .user, (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty),
              !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        isPaused = false
    }

    public mutating func remove(_ id: UUID) {
        messages.removeAll { $0.id == id }
    }

    public mutating func resume() { isPaused = false }

    /// Stop, a failed turn, and app shutdown keep unsent text but withdraw automatic delivery.
    public mutating func pause() {
        isPaused = true
    }

    /// Called only after the old process and both output pipes have finished. Stop and failures
    /// always require the owner to resume the queue.
    public mutating func finishTurn(stopped: Bool, failed: Bool) {
        if failed || stopped { pause() }
    }
}
