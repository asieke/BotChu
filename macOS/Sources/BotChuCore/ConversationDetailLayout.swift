import Foundation

/// The real contents of the conversation pane: the Project Areas column, the chat and the inspector.
/// These minima must agree with the views, or a native split can lay out outside its window (#354).
public enum ConversationDetailLayout {
    public static let chatMinimum = 300.0
    public static let inspectorWidths = 280.0...380.0
    public static let inspectorWidth = 380.0

    /// The chat and the Project Areas column beside it at the owner's width (`areasWidth`, clamped):
    /// the same for every bot, with areas or none (#407).
    public static func conversationMinimum(areasWidth: Double) -> Double {
        chatMinimum + ConversationColumnLayout.clamped(areasWidth)
    }

    public static func minimum(conversation: Double, showsInspector: Bool, divider: Double = 1) -> Double {
        conversation + (showsInspector ? inspectorWidths.lowerBound + divider : 0)
    }

    public static func clampedInspector(_ width: Double) -> Double {
        guard width.isFinite else { return inspectorWidth }
        return min(inspectorWidths.upperBound, max(inspectorWidths.lowerBound, width))
    }
}

/// The window's sidebar, a native split's first column (#437): its widths, and how it was left.
public enum WindowSidebarLayout {
    public static let widths = 210.0...320.0
    public static let width = 240.0
    /// AppKit keeps the split's frames under this name, across launches.
    public static let autosaveName = "BotChu.window.sidebar"
    /// Where SwiftUI's navigation split kept them before #437, read once so the width carries over.
    public static let legacyAutosaveName = "main-AppWindow-1, SidebarNavigationSplitView"

    public static func defaultsKey(autosaveName: String) -> String { "NSSplitView Subview Frames \(autosaveName)" }

    public struct Saved: Equatable, Sendable {
        public var width: Double
        public var collapsed: Bool

        public init(width: Double, collapsed: Bool) {
            self.width = width
            self.collapsed = collapsed
        }
    }

    /// The sidebar as AppKit saved it: one "x, y, width, height, collapsed, hidden" string per
    /// column, the sidebar's first. A collapsed sidebar saved without a width opens at the default.
    public static func saved(frames: [String]) -> Saved? {
        guard let first = frames.first else { return nil }
        let parts = first.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4, let width = Double(parts[2]), width.isFinite else { return nil }
        let collapsed = parts.count > 4 && parts[4] == "YES"
        return Saved(width: width >= 1 ? min(widths.upperBound, max(widths.lowerBound, width)) : Self.width, collapsed: collapsed)
    }

    /// How the sidebar opens: as the split saved it (`nil`, AppKit restores it), else as SwiftUI's
    /// split left it, else at the default width.
    public static func initial(saved: [String]?, legacy: [String]?) -> Saved? {
        guard saved == nil else { return nil }
        return legacy.flatMap(Self.saved(frames:)) ?? Saved(width: width, collapsed: false)
    }
}
