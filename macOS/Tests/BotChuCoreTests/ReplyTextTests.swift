import Foundation
import Testing
@testable import BotChuCore

/// #156: a reply's text selected across its blocks, and copied in reading order.
@Suite struct ReplyTextTests {
    static let reply = """
    ## Heading

    A **bold** [link](https://example.com).

    - One
    - Two
      1. Nested

    > Quoted

    ```swift
    let x = 1

    let y = 2
    ```

    | A | B |
    | --- | --- |
    | 1 | |

    ---

    Last.
    """

    /// Each text the view draws is a piece, in reading order, keyed by its block's path; copying
    /// all of them puts blank lines between blocks, line breaks between items and rows (a nested
    /// list indented by a tab), a space after a marker and tabs between cells, and leaves out the
    /// rule.
    @Test func piecesAreTheReplysTextsInReadingOrder() throws {
        let text = ReplyText(blocks: MarkdownBlock.split(Self.reply))
        typealias Key = ReplyText.Key
        #expect(text.pieces.map(\.key) == [
            Key(path: [0], part: .text), Key(path: [1], part: .text),
            Key(path: [2, 0], part: .marker), Key(path: [2, 0, 0], part: .text),
            Key(path: [2, 1], part: .marker), Key(path: [2, 1, 0], part: .text),
            Key(path: [2, 1, 1, 0], part: .marker), Key(path: [2, 1, 1, 0, 0], part: .text),
            Key(path: [3, 0], part: .text), Key(path: [4], part: .code),
            Key(path: [5, 0], part: .cell(0)), Key(path: [5, 0], part: .cell(1)),
            Key(path: [5, 1], part: .cell(0)), Key(path: [5, 1], part: .cell(1)),
            Key(path: [7], part: .text),
        ])
        #expect(text.index(of: Key(path: [4], part: .code)) == 9)
        let whole = try #require(text.whole)
        #expect(text.string(in: whole) == """
        Heading

        A bold link.

        • One
        • Two
        \t1. Nested

        Quoted

        let x = 1

        let y = 2

        A\tB
        1\t

        Last.
        """)
        #expect(text.pieces[1].links == [ReplyText.Link(range: 7..<11, url: URL(string: "https://example.com")!)])
        #expect(text.link(at: ReplyPosition(piece: 1, offset: 8)) == URL(string: "https://example.com"))
        #expect(text.link(at: ReplyPosition(piece: 1, offset: 4)) == nil)
    }

    /// Part of the first piece to part of a later one, either way round; the parts of the pieces
    /// between are whole, and each piece's range is what it draws selected.
    @Test func aSelectionCopiesItsPartsWithWhatGoesBetweenThem() {
        let text = ReplyText(blocks: MarkdownBlock.split(Self.reply))
        let forward = ReplySelection(anchor: ReplyPosition(piece: 0, offset: 3), focus: ReplyPosition(piece: 3, offset: 2))
        #expect(text.string(in: forward) == "ding\n\nA bold link.\n\n• On")
        let backward = ReplySelection(anchor: forward.focus, focus: forward.anchor)
        #expect(text.string(in: backward) == text.string(in: forward))
        #expect(text.range(of: 0, in: forward) == 3..<7)
        #expect(text.range(of: 1, in: forward) == 0..<12)
        #expect(text.range(of: 3, in: forward) == 0..<2)
        #expect(text.range(of: 4, in: forward) == nil)
        // Within one piece, and nothing for an empty selection.
        #expect(text.string(in: ReplySelection(anchor: ReplyPosition(piece: 9, offset: 4), focus: ReplyPosition(piece: 9, offset: 9))) == "x = 1")
        let caret = ReplySelection(anchor: ReplyPosition(piece: 1, offset: 2), focus: ReplyPosition(piece: 1, offset: 2))
        #expect(text.string(in: caret) == "")
        #expect(text.range(of: 1, in: caret) == nil)
        // From the end of one piece to the start of another takes neither, nor what goes between.
        let across = ReplySelection(anchor: ReplyPosition(piece: 0, offset: 7), focus: ReplyPosition(piece: 2, offset: 0))
        #expect(text.string(in: across) == "A bold link.")
        let boundary = ReplySelection(anchor: ReplyPosition(piece: 0, offset: 7), focus: ReplyPosition(piece: 1, offset: 0))
        #expect(text.string(in: boundary) == "")
    }

    /// Offsets are UTF-16, as the layout counts them: an emoji is two.
    @Test func offsetsCountUTF16() {
        let text = ReplyText(blocks: MarkdownBlock.split("a😀b c"))
        #expect(text.pieces[0].length == 6)
        #expect(text.string(in: ReplySelection(anchor: ReplyPosition(piece: 0, offset: 1), focus: ReplyPosition(piece: 0, offset: 4))) == "😀b")
        #expect(text.unit(.word, at: ReplyPosition(piece: 0, offset: 5)) == ReplySelection(anchor: ReplyPosition(piece: 0, offset: 5), focus: ReplyPosition(piece: 0, offset: 6)))
    }

    /// A double click's word (also from just after it), a triple click's paragraph, which in code is
    /// a line, and a drag from them taking whole words or lines either way.
    @Test func wordsAndParagraphsSelectWhole() {
        let text = ReplyText(blocks: MarkdownBlock.split("Alpha beta, gamma.\n\n```\nfirst line\nsecond line\n```"))
        func at(_ piece: Int, _ offset: Int) -> ReplyPosition { ReplyPosition(piece: piece, offset: offset) }
        #expect(text.unit(.word, at: at(0, 7)) == ReplySelection(anchor: at(0, 6), focus: at(0, 10)))
        #expect(text.unit(.word, at: at(0, 10)) == ReplySelection(anchor: at(0, 6), focus: at(0, 10)))
        // Between words, the character there.
        #expect(text.unit(.word, at: at(0, 11)) == ReplySelection(anchor: at(0, 11), focus: at(0, 12)))
        #expect(text.unit(.paragraph, at: at(1, 13)) == ReplySelection(anchor: at(1, 11), focus: at(1, 22)))
        #expect(text.unit(.paragraph, at: at(1, 2)) == ReplySelection(anchor: at(1, 0), focus: at(1, 10)))
        let beta = text.unit(.word, at: at(0, 7))
        #expect(text.extending(beta, to: at(0, 14), by: .word) == ReplySelection(anchor: at(0, 6), focus: at(0, 17)))
        #expect(text.extending(beta, to: at(0, 2), by: .word) == ReplySelection(anchor: at(0, 10), focus: at(0, 0)))
        #expect(text.extending(beta, to: at(0, 8), by: .word) == beta)
        let line = text.unit(.paragraph, at: at(1, 2))
        #expect(text.string(in: text.extending(line, to: at(1, 12), by: .paragraph)) == "first line\nsecond line")
        #expect(text.extending(ReplySelection(anchor: at(0, 3), focus: at(0, 3)), to: at(1, 4), by: .character)
                == ReplySelection(anchor: at(0, 3), focus: at(1, 4)))
    }

    /// As a reply is written its pieces change: a selection is kept within them, and a reply with
    /// nothing has nothing to select.
    @Test func aSelectionStaysWithinTheReplyAsItChanges() {
        let longer = ReplyText(blocks: MarkdownBlock.split("First.\n\nSecond paragraph."))
        let selection = ReplySelection(anchor: ReplyPosition(piece: 0, offset: 2), focus: ReplyPosition(piece: 1, offset: 17))
        #expect(longer.string(in: selection) == "rst.\n\nSecond paragraph.")
        let shorter = ReplyText(blocks: MarkdownBlock.split("First."))
        #expect(shorter.clamped(selection) == ReplySelection(anchor: ReplyPosition(piece: 0, offset: 2), focus: ReplyPosition(piece: 0, offset: 6)))
        #expect(shorter.string(in: selection) == "rst.")
        #expect(shorter.range(of: 0, in: selection) == 2..<6)
        // A place in a piece that is gone is past the end.
        let early = ReplySelection(anchor: ReplyPosition(piece: 0, offset: 0), focus: ReplyPosition(piece: 1, offset: 3))
        #expect(shorter.string(in: early) == "First.")
        let empty = ReplyText(blocks: [])
        #expect(empty.whole == nil)
        #expect(empty.clamped(selection) == nil)
        #expect(empty.string(in: selection) == "")
        // Text written since the last rendering is the last piece, after a line break.
        let pending = ReplyText(blocks: MarkdownBlock.split("First."), pending: "and more")
        #expect(pending.pieces.last?.key == ReplyText.Key(path: [1], part: .pending))
        #expect(pending.string(in: pending.whole!) == "First.\nand more")
        // Most deltas change only that text, which is replaced without going through the blocks.
        let blocks = MarkdownBlock.split("First.")
        #expect(pending.replacingPending("and more still") == ReplyText(blocks: blocks, pending: "and more still"))
        #expect(pending.replacingPending(nil) == ReplyText(blocks: blocks))
        #expect(ReplyText(blocks: blocks).replacingPending("and more") == pending)
        #expect(empty.replacingPending("alone").pieces.map(\.separator) == [""])
    }

    /// A paragraph's lines as SwiftUI lays them out: offsets count from each paragraph's start
    /// (here, after a hard line break and an empty line), a wrapped line goes on from the last.
    static func laidOut() -> (text: String, lines: TextLines) {
        let text = "One two three\nfour\n\nfive"
        func line(_ y: Double, _ glyphs: [Int]) -> TextLines.Laid {
            TextLines.Laid(minY: y, maxY: y + 16, glyphs: glyphs.enumerated().map { (Double($0.offset) * 7, Double($0.offset + 1) * 7, $0.element) })
        }
        let lines = TextLines(lines: [
            line(0, Array(0...7)),        // "One two " (wrapped)
            line(16, Array(8...12)),      // "three"
            line(32, Array(0...3)),       // "four"
            line(48, []),                 // the empty paragraph
            line(64, Array(0...3)),       // "five"
        ], text: text)
        return (text, lines)
    }

    @Test func linesResolveTheirPlacesInTheWholeText() {
        let lines = Self.laidOut().lines
        #expect(lines.length == 24)
        #expect(lines.lines.map(\.start) == [0, 8, 14, 19, 20])
        #expect(lines.lines.map(\.end) == [8, 13, 18, 19, 24])
        #expect(lines.lines.map(\.lineBreak) == [nil, 13, 18, 19, nil])
        #expect(lines.lines[2].glyphs.map(\.start) == [14, 15, 16, 17])
        #expect(lines.lines[2].glyphs.map(\.end) == [15, 16, 17, 18])
        // The nearest edge of the glyph under x, or the line's ends beside it.
        #expect(lines.offset(atX: -5, line: 1) == 8)
        #expect(lines.offset(atX: 9, line: 1) == 9)
        #expect(lines.offset(atX: 12, line: 1) == 10)
        #expect(lines.offset(atX: 300, line: 1) == 13)
        #expect(lines.offset(atX: 300, line: 3) == 19)
        #expect(lines.glyph(atX: 9, line: 1)?.start == 9)
        #expect(lines.glyph(atX: 300, line: 1) == nil)
    }

    /// A range covers its glyphs on each line, and a little past a line whose line break it takes
    /// (an empty line shows just that).
    @Test func rangesCoverTheirGlyphsAndLineBreaks() {
        let lines = Self.laidOut().lines
        typealias Rect = TextLines.Rect
        #expect(lines.rects(for: 4..<10) == [Rect(minX: 28, minY: 0, maxX: 56, maxY: 16), Rect(minX: 0, minY: 16, maxX: 14, maxY: 32)])
        #expect(lines.rects(for: 10..<20) == [
            Rect(minX: 14, minY: 16, maxX: 35 + TextLines.lineBreakWidth, maxY: 32),
            Rect(minX: 0, minY: 32, maxX: 28 + TextLines.lineBreakWidth, maxY: 48),
            Rect(minX: 0, minY: 48, maxX: TextLines.lineBreakWidth, maxY: 64),
        ])
        #expect(lines.rects(for: 5..<5).isEmpty)
    }

    /// The place under a point among a reply's pieces: on a line (beside it, its nearest end), the
    /// nearer of two side by side, between pieces the start of the next, and past them all the
    /// end of the last. Pieces above the point aren't laid out.
    @Test func aPointFindsItsPlaceAmongThePieces() {
        let layout = Self.laidOut().lines
        let short = TextLines(lines: [TextLines.Laid(minY: 0, maxY: 16, glyphs: [(0, 7, 0), (7, 14, 1)])], text: "ab")
        let pieces = [layout, short, short, short]
        let placed = [
            TextLines.Placed(piece: 0, bounds: TextLines.Rect(minX: 0, minY: 0, maxX: 56, maxY: 80), x: 10, y: 100),
            TextLines.Placed(piece: 1, bounds: TextLines.Rect(minX: 0, minY: 0, maxX: 14, maxY: 16), x: 10, y: 200),
            TextLines.Placed(piece: 2, bounds: TextLines.Rect(minX: 0, minY: 0, maxX: 14, maxY: 16), x: 60, y: 200),
            TextLines.Placed(piece: 3, bounds: TextLines.Rect(minX: 0, minY: 0, maxX: 14, maxY: 16), x: 10, y: 240),
        ]
        var asked: Set<Int> = []
        func hit(_ x: Double, _ y: Double) -> TextLines.Hit? {
            TextLines.hit(atX: x, y: y, in: placed) { asked.insert($0); return pieces[$0] }
        }
        #expect(hit(10 + 9, 100 + 20) == TextLines.Hit(position: ReplyPosition(piece: 0, offset: 9), character: ReplyPosition(piece: 0, offset: 9)))
        #expect(hit(500, 100 + 20) == TextLines.Hit(position: ReplyPosition(piece: 0, offset: 13), character: nil))
        #expect(asked == [0])
        // Side by side, the nearer.
        #expect(hit(30, 205)?.position == ReplyPosition(piece: 1, offset: 2))
        #expect(hit(56, 205)?.position == ReplyPosition(piece: 2, offset: 0))
        // Between pieces, above them all, and below them all.
        asked = []
        #expect(hit(0, 220) == TextLines.Hit(position: ReplyPosition(piece: 3, offset: 0), character: nil))
        #expect(!asked.contains(0))
        #expect(hit(0, 0)?.position == ReplyPosition(piece: 0, offset: 0))
        #expect(hit(0, 1000)?.position == ReplyPosition(piece: 3, offset: 2))
        #expect(TextLines.hit(atX: 0, y: 0, in: []) { pieces[$0] } == nil)
    }
}
