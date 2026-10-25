import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// Reading earlier history while the agent works (#110): the chat lays out only the rows near the
/// visible part, counted as they appear and go, however many pages are open and items arrive; the
/// reader's place holds, by what is on the screen; and every row can still be reached, both ways.
extension RenderingTests {
    @Test func browsingHistoryKeepsTheRowsLaidOutBoundedAndTheReadersPlace() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        let conversation = app.conversation(fixture.task)
        conversation.replace(BrowsingFixture.messages(5_000))
        TranscriptCache.forget(fixture.task)
        app.runStates[fixture.task] = RunState(hasOutput: true)
        app.show(fixture.task)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        let defaults = UserDefaults(suiteName: fixture.domain)!
        let host = NSHostingView(rootView: AnyView(ChatView(target: fixture.task).id(fixture.task).environment(app).defaultAppStorage(defaults)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let model = TranscriptCache.model(for: fixture.task)
        for _ in 0..<500 where model.isLoadingEarlier { try await Task.sleep(for: .milliseconds(20)) }
        try await settle(window)
        let limit = TranscriptViewport.rowLimit
        let scroll = try #require(Self.chatScrollView(in: host))
        func scrollTo(_ y: CGFloat) async throws {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(window)
        }
        func items() -> ChunkedArray<ActivityItem> {
            model.items(for: app.thread(fixture.task), root: app.task(fixture.task)?.folder, epoch: conversation.epoch)
        }
        #expect(model.realized > 0)
        #expect(model.realized <= limit)
        #expect(items().count > 3_000)

        // Ten pages of earlier items, each clicked at the top: what the reader saw stays put.
        for page in 0..<10 {
            try await scrollTo(0)
            let seen = try #require(picture(of: scroll, in: window))
            let anchor = BrowsingFixture.anchor(model)
            let start = model.start(of: items())
            let state = model.viewport.summary
            model.showEarlier(items: items())
            try await settle(window, frames: 12)
            #expect(model.realized <= limit)
            let now = anchor.flatMap { BrowsingFixture.position(model, $0.row) }
            #expect(picture(of: scroll, in: window) == seen,
                    "page \(page) from \(start) of \(items().count): reader's row at \(anchor.map { "\($0.at)" } ?? "-"), now \(now.map { "\($0)" } ?? "gone"); clip \(scroll.contentView.bounds.minY); before: \(state); after: \(model.viewport.summary)")
        }
        let open = items().count - model.start(of: items())
        #expect(open >= 400)

        // Paused at an old message while 1,000 items arrive and the reply streams below.
        try await scrollTo((scroll.documentView?.frame.height ?? 0) * 0.3)
        try await settle(window, frames: 10)
        model.peakRealized = model.realized
        let held = try #require(picture(of: scroll, in: window))
        let before = items().count
        var index = 0
        while items().count < before + 1_000 {
            for _ in 0..<20 {
                conversation.append(BrowsingFixture.message(100_000 + index))
                index += 1
            }
            try await Task.sleep(for: .milliseconds(5))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        conversation.append(ChatMessage(role: .assistant, text: "Streaming"))
        for i in 0..<20 {
            conversation.stream { $0[$0.count - 1].text += " token \(i) with **some** words" }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await settle(window, frames: 12)
        #expect(model.peakRealized <= limit)
        #expect(picture(of: scroll, in: window) == held)

        // Down through everything open, then up again: every row is laid out at some point,
        // never more than the bound at once.
        var planned: Set<UUID> = []
        try await scrollTo(0)
        model.peakRealized = model.realized
        var y: CGFloat = 0
        while y < (scroll.documentView?.frame.height ?? 0) {
            planned.formUnion(model.viewport.plan.rows.map(\.id.item))
            y += 1_000
            try await scrollTo(y)
        }
        planned.formUnion(model.viewport.plan.rows.map(\.id.item))
        let reachable = items()[model.start(of: items())...].map(\.id)
        #expect(Set(reachable).isSubset(of: planned))
        while y > 0 {
            y -= 1_500
            try await scrollTo(y)
        }
        #expect(model.peakRealized <= limit)

        // Back to the newest, and away and back: the newest rows only, at the end.
        try await scrollTo(.greatestFiniteMagnitude)
        try await settle(window, frames: 10)
        #expect(model.realized <= limit)
        let below = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
        #expect(below < 40)
        host.rootView = AnyView(ChatView(target: .home(fixture.task.botID)).id(ChatTarget.home(fixture.task.botID)).environment(app).defaultAppStorage(defaults))
        try await settle(window)
        #expect(model.realized == 0)
        host.rootView = AnyView(ChatView(target: fixture.task).id(fixture.task).environment(app).defaultAppStorage(defaults))
        try await settle(window, frames: 10)
        #expect(model.realized > 0)
        #expect(model.realized <= limit)
        let again = try #require(Self.chatScrollView(in: host, minimum: 0))
        #expect((again.documentView?.frame.height ?? 0) - again.contentView.bounds.maxY < 40)
        #expect(model.windowStart == nil, "\(items().count) items; \(model.viewport.summary)")
    }

    /// A single group of 5,000 calls, in Raw and opened again and again in Detailed: a screenful of
    /// its calls is laid out at a time, and a call's details stay open as it goes and comes back.
    @Test func aGroupOfFiveThousandCallsIsLaidOutAScreenAtATime() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        let calls = (0..<5_000).map { BrowsingFixture.read($0) }
        app.conversation(fixture.task).replace([ChatMessage(role: .user, text: "Trace every file")] + calls
            + [ChatMessage(role: .assistant, text: "Traced.")])
        TranscriptCache.forget(fixture.task)
        app.show(fixture.task)
        let defaults = UserDefaults(suiteName: fixture.domain)!
        defaults.set(ChatDensity.raw.rawValue, forKey: ChatDensity.storageKey)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: AnyView(ChatView(target: fixture.task).id(fixture.task).environment(app).defaultAppStorage(defaults)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let model = TranscriptCache.model(for: fixture.task)
        for _ in 0..<500 where model.isLoadingEarlier { try await Task.sleep(for: .milliseconds(20)) }
        try await settle(window, frames: 10)
        let limit = TranscriptViewport.rowLimit
        let scroll = try #require(Self.chatScrollView(in: host))
        func scrollTo(_ y: CGFloat) async throws {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(window)
        }
        model.peakRealized = model.realized
        #expect(model.realized > 10)
        #expect(model.realized <= limit)
        // In Raw, every call is a card of its own: scroll a long way up through them.
        #expect((scroll.documentView?.frame.height ?? 0) > 5_000 * 20)
        let bottom = scroll.contentView.bounds.minY
        for step in 1...20 { try await scrollTo(bottom - CGFloat(step) * 4_000) }
        #expect(model.peakRealized <= limit)
        // Detailed, opened and closed again and again, scrolling through it each time.
        defaults.set(ChatDensity.detailed.rawValue, forKey: ChatDensity.storageKey)
        try await settle(window, frames: 10)
        let group = try #require(model.items(for: app.thread(fixture.task), root: app.task(fixture.task)?.folder,
                                             epoch: app.conversation(fixture.task).epoch).first { if case .exploration = $0 { true } else { false } })
        let entry = calls[2].id
        let head = TranscriptViewport.RowID(item: group.id, part: 0)
        for round in 0..<4 {
            try await scrollTo(0)
            // Opened where the reader clicked it, it grows downward from its header.
            let clicked = try #require(BrowsingFixture.position(model, head))
            model.toggle(group.id, default: false)
            try await settle(window, frames: 10)
            #expect(model.realized <= limit)
            #expect(BrowsingFixture.position(model, head).map { abs($0 - clicked) < 1.5 } == true)
            if round == 0 { model.toggleExpanded(entry) }
            for step in 1...8 { try await scrollTo(CGFloat(step) * 9_000) }
            #expect(model.isExpanded(entry))
            model.toggle(group.id, default: false)
            try await settle(window, frames: 10)
            #expect(model.realized <= limit)
        }
        #expect(model.peakRealized <= limit)
    }

    /// Rich replies, code, tables and images above the reader, rendered late, shown again after
    /// memory pressure, at another width and in the other appearance: the row the reader is at
    /// stays where it is on the screen, and no blank space opens up in the visible part.
    @Test func lateHeightsAboveTheReaderDontMoveIt() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.conversation(fixture.task).replace(BrowsingFixture.richMessages(240))
        TranscriptCache.forget(fixture.task)
        app.show(fixture.task)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil; window.close() }
        let defaults = UserDefaults(suiteName: fixture.domain)!
        let host = NSHostingView(rootView: AnyView(ChatView(target: fixture.task).id(fixture.task).environment(app).defaultAppStorage(defaults)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await settle(window, frames: 20)
        let model = TranscriptCache.model(for: fixture.task)
        let scroll = try #require(Self.chatScrollView(in: host))
        model.showEarlier(items: model.items(for: app.thread(fixture.task), root: app.task(fixture.task)?.folder, epoch: app.conversation(fixture.task).epoch))
        try await settle(window, frames: 20)
        func scrollTo(_ y: CGFloat) async throws {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(window, frames: 2)
        }
        func holds(_ what: String, while change: () async throws -> Void) async throws {
            let anchor = try #require(BrowsingFixture.anchor(model))
            try await change()
            let now = BrowsingFixture.position(model, anchor.row)
            #expect(now.map { abs($0 - anchor.at) < 1.5 } == true, "\(what): moved from \(anchor.at) to \(now.map { "\($0)" } ?? "gone")")
            #expect(BrowsingFixture.covered(model, scroll), "\(what): blank space in the visible part")
        }
        // Halfway up, with rich replies laid out above it still to render: they render and grow.
        let middle = (scroll.documentView?.frame.height ?? 0) * 0.45
        try await scrollTo(middle)
        try await holds("rich replies rendered") { try await settle(window, frames: 60) }
        // Memory pressure while they're out of view: kept web views and heights go, and coming
        // back they're estimated, made again and rendered again.
        try await scrollTo(.greatestFiniteMagnitude)
        try await settle(window, frames: 10)
        RichReplyPool.removeAll()
        TranscriptCache.relievePressure()
        model.forgetHeights()
        try await scrollTo(middle)
        try await holds("shown again after memory pressure") { try await settle(window, frames: 60) }
        // Narrower, then the other appearance.
        try await holds("narrower window") {
            window.setContentSize(NSSize(width: 820, height: 760))
            try await settle(window, frames: 40)
        }
        try await holds("dark appearance") {
            window.appearance = NSAppearance(named: .darkAqua)
            try await settle(window, frames: 30)
        }
        #expect(model.realized <= TranscriptViewport.rowLimit)
    }

    /// Lets the chat lay out, measure and correct for a few frames.
    private func settle(_ window: NSWindow, frames: Int = 4) async throws {
        for _ in 0..<frames {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    /// The middle of the chat's visible part as drawn, left of its scroller: equal pictures mean
    /// what the reader sees there didn't move.
    private func picture(of scroll: NSScrollView, in window: NSWindow) -> Data? {
        guard let content = window.contentView else { return nil }
        let visible = scroll.convert(scroll.contentView.frame, to: content)
        let band = NSRect(x: visible.minX, y: visible.minY + visible.height * 0.3, width: visible.width - 24, height: visible.height * 0.4).integral
        guard let rep = content.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        content.cacheDisplay(in: band, to: rep)
        guard let data = rep.bitmapData else { return nil }
        return Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh)
    }
}

@MainActor enum BrowsingFixture {
    static func read(_ index: Int) -> ChatMessage {
        let path = "/work/repo/Sources/Folder\(index % 5)/File\(index).swift"
        return ChatMessage(role: .tool, toolID: "r\(index)", toolName: "Read", toolInput: path, toolOutput: "let x = \(index)", toolState: .done)
    }

    /// Turns of a question, reads, a build and a reply with code and a table.
    static func message(_ index: Int) -> ChatMessage {
        switch index % 7 {
        case 0: ChatMessage(role: .user, text: "Step \(index): keep going with the next part.")
        case 1, 2, 3: read(index)
        case 4: ChatMessage(role: .tool, toolID: "b\(index)", toolName: "Bash", toolInput: "swift build", toolOutput: "Build complete!", toolState: .done)
        case 5: ChatMessage(role: .assistant, text: "Turn \(index) done.\n\n```swift\nlet value = \(index)\nprint(value)\n```")
        default: ChatMessage(role: .assistant, text: "| File | Lines |\n| --- | ---: |\n| A\(index).swift | \(index) |\n| B.swift | 12 |\n\nAnd a sentence after the table, long enough to wrap onto a second line in a narrow chat.")
        }
    }

    static func messages(_ count: Int) -> [ChatMessage] { (0..<count).map(message) }

    /// Replies with math, a diagram, a table and code, between questions.
    static func richMessages(_ count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            switch index % 4 {
            case 0: ChatMessage(role: .user, text: "Question \(index)")
            case 1: ChatMessage(role: .assistant, text: "The sum is $$\\sum_{i=1}^{\(index)} i^2 = \\frac{n(n+1)(2n+1)}{6}$$ as before.")
            case 2: ChatMessage(role: .assistant, text: "```mermaid\ngraph TD\n  A\(index) --> B\n  B --> C\n```\n\nThe flow above.")
            default: message(5 + index % 2)
            }
        }
    }

    static func anchor(_ model: TranscriptModel) -> (row: TranscriptViewport.RowID, at: Double)? {
        guard let top = model.viewport.visibleTop,
              let row = model.viewport.plan.rows.first(where: { $0.top + $0.height > top }) else { return nil }
        return (row.id, row.top - top)
    }

    static func position(_ model: TranscriptModel, _ id: TranscriptViewport.RowID) -> Double? {
        guard let top = model.viewport.visibleTop, let row = model.viewport.plan.rows.first(where: { $0.id == id }) else { return nil }
        return row.top - top
    }

    /// The rows laid out cover the visible part (or reach the ends of what can be scrolled to).
    static func covered(_ model: TranscriptModel, _ scroll: NSScrollView) -> Bool {
        let plan = model.viewport.plan
        guard let top = model.viewport.visibleTop, let height = model.viewport.viewport,
              let first = plan.rows.first, let last = plan.rows.last else { return false }
        return (first.top <= max(0, top) + 0.5 || plan.above < 0.5) && (last.top + last.height >= min(top + height, plan.total) - 0.5)
    }
}
