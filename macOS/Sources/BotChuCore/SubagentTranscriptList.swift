import Foundation

/// What a sub-agent's Transcript in the Sub-agents tab lists (#361): its replies, tool calls and
/// errors, without empty replies or the provider's progress rows (Sail's submissions, which the
/// conversation itself still shows; one that failed is listed), and of those only the last `window`
/// until the reader asks for earlier ones, so a long run streaming in redraws a short list.
public struct SubagentTranscriptList: Sendable {
    public static let window = 12

    /// Everything listed, oldest first: what the count says.
    public let items: [ChatMessage]

    public init(_ messages: [ChatMessage], kind: AgentKind) {
        items = messages.filter { Self.isListed($0, kind: kind) }
    }

    public static func isListed(_ message: ChatMessage, kind: AgentKind) -> Bool {
        switch message.role {
        case .tool: kind != .sail || message.toolName != SailAgent.rowName || message.toolState == .failed
        // Looks only as far as the first character that isn't a space: a long reply isn't copied.
        case .assistant, .error: message.text.contains { !$0.isWhitespace }
        case .user, .note, .receipt: false
        }
    }

    /// Where the shown items start: where the reader asked, or the last `window` while following.
    public func start(pinned: Int?) -> Int {
        min(pinned ?? max(0, items.count - Self.window), items.count)
    }

    /// Where the shown items start in `pinned`, the same transcript once it is held still, after
    /// the reader asks for `earlier` more than the `shown` last ones it lists now.
    public static func start(showing earlier: Int, before shown: Int, in pinned: SubagentTranscriptList) -> Int {
        max(0, pinned.items.count - shown - earlier)
    }
}
