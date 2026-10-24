import AppKit
import SwiftUI
import WebKit
import Testing
@testable import BotChuCore
@testable import BotChu

/// #106: a long reply being written, native or rich, as the chat draws it.
extension RenderingTests {
    /// It is parsed off the main thread, only as often as the worker keeps up, while its last
    /// rendering shows; once it stops, it is laid out as a full parse of its text is.
    @Test func aLongReplyBeingWrittenIsParsedOffTheMainThread() async throws {
        _ = NSApplication.shared
        let paragraph = "A **measured** answer has `code`, a [link](https://example.test), and explanation.\n\n"
        var text = "Reply \(UUID().uuidString)\n\n"
        let host = NSHostingView(rootView: MarkdownText(text: text).frame(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        // Its first, short version was parsed in place; none of the rest is.
        let parsedOnMain = MarkdownParses.main
        let before = MarkdownWorker.shared.statistics
        for index in 0..<100 {
            text += paragraph + paragraph + "Delta \(index) with **more** words.\n\n"
            host.rootView = MarkdownText(text: text).frame(width: 600)
            host.layoutSubtreeIfNeeded()
        }
        #expect(text.utf8.count > MarkdownPreparation.tailLimit)
        #expect(MarkdownWorker.shared.statistics.started - before.started < 100)
        for _ in 0..<250 where MarkdownCache.shared.cached(text) == nil { try await Task.sleep(for: .milliseconds(20)) }
        // The same text drawn afresh, from the cache.
        let fresh = NSHostingView(rootView: MarkdownText(text: text).frame(width: 600))
        fresh.layoutSubtreeIfNeeded()
        for _ in 0..<250 where host.fittingSize.height != fresh.fittingSize.height {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        #expect(host.fittingSize.height == fresh.fittingSize.height)
        #expect(host.fittingSize.height > 2_000)
        #expect(MarkdownParses.main == parsedOnMain)
    }

    /// A rich reply's web view renders one revision at a time: the revisions written meanwhile
    /// wait, only the newest, and the page ends with the last one. A height reported for another
    /// revision changes nothing.
    @Test func aRichReplyRendersOneRevisionAtATime() async throws {
        _ = NSApplication.shared
        var source = "Reply \(UUID().uuidString): "
        let revisions = try (0..<30).map { index in
            source += "Term $x_{\(index)}^2$ and more. "
            return try #require(RichMarkdown.html(source))
        }
        let host = NSHostingView(rootView: RichMarkdownText(html: revisions[0]).frame(width: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let web = try #require(webView(in: host))
        try await rendered(web, "document.querySelectorAll('.katex').length === 1")
        for _ in 0..<150 where web.busy { try await Task.sleep(for: .milliseconds(20)) }
        let renders = web.renders
        for html in revisions.dropFirst() {
            host.rootView = RichMarkdownText(html: html).frame(width: 600)
            host.layoutSubtreeIfNeeded()
        }
        // The first started, the last waits, and those between were never rendered.
        #expect(web.busy && web.waiting)
        #expect(web.skipped == revisions.count - 3)
        try await rendered(web, "document.querySelectorAll('.katex').length === 30")
        for _ in 0..<150 where web.busy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(web.renders - renders == 2)
        #expect(web.rendered?.html == revisions.last)
        for _ in 0..<150 where RichMarkdownHeights.height(for: revisions.last!) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let height = try #require(RichMarkdownHeights.height(for: revisions.last!))
        #expect(revisions[2..<(revisions.count - 1)].allSatisfy { RichMarkdownHeights.height(for: $0) == nil })
        // A late height of an earlier revision is ignored.
        _ = try await web.callAsyncJavaScript("window.webkit.messageHandlers.layout.postMessage({ height: 999, revision: \(web.revision - 1) });",
                                              in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(RichMarkdownHeights.height(for: revisions.last!) == height)
        #expect(abs(web.frame.height - height) < 1)
    }

    private func webView(in view: NSView) -> ChatWebView? {
        (view as? ChatWebView) ?? view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    private func rendered(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<100 {
            if (try? await web.callAsyncJavaScript("return \(script);", in: nil, contentWorld: .defaultClient)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Rendering did not complete: \(script)")
    }
}
