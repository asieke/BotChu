import Foundation

/// What a bot did in one turn of a Project Area before its reply, folded into one row (#425):
/// interim messages, tool calls and exploration groups, in order, behind "Worked 2 min · 14 files ·
/// 3 commands". Nothing is dropped: opened, the row shows every item it holds.
public struct TurnWork: Equatable, Sendable, Identifiable {
    public struct Counts: Equatable, Sendable {
        public var files = 0
        public var searches = 0
        public var commands = 0
        /// Tool calls, each call of a group counted.
        public var calls = 0
        public var messages = 0
    }

    /// Its first item's, so the row keeps its place as items join it.
    public let id: UUID
    public let items: [ActivityItem]
    /// Nothing but the turn's reply follows it: while the turn runs, more may join it.
    public let isOpen: Bool
    public let started: Date
    /// When its turn's reply began, or else when its last item ended.
    public let finished: Date
    public let counts: Counts
    /// Changes whenever anything it shows does.
    public let revision: Int
    /// A call of it is still running.
    public let running: Bool

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.revision == b.revision }

    init(items: [ActivityItem], isOpen: Bool, reply: Date?) {
        precondition(!items.isEmpty, "A work group holds something")
        id = items[0].id
        self.items = items
        self.isOpen = isOpen
        started = items[0].date
        var counts = Counts()
        var files = Set<String>()
        var end = started
        var running = false
        var hasher = Hasher()
        hasher.combine(isOpen)
        hasher.combine(reply)
        for item in items {
            item.combineRevision(into: &hasher)
            if !item.isFinished { running = true }
            switch item {
            case .message(let message):
                counts.messages += 1
                end = max(end, message.date)
            case .tool(let tool):
                counts.calls += 1
                if tool.activity.intent == .command { counts.commands += 1 }
                for path in tool.activity.edits { files.insert(ExplorationGroup.normalized(path)) }
                end = max(end, tool.message.date.addingTimeInterval(tool.message.toolDuration ?? 0))
            case .exploration(let group):
                counts.calls += group.calls.count
                counts.searches += group.counts.searches
                counts.commands += group.counts.commands
                for file in group.files { files.insert(ExplorationGroup.normalized(file.path)) }
                end = max(end, group.finished)
            case .work(let work):
                // Never nested; counted all the same.
                counts.calls += work.counts.calls
                counts.messages += work.counts.messages
                end = max(end, work.finished)
            }
        }
        counts.files = files.count
        self.counts = counts
        self.running = running
        let start = started
        finished = reply.map { max($0, start) } ?? end
        revision = hasher.finalize()
    }

    /// `14 files · 3 commands`; `2 calls` or `1 message` when it touched no file and ran nothing.
    public var summary: String {
        var parts: [String] = []
        func add(_ count: Int, _ one: String, _ many: String) { if count > 0 { parts.append("\(count) \(count == 1 ? one : many)") } }
        add(counts.files, "file", "files")
        add(counts.searches, "search", "searches")
        add(counts.commands, "command", "commands")
        if parts.isEmpty { add(counts.calls, "call", "calls") }
        if parts.isEmpty { add(counts.messages, "message", "messages") }
        return parts.joined(separator: " · ")
    }

    /// `Worked 2 min · 14 files · 3 commands`.
    public var headline: String {
        ["Worked " + Self.duration(finished.timeIntervalSince(started)), summary].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What it did last, for its row while the turn runs: `Running swift test`, `Reading Foo.swift`,
    /// or an interim message's first line.
    public var lastAction: String {
        guard let last = items.last else { return "" }
        return Self.describe(last)
    }

    /// `12 s`, `2 min`, `1 h 5 min`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        let minutes = total % 3600 / 60
        return "\(total / 3600) h" + (minutes > 0 ? " \(minutes) min" : "")
    }

    static func describe(_ item: ActivityItem) -> String {
        switch item {
        case .message(let message):
            let line = message.text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            return line.count > 120 ? String(line.prefix(119)) + "…" : line
        case .tool(let tool):
            return describe(tool.activity, running: tool.state == .running)
        case .exploration(let group):
            guard let entry = group.entries.last else { return group.summary }
            return describe(entry.activity, running: entry.state == .running)
        case .work(let work):
            return work.lastAction
        }
    }

    static func describe(_ activity: ToolActivity, running: Bool) -> String {
        let verb: String? = switch activity.intent {
        case .read: running ? "Reading" : "Read"
        case .list: running ? "Listing" : "Listed"
        case .search: running ? "Searching" : "Searched"
        case .fetch: running ? "Fetching" : "Fetched"
        case .inspect, .command: running ? "Running" : "Ran"
        case .edit: running ? "Editing" : (activity.verb ?? "Edited")
        case .subagent: running ? "Delegating" : "Delegated"
        case .plan: running ? "Updating the plan" : "Updated the plan"
        case .question: running ? "Asking" : "Asked"
        case .other: nil
        }
        let what = activity.intent == .command || activity.intent == .inspect
            ? ToolActivity.firstLine(activity.command ?? activity.title) : activity.title
        if activity.intent == .plan { return verb ?? what }
        return [verb, what].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// A Project Area's items with each turn's work folded into one `TurnWork` before its reply
/// (#425). A run of one bot's items between messages that aren't the bot's folds, but for its
/// last item when that is a reply, which shows in full. `botchu-subagent` calls stay rows of
/// their own, so their runs' cards show, and the work around them folds on each side.
///
/// Kept up to date as the transcript grows: the turns before the latest message that isn't a bot's
/// among the transcript's settled items fold once, and only the items after it fold again at each
/// update.
public struct WorkFolding: Sendable {
    private var identity: UUID?
    private var generation = 0
    private var folded = ChunkedArray<ActivityItem>()
    /// How many of `folded` stay as they are.
    private var keptCount = 0
    /// How many of the transcript's items those fold.
    private var consumed = 0
    /// How many items the last update folded, for tests.
    public private(set) var lastExamined = 0

    public init() {}

    public mutating func fold(_ transcript: ActivityTranscript) -> ChunkedArray<ActivityItem> {
        let items = transcript.items
        if transcript.identity != identity || transcript.generation != generation || consumed > transcript.settledItems {
            self = WorkFolding()
            identity = transcript.identity
            generation = transcript.generation
        }
        // The latest settled message that isn't a bot's ends a turn for good, with all before it.
        var boundary = consumed
        var index = min(transcript.settledItems, items.count) - 1
        while index >= consumed {
            if !items[index].isBotTurn {
                boundary = index + 1
                break
            }
            index -= 1
        }
        folded.removeSuffix(from: keptCount)
        lastExamined = 0
        if boundary > consumed {
            Self.fold(items[consumed..<boundary], into: &folded, closing: true)
            lastExamined += boundary - consumed
            keptCount = folded.count
            consumed = boundary
        }
        Self.fold(items[consumed...], into: &folded, closing: false)
        lastExamined += items.count - consumed
        return folded
    }

    /// Folds `items` all at once, as an area shows them.
    public static func fold(_ items: some Collection<ActivityItem>) -> ChunkedArray<ActivityItem> {
        var out = ChunkedArray<ActivityItem>()
        fold(items, into: &out, closing: false)
        return out
    }

    /// Appends `items` folded to `out`. Unless `closing`, the last turn may still grow: its work is open.
    static func fold(_ items: some Collection<ActivityItem>, into out: inout ChunkedArray<ActivityItem>, closing: Bool) {
        var run: [ActivityItem] = []
        /// The run's work, and with `turnEnds` its last item as the reply when it is one.
        func flush(turnEnds: Bool, open: Bool) {
            guard !run.isEmpty else { return }
            var reply: ActivityItem?
            if turnEnds, case .message(let message) = run[run.count - 1], message.role == .assistant {
                reply = run.removeLast()
            }
            if !run.isEmpty {
                var date: Date?
                if case .message(let message) = reply { date = message.date }
                out.append(.work(TurnWork(items: run, isOpen: open, reply: date)))
            }
            if let reply { out.append(reply) }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if !item.isBotTurn {
                flush(turnEnds: true, open: false)
                out.append(item)
            } else if item.staysUnfolded {
                flush(turnEnds: false, open: false)
                out.append(item)
            } else {
                if let first = run.first, first.speaker != item.speaker { flush(turnEnds: true, open: false) }
                run.append(item)
            }
        }
        flush(turnEnds: true, open: !closing)
    }
}

extension ActivityItem {
    /// A `botchu-subagent` call: its runs' cards show in an area's stream, outside the turn's work.
    var staysUnfolded: Bool {
        if case .tool(let tool) = self { return tool.activity.delegation != nil }
        return false
    }
}
