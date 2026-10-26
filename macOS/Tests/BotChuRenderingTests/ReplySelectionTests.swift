import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// #156: a reply's text is selected across its lines and blocks, though SwiftUI selects text only
/// within one `Text` and a reply draws each block as its own. Native mouse events go to the reply
/// drawn alone, and Copy goes to the window's first responder, as Edit ▸ Copy sends it; what is
/// copied lands on a stand-in pasteboard.
extension RenderingTests {
    static let selectableReply = """
    ## Heading here

    First paragraph with **bold** and a [link](https://example.com).

    - Item one
    - Item two
      1. Nested

    > Quoted line

    ```swift
    let x = 1
    let y = 2
    ```

    | A | B |
    | --- | --- |
    | 1 | 2 |

    Last paragraph.
    """
    static let selectableReplyText = """
    Heading here

    First paragraph with bold and a link.

    • Item one
    • Item two
    \t1. Nested

    Quoted line

    let x = 1
    let y = 2

    A\tB
    1\t2

    Last paragraph.
    """

    /// A drag from the start of a reply's first line to past the end of its last selects every
    /// block between (a heading, a paragraph, a nested list, a quote, code and a table), and Copy
    /// copies all of it in reading order, with line breaks between blocks. The selection is shown
    /// behind the reply's blocks, its code's and its table's, and a click clears it, leaving the
    /// reply drawn as it was.
    @Test func aDragAcrossAReplysBlocksCopiesThemAll() async throws {
        _ = NSApplication.shared
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        let reply = ReplyWindow(MarkdownText(text: Self.selectableReply))
        defer { reply.close() }
        try await reply.settle()
        let unselected = reply.picture()
        // The heading's line, past its top padding.
        let start = reply.point(x: 1, y: 14)
        reply.drag(from: start, to: reply.point(x: reply.size.width - 2, y: reply.size.height - 8))
        try await reply.settle()
        #expect(reply.copy() == Self.selectableReplyText)
        #expect(reply.surfaces.count == 3)
        #expect(reply.surfaces.allSatisfy { $0.selectionShape != nil })
        reply.click(at: start)
        try await reply.settle()
        #expect(reply.surfaces.allSatisfy { $0.selectionShape == nil })
        #expect(reply.picture() == unselected)
    }

    /// Shift-click extends a selection, a double click selects a word and a triple click a line of
    /// code, Select All the whole reply, and a click selects nothing (Copy is off) or opens the link
    /// under it. A drag can start inside code and end in a table, which scroll sideways, and the
    /// code's Copy button still copies its code.
    @Test func clicksSelectWordsLinesAndTheWholeReply() async throws {
        _ = NSApplication.shared
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        var opened: [URL] = []
        let reply = ReplyWindow(MarkdownText(text: Self.selectableReply).environment(\.openURL, OpenURLAction { url in
            opened.append(url)
            return .handled
        }))
        defer { reply.close() }
        try await reply.settle()
        let selection = try #require(reply.selection)
        let text = selection.text
        func at(_ piece: Int, _ offset: Int) throws -> NSPoint { try #require(selection.point(at: ReplyPosition(piece: piece, offset: offset))) }

        reply.click(at: reply.point(x: 1, y: 14))
        let paragraph = try #require(selection.frame(ofPiece: 1))
        reply.click(at: NSPoint(x: paragraph.maxX + 20, y: paragraph.midY), flags: .shift)
        #expect(reply.copy() == "Heading here\n\nFirst paragraph with bold and a link.")
        // "First paragraph with **bold**": the o of bold.
        reply.click(at: try at(1, 22), clicks: 2)
        #expect(reply.copy() == "bold")
        let code = try #require(text.index(of: ReplyText.Key(path: [4], part: .code)))
        reply.click(at: try at(code, 12), clicks: 3)
        #expect(reply.copy() == "let y = 2")

        reply.click(at: try at(1, 3))
        #expect(!selection.hasSelection)
        let surface = try #require(reply.window.firstResponder as? ReplyTextSurface)
        #expect(!surface.validateMenuItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")))
        #expect(opened.isEmpty)
        reply.selectAll()
        #expect(reply.copy() == Self.selectableReplyText)
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: try at(1, 3), modifierFlags: [], timestamp: 0,
                                                         windowNumber: reply.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(surface.menu(for: rightClick)?.items.map(\.title) == ["Copy", "Select All"])

        // From the x of `let x = 1` to the start of the table's second row.
        let row = try #require(text.index(of: ReplyText.Key(path: [5, 1], part: .cell(0))))
        reply.drag(from: try at(code, 4), to: try at(row, 0))
        #expect(reply.copy() == "x = 1\nlet y = 2\n\nA\tB")

        // "… and a [link]": the i of link.
        reply.click(at: try at(1, 33))
        #expect(opened == [URL(string: "https://example.com")!])

        // The Copy button, at the right of the code's header, above the code and its padding.
        let codeFrame = try #require(selection.frame(ofPiece: code))
        let header = reply.point(x: reply.size.width - 20, y: 0)
        reply.click(at: NSPoint(x: header.x, y: codeFrame.maxY + 12 + 1 + 16))
        #expect(NSPasteboard.general.string(forType: .string) == "let x = 1\nlet y = 2\n")
    }

    /// Selecting in one reply, then another, leaves only the second selected; Copy copies it.
    @Test func selectingInAnotherReplyClearsTheFirst() async throws {
        _ = NSApplication.shared
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        let reply = ReplyWindow(VStack(spacing: 20) {
            MarkdownText(text: "First reply.\n\nIts second paragraph.")
            MarkdownText(text: "Second reply.\n\nIts own paragraph.")
        })
        defer { reply.close() }
        try await reply.settle()
        let controllers = reply.surfaces.compactMap(\.controller)
        let first = try #require(controllers.first { $0.text.pieces.first?.text == "First reply." })
        let second = try #require(controllers.first { $0.text.pieces.first?.text == "Second reply." })
        reply.click(at: try #require(first.point(at: ReplyPosition(piece: 0, offset: 0))))
        reply.selectAll()
        #expect(reply.copy() == "First reply.\n\nIts second paragraph.")
        let end = try #require(second.frame(ofPiece: 1))
        reply.drag(from: try #require(second.point(at: ReplyPosition(piece: 0, offset: 7))), to: NSPoint(x: end.maxX + 10, y: end.midY))
        #expect(first.selection == nil)
        #expect(reply.copy() == "reply.\n\nIts own paragraph.")
    }

    /// A reply long enough to be laid out in chunks, each in a view of its own: a drag goes from
    /// one chunk into the next, and Select All copies every chunk and the blocks after them. The
    /// chunks' texts give their layouts as they are drawn, rather than have SwiftUI lay them out
    /// again for each delta.
    @Test func aSelectionSpansTheChunksOfALongReply() async throws {
        _ = NSApplication.shared
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        let source = (1...300).map { "Paragraph \($0)." }.joined(separator: "\n\n")
        MarkdownCache.shared.warm([source])
        let reply = ReplyWindow(MarkdownText(text: source), height: 600)
        defer { reply.close() }
        try await reply.settle()
        // Two chunks of 128 and the 44 blocks after them.
        #expect(reply.surfaces.count == 3)
        if #available(macOS 15, *) {
            #expect(reply.surfaces.filter { if case .given = $0.source { true } else { false } }.count == 2)
        }
        let selection = try #require(reply.selection)
        #expect(selection.text.pieces.count == 300)
        reply.click(at: try #require(selection.point(at: ReplyPosition(piece: 0, offset: 0))))
        reply.selectAll()
        #expect(reply.copy() == source)

        // Where the first chunk ends, in the middle of the window.
        let last = try #require(selection.frame(ofPiece: 127))
        reply.top = reply.window.contentView!.bounds.height - last.maxY - 300
        try await reply.settle()
        reply.drag(from: try #require(selection.point(at: ReplyPosition(piece: 127, offset: 0))),
                   to: try #require(selection.point(at: ReplyPosition(piece: 128, offset: 4))))
        #expect(reply.copy() == "Paragraph 128.\n\nPara")
    }

    /// A reply being written keeps its selection as it grows, can be dragged across while it
    /// changes between the mouse's events, and keeps the selection within it when it shortens.
    @Test func aSelectionHoldsWhileTheReplyIsWritten() async throws {
        _ = NSApplication.shared
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        var text = "First paragraph.\n\nSecond paragraph."
        let reply = ReplyWindow(MarkdownText(text: text), height: 500)
        defer { reply.close() }
        try await reply.settle()
        let start = reply.point(x: 1, y: 8)
        reply.drag(from: start, to: reply.point(x: reply.size.width - 2, y: reply.size.height - 8))
        #expect(reply.copy() == text)
        text += "\n\nThird paragraph."
        reply.show(MarkdownText(text: text))
        try await reply.settle()
        #expect(reply.copy() == "First paragraph.\n\nSecond paragraph.")

        reply.send(.leftMouseDown, at: start)
        for index in 0..<10 {
            text += "\n\nMore \(index)."
            reply.show(MarkdownText(text: text))
            reply.send(.leftMouseDragged, at: reply.point(x: reply.size.width - 2, y: reply.size.height - 8))
            try await Task.sleep(for: .milliseconds(10))
        }
        try await reply.settle()
        reply.send(.leftMouseDragged, at: reply.point(x: reply.size.width - 2, y: reply.size.height - 8))
        reply.send(.leftMouseUp, at: reply.point(x: reply.size.width - 2, y: reply.size.height - 8))
        #expect(reply.copy() == text)

        reply.show(MarkdownText(text: "First paragraph."))
        try await reply.settle()
        #expect(reply.copy() == "First paragraph.")
    }
}

/// A reply drawn alone in a window, 10 points in from its edges, from `top` points down it.
@MainActor final class ReplyWindow {
    static let padding: CGFloat = 10
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let width: CGFloat
    var top: CGFloat = 0 { didSet { place() } }

    init(_ view: some View, width: CGFloat = 520, height: CGFloat? = nil) {
        self.width = width
        host = NSHostingView(rootView: Self.wrap(view, width: width))
        let fitting = host.fittingSize
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height ?? fitting.height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height ?? fitting.height))
        window.contentView?.addSubview(host)
        place()
        window.makeKeyAndOrderFront(nil)
    }

    private static func wrap(_ view: some View, width: CGFloat) -> AnyView {
        AnyView(view.padding(padding).frame(width: width).background(Color.white).environment(\.colorScheme, .light))
    }

    /// Draws `view` in place of the reply, as a reply being written is drawn again.
    func show(_ view: some View) {
        host.rootView = Self.wrap(view, width: width)
        place()
    }

    private func place() {
        let height = host.fittingSize.height
        host.frame = NSRect(x: 0, y: (window.contentView?.bounds.height ?? 0) - height + top, width: width, height: height)
        host.layoutSubtreeIfNeeded()
    }

    /// The reply's own size, inside its padding.
    var size: CGSize { CGSize(width: host.bounds.width - 2 * Self.padding, height: host.bounds.height - 2 * Self.padding) }

    /// A point measured from the reply's top-left corner, in the window.
    func point(x: CGFloat, y: CGFloat) -> NSPoint {
        let y = Self.padding + y
        return host.convert(NSPoint(x: Self.padding + x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
    }

    func send(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!)
    }

    func click(at point: NSPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        send(.leftMouseDown, at: point, clicks: clicks, flags: flags)
        send(.leftMouseUp, at: point, clicks: clicks, flags: flags)
    }

    func drag(from start: NSPoint, to end: NSPoint) {
        send(.leftMouseDown, at: start)
        for step in 1...8 {
            let t = CGFloat(step) / 8
            send(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        send(.leftMouseUp, at: end)
    }

    /// What Copy puts on the pasteboard, nil if nothing. Sent along the window's responder chain,
    /// as Edit ▸ Copy is to the key window's (this one isn't key, as tests don't activate the app).
    func copy() -> String? {
        NSPasteboard.general.clearContents()
        _ = window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil)
        return NSPasteboard.general.string(forType: .string)
    }

    func selectAll() {
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil)
    }

    var surfaces: [ReplyTextSurface] {
        func surfaces(in view: NSView) -> [ReplyTextSurface] { ((view as? ReplyTextSurface).map { [$0] } ?? []) + view.subviews.flatMap(surfaces) }
        return surfaces(in: host)
    }

    /// The selection of the (first) reply.
    var selection: ReplySelectionController? { surfaces.lazy.compactMap(\.controller).first }

    func picture() -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.tiffRepresentation
    }

    func settle() async throws {
        for _ in 0..<4 {
            place()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
