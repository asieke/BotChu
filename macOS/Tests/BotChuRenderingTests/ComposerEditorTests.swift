import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// #80: the message box's text stays put while it is typed.
extension RenderingTests {
    /// Typed into, narrow and wide, line by line and wrapping, past its maximum and back: the first
    /// line never leaves the top while the box can still grow, not even in the moment between a
    /// keystroke and SwiftUI's layout, and the caret's line stays in view once it scrolls.
    @Test func composerTextStaysPutWhileItIsTyped() async throws {
        _ = NSApplication.shared
        for width in [300.0, 700.0] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 40, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.contentView = nil; window.close() }
            let host = NSHostingView(rootView: ComposerEditorSample(width: width))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let editor = try #require(findComposerTextView(in: host))
            let scroll = try #require(editor.enclosingScrollView)
            let layout = try #require(editor.layoutManager), container = try #require(editor.textContainer)
            func contentHeight() -> CGFloat {
                layout.ensureLayout(for: container)
                return ceil(layout.usedRect(for: container).height + 8)
            }
            var jumped: [String] = []
            func key(_ type: () -> Void) async throws {
                type()
                // Before SwiftUI lays the box out again: the text view may already be taller.
                if contentHeight() <= 200, editor.visibleRect.minY > 0.5 { jumped.append("\(width): \(editor.visibleRect.minY) at \(contentHeight())") }
                try await Task.sleep(for: .milliseconds(20))
                window.layoutIfNeeded()
            }
            func expectSettled(_ comment: Comment) {
                let content = contentHeight()
                #expect(abs(scroll.frame.height - min(200, max(42, content))) < 0.5, comment)
                #expect(editor.frame.origin == .zero, comment)
                #expect(abs(container.containerSize.width - editor.frame.width) < 0.5, comment)
                #expect(scroll.hasVerticalScroller == (content > 200.5), comment)
                if content <= 200.5 {
                    #expect(editor.visibleRect.minY < 0.5, comment)
                } else {
                    // At the end of the draft, its last line shows, with the inset below it.
                    #expect(abs(editor.visibleRect.maxY - editor.frame.height) < 0.5, comment)
                }
            }

            try await key { editor.insertText("Hello", replacementRange: editor.selectedRange()) }
            expectSettled("short")
            for line in 2...16 {
                try await key { editor.insertNewline(nil) }
                expectSettled("\(line) lines")
            }
            for line in (1...15).reversed() {
                try await key { editor.deleteBackward(nil) }
                expectSettled("back to \(line) lines")
            }
            for _ in 0..<80 { try await key { editor.insertText("wrapping ", replacementRange: editor.selectedRange()) } }
            expectSettled("wrapped past the maximum")
            editor.selectAll(nil)
            try await key { editor.deleteBackward(nil) }
            expectSettled("cleared")
            #expect(jumped.isEmpty, "the text scrolled while the box could still grow: \(jumped.prefix(3))")

            // Measuring another width, as SwiftUI does, leaves the text shown as it is.
            let before = (editor.frame, container.containerSize)
            _ = editor.textHeight(width: 120)
            #expect(editor.frame == before.0 && container.containerSize == before.1)
        }
    }
}

private func findComposerTextView(in view: NSView) -> ComposerTextView? {
    if let editor = view as? ComposerTextView { return editor }
    return view.subviews.lazy.compactMap { findComposerTextView(in: $0) }.first
}

private struct ComposerEditorSample: View {
    let width: CGFloat
    @State private var text = ""

    var body: some View {
        VStack(spacing: 12) {
            ComposerEditor(text: $text, focused: .constant(false), placeholder: "Message", send: {}, pasteImages: { _ in false })
            Color.clear.frame(height: 32)
        }
        .frame(width: width)
    }
}
