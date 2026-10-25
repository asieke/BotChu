import Foundation

/// Whether a chat keeps its reader at the newest content (#131), as Claude, ChatGPT and Cursor
/// do: pinned, the chat stays at its end as replies stream, calls and groups grow, sub-agents report
/// and the window resizes; unpinned, nothing that arrives moves the reader.
///
/// Only the reader's own scrolling unpins it, and only scrolling toward the top that leaves the end:
/// the chat's own moves (to the end, or to keep a row in place) and the scroll view settling after
/// its content or size changed never do, however far from the end they land. Scrolling back to
/// within `nearEnd` of the end pins it again, and so do opening the conversation, sending a
/// message and Jump to Latest, wherever the reader was. A card opened by a click unpins it, so the
/// card grows from where it was clicked (#110).
public struct ChatPin: Equatable, Sendable {
    /// Scrolling toward the end that stops within this many points of it pins the chat again.
    public static let nearEnd = 40.0
    /// Scrolling toward the top that stops within this many points of the end keeps the chat
    /// pinned: the bounce of a scroll past the end, or a nudge.
    public static let slack = 2.0

    public enum Event: Equatable, Sendable {
        /// The conversation was opened or switched to.
        case opened
        /// The reader sent a message.
        case sent
        /// The reader asked for the newest content (Jump to Latest, Follow Live).
        case jumped
        /// The reader opened a card by clicking it.
        case openedCard
        /// The reader scrolled by `delta` points (negative: toward the top), leaving the end `below`
        /// points under the visible part (negative past it).
        case scrolled(delta: Double, below: Double)
    }

    public private(set) var isPinned: Bool

    public init(isPinned: Bool = true) {
        self.isPinned = isPinned
    }

    /// Applies what happened. True when the chat should go to its end now: it was opened or the
    /// reader asked for the newest content, wherever they were.
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        switch event {
        case .opened, .sent, .jumped:
            isPinned = true
            return true
        case .openedCard:
            isPinned = false
        case let .scrolled(delta, below):
            if delta < 0, below > Self.slack {
                isPinned = false
            } else if delta > 0, below <= Self.nearEnd {
                isPinned = true
            }
        }
        return false
    }

    /// Whether the chat should go to its end after its content or size changed, or something but
    /// the reader moved it, with the end `below` points under the visible part. Never while the
    /// reader is scrolling: the end waits until they let go.
    public func keepsEnd(below: Double, readerScrolling: Bool) -> Bool {
        isPinned && !readerScrolling && below > 0.5
    }
}
