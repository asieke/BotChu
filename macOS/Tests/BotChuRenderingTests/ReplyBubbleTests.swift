import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// "pineapple" gets a bubble its own size, not the chat's width; a long paragraph still wraps
    /// at the chat's width, and a table or code block fills it.
    @Test func replyBubblesFitShortTextAndFillForLongText() async throws {
        _ = NSApplication.shared
        let short = try await fittedWidth("pineapple")
        #expect(short > 20 && short < 120, "short reply was \(short) wide")
        let long = try await fittedWidth(String(repeating: "A reply long enough to wrap across the chat. ", count: 12))
        #expect(long > 560 && long <= 600, "long reply was \(long) wide")
        let code = try await fittedWidth("Run this:\n\n```sh\nls\n```")
        #expect(code == 600, "code reply was \(code) wide")
        let filling = try await fittedWidth("pineapple", fitsText: false)
        #expect(filling == 600)
    }

    @MainActor private func fittedWidth(_ text: String, fitsText: Bool = true) async throws -> CGFloat {
        final class Box { var width: CGFloat = 0 }
        let box = Box()
        let view = HStack(spacing: 0) {
            MarkdownText(text: text, fitsText: fitsText)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { box.width = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in box.width = width }
                })
            Spacer(minLength: 0)
        }
        .frame(width: 600)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var last: CGFloat = -1
        // Settled once the width stops changing (the worker's parse lands after the first pass).
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            if box.width > 0, box.width == last { break }
            last = box.width
        }
        return box.width
    }
}
