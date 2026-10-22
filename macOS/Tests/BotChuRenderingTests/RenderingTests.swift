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
        // Wait for the height bridge, then verify the outer chat receives the document's full size.
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
