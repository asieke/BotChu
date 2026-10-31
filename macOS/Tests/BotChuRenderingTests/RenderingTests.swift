import AppKit
import SwiftUI
import WebKit
import Testing
import BotChuCore
@testable import BotChu

// Every AppKit test belongs to this suite: separate suites can steal one another's window focus.
@Suite(.serialized) @MainActor struct RenderingTests {
    init() { QuietWindows.install }

    @Test func invalidMathAndDiagramKeepSourceAndNetworkIsBlocked() async throws {
        _ = NSApplication.shared
        let source = #"""
        $\unknown{x}$

        ```mermaid
        flowchart LR
          A[Unfinished
        ```
        """#
        let host = NSHostingView(rootView: MarkdownText(text: source).frame(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let web = try #require(findWebView(in: host))
        try await waitFor(web, script: "document.querySelector('.math-source') !== null")
        let state = try await web.callAsyncJavaScript("""
        const blocked = await fetch('https://example.com/botchu-test').then(() => false, () => true);
        return { source: document.querySelector('.math-source').textContent,
                 diagramSource: document.querySelector('.diagram-block details').open,
                 blocked, svg: document.querySelectorAll('.diagram svg').length };
        """, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(state?["source"] as? String == #"$\unknown{x}$"#)
        #expect(state?["diagramSource"] as? Bool == true)
        #expect(state?["blocked"] as? Bool == true)
        #expect(state?["svg"] as? Int == 0)
    }

    /// #63: a rich reply shows only once it has rendered, at its final height. Before, a new web
    /// view showed WebKit's white page, then the diagram's source, taller than the diagram, so the
    /// reply grew and shrank and moved the chat each time its conversation was shown.
    @Test func aRichReplyShowsOnlyOnceRenderedAtItsFinalHeight() async throws {
        _ = NSApplication.shared
        let source = "Reply \(UUID().uuidString):\n\n```mermaid\nflowchart LR\n  A[Start] --> B[Work]\n  B --> C[Review]\n  C --> D[Done]\n```"
        let host = NSHostingView(rootView: MarkdownText(text: source).frame(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let web = try #require(findWebView(in: host))
        #expect(web.alphaValue == 0)
        var heights: [CGFloat] = []
        var shownBeforeDrawn = false
        for _ in 0..<300 {
            host.layoutSubtreeIfNeeded()
            heights.append(web.frame.height)
            if web.alphaValue > 0 {
                let drawn = try await web.callAsyncJavaScript("return document.querySelector('.diagram svg') !== null;",
                                                              in: nil, contentWorld: .defaultClient) as? Bool
                shownBeforeDrawn = drawn != true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(web.alphaValue > 0)
        #expect(!shownBeforeDrawn)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let final = web.frame.height
        #expect(final > 60)
        #expect(heights.allSatisfy { $0 <= final + 1 })
    }

    /// A rendered reply shown again, as when its conversation is opened again, is its kept web
    /// view, shown at once rather than loaded and rendered again, and told of its new width. In
    /// the other appearance it gets a web view of its own.
    @Test func aRichReplyShownAgainIsItsKeptWebViewAtOnce() async throws {
        _ = NSApplication.shared
        RichReplyPool.removeAll()
        defer { RichReplyPool.removeAll() }
        let source = "Reply \(UUID().uuidString): $\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}$ for every $n$. "
            + String(repeating: "This sentence goes on to take several lines in a narrow chat. ", count: 4)
        func reply(width: CGFloat, dark: Bool = false) -> AnyView {
            AnyView(MarkdownText(text: source).frame(width: width).environment(\.colorScheme, dark ? .dark : .light))
        }
        let host = NSHostingView(rootView: reply(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle(until condition: () -> Bool) async throws {
            for _ in 0..<150 where !condition() {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
        }
        host.layoutSubtreeIfNeeded()
        let web = try #require(findWebView(in: host))
        try await settle { web.alphaValue == 1 }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let wide = web.frame.height
        #expect(web.alphaValue == 1)

        // Its conversation goes: the web view waits, hidden, in its window.
        host.rootView = AnyView(Color.clear)
        try await settle { RichReplyPool.count == 1 }
        #expect(RichReplyPool.count == 1)
        #expect(web.window === window && web.isHiddenOrHasHiddenAncestor)

        // Shown again, narrower: that web view, shown at once, and it reports its new height.
        host.rootView = reply(width: 320)
        try await settle { RichReplyPool.count == 0 }
        #expect(RichReplyPool.count == 0)
        #expect(web.superview is ReplyWebContainer && !web.isHiddenOrHasHiddenAncestor && web.alphaValue == 1)
        try await settle { web.frame.height > wide + 1 }
        #expect(web.frame.height > wide + 1)

        // In the other appearance, a web view of its own, while the kept one stays kept.
        host.rootView = AnyView(Color.clear)
        try await settle { RichReplyPool.count == 1 }
        host.rootView = reply(width: 320, dark: true)
        try await settle { webViews(in: host).contains { $0.superview is ReplyWebContainer } }
        let dark = try #require(webViews(in: host).first { $0.superview is ReplyWebContainer })
        #expect(dark !== web)
        #expect(RichReplyPool.count == 1)
    }

    private func webViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap { webViews(in: $0) }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { findWebView(in: $0) }.first
    }

    private func waitFor(_ web: WKWebView, script: String) async throws {
        for _ in 0..<100 {
            if (try? await web.callAsyncJavaScript("return \(script);", in: nil, contentWorld: .defaultClient)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Rendering did not complete: \(script)")
    }
}
