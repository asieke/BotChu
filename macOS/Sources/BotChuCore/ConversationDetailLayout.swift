import Foundation

/// The real contents of the conversation pane: its chat, optional task column/rail, and inspector.
/// These minima must agree with the views, or a native split can lay out outside its window (#354).
public enum ConversationDetailLayout {
    public static let chatMinimum = 300.0
    public static let inspectorWidths = 280.0...380.0
    public static let inspectorWidth = 380.0

    public static func conversationMinimum(hasTasks: Bool, collapsed: Bool, taskWidth: Double) -> Double {
        chatMinimum + (hasTasks ? (collapsed ? ConversationColumnLayout.railWidth : ConversationColumnLayout.clamped(taskWidth)) : 0)
    }

    public static func minimum(conversation: Double, showsInspector: Bool, divider: Double = 1) -> Double {
        conversation + (showsInspector ? inspectorWidths.lowerBound + divider : 0)
    }

    public static func clampedInspector(_ width: Double) -> Double {
        guard width.isFinite else { return inspectorWidth }
        return min(inspectorWidths.upperBound, max(inspectorWidths.lowerBound, width))
    }
}
