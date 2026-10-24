import Foundation

/// How tall a growing writing area is, such as the message box, and how far its text may scroll. It
/// grows with its text from `minHeight` to `maxHeight`, then scrolls.
///
/// Its text view grows the moment a line is added, before the area around it does (SwiftUI lays it
/// out after the keystroke), so AppKit scrolled the new line into view and the first line out of it:
/// the text jumped up a line and back as it wrapped, or stayed clipped when the area kept its height
/// (#80). `scrollOffset` keeps the text at the top until it is taller than the area can grow.
public struct ComposerLayout: Equatable, Sendable {
    public var minHeight: Double
    public var maxHeight: Double
    /// Above and below the text.
    public var inset: Double

    public init(minHeight: Double, maxHeight: Double, inset: Double = 4) {
        self.minHeight = minHeight
        self.maxHeight = max(minHeight, maxHeight)
        self.inset = inset
    }

    /// Text laid out `textHeight` tall with the insets, rounded up to a whole point.
    public func contentHeight(forText textHeight: Double) -> Double {
        (textHeight + 2 * inset).rounded(.up)
    }

    /// The area's height for text laid out `textHeight` tall.
    public func height(forText textHeight: Double) -> Double {
        min(maxHeight, max(minHeight, contentHeight(forText: textHeight)))
    }

    /// Whether a text view this tall (at least the area's height, more when its text is) scrolls:
    /// only once it is taller than the area can grow.
    public func scrolls(documentHeight: Double) -> Bool {
        documentHeight > maxHeight + 0.5
    }

    /// Where the text may scroll to, from where AppKit would put it (`proposed`): not above its top,
    /// not past its end, and while it still fits the area at full height, not at all.
    public func scrollOffset(_ proposed: Double, documentHeight: Double, visibleHeight: Double) -> Double {
        min(max(0, proposed), max(0, documentHeight - max(visibleHeight, maxHeight)))
    }
}
