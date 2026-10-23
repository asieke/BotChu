import AppKit
import SwiftUI

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
        editor.setAccessibilityIdentifier(identifier)
        editor.updateDragTypeRegistration()
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
        if editor.isEditable != editable { editor.isEditable = editable }
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if focused.wrappedValue, let window = editor.window, window.firstResponder !== editor {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.wantsFocus else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let editor = nsView.documentView as? NSTextView,
              let container = editor.textContainer, let layout = editor.layoutManager else { return nil }
        container.containerSize = NSSize(width: max(1, width - 16), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let contentHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 8
        let height = min(maxHeight, max(minHeight, ceil(contentHeight)))
        nsView.hasVerticalScroller = contentHeight > maxHeight
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
    var onSend: (() -> Void)?
    var onPasteImages: (NSPasteboard) -> Bool = { _ in false }
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus else { return }
            self.window?.makeFirstResponder(self)
        }
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
