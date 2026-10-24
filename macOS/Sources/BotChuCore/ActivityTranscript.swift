import Foundation

/// What a read has in common with the read right after it when the two show as one row: the same
/// single file, read the same way, both failing or neither.
struct ReadKey: Hashable, Sendable {
    var path: String
    var isShell: Bool
    var failed: Bool

    init?(_ activity: ToolActivity) {
        guard activity.intent == .read, activity.reads.count == 1 else { return nil }
        path = ExplorationGroup.normalized(activity.reads[0].path)
        isShell = activity.isShell
        failed = activity.failure != nil
    }
}

/// The lines of a file a row's reads covered, merged as each read joins it, as `LineRange.merged`
/// merges them all at once.
struct LineSpans: Equatable, Sendable {
    private struct Span: Equatable, Sendable {
        var start: Int
        var end: Int
    }

    /// In order, none touching another.
    private var spans: [Span] = []
    /// `tail -n 30`: in order, each once.
    private var tails: [Int] = []

    mutating func insert(_ range: LineRange) {
        if let last = range.last {
            var low = 0, high = tails.count
            while low < high { let mid = (low + high) / 2; if tails[mid] < last { low = mid + 1 } else { high = mid } }
            if low == tails.count || tails[low] != last { tails.insert(last, at: low) }
            return
        }
        guard range.start != nil || range.end != nil else { return }
        var new = Span(start: range.start ?? 1, end: range.end ?? Int.max)
        // The first span that reaches the new one, and every one it touches from there.
        var low = 0, high = spans.count
        while low < high { let mid = (low + high) / 2; if Self.touches(spans[mid].end, new.start) { high = mid } else { low = mid + 1 } }
        var upper = low
        while upper < spans.count, Self.touches(new.end, spans[upper].start) {
            new.start = min(new.start, spans[upper].start)
            new.end = max(new.end, spans[upper].end)
            upper += 1
        }
        spans.replaceSubrange(low..<upper, with: [new])
    }

    /// The line after `end` is `start` or later.
    private static func touches(_ end: Int, _ start: Int) -> Bool { end == Int.max || end + 1 >= start }

    var ranges: [LineRange] {
        spans.map { LineRange(start: $0.start, end: $0.end == Int.max ? nil : $0.end) } + tails.map { LineRange(last: $0) }
    }
}

/// A row of an open exploration group: one call, or the same file read again right after it,
/// shown once (`×2`) with the ranges of both reads merged.
public struct ExplorationEntry: Equatable, Sendable, Identifiable {
    /// The first call's, which is the row's.
    public let id: UUID
    /// What its first call did; the calls joining it read the same file.
    public let activity: ToolActivity
    /// Where its calls are in the group's `calls`.
    public fileprivate(set) var range: Range<Int>
    /// Why its last call failed, if it did.
    public fileprivate(set) var failure: String?
    fileprivate var running = 0
    fileprivate var lastState: ChatMessage.ToolState
    fileprivate var lines = LineSpans()
    fileprivate let key: ReadKey?

    fileprivate init(_ message: ChatMessage, _ activity: ToolActivity, key: ReadKey?, at index: Int) {
        id = message.id
        self.activity = activity
        self.key = key
        range = index..<index
        lastState = message.toolState ?? .done
        add(message, activity)
    }

    fileprivate mutating func add(_ message: ChatMessage, _ activity: ToolActivity) {
        range = range.lowerBound..<range.upperBound + 1
        let state = message.toolState ?? .done
        if state == .running { running += 1 }
        lastState = state
        failure = activity.failure
        for read in activity.reads { if let lines = read.range { self.lines.insert(lines) } }
    }

    public var count: Int { range.count }

    public var state: ChatMessage.ToolState { running > 0 ? .running : lastState }

    /// `×2 · L1–60`, a range, `no matches`.
    public var detail: String? {
        guard count > 1 else { return activity.detail }
        let ranges = lines.ranges
        let label = ranges.prefix(2).map(\.label).joined(separator: ", ") + (ranges.count > 2 ? "…" : "")
        return label.isEmpty ? "×\(count)" : "×\(count) · \(label)"
    }
}

/// A file a group read, as a chip: its name, and how many times it was read.
public struct FileChip: Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var reads: Int
    public var id: String { path }
}

/// The failed calls of a group that failed the same way: `7 not found` and the files.
public struct FailureSummary: Equatable, Sendable, Identifiable {
    public var reason: String
    /// What each failed call was about, once each: a file name, or the command.
    public var names: [String]
    public var count: Int
    public var id: String { reason }
}

/// Consecutive read-only tool calls, folded into one summary: what they explored, where, for how
/// long, and what failed. Its summary is kept as calls join it (and as the latest ones are taken
/// out again, when they change), so a call costs the same in a group of 5,000 as in one of 5; and
/// two copies compare by `revision`, without comparing their calls.
public struct ExplorationGroup: Equatable, Sendable, Identifiable {
    public struct Counts: Equatable, Sendable {
        public var files = 0
        public var folders = 0
        public var searches = 0
        public var fetches = 0
        public var commands = 0
    }

    /// Its first call's, so the group keeps its place as calls join it.
    public let id: UUID
    /// Every call, as its CLI reported it.
    public private(set) var calls = ChunkedArray<ChatMessage>()
    public private(set) var entries = ChunkedArray<ExplorationEntry>()
    public private(set) var failures: [FailureSummary] = []
    public private(set) var failureCount = 0
    /// `in BotChu/App, Chat · BotChuCore`: the folders it touched, in short.
    public private(set) var location = ""
    /// Nothing follows it yet: while its turn runs, more calls may join it.
    public private(set) var isOpen: Bool
    /// When its last call ended, as far as the calls say.
    public private(set) var finished = Date.distantPast
    /// New with every change to the group.
    public private(set) var revision = UUID()
    public private(set) var counts = Counts()
    private var runningCalls = 0
    /// Every file read, in the order first read, with how many reads didn't fail.
    private var chips = ChunkedArray<Chip>()
    /// Its files, worked out once it can no longer change.
    private var settledFiles: [FileChip]?

    fileprivate struct Chip: Sendable {
        var path: String
        var reads: Int
        var ok: Int
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.revision == b.revision }

    public var started: Date { calls.first?.date ?? .distantPast }
    public var running: Bool { runningCalls > 0 }

    /// The files it read: those a call read without failing.
    public var files: [FileChip] { settledFiles ?? Self.files(chips) }

    /// `19 files · 1 search`.
    public var summary: String {
        var parts: [String] = []
        func add(_ count: Int, _ one: String, _ many: String) { if count > 0 { parts.append("\(count) \(count == 1 ? one : many)") } }
        add(counts.files, "file", "files")
        add(counts.folders, "folder", "folders")
        add(counts.searches, "search", "searches")
        add(counts.fetches, "fetch", "fetches")
        add(counts.commands, "command", "commands")
        if parts.isEmpty { add(calls.count, "call", "calls") }
        return parts.joined(separator: " · ")
    }

    /// The calls of one of its rows.
    public func calls(of entry: ExplorationEntry) -> Slice<ChunkedArray<ChatMessage>> { calls[entry.range] }

    init(id: UUID, isOpen: Bool) {
        self.id = id
        self.isOpen = isOpen
    }

    /// A group of these calls, each described afresh.
    public init(messages: [ChatMessage], isOpen: Bool, root: String?) {
        self.init(id: messages.first?.id ?? UUID(), isOpen: isOpen)
        var live = GroupLive(root: root, start: 0)
        for message in messages { append(message, ToolActivity.describe(message, root: root), &live, undoable: false) }
        _ = refreshLocation(&live)
    }

    /// Adds a call at its end. With `undoable` (or once any call is), it keeps what it takes to take
    /// the call out again (`removeLast`).
    mutating func append(_ message: ChatMessage, _ activity: ToolActivity, _ live: inout GroupLive, undoable: Bool) {
        let index = calls.count
        let recording = undoable || !live.undo.isEmpty
        var undo = GroupLive.Undo(finished: finished)
        calls.append(message)
        if message.toolState == .running { runningCalls += 1 }
        finished = max(finished, message.date.addingTimeInterval(message.toolDuration ?? 0))
        // The same single file read again right away joins its row.
        let key = ReadKey(activity)
        if let key, let last = entries.last, last.key == key {
            if recording { undo.entry = last }
            entries[entries.count - 1].add(message, activity)
        } else {
            entries.append(ExplorationEntry(message, activity, key: key, at: index))
        }
        // A file only failed calls tried to read isn't a file the group read.
        let ok = activity.failure == nil
        undo.ok = ok
        for read in activity.reads {
            let path = key?.path ?? Self.normalized(read.path)
            if let chip = live.chipIndex[path] {
                chips[chip].reads += 1
                if ok {
                    chips[chip].ok += 1
                    if chips[chip].ok == 1 { counts.files += 1 }
                }
                if recording { undo.chips.append(.init(index: chip, key: nil)) }
            } else {
                live.chipIndex[path] = chips.count
                chips.append(Chip(path: read.path, reads: 1, ok: ok ? 1 : 0))
                if ok { counts.files += 1 }
                if recording { undo.chips.append(.init(index: chips.count - 1, key: path)) }
            }
        }
        for list in activity.lists {
            let folder = Self.normalized(list)
            live.lists[folder, default: 0] += 1
            if live.lists[folder] == 1 { counts.folders += 1 }
            if recording { undo.lists.append(folder) }
        }
        undo.searches = activity.searches.count
        undo.fetches = activity.fetches
        undo.commands = activity.inspections
        counts.searches += undo.searches
        counts.fetches += undo.fetches
        counts.commands += undo.commands
        let folders = (activity.reads.map(\.path) + activity.edits).map(ToolActivity.parent) + activity.lists + activity.searches.flatMap(\.paths)
        for folder in folders {
            guard let parts = FolderTally.parts(of: folder, root: live.root) else { continue }
            live.places.add(parts)
            if recording { undo.places.append(parts) }
            live.placesChanged = true
        }
        if let reason = activity.failure {
            let name = activity.reads.first.map { ToolActivity.fileName($0.path) } ?? activity.title
            if let summary = live.failureIndex[reason] {
                failures[summary].count += 1
                let added = live.failureNames[summary].insert(name).inserted
                if added { failures[summary].names.append(name) }
                undo.failure = .init(index: summary, created: false, name: added ? name : nil)
            } else {
                live.failureIndex[reason] = failures.count
                live.failureNames.append([name])
                failures.append(FailureSummary(reason: reason, names: [name], count: 1))
                undo.failure = .init(index: failures.count - 1, created: true, name: name)
            }
            failureCount += 1
        }
        if recording {
            if live.undo.isEmpty { live.undoBase = index }
            live.undo.append(undo)
        } else {
            live.undoBase = index + 1
        }
        revision = UUID()
    }

    /// Whether its calls from `index` on can be taken out again.
    func canRemove(from index: Int, _ live: GroupLive) -> Bool {
        index >= live.undoBase && live.undoBase + live.undo.count == calls.count
    }

    /// Takes its last call out again, as if it had never joined.
    mutating func removeLast(_ live: inout GroupLive) {
        guard let undo = live.undo.popLast() else { preconditionFailure("No call to take out") }
        let message = calls.removeLast()
        if message.toolState == .running { runningCalls -= 1 }
        finished = undo.finished
        if let entry = undo.entry { entries[entries.count - 1] = entry } else { entries.removeLast() }
        for step in undo.chips.reversed() {
            chips[step.index].reads -= 1
            if undo.ok {
                chips[step.index].ok -= 1
                if chips[step.index].ok == 0 { counts.files -= 1 }
            }
            if let key = step.key {
                live.chipIndex[key] = nil
                chips.removeLast()
            }
        }
        for folder in undo.lists.reversed() {
            let count = (live.lists[folder] ?? 1) - 1
            live.lists[folder] = count > 0 ? count : nil
            if count == 0 { counts.folders -= 1 }
        }
        counts.searches -= undo.searches
        counts.fetches -= undo.fetches
        counts.commands -= undo.commands
        for parts in undo.places.reversed() { live.places.remove(parts) }
        if !undo.places.isEmpty { live.placesChanged = true }
        if let step = undo.failure {
            failures[step.index].count -= 1
            failureCount -= 1
            if step.created {
                live.failureIndex[failures[step.index].reason] = nil
                live.failureNames.removeLast()
                failures.removeLast()
            } else if let name = step.name {
                live.failureNames[step.index].remove(name)
                failures[step.index].names.removeLast()
            }
        }
        revision = UUID()
    }

    /// Names where it explored again, if calls that joined or left touched folders. Returns how many
    /// folders that looked at.
    mutating func refreshLocation(_ live: inout GroupLive) -> Int {
        guard live.placesChanged else { return 0 }
        live.placesChanged = false
        let location = live.places.describe()
        if location != self.location {
            self.location = location
            revision = UUID()
        }
        return live.places.count
    }

    mutating func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        revision = UUID()
    }

    /// Once nothing about it can change: its files are worked out for good.
    mutating func settle() {
        guard settledFiles == nil else { return }
        settledFiles = Self.files(chips)
        chips.removeAll()
    }

    private static func files(_ chips: ChunkedArray<Chip>) -> [FileChip] {
        var files = chips.filter { $0.ok > 0 }.map { FileChip(path: $0.path, name: ToolActivity.fileName($0.path), reads: $0.reads) }
        // Files of the same name say which folder they're in.
        let names = Dictionary(grouping: files.indices, by: { files[$0].name })
        for (_, indices) in names where indices.count > 1 {
            for index in indices {
                let folder = ((files[index].path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !folder.isEmpty { files[index].name = shortened(folder) + "/" + files[index].name }
            }
        }
        return files
    }

    static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// A long folder name (a UUID) by its end: `…F35D2397220`.
    static func shortened(_ name: String) -> String {
        name.count > 14 ? "…" + name.suffix(11) : name
    }
}

/// What a group still open keeps, apart from the group the views hold, to take calls in and to take
/// the latest out again without going over the others: which file, failure and folder each is
/// counted under, and how to undo each call that can still change. The transcript keeps it while
/// the group is in its tail, and drops it once the group settles.
struct GroupLive: Sendable {
    struct Undo: Sendable {
        struct ChipStep: Sendable {
            var index: Int
            /// Set when the call added the chip.
            var key: String?
        }

        struct FailureStep: Sendable {
            var index: Int
            var created: Bool
            /// Set when the call added the name.
            var name: String?
        }

        var finished: Date
        /// The row it joined, as it was before.
        var entry: ExplorationEntry?
        var ok = true
        var chips: [ChipStep] = []
        var lists: [String] = []
        var places: [[String]] = []
        var searches = 0
        var fetches = 0
        var commands = 0
        var failure: FailureStep?
    }

    let root: String?
    /// The index of the group's first call in the thread.
    let start: Int
    var chipIndex: [String: Int] = [:]
    var failureIndex: [String: Int] = [:]
    var failureNames: [Set<String>] = []
    var lists: [String: Int] = [:]
    var places = FolderTally()
    var placesChanged = false
    /// How to take out each call from `undoBase` on: those that can still change, and those after them.
    var undo: [Undo] = []
    var undoBase = 0

    init(root: String?, start: Int) {
        self.root = root
        self.start = start
    }

    /// Calls before `index` can't change any more: what it takes to take them out goes.
    mutating func forget(before index: Int) {
        guard index > undoBase else { return }
        if index - undoBase >= undo.count {
            undo = []
            undoBase = index
        } else {
            undo.removeFirst(index - undoBase)
            undoBase = index
        }
    }
}

/// A tool call that stands on its own: a command, an edit, a sub-agent, a question, another tool.
public struct ToolCallItem: Equatable, Sendable, Identifiable {
    public var message: ChatMessage
    public var activity: ToolActivity
    public var id: UUID { message.id }
    public var state: ChatMessage.ToolState { message.toolState ?? .done }
}

/// What the chat shows, in order: messages, standalone tool calls and exploration groups.
public enum ActivityItem: Equatable, Sendable, Identifiable {
    case message(ChatMessage)
    case tool(ToolCallItem)
    case exploration(ExplorationGroup)

    public var id: UUID {
        switch self {
        case .message(let message): message.id
        case .tool(let tool): tool.id
        case .exploration(let group): group.id
        }
    }

    public var date: Date {
        switch self {
        case .message(let message): message.date
        case .tool(let tool): tool.message.date
        case .exploration(let group): group.started
        }
    }

    /// Replies and tool work are the bot's; its avatar shows once at the start of a turn.
    public var isBotTurn: Bool {
        switch self {
        case .message(let message): message.role == .assistant
        case .tool, .exploration: true
        }
    }

    /// No call of it is still running.
    var isFinished: Bool {
        switch self {
        case .message: true
        case .tool(let tool): tool.state != .running
        case .exploration(let group): !group.running
        }
    }

    /// A `botchu-subagent` call that starts runs, as placing their cards needs it.
    var launch: SubagentPlacement.Launch? {
        guard case .tool(let tool) = self, let delegation = tool.activity.delegation, delegation.isLaunch else { return nil }
        let finished = tool.state == .running ? nil : tool.message.date.addingTimeInterval(tool.message.toolDuration ?? 1)
        return .init(messageID: tool.id, started: tool.message.date, finished: finished, printedIDs: tool.activity.runIDs,
                     launches: delegation.launches)
    }

    /// Where its messages, from `start` in `messages`, first differ from those it was made of.
    func firstMismatch(in messages: [ChatMessage], at start: Int) -> Int? {
        switch self {
        case .message(let message):
            return start < messages.count && messages[start] == message ? nil : 0
        case .tool(let tool):
            return start < messages.count && messages[start] == tool.message ? nil : 0
        case .exploration(let group):
            for (offset, call) in group.calls.enumerated() where start + offset >= messages.count || messages[start + offset] != call {
                return offset
            }
            return nil
        }
    }
}

/// A conversation's messages as the chat shows them, kept up to date as the conversation grows.
///
/// A turn writes into its thread by adding messages at the end and by writing further into its
/// last message and into calls still running (`ConversationState.stream`). So an update compares
/// only those with what it saw last, groups only new messages and what a change affects, and takes
/// out only the latest calls of a group when one of them changes. Items followed by something that
/// can no longer change are settled: kept as they are, with the running state of their groups
/// dropped. Any other change to the thread (replacing it, repairing it, editing it) needs
/// `update(_:verify:)` with `verify`, which compares every grouped message once and regroups from
/// the first that differs; a thread replaced by another starts over.
public struct ActivityTranscript: Sendable {
    /// What an update did, for tests and benchmarks of how much it costs.
    public struct Work: Equatable, Sendable {
        /// Messages compared with what the last update saw, to find what changed.
        public var checked = 0
        /// Messages grouped: new ones, changed ones, and those after a change that regrouped them.
        public var processed = 0
        /// Tool calls described (`ToolActivity.describe`).
        public var described = 0
        /// Calls added to an exploration group's summary, or taken out of it.
        public var aggregated = 0
        /// Folders looked at to name where groups explored.
        public var folders = 0

        public init(checked: Int = 0, processed: Int = 0, described: Int = 0, aggregated: Int = 0, folders: Int = 0) {
            self.checked = checked
            self.processed = processed
            self.described = described
            self.aggregated = aggregated
            self.folders = folders
        }
    }

    /// What the transcript keeps beyond its items, for tests of what it holds on to.
    public struct Retained: Equatable, Sendable {
        /// Groups with running state (`GroupLive`).
        public var groups = 0
        /// Calls those groups could still take out.
        public var undoable = 0
        /// Tool calls whose descriptions are kept.
        public var descriptions = 0
        /// Messages compared at each update.
        public var watched = 0

        public init(groups: Int = 0, undoable: Int = 0, descriptions: Int = 0, watched: Int = 0) {
            self.groups = groups
            self.undoable = undoable
            self.descriptions = descriptions
            self.watched = watched
        }
    }

    public private(set) var items = ChunkedArray<ActivityItem>()
    public let root: String?
    /// How many messages the last update grouped.
    public var lastExamined: Int { lastWork.processed }
    public private(set) var lastWork = Work()
    /// Items, and the messages they hold, that later updates leave alone.
    public private(set) var settledItems = 0
    /// Messages at the start of the thread it leaves out (`init(root:skipping:of:)`).
    public private(set) var skipped = 0
    /// New for each transcript, and when it starts over: tells a transcript from one put in its place.
    public private(set) var identity = UUID()
    /// New whenever it starts over or regroups settled items.
    public private(set) var generation = 0
    /// New whenever an item is added or taken out; not when one changes in place.
    public private(set) var structure = 0
    /// The `botchu-subagent` calls among its items that started runs, in order.
    public private(set) var launches: [SubagentPlacement.Launch] = []

    /// The index in the thread of each item's first message.
    private var starts = ChunkedArray<Int>()
    private var settledMessages = 0
    private var boundary: UUID?
    /// How many messages the last update saw.
    private var seen = 0
    /// The messages that can still change, as last seen: running calls in the tail, and the last message.
    private var watched: [Watch] = []
    private var described: [UUID: Described] = [:]
    /// The running state of the tail's groups, by group.
    private var live: [UUID: GroupLive] = [:]
    /// How many of `launches` are settled items'.
    private var settledLaunches = 0

    private struct Watch: Sendable {
        var index: Int
        var message: ChatMessage
    }

    private struct Described: Sendable {
        var fields: ToolFields
        var activity: ToolActivity
    }

    /// Everything of a message a description reads.
    private struct ToolFields: Equatable, Sendable {
        var name: String?
        var input: String?
        var output: String?
        var arguments: String?
        var state: ChatMessage.ToolState?
        var exitCode: Int?

        init(_ message: ChatMessage) {
            name = message.toolName
            input = message.toolInput
            output = message.toolOutput
            arguments = message.toolArguments
            state = message.toolState
            exitCode = message.toolExitCode
        }
    }

    /// Stands in for an item while it changes, so the item is the only copy the transcript holds.
    private static let placeholder = ActivityItem.message(ChatMessage(role: .note))

    /// `root` is the conversation's folder (a task's worktree, a bot's workspace): paths in it show
    /// relative to it.
    public init(root: String? = nil) {
        self.root = root
    }

    /// One that leaves out the first `count` messages: the newest part of a long thread, shown while
    /// the whole is grouped elsewhere. `count` should be where an item starts (`recentStart`).
    public init(root: String? = nil, skipping count: Int, of messages: [ChatMessage]) {
        self.root = root
        guard count > 0, count <= messages.count else { return }
        skipped = count
        settledMessages = count
        seen = count
        boundary = messages[count - 1].id
    }

    /// What it keeps beyond its items.
    public var retained: Retained {
        Retained(groups: live.count, undoable: live.values.map(\.undo.count).reduce(0, +), descriptions: described.count,
                 watched: watched.count)
    }

    /// How many messages the next update would group: those it hasn't seen, or all, if the thread
    /// was replaced.
    public func backlog(_ messages: [ChatMessage]) -> Int {
        if settledMessages > messages.count || (settledMessages > 0 && messages[settledMessages - 1].id != boundary) {
            return messages.count
        }
        return max(0, messages.count - seen)
    }

    /// Where to start grouping a long thread so that its newest `keeping` messages can show at once
    /// while the rest is grouped elsewhere: at a message that starts an item of its own (not a tool
    /// call, which may belong to a group with calls before it), at most `scanning` messages further
    /// back, or failing that closer to the end. Nil when no such message is there.
    public static func recentStart(in messages: [ChatMessage], keeping: Int, scanning: Int) -> Int? {
        let target = max(0, messages.count - keeping)
        guard target > 0 else { return 0 }
        var index = target
        while index >= max(0, target - scanning) {
            if messages[index].role != .tool { return index }
            index -= 1
        }
        index = target + 1
        while index < messages.count {
            if messages[index].role != .tool { return index }
            index += 1
        }
        return nil
    }

    public mutating func update(_ messages: [ChatMessage], verify: Bool = false) {
        var work = Work()
        // The settled part is still the start of this thread, unless it was replaced or shortened.
        if settledMessages > messages.count || (settledMessages > 0 && messages[settledMessages - 1].id != boundary) {
            reset()
        } else if verify || messages.count < seen || watched.contains(where: { $0.index >= messages.count || messages[$0.index].id != $0.message.id }) {
            // A turn never takes messages out or puts others in their place: the thread was edited.
            revalidate(messages, &work)
        }
        let settledBefore = settledItems
        // What changed since: the messages that could, and those added.
        var dirty = min(seen, messages.count)
        var changed: [Int] = []
        for watch in watched where watch.index < dirty {
            work.checked += 1
            if messages[watch.index] != watch.message { changed.append(watch.index) }
        }
        // A change that leaves the grouping as it was is made in place; any other regroups from it.
        for index in changed where index < dirty {
            if !patch(index, messages[index], &work) { dirty = index }
        }
        let undoFrom = earliestChangeable(messages, from: dirty)
        let removed = truncate(to: dirty, &work)
        let added = append(messages, from: dirty, undoFrom: undoFrom, &work)
        if removed || added { structure += 1 }
        relocate(&work)
        settle(messages)
        watch(messages, from: dirty)
        compact(messages)
        collectLaunches(from: settledBefore)
        seen = messages.count
        lastWork = work
    }

    private mutating func reset() {
        let generation = self.generation + 1, structure = self.structure + 1
        self = ActivityTranscript(root: root)
        self.generation = generation
        self.structure = structure
    }

    /// After a change other than a turn writing into the thread: takes out every item from the first
    /// whose messages differ (and a group just before it, which may take in the calls after it now).
    private mutating func revalidate(_ messages: [ChatMessage], _ work: inout Work) {
        var first: Int?
        for index in items.indices {
            let item = items[index]
            work.checked += item.messageCount
            if item.firstMismatch(in: messages, at: starts[index]) != nil {
                first = index
                break
            }
        }
        guard var first else { return }
        if first > 0, case .exploration = items[first - 1] { first -= 1 }
        let start = starts[first]
        for item in items[first...] { if case .exploration(let group) = item { live[group.id] = nil } }
        items.removeSuffix(from: first)
        starts.removeSuffix(from: first)
        if first < settledItems {
            settledItems = first
            settledMessages = start
            boundary = start > 0 ? messages[start - 1].id : nil
            launches = []
            settledLaunches = 0
            collectLaunches(from: 0)
            generation += 1
        }
        seen = start
        watched.removeAll { $0.index >= start }
        structure += 1
    }

    /// The first message that can still change once this update is done: a running call, or the last
    /// message. Calls from it on keep what it takes to take them out of their group again.
    private func earliestChangeable(_ messages: [ChatMessage], from dirty: Int) -> Int {
        var earliest = max(0, messages.count - 1)
        if let watch = watched.first(where: { $0.index < dirty && messages[$0.index].toolState == .running }) {
            earliest = min(earliest, watch.index)
        }
        if dirty < earliest, let running = messages[dirty..<earliest].firstIndex(where: { $0.role == .tool && $0.toolState == .running }) {
            earliest = running
        }
        return earliest
    }

    /// The item holding the message at `index`.
    private func item(holding index: Int) -> Int? {
        guard index >= 0, !starts.isEmpty else { return nil }
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= index { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    /// A message that changed in place: a reply streaming in, a standalone call finishing. False when
    /// the change may group the messages around it differently.
    private mutating func patch(_ index: Int, _ message: ChatMessage, _ work: inout Work) -> Bool {
        guard let item = item(holding: index), starts[item] == index, item >= settledItems else { return false }
        switch items[item] {
        case .message:
            guard message.role != .tool else { return false }
            items[item] = .message(message)
        case .tool:
            guard message.role == .tool else { return false }
            let activity = describe(message, keep: true, &work)
            guard !activity.intent.isExploration else { return false }
            items[item] = .tool(ToolCallItem(message: message, activity: activity))
        case .exploration:
            return false
        }
        work.processed += 1
        return true
    }

    /// Whether the group at `item` can take out its calls from the message at `index` on.
    private func canCut(_ item: Int, at index: Int) -> Bool {
        guard index > starts[item], case .exploration(let group) = items[item], let state = live[group.id] else { return false }
        return group.canRemove(from: index - starts[item], state)
    }

    /// Takes out what the messages from `index` on made, keeping what came before them. Returns
    /// whether an item went.
    private mutating func truncate(to index: Int, _ work: inout Work) -> Bool {
        guard index < seen, let item = item(holding: index) else { return false }
        var cut = item
        if canCut(item, at: index), case .exploration(var group) = items[item], var state = live.removeValue(forKey: group.id) {
            items[item] = Self.placeholder
            while group.calls.count > index - starts[item] {
                group.removeLast(&state)
                work.aggregated += 1
            }
            group.setOpen(true)
            items[item] = .exploration(group)
            live[group.id] = state
            cut = item + 1
        }
        guard cut < items.count else { return false }
        for gone in items[cut...] { if case .exploration(let group) = gone { live[group.id] = nil } }
        items.removeSuffix(from: cut)
        starts.removeSuffix(from: cut)
        // A group left last is open again: nothing follows it now.
        if cut > settledItems, case .exploration(var group) = items[cut - 1], !group.isOpen {
            items[cut - 1] = Self.placeholder
            group.setOpen(true)
            items[cut - 1] = .exploration(group)
        }
        return true
    }

    /// Groups the messages from `start` on, after the items there are. Returns whether it added items.
    private mutating func append(_ messages: [ChatMessage], from start: Int, undoFrom: Int, _ work: inout Work) -> Bool {
        guard start < messages.count else { return false }
        var added = false
        // The group they may join: the last item, still open. It's taken out of `items` while calls
        // join it, so that it's the only copy.
        var group: ExplorationGroup?
        var state: GroupLive?
        var slot = 0
        if items.count > settledItems, case .exploration(let last) = items[items.count - 1], last.isOpen, live[last.id] != nil {
            slot = items.count - 1
            state = live.removeValue(forKey: last.id)
            items[slot] = Self.placeholder
            group = last
        }
        for index in start..<messages.count {
            let message = messages[index]
            work.processed += 1
            if message.role == .tool {
                let activity = describe(message, keep: index >= undoFrom, &work)
                if activity.intent.isExploration {
                    if group == nil {
                        group = ExplorationGroup(id: message.id, isOpen: true)
                        state = GroupLive(root: root, start: index)
                        slot = items.count
                        items.append(Self.placeholder)
                        starts.append(index)
                        added = true
                    }
                    group!.append(message, activity, &state!, undoable: index >= undoFrom)
                    work.aggregated += 1
                    continue
                }
                store(&group, &state, at: slot, open: false, &work)
                items.append(.tool(ToolCallItem(message: message, activity: activity)))
            } else {
                store(&group, &state, at: slot, open: false, &work)
                items.append(.message(message))
            }
            starts.append(index)
            added = true
        }
        store(&group, &state, at: slot, open: true, &work)
        return added
    }

    /// Puts a group back in its place, open or closed by what follows it.
    private mutating func store(_ group: inout ExplorationGroup?, _ state: inout GroupLive?, at slot: Int, open: Bool, _ work: inout Work) {
        guard group != nil, state != nil else { return }
        group!.setOpen(open)
        work.folders += group!.refreshLocation(&state!)
        live[group!.id] = state
        items[slot] = .exploration(group!)
        group = nil
        state = nil
    }

    /// Names where a group explored again when calls taken out of it changed that, and no call
    /// joined it afterwards (which names it then).
    private mutating func relocate(_ work: inout Work) {
        let stale = live.compactMap { $0.value.placesChanged ? (id: $0.key, start: $0.value.start) : nil }
        for (id, start) in stale {
            guard let index = item(holding: start), case .exploration(var group) = items[index], group.id == id,
                  var state = live.removeValue(forKey: id) else { continue }
            items[index] = Self.placeholder
            work.folders += group.refreshLocation(&state)
            items[index] = .exploration(group)
            live[id] = state
        }
    }

    /// Settles the items that can no longer change: none of their calls runs, and what follows them
    /// can't group with them any more (it isn't a tool call that is running or last, whose kind may
    /// still change).
    private mutating func settle(_ messages: [ChatMessage]) {
        var index = settledItems
        while index < items.count - 1, items[index].isFinished {
            let next = starts[index + 1]
            let first = messages[next]
            guard first.role != .tool || (first.toolState != .running && next != messages.count - 1) else { break }
            if case .exploration(var group) = items[index] {
                live[group.id] = nil
                items[index] = Self.placeholder
                group.settle()
                items[index] = .exploration(group)
            }
            settledMessages = next
            boundary = messages[next - 1].id
            index += 1
        }
        settledItems = index
    }

    /// Notes the messages that can still change, as they are now.
    private mutating func watch(_ messages: [ChatMessage], from dirty: Int) {
        guard let last = messages.indices.last else {
            watched = []
            return
        }
        var next: [Watch] = []
        func running(_ index: Int) -> Bool { messages[index].role == .tool && messages[index].toolState == .running }
        for watch in watched where watch.index < min(dirty, last) && watch.index >= settledMessages && running(watch.index) {
            next.append(Watch(index: watch.index, message: messages[watch.index]))
        }
        for index in max(dirty, settledMessages)..<max(last, max(dirty, settledMessages)) where running(index) {
            next.append(Watch(index: index, message: messages[index]))
        }
        if last >= settledMessages { next.append(Watch(index: last, message: messages[last])) }
        watched = next
    }

    /// Lets go of what only messages that can still change need: the undo state of calls before the
    /// first of them, and descriptions of calls before it.
    private mutating func compact(_ messages: [ChatMessage]) {
        let earliest = watched.first?.index ?? messages.count
        for id in Array(live.keys) { live[id]!.forget(before: earliest - live[id]!.start) }
        guard !described.isEmpty else { return }
        let keep = Set(messages[max(earliest, settledMessages)...].lazy.map(\.id))
        described = described.filter { keep.contains($0.key) }
    }

    /// The launches of the settled items stay; the tail's are looked at again.
    private mutating func collectLaunches(from settledBefore: Int) {
        launches.removeSubrange(settledLaunches...)
        for index in settledBefore..<items.count {
            if index == settledItems { settledLaunches = launches.count }
            if let launch = items[index].launch { launches.append(launch) }
        }
        if settledItems >= items.count { settledLaunches = launches.count }
    }

    private mutating func describe(_ message: ChatMessage, keep: Bool, _ work: inout Work) -> ToolActivity {
        let fields = ToolFields(message)
        if let cached = described[message.id], cached.fields == fields { return cached.activity }
        work.described += 1
        let activity = ToolActivity.describe(message, root: root)
        if keep { described[message.id] = Described(fields: fields, activity: activity) }
        return activity
    }
}

extension ActivityItem {
    var messageCount: Int {
        if case .exploration(let group) = self { return group.calls.count }
        return 1
    }
}

/// The folders a group touched, in short: `BotChu/App, Chat · BotChuCore` for files in
/// `macOS/Sources/BotChu/App`, `…/Chat` and `macOS/Sources/BotChuCore`.
public enum FolderSummary {
    public static func describe(files: [String], folders given: [String] = [], root: String?, limit: Int = 3) -> String {
        var tally = FolderTally()
        for path in files.map(ToolActivity.parent) + given {
            if let parts = FolderTally.parts(of: path, root: root) { tally.add(parts) }
        }
        return tally.describe(limit: limit)
    }

    /// A long folder by its last two names.
    static func tail(_ parts: [String]) -> String {
        (parts.count > 2 ? Array(parts.suffix(2)) : parts).map(short).joined(separator: "/")
    }

    /// A folder named by an id: its end is enough to tell it apart.
    static func short(_ name: String) -> String {
        name.count > 24 ? "…" + name.suffix(11) : name
    }
}

/// The folders a group touched and how often, kept as calls join and leave it, so naming them looks
/// at each folder once rather than at every call.
struct FolderTally: Sendable {
    /// In the order first touched.
    private var order: [[String]] = []
    private var weight: [[String]: Int] = [:]
    /// Folders holding others it touched (a search of `Sources`), with how many.
    private var holding: [[String]: Int] = [:]

    var count: Int { order.count }

    /// A folder as its parts, shown relative to `root`; nil for none.
    static func parts(of folder: String, root: String?) -> [String]? {
        guard !folder.isEmpty else { return nil }
        let parts = ToolActivity.display(folder: folder, root: root).split(separator: "/").map(String.init).filter { $0 != "." }
        return parts.isEmpty ? nil : parts
    }

    mutating func add(_ parts: [String]) {
        if let count = weight[parts] {
            weight[parts] = count + 1
            return
        }
        weight[parts] = 1
        order.append(parts)
        for length in 1..<parts.count { holding[Array(parts.prefix(length)), default: 0] += 1 }
    }

    /// Takes out the latest `add` of `parts`.
    mutating func remove(_ parts: [String]) {
        guard let count = weight[parts] else { return }
        guard count == 1 else {
            weight[parts] = count - 1
            return
        }
        weight[parts] = nil
        if let index = order.lastIndex(of: parts) { order.remove(at: index) }
        for length in 1..<parts.count {
            let prefix = Array(parts.prefix(length))
            let left = (holding[prefix] ?? 1) - 1
            holding[prefix] = left > 0 ? left : nil
        }
    }

    func describe(limit: Int = 3) -> String {
        // A folder that holds others the group touched (a search of `Sources`) adds nothing.
        let folders = order.filter { holding[$0] == nil }
        guard !folders.isEmpty else { return "" }
        if folders.count == 1 { return FolderSummary.tail(folders[0]) }
        // Strip the start every folder shares, then name each top folder with its subfolders,
        // the most used first.
        var common = 0
        while folders.allSatisfy({ $0.count > common + 1 && $0[common] == folders[0][common] }) { common += 1 }
        var tops: [String] = []
        var children: [String: [String]] = [:]
        var known: [String: Set<String>] = [:]
        var used: [String: Int] = [:]
        var childUse: [String: Int] = [:]
        for folder in folders {
            let rest = folder.dropFirst(common)
            let top = rest.first ?? ""
            let uses = weight[folder] ?? 1
            if children[top] == nil {
                tops.append(top)
                children[top] = []
            }
            used[top, default: 0] += uses
            if rest.count > 1, let child = rest.last {
                if known[top, default: []].insert(child).inserted { children[top]?.append(child) }
                childUse[top + "/" + child, default: 0] += uses
            }
        }
        let ranked = tops.enumerated().sorted { a, b in
            let (x, y) = (used[a.element] ?? 0, used[b.element] ?? 0)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        var parts = ranked.prefix(limit).map { top -> String in
            let subs = (children[top] ?? []).enumerated().sorted { a, b in
                let (x, y) = (childUse[top + "/" + a.element] ?? 0, childUse[top + "/" + b.element] ?? 0)
                return x != y ? x > y : a.offset < b.offset
            }.map { FolderSummary.short($0.element) }
            guard !subs.isEmpty else { return FolderSummary.short(top) }
            return "\(FolderSummary.short(top))/" + subs.prefix(4).joined(separator: ", ") + (subs.count > 4 ? " +\(subs.count - 4)" : "")
        }
        if ranked.count > limit { parts.append("+\(ranked.count - limit) more") }
        return parts.joined(separator: " · ")
    }
}

/// Which `botchu-subagent` call started each delegated run, so the chat shows one card per run
/// where it was started: the ids the call printed first, then the runs that began while it ran.
public enum SubagentPlacement {
    public struct Launch: Equatable, Sendable {
        public var messageID: UUID
        public var started: Date
        public var finished: Date?
        public var printedIDs: [UUID]
        public var launches: [DelegationCall.Launch]

        public init(messageID: UUID, started: Date, finished: Date?, printedIDs: [UUID], launches: [DelegationCall.Launch]) {
            self.messageID = messageID
            self.started = started
            self.finished = finished
            self.printedIDs = printedIDs
            self.launches = launches
        }
    }

    public struct Run: Sendable {
        public var id: UUID
        public var createdAt: Date
        public var title: String
        public var agent: String

        public init(id: UUID, createdAt: Date, title: String, agent: String) {
            self.id = id
            self.createdAt = createdAt
            self.title = title
            self.agent = agent
        }
    }

    /// Run ids by the message of the call that started them. Runs no call claims are left out.
    public static func assign(launches: [Launch], runs: [Run], now: Date = Date()) -> [UUID: [UUID]] {
        let known = Set(runs.map(\.id))
        var claimed = Set<UUID>()
        var result: [UUID: [UUID]] = [:]
        for launch in launches {
            let ids = launch.printedIDs.filter { known.contains($0) && !claimed.contains($0) }
            result[launch.messageID] = ids
            claimed.formUnion(ids)
        }
        for launch in launches {
            let missing = launch.launches.count - (result[launch.messageID]?.count ?? 0)
            guard missing > 0 else { continue }
            // A run is admitted a moment after its request: within the call, or just after it for
            // `spawn`, which returns at once.
            let lower = launch.started.addingTimeInterval(-2)
            let window = lower...max(lower, (launch.finished ?? now).addingTimeInterval(6))
            let candidates = runs.filter { !claimed.contains($0.id) && window.contains($0.createdAt) }
                .sorted { a, b in
                    let (x, y) = (score(a, launch), score(b, launch))
                    return x != y ? x > y : a.createdAt < b.createdAt
                }
            let taken = candidates.prefix(missing).sorted { $0.createdAt < $1.createdAt }.map(\.id)
            result[launch.messageID, default: []] += taken
            claimed.formUnion(taken)
        }
        return result
    }

    private static func score(_ run: Run, _ launch: Launch) -> Int {
        launch.launches.map { wanted in
            (wanted.title.map { $0 == run.title || run.title.hasPrefix($0) } == true ? 2 : 0)
                + (wanted.agent.caseInsensitiveCompare(run.agent) == .orderedSame || Bot.slug(wanted.agent) == Bot.slug(run.agent) ? 1 : 0)
        }.max() ?? 0
    }

    /// For runs no call claimed: the item each follows, the last one that began before it.
    public static func anchors(for runs: [Run], items: [(id: UUID, date: Date)]) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for run in runs.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let anchor = items.last(where: { $0.date <= run.createdAt }) ?? items.first else { continue }
            result[anchor.id, default: []].append(run.id)
        }
        return result
    }
}

/// Which delegated runs show where in a conversation's chat: each with the `botchu-subagent` call
/// that started it, and any the calls don't account for after the item that came before them.
public struct SubagentCards: Sendable {
    private var placed: [UUID: [SubagentRun]] = [:]
    private var leftover: [UUID: [SubagentRun]] = [:]
    private var all: [UUID: SubagentRun] = [:]

    public init() {}

    public init(launches: [SubagentPlacement.Launch], items: ChunkedArray<ActivityItem>, runs: [SubagentRun], now: Date = Date()) {
        let top = runs.filter { $0.parentSubagentID == nil }
        guard !top.isEmpty else { return }
        all = Dictionary(top.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let assigned = SubagentPlacement.assign(launches: launches, runs: top.map(Self.placement), now: now)
        for (message, ids) in assigned { placed[message] = ids.compactMap { all[$0] } }
        let claimed = Set(assigned.values.flatMap { $0 })
        let unclaimed = top.filter { !claimed.contains($0.id) }
        if !unclaimed.isEmpty {
            let anchors = SubagentPlacement.anchors(for: unclaimed.map(Self.placement), items: items.map { ($0.id, $0.date) })
            for (item, ids) in anchors { leftover[item] = ids.compactMap { all[$0] } }
        }
    }

    private static func placement(_ run: SubagentRun) -> SubagentPlacement.Run {
        .init(id: run.id, createdAt: run.createdAt, title: run.title, agent: run.targetBotName)
    }

    /// Whether some run no call accounts for shows after an item: where depends on the items.
    var hasLeftovers: Bool { !leftover.isEmpty }

    /// Runs no call accounts for, which began after this item.
    public func unplaced(after item: UUID) -> [SubagentRun] { leftover[item] ?? [] }

    /// The runs a call started; for a `wait`, those it names in its output, or while it waits,
    /// those still running.
    public func runs(for item: ActivityItem) -> [SubagentRun] {
        guard case .tool(let tool) = item, let delegation = tool.activity.delegation else { return [] }
        if delegation.isLaunch { return placed[tool.id] ?? [] }
        let named = tool.activity.runIDs.compactMap { all[$0] }
        if !named.isEmpty || tool.state != .running { return named }
        return all.values.filter { $0.phase.isActive }.sorted { $0.createdAt < $1.createdAt }
    }
}

/// A conversation's last placement of its runs' cards, worked out again only when what it depends
/// on changes: the calls that started runs (their state, end, and the ids they printed), the runs'
/// records, and, while some run no call accounts for is placed by time, the items. A reply
/// streaming in changes none of these.
public struct SubagentCardsCache: Sendable {
    private struct Key: Equatable, Sendable {
        var transcript: UUID
        var generation: Int
        var structure: Int?
        var launches: [SubagentPlacement.Launch]
        var runs: [SubagentRun]
    }

    private var key: Key?
    private var cards = SubagentCards()
    /// How many times it worked the placement out.
    public private(set) var rebuilds = 0

    public init() {}

    public mutating func cards(for transcript: ActivityTranscript, runs: [SubagentRun], now: Date = Date()) -> SubagentCards {
        var key = Key(transcript: transcript.identity, generation: transcript.generation, structure: nil, launches: transcript.launches, runs: runs)
        if cards.hasLeftovers { key.structure = transcript.structure }
        if key == self.key { return cards }
        rebuilds += 1
        cards = SubagentCards(launches: transcript.launches, items: transcript.items, runs: runs, now: now)
        if cards.hasLeftovers { key.structure = transcript.structure } else { key.structure = nil }
        self.key = key
        return cards
    }
}

/// `23 tool calls · 5 shell`: how many tool calls a transcript holds.
public struct ToolCounts: Equatable, Sendable {
    public var tools = 0
    public var shell = 0

    public init(tools: Int = 0, shell: Int = 0) {
        self.tools = tools
        self.shell = shell
    }

    public init(messages: [ChatMessage]) {
        for message in messages where message.role == .tool {
            tools += 1
            if ToolActivity.isShell(toolName: message.toolName ?? "") { shell += 1 }
        }
    }

    public var parts: [String] {
        guard tools > 0 else { return [] }
        return ["\(tools) tool \(tools == 1 ? "call" : "calls")"] + (shell > 0 ? ["\(shell) shell"] : [])
    }
}

/// A sub-agent's `ToolCounts`, kept up to date as its transcript streams in: each update looks at
/// new messages and at those that can still change (running calls and the last message, whose
/// tool's name may still arrive), not at the whole transcript. A transcript replaced by another is
/// counted again.
public struct ToolCallTally: Sendable {
    public private(set) var counts = ToolCounts()
    /// How many messages the last update looked at.
    public private(set) var lastExamined = 0
    private var seen = 0
    private var boundary: UUID?
    /// Calls that can still change, as counted.
    private var open: [(index: Int, shell: Bool)] = []

    public init() {}

    public mutating func update(_ messages: [ChatMessage]) {
        if seen > messages.count || (seen > 0 && messages[seen - 1].id != boundary) { self = ToolCallTally() }
        var examined = 0
        for call in open {
            examined += 1
            let shell = ToolActivity.isShell(toolName: messages[call.index].toolName ?? "")
            if shell != call.shell { counts.shell += shell ? 1 : -1 }
        }
        for message in messages[seen...] where message.role == .tool {
            counts.tools += 1
            if ToolActivity.isShell(toolName: message.toolName ?? "") { counts.shell += 1 }
        }
        examined += messages.count - seen
        var next: [(index: Int, shell: Bool)] = []
        for index in open.map(\.index) + Array(seen..<messages.count) where Self.canChange(messages, index) {
            next.append((index, ToolActivity.isShell(toolName: messages[index].toolName ?? "")))
        }
        open = next
        seen = messages.count
        boundary = messages.last?.id
        lastExamined = examined
    }

    private static func canChange(_ messages: [ChatMessage], _ index: Int) -> Bool {
        messages[index].role == .tool && (messages[index].toolState == .running || index == messages.count - 1)
    }
}
