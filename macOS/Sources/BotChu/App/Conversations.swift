import Foundation
import Observation
import BotChuCore

/// One conversation's live state: its thread, the turn under way, its pet's short reaction and its
/// queue of follow-ups. Each conversation is observed on its own, so a turn streaming into one
/// redraws only the views that read that conversation, never the one shown beside it.
///
/// Views read it through `AppModel`: `thread(_:)`, `status(of:)`, `isRunning(_:)`, and
/// `runStates`, `messageQueues` and `reactions`, which read like dictionaries by conversation.
/// What a view reads of one conversation is all it observes.
@MainActor @Observable
final class ConversationState {
    /// The thread, oldest first. It changes through `load`, `replace`, `append`, `stream` and
    /// `edit`, which keep `summary` up to date.
    private(set) var messages: [ChatMessage] = []
    /// What a status reads from the thread. It changes when a message is added, not while a
    /// reply's text streams in, so a view that shows only the status isn't redrawn by every delta.
    private(set) var summary = ThreadSummary()
    var run: RunState?
    var reaction: BotActivity?
    var queue: MessageQueue?
    /// Whether the thread was read: a closed task's isn't, at launch.
    @ObservationIgnored private(set) var isLoaded = false
    /// Which state of the thread this is, so a save of a state already written is skipped
    /// (`StorageQueue.replace`): this conversation's own id and a count of its changes.
    @ObservationIgnored private let id = UUID()
    @ObservationIgnored private var revision = 0
    var version: AnyHashable { AnyHashable([id.uuidString, String(revision)]) }

    func load(_ messages: [ChatMessage]) {
        isLoaded = true
        replace(messages)
    }

    func replace(_ messages: [ChatMessage]) {
        revision += 1
        self.messages = messages
        summarize(ThreadSummary(messages))
    }

    func append(_ message: ChatMessage) {
        revision += 1
        messages.append(message)
        var summary = self.summary
        summary.extend(with: messages, from: messages.count - 1)
        summarize(summary)
    }

    /// Writes a turn's output into the thread, in place: messages added at its end, and the reply
    /// or tool calls already in it written further, but none removed, reordered or given another
    /// role. `write` mustn't read or change this thread otherwise.
    func stream(_ write: (inout [ChatMessage]) -> Void) {
        revision += 1
        let start = messages.count
        write(&messages)
        var summary = self.summary
        summary.extend(with: messages, from: start)
        summarize(summary)
    }

    /// Any other change to the thread.
    func edit(_ change: (inout [ChatMessage]) -> Void) {
        revision += 1
        change(&messages)
        summarize(ThreadSummary(messages))
    }

    private func summarize(_ new: ThreadSummary) {
        if new != summary { summary = new }
    }
}

/// One field of every conversation, read and written like the dictionary by conversation it
/// replaces (`model.runStates[target]`), while each conversation is observed on its own.
@MainActor struct ConversationField<Value> {
    let model: AppModel
    let field: ReferenceWritableKeyPath<ConversationState, Value?>

    subscript(target: ChatTarget) -> Value? {
        get { model.conversation(target)[keyPath: field] }
        nonmutating set { model.conversation(target)[keyPath: field] = newValue }
    }

    /// The conversations that have one. For the model's own work, not for views: it can't see a
    /// conversation that gets one after it was read.
    var keys: [ChatTarget] {
        model.conversations.compactMap { $0.value[keyPath: field] == nil ? nil : $0.key }
    }

    /// How many conversations have one; like `keys`, not for views.
    var count: Int { model.conversations.values.filter { $0[keyPath: field] != nil }.count }
    var isEmpty: Bool { count == 0 }

    func removeAll() {
        for conversation in model.conversations.values where conversation[keyPath: field] != nil {
            conversation[keyPath: field] = nil
        }
    }
}
