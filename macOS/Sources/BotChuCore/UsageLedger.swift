import Foundation

/// Passive, append-only accounting. Files belong to the bot, survive Clear Run, and contain no
/// conversation content. Callers hand off values; encoding, normalization and all IO run on storage.
public enum UsageLedger {
    public enum Kind: String, Codable, Sendable { case home, task, job, subagent }
    public enum Outcome: String, Codable, Sendable { case finished, failed, stopped }
    public enum ModelSource: String, Codable, Sendable { case reported, requested, unreported }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var at: Date
        public var startedAt: Date
        public var kind: Kind
        public var botID: UUID
        public var taskID: UUID?
        public var jobRunID: UUID?
        public var subagentRunID: UUID?
        /// Exact transcript identity, independent of queue waits or execution start time.
        public var messageID: UUID?
        /// All acknowledged prompts covered by this invocation. Usage is owned by `messageID`
        /// once, never divided heuristically among Claude's live follow-ups.
        public var messageIDs: [UUID]
        public var accountID: String
        public var provider: AgentKind
        /// The backend (for example openrouter or anthropic), distinct from the CLI family.
        public var providerID: String?
        /// Frozen execution/auth provenance; reconciliation must not consult today's profile.
        public var remote: Bool
        public var usesLegacyOpenRouterKey: Bool
        public var model: String?
        public var modelSource: ModelSource
        public var outcome: Outcome
        public var usage: TurnUsage?
        /// Only canonical UUID session identities are persisted. Paths and unknown IDs are dropped.
        public var sessionID: String?
        /// A first ledger-seen resumed session is a baseline, not a fresh session's usage.
        public var resumed: Bool

        public init(id: UUID = UUID(), at: Date = Date(), startedAt: Date, kind: Kind, botID: UUID,
                    taskID: UUID? = nil, jobRunID: UUID? = nil, subagentRunID: UUID? = nil,
                    messageID: UUID? = nil, messageIDs: [UUID] = [], accountID: String, provider: AgentKind, providerID: String? = nil,
                    remote: Bool = false, usesLegacyOpenRouterKey: Bool = false,
                    model: String? = nil, modelSource: ModelSource = .unreported, outcome: Outcome,
                    usage: TurnUsage? = nil, sessionID: String? = nil, resumed: Bool = false) {
            self.id = id; self.at = at; self.startedAt = startedAt; self.kind = kind; self.botID = botID
            self.taskID = taskID; self.jobRunID = jobRunID; self.subagentRunID = subagentRunID
            self.messageID = messageID; self.accountID = accountID; self.provider = provider
            self.messageIDs = messageIDs.isEmpty ? messageID.map { [$0] } ?? [] : messageIDs
            self.providerID = providerID; self.model = model; self.modelSource = modelSource
            self.remote = remote; self.usesLegacyOpenRouterKey = usesLegacyOpenRouterKey
            self.outcome = outcome; self.usage = usage; self.sessionID = sessionID; self.resumed = resumed
        }

        private enum CodingKeys: String, CodingKey {
            case id, at, startedAt, kind, botID, taskID, jobRunID, subagentRunID, messageID, messageIDs
            case accountID, provider, providerID, remote, usesLegacyOpenRouterKey, model, modelSource, outcome, usage, sessionID, resumed
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(at, forKey: .at)
            try c.encode(startedAt, forKey: .startedAt); try c.encode(kind, forKey: .kind)
            try c.encode(botID, forKey: .botID); try c.encodeIfPresent(taskID, forKey: .taskID)
            try c.encodeIfPresent(jobRunID, forKey: .jobRunID); try c.encodeIfPresent(subagentRunID, forKey: .subagentRunID)
            try c.encodeIfPresent(messageID, forKey: .messageID); try c.encode(accountID, forKey: .accountID)
            try c.encode(messageIDs, forKey: .messageIDs)
            try c.encode(provider, forKey: .provider); try c.encodeIfPresent(providerID, forKey: .providerID)
            try c.encode(remote, forKey: .remote); try c.encode(usesLegacyOpenRouterKey, forKey: .usesLegacyOpenRouterKey)
            try c.encodeIfPresent(model, forKey: .model); try c.encode(modelSource, forKey: .modelSource)
            try c.encode(outcome, forKey: .outcome); try c.encode(usage, forKey: .usage)
            try c.encodeIfPresent(sessionID, forKey: .sessionID); try c.encode(resumed, forKey: .resumed)
        }
    }

    /// One invocation, possibly several Claude result events and acknowledged live prompts.
    /// Constant-time event collection; aggregation and serialization happen only on storage.
    @MainActor public final class Capture {
        private var entry: Entry
        private var reports: [TurnUsage] = []
        private var ended = false

        public init(_ entry: Entry) { self.entry = entry }
        public func started(at: Date) { if !ended { entry.startedAt = at } }
        public func record(_ event: AgentEvent) {
            guard !ended else { return }
            switch event {
            case .usage(let usage): reports.append(usage)
            case .model(let model):
                if !model.isEmpty { entry.model = model; entry.modelSource = .reported }
            case .session(let id): entry.sessionID = id
            default: break
            }
        }
        public func include(messageID: UUID) {
            guard !ended else { return }
            entry.messageIDs.append(messageID)
        }
        public func finish(_ outcome: Outcome, at: Date = Date(), in home: BotHome,
                                    queue: StorageQueue = .shared) {
            guard !ended else { return }
            ended = true; entry.at = at; entry.outcome = outcome
            UsageLedger.append(entry, reports: reports, in: home, queue: queue)
        }
    }

    /// Reconciled whole-turn cost. Repeating an amendment is harmless; the latest valid value wins.
    /// No partial generation cost may be represented as a whole-turn actual cost.
    public struct Amendment: Codable, Equatable, Sendable {
        public var amends: UUID
        public var actualCostUSD: Double
        public init(amends: UUID, actualCostUSD: Double) {
            self.amends = amends; self.actualCostUSD = actualCostUSD
        }
    }

    public struct ReadResult: Sendable {
        public var entries: [Entry] = []
        public var amendments: [Amendment] = []
        public var unreadableLines = 0
        public var unreadableFiles = 0
    }

    public static func directory(in home: BotHome) -> URL { home.url.appendingPathComponent("usage", isDirectory: true) }
    public static func lane(in home: BotHome) -> String { directory(in: home).path }

    /// O(1) in ledger/history size on the caller. Usage aggregation also runs on the storage lane.
    public static func append(_ entry: Entry, reports: [TurnUsage] = [], in home: BotHome,
                              queue: StorageQueue = .shared,
                              done: (@MainActor @Sendable (Result<Void, Error>) -> Void)? = nil) {
        queue.submit(lane(in: home), label: "usage ledger append", work: {
            var entry = entry
            var total = TurnUsageAccumulator()
            if let usage = entry.usage { total.add(usage) }
            for report in reports { total.add(report) }
            entry.usage = total.value
            if entry.modelSource != .reported, let reported = entry.usage?.models.first(where: { !$0.model.isEmpty })?.model {
                entry.model = reported; entry.modelSource = .reported
            }
            // Local model backends can report a filename instead of a catalog ID. Keep the counts,
            // but do not persist filesystem locations as model/provider/generation identifiers.
            entry.model = entry.model.flatMap { identifier($0, slash: true) }
            if entry.model == nil { entry.modelSource = .unreported }
            entry.providerID = entry.providerID.flatMap { identifier($0) }
            entry.accountID = identifier(entry.accountID) ?? "unrecorded"
            if var usage = entry.usage {
                usage.models = usage.models.map { value in
                    var value = value; value.model = identifier(value.model, slash: true) ?? ""; return value
                }
                // Keep an explicit unsupported marker so reconciliation cannot mistake a partly
                // sanitized ID list for complete billable coverage.
                usage.generationIDs = usage.generationIDs.map { identifier($0) ?? "unrecorded" }
                entry.usage = usage
            }
            entry.sessionID = entry.sessionID.flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
            try write(entry, at: entry.at, in: home)
        }, done: done)
    }

    private static func identifier(_ value: String, slash: Bool = false) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:" + (slash ? "/" : ""))
        let segments = value.split(separator: "/")
        guard !value.isEmpty, value.utf8.count <= 512, !value.hasPrefix("/"), !value.contains(":/"),
              !segments.contains("."), !segments.contains(".."), value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    public static func amend(_ amendment: Amendment, at: Date = Date(), in home: BotHome,
                             queue: StorageQueue = .shared,
                             done: (@MainActor @Sendable (Result<Void, Error>) -> Void)? = nil) {
        queue.submit(lane(in: home), label: "usage ledger amend", work: {
            guard amendment.actualCostUSD.isFinite, amendment.actualCostUSD >= 0 else {
                throw CocoaError(.coderInvalidValue)
            }
            // Billing retries survive relaunch. Only this uncommon operation scans history;
            // ordinary turn completion never reads it. The lane serializes the check and append.
            let previous = try read(in: home).amendments.last { $0.amends == amendment.amends }
            guard previous != amendment else { return }
            try write(amendment, at: at, in: home)
        }, done: done)
    }

    /// Call off the main thread after a storage barrier when a current snapshot is needed.
    /// Damaged lines/files are skipped independently. Duplicate entry IDs keep their first value;
    /// amendments keep the last value for their target, even if the entry appears in a later file.
    public static func read(in home: BotHome) throws -> ReadResult {
        let folder = directory(in: home)
        guard FileManager.default.fileExists(atPath: folder.path) else { return ReadResult() }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result = ReadResult(), ids: Set<UUID> = [], amended: [UUID: Int] = [:]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for file in files {
            guard let data = try? Data(contentsOf: file) else { result.unreadableFiles += 1; continue }
            for bytes in data.split(separator: 10) {
                let line = Data(bytes)
                if let entry = try? decoder.decode(Entry.self, from: line) {
                    if ids.insert(entry.id).inserted { result.entries.append(entry) }
                } else if let amendment = try? decoder.decode(Amendment.self, from: line),
                          amendment.actualCostUSD.isFinite, amendment.actualCostUSD >= 0 {
                    if let i = amended[amendment.amends] { result.amendments[i] = amendment }
                    else { amended[amendment.amends] = result.amendments.count; result.amendments.append(amendment) }
                } else { result.unreadableLines += 1 }
            }
        }
        return result
    }

    private static func write<T: Encodable>(_ value: T, at: Date, in home: BotHome) throws {
        let folder = directory(in: home), fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: at)
        let filename = String(format: "%04d-%02d.jsonl", parts.year!, parts.month!)
        let file = folder.appendingPathComponent(filename)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value); data.append(10)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // One byte on the worker detects a torn append without scanning any ledger history.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            let last = try handle.read(upToCount: 1)
            try handle.seekToEnd()
            if last != Data([10]) { try handle.write(contentsOf: Data([10])) }
        }
        try handle.write(contentsOf: data)
    }
}
