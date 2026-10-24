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
    /// Counts the changes other than a turn writing into the thread (`load`, `replace`, `edit`), after
    /// which the chat compares what it grouped with the thread again.
    private(set) var epoch = 0
    var run: RunState?
    var reaction: BotActivity?
    var queue: MessageQueue?
    /// Whether the thread is in memory (#109). Until it is, the chat shows a spinner, not an empty
    /// conversation, and `summary` comes from its digest.
    private(set) var isLoaded = false
    /// Where its history is (`HistoryState`), and what waits for it: changes asked for while it
    /// isn't in memory or is being read or recovered, run in order once it is (`AppModel.later`).
    @ObservationIgnored var history = HistoryState()
    @ObservationIgnored var waiting: [Waiting] = []
    /// What waits is running (`AppModel.drain`): what it asks for in turn goes before the rest.
    @ObservationIgnored var draining = false
    @ObservationIgnored var insertion = 0
    /// What a task report reads of a thread that isn't in memory: its digest, from its index.
    @ObservationIgnored private(set) var digest: ThreadDigest?
    /// Which state of the thread this is, so a save of a state already written is skipped
    /// (`StorageQueue.replace`): this conversation's own id and a count of its changes.
    @ObservationIgnored private let id = UUID()
    @ObservationIgnored private(set) var revision = 0
    /// The latest state known to be on disk: read from it, or saved.
    @ObservationIgnored private(set) var savedRevision = 0
    var version: AnyHashable { AnyHashable([id.uuidString, String(revision)]) }
    /// Whether what is in memory is what was last read or saved.
    var isSaved: Bool { savedRevision == revision }

    struct Waiting {
        /// Its queue recovered; no read or recovery under way; its history in memory too.
        enum Need { case recovery, idle, history }
        var need: Need
        var run: () -> Void
        /// Runs instead when the conversation goes (its bot or task deleted).
        var cancel: (() -> Void)?
    }

    /// The thread as read from disk (or new, with nothing on disk yet).
    func load(_ messages: [ChatMessage], summary: ThreadSummary? = nil) {
        isLoaded = true
        revision += 1
        self.messages = messages
        epoch += 1
        summarize(summary ?? ThreadSummary(messages))
        savedRevision = revision
        digest = nil
    }

    /// A conversation made now, with nothing on disk yet.
    func start() {
        history = .created
        load([])
    }


    /// Drops the thread from memory, keeping its digest for the sidebar and task reports.
    func unload() {
        digest = ThreadDigest(summary: summary, count: messages.count, lastReply: messages.last(where: { $0.role == .assistant })?.text)
        revision += 1
        savedRevision = revision
        isLoaded = false
        messages = []
        epoch += 1
    }

    /// What its index says of a thread that isn't in memory.
    func know(_ digest: ThreadDigest) {
        guard !isLoaded else { return }
        self.digest = digest
        summarize(digest.summary)
    }

    /// A save of `revision` was written.
    func saved(_ revision: Int) {
        savedRevision = max(savedRevision, revision)
    }

    /// The whole thread given anew. Given to a conversation not in memory, it is the thread now:
    /// no read under way is taken, and it is saved as any change is.
    func replace(_ messages: [ChatMessage]) {
        if !isLoaded {
            history.adopt()
            isLoaded = true
            digest = nil
        }
        revision += 1
        self.messages = messages
        epoch += 1
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
        epoch += 1
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
