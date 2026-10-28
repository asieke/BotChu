import Foundation

public enum SubagentWorkspaceMode: String, Codable, Sendable, CaseIterable {
    case sharedCallerWorkspace = "shared"
    case subagentHomeWorkspace = "bot_home"
}

public enum SubagentPhase: String, Codable, Sendable, CaseIterable {
    case queued, preparing, running, completed, failed, stopped

    public var isActive: Bool { self == .queued || self == .preparing || self == .running }
}

public enum SubagentLimits {
    public static let maxDepth = 3
    public static let maxBriefCharacters = 100_000
    public static let maxRequestBytes = 512_000
    public static let heartbeatTimeout: TimeInterval = 30
}

/// A snapshot of the called bot. Later edits/deletion do not change a past delegation's identity.
public struct SubagentRun: Identifiable, Codable, Equatable, Sendable, RunSettings {
    public var id: UUID
    public var rootBotID: UUID
    public var rootTaskID: UUID?
    public var parentSubagentID: UUID?
    public var depth: Int
    public var targetBotID: UUID
    public var targetBotName: String
    public var targetBotEmoji: String
    public var targetBotAppearance: String?
    public var targetBotWorkspace: String
    public var title: String
    public var brief: String
    public var workspaceMode: SubagentWorkspaceMode
    public var workingDirectory: String
    public var hostID: UUID?
    /// The caller's mailbox can be remote even when this run uses the called bot's local home.
    public var callerInvocationID: UUID?
    public var callerHostID: UUID?
    public var accountID: String
    public var accountProfile: Account?
    public var model: String
    public var reasoningEffort: ReasoningEffort?
    public var fastMode: Bool?
    public var sessionID: String?
    public var sessionAccountID: String?
    public var reportedModel: ReportedModel?
    public var phase: SubagentPhase
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var handoffOutput: String?
    public var errorMessage: String?

    public init(id: UUID = UUID(), rootBotID: UUID, rootTaskID: UUID? = nil, parentSubagentID: UUID? = nil,
                depth: Int, targetBot: Bot, title: String, brief: String,
                workspaceMode: SubagentWorkspaceMode = .sharedCallerWorkspace, workingDirectory: String,
                hostID: UUID? = nil, callerInvocationID: UUID? = nil, callerHostID: UUID? = nil,
                phase: SubagentPhase = .queued, createdAt: Date = Date()) {
        self.id = id
        self.rootBotID = rootBotID
        self.rootTaskID = rootTaskID
        self.parentSubagentID = parentSubagentID
        self.depth = depth
        targetBotID = targetBot.id
        targetBotName = targetBot.name
        targetBotEmoji = targetBot.emoji
        targetBotAppearance = targetBot.appearance
        targetBotWorkspace = targetBot.workspace
        self.title = title
        self.brief = brief
        self.workspaceMode = workspaceMode
        self.workingDirectory = workingDirectory
        self.hostID = hostID
        self.callerInvocationID = callerInvocationID
        self.callerHostID = callerHostID
        accountID = targetBot.accountID
        accountProfile = targetBot.accountProfile
        model = targetBot.model
        reasoningEffort = targetBot.reasoningEffort
        fastMode = targetBot.fastMode
        self.phase = phase
        self.createdAt = createdAt
    }

    public var result: SubagentResult {
        SubagentResult(id: id, targetBotID: targetBotID, targetBotName: targetBotName, phase: phase,
                       handoffOutput: handoffOutput ?? "", errorMessage: errorMessage,
                       startedAt: startedAt, finishedAt: finishedAt ?? Date())
    }
}

/// How the Sub-agents tab lists a conversation's runs (#194). Each run the conversation started
/// (a root) heads its tree, with the runs it delegated to beneath it. Roots are grouped by the turn
/// that started them (`callerInvocationID`), or by day for records made before that was saved.
///
/// A root stays in view while anything in its tree is under way or has failed; once its tree has
/// ended completed or stopped with no failure, it moves into Finished at once, nested runs and all.
/// A failure never folds away: only clearing the run removes it.
public struct SubagentOverview: Equatable, Sendable {
    public enum GroupKey: Hashable, Sendable {
        case invocation(UUID)
        /// The start of the day, for records without an invocation.
        case day(Date)
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public var key: GroupKey
        public var id: GroupKey { key }
        /// When its turn delegated its first run.
        public var date: Date
        /// The roots it has in this part of the list, in the order they were delegated.
        public var roots: [SubagentRun]
        /// A run of its turn is under way: the turn the list leads with, without a caption.
        public var isUnderWay: Bool
    }

    /// Turns under way first, then those holding only failures, newest first.
    public var visible: [Group]
    /// Trees that ended completed or stopped with no failure, newest turn first.
    public var finished: [Group]
    private var parents: [UUID: UUID]
    private var failures: [UUID: Int]
    private var finishedRoots: Set<UUID>
    private var roots: [UUID: UUID]

    /// `runs` are a conversation's, oldest first, descendants beside its own.
    public init(runs: [SubagentRun], calendar: Calendar = .current) {
        let ids = Set(runs.map(\.id))
        let byParent = Dictionary(grouping: runs, by: \.parentSubagentID)
        // A run whose parent is missing (cleared, or a damaged record) heads its own tree.
        let heads = runs.filter { $0.parentSubagentID.map { !ids.contains($0) } ?? true }
        var parents: [UUID: UUID] = [:]
        var failures: [UUID: Int] = [:]
        var roots: [UUID: UUID] = [:]
        var underWay: Set<UUID> = []
        var finishedRoots: Set<UUID> = []
        for head in heads {
            var active = false
            var seen: Set<UUID> = []
            // Depth-first, returning how many runs beneath failed; bounded and guarded, so a
            // malformed saved tree can't loop.
            func walk(_ run: SubagentRun, depth: Int) -> Int {
                guard depth <= SubagentLimits.maxDepth + 1, seen.insert(run.id).inserted else { return 0 }
                roots[run.id] = head.id
                active = active || run.phase.isActive
                var below = 0
                for child in byParent[run.id] ?? [] where !seen.contains(child.id) {
                    parents[child.id] = run.id
                    below += walk(child, depth: depth + 1) + (child.phase == .failed ? 1 : 0)
                }
                if below > 0 { failures[run.id] = below }
                return below
            }
            let failed = walk(head, depth: 0) + (head.phase == .failed ? 1 : 0)
            if active { underWay.insert(head.id) } else if failed == 0 { finishedRoots.insert(head.id) }
        }

        func key(_ run: SubagentRun) -> GroupKey {
            run.callerInvocationID.map(GroupKey.invocation) ?? .day(calendar.startOfDay(for: run.createdAt))
        }
        var order: [GroupKey] = []
        var dates: [GroupKey: Date] = [:]
        for head in heads {
            let key = key(head)
            if dates[key] == nil { order.append(key) }
            dates[key] = min(dates[key] ?? head.createdAt, head.createdAt)
        }
        func groups(_ include: (SubagentRun) -> Bool) -> [Group] {
            let members = Dictionary(grouping: heads.filter(include), by: key)
            return order.compactMap { key in
                guard let roots = members[key], let date = dates[key] else { return nil }
                return Group(key: key, date: date, roots: roots, isUnderWay: roots.contains { underWay.contains($0.id) })
            }
        }
        func newestFirst(_ a: Group, _ b: Group) -> Bool { a.date > b.date }
        let shown = groups { !finishedRoots.contains($0.id) }
        visible = shown.filter(\.isUnderWay) + shown.filter { !$0.isUnderWay }.sorted(by: newestFirst)
        finished = groups { finishedRoots.contains($0.id) }.sorted(by: newestFirst)
        self.parents = parents
        self.failures = failures
        self.roots = roots
        self.finishedRoots = finishedRoots
    }

    /// How many trees Finished holds: the runs this conversation started, not their nested runs.
    public var finishedCount: Int { finished.reduce(0) { $0 + $1.roots.count } }

    /// How many runs beneath this one failed, at any depth.
    public func failedBelow(_ id: UUID) -> Int { failures[id] ?? 0 }

    /// Whether the run's tree is in Finished.
    public func isFinished(_ id: UUID) -> Bool { roots[id].map(finishedRoots.contains) ?? false }

    /// The run heading the tree this run is in.
    public func root(of id: UUID) -> UUID? { roots[id] }

    /// The runs above this one, its parent first.
    public func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = []
        var next = parents[id]
        while let current = next, !result.contains(current), result.count <= SubagentLimits.maxDepth {
            result.append(current)
            next = parents[current]
        }
        return result
    }

    /// Whether `id` is `ancestor` or beneath it.
    public func isInTree(_ id: UUID, of ancestor: UUID) -> Bool { id == ancestor || ancestors(of: id).contains(ancestor) }

    /// The caption above a group that isn't the turn under way: "Today, 11:02 AM",
    /// "Yesterday, 4:10 PM", "Saturday, Oct 24, 9:30 AM", or only the day for a group without an invocation.
    public static func caption(_ group: Group, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let day: String
        if calendar.isDate(group.date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(group.date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            let format = DateFormatter()
            format.locale = locale
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            format.setLocalizedDateFormatFromTemplate(calendar.isDate(group.date, equalTo: now, toGranularity: .year) ? "EEEEMMMd" : "EEEEMMMdy")
            day = format.string(from: group.date)
        }
        if case .day = group.key { return day }
        return "\(day), \(time.string(from: group.date))"
    }
}

/// What a run's row and details say about it: only what was recorded (#194). Nothing is inferred:
/// no progress, no blocked or accepted phase, and Done only for a run that ended with a handoff.
public struct SubagentRowState: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case queued, preparing, running, stopping, done, noHandoff, failed, stopped
    }

    public var kind: Kind
    /// The state's word: Queued, Preparing, the running activity (Reading files…), Done, No handoff…
    public var word: String
    /// When its time counts from: its start, or its creation until it starts.
    public var since: Date
    /// When it ended; nil while it ticks.
    public var ended: Date?

    /// `activity` is the running turn's (`RunState`), nil before it streams; `stopping`, that Stop
    /// was asked for and the process hasn't exited yet.
    public init(_ run: SubagentRun, activity: BotActivity? = nil, stopping: Bool = false) {
        since = run.startedAt ?? run.createdAt
        ended = run.phase.isActive ? nil : (run.finishedAt ?? run.startedAt ?? run.createdAt)
        switch run.phase {
        case .queued: (kind, word) = (.queued, "Queued")
        case .preparing: (kind, word) = (.preparing, "Preparing")
        case .running: (kind, word) = (.running, activity?.doing ?? "Working")
        case .completed:
            let empty = (run.handoffOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            (kind, word) = empty ? (.noHandoff, "No handoff") : (.done, "Done")
        case .failed: (kind, word) = (.failed, "Failed")
        case .stopped: (kind, word) = (.stopped, "Stopped")
        }
        if stopping, run.phase.isActive { (kind, word) = (.stopping, "Stopping…") }
    }

    public var isLive: Bool { ended == nil }

    /// Why a stopped run stopped, when it says more than "Stopped".
    public static func stopReason(_ run: SubagentRun) -> String? {
        guard run.phase == .stopped, let reason = run.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty, reason != "Stopped" else { return nil }
        return reason
    }
}

/// Where the Sub-agents tab is: its list, or a run's or a task's details pushed on it, each push
/// remembering where the list it left was, to come back to (#194).
public struct SubagentNavigation: Equatable, Sendable {
    public enum Route: Hashable, Sendable {
        case run(UUID)
        /// One of Home's tasks: its own list.
        case task(UUID)
    }

    /// A place in a list or details: the row opened from it, and the block on top of the view and
    /// how far down it was (a fraction of the view), so the list comes back anchored on content
    /// rather than pixels.
    public struct Mark: Equatable, Sendable {
        public var opened: UUID?
        public var anchor: SubagentAnchor?
        public var fraction: Double

        public init(opened: UUID? = nil, anchor: SubagentAnchor? = nil, fraction: Double = 0) {
            self.opened = opened
            self.anchor = anchor
            self.fraction = fraction
        }
    }

    public private(set) var path: [Route] = []
    private var marks: [Mark?] = []

    public init() {}

    public var top: Route? { path.last }

    /// Opens a row's route from where the reader is.
    public mutating func push(_ route: Route, from mark: Mark?) {
        guard path.last != route else { return }
        path.append(route)
        marks.append(mark)
    }

    /// The chat's Open: that run's details directly, whatever was shown. Back returns to the list
    /// as it was (`mark` has no row, so nothing opens to reveal one).
    public mutating func open(_ id: UUID, from mark: Mark?) {
        if path.last == .run(id) { return }
        let place = path.isEmpty ? mark : marks.first ?? nil
        path = [.run(id)]
        marks = [place.map { Mark(anchor: $0.anchor, fraction: $0.fraction) }]
    }

    /// Goes back one step, returning where to put the reader in what shows now.
    @discardableResult public mutating func back() -> Mark? {
        guard !path.isEmpty else { return nil }
        path.removeLast()
        return marks.removeLast()
    }

    /// Forgets routes to runs that no longer exist (cleared).
    public mutating func prune(keeping exists: (Route) -> Bool) {
        while let last = path.last, !exists(last) { back() }
    }
}

/// What the Sub-agents tab scrolls to and keeps in place: a run's row, or a block such as a
/// caption, Finished's heading or a section of the details.
public enum SubagentAnchor: Hashable, Sendable {
    case run(UUID)
    case block(String)
}

/// Caller metadata is descriptive only. The app resolves invocationID against its active turns
/// and uses that registered context, never a helper-supplied path, identity or depth.
public struct SubagentRequest: Codable, Equatable, Sendable {
    public var id: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    public var depth: Int
    public var targetAgent: String
    public var title: String?
    public var brief: String
    public var workspaceMode: SubagentWorkspaceMode?
    public var callerWorkingDirectory: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil,
                parentSubagentID: UUID? = nil, depth: Int = 0, targetAgent: String, title: String? = nil,
                brief: String, workspaceMode: SubagentWorkspaceMode? = nil, callerWorkingDirectory: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID
        self.parentSubagentID = parentSubagentID
        self.depth = depth
        self.targetAgent = targetAgent
        self.title = title
        self.brief = brief
        self.workspaceMode = workspaceMode
        self.callerWorkingDirectory = callerWorkingDirectory
        self.createdAt = createdAt
    }
}

public struct SubagentResult: Codable, Equatable, Sendable {
    public var id: UUID
    /// Nil when a request could not resolve its target bot.
    public var targetBotID: UUID?
    public var targetBotName: String
    public var phase: SubagentPhase
    public var handoffOutput: String
    public var errorMessage: String?
    public var startedAt: Date?
    public var finishedAt: Date

    public init(id: UUID, targetBotID: UUID? = nil, targetBotName: String, phase: SubagentPhase,
                handoffOutput: String = "", errorMessage: String? = nil, startedAt: Date? = nil,
                finishedAt: Date = Date()) {
        self.id = id
        self.targetBotID = targetBotID
        self.targetBotName = targetBotName
        self.phase = phase
        self.handoffOutput = handoffOutput
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct SubagentStatus: Codable, Equatable, Sendable {
    public var id: UUID
    public var phase: SubagentPhase
    public var activity: String
    public var updatedAt: Date

    public init(id: UUID, phase: SubagentPhase, activity: String, updatedAt: Date = Date()) {
        self.id = id
        self.phase = phase
        self.activity = activity
        self.updatedAt = updatedAt
    }
}

public struct BotRosterEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var slug: String
    public var name: String
    public var title: String
    public var emoji: String
    /// A remote queue bot, which is messaged (`botchu-message`) rather than delegated to.
    public var remote: Bool?
    public var isRemote: Bool { remote == true }

    public init(bot: Bot) {
        id = bot.id
        slug = Bot.slug(bot.name)
        name = bot.name
        title = bot.title
        emoji = bot.emoji
        remote = bot.isRemoteQueue ? true : nil
    }
}

public enum SubagentError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum SubagentResolver {
    /// `list` is the command that prints the roster, for the error's advice.
    public static func resolve(_ target: String, bots: [Bot], list: String = "botchu-subagent list") throws -> Bot {
        let query = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SubagentError.invalid("Choose an agent name, slug or UUID.") }
        if let id = UUID(uuidString: query), let bot = bots.first(where: { $0.id == id }) { return bot }
        let matches = bots.filter {
            $0.name.caseInsensitiveCompare(query) == .orderedSame || Bot.slug($0.name).caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1 else {
            if matches.isEmpty { throw SubagentError.invalid("No BotChu agent matches ‘\(query)’. Run \(list).") }
            throw SubagentError.invalid("Several BotChu agents match ‘\(query)’. Use the agent's UUID from \(list).")
        }
        return matches[0]
    }
}

/// Created by the app at CLI launch, including for nested turns; never decoded from requests.
public struct SubagentCallerContext: Equatable, Sendable {
    public var invocationID: UUID
    public var botID: UUID
    public var taskID: UUID?
    public var parentSubagentID: UUID?
    public var depth: Int
    public var workingDirectory: String
    public var hostID: UUID?

    public init(invocationID: UUID, botID: UUID, taskID: UUID? = nil, parentSubagentID: UUID? = nil,
                depth: Int = 0, workingDirectory: String, hostID: UUID? = nil) {
        self.invocationID = invocationID
        self.botID = botID
        self.taskID = taskID
        self.parentSubagentID = parentSubagentID
        self.depth = depth
        self.workingDirectory = workingDirectory
        self.hostID = hostID
    }

    public func validate(_ request: SubagentRequest, now: Date = Date()) throws {
        guard request.invocationID == invocationID, request.callerBotID == botID,
              request.callerTaskID == taskID, request.parentSubagentID == parentSubagentID,
              request.depth == depth else {
            throw SubagentError.invalid("The calling turn no longer matches this request. Delegate again from the active turn.")
        }
        guard depth >= 0, depth < SubagentLimits.maxDepth else {
            throw SubagentError.invalid("Maximum sub-agent depth (\(SubagentLimits.maxDepth)) reached.")
        }
        guard request.createdAt.timeIntervalSince(now) < 60, now.timeIntervalSince(request.createdAt) < 300 else {
            throw SubagentError.invalid("This sub-agent request is stale. Delegate again from the active turn.")
        }
        guard !request.targetAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.targetAgent.count <= 256 else { throw SubagentError.invalid("Provide an agent name, slug or UUID (up to 256 characters).") }
        guard !request.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.brief.count <= SubagentLimits.maxBriefCharacters else {
            throw SubagentError.invalid("The delegated brief must contain 1–\(SubagentLimits.maxBriefCharacters) characters.")
        }
        guard (request.title?.count ?? 0) <= 240 else { throw SubagentError.invalid("The sub-agent title must be at most 240 characters.") }
    }
}

/// The same JSON protocol is used locally and by the SSH mailbox bridge. Files become visible
/// only after an atomic rename. The owner must keep heartbeat.json fresh while polling requests.
public struct SubagentIPC: Sendable {
    public let root: URL
    public init(root: URL = Self.defaultRoot) { self.root = root }
    public static var defaultRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".botchu/ipc/subagents", isDirectory: true) }
    public static var defaultBinDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".botchu/bin", isDirectory: true) }
    public var requestsURL: URL { root.appendingPathComponent("requests", isDirectory: true) }
    public var statusDirectory: URL { root.appendingPathComponent("status", isDirectory: true) }
    public var resultsURL: URL { root.appendingPathComponent("results", isDirectory: true) }
    public var rosterURL: URL { root.appendingPathComponent("roster.json") }
    public var heartbeatURL: URL { root.appendingPathComponent("heartbeat.json") }
    public func requestURL(_ id: UUID) -> URL { requestsURL.appendingPathComponent("\(id.uuidString.lowercased()).json") }
    public func statusURL(_ id: UUID) -> URL { statusDirectory.appendingPathComponent("\(id.uuidString.lowercased()).status.json") }
    public func resultURL(_ id: UUID) -> URL { resultsURL.appendingPathComponent("\(id.uuidString.lowercased()).result.json") }

    public func prepare() throws {
        for directory in [root, requestsURL, statusDirectory, resultsURL] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    public func writeRoster(_ roster: [BotRosterEntry]) throws { try write(roster, to: rosterURL) }
    public func writeStatus(_ status: SubagentStatus) throws { try write(status, to: statusURL(status.id)) }
    public func writeResult(_ result: SubagentResult) throws {
        guard !result.phase.isActive else { throw SubagentError.invalid("A sub-agent result must have a terminal phase.") }
        try write(result, to: resultURL(result.id))
    }
    public func writeHeartbeat(now: Date = Date()) throws { try write(["updatedAt": now], to: heartbeatURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepare()
        try Self.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Oversized/malformed requests are returned for rejection, without unbounded allocation.
    public func pendingRequests() -> [(file: URL, data: Data)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: requestsURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), properties.isRegularFile == true else { return nil }
            if (properties.fileSize ?? 0) > SubagentLimits.maxRequestBytes { return (file, Data()) }
            return (try? Data(contentsOf: file)).map { (file, $0) }
        }
    }

    @discardableResult public func removeRequest(_ file: URL) -> Bool {
        guard file.deletingLastPathComponent().standardizedFileURL == requestsURL.standardizedFileURL else { return false }
        return (try? FileManager.default.removeItem(at: file)) != nil
    }
}
