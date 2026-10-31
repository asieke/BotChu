import Foundation

/// Which of a pasteboard item's types a paste gives a draft as an image (#64): the first image
/// type it offers ahead of any plain text, in the order its source wrote them. Copied text often
/// comes with a picture of itself after it (a spreadsheet's cells, say), and pastes as text; a
/// screenshot or a browser's Copy Image offers the picture alone, or first.
public enum PasteboardOrder {
    /// Plain text's type, `NSPasteboard.PasteboardType.string`.
    public static let plainText = "public.utf8-plain-text"

    /// The first of `types` that `isImage` says is an image, unless plain text comes before it.
    public static func image(in types: [String], isImage: (String) -> Bool) -> String? {
        for type in types {
            if type == plainText { return nil }
            if isImage(type) { return type }
        }
        return nil
    }
}
