import Foundation

/// One tool call in an exploration group.
public struct ExplorationCall: Equatable, Sendable, Identifiable {
    public var message: ChatMessage
    public var activity: ToolActivity
    public var id: UUID { message.id }

    public var state: ChatMessage.ToolState { message.toolState ?? .done }
}

/// A row of an open exploration group: one call, or the same file read again right after it,
/// shown once (`×2`) with the ranges of both reads merged.
public struct ExplorationEntry: Equatable, Sendable, Identifiable {
    public var calls: [ExplorationCall]
    public var id: UUID { calls[0].id }
    public var activity: ToolActivity { calls[0].activity }
    public var count: Int { calls.count }

    public var state: ChatMessage.ToolState {
        if calls.contains(where: { $0.state == .running }) { return .running }
        return calls.last!.state
    }

    /// `×2 · L1–60`, a range, `no matches`.
    public var detail: String? {
        guard count > 1 else { return activity.detail }
        let ranges = LineRange.merged(calls.flatMap { $0.activity.reads.compactMap(\.range) })
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
    /// What each failed call was about: a file name, or the command.
    public var names: [String]
    public var messageIDs: [UUID]
    public var count: Int { messageIDs.count }
    public var id: String { reason }
}

/// Consecutive read-only tool calls, folded into one summary: what they explored, where, for how
/// long, and what failed.
public struct ExplorationGroup: Equatable, Sendable, Identifiable {
    public struct Counts: Equatable, Sendable {
        public var files = 0
        public var folders = 0
        public var searches = 0
        public var fetches = 0
        public var commands = 0
    }

    public var calls: [ExplorationCall]
    public var entries: [ExplorationEntry]
    public var files: [FileChip]
    public var counts: Counts
    /// `in BotChu/App, Chat · BotChuCore`: the folders it touched, in short.
    public var location: String
    public var failures: [FailureSummary]
    /// Nothing follows it yet: while its turn runs, more calls may join it.
    public var isOpen: Bool
    public var id: UUID { calls[0].id }

    public var started: Date { calls[0].message.date }

    /// When its last call ended, as far as the calls say.
    public var finished: Date {
        calls.map { $0.message.date.addingTimeInterval($0.message.toolDuration ?? 0) }.max() ?? started
    }

    public var running: Bool { calls.contains { $0.state == .running } }
    public var failureCount: Int { failures.map(\.count).reduce(0, +) }

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

    public init(calls: [ExplorationCall], isOpen: Bool, root: String?) {
        self.calls = calls
        self.isOpen = isOpen
        var entries: [ExplorationEntry] = []
        var chips: [FileChip] = []
        var chipIndex: [String: Int] = [:]
        var folders = Set<String>(), counts = Counts(), touchedFiles: [String] = [], touchedFolders: [String] = []
        var failures: [FailureSummary] = []
        for call in calls {
            let activity = call.activity
            // The same single file read again right away is one row.
            if let last = entries.last, Self.sameRead(last.calls.last!, call) {
                entries[entries.count - 1].calls.append(call)
            } else {
                entries.append(ExplorationEntry(calls: [call]))
            }
            for read in activity.reads {
                let key = Self.normalized(read.path)
                if let index = chipIndex[key] {
                    chips[index].reads += 1
                } else {
                    chipIndex[key] = chips.count
                    chips.append(FileChip(path: read.path, name: ToolActivity.fileName(read.path), reads: 1))
                }
            }
            for list in activity.lists { folders.insert(Self.normalized(list)) }
            counts.searches += activity.searches.count
            counts.fetches += activity.fetches
            counts.commands += activity.inspections
            touchedFiles += activity.reads.map(\.path) + activity.edits
            touchedFolders += activity.lists + activity.searches.flatMap(\.paths)
            if let reason = activity.failure {
                let name = activity.reads.first.map { ToolActivity.fileName($0.path) } ?? activity.title
                if let index = failures.firstIndex(where: { $0.reason == reason }) {
                    failures[index].messageIDs.append(call.id)
                    if !failures[index].names.contains(name) { failures[index].names.append(name) }
                } else {
                    failures.append(FailureSummary(reason: reason, names: [name], messageIDs: [call.id]))
                }
            }
        }
        // A file only some failed calls tried to read isn't a file the group read.
        let readOK = Set(calls.filter { $0.activity.failure == nil }.flatMap { $0.activity.reads.map { Self.normalized($0.path) } })
        self.files = chips.filter { readOK.contains(Self.normalized($0.path)) }
        counts.files = self.files.count
        counts.folders = folders.count
        self.entries = entries
        self.counts = counts
        self.failures = failures
        location = FolderSummary.describe(files: touchedFiles, folders: touchedFolders, root: root)
    }

    static func sameRead(_ a: ExplorationCall, _ b: ExplorationCall) -> Bool {
        guard a.activity.intent == .read, b.activity.intent == .read, a.activity.reads.count == 1, b.activity.reads.count == 1,
              (a.activity.failure == nil) == (b.activity.failure == nil) else { return false }
        return normalized(a.activity.reads[0].path) == normalized(b.activity.reads[0].path) && a.activity.isShell == b.activity.isShell
    }

    static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
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

    var messageCount: Int {
        if case .exploration(let group) = self { return group.calls.count }
        return 1
    }

    var lastMessageID: UUID {
        if case .exploration(let group) = self { return group.calls.last!.id }
        return id
    }

    /// Nothing about it changes once something follows it: no call of it is still running.
    var isSettled: Bool {
        switch self {
        case .message: true
        case .tool(let tool): tool.state != .running
        case .exploration(let group): !group.running
        }
    }
}

/// A conversation's messages as the chat shows them, kept up to date as the conversation grows.
/// Items that can no longer change (they are followed by something, and none of their calls is
/// running) are kept; each update describes and groups only the messages after them, so a
/// streamed reply or a new tool call never costs a pass over the whole history.
public struct ActivityTranscript: Sendable {
    public private(set) var items: [ActivityItem] = []
    public let root: String?
    /// How many messages the last update looked at: the tail after the settled items.
    public private(set) var lastExamined = 0
    /// Items, and the messages they hold, that later updates leave alone.
    public private(set) var settledItems = 0
    private var settledMessages = 0
    private var boundary: UUID?
    private var described: [UUID: (signature: Signature, activity: ToolActivity)] = [:]

    private struct Signature: Equatable {
        var state: ChatMessage.ToolState?
        var name: String?
        var input: Int
        var output: Int
        var arguments: Int
        var exitCode: Int?

        init(_ message: ChatMessage) {
            state = message.toolState
            name = message.toolName
            input = message.toolInput?.utf8.count ?? -1
            output = message.toolOutput?.utf8.count ?? -1
            arguments = message.toolArguments?.utf8.count ?? -1
            exitCode = message.toolExitCode
        }
    }

    /// `root` is the conversation's folder (a task's worktree, a bot's workspace): paths in it show
    /// relative to it.
    public init(root: String? = nil) {
        self.root = root
    }

    public mutating func update(_ messages: [ChatMessage]) {
        // The settled part is still the start of this thread, unless it was replaced or shortened.
        if settledMessages > messages.count || (settledMessages > 0 && messages[settledMessages - 1].id != boundary) {
            items = []
            settledItems = 0
            settledMessages = 0
            boundary = nil
        }
        let tail = build(messages[settledMessages...])
        lastExamined = messages.count - settledMessages
        items.removeSubrange(settledItems...)
        items.append(contentsOf: tail)
        var index = settledItems
        while index < items.count - 1, items[index].isSettled {
            settledMessages += items[index].messageCount
            boundary = items[index].lastMessageID
            if case .exploration(let group) = items[index] {
                for call in group.calls { described[call.id] = nil }
            } else {
                described[items[index].id] = nil
            }
            index += 1
        }
        settledItems = index
    }

    private mutating func build(_ messages: ArraySlice<ChatMessage>) -> [ActivityItem] {
        var result: [ActivityItem] = []
        var pending: [ExplorationCall] = []
        func flush(open: Bool) {
            guard !pending.isEmpty else { return }
            result.append(.exploration(ExplorationGroup(calls: pending, isOpen: open, root: root)))
            pending = []
        }
        for message in messages {
            guard message.role == .tool else {
                flush(open: false)
                result.append(.message(message))
                continue
            }
            let activity = describe(message)
            if activity.intent.isExploration {
                pending.append(ExplorationCall(message: message, activity: activity))
            } else {
                flush(open: false)
                result.append(.tool(ToolCallItem(message: message, activity: activity)))
            }
        }
        flush(open: true)
        return result
    }

    private mutating func describe(_ message: ChatMessage) -> ToolActivity {
        let signature = Signature(message)
        if let cached = described[message.id], cached.signature == signature { return cached.activity }
        let activity = ToolActivity.describe(message, root: root)
        described[message.id] = (signature, activity)
        return activity
    }
}

/// The folders a group touched, in short: `BotChu/App, Chat · BotChuCore` for files in
/// `macOS/Sources/BotChu/App`, `…/Chat` and `macOS/Sources/BotChuCore`.
public enum FolderSummary {
    public static func describe(files: [String], folders given: [String] = [], root: String?, limit: Int = 3) -> String {
        var folders: [[String]] = []
        let all = files.map { ($0 as NSString).deletingLastPathComponent } + given
        for path in all where !path.isEmpty {
            let folder = ToolActivity.display(folder: (path as NSString).standardizingPath, root: root)
            let parts = folder.split(separator: "/").map(String.init).filter { $0 != "." }
            if !folders.contains(parts) { folders.append(parts) }
        }
        folders.removeAll { $0.isEmpty }
        guard !folders.isEmpty else { return "" }
        if folders.count == 1 { return tail(folders[0]) }
        // Strip the start every folder shares, then name each top folder with its subfolders.
        var common = 0
        while folders.allSatisfy({ $0.count > common + 1 }), Set(folders.map { $0[common] }).count == 1 { common += 1 }
        var order: [String] = []
        var children: [String: [String]] = [:]
        for folder in folders {
            let rest = Array(folder.dropFirst(common))
            let top = rest.first ?? ""
            if children[top] == nil { order.append(top); children[top] = [] }
            if rest.count > 1, !children[top]!.contains(rest.last!) { children[top]!.append(rest.last!) }
        }
        var parts = order.prefix(limit).map { top -> String in
            let subs = children[top] ?? []
            guard !subs.isEmpty else { return top }
            let shown = subs.prefix(4).joined(separator: ", ")
            return "\(top)/\(shown)" + (subs.count > 4 ? " +\(subs.count - 4)" : "")
        }
        if order.count > limit { parts.append("+\(order.count - limit) more") }
        return parts.joined(separator: " · ")
    }

    /// A long folder by its last two names.
    static func tail(_ parts: [String]) -> String {
        parts.count > 2 ? parts.suffix(2).joined(separator: "/") : parts.joined(separator: "/")
    }
}

/// Which `botchu-subagent` call started each delegated run, so the chat shows one card per run
/// where it was started: the ids the call printed first, then the runs that began while it ran.
public enum SubagentPlacement {
    public struct Launch: Sendable {
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
            let window = launch.started.addingTimeInterval(-2)...(launch.finished ?? now).addingTimeInterval(6)
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
