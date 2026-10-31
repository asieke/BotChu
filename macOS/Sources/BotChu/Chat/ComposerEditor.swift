import AppKit
import SwiftUI
import BotChuCore

/// A plain-text editor with predictable Return handling, IME support, and a bounded growing height.
/// It takes pasted and dropped images (`pasteImages`). With `send`, Return sends and Shift-Return
/// starts a new line, as in the composer; without it, Return starts a new line, as in a sheet. With
/// `mentions`, `@` and `#` complete agents and projects (`MentionCompleter`), whose chosen labels it
/// keeps linked in `references`; the report and New Task sheets share it without them.
struct ComposerEditor: NSViewRepresentable {
    @Binding var text: String
    var focused: Binding<Bool>
    /// A different draft starts a fresh editing session without rebuilding TextKit's views.
    var draftID: UUID? = nil
    let placeholder: String
    let send: (() -> Void)?
    let pasteImages: (NSPasteboard) -> Bool
    var editable = true
    var minHeight: CGFloat = 42
    var maxHeight: CGFloat = 200
    var identifier = "message-input"
    var mentions: MentionCompleter?
    var mentionSources: MentionSources?
    var references: Binding<[MessageReference]> = .constant([])
    /// The `statusKey`s of the draft's mentions that point at nothing now, which show dotted.
    var unresolvedMentions: Set<String> = []

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
        if draftID != nil { editor.draftUndoManager = UndoManager() }
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier(identifier)
        editor.updateDragTypeRegistration()
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: ComposerScrollView, context: Context) {
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        let changedDraft = context.coordinator.parent.draftID != draftID
        if changedDraft {
            // End the old input context while its delegate still owns the old draft binding.
            // A late IME commit must never be written into the newly selected delivery.
            // An unfocused editor with no composition has no input session to end. Merely
            // asking for its context activates the input method and can wait on IMK XPC.
            if editor.hasMarkedText() || editor.window?.firstResponder === editor {
                editor.inputContext?.discardMarkedText()
                editor.unmarkText()
            }
            if editor.window?.firstResponder === editor { editor.window?.makeFirstResponder(nil) }
        }
        context.coordinator.parent = self
        scroll.sizing = sizing
        editor.onSend = send
        editor.onPasteImages = pasteImages
        editor.wantsFocus = focused.wrappedValue
        editor.setAccessibilityLabel(placeholder)
        if editor.isEditable != editable { editor.isEditable = editable }
        if let mentions {
            mentions.sources = mentionSources
            mentions.editor = editor
            editor.completer = mentions
        }
        if changedDraft || (editor.string != text && !editor.hasMarkedText()) {
            let selection = changedDraft ? NSRange(location: 0, length: 0) : editor.selectedRange()
            if editor.string != text { editor.string = text }
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            if mentions != nil { editor.setMentions(references.wrappedValue) }
        } else if mentions != nil, !editor.hasMarkedText(), editor.mentionReferences != MessageReference.standing(references.wrappedValue, in: text) {
            // Unlinked, or taken back from the queue with the same text.
            editor.setMentions(references.wrappedValue)
        }
        if changedDraft {
            editor.undoManager?.removeAllActions()
            scroll.contentView.scroll(to: .zero)
        }
        if mentions != nil { editor.unresolvedMentions = unresolvedMentions }
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
            FrameTimings.mark(FrameMarks.composer)
            parent.text = editor.string
            guard let editor = editor as? ComposerTextView, let mentions = parent.mentions else { return }
            // A label edited into other text is no longer linked: it stays as ordinary text.
            let references = editor.mentionReferences
            if parent.references.wrappedValue != references { parent.references.wrappedValue = references }
            editor.styleMentions()
            mentions.update(typed: editor.isTyping)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard notification.object is ComposerTextView, let mentions = parent.mentions, mentions.isOpen else { return }
            mentions.update(typed: false)
        }
        /// Text typed after a chosen label isn't part of it.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            var attributes = newTypingAttributes
            attributes[.botchuMention] = nil
            return attributes
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) {
            parent.focused.wrappedValue = false
            if let mentions = parent.mentions, let editor = notification.object as? NSTextView { closeOnceFocusLeft(mentions, editor) }
        }

        /// Closes the list when the editor has lost focus for good: not while the mouse is down, as when
        /// a click on one of its rows, which ends editing first, has yet to insert it.
        private func closeOnceFocusLeft(_ mentions: MentionCompleter, _ editor: NSTextView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak mentions, weak editor] in
                guard let self, let mentions, let editor, mentions.isOpen else { return }
                if NSEvent.pressedMouseButtons != 0 { return self.closeOnceFocusLeft(mentions, editor) }
                if editor.window?.firstResponder !== editor { mentions.close() }
            }
        }
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
    /// Context-switched drafts own their undo history, so clearing it leaves other fields alone.
    var draftUndoManager: UndoManager?
    override var undoManager: UndoManager? { draftUndoManager ?? super.undoManager }
    var onSend: (() -> Void)?
    var onPasteImages: (NSPasteboard) -> Bool = { _ in false }
    var wantsFocus = false
    /// `@` and `#` completion, when the editor has it.
    weak var completer: MentionCompleter?
    /// The `statusKey`s of mentions that point at nothing now.
    var unresolvedMentions: Set<String> = [] {
        didSet { if unresolvedMentions != oldValue { styleMentions() } }
    }
    /// Whether the change under way is typed (input methods and dictation included), which alone opens
    /// completion; pasted and dropped text isn't.
    private(set) var isTyping = false
    private var pasting = false
    /// Whether the text showed a chosen label when last styled (`styleMentions`).
    var stylesMentions = false
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
        // An open completion list takes its keys first, so Return that inserts a suggestion never sends.
        if let completer, completer.handle(event) { return }
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
        if onPasteImages(.general) { return }
        if completer != nil, pasteMentions(from: .general) { return }
        pasting = true
        defer { pasting = false }
        super.paste(sender)
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
        if onPasteImages(sender.draggingPasteboard) { return true }
        pasting = true
        defer { pasting = false }
        return super.performDragOperation(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if typingAttributes[.botchuMention] != nil { typingAttributes[.botchuMention] = nil }
        isTyping = !pasting
        defer { isTyping = false }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Copying keeps the plain text, readable anywhere, and adds the mentions in it for another message box.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let wrote = super.writeSelection(to: pboard, types: types)
        let selection = selectedRange()
        guard wrote, completer != nil, selection.length > 0 else { return wrote }
        let inside = mentionReferences.filter { $0.location >= selection.location && NSMaxRange($0.range) <= NSMaxRange(selection) }
        guard !inside.isEmpty,
              let data = try? JSONEncoder().encode(MentionClip(text: (string as NSString).substring(with: selection),
                                                               references: inside.map { $0.moved(by: -selection.location) }))
        else { return wrote }
        pboard.addTypes([.botchuMentions], owner: nil)
        pboard.setData(data, forType: .botchuMentions)
        return wrote
    }
}

// MARK: Mentions

extension NSAttributedString.Key {
    /// A label chosen from `@` or `#` completion, on its characters: its `MentionToken`.
    static let botchuMention = NSAttributedString.Key("BotChuMention")
}

extension NSPasteboard.PasteboardType {
    /// Copied text with the mentions in it (`MentionClip`), which pasting into a message box keeps linked.
    static let botchuMentions = NSPasteboard.PasteboardType("local.BotChu.mentions")
}

/// What a chosen label's characters carry: one token per choice (equal only to itself), so two labels
/// side by side stay apart, and characters typed into a label split it into runs that no longer match it.
final class MentionToken: NSObject {
    let reference: MessageReference
    init(_ reference: MessageReference) { self.reference = reference }
}

/// Copied text and the mentions in it, placed from its start.
struct MentionClip: Codable {
    var text: String
    var references: [MessageReference]
}

extension ComposerTextView {
    /// The labels in the text still as chosen, in order. Undo restores a label's characters with their
    /// token, and so its link; any other edit inside one leaves ordinary text.
    var mentionReferences: [MessageReference] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let text = storage.string as NSString
        var references: [MessageReference] = []
        storage.enumerateAttribute(.botchuMention, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let token = value as? MentionToken, text.substring(with: range) == token.reference.label else { return }
            var reference = token.reference
            reference.location = range.location
            references.append(reference)
        }
        return references
    }

    /// Links the labels of `references` that stand in the text, and nothing else.
    func setMentions(_ references: [MessageReference]) {
        guard let storage = textStorage else { return }
        storage.removeAttribute(.botchuMention, range: NSRange(location: 0, length: storage.length))
        for reference in MessageReference.standing(references, in: string) {
            storage.addAttribute(.botchuMention, value: MentionToken(reference), range: reference.range)
        }
        styleMentions()
    }

    /// Shows linked labels in the accent color on a faint tint, and those that point at nothing now
    /// dotted, without changing how the text lays out (#80 measures it).
    func styleMentions() {
        guard let layout = layoutManager, let storage = textStorage else { return }
        let references = mentionReferences
        // A draft that has never had a label has nothing to restyle.
        guard stylesMentions || !references.isEmpty else { return }
        stylesMentions = !references.isEmpty
        let whole = NSRange(location: 0, length: storage.length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor] {
            layout.removeTemporaryAttribute(key, forCharacterRange: whole)
        }
        for reference in references {
            let resolved = !unresolvedMentions.contains(reference.statusKey)
            layout.addTemporaryAttributes(resolved ? Self.linkedStyle : Self.unresolvedStyle, forCharacterRange: reference.range)
        }
    }

    static let linkedStyle: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.controlAccentColor,
        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12),
    ]
    static let unresolvedStyle: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
        .underlineStyle: NSUnderlineStyle.single.union(.patternDot).rawValue,
        .underlineColor: NSColor.systemOrange,
    ]

    /// The text's own attributes, without a label's token.
    private var plainAttributes: [NSAttributedString.Key: Any] {
        var attributes = typingAttributes
        attributes[.botchuMention] = nil
        return attributes
    }

    /// Replaces `range` (the query) with a chosen label and what follows it, as one undoable change,
    /// and puts the caret back to writing after it.
    func insertMention(_ reference: MessageReference, replacing range: NSRange, with replacement: String, caret: Int) {
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: plainAttributes))
        storage.addAttribute(.botchuMention, value: MentionToken(reference), range: NSRange(location: range.location, length: reference.label.utf16.count))
        storage.endEditing()
        didChangeText()
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        typingAttributes = plainAttributes
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    /// Pastes text copied from a message box with its mentions still linked; false for anything else.
    func pasteMentions(from board: NSPasteboard) -> Bool {
        guard isEditable, board.availableType(from: [.botchuMentions]) != nil,
              let data = board.data(forType: .botchuMentions), let clip = try? JSONDecoder().decode(MentionClip.self, from: data),
              board.string(forType: .string) == clip.text, let storage = textStorage else { return false }
        let range = selectedRange()
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: clip.text) else { return true }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: clip.text, attributes: plainAttributes))
        for reference in MessageReference.standing(clip.references, in: clip.text) {
            storage.addAttribute(.botchuMention, value: MentionToken(reference), range: reference.moved(by: range.location).range)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: range.location + clip.text.utf16.count, length: 0))
        return true
    }

    /// Where the character at `location` starts, from the editor's left edge.
    func mentionX(at location: Int) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer, let scroll = enclosingScrollView,
              let storage = textStorage, location < storage.length else { return 0 }
        let glyph = layout.glyphIndexForCharacter(at: location)
        let x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).minX
        return max(0, convert(NSPoint(x: x + textContainerOrigin.x, y: 0), to: scroll).x)
    }

    /// Where the line of the character at `location` ends, from the editor's top, as it shows.
    func mentionLineBottom(at location: Int) -> CGFloat {
        guard let layout = layoutManager, let scroll = enclosingScrollView, let storage = textStorage, location < storage.length else { return 0 }
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
        let y = convert(NSPoint(x: 0, y: line.maxY + textContainerOrigin.y), to: scroll).y
        return min(max(0, scroll.isFlipped ? y : scroll.bounds.height - y), scroll.bounds.height)
    }
}
