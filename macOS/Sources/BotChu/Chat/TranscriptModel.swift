import Foundation
import Observation
import BotChuCore

/// How much of the agents' tool work the chat shows (View ▸ Chat Density).
enum ChatDensity: String, CaseIterable, Identifiable {
    /// Headers only.
    case compact
    /// Headers, file chips and errors.
    case detailed
    /// Every call on its own, with its arguments, as before grouping.
    case raw

    static let storageKey = "chat.density"
    var id: Self { self }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .detailed: "Detailed"
        case .raw: "Raw"
        }
    }

    var symbol: String {
        switch self {
        case .compact: "rectangle.compress.vertical"
        case .detailed: "rectangle.expand.vertical"
        case .raw: "curlybraces"
        }
    }
}

/// One conversation as the chat shows it: its messages as activity items, regrouped a tail at a
/// time as they stream in (`ActivityTranscript`), the part of the history shown, and the groups and
/// cards opened or closed by hand. Lives as long as the chat view of that conversation.
///
/// A long conversation it hasn't grouped yet (never shown, or forgotten by `TranscriptCache`) is
/// grouped off the main thread: its newest messages show at once, and earlier items once the whole
/// is ready, so opening it never waits for its whole history.
@MainActor @Observable
final class TranscriptModel {
    @ObservationIgnored private var transcript = ActivityTranscript()
    @ObservationIgnored private var placement = SubagentCardsCache()
    /// The conversation's `epoch` at the last update: when it changes, the thread was replaced or
    /// edited, not only written into by a turn.
    @ObservationIgnored private var epoch: Int?
    @ObservationIgnored private var verifyNext = false
    /// Grouping the whole thread, off the main thread.
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// While it loads, the newest messages couldn't be grouped on their own: nothing shows yet.
    @ObservationIgnored private var holding = false
    /// Counts the loads finished, so the chat shows what they grouped.
    private var loaded = 0
    /// The first item shown; nil shows the newest `page`, following new ones.
    var windowStart: Int?
    /// Cards opened (true) or closed (false) by a click, overriding the density.
    var overrides: [UUID: Bool] = [:]

    /// How many more items each "Show earlier" adds, and the most the chat lays out at first.
    static let page = 40
    /// The fewest items shown at first, and roughly how many milliseconds of layout the first
    /// frame may take for its rows (`layoutCost`): a conversation of long replies with code opens
    /// with fewer rows, which still fill a couple of screens.
    static let firstItems = 8
    static let firstBudget = 60.0
    /// More messages to group than this, and the whole thread is grouped off the main thread, with
    /// about its newest `recentMessages` grouped at once.
    static let coldLimit = 600
    static let recentMessages = 300

    /// A rough cost, in milliseconds, of laying out an item the first time, from measurements on
    /// an M-series Mac: replies by their length and code blocks, which are the dearest; math and
    /// diagrams load a web view.
    static func layoutCost(_ item: ActivityItem) -> Double {
        switch item {
        case .message(let message):
            guard message.role == .assistant else { return 1 + 3 * Double(message.images.count) }
            let shape = MarkdownShape(message.text)
            return 2 + Double(shape.bytes) / 400 + 2.5 * Double(shape.fences) + (shape.mayBeRich ? 15 : 0)
        case .exploration:
            return 2.5
        case .tool:
            return 1.5
        }
    }

    /// Earlier items are still being grouped.
    var isLoadingEarlier: Bool { loading != nil }

    /// What the last update did, for tests.
    var lastWork: ActivityTranscript.Work { transcript.lastWork }
    /// How many times the cards' placement was worked out, for tests.
    var placementRebuilds: Int { placement.rebuilds }

    /// The conversation's items, updated for `messages`: only what changed since is looked at again.
    /// `epoch` is the conversation's (`ConversationState.epoch`).
    func items(for messages: [ChatMessage], root: String?, epoch: Int) -> ChunkedArray<ActivityItem> {
        _ = loaded
        if transcript.root != root {
            loading?.cancel()
            loading = nil
            holding = false
            transcript = ActivityTranscript(root: root)
        }
        if let last = self.epoch, last != epoch { verifyNext = true }
        self.epoch = epoch
        if loading == nil, transcript.backlog(messages) > Self.coldLimit { load(messages, root: root) }
        if holding { return [] }
        transcript.update(messages, verify: verifyNext)
        verifyNext = false
        return transcript.items
    }

    /// Groups the whole thread off the main thread; meanwhile its newest messages, from where an
    /// item starts, are grouped here.
    private func load(_ messages: [ChatMessage], root: String?) {
        if let start = ActivityTranscript.recentStart(in: messages, keeping: Self.recentMessages, scanning: Self.coldLimit) {
            transcript = ActivityTranscript(root: root, skipping: start, of: messages)
        } else {
            holding = true
        }
        let snapshot = messages
        loading = Task { [weak self] in
            let whole = await Task.detached(priority: .userInitiated) {
                var transcript = ActivityTranscript(root: root)
                transcript.update(snapshot)
                return transcript
            }.value
            guard let self, !Task.isCancelled else { return }
            self.adopt(whole)
        }
    }

    private func adopt(_ whole: ActivityTranscript) {
        // The shown part stays on the same items, now further down.
        if let windowStart, let first = transcript.items.first?.id, let offset = whole.items.firstIndex(where: { $0.id == first }) {
            self.windowStart = windowStart + offset
        }
        transcript = whole
        // The thread may have changed in any way meanwhile.
        verifyNext = true
        holding = false
        loading = nil
        loaded += 1
    }

    /// Which delegated runs show where, worked out again only when the calls that started them or
    /// their records change.
    func cards(runs: [SubagentRun]) -> SubagentCards {
        placement.cards(for: transcript, runs: runs)
    }

    /// Where the shown part of `items` starts: the newest page, fewer when its replies are long.
    func start(of items: ChunkedArray<ActivityItem>) -> Int {
        if let windowStart { return min(windowStart, max(0, items.count - 1)) }
        var index = items.count
        var cost = 0.0
        while index > 0, items.count - index < Self.page {
            cost += Self.layoutCost(items[index - 1])
            if items.count - index >= Self.firstItems, cost > Self.firstBudget { break }
            index -= 1
        }
        return index
    }

    /// While the reader looks at earlier content, the shown part stays where it is, so new items
    /// don't push what they read away. Back at the newest items, a part grown long slides again,
    /// dropping items far above the window.
    func follow(_ following: Bool, items: ChunkedArray<ActivityItem>) {
        if !following {
            if windowStart == nil { windowStart = start(of: items) }
        } else if let windowStart, items.count - windowStart > Self.page * 2 {
            self.windowStart = nil
        }
    }

    func showEarlier(items: ChunkedArray<ActivityItem>) {
        windowStart = max(0, start(of: items) - Self.page)
    }

    func isOpen(_ id: UUID, default open: Bool) -> Bool { overrides[id] ?? open }

    func toggle(_ id: UUID, default open: Bool) {
        overrides[id] = !(overrides[id] ?? open)
    }
}

/// Recent conversations' transcripts: switching back to one regroups only what arrived
/// meanwhile, and its opened cards stay open. A deleted bot's and a closed task's go, and so does
/// the least recently shown beyond `capacity`; one shown again is simply grouped again.
@MainActor
enum TranscriptCache {
    private static var models: [ChatTarget: TranscriptModel] = [:]
    /// The least recently shown first.
    private static var order: [ChatTarget] = []
    static let capacity = 48

    static func model(for target: ChatTarget) -> TranscriptModel {
        order.removeAll { $0 == target }
        order.append(target)
        if let model = models[target] { return model }
        let model = TranscriptModel()
        models[target] = model
        while order.count > capacity { models[order.removeFirst()] = nil }
        return model
    }

    static func contains(_ target: ChatTarget) -> Bool { models[target] != nil }

    static func forget(_ target: ChatTarget) {
        models[target] = nil
        order.removeAll { $0 == target }
    }

    /// Every conversation of a bot: its Home and its tasks.
    static func forget(bot id: UUID) {
        for target in order where target.botID == id { models[target] = nil }
        order.removeAll { $0.botID == id }
    }
}

/// A sub-agent to show in the status sidebar's Sub-agents tab: the chat's Open sets it, and the tab
/// expands that run and scrolls to it.
@MainActor @Observable
final class SubagentFocus {
    static let shared = SubagentFocus()
    private(set) var runID: UUID?
    /// Changes with every request, so asking for the same run again still scrolls to it.
    private(set) var ticket = 0

    func focus(_ id: UUID) {
        runID = id
        ticket += 1
    }

    /// The run, once: the tab that shows it takes it.
    func take(from runs: [SubagentRun]) -> UUID? {
        guard let runID, runs.contains(where: { $0.id == runID }) else { return nil }
        self.runID = nil
        return runID
    }
}
