import Foundation
import Testing
@testable import BotChuCore

/// The rows a chat lays out as the reader pages through its history (#110): bounded by the
/// visible part and the overscan, however much history is open or arrives, with the reader's row
/// kept in place, and heights only ever reused for the same content and layout.
private let root = "/work/BotChu"

private func call(_ index: Int, read: Bool = true, state: ChatMessage.ToolState = .done) -> ChatMessage {
    let path = "\(root)/Sources/Folder\(index % 5)/File\(index).swift"
    return read
        ? ChatMessage(role: .tool, toolID: "r\(index)", toolName: "Read", toolInput: path, toolOutput: "let x = \(index)", toolState: state)
        : ChatMessage(role: .tool, toolID: "b\(index)", toolName: "Bash", toolInput: "swift build", toolOutput: "Build complete!", toolState: state)
}

/// A long conversation: turns of a question, a few reads, a build and a reply.
private func conversation(_ count: Int, from start: Int = 0) -> [ChatMessage] {
    var messages: [ChatMessage] = []
    var index = start
    while messages.count < count {
        switch index % 7 {
        case 0: messages.append(ChatMessage(role: .user, text: "Step \(index): keep going with the next part."))
        case 1, 2, 3: messages.append(call(index))
        case 4: messages.append(call(index, read: false))
        default: messages.append(ChatMessage(role: .assistant, text: "Turn \(index) done.\n\n" + String(repeating: "A line of the reply. ", count: index % 23)))
        }
        index += 1
    }
    return messages
}

private func items(_ messages: [ChatMessage]) -> ChunkedArray<ActivityItem> {
    var transcript = ActivityTranscript(root: root)
    transcript.update(messages)
    return transcript.items
}

/// A thread's items kept up to date as it grows, as the chat keeps them.
private struct Thread {
    var messages: [ChatMessage]
    var transcript = ActivityTranscript(root: root)

    init(_ messages: [ChatMessage]) {
        self.messages = messages
        transcript.update(messages)
    }

    var items: ChunkedArray<ActivityItem> { transcript.items }

    mutating func append(_ more: [ChatMessage]) {
        messages += more
        transcript.update(messages)
    }

    mutating func stream(_ text: String) {
        messages[messages.count - 1].text += text
        transcript.update(messages)
    }
}

/// A chat laid out by a stand-in for SwiftUI: every row planned is measured at its true height,
/// and the scroll view goes where the viewport says the reader's row needs it.
private struct Layout {
    var viewport = TranscriptViewport()
    var items: ChunkedArray<ActivityItem>
    var start = 0
    var width = 640
    var density = 1
    var epoch = 0
    var pinned = true
    var opened: Set<UUID> = []
    var raw = false
    var height = 800.0
    /// What every row measures, as a real layout would: a fixed height per row, unlike the estimate.
    var scale = 1.37
    var top = 0.0
    var seen: Set<TranscriptViewport.RowID> = []
    var peak = 0

    init(_ items: ChunkedArray<ActivityItem>) { self.items = items }

    func trueHeight(_ row: TranscriptViewport.Row) -> Double {
        let jitter = Double(abs(row.id.item.uuidString.hashValue % 17))
        return (22 + jitter + (row.split == .whole ? 30 : 0)) * scale + Double(width % 7)
    }

    /// The reader scrolls to `y`.
    mutating func jump(to y: Double) {
        top = y
        viewport.scrolled(top: y, height: height)
        viewport.readerMoved()
        settle()
    }

    /// Plans, lays out, measures and scrolls until nothing changes.
    @discardableResult mutating func settle() -> TranscriptViewport.Plan {
        var plan = TranscriptViewport.Plan()
        for _ in 0..<20 {
            let opened = opened, raw = raw
            plan = viewport.plan(items, from: start, inputs: .init(width: width, density: density, dark: false, epoch: epoch), pinned: pinned) { _, item in
                guard case .exploration(let group) = item else { return .init() }
                if raw { return .init(split: .calls) }
                return .init(split: opened.contains(group.id) ? .opened : .whole)
            }
            peak = max(peak, plan.rows.count)
            var again = false
            for row in plan.rows {
                seen.insert(row.id)
                again = viewport.measured(row.id, signature: row.signature, height: trueHeight(row)) || again
            }
            let total = viewport.plan.total
            if pinned { top = max(0, total - height) }
            if let correction = viewport.correction { top = min(max(correction, -40), max(0, total - height)) }
            again = viewport.scrolled(top: top, height: height) || again
            if viewport.correction != nil { viewport.corrected(to: top) }
            if !again { break }
        }
        return viewport.plan
    }

    mutating func scroll(by delta: Double) {
        top = min(max(-40, top + delta), max(0, viewport.plan.total - height))
        let replan = viewport.scrolled(top: top, height: height)
        viewport.readerMoved()
        if replan { settle() }
    }

    /// Where a row is on the screen, if it is laid out.
    func onScreen(_ id: TranscriptViewport.RowID) -> Double? {
        viewport.plan.rows.first { $0.id == id }.map { $0.top - top }
    }

    /// The row at the top of the visible part.
    var topRow: TranscriptViewport.RowID? {
        viewport.plan.rows.first { $0.top + $0.height > top }?.id
    }
}

@Suite struct TranscriptViewportTests {
    @Test func aPartialGroupHeaderKeepsTheFollowingMessageInPlaceWhenEarlierCallsJoinIt() throws {
        let calls = (0..<50).map { call($0) }
        let reply = ChatMessage(role: .assistant, text: "The result below these calls.")
        var layout = Layout(items(Array(calls.suffix(20)) + [reply]))
        layout.pinned = false
        layout.settle()
        layout.jump(to: -20)
        let row = TranscriptViewport.RowID(item: reply.id, part: 0)
        let before = try #require(layout.onScreen(row))
        let next = items(calls + [reply])
        layout.viewport.relocateAnchor(from: layout.items, to: next)
        layout.items = next
        layout.epoch += 1
        layout.settle()
        #expect(layout.onScreen(row).map { abs($0 - before) < 0.5 } == true)
        // Native rows can measure on separate frames. Reports after the first correction must
        // not move the anchor back into the header that is still growing above this message.
        for growth in [20.0, 10.0] {
            let head = try #require(layout.viewport.plan.rows.first { $0.id.item != reply.id })
            _ = layout.viewport.measured(head.id, signature: head.signature, height: head.height + growth)
            let top = try #require(layout.viewport.correction)
            layout.viewport.corrected(to: top)
            _ = layout.viewport.scrolled(top: top, height: layout.height)
            let message = try #require(layout.viewport.plan.rows.first { $0.id == row })
            #expect(abs(message.top - top - before) < 0.5)
        }
        layout.jump(to: 0)
        #expect(layout.viewport.anchorRow?.row.item == next.first?.id,
                "A later reader scroll must choose its own anchor again")
    }

    @Test(arguments: [false, true]) func aCallKeepsItsPositionWhenPagingChangesItsGroupID(raw: Bool) throws {
        let calls = (0..<1_000).map { call($0) }
        var layout = Layout(items(Array(calls[256..<768])))
        layout.raw = raw
        layout.pinned = false
        layout.opened = Set(layout.items.map(\.id))
        layout.settle()
        layout.jump(to: layout.viewport.plan.total * 0.5)
        let row = try #require(layout.topRow)
        let before = try #require(layout.onScreen(row))
        let selected = calls[256 + row.part - (raw ? 0 : 1)].id
        for range in [128..<640, 384..<896] {
            let next = items(Array(calls[range]))
            layout.viewport.relocateAnchor(from: layout.items, to: next)
            layout.items = next
            layout.opened = Set(next.map(\.id))
            layout.epoch += 1
            layout.settle()
            let offset = try #require(calls[range].firstIndex { $0.id == selected }) - range.lowerBound
            let moved = TranscriptViewport.RowID(item: try #require(next.first?.id), part: offset + (raw ? 0 : 1))
            #expect(layout.onScreen(moved).map { abs($0 - before) < 0.5 } == true)
            #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
        }
    }

    /// #110's fixture: 5,000 messages, ten pages of earlier history opened, the reader paused at
    /// an old message, and 1,000 new items arriving: the rows laid out stay within the bound, the
    /// reader's row stays put, and the rows a delta lays out don't grow with what arrived.
    @Test func rowsStayBoundedWhilePagingAndAppending() {
        var thread = Thread(conversation(5_000))
        var layout = Layout(thread.items)
        let pageStart = max(0, layout.items.count - 40)
        layout.start = pageStart
        layout.settle()
        #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
        #expect(layout.viewport.plan.below < 1)
        // Ten pages of earlier history, the reader at the top each time.
        layout.pinned = false
        for page in 1...10 {
            layout.jump(to: -20)
            let first = try! #require(layout.topRow)
            let before = try! #require(layout.onScreen(first))
            layout.start = max(0, pageStart - 40 * page)
            layout.settle()
            #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
            // The row the reader was at stays where it was on the screen, the earlier ones above.
            #expect(abs((layout.onScreen(first) ?? .infinity) - before) < 0.5)
        }
        #expect(layout.viewport.plan.start == pageStart - 400)
        // Paused at an old message, a little way down.
        layout.scroll(by: 1_500)
        layout.settle()
        let held = try! #require(layout.topRow)
        let heldAt = try! #require(layout.onScreen(held))
        let rowsBefore = Set(layout.viewport.plan.rows.map(\.id))
        // 1,000 new items, in batches as a turn writes them.
        var added = 0
        var index = 100_000
        while added < 1_000 {
            let before = layout.items.count
            thread.append(conversation(14, from: index))
            index += 14
            layout.items = thread.items
            added += layout.items.count - before
            layout.settle()
            #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
            #expect(abs((layout.onScreen(held) ?? .infinity) - heldAt) < 0.5)
            // Nothing new is laid out: it arrives below, as space.
            #expect(Set(layout.viewport.plan.rows.map(\.id)) == rowsBefore)
        }
        #expect(layout.peak <= TranscriptViewport.rowLimit)
        // Back at the newest content, and switching away and back: the tail only.
        layout.pinned = true
        layout.start = max(0, layout.items.count - 40)
        layout.settle()
        #expect(layout.viewport.plan.below < 1)
        #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
        #expect(layout.viewport.plan.rows.last?.index == layout.items.count - 1)
    }

    /// Paging down from the oldest open item to the newest, then back up: every row is laid out
    /// at some point, none beyond the bound at any.
    @Test func everyRowIsReachableInBothDirections() {
        var layout = Layout(items(conversation(1_200)))
        layout.start = 0
        layout.pinned = false
        layout.jump(to: 0)
        while layout.top < layout.viewport.plan.total - layout.height - 1 {
            layout.scroll(by: 300)
            #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
        }
        let down = layout.seen
        while layout.top > 0 {
            layout.scroll(by: -300)
            #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
        }
        #expect(layout.peak <= TranscriptViewport.rowLimit)
        let all = layout.items.map { TranscriptViewport.RowID(item: $0.id, part: 0) }
        #expect(Set(all).isSubset(of: down))
        #expect(layout.viewport.plan.rows.first?.index == 0)
    }

    /// A single group of 5,000 calls, in Raw and opened again and again in Detailed: it is laid
    /// out a screenful at a time, as an outer row alone isn't.
    @Test func aGroupOfFiveThousandCallsIsLaidOutAScreenAtATime() {
        let messages = [ChatMessage(role: .user, text: "Trace it")] + (0..<5_000).map { call($0) }
            + [ChatMessage(role: .assistant, text: "Done.")]
        var layout = Layout(items(messages))
        guard case .exploration(let group) = layout.items[1] else { Issue.record("no group"); return }
        #expect(group.calls.count == 5_000)
        layout.raw = true
        layout.settle()
        #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
        #expect(layout.viewport.plan.total > 5_000 * 20)
        layout.pinned = false
        for _ in 0..<40 { layout.scroll(by: -2_000) }
        #expect(layout.peak <= TranscriptViewport.rowLimit)
        layout.raw = false
        for _ in 0..<5 {
            layout.opened = [group.id]
            layout.jump(to: 0)
            #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
            for _ in 0..<10 { layout.scroll(by: 1_500) }
            layout.opened = []
            layout.settle()
            #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
        }
        #expect(layout.peak <= TranscriptViewport.rowLimit)
    }

    /// A height measured for other content or another layout is never used, and a measurement
    /// from a row no longer laid out, or laid out since with other content, is dropped. (Another
    /// width keeps the heights: `aResizeKeepsTheRowsLaidOutAndMeasuresThemAgain`.)
    @Test func heightsAreKeptOnlyForTheSameContentAndLayout() {
        var thread = Thread(conversation(400) + [ChatMessage(role: .assistant, text: "Writing")])
        var layout = Layout(thread.items)
        layout.start = 0
        layout.settle()
        let last = try! #require(layout.viewport.plan.rows.last)
        // Streaming into the last message: its old height isn't its height any more.
        thread.stream(" and more words being written")
        layout.items = thread.items
        layout.settle()
        let streamed = try! #require(layout.viewport.plan.rows.last)
        #expect(streamed.id == last.id)
        #expect(streamed.signature != last.signature)
        let dropped = layout.viewport.droppedMeasurements
        let stale = layout.viewport.measured(last.id, signature: last.signature, height: 999)
        #expect(!stale)
        #expect(layout.viewport.droppedMeasurements == dropped + 1)
        #expect(layout.viewport.plan.rows.last?.height != 999)
        // A row scrolled far away: its measurement no longer reaches anything.
        let away = try! #require(layout.viewport.plan.rows.first)
        layout.pinned = false
        layout.jump(to: 0)
        #expect(!layout.viewport.plan.rows.contains { $0.id == away.id })
        let gone = layout.viewport.measured(away.id, signature: away.signature, height: 5)
        #expect(!gone)
        #expect(layout.viewport.droppedMeasurements == dropped + 2)
        // Each layout input but the width, and the conversation's epoch, measures again.
        for change in 0..<3 {
            switch change {
            case 0: layout.density = 0
            case 1: layout.scale = 1.1
            default: layout.epoch += 1
            }
            let before = layout.viewport.plan.rows.map(\.signature)
            layout.settle()
            // No height is reused: they're reused only for the same signature.
            if change != 1 { #expect(Set(layout.viewport.plan.rows.map(\.signature)).isDisjoint(with: before)) }
        }
    }

    /// A resize leaves the rows laid out as they are (#354): the frames a window goes through on the
    /// way to its new size, where the chat is briefly a strip and at other widths, plan nothing
    /// again; a new width keeps every row and its signature, and the rows laid out measure
    /// themselves again at it, as do those out of view once they're laid out.
    @Test func aResizeKeepsTheRowsLaidOutAndMeasuresThemAgain() throws {
        var layout = Layout(items(conversation(2_000)))
        layout.start = 0
        layout.settle()
        let inputs = { (width: Int) in TranscriptViewport.Inputs(width: width, density: 1, dark: false, epoch: 0) }
        // A strip, then the height it was planned for: the rows planned cover both.
        for height in [52.0, layout.height] {
            let replan = layout.viewport.scrolled(top: max(0, layout.viewport.plan.total - height), height: height)
            #expect(!replan)
        }
        for width in [492, 392, 567] {
            let before = layout.viewport.plan(layout.items, from: 0, inputs: inputs(layout.width), pinned: true) { _, _ in .init() }
            layout.width = width
            let plan = layout.viewport.plan(layout.items, from: 0, inputs: inputs(width), pinned: true) { _, _ in .init() }
            #expect(plan == before)
            #expect(layout.viewport.rebuiltRows == 0)
            layout.settle()
            for row in layout.viewport.plan.rows { #expect(abs(row.height - layout.trueHeight(row)) < 0.01) }
        }
        // Rows out of view kept their heights; laid out again, they're measured at the new width.
        layout.pinned = false
        layout.jump(to: 0)
        let first = try #require(layout.viewport.plan.rows.first)
        #expect(abs(first.height - layout.trueHeight(first)) < 0.01)
        // Taller than the rows were planned for, the chat plans again.
        let taller = layout.viewport.scrolled(top: 0, height: layout.height + 200)
        #expect(taller)
    }

    /// Half as wide, its rows twice as tall: the reader's row stays where it is on the screen, and
    /// scrolling up through rows that kept the heights they were measured at in the wider window
    /// measures them again, with the row the reader is at in place and no blank space.
    @Test func aMuchNarrowerWindowKeepsTheReaderInPlaceThroughRowsMeasuredWider() throws {
        var layout = Layout(items(conversation(2_000)))
        layout.start = 0
        layout.settle()
        layout.pinned = false
        // Rows above the reader measured at the wider width, then out of view.
        layout.jump(to: 27_000)
        layout.jump(to: 30_000)
        let row = try #require(layout.topRow)
        let at = try #require(layout.onScreen(row))
        // The stand-in's heights hardly depend on the width: twice the scale is what half the width does.
        layout.width = 320
        layout.scale *= 2
        layout.settle()
        #expect(abs((layout.onScreen(row) ?? .infinity) - at) < 0.5)
        for _ in 0..<12 {
            layout.top -= 300
            _ = layout.viewport.scrolled(top: layout.top, height: layout.height)
            layout.viewport.readerMoved()
            let reader = try #require(layout.topRow)
            let shown = try #require(layout.onScreen(reader))
            layout.settle()
            #expect(abs((layout.onScreen(reader) ?? .infinity) - shown) < 0.5)
            let rows = layout.viewport.plan.rows
            #expect(rows.allSatisfy { abs($0.height - layout.trueHeight($0)) < 0.01 })
            let first = try #require(rows.first), last = try #require(rows.last)
            #expect(first.top <= max(0, layout.top) + 0.5 || layout.viewport.plan.above < 0.5)
            #expect(last.top + last.height >= min(layout.top + layout.height, layout.viewport.plan.total) - 0.5)
        }
    }

    /// A row first measured at another width than it was guessed at teaches the guesses nothing.
    @Test func guessesForAnotherWidthTeachNothing() {
        let items = items(conversation(40))
        let inputs = TranscriptViewport.Inputs(width: 640, density: 1, dark: false, epoch: 0)
        func estimated(measuredAt width: Int) -> Double {
            var viewport = TranscriptViewport()
            let plan = viewport.plan(items, from: 0, inputs: inputs, pinned: true) { _, _ in .init() }
            _ = viewport.scrolled(top: max(0, plan.total - 800), height: 800, width: width)
            for row in plan.rows { _ = viewport.measured(row.id, signature: row.signature, height: row.height * 3) }
            viewport.forgetHeights()
            return viewport.plan(items, from: 0, inputs: inputs, pinned: true) { _, _ in .init() }.total
        }
        #expect(estimated(measuredAt: 640) > estimated(measuredAt: 320) * 2)
    }

    /// The reader's row stays where it is on the screen while rows above it change: measured for
    /// the first time, grown late (a rendered reply), at another width, or forgotten under memory
    /// pressure; but not while pinned to the newest content.
    @Test func theReadersRowStaysPutWhileRowsAboveChange() {
        var layout = Layout(items(conversation(2_000)))
        layout.start = 0
        layout.settle()
        layout.pinned = false
        layout.jump(to: 30_000)
        let row = try! #require(layout.topRow)
        let at = try! #require(layout.onScreen(row))
        let first = try! #require(layout.viewport.plan.rows.first)
        // A row above it grows late, as a reply's math renders.
        _ = layout.viewport.measured(first.id, signature: first.signature, height: layout.trueHeight(first) + 300)
        let corrected = try! #require(layout.viewport.correction)
        #expect(abs(corrected - (layout.top + 300)) < 0.5)
        layout.top = corrected
        layout.viewport.scrolled(top: corrected, height: layout.height)
        #expect(layout.viewport.correction == nil)
        #expect(abs((layout.onScreen(row) ?? .infinity) - at) < 0.5)
        for change in 0..<3 {
            switch change {
            case 0: layout.width = 420
            case 1: layout.scale = 0.8
            default: layout.viewport.forgetHeights()
            }
            layout.settle()
            #expect(layout.viewport.plan.rows.contains { $0.id == row })
            #expect(abs((layout.onScreen(row) ?? .infinity) - at) < 0.5)
        }
        // Rows moved below the reader, or under a pinned reader, ask for nothing.
        let last = try! #require(layout.viewport.plan.rows.last)
        _ = layout.viewport.measured(last.id, signature: last.signature, height: last.height + 200)
        #expect(layout.viewport.correction == nil)
        layout.pinned = true
        layout.settle()
        let tail = try! #require(layout.viewport.plan.rows.first)
        _ = layout.viewport.measured(tail.id, signature: tail.signature, height: tail.height + 200)
        #expect(layout.viewport.correction == nil)
    }

    /// A card opened while the chat follows grows downward from where it was clicked: the chat
    /// stops following in the same update, and the reader's row is where they were looking.
    @Test func aCardOpenedWhileFollowingGrowsFromWhereItWasClicked() {
        let messages = [ChatMessage(role: .user, text: "Trace it")] + (0..<5_000).map { call($0) }
            + [ChatMessage(role: .assistant, text: "Done.")]
        var layout = Layout(items(messages))
        layout.settle()
        guard case .exploration(let group) = layout.items[1] else { Issue.record("no group"); return }
        let head = TranscriptViewport.RowID(item: group.id, part: 0)
        let clicked = try! #require(layout.onScreen(head))
        layout.opened = [group.id]
        // The update that opens it plans while still pinned, then the chat no longer follows.
        _ = layout.viewport.plan(layout.items, from: 0, inputs: .init(width: layout.width, density: 1, dark: false, epoch: 0), pinned: true) { _, item in
            if case .exploration = item { return .init(split: .opened) }
            return .init()
        }
        layout.pinned = false
        layout.settle()
        #expect(layout.onScreen(head).map { abs($0 - clicked) < 0.5 } == true)
        #expect(layout.viewport.plan.rows.count <= TranscriptViewport.rowLimit)
    }

    /// A reader who went to the very end without following stays there as the rows near it are
    /// measured taller than estimated, so the chat sees them at the bottom and follows again.
    @Test func aReaderAtTheEndStaysThere() {
        var layout = Layout(items(conversation(2_000)))
        layout.start = 0
        layout.settle()
        layout.pinned = false
        layout.jump(to: 10_000)
        layout.scale = 1.6
        layout.viewport.forgetHeights()
        layout.jump(to: layout.viewport.plan.total - layout.height)
        layout.scale = 2.1
        layout.viewport.forgetHeights()
        layout.settle()
        #expect(abs(layout.top - (layout.viewport.plan.total - layout.height)) < 0.5)
    }

    /// The rows moved in the scroll view (the intro above them changed height): the reader's row
    /// is held where it was.
    @Test func rowsMovedUnderTheReaderAreHeld() {
        var layout = Layout(items(conversation(600)))
        layout.settle()
        layout.pinned = false
        layout.jump(to: 2_000)
        layout.viewport.hold(visibleTop: layout.top - 48)
        #expect(layout.viewport.correction.map { abs($0 - layout.top) < 0.5 } == true)
        layout.viewport.corrected(to: layout.top)
        layout.viewport.hold(visibleTop: layout.top)
        #expect(layout.viewport.correction == nil)
    }

    /// Heights are kept for the items that can be scrolled to and a few more; the rest go.
    @Test func heightsOfItemsOutOfReachGo() {
        var layout = Layout(items(conversation(3_000)))
        layout.start = 0
        layout.settle()
        let all = layout.viewport.keptItems
        #expect(all == layout.items.count)
        layout.start = layout.items.count - 40
        layout.settle()
        #expect(layout.viewport.keptItems == 40)
        layout.viewport.forgetHeights()
        #expect(layout.viewport.keptItems == 0)
    }

    @Test func linesAreEstimatedFromTheText() {
        #expect(TranscriptViewport.lines("short", width: 600, character: 7.5) == 1)
        #expect(TranscriptViewport.lines("a\nb\nc", width: 600, character: 7.5) == 3)
        #expect(TranscriptViewport.lines(String(repeating: "x", count: 800), width: 600, character: 7.5) == 10)
    }
}
