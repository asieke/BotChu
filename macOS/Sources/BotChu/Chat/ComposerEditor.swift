import AppKit
import SwiftUI
import BotChuCore

/// A plain-text editor with predictable Return handling, IME support, and a bounded growing height.
/// It takes pasted and dropped images (`pasteImages`). With `send`, Return sends and Shift-Return
/// starts a new line, as in the composer; without it, Return starts a new line, as in a sheet.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    var focused: Binding<Bool>
    let placeholder: String
    let send: (() -> Void)?
    let pasteImages: (NSPasteboard) -> Bool
    var editable = true
    var minHeight: CGFloat = 42
    var maxHeight: CGFloat = 200
    var identifier = "message-input"

    private var sizing: ComposerLayout { ComposerLayout(minHeight: minHeight, maxHeight: maxHeight) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scroll = ComposerScrollView()
        scroll.contentView = ComposerClipView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        // TextKit 1, as the text is measured (`textHeight(width:)`).
        let editor = ComposerTextView(usingTextLayoutManager: false)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        // It fills the scroll view's width and grows with its text (`ComposerScrollView.tile()`).
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: sizing.inset)
        editor.textContainer?.lineFragmentPadding = 4
        editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier(identifier)
        editor.updateDragTypeRegistration()
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        scroll.sizing = sizing
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSend = send
        editor.onPasteImages = pasteImages
        editor.wantsFocus = focused.wrappedValue
        editor.setAccessibilityLabel(placeholder)
        if editor.isEditable != editable { editor.isEditable = editable }
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        // In this update, not after it: a frame drawn before the composer takes focus would show the
        // sidebar row just clicked in its focused, accent color for a moment.
        if focused.wrappedValue, let window = editor.window, window.firstResponder !== editor {
            window.makeFirstResponder(editor)
        }
    }

    /// Measures the text at the width offered without laying the editor out at it: SwiftUI also asks
    /// about widths it doesn't use, and laying out the text shown at each of them made it rewrap and
    /// jump as it was typed, or stay at the height of one of them (#80).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComposerScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite,
              let editor = nsView.documentView as? ComposerTextView else { return nil }
        // Less a scroller that takes room (not one that overlays the text) while the text scrolls.
        let textWidth = width - max(0, nsView.frame.width - nsView.contentSize.width)
        return CGSize(width: width, height: sizing.height(forText: editor.textHeight(width: textWidth)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditor
        init(_ parent: ComposerEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused.wrappedValue = false }
    }
}

/// The editor's scroll view. Its text view fills it, so a click anywhere in it reaches the text, and
/// grows with the text; it scrolls, with a scroller, only once the text is taller than the area can grow.
final class ComposerScrollView: NSScrollView {
    var sizing = ComposerLayout(minHeight: 42, maxHeight: 200)

    override func tile() {
        super.tile()
        guard let editor = documentView as? NSTextView else { return }
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        // At the top: sized to its text as it joined the clip view, before that was flipped, it
        // moved down by its insets, which hid the first line's top.
        editor.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: editor.frame.height)
        editor.sizeToFit()
    }

    override func reflectScrolledClipView(_ clip: NSClipView) {
        let scrolls = documentView.map { sizing.scrolls(documentHeight: $0.frame.height) } ?? false
        if hasVerticalScroller != scrolls { hasVerticalScroller = scrolls }
        super.reflectScrolledClipView(clip)
    }
}

/// Keeps the text at the top while it still fits the area at full height (`ComposerLayout.scrollOffset`).
final class ComposerClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let scroll = enclosingScrollView as? ComposerScrollView, let document = documentView else { return bounds }
        bounds.origin.y = scroll.sizing.scrollOffset(bounds.origin.y, documentHeight: document.frame.height, visibleHeight: bounds.height)
        return bounds
    }
}

final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPasteImages: (NSPasteboard) -> Bool = { _ in false }
    var wantsFocus = false
    private var measured: (text: String, heights: [CGFloat: CGFloat]) = ("", [:])

    /// How tall its text lays out at `width`, measured on a copy, so the text shown is laid out only
    /// at the width it is shown at.
    func textHeight(width: CGFloat) -> CGFloat {
        if measured.text != string { measured = (string, [:]) }
        if let height = measured.heights[width] { return height }
        // An empty text is one line, in the typing font.
        let storage = NSTextStorage(attributedString: string.isEmpty ? NSAttributedString(string: " ", attributes: typingAttributes) : attributedString())
        let container = NSTextContainer(size: NSSize(width: max(1, width - 2 * textContainerInset.width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height
        measured.heights[width] = height
        return height
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus else { return }
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if let onSend, (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if !event.modifierFlags.intersection([.shift, .option]).isEmpty { insertNewline(nil) }
            else { onSend() }
            return
        }
        super.keyDown(with: event)
    }

    // A plain-text view turns Paste off when the pasteboard holds no text, as after a screenshot
    // is copied, so ⌘V never reached `paste(_:)`: it stays on for an image. Only the pasteboard's
    // types are looked at here, as AppKit's own check does: reading the general pasteboard's
    // contents other than to paste makes macOS ask the owner whether BotChu may.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        pastesImages(menuItem.action) || super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        pastesImages(item.action) || super.validateUserInterfaceItem(item)
    }

    private func pastesImages(_ action: Selector?) -> Bool {
        action == #selector(paste(_:)) && isEditable && ImagePaste.imageType(in: NSPasteboard.general.types ?? []) != nil
    }

    override func paste(_ sender: Any?) {
        if !onPasteImages(.general) { super.paste(sender) }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + ImagePaste.dragTypes
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        ImagePaste.hasImages(on: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        ImagePaste.hasImages(on: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onPasteImages(sender.draggingPasteboard) || super.performDragOperation(sender)
    }
}
