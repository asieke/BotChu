import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// #63: switching conversations without a flash.
extension RenderingTests {
    /// The toolbar's buttons stay as they are across a switch (made anew, they had AppKit rebuild
    /// the toolbar, and every button faded back in), and the chat shown opens at its very end.
    @Test func switchingConversationsKeepsTheToolbarAndOpensAtTheEnd() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        var messages: [ChatMessage] = []
        for turn in 0..<20 {
            messages.append(ChatMessage(role: .user, text: "Question \(turn)"))
            messages.append(ChatMessage(role: .assistant, text: "Answer \(turn)\n\nA paragraph long enough to take a few lines in the chat, so the conversation is much taller than its window."))
        }
        app.conversation(fixture.task).replace(messages)
        let home = ChatTarget.home(fixture.task.botID)
        app.show(home)
        let defaults = UserDefaults(suiteName: fixture.domain)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        func buttons() -> [String] {
            (window.toolbar?.items ?? []).compactMap { item in item.view.map { "\(item.label) \(ObjectIdentifier($0))" } }
        }
        let before = buttons()
        #expect(before.contains { $0.hasPrefix("Report a Bug or Feature ") })
        #expect(before.contains { $0.hasPrefix("New Task ") })
        #expect(before.contains { $0.hasPrefix("Chat Density ") })

        app.show(fixture.task)
        try await Task.sleep(for: .milliseconds(400))
        #expect(buttons() == before)
        // Its long chat opens at the end, not its bottom margin short of it, and stays there.
        let scroll = try #require(Self.chatScrollView(in: window.contentView!))
        scroll.layoutSubtreeIfNeeded()
        #expect(abs((scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY) < 1)

        app.show(home)
        try await Task.sleep(for: .milliseconds(300))
        #expect(buttons() == before)
    }

    /// The message box takes focus in the update that shows it, not after it: a frame drawn in
    /// between showed the sidebar row just clicked in its focused, accent color.
    @Test func composerTakesFocusInTheUpdateThatShowsIt() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = content
        let elsewhere = NSTextView(frame: NSRect(x: 0, y: 200, width: 200, height: 30))
        content.addSubview(elsewhere)
        window.makeKeyAndOrderFront(nil)

        // Joining the window focused: at once, with no turn of the run loop in between.
        window.makeFirstResponder(elsewhere)
        let joining = ComposerTextView(frame: NSRect(x: 0, y: 150, width: 300, height: 40))
        joining.wantsFocus = true
        content.addSubview(joining)
        #expect(window.firstResponder === joining)

        // Asked for focus once in the window, as a conversation's view asks when it appears.
        window.makeFirstResponder(elsewhere)
        func composer(focused: Bool) -> some View {
            ComposerEditor(text: .constant(""), focused: .constant(focused), placeholder: "Message", send: {}, pasteImages: { _ in false })
        }
        let host = NSHostingView(rootView: composer(focused: false))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let editor = try #require(composerTextView(in: host))
        #expect(window.firstResponder === elsewhere)
        host.rootView = composer(focused: true)
        host.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === editor)
    }

    private func composerTextView(in view: NSView) -> ComposerTextView? {
        if let editor = view as? ComposerTextView { return editor }
        return view.subviews.lazy.compactMap { composerTextView(in: $0) }.first
    }
}
