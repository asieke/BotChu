import Foundation

/// A piece of a reply's text as it is laid out (#156): its lines, top to bottom, with their glyphs
/// and the places in the text at their edges, so the place under a point, and what a selected range
/// covers, can be told. Made from what SwiftUI's text layout gives for each line: its top and bottom,
/// and each glyph's left and right edges with the UTF-16 offset of its first character, counted from
/// the start of the glyph's paragraph (the layout counts again after each line break). Coordinates
/// are the text's own, y going down.
public struct TextLines: Equatable, Sendable {
    /// A line as the layout gives it.
    public struct Laid: Sendable {
        public var minY: Double
        public var maxY: Double
        public var glyphs: [(minX: Double, maxX: Double, offset: Int)]

        public init(minY: Double, maxY: Double, glyphs: [(minX: Double, maxX: Double, offset: Int)]) {
            self.minY = minY
            self.maxY = maxY
            self.glyphs = glyphs
        }
    }

    public struct Glyph: Equatable, Sendable {
        public var minX: Double
        public var maxX: Double
        /// Where its characters start and end in the whole text.
        public var start: Int
        public var end: Int
    }

    public struct Line: Equatable, Sendable {
        public var minY: Double
        public var maxY: Double
        public var glyphs: [Glyph]
        /// The places at its ends.
        public var start: Int
        public var end: Int
        /// The line break after it, when it ends a paragraph that isn't the last.
        public var lineBreak: Int?

        public var minX: Double { glyphs.first?.minX ?? 0 }
        public var maxX: Double { glyphs.last?.maxX ?? 0 }
    }

    public struct Rect: Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }
    }

    /// How wide a selected line break shows, past the end of its line.
    public static let lineBreakWidth = 4.0

    public let lines: [Line]
    /// The text's length in UTF-16.
    public let length: Int

    public init(lines laid: [Laid], text: String) {
        let units = Array(text.utf16)
        length = units.count
        var lines: [Line] = []
        // The paragraph being read: where it starts, the lines of it so far, and the offset (from
        // its start) of the last glyph in them.
        var start = 0
        var first = 0
        var last: Int?

        func isBreak(_ unit: UInt16) -> Bool {
            unit == 0x0A || unit == 0x0B || unit == 0x0C || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029
        }
        func nextBreak(from index: Int) -> Int? {
            var index = max(index, 0)
            while index < units.count, !isBreak(units[index]) { index += 1 }
            return index < units.count ? index : nil
        }
        /// Gives the lines of the paragraph read their ends, and its glyphs theirs: where the next
        /// glyph starts, or the paragraph's end.
        func finish() {
            let paragraphEnd = nextBreak(from: start + (last.map { $0 + 1 } ?? 0))
            let end = paragraphEnd ?? units.count
            let starts = Set(lines[first...].flatMap { $0.glyphs.map(\.start) }).sorted()
            var next: [Int: Int] = [:]
            for (index, at) in starts.enumerated() { next[at] = index + 1 < starts.count ? starts[index + 1] : end }
            for index in lines.indices[first...] {
                for glyph in lines[index].glyphs.indices {
                    let at = lines[index].glyphs[glyph].start
                    lines[index].glyphs[glyph].end = max(at, next[at] ?? end)
                }
                lines[index].start = lines[index].glyphs.map(\.start).min() ?? min(start, end)
                lines[index].end = lines[index].glyphs.map(\.end).max() ?? min(start, end)
            }
            if let lastLine = lines.indices.last, lastLine >= first {
                lines[lastLine].end = max(lines[lastLine].end, end)
                lines[lastLine].lineBreak = paragraphEnd
            }
        }

        for line in laid {
            let offsets = line.glyphs.map(\.offset)
            // A line that counts from the start again, or an empty one, begins the next paragraph,
            // after the line break that ends this one.
            if lines.count > first, last == nil || offsets.isEmpty || offsets.min()! <= last! {
                finish()
                start = nextBreak(from: start + (last.map { $0 + 1 } ?? 0)).map { units[$0] == 0x0D && $0 + 1 < units.count && units[$0 + 1] == 0x0A ? $0 + 2 : $0 + 1 } ?? units.count
                first = lines.count
                last = nil
            }
            let glyphs = line.glyphs
                .map { Glyph(minX: $0.minX, maxX: $0.maxX, start: min(start + max($0.offset, 0), units.count), end: 0) }
                .sorted { $0.minX < $1.minX }
            if let highest = offsets.max() { last = max(last ?? highest, highest) }
            lines.append(Line(minY: line.minY, maxY: line.maxY, glyphs: glyphs, start: start, end: start, lineBreak: nil))
        }
        if lines.count > first { finish() }
        self.lines = lines
    }

    /// The place nearest `x` on line `index`: before or after the glyph under it, whichever edge
    /// is closer, or the line's start or end beside it.
    public func offset(atX x: Double, line index: Int) -> Int {
        let line = lines[index]
        guard let leftmost = line.glyphs.first, x > leftmost.minX else { return line.start }
        for glyph in line.glyphs where x < glyph.maxX {
            return x < (glyph.minX + glyph.maxX) / 2 ? glyph.start : glyph.end
        }
        return line.end
    }

    /// What `range` covers on each line: its glyphs, and a little past the line's end where the
    /// line break after it is selected.
    public func rects(for range: Range<Int>) -> [Rect] {
        var rects: [Rect] = []
        for line in lines {
            var minX = Double.infinity, maxX = -Double.infinity
            for glyph in line.glyphs where glyph.start < range.upperBound && glyph.end > range.lowerBound {
                minX = min(minX, glyph.minX)
                maxX = max(maxX, glyph.maxX)
            }
            if let lineBreak = line.lineBreak, range.contains(lineBreak) {
                if minX > maxX { minX = line.maxX; maxX = line.maxX }
                maxX += Self.lineBreakWidth
            }
            if minX < maxX { rects.append(Rect(minX: minX, minY: line.minY, maxX: maxX, maxY: line.maxY)) }
        }
        return rects
    }

    /// The glyph under `x` on line `index`, if any.
    public func glyph(atX x: Double, line index: Int) -> Glyph? {
        lines[index].glyphs.first { $0.minX <= x && x < $0.maxX }
    }

    /// A piece of a reply where it is drawn among the rest: its origin in a space all of them
    /// share, y going down, and where it draws around that (`bounds`), read without its glyphs.
    public struct Placed: Sendable {
        public var piece: Int
        public var bounds: Rect
        public var x: Double
        public var y: Double

        public init(piece: Int, bounds: Rect, x: Double, y: Double) {
            self.piece = piece
            self.bounds = bounds
            self.x = x
            self.y = y
        }
    }

    /// What is under a point in a reply.
    public struct Hit: Equatable, Sendable {
        /// The place nearest the point, where a click puts the caret.
        public var position: ReplyPosition
        /// The character under the point, when it is on one: what a double click selects the word
        /// of, and a click on a link opens.
        public var character: ReplyPosition?
    }

    /// What is under a point among a reply's pieces (`placed`, in reading order): on the line
    /// beside the point that is nearest it, or, between lines, the start of the first line in
    /// reading order below it, or else the end of the last piece. `lines` gives a placed piece's
    /// lines, asked only of the pieces beside or below the point. Nil without pieces.
    public static func hit(atX x: Double, y: Double, in placed: [Placed], lines lay: (Int) -> TextLines) -> Hit? {
        var best: (distance: Double, placed: Int, line: Int)?
        var laid: [Int: TextLines] = [:]
        func lines(of index: Int) -> TextLines {
            if let known = laid[index] { return known }
            let made = lay(index)
            laid[index] = made
            return made
        }
        for (index, piece) in placed.enumerated() where piece.y + piece.bounds.minY <= y && y < piece.y + piece.bounds.maxY {
            for (number, line) in lines(of: index).lines.enumerated() where piece.y + line.minY <= y && y < piece.y + line.maxY {
                let left = piece.x + line.minX, right = piece.x + line.maxX
                let distance = x < left ? left - x : x > right ? x - right : 0
                if best == nil || distance < best!.distance { best = (distance, index, number) }
            }
        }
        if let best {
            let piece = placed[best.placed], text = lines(of: best.placed)
            let position = ReplyPosition(piece: piece.piece, offset: text.offset(atX: x - piece.x, line: best.line))
            let character = text.glyph(atX: x - piece.x, line: best.line).map { ReplyPosition(piece: piece.piece, offset: $0.start) }
            return Hit(position: position, character: character)
        }
        for (index, piece) in placed.enumerated() where piece.y + piece.bounds.maxY > y {
            if let line = lines(of: index).lines.first(where: { piece.y + $0.minY > y }) {
                return Hit(position: ReplyPosition(piece: piece.piece, offset: line.start), character: nil)
            }
        }
        guard let last = placed.indices.max(by: { placed[$0].piece < placed[$1].piece }) else { return nil }
        return Hit(position: ReplyPosition(piece: placed[last].piece, offset: lines(of: last).length), character: nil)
    }
}
