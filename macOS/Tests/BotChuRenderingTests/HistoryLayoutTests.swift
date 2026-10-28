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
        let original = BrowsingFixture.messages(5_000)
        conversation.replace(original)
        app.saveThread(fixture.task)
        await app.storage.settle()
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
        func scrollTo(_ y: CGFloat, frames: Int = 4) async throws {
            // Already at the top, Show Earlier needs no synthetic scroll. A fake zero-delta
            // scroll on a collapsed page would request its next page instead of clicking it.
            if y != 0 || scroll.contentView.bounds.minY > 0.5 { Self.dragScroller(scroll, to: y) }
            try await settle(window, frames: frames)
            for _ in 0..<250 where conversation.isPaging { try await settle(window) }
            try #require(!conversation.isPaging)
        }
        func items() -> ChunkedArray<ActivityItem> {
            model.items(for: conversation.displayMessages, root: app.task(fixture.task)?.folder, epoch: conversation.epoch)
        }
        func earlier() async throws {
            if model.start(of: items()) > 0 { model.showEarlier(items: items()) }
            else {
                await withCheckedContinuation { done in
                    app.pageEarlier(fixture.task) { model.revealEarlier(); done.resume() }
                }
            }
            try await settle(window)
            #expect(conversation.messages.count <= PagedTranscript.residentLimit)
            #expect(conversation.displayMessages.count <= PagedTranscript.browsingLimit)
        }
        #expect(model.realized > 0)
        #expect(model.realized <= limit)
        #expect(conversation.summary.messageCount == ThreadSummary(original).messageCount)
        #expect(conversation.messages.map(\.id) == original.suffix(PagedTranscript.residentLimit).map(\.id))

        // At least ten Show Earlier actions and 400 items, including partial disk pages:
        // each clicked at the top keeps what the reader saw in place.
        var revealed: Set<UUID> = []
        for page in 0..<20 {
            try await scrollTo(0)
            let seen = try #require(picture(of: scroll, in: window))
            let anchor = BrowsingFixture.anchor(model)
            let start = model.start(of: items())
            let state = model.viewport.summary
            try await earlier()
            try await settle(window, frames: 12)
            revealed.formUnion(items()[model.start(of: items())...].map(\.id))
            #expect(model.realized <= limit)
            let now = anchor.flatMap { BrowsingFixture.position(model, $0.row) }
            try #require(picture(of: scroll, in: window) == seen,
                    "page \(page) from \(start) of \(items().count): reader's row at \(anchor.map { "\($0.at)" } ?? "-"), now \(now.map { "\($0)" } ?? "gone"); clip \(scroll.contentView.bounds.minY); before: \(state); after: \(model.viewport.summary)")
            if page >= 9 && revealed.count >= 400 { break }
        }
        #expect(revealed.count >= 400, "Earlier items remain reachable across bounded pages")

        // Paused at an old message while 1,000 items arrive and the reply streams below.
        try await scrollTo((scroll.documentView?.frame.height ?? 0) * 0.3)
        try await settle(window, frames: 10)
        model.peakRealized = model.realized
        let held = try #require(picture(of: scroll, in: window))
        let selected = conversation.displayMessages
        let incoming = (100_000..<101_400).map(BrowsingFixture.message)
        var grouped = ActivityTranscript()
        grouped.update(incoming)
        #expect(grouped.items.count >= 1_000)
        for offset in stride(from: 0, to: incoming.count, by: 20) {
            for message in incoming[offset..<min(offset + 20, incoming.count)] { conversation.append(message) }
            app.saveThread(fixture.task)
            try await Task.sleep(for: .milliseconds(5))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        conversation.append(ChatMessage(role: .assistant, text: "Streaming"))
        for i in 0..<20 {
            conversation.stream { $0[$0.count - 1].text += " token \(i) with **some** words" }
            try await Task.sleep(for: .milliseconds(10))
        }
        app.saveThread(fixture.task)
        await app.storage.settle()
        try await settle(window, frames: 12)
        #expect(model.peakRealized <= limit)
        try #require(picture(of: scroll, in: window) == held)
        #expect(conversation.displayMessages == selected, "The selected page's full text survives live-tail eviction")
        #expect(conversation.messages.count <= PagedTranscript.residentLimit)

        // Open back to the first page, then walk the complete history in both directions,
        // including pages evicted from memory. Follow the corrected position after each page.
        var progress = BrowsingFixture.Progress()
        while conversation.displayStart > 0 || model.start(of: items()) > 0 {
            try await scrollTo(0)
            try await earlier()
            try progress.check(conversation, model, scroll)
        }
        let expected = Set((original + incoming + conversation.messages.suffix(1)).map(\.id))
        var planned = Set<UUID>()
        progress = BrowsingFixture.Progress()
        model.peakRealized = model.realized
        try await scrollTo(0)
        for _ in 0..<4_000 {
            planned.formUnion(BrowsingFixture.plannedMessages(model, items: items()))
            let below = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
            if !conversation.hasLaterPage && below < 1 { break }
            // Approach a page edge as a wheel does, allowing its prefetch to lay out before
            // continuing, rather than dragging directly to the newest page's end.
            let step = scroll.contentView.bounds.height * 0.7
            let advance = conversation.hasLaterPage && below > 150 ? min(step, below - 150) : step
            try await scrollTo(scroll.contentView.bounds.minY + advance, frames: 2)
            try progress.check(conversation, model, scroll)
        }
        #expect(expected.subtracting(planned).isEmpty, "\(expected.subtracting(planned).count) messages unreachable scrolling down")
        planned.removeAll()
        progress = BrowsingFixture.Progress()
        for _ in 0..<4_000 {
            planned.formUnion(BrowsingFixture.plannedMessages(model, items: items()))
            if scroll.contentView.bounds.minY < 1 {
                if conversation.displayStart == 0 && model.start(of: items()) == 0 { break }
                try await earlier()
            } else {
                try await scrollTo(max(0, scroll.contentView.bounds.minY - scroll.contentView.bounds.height * 0.7), frames: 2)
            }
            try progress.check(conversation, model, scroll)
        }
        #expect(expected.subtracting(planned).isEmpty, "\(expected.subtracting(planned).count) messages unreachable scrolling up")
        #expect(model.peakRealized <= limit)

        // Back to the newest, and away and back: the newest rows only, at the end.
        conversation.showLatest()
        model.follow(.jumped)
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
        let conversation = app.conversation(fixture.task)
        conversation.replace([ChatMessage(role: .user, text: "Trace every file")] + calls
            + [ChatMessage(role: .assistant, text: "Traced.")])
        app.saveThread(fixture.task)
        await app.storage.settle()
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
        func scrollTo(_ y: CGFloat, frames: Int = 4) async throws {
            // Already at the top, Show Earlier needs no synthetic scroll. A fake zero-delta
            // scroll on a collapsed page would request its next page instead of clicking it.
            if y != 0 || scroll.contentView.bounds.minY > 0.5 { Self.dragScroller(scroll, to: y) }
            try await settle(window, frames: frames)
            for _ in 0..<250 where conversation.isPaging { try await settle(window) }
            try #require(!conversation.isPaging)
        }
        func items() -> ChunkedArray<ActivityItem> {
            model.items(for: conversation.displayMessages, root: app.task(fixture.task)?.folder, epoch: conversation.epoch)
        }
        func earlier() async throws {
            if model.start(of: items()) > 0 { model.showEarlier(items: items()) }
            else {
                await withCheckedContinuation { done in
                    app.pageEarlier(fixture.task) { model.revealEarlier(); done.resume() }
                }
            }
            try await settle(window)
            #expect(conversation.displayMessages.count <= PagedTranscript.browsingLimit)
            #expect(conversation.messages.count <= PagedTranscript.residentLimit)
        }
        model.peakRealized = model.realized
        #expect(model.realized > 10)
        #expect(model.realized <= limit)
        // In Raw, every call is a card of its own. Visit every card across all the pages;
        // prepending calls to a partial group keeps the same call at the reader's position.
        var planned = Set<UUID>()
        var progress = BrowsingFixture.Progress()
        for _ in 0..<4_000 {
            let current = items()
            planned.formUnion(BrowsingFixture.plannedMessages(model, items: current))
            if scroll.contentView.bounds.minY < 1 {
                if conversation.displayStart == 0 && model.start(of: current) == 0 { break }
                let anchor = try #require(model.viewport.plan.rows.first { $0.top + $0.height > (model.viewport.visibleTop ?? 0) })
                let message = try #require(BrowsingFixture.messages(in: anchor, items: current).first)
                let at = anchor.top - (model.viewport.visibleTop ?? 0)
                try await earlier()
                let now = model.viewport.plan.rows.first { BrowsingFixture.messages(in: $0, items: items()).contains(message) }
                    .map { $0.top - (model.viewport.visibleTop ?? 0) }
                #expect(now.map { abs($0 - at) < 1.5 } == true, "Paged exploration moved its call from \(at) to \(now.map(String.init(describing:)) ?? "gone")")
            } else {
                try await scrollTo(max(0, scroll.contentView.bounds.minY - scroll.contentView.bounds.height * 0.7), frames: 2)
            }
            try progress.check(conversation, model, scroll)
        }
        let expected = Set(calls.map(\.id))
        #expect(expected.subtracting(planned).isEmpty, "\(expected.subtracting(planned).count) raw calls were unreachable")
        #expect(model.peakRealized <= limit)
        // Detailed, opened and closed again and again, scrolling through it each time.
        defaults.set(ChatDensity.detailed.rawValue, forKey: ChatDensity.storageKey)
        try await settle(window, frames: 10)
        let entry = calls[2].id
        for round in 0..<4 {
            try await scrollTo(0)
            let group = try #require(items().first { if case .exploration = $0 { true } else { false } })
            let head = TranscriptViewport.RowID(item: group.id, part: 0)
            // Opened where the reader clicked it, it grows downward from its header.
            let clicked = try #require(BrowsingFixture.position(model, head))
            model.toggle(group.id, default: false)
            try await settle(window, frames: 10)
            #expect(model.realized <= limit)
            #expect(BrowsingFixture.position(model, head).map { abs($0 - clicked) < 1.5 } == true)
            if round == 0 { model.toggleExpanded(entry) }
            var reachable = Set<UUID>()
            progress = BrowsingFixture.Progress()
            for _ in 0..<100 {
                reachable.formUnion(conversation.displayMessages.filter { $0.role == .tool }.map(\.id))
                let current = try #require(items().first { if case .exploration = $0 { true } else { false } })
                #expect(model.isOpen(current.id, default: false), "A paged group's open state follows its calls")
                if !conversation.hasLaterPage { break }
                try await scrollTo(.greatestFiniteMagnitude)
                try progress.check(conversation, model, scroll)
            }
            #expect(expected.subtracting(reachable).isEmpty, "Detailed round \(round) could not reach \(expected.subtracting(reachable).count) calls")
            #expect(model.isExpanded(entry))
            let last = try #require(items().first { if case .exploration = $0 { true } else { false } })
            model.toggle(last.id, default: false)
            try await settle(window, frames: 10)
            #expect(model.realized <= limit)
            progress = BrowsingFixture.Progress()
            while conversation.displayStart > 0 || model.start(of: items()) > 0 {
                try await scrollTo(0)
                try await earlier()
                try progress.check(conversation, model, scroll)
            }
            #expect(conversation.displayMessages.contains { $0.id == entry })
            #expect(model.isExpanded(entry), "Details remain selected after eviction and reloading")
        }
        #expect(model.peakRealized <= limit)
    }

    /// Rich replies, code, tables and pictures above the reader, rendered late, shown again after
    /// memory pressure, at another width and in the other appearance: the row the reader is at
    /// stays where it is on the screen, and no blank space opens up in the visible part.
    @Test func lateHeightsAboveTheReaderDontMoveIt() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        // And pictures, which take their height once decoded.
        let workspace = try #require(app.bot(fixture.task.botID)?.workspace)
        let picture = try BotHome(workspace: workspace).saveImage(BrowsingFixture.png(), name: "screenshot.png")
        var messages = BrowsingFixture.richMessages(240)
        for index in stride(from: 8, to: messages.count, by: 24) {
            messages[index] = ChatMessage(role: .user, text: "Look at this", images: [picture])
        }
        app.conversation(fixture.task).replace(messages)
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
            Self.dragScroller(scroll, to: y)
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
    @MainActor struct Progress {
        private var last = ""
        private var stalled = 0

        mutating func check(_ state: ConversationState, _ model: TranscriptModel, _ scroll: NSScrollView) throws {
            let location = "\(state.displayStart):\(model.windowStart ?? -1):\(Int(scroll.contentView.bounds.minY.rounded()))"
            stalled = location == last ? stalled + 1 : 0
            last = location
            let diagnostic = "Paging stopped at \(location); later \(state.hasLaterPage)/\(model.hasLaterPage), loading \(state.isPaging); \(model.viewport.summary)"
            try #require(stalled < 5, Comment(rawValue: diagnostic))
        }
    }

    static func messages(in row: TranscriptViewport.Row, items: ChunkedArray<ActivityItem>) -> [UUID] {
        guard items.indices.contains(row.index) else { return [] }
        let item = items[row.index]
        guard case .exploration(let group) = item else { return [item.id] }
        switch row.split {
        case .calls: return [group.calls[row.part].id]
        case .opened where row.part > 0 && row.part <= group.entries.count:
            return group.calls(of: group.entries[row.part - 1]).map(\.id)
        case .opened: return []
        case .whole: return group.calls.map(\.id)
        }
    }

    static func plannedMessages(_ model: TranscriptModel, items: ChunkedArray<ActivityItem>) -> Set<UUID> {
        Set(model.viewport.plan.rows.flatMap { messages(in: $0, items: items) })
    }

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

    /// A 600 × 400 picture.
    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 600, height: 400).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
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
