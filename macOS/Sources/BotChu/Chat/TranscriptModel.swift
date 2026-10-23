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
@MainActor @Observable
final class TranscriptModel {
    @ObservationIgnored private var transcript = ActivityTranscript()
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

    /// A rough cost, in milliseconds, of laying out an item the first time, from measurements on
    /// an M-series Mac: replies by their length and code blocks, which are the dearest; math and
    /// diagrams load a web view.
    static func layoutCost(_ item: ActivityItem) -> Double {
        switch item {
        case .message(let message):
            guard message.role == .assistant else { return 1 + 3 * Double(message.images.count) }
            let text = message.text
            let fences = text.components(separatedBy: "```").count - 1
            let rich = text.contains("$") || text.contains("\\(") || text.contains("```mermaid")
            return 2 + Double(text.utf8.count) / 400 + 2.5 * Double(fences) + (rich ? 15 : 0)
        case .exploration:
            return 2.5
        case .tool:
            return 1.5
        }
    }

    /// The conversation's items, updated for `messages`. Only the messages after the last settled
    /// item are looked at again.
    func items(for messages: [ChatMessage], root: String?) -> [ActivityItem] {
        if transcript.root != root { transcript = ActivityTranscript(root: root) }
        transcript.update(messages)
        return transcript.items
    }

    /// Where the shown part of `items` starts: the newest page, fewer when its replies are long.
    func start(of items: [ActivityItem]) -> Int {
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
    func follow(_ following: Bool, items: [ActivityItem]) {
        if !following {
            if windowStart == nil { windowStart = start(of: items) }
        } else if let windowStart, items.count - windowStart > Self.page * 2 {
            self.windowStart = nil
        }
    }

    func showEarlier(items: [ActivityItem]) {
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
