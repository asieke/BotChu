import AppKit
import SwiftUI
import WebKit
import Testing
import BotChuCore
@testable import BotChu

// Every AppKit test belongs to this suite: separate suites can steal one another's window focus.
@Suite(.serialized) @MainActor struct RenderingTests {
    @Test func mathLaysOutAndResizesInsideAReply() async throws {
        _ = NSApplication.shared
        let source = #"""
        | Range | Total |
        | --- | ---: |
        | $p_1 \dots p_{3000}$ | **38,645,211** |

        $$3,682,913 + 12,591,714 + 22,370,584 = \mathbf{38,645,211}$$
        """#
        let host = NSHostingView(rootView: MarkdownText(text: source).frame(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let web = try #require(findWebView(in: host))
        try await waitFor(web, script: "document.querySelectorAll('.katex').length === 2")
        let value = try await web.callAsyncJavaScript("""
        const content = document.getElementById('content');
        return {
            scripts: content.querySelectorAll('msub').length,
            tables: content.querySelectorAll('table').length,
            height: content.getBoundingClientRect().height,
            width: content.getBoundingClientRect().width,
            text: Array.from(content.querySelectorAll('.katex-html')).map(x => x.textContent).join(' ')
        };
        """, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(value?["scripts"] as? Int == 2)
        #expect(value?["tables"] as? Int == 1)
        #expect((value?["height"] as? Double ?? 0) > 60)
        #expect((value?["width"] as? Double ?? 0) > 500)
        #expect((value?["text"] as? String)?.contains("38,645,211") == true)
        #expect((value?["text"] as? String)?.contains("\\mathbf") == false)
        // Wait for the height bridge (the reply shows once it reports), then verify the outer chat
        // receives the document's full size.
        for _ in 0..<150 where web.alphaValue == 0 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(web.frame.height >= (value?["height"] as? Double ?? 0))
        host.rootView = MarkdownText(text: source).frame(width: 320)
        host.layoutSubtreeIfNeeded()
        try await waitFor(web, script: "document.getElementById('content').clientWidth === 320")
        let narrow = try await web.callAsyncJavaScript("""
        const equation = document.querySelector('.tex[data-display="true"]');
        return { scrolls: equation.scrollWidth > equation.clientWidth,
                 fonts: Array.from(document.fonts).filter(f => f.status === 'loaded').length };
        """, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(narrow?["scrolls"] as? Bool == true)
        #expect((narrow?["fonts"] as? Int ?? 0) > 0)
    }

    @Test func mermaidRendersSubgraphsSequenceDiagramsAndKeepsSource() async throws {
        _ = NSApplication.shared
        let source = #"""
        ```mermaid
        flowchart LR
          subgraph BotChu["BotChu (Single macOS Workspace)"]
            direction TB
            Sidebar["Left Sidebar:<br/>Persistent Bots (Chief, 10x, Treasurer)"]
            Stream["Center: Bot Chat Stream<br/>+ Inline Approval Cards"]
            Inspector["Right Inspector:<br/>Bound Repos, Open Issues, Live vs Main"]
          end
          subgraph Local["This Mac (~Desktop/WORKSPACE)"]
            Worktrees["Git Worktrees<br/>.claude/worktrees/type-slug"]
            LiveCheckouts["Live Checkouts (main)"]
          end
          subgraph GitHub["GitHub (Single Source of Truth)"]
            Repos["Code and Life Repos"]
            Issues["Issues (Async Queue and Open Loops)"]
            PRs["Pull Requests (Atomic Transactions)"]
          end
          Stream -->|"Spawns work in"| Worktrees
          Worktrees -->|"Push + check.sh --report"| PRs
          PRs -->|"merge: agent (auto) OR<br/>merge: owner (1-click in Stream)"| Repos
          Stream -->|"Files deferred work"| Issues
          Issues -->|"Triggers / Feeds"| Stream
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
        try await waitFor(web, script: "document.querySelector('.diagram svg') !== null")
        let metrics = try await web.callAsyncJavaScript("""
        const section = document.querySelector('.diagram-block');
        const svg = section.querySelector('svg');
        section.querySelector('.diagram-size').click();
        return { clusters: svg.querySelectorAll('.cluster').length,
                 width: svg.getBoundingClientRect().width,
                 actualSize: section.querySelector('.diagram').classList.contains('actual-size'),
                 source: section.querySelector('code').textContent,
                 collapsed: !section.querySelector('details').open };
        """, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(metrics?["clusters"] as? Int == 3)
        #expect((metrics?["width"] as? Double ?? 0) > 0)
        #expect(metrics?["actualSize"] as? Bool == true)
        #expect(metrics?["collapsed"] as? Bool == true)
        #expect((metrics?["source"] as? String)?.contains(".claude/worktrees/type-slug") == true)

        // Complete a new streamed reply while an older diagram render is queued. The last revision
        // must win, including its appearance, and the widget must shrink as well as grow.
        let old = try #require(RichMarkdown.html("```mermaid\nflowchart LR\n A[Old] --> B[Result]\n```"))
        let latest = try #require(RichMarkdown.html("```mermaid\nsequenceDiagram\n User->>Bot: Hello\n Bot-->>User: Done\n```"))
        _ = try await web.callAsyncJavaScript("""
        await Promise.all([window.renderReply(old, false), window.renderReply(latest, true)]);
        """, arguments: ["old": old, "latest": latest], in: nil, contentWorld: .defaultClient)
        let final = try await web.callAsyncJavaScript("""
        return { svg: document.querySelectorAll('.diagram svg').length,
                 text: document.querySelector('.diagram').textContent,
                 dark: document.documentElement.dataset.appearance === 'dark',
                 background: getComputedStyle(document.body).backgroundColor };
        """, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(final?["svg"] as? Int == 1)
        #expect((final?["text"] as? String)?.contains("Done") == true)
        #expect((final?["text"] as? String)?.contains("Old") == false)
        #expect(final?["dark"] as? Bool == true)
        #expect(final?["background"] as? String == "rgb(41, 41, 41)")
    }

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

    /// #46: a long chat makes web views only for the rich replies near what is visible, and makes
    /// the rest as they scroll into view.
    @Test func richRepliesFarFromViewWaitForTheirWebViews() async throws {
        _ = NSApplication.shared
        let replies = (0..<24).map { "Reply \($0): $x_{\($0)}^2$ is math." }
        let host = NSHostingView(rootView: ScrollView {
            VStack(spacing: 40) {
                ForEach(replies, id: \.self) { MarkdownText(text: $0).frame(height: 120) }
            }
        }.frame(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let near = webViews(in: host).count
        #expect(near > 0)
        #expect(near < replies.count / 2)
        let scroll = try #require(scrollView(in: host))
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(webViews(in: host).count > near)
    }

    /// #46: Mermaid, over 5 MB, goes only into a reply with a diagram, also one that gains it as
    /// it streams.
    @Test func aReplyGetsMermaidOnlyOnceItHasADiagram() async throws {
        _ = NSApplication.shared
        let math = "The sum is $a + b$."
        let host = NSHostingView(rootView: MarkdownText(text: math).frame(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let web = try #require(findWebView(in: host))
        try await waitFor(web, script: "document.querySelectorAll('.katex').length === 1")
        let before = try await web.callAsyncJavaScript("return [typeof katex, typeof mermaid];", in: nil, contentWorld: .defaultClient) as? [String]
        #expect(before == ["object", "undefined"])
        host.rootView = MarkdownText(text: math + "\n\n```mermaid\nflowchart LR\n  A[Start] --> B[Done]\n```").frame(width: 600)
        host.layoutSubtreeIfNeeded()
        try await waitFor(web, script: "document.querySelector('.diagram svg') !== null")
        #expect(findWebView(in: host) === web)
        let after = try await web.callAsyncJavaScript("return typeof mermaid;", in: nil, contentWorld: .defaultClient) as? String
        #expect(after == "object")
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
