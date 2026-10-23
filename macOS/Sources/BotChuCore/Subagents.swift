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
    public var sessionID: String?
    public var sessionAccountID: String?
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
        self.phase = phase
        self.createdAt = createdAt
    }

    public var result: SubagentResult {
        SubagentResult(id: id, targetBotID: targetBotID, targetBotName: targetBotName, phase: phase,
                       handoffOutput: handoffOutput ?? "", errorMessage: errorMessage,
                       startedAt: startedAt, finishedAt: finishedAt ?? Date())
    }
}

/// How the Sub-agents tab lists a conversation's own runs, each with the runs it delegated to
/// beneath it: those under way, and finished ones it keeps in view, first, in the order they were
/// delegated; every other one in Finished, newest first.
public struct SubagentSections: Equatable, Sendable {
    public var current: [SubagentRun]
    public var finished: [SubagentRun]

    /// `runs` are a conversation's, oldest first. A run finishes only after the runs beneath it,
    /// so its own phase says whether anything in its tree is under way.
    public init(_ runs: [SubagentRun], keeping kept: Set<UUID> = []) {
        let own = runs.filter { $0.parentSubagentID == nil }
        current = own.filter { $0.phase.isActive || kept.contains($0.id) }
        finished = own.filter { !$0.phase.isActive && !kept.contains($0.id) }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    public var failedCount: Int { finished.filter { $0.phase == .failed }.count }
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

    public init(bot: Bot) {
        id = bot.id
        slug = Bot.slug(bot.name)
        name = bot.name
        title = bot.title
        emoji = bot.emoji
    }
}

public enum SubagentError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum SubagentResolver {
    public static func resolve(_ target: String, bots: [Bot]) throws -> Bot {
        let query = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SubagentError.invalid("Choose an agent name, slug or UUID.") }
        if let id = UUID(uuidString: query), let bot = bots.first(where: { $0.id == id }) { return bot }
        let matches = bots.filter {
            $0.name.caseInsensitiveCompare(query) == .orderedSame || Bot.slug($0.name).caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1 else {
            if matches.isEmpty { throw SubagentError.invalid("No BotChu agent matches ‘\(query)’. Run botchu-subagent list.") }
            throw SubagentError.invalid("Several BotChu agents match ‘\(query)’. Use the agent's UUID from botchu-subagent list.")
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
