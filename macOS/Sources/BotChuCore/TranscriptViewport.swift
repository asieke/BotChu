import Foundation

/// Which rows of a chat its view lays out, and where the reader is among them (#110).
///
/// The chat lays out only the rows near the visible part of its scroll view: those within
/// `overscan(for:)` above and below it, at most `rowLimit` unless the visible part itself needs
/// more, however many earlier items are open to scrolling or arrive meanwhile. The rest of what can
/// be scrolled to is empty space above and below them, as tall as those rows were last measured at,
/// or as estimated. A message, a card and a folded or live exploration group are a row each; an
/// opened group is its header, a row per entry and its foot, and in Raw every call of a group is a
/// row of its own, so a group of 5,000 calls is laid out a screenful at a time as well.
///
/// A row's height is kept with a signature of what it showed: its content's revision (a reply's
/// text by its length, which only grows as it streams; a group's `revision`; a call's state and
/// output), whether it is opened, the layout inputs (width, density, appearance) and the
/// conversation's `epoch`. A height measured for anything else is never used, and a measurement
/// that comes from a row no longer laid out, or laid out since with other content, is dropped.
/// Heights are kept only for the items that can be scrolled to, and a few more (`spareItems`), and
/// `forgetHeights()` lets them all go.
///
/// A reader who isn't pinned to the newest content keeps their place by a row and their offset
/// into it. When what is above them changes height (a row measured for the first time, a reply's
/// math rendered late, a narrower window) or grows (earlier items shown), `correction` is where the
/// visible part must start for that row to stay where it is on the screen.
public struct TranscriptViewport: Sendable {
    /// The most rows laid out at once, unless the visible part alone holds more.
    public static let rowLimit = 160
    /// How far beyond the visible part rows are laid out, above and below it.
    public static func overscan(for viewport: Double) -> Double { max(400, viewport * 0.75) }
    /// The visible part's height assumed before the scroll view has said.
    public static let defaultViewport = 1_000.0
    /// Heights kept for items that can't be scrolled to (now), beyond those that can.
    public static let spareItems = 256

    /// How an item is laid out.
    public enum Split: Hashable, Sendable {
        /// One row: a message, a card, a folded or live group.
        case whole
        /// An opened exploration group: its header, a row per entry, and its foot with failures.
        case opened
        /// Every call of a group as a card of its own (Raw).
        case calls
    }

    /// How the chat shows an item: its split, and a hash of whatever else changes its height
    /// (opened by a click, live, the sub-agents' cards it carries).
    public struct Style: Hashable, Sendable {
        public var split: Split
        public var extra: Int

        public init(split: Split = .whole, extra: Int = 0) {
            self.split = split
            self.extra = extra
        }
    }

    /// What every row's height depends on besides its content.
    public struct Inputs: Hashable, Sendable {
        public var width: Int
        public var density: Int
        public var dark: Bool
        /// The conversation's `epoch`: a thread replaced or edited measures again.
        public var epoch: Int

        public init(width: Int, density: Int, dark: Bool, epoch: Int) {
            self.width = width
            self.density = density
            self.dark = dark
            self.epoch = epoch
        }
    }

    public struct RowID: Hashable, Sendable {
        public let item: UUID
        public let part: Int

        public init(item: UUID, part: Int) {
            self.item = item
            self.part = part
        }
    }

    /// A row to lay out: which item (by index in the items) and part, where it starts in the
    /// scrollable rows, and its height as known.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: RowID
        public let index: Int
        public let split: Split
        /// How many rows its item has.
        public let parts: Int
        /// What its height depends on: a measurement is kept only for the same signature.
        public let signature: Int
        public internal(set) var top: Double
        public internal(set) var height: Double

        public var part: Int { id.part }

        /// The space under it, which its height includes: between items, or between a group's calls.
        public var gap: Double {
            switch split {
            case .whole: 12
            case .opened: part == parts - 1 ? 12 : 0
            case .calls: part == parts - 1 ? 12 : 6
            }
        }
    }

    /// The rows to lay out, and the space to leave above and below them.
    public struct Plan: Equatable, Sendable {
        public internal(set) var rows: [Row] = []
        public internal(set) var above = 0.0
        public internal(set) var below = 0.0
        /// Every scrollable row together.
        public internal(set) var total = 0.0
        /// The first item that can be scrolled to.
        public internal(set) var start = 0

        public init() {}
    }

    private struct Measure: Sendable {
        var signature: Int
        var height: Double
        /// The estimate before learning, for learning from the measurement.
        var guess: Double
        var kind: Int
        var measured: Bool
    }

    private struct ItemRows: Sendable {
        var signature: Int
        var split: Split
        var rows: [Measure]
        var total: Double
        var generation: Int
    }

    private struct Anchor: Equatable, Sendable {
        var row: RowID
        var offset: Double
    }

    private var cache: [UUID: ItemRows] = [:]
    private var generation = 0
    public private(set) var plan = Plan()
    private var planned: [RowID: Int] = [:]
    /// The scrollable items' ids and tops (with the bottom of the last), as planned.
    private var ids: [UUID] = []
    private var tops: [Double] = []
    /// How much the rows laid out grew, as measured, since they were planned.
    private var shift = 0.0
    private var anchor: Anchor?
    private var pinned = true
    /// The visible part, in the rows' coordinates: 0 at the first scrollable row's top.
    public private(set) var visibleTop: Double?
    public private(set) var viewport: Double?
    /// Where the visible part must start to keep the reader's row in place; nil when it does.
    public private(set) var correction: Double?
    /// Measured to estimated height, by kind of row, as learned.
    private var ratios = [Double](repeating: 1, count: Kind.count)
    private var samples = [Int](repeating: 0, count: Kind.count)

    /// Measurements dropped: of a row no longer laid out, or laid out since with other content.
    public private(set) var droppedMeasurements = 0
    /// Rows rebuilt (signature worked out, height looked up or estimated) by the last plan.
    public private(set) var rebuiltRows = 0

    public init() {}

    /// How many items' heights are kept.
    public var keptItems: Int { cache.count }

    /// Lets every height go, as under memory pressure: rows are estimated again, then measured.
    public mutating func forgetHeights() {
        cache.removeAll()
    }

    // MARK: Planning

    /// Works out the rows to lay out of `items` from `start`, the first that can be scrolled to:
    /// at the newest content while `pinned`, else around the reader's row. `expansions` changes
    /// whenever a call's details are opened or closed (`expanded` holds those open).
    public mutating func plan(_ items: ChunkedArray<ActivityItem>, from start: Int, inputs: Inputs, pinned: Bool,
                              expanded: Set<UUID> = [], expansions: Int = 0,
                              style: (Int, ActivityItem) -> Style) -> Plan {
        generation += 1
        rebuiltRows = 0
        self.pinned = pinned
        let start = min(max(0, start), items.count)
        let count = items.count - start
        ids.removeAll(keepingCapacity: true)
        tops.removeAll(keepingCapacity: true)
        ids.reserveCapacity(count)
        tops.reserveCapacity(count + 1)
        var y = 0.0
        var anchorAt: Int?
        for index in start..<items.count {
            let item = items[index]
            let style = style(index, item)
            let turn = index == 0 || !items[index - 1].isBotTurn
            let signature = Self.signature(item, style: style, startsTurn: turn, inputs: inputs, expanded: expanded, expansions: expansions)
            let id = item.id
            if cache[id]?.signature != signature {
                cache[id] = rows(of: item, style: style, startsTurn: turn, inputs: inputs, expanded: expanded,
                                 signature: signature, previous: cache[id])
            }
            cache[id]?.generation = generation
            if id == anchor?.row.item { anchorAt = index - start }
            ids.append(id)
            tops.append(y)
            y += cache[id]?.total ?? 0
        }
        tops.append(y)
        let total = y
        if cache.count > count + Self.spareItems { cache = cache.filter { $0.value.generation == generation } }

        let height = viewport ?? Self.defaultViewport
        var top = max(0, total - height)
        correction = nil
        if !pinned {
            if let anchor, let anchorAt {
                top = rowTop(item: anchorAt, part: anchor.row.part) + anchor.offset
                if let visibleTop, abs(visibleTop - top) > 0.5 { correction = top }
            } else if let visibleTop {
                top = visibleTop
            }
        }
        let overscan = Self.overscan(for: height)
        plan = select(from: start, items: count, total: total, visible: top..<(top + height),
                      band: (top - overscan)..<(top + height + (pinned ? 0 : overscan)))
        shift = 0
        planned.removeAll(keepingCapacity: true)
        for (index, row) in plan.rows.enumerated() { planned[row.id] = index }
        if pinned || anchorAt == nil { anchor = self.anchor(at: top) }
        return plan
    }

    /// The rows meeting the band, at most `rowLimit` unless the visible part holds more, trimmed
    /// from the side further from it.
    private func select(from start: Int, items count: Int, total: Double, visible: Range<Double>, band: Range<Double>) -> Plan {
        var plan = Plan()
        plan.start = start
        plan.total = total
        guard count > 0 else { return plan }
        var rows: [Row] = []
        var first = item(at: band.lowerBound)
        outer: while first < count {
            guard let entry = cache[ids[first]] else { break }
            var y = tops[first]
            for (part, measure) in entry.rows.enumerated() {
                let bottom = y + measure.height
                if y >= band.upperBound, !rows.isEmpty { break outer }
                if bottom > band.lowerBound || (part == entry.rows.count - 1 && first == count - 1 && rows.isEmpty) {
                    rows.append(Row(id: RowID(item: ids[first], part: part), index: start + first, split: entry.split,
                                    parts: entry.rows.count, signature: measure.signature, top: y, height: measure.height))
                }
                y = bottom
            }
            first += 1
        }
        if rows.count > Self.rowLimit {
            let shownFirst = rows.firstIndex { $0.top + $0.height > visible.lowerBound } ?? 0
            let shownLast = rows.lastIndex { $0.top < visible.upperBound } ?? rows.count - 1
            let keep = max(Self.rowLimit, shownLast - shownFirst + 1)
            var low = 0, high = rows.count
            while high - low > keep {
                if shownFirst - low > high - 1 - shownLast { low += 1 } else { high -= 1 }
            }
            rows = Array(rows[low..<high])
        }
        plan.rows = rows
        plan.above = rows.first?.top ?? 0
        plan.below = rows.last.map { total - $0.top - $0.height } ?? 0
        return plan
    }

    /// The scrollable item, by its place among them, that `y` is in.
    private func item(at y: Double) -> Int {
        var low = 0, high = ids.count - 1
        guard high >= 0 else { return 0 }
        while low < high {
            let middle = (low + high + 1) / 2
            if tops[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Where a part of a scrollable item starts, as planned.
    private func rowTop(item: Int, part: Int) -> Double {
        guard let entry = cache[ids[item]] else { return tops[item] }
        var y = tops[item]
        for index in 0..<min(part, entry.rows.count - 1) { y += entry.rows[index].height }
        return y
    }

    /// The row the visible part starts in, and how far into it: from the rows laid out, as
    /// measured, or from the rest as planned.
    private func anchor(at y: Double) -> Anchor? {
        let rows = plan.rows
        if let first = rows.first, let last = rows.last, y >= first.top || plan.above < 0.5, y < last.top + last.height || plan.below < 0.5 {
            var low = 0, high = rows.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if rows[middle].top <= y { low = middle } else { high = middle - 1 }
            }
            return Anchor(row: rows[low].id, offset: y - rows[low].top)
        }
        guard !ids.isEmpty else { return nil }
        // Beyond the rows laid out: those below them moved with what was measured.
        let below = rows.last.map { y >= $0.top + $0.height } ?? false
        let planned = below ? y - shift : y
        let index = item(at: planned)
        guard let entry = cache[ids[index]] else { return nil }
        var top = tops[index]
        var part = 0
        while part < entry.rows.count - 1, top + entry.rows[part].height <= planned {
            top += entry.rows[part].height
            part += 1
        }
        return Anchor(row: RowID(item: ids[index], part: part), offset: planned - top)
    }

    // MARK: The scroll view

    /// The scroll view's visible part, in the rows' coordinates. True when the rows laid out no
    /// longer cover enough of what is near it, or its height changed, so the chat should plan again.
    public mutating func scrolled(top: Double, height: Double) -> Bool {
        let resized = viewport.map { abs($0 - height) > 0.5 } ?? true
        viewport = height
        visibleTop = top
        if let correction {
            // Content moved under the reader: their place is the anchor, not where it went.
            guard abs(correction - top) <= 0.5 else { return resized }
            self.correction = nil
        } else {
            anchor = anchor(at: top)
        }
        return resized || uncovered(top: top, height: height)
    }

    /// The rows moved in the scroll view, so the visible part is at `visibleTop` in their
    /// coordinates without the reader scrolling: `correction` takes it back to the reader's row.
    public mutating func hold(visibleTop top: Double) {
        guard !pinned, let anchor, let at = planned[anchor.row] else { return }
        let wanted = plan.rows[at].top + anchor.offset
        if abs(wanted - top) > 0.5 { correction = wanted }
    }

    /// The scroll view went where `correction` said, or as near as it could: `top`.
    public mutating func corrected(to top: Double) {
        guard let correction else { return }
        self.correction = nil
        visibleTop = top
        if abs(correction - top) > 0.5 { anchor = anchor(at: top) }
    }

    /// The reader's row is no longer laid out near the visible part.
    private func uncovered(top: Double, height: Double) -> Bool {
        guard let first = plan.rows.first, let last = plan.rows.last else { return plan.total > 0 }
        let margin = Self.overscan(for: height) / 3
        if plan.above > 0.5, top - margin < first.top { return true }
        if plan.below > 0.5, top + height + margin > last.top + last.height { return true }
        return false
    }

    /// A row's height as laid out. Dropped unless the row is laid out now with that signature.
    /// True when the rows no longer cover what is near the visible part, so the chat should plan
    /// again; `correction` is set when the reader's row moved.
    public mutating func measured(_ id: RowID, signature: Int, height: Double) -> Bool {
        guard let index = planned[id], plan.rows[index].signature == signature, height.isFinite, height >= 0,
              var entry = cache[id.item], id.part < entry.rows.count, entry.rows[id.part].signature == signature else {
            droppedMeasurements += 1
            return false
        }
        var measure = entry.rows[id.part]
        let delta = height - plan.rows[index].height
        if !measure.measured {
            learn(measure.kind, measured: height, guess: measure.guess)
            measure.measured = true
        }
        guard abs(delta) > 0.01 else {
            entry.rows[id.part] = measure
            cache[id.item] = entry
            return false
        }
        measure.height = height
        entry.rows[id.part] = measure
        entry.total += delta
        cache[id.item] = entry
        plan.rows[index].height = height
        for later in (index + 1)..<plan.rows.count { plan.rows[later].top += delta }
        plan.total += delta
        shift += delta
        if !pinned, let anchor, let at = planned[anchor.row], at > index {
            let top = plan.rows[at].top + anchor.offset
            if let visibleTop, abs(visibleTop - top) > 0.5 { correction = top } else { correction = nil }
        }
        guard let visibleTop, let viewport else { return false }
        return uncovered(top: correction ?? visibleTop, height: viewport)
    }

    // MARK: Rows and their heights

    private enum Kind {
        static let user = 0, reply = 1, message = 2, tool = 3, card = 4, head = 5, entry = 6, foot = 7, call = 8
        static let count = 9
    }

    private mutating func learn(_ kind: Int, measured: Double, guess: Double) {
        guard guess > 1, measured > 1 else { return }
        let ratio = min(4, max(0.25, measured / guess))
        samples[kind] += 1
        // An average of the first few, then a slow drift.
        let weight = max(0.05, 1 / Double(samples[kind]))
        ratios[kind] += (ratio - ratios[kind]) * weight
    }

    private mutating func rows(of item: ActivityItem, style: Style, startsTurn: Bool, inputs: Inputs, expanded: Set<UUID>,
                               signature: Int, previous: ItemRows?) -> ItemRows {
        let parts = Self.parts(of: item, split: style.split)
        var rows: [Measure] = []
        rows.reserveCapacity(parts)
        var total = 0.0
        let reusable = previous?.split == style.split ? previous : nil
        for part in 0..<parts {
            let rowSignature = style.split == .whole
                ? signature
                : Self.signature(item, part: part, style: style, startsTurn: startsTurn, inputs: inputs, expanded: expanded)
            if let old = reusable?.rows, part < old.count, old[part].signature == rowSignature {
                rows.append(old[part])
                total += old[part].height
                continue
            }
            let (kind, guess) = Self.estimate(item, part: part, parts: parts, split: style.split, startsTurn: startsTurn,
                                              width: Double(inputs.width), expanded: expanded)
            let height = (guess * ratios[kind]).rounded()
            rows.append(Measure(signature: rowSignature, height: height, guess: guess, kind: kind, measured: false))
            total += height
            rebuiltRows += 1
        }
        return ItemRows(signature: signature, split: style.split, rows: rows, total: total, generation: generation)
    }

    static func parts(of item: ActivityItem, split: Split) -> Int {
        guard case .exploration(let group) = item else { return 1 }
        switch split {
        case .whole: return 1
        case .opened: return group.entries.count + 2
        case .calls: return max(1, group.calls.count)
        }
    }

    /// An item's signature: its content's revision, how it is shown, and the inputs. A whole
    /// row's is its own, with whether its call's details are open; a split item's changes with any
    /// of its rows', and whenever any call's details open or close (`expansions`), as its rows'
    /// own signatures tell which.
    static func signature(_ item: ActivityItem, style: Style, startsTurn: Bool, inputs: Inputs, expanded: Set<UUID>,
                          expansions: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(inputs)
        hasher.combine(style)
        hasher.combine(startsTurn)
        item.combineRevision(into: &hasher)
        if case .exploration = item {
            // A live card's last calls can open too.
            hasher.combine(expansions)
        } else {
            hasher.combine(expanded.contains(item.id))
        }
        return hasher.finalize()
    }

    /// A row of a split item's signature: what it shows of the item.
    static func signature(_ item: ActivityItem, part: Int, style: Style, startsTurn: Bool, inputs: Inputs, expanded: Set<UUID>) -> Int {
        var hasher = Hasher()
        hasher.combine(inputs)
        hasher.combine(style.split)
        hasher.combine(part)
        guard case .exploration(let group) = item else {
            item.combineRevision(into: &hasher)
            return hasher.finalize()
        }
        switch style.split {
        case .whole:
            item.combineRevision(into: &hasher)
        case .opened:
            if part == 0 {
                hasher.combine(group.id)
                hasher.combine(group.revision)
                hasher.combine(startsTurn)
            } else if part <= group.entries.count {
                let entry = group.entries[part - 1]
                hasher.combine(entry.id)
                hasher.combine(entry.count)
                hasher.combine(entry.state)
                hasher.combine(entry.failure)
                hasher.combine(entry.detail)
                hasher.combine(part == group.entries.count)
                hasher.combine(expanded.contains(entry.id))
            } else {
                hasher.combine(group.failureCount)
                for failure in group.failures { hasher.combine(failure.names.count) }
            }
        case .calls:
            let call = group.calls[part]
            call.combineRevision(into: &hasher)
            hasher.combine(part == 0 && startsTurn)
            hasher.combine(part == group.calls.count - 1)
            hasher.combine(expanded.contains(call.id))
        }
        return hasher.finalize()
    }

    /// A first guess at a row's height, gap included, before it is measured; scaled by what
    /// measurements of its kind taught.
    static func estimate(_ item: ActivityItem, part: Int, parts: Int, split: Split, startsTurn: Bool, width: Double,
                         expanded: Set<UUID>) -> (kind: Int, height: Double) {
        let avatar = startsTurn && part == 0 && item.isBotTurn ? 6.0 : 0
        let gap: Double = switch split {
        case .whole: 12
        case .opened: part == parts - 1 ? 12 : 0
        case .calls: part == parts - 1 ? 12 : 6
        }
        switch item {
        case .message(let message):
            switch message.role {
            case .user:
                let text = lines(message.text, width: min(width - 80, 640) - 28, character: 7.6)
                return (Kind.user, 6 + 18 + 17 * Double(text) + 248 * Double(message.images.count) + gap)
            case .assistant:
                let text = lines(message.text, width: width - 36 - 32, character: 7.6)
                return (Kind.reply, avatar + 26 + 18.5 * Double(text) + gap)
            case .tool:
                return (Kind.tool, avatar + 30 + (expanded.contains(message.id) ? 160 : 0) + gap)
            default:
                let text = lines(message.text, width: width - 40, character: 6.6)
                return (Kind.message, 6 + 16 * Double(text) + gap)
            }
        case .tool(let tool):
            let preview = tool.activity.output == nil ? 0.0 : 33
            return (Kind.tool, avatar + 37 + preview + (expanded.contains(tool.id) ? 160 : 0) + gap)
        case .exploration(let group):
            switch split {
            case .whole:
                let body = group.isOpen ? 8 + 26 * Double(min(3, group.entries.count)) : group.files.isEmpty ? 0 : 40
                return (Kind.card, avatar + 37 + body + 34 * Double(group.failures.count) + gap)
            case .opened:
                if part == 0 { return (Kind.head, avatar + 37) }
                if part == parts - 1 { return (Kind.foot, 8 + 34 * Double(group.failures.count) + gap) }
                let entry = group.entries[part - 1]
                return (Kind.entry, 24 + (part < parts - 2 ? 2 : 0) + (expanded.contains(entry.id) ? 160 * Double(entry.count) : 0))
            case .calls:
                let call = group.calls[min(part, group.calls.count - 1)]
                return (Kind.call, avatar + 30 + (expanded.contains(call.id) ? 160 : 0) + gap)
            }
        }
    }

    /// Roughly how many lines `text` takes at `width` points, `character` points a character.
    static func lines(_ text: String, width: Double, character: Double) -> Int {
        let perLine = max(10, (max(80, width) / character).rounded(.down))
        var lines = 0
        var run = 0
        for byte in text.utf8 {
            if byte == 10 {
                lines += max(1, Int((Double(run) / perLine).rounded(.up)))
                run = 0
            } else if byte & 0xC0 != 0x80 {
                run += 1
            }
        }
        lines += max(1, Int((Double(run) / perLine).rounded(.up)))
        return lines
    }
}

extension ActivityItem {
    /// What its rows' heights depend on, cheaply: an item that differs from what it was in any
    /// way the chat shows differs here too, as a turn writes into its thread (by adding messages,
    /// writing further into its last and into calls still running); any other change bumps the
    /// conversation's `epoch`.
    func combineRevision(into hasher: inout Hasher) {
        switch self {
        case .message(let message):
            hasher.combine(0)
            message.combineRevision(into: &hasher)
        case .tool(let tool):
            hasher.combine(1)
            tool.message.combineRevision(into: &hasher)
        case .exploration(let group):
            hasher.combine(2)
            hasher.combine(group.id)
            hasher.combine(group.revision)
        }
    }
}

extension ChatMessage {
    func combineRevision(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(role)
        hasher.combine(text.utf8.count)
        hasher.combine(images.count)
        hasher.combine(toolState)
        hasher.combine(toolInput?.utf8.count)
        hasher.combine(toolOutput?.utf8.count)
        hasher.combine(toolArguments?.utf8.count)
    }
}
