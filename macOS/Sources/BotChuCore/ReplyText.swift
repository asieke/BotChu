import Foundation

/// A reply's text as it is selected and copied (#156). Its view draws each heading, paragraph, list
/// item's marker, table cell and code block as a text of its own, so the reply is kept here as those
/// pieces, in reading order, each with what goes between it and the piece before it when a selection
/// across them is copied: a blank line between blocks, a line break between list items (indented by
/// a tab for each level a list is nested) and between table rows, a space after an item's marker,
/// and a tab between cells. A place in it is a piece and a UTF-16 offset into it, as text layout
/// counts them (`TextLines`).
public struct ReplyText: Equatable, Sendable {
    /// Which of a reply's texts a piece is: its block's path from the reply's top
    /// (`MarkdownBlock.path`), and which text of that block.
    public struct Key: Hashable, Sendable {
        public var path: [Int]
        public var part: Part

        public init(path: [Int], part: Part) {
            self.path = path
            self.part = part
        }
    }

    public enum Part: Hashable, Sendable {
        /// A heading's or paragraph's text.
        case text
        /// A list item's number or bullet; the path is the item's.
        case marker
        /// A code block's code.
        case code
        /// A table row's cell in a column, empty or not; the path is the row's.
        case cell(Int)
        /// What has been written since the reply's last rendering, shown as it is.
        case pending
    }

    public struct Piece: Equatable, Sendable {
        public var key: Key
        public var text: String
        /// What goes before it when it is copied after the piece before it.
        public var separator: String
        public var links: [Link]
        public var length: Int { text.utf16.count }
    }

    public struct Link: Equatable, Sendable {
        public var range: Range<Int>
        public var url: URL
    }

    /// How far a click or drag selects: by character, by word (a double click) or by paragraph,
    /// which in code is a line (a triple click).
    public enum Granularity: Sendable {
        case character, word, paragraph
    }

    public private(set) var pieces: [Piece]
    private var indices: [Key: Int]
    private var blockCount: Int

    /// The pieces of `blocks` as `MarkdownText` draws them, then the text written since they were
    /// parsed, if any.
    public init(blocks: [MarkdownBlock], pending: String? = nil) {
        var walk = Walk()
        walk.blocks(blocks, gap: "\n\n", depth: 0)
        pieces = walk.pieces
        indices = Dictionary(walk.pieces.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { first, _ in first })
        blockCount = blocks.count
        if let pending { self = replacingPending(pending) }
    }

    /// The same blocks with other text written since they were parsed: what a reply being written
    /// changes with most deltas, without going through its blocks again.
    public func replacingPending(_ pending: String?) -> ReplyText {
        var text = self
        if let last = text.pieces.last, last.key.part == .pending {
            text.pieces.removeLast()
            text.indices[last.key] = nil
        }
        if let pending {
            let key = Key(path: [blockCount], part: .pending)
            text.indices[key] = text.pieces.count
            text.pieces.append(Piece(key: key, text: pending, separator: text.pieces.isEmpty ? "" : "\n", links: []))
        }
        return text
    }

    public func index(of key: Key) -> Int? { indices[key] }

    /// All of it, nil when there is nothing.
    public var whole: ReplySelection? {
        guard let last = pieces.indices.last else { return nil }
        return ReplySelection(anchor: ReplyPosition(piece: 0, offset: 0), focus: ReplyPosition(piece: last, offset: pieces[last].length))
    }

    /// The nearest place that is in it: past its last piece, the end of that. Needs a piece.
    public func clamped(_ position: ReplyPosition) -> ReplyPosition {
        guard position.piece < pieces.count else { return ReplyPosition(piece: pieces.count - 1, offset: pieces[pieces.count - 1].length) }
        guard position.piece >= 0 else { return ReplyPosition(piece: 0, offset: 0) }
        return ReplyPosition(piece: position.piece, offset: min(max(position.offset, 0), pieces[position.piece].length))
    }

    /// `selection` within this text, after the reply changed as it is written; nil when it has
    /// nothing now.
    public func clamped(_ selection: ReplySelection) -> ReplySelection? {
        guard !pieces.isEmpty else { return nil }
        return ReplySelection(anchor: clamped(selection.anchor), focus: clamped(selection.focus))
    }

    /// The part of piece `index` that `selection` covers, nil if none of it.
    public func range(of index: Int, in selection: ReplySelection) -> Range<Int>? {
        guard !selection.isEmpty, pieces.indices.contains(index) else { return nil }
        let start = selection.start, end = selection.end
        guard start.piece <= index, index <= end.piece else { return nil }
        let length = pieces[index].length
        let lower = index == start.piece ? min(start.offset, length) : 0
        let upper = index == end.piece ? min(end.offset, length) : length
        return lower < upper ? lower..<upper : nil
    }

    /// What copying `selection` gives: the selected part of each piece, in reading order, with
    /// what goes between them. A selection that ends at a piece's very start, or starts at one's
    /// very end, takes neither that piece nor what goes between it and the rest.
    public func string(in selection: ReplySelection) -> String {
        guard !pieces.isEmpty, !selection.isEmpty else { return "" }
        var start = clamped(selection.start), end = clamped(selection.end)
        if end.offset == 0, end.piece > start.piece { end = ReplyPosition(piece: end.piece - 1, offset: pieces[end.piece - 1].length) }
        if start.offset == pieces[start.piece].length, start.piece < end.piece { start = ReplyPosition(piece: start.piece + 1, offset: 0) }
        guard start < end else { return "" }
        var result = ""
        for index in start.piece...end.piece {
            let piece = pieces[index]
            if index > start.piece { result += piece.separator }
            let lower = index == start.piece ? start.offset : 0
            let upper = index == end.piece ? end.offset : piece.length
            if lower < upper { result += (piece.text as NSString).substring(with: NSRange(location: lower, length: upper - lower)) }
        }
        return result
    }

    /// The word, or paragraph, at `position`: a double or triple click's selection. Between words,
    /// a word is the character there.
    public func unit(_ granularity: Granularity, at position: ReplyPosition) -> ReplySelection {
        let position = clamped(position)
        let text = pieces[position.piece].text as NSString
        let offset = position.offset
        var range = NSRange(location: offset, length: 0)
        switch granularity {
        case .character:
            break
        case .word:
            guard text.length > 0 else { break }
            // The word the place is in, or else the one it ends, or else the character after it.
            let probe = min(offset, text.length - 1)
            var found: NSRange?
            text.enumerateSubstrings(in: text.paragraphRange(for: NSRange(location: probe, length: 0)),
                                     options: [.byWords, .substringNotRequired]) { _, word, _, stop in
                guard word.location <= offset else { stop.pointee = true; return }
                if offset < NSMaxRange(word) {
                    found = word
                    stop.pointee = true
                } else if offset == NSMaxRange(word) {
                    found = word
                }
            }
            range = found ?? text.rangeOfComposedCharacterSequence(at: probe)
        case .paragraph:
            range = text.paragraphRange(for: NSRange(location: offset, length: 0))
            // Without the line break that ends it.
            while range.length > 0, let scalar = Unicode.Scalar(text.character(at: NSMaxRange(range) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                range.length -= 1
            }
        }
        return ReplySelection(anchor: ReplyPosition(piece: position.piece, offset: range.location),
                              focus: ReplyPosition(piece: position.piece, offset: NSMaxRange(range)))
    }

    /// A drag's selection: from `initial` (where the mouse went down, and the word or paragraph
    /// there after a double or triple click) to `position`, taking whole words or paragraphs.
    public func extending(_ initial: ReplySelection, to position: ReplyPosition, by granularity: Granularity) -> ReplySelection {
        guard granularity != .character else { return ReplySelection(anchor: initial.anchor, focus: clamped(position)) }
        let unit = unit(granularity, at: position)
        if unit.start < initial.start { return ReplySelection(anchor: initial.end, focus: unit.start) }
        return ReplySelection(anchor: initial.start, focus: max(unit.end, initial.end))
    }

    /// The link at `position`, if it is on one.
    public func link(at position: ReplyPosition) -> URL? {
        guard pieces.indices.contains(position.piece) else { return nil }
        return pieces[position.piece].links.first { $0.range.contains(position.offset) }?.url
    }

    /// Walks the blocks as the view lays them out, collecting their texts.
    private struct Walk {
        var pieces: [Piece] = []
        /// What goes before the next piece, as its container says.
        var separator = ""

        mutating func add(_ key: Key, _ text: String, links: [Link] = []) {
            pieces.append(Piece(key: key, text: text, separator: pieces.isEmpty ? "" : separator, links: links))
        }

        mutating func add(_ key: Key, _ text: AttributedString) {
            add(key, String(text.characters), links: ReplyText.links(in: text))
        }

        mutating func blocks(_ blocks: [MarkdownBlock], gap: String, depth: Int) {
            for (index, block) in blocks.enumerated() {
                if index > 0 { separator = gap }
                self.block(block, depth: depth)
            }
        }

        mutating func block(_ block: MarkdownBlock, depth: Int) {
            switch block.kind {
            case .header, .paragraph, .tableCell:
                add(Key(path: block.path, part: .text), block.text)
            case .codeBlock:
                add(Key(path: block.path, part: .code), block.code)
            case .orderedList, .unorderedList:
                let indent = String(repeating: "\t", count: depth)
                for (index, item) in block.children.enumerated() {
                    if index > 0 { separator = "\n" + indent }
                    add(Key(path: item.path, part: .marker), block.marker(for: item))
                    separator = " "
                    blocks(item.children, gap: "\n" + indent + "\t", depth: depth + 1)
                }
            case .table(let columns):
                for (index, row) in block.children.enumerated() {
                    if index > 0 { separator = "\n" }
                    for column in columns.indices {
                        if column > 0 { separator = "\t" }
                        let cell = row.children.first { $0.kind == .tableCell(columnIndex: column) }
                        let key = Key(path: row.path, part: .cell(column))
                        if let cell { add(key, cell.text) } else { add(key, "") }
                    }
                }
            case .thematicBreak:
                break
            default:
                blocks(block.children, gap: "\n\n", depth: depth)
            }
        }
    }

    private static func links(in text: AttributedString) -> [Link] {
        guard text.runs.contains(where: { $0.link != nil }) else { return [] }
        var links: [Link] = []
        var offset = 0
        for run in text.runs {
            let length = String(text[run.range].characters).utf16.count
            if let url = run.link { links.append(Link(range: offset..<offset + length, url: url)) }
            offset += length
        }
        return links
    }
}

/// A place in a reply's text: a piece, and a UTF-16 offset into it.
public struct ReplyPosition: Comparable, Hashable, Sendable {
    public var piece: Int
    public var offset: Int

    public init(piece: Int, offset: Int) {
        self.piece = piece
        self.offset = offset
    }

    public static func < (lhs: ReplyPosition, rhs: ReplyPosition) -> Bool {
        (lhs.piece, lhs.offset) < (rhs.piece, rhs.offset)
    }
}

/// A selection in a reply's text, from where it began to where it was extended to, either way.
public struct ReplySelection: Equatable, Sendable {
    public var anchor: ReplyPosition
    public var focus: ReplyPosition

    public init(anchor: ReplyPosition, focus: ReplyPosition) {
        self.anchor = anchor
        self.focus = focus
    }

    public var start: ReplyPosition { min(anchor, focus) }
    public var end: ReplyPosition { max(anchor, focus) }
    public var isEmpty: Bool { anchor == focus }
}

extension MarkdownBlock {
    /// What a list item shows before it in this list: its number, or a bullet.
    public func marker(for item: MarkdownBlock) -> String {
        if kind == .orderedList, case .listItem(let ordinal) = item.kind { return "\(ordinal)." }
        return "•"
    }

    /// A code block's code as it is shown, without the line breaks at its ends.
    public var code: String {
        String(text.characters).trimmingCharacters(in: .newlines)
    }
}
