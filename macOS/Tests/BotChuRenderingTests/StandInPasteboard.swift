import AppKit
import ObjectiveC

nonisolated(unsafe) private var standIn: NSPasteboard?

extension NSPasteboard {
    /// Once swapped in, what `NSPasteboard.general` gives.
    @objc fileprivate class func botchuStandInGeneral() -> NSPasteboard { standIn ?? .withUniqueName() }
}

/// A private pasteboard in place of the general one while a test pastes, so paste goes the way it
/// does in the app (Edit ▸ Paste's check included) and the owner's clipboard is never read or changed.
@MainActor final class StandInPasteboard {
    let board = NSPasteboard.withUniqueName()

    init() {
        standIn = board
        Self.swap()
    }

    func restore() {
        Self.swap()
        standIn = nil
        board.releaseGlobally()
    }

    private static func swap() {
        method_exchangeImplementations(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general))!,
                                       class_getClassMethod(NSPasteboard.self, #selector(NSPasteboard.botchuStandInGeneral))!)
    }
}
