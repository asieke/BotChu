import Foundation
import Observation
import BotChuCore

/// One conversation's live state: its thread, the turn under way, its pet's short reaction, its
/// queue of follow-ups, its draft and whether it is unread. Each conversation is observed on its
/// own, so a turn streaming into one redraws only the views that read that conversation, never the
/// one shown beside it, and typing in one redraws only its composer.
///
/// Views read it through `AppModel`: `thread(_:)`, `status(of:)`, `isRunning(_:)`, `unread`, and
/// `runStates`, `messageQueues`, `reactions` and the drafts' fields, which read like dictionaries by
/// conversation. What a view reads of one conversation is all it observes.
@MainActor @Observable
final class ConversationState {
    /// The thread, oldest first. It changes through `load`, `replace`, `append`, `stream` and
    /// `edit`, which keep `summary` up to date.
    private(set) var messages: [ChatMessage] = []
    private(set) var historyStart = 0
    @ObservationIgnored private var pending: [UUID: PagedTranscript.Pending] = [:]
    @ObservationIgnored private(set) var prefixDigest = ThreadDigest([])
    @ObservationIgnored private var savedBase: [ChatMessage]? = []
    private(set) var browsing: HistoryLoad?
    var isPaging = false
    var reportDigest: ThreadDigest {
        guard isLoaded else { return digest ?? ThreadDigest([]) }
        let reply = messages.last(where: { $0.role == .assistant })?.text
        var result = ThreadDigest(summary: summary, count: historyStart + messages.count,
                                  lastReply: reply ?? prefixDigest.lastReply ?? digest?.lastReply,
                                  shellCount: prefixDigest.shellCount + ToolCounts(messages: messages).shell)
        if reply == nil { result.lastReplyCut = prefixDigest.lastReply != nil ? prefixDigest.lastReplyCut : (digest?.lastReplyCut ?? false) }
        return result
    }
    var displayMessages: [ChatMessage] {
        let tail = messages
        guard let browsing else { return tail }
        let latest = Dictionary(tail.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return browsing.messages.map { latest[$0.id] ?? pending[$0.id]?.message ?? $0 }
    }
    /// What the chat shows: `displayMessages`, then the message being sent (`sending`).
    var chatMessages: [ChatMessage] {
        let shown = displayMessages
        guard let sending, browsing == nil, shown.last?.id != sending.id else { return shown }
        return shown + [sending]
    }
    var displayStart: Int { browsing?.start ?? historyStart }
    var startsBotTurn: Bool {
        let previous = (browsing?.prefix ?? prefixDigest).summary.lastRole
        return previous != .assistant && previous != .tool
    }
    var hasLaterPage: Bool { browsing.map { $0.start + $0.messages.count < historyStart + messages.count } ?? false }
    var snapshot: PagedTranscript.Snapshot { .init(messages, start: historyStart, base: savedBase, pending: Array(pending.values)) }

    func load(_ history: HistoryLoad) {
        load(history.messages, summary: history.digest.summary)
        historyStart = history.start
        prefixDigest = history.prefix
        digest = history.digest
    }

    func browse(_ page: HistoryLoad) {
        var page = page
        let current = browsing?.messages ?? messages
        page.messages = Array((page.messages + current).prefix(PagedTranscript.browsingLimit))
        browsing = page
        epoch += 1
    }

    func pinDisplay() {
        guard browsing == nil else { return }
        let shown = Array(messages.suffix(PagedTranscript.browsingLimit))
        var prefix = prefixDigest
        let omitted = Array(messages.prefix(messages.count - shown.count))
        prefix.summary.extend(with: omitted, from: 0)
        prefix.count += omitted.count
        browsing = HistoryLoad(messages: shown, digest: ThreadDigest(summary: summary, count: historyStart + messages.count,
                                lastReply: messages.last(where: { $0.role == .assistant })?.text), bytes: 0, reindexed: false,
                                start: historyStart + messages.count - shown.count, prefix: prefix)
        epoch += 1
    }

    func browseLater(_ page: HistoryLoad) {
        guard var current = browsing else { return }
        let end = current.start + current.messages.count
        let overlap = max(0, end - page.start)
        current.messages += page.messages.dropFirst(overlap)
        let drop = max(0, current.messages.count - PagedTranscript.browsingLimit)
        current.prefix.summary.extend(with: Array(current.messages.prefix(drop)), from: 0)
        current.prefix.count += drop
        current.messages.removeFirst(drop)
        current.start += drop
        browsing = current
        epoch += 1
    }

    func showLatest() {
        guard browsing != nil else { return }
        browsing = nil
        epoch += 1
    }

    /// What a status reads from the thread. It changes when a message is added, not while a
    /// reply's text streams in, so a view that shows only the status isn't redrawn by every delta.
    private(set) var summary = ThreadSummary()
    /// Counts the changes other than a turn writing into the thread (`load`, `replace`, `edit`), after
    /// which the chat compares what it grouped with the thread again.
    private(set) var epoch = 0
    var run: RunState?
    var reaction: BotActivity?
    var queue: MessageQueue?
    /// The message sent to it while idle, shown at the chat's end from the moment it is sent, while
    /// its queue is saved; the turn then takes it into the thread in the same update
    /// (`AppModel.send`). Never saved: the thread holds a message only once its turn does.
    var sending: ChatMessage?
    /// Its turn ended while it wasn't shown.
    var unread = false
    /// What is typed in its message box and not sent yet, the agents and projects chosen in it from
    /// `@` and `#` completion (`Mentions.swift`), its images, a remote queue bot's documents
    /// (`addFiles`), and why the last attachment wasn't added. The text and references are kept
    /// between launches (`DraftStore`), written as they change through `AppModel.drafts` and
    /// `draftReferences`; the attachments only in memory.
    var draft: String?
    var draftReferences: [MessageReference]?
    var draftImages: [ImageAttachment]?
    var draftFiles: [FileAttachment]?
    var attachmentError: String?
    /// What the conversation is about, on the Activity tab (#320), and whether the one saved
    /// beside its transcript was read.
    var context: ConversationContext?
    @ObservationIgnored var contextRead = false
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
        historyStart = 0
        pending = [:]
        prefixDigest = ThreadDigest([])
        savedBase = messages
        browsing = nil
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
        digest = reportDigest
        revision += 1
        savedRevision = revision
        isLoaded = false
        messages = []
        savedBase = []
        pending = [:]
        browsing = nil
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

    /// Drop only payload confirmed on disk. An unresolved tool remains mutable, even across a
    /// very long turn. Browsing owns its own bounded window and never pins the live tail.
    func saved(_ revision: Int, snapshot: PagedTranscript.Snapshot) {
        saved(revision)
        for update in snapshot.pending {
            guard var current = pending[update.message.id] else { continue }
            current.base = update.message
            if let index = browsing?.messages.firstIndex(where: { $0.id == update.message.id }) {
                browsing?.messages[index] = update.message
            }
            pending[update.message.id] = current.message == update.message && current.message.toolState != .running ? nil : current
        }
        guard historyStart == snapshot.start else { return }
        savedBase = snapshot.messages
        let safe = min(snapshot.messages.count, messages.count) - PagedTranscript.residentLimit
        let keep = max(0, safe)
        guard keep > 0, messages.prefix(keep).elementsEqual(snapshot.messages.prefix(keep)) else { return }
        let dropped = Array(messages.prefix(keep))
        if var page = browsing {
            let committed = Dictionary(dropped.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            page.messages = page.messages.map { committed[$0.id] ?? $0 }
            browsing = page
        }
        for (offset, message) in dropped.enumerated() where message.toolState == .running {
            pending[message.id] = .init(position: historyStart + offset, message: message)
        }
        var summary = prefixDigest.summary
        summary.extend(with: dropped, from: 0)
        let priorCut = prefixDigest.lastReplyCut
        let droppedReply = dropped.last(where: { $0.role == .assistant })?.text
        prefixDigest = ThreadDigest(summary: summary, count: historyStart + keep,
                                    lastReply: droppedReply ?? prefixDigest.lastReply,
                                    shellCount: prefixDigest.shellCount + ToolCounts(messages: dropped).shell)
        if droppedReply == nil { prefixDigest.lastReplyCut = priorCut }
        historyStart += keep
        messages.removeFirst(keep)
        savedBase?.removeFirst(keep)
        // The frozen page has not changed. Invalidating its measured heights on every live
        // checkpoint would move a reader while unrelated output is saved below them.
        if browsing == nil { epoch += 1 }
    }

    /// The whole thread given anew. Given to a conversation not in memory, it is the thread now:
    /// no read under way is taken, and it is saved as any change is.
    func replace(_ messages: [ChatMessage]) {
        historyStart = 0
        pending = [:]
        prefixDigest = ThreadDigest([])
        savedBase = nil
        browsing = nil
        if !isLoaded {
            history.adopt()
            isLoaded = true
            digest = nil
        }
        revision += 1
        self.messages = messages
        epoch += 1
        summarize(combinedSummary())
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
        if pending.isEmpty { write(&messages) }
        else {
            let held = pending.values.sorted { $0.position < $1.position }
            var working = held.map(\.message) + messages
            write(&working)
            let ids = Set(held.map { $0.message.id })
            for message in working where ids.contains(message.id) {
                if let prior = pending[message.id]?.message {
                    prefixDigest.shellCount += ToolCounts(messages: [message]).shell - ToolCounts(messages: [prior]).shell
                }
                pending[message.id]?.message = message
            }
            messages = working.filter { !ids.contains($0.id) }
        }
        var summary = self.summary
        summary.extend(with: messages, from: start)
        summarize(summary)
    }

    /// Any other change to the thread.
    func edit(_ change: (inout [ChatMessage]) -> Void) {
        revision += 1
        change(&messages)
        epoch += 1
        summarize(combinedSummary())
    }

    private func combinedSummary() -> ThreadSummary {
        var value = prefixDigest.summary
        value.extend(with: messages, from: 0)
        return value
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
    /// Hears each conversation whose value is set, after it is (a draft, to save it).
    var changed: (@MainActor (ChatTarget) -> Void)?

    subscript(target: ChatTarget) -> Value? {
        get { model.conversation(target)[keyPath: field] }
        nonmutating set {
            model.conversation(target)[keyPath: field] = newValue
            changed?(target)
        }
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

/// One flag of every conversation, read and changed like the set of conversations it replaces
/// (`model.unread.contains(target)`), while each conversation is observed on its own.
@MainActor struct ConversationFlag {
    let model: AppModel
    let flag: ReferenceWritableKeyPath<ConversationState, Bool>

    func contains(_ target: ChatTarget) -> Bool { model.conversation(target)[keyPath: flag] }
    func insert(_ target: ChatTarget) { model.conversation(target)[keyPath: flag] = true }
    /// Clearing it makes no conversation that isn't there.
    func remove(_ target: ChatTarget) { model.conversations[target]?[keyPath: flag] = false }
}

/// One bot's tasks, observed apart from every other bot's.
@MainActor @Observable
final class BotTaskList {
    var tasks: [BotTask] = []
}

/// Each bot's tasks, read and written like the dictionary by bot it replaces (`model.tasks[botID]`),
/// while each bot's are observed on their own. Never nil: a bot without tasks has none, and nil
/// empties its list.
@MainActor struct BotTasks {
    let model: AppModel

    subscript(botID: UUID) -> [BotTask]? {
        get { model.taskList(botID).tasks }
        nonmutating set { model.taskList(botID).tasks = newValue ?? [] }
    }

    subscript(botID: UUID, default _: [BotTask]) -> [BotTask] {
        get { model.taskList(botID).tasks }
        nonmutating set { model.taskList(botID).tasks = newValue }
    }

    /// Every bot's. For the model's own work, not for views: it observes every bot's.
    var values: [[BotTask]] { model.taskLists.values.map(\.tasks) }
}
