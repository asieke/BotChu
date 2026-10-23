import AppKit
import SwiftUI

/// A plain-text editor with predictable Return handling, IME support, and a bounded growing height.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    var focused: Binding<Bool>
    let placeholder: String
    let send: () -> Void
    let pasteImages: (NSPasteboard) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let editor = ComposerTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 4
        editor.textContainer?.widthTracksTextView = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("message-input")
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSend = send
        editor.onPasteImages = pasteImages
        editor.wantsFocus = focused.wrappedValue
        editor.setAccessibilityLabel(placeholder)
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let editor = nsView.documentView as? NSTextView,
              let container = editor.textContainer, let layout = editor.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(1, width - 16), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let contentHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 8
        let height = min(200, max(42, ceil(contentHeight)))
        nsView.hasVerticalScroller = contentHeight > 200
        editor.setFrameSize(NSSize(width: width, height: max(height, contentHeight)))
        return CGSize(width: width, height: height)
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

final class ComposerTextView: NSTextView {
    var onSend: () -> Void = {}
    var onPasteImages: (NSPasteboard) -> Bool = { _ in false }
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus else { return }
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText() {
            if !event.modifierFlags.intersection([.shift, .option]).isEmpty { insertNewline(nil) }
            else { onSend() }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if !onPasteImages(.general) { super.paste(sender) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPasteImages(sender.draggingPasteboard) || super.performDragOperation(sender)
    }
}
