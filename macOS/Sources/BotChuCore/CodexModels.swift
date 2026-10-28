import Foundation

/// A configured profile as its command runs it on this Mac, whose CLI lists its own models (#220).
/// A changed command is another scope; a host's task has none, since a list read here says nothing
/// about what the host can run.
public struct ModelCatalogScope: Hashable, Sendable {
    public var accountID: String
    public var command: String

    public init(accountID: String, command: String) {
        self.accountID = accountID
        self.command = command
    }

    /// How the scope is saved: opaque, so `model-catalogs.json` holds no command.
    public var key: String { ConnectorScope.profile(accountID: accountID, command: command) }
}

/// The models a profile's CLI listed, read whole, and when that was. A listing is not proof that a
/// model runs on the account; the CLI still says so when a turn starts.
public struct NativeCatalog: Equatable, Sendable {
    public var models: [ModelOption]
    public var checkedAt: Date

    public init(models: [ModelOption], checkedAt: Date) {
        self.models = models
        self.checkedAt = checkedAt
    }
}

public struct CodexModelFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }

    static let unrecognized = CodexModelFailure("Codex listed its models in a form BotChu doesn’t recognize.")
    static let unsupported = CodexModelFailure("This version of Codex can’t list its models.")
    static let failed = CodexModelFailure("Codex couldn’t list its models. Check its sign-in and command.")
}

/// Codex app-server's `model/list`, through the profile's own command: a bounded, read-only query
/// that starts no model turn and reads no login. Codex keeps its own catalog and cache.
public enum CodexModelList {
    public static let timeout: TimeInterval = 20
    /// `model/list` pages read at most; a listing with more is incomplete and not used.
    static let pageLimit = 20

    /// Every visible row of `pages`, in Codex's order: the model it runs as, its display name and the
    /// efforts it lists (the family's when a row lists none at all).
    public static func parse(_ pages: [[String: Any]]) throws -> [ModelOption] {
        var models: [ModelOption] = []
        var seen = Set<String>()
        for page in pages {
            guard let rows = page["data"] as? [[String: Any]] else { throw CodexModelFailure.unrecognized }
            for row in rows where row["hidden"] as? Bool != true {
                guard let id = [row["model"], row["id"]].lazy.compactMap({ ($0 as? String)?.trimmingCharacters(in: .whitespaces) })
                    .first(where: { !$0.isEmpty }), seen.insert(id).inserted else { continue }
                let name = (row["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                let efforts: [ReasoningEffort]
                if let listed = row["supportedReasoningEfforts"] as? [[String: Any]] {
                    var unique: [ReasoningEffort] = []
                    for effort in listed.compactMap({ ($0["reasoningEffort"] as? String).flatMap(ReasoningEffort.init) })
                    where !unique.contains(effort) { unique.append(effort) }
                    efforts = unique
                } else {
                    efforts = GenerationOptions.efforts(for: .codex, model: id)
                }
                // `priority` is the Fast tier's ID; older Codex lists it as an extra speed tier, `fast`.
                let tiers = (row["serviceTiers"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                    + (row["additionalSpeedTiers"] as? [String] ?? [])
                models.append(ModelOption(id: id, name: name, efforts: efforts, fast: tiers.contains("priority") || tiers.contains("fast")))
            }
        }
        guard !models.isEmpty else { throw CodexModelFailure.unrecognized }
        return models
    }

    /// The profile's models, run from `folder` (the home folder).
    public static func list(command: String, folder: String = NSHomeDirectory(), timeout: TimeInterval = timeout) async throws -> [ModelOption] {
        try await Task.detached(priority: .utility) { try read(command: command, folder: folder, timeout: timeout) }.value
    }

    private static func read(command: String, folder: String, timeout: TimeInterval) throws -> [ModelOption] {
        let started = Date()
        let process: UsageProcess
        do {
            process = try UsageProcess(command: command, arguments: ["app-server"], directory: URL(fileURLWithPath: folder, isDirectory: true),
                                       timeout: timeout, frameLimit: 8 << 20)
        } catch {
            throw CodexModelFailure("Could not start Codex. Check the profile’s command in Settings.")
        }
        defer { process.stop() }
        do {
            _ = try process.call("initialize", ["clientInfo": ["name": "botchu", "title": "BotChu", "version": "1"],
                                                "capabilities": ["experimentalApi": true]])
            try process.send(["jsonrpc": "2.0", "method": "initialized"])
            var pages: [[String: Any]] = []
            var cursor: String?
            repeat {
                let page = try call(process, "model/list", cursor.map { ["cursor": $0] } ?? [:])
                pages.append(page)
                cursor = (page["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            } while cursor != nil && pages.count < pageLimit
            if cursor != nil { throw CodexModelFailure("Codex listed more models than BotChu reads.") }
            return try parse(pages)
        } catch let failure as CodexModelFailure {
            throw failure
        } catch {
            throw Date().timeIntervalSince(started) >= timeout - 1
                ? CodexModelFailure("Codex didn’t list its models within \(Int(timeout)) seconds.") : CodexModelFailure.failed
        }
    }

    /// One JSON-RPC call, telling a Codex too old for the method from any other error.
    private static func call(_ process: UsageProcess, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = Int.random(in: 1_000...Int(Int32.max))
        try process.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            guard let frame = try process.next(), frame["id"] as? Int == id else { continue }
            if let error = frame["error"] as? [String: Any] {
                throw error["code"] as? Int == -32601 || (error["message"] as? String)?.contains("unknown variant") == true
                    ? CodexModelFailure.unsupported : CodexModelFailure.failed
            }
            guard let result = frame["result"] as? [String: Any] else { throw CodexModelFailure.unrecognized }
            return result
        }
    }
}

/// How a profile's list stands, as its picker shows it.
public struct NativeCatalogStatus: Equatable, Sendable {
    /// When the list shown was read; nil while the starter choices stand in.
    public var checkedAt: Date?
    public var checking: Bool
    /// Why the last check failed, until one succeeds; the last list read stays meanwhile.
    public var failure: String?

    public init(checkedAt: Date? = nil, checking: Bool = false, failure: String? = nil) {
        self.checkedAt = checkedAt
        self.checking = checking
        self.failure = failure
    }

    /// The picker's footer line: "Checking models…", "Checked 3h ago", "Couldn’t check · from 2d ago".
    public func summary(at now: Date) -> String {
        if checking { return "Checking models…" }
        let age = checkedAt.map { Self.ago(now.timeIntervalSince($0)) }
        if failure != nil { return age.map { "Couldn’t check · list from \($0)" } ?? "Couldn’t check · starter list" }
        return age.map { "Checked \($0)" } ?? "Starter list · not checked yet"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "just now" }
        if total < 3_600 { return "\(total / 60)m ago" }
        if total < 86_400 { return "\(total / 3_600)h ago" }
        return "\(total / 86_400)d ago"
    }
}

/// Each local profile's last whole list, and how its checks are going (#220). A list older than
/// `staleAfter` is checked again; a failed check keeps the list and waits longer after each failure
/// in a row, up to an hour. One check of a profile runs at a time, and only its own answer counts.
public struct NativeCatalogBook: Sendable {
    public static let staleAfter: TimeInterval = 86_400

    struct Entry: Sendable {
        var catalog: NativeCatalog?
        var failure: String?
        var failedAt: Date?
        var failures = 0
        var running: UUID?
    }

    private var entries: [String: Entry]

    /// `saved`: the lists read before, by `ModelCatalogScope.key`.
    public init(saved: [String: NativeCatalog] = [:]) {
        entries = saved.mapValues { Entry(catalog: $0) }
    }

    /// The scope's models; nil when none were ever read, so the starters stand in.
    public func models(for scope: ModelCatalogScope) -> [ModelOption]? { entries[scope.key]?.catalog?.models }

    public func status(for scope: ModelCatalogScope) -> NativeCatalogStatus {
        let entry = entries[scope.key]
        return NativeCatalogStatus(checkedAt: entry?.catalog?.checkedAt, checking: entry?.running != nil, failure: entry?.failure)
    }

    /// How long a check waits after `failures` failed in a row: a minute, doubling, at most an hour.
    public static func retryDelay(after failures: Int) -> TimeInterval {
        failures <= 0 ? 0 : min(3_600, 60 * pow(2, Double(min(failures, 7) - 1)))
    }

    /// Whether the scope should be checked now: never read or stale, and not waiting after a failure.
    public func isDue(_ scope: ModelCatalogScope, now: Date = Date()) -> Bool {
        let entry = entries[scope.key] ?? Entry()
        guard entry.running == nil else { return false }
        if let failedAt = entry.failedAt, now.timeIntervalSince(failedAt) < Self.retryDelay(after: entry.failures) { return false }
        return entry.catalog.map { now.timeIntervalSince($0.checkedAt) >= Self.staleAfter } ?? true
    }

    /// Starts a check when one is due (`force`: Refresh models, whenever none is running); its token,
    /// or nil when nothing should start.
    public mutating func begin(_ scope: ModelCatalogScope, now: Date = Date(), force: Bool = false) -> UUID? {
        guard entries[scope.key]?.running == nil, force || isDue(scope, now: now) else { return nil }
        let token = UUID()
        entries[scope.key, default: Entry()].running = token
        return token
    }

    /// Records the check `token` started; returns whether the saved lists changed. The answer of a
    /// check no longer running for the scope (its profile went, or its command changed) is dropped.
    @discardableResult
    public mutating func finish(_ scope: ModelCatalogScope, token: UUID, _ result: Result<[ModelOption], CodexModelFailure>,
                                now: Date = Date()) -> Bool {
        guard var entry = entries[scope.key], entry.running == token else { return false }
        entry.running = nil
        defer { entries[scope.key] = entry }
        switch result {
        case .success(let models):
            entry.catalog = NativeCatalog(models: models, checkedAt: now)
            entry.failure = nil
            entry.failedAt = nil
            entry.failures = 0
            return true
        case .failure(let failure):
            entry.failure = failure.message
            entry.failedAt = now
            entry.failures += 1
            return false
        }
    }

    /// Keeps the scopes in `keys` only (the profiles in Settings, each by its command now); returns
    /// whether a saved list went.
    @discardableResult
    public mutating func retain(_ keys: Set<String>) -> Bool {
        let before = saved.count
        entries = entries.filter { keys.contains($0.key) }
        return saved.count != before
    }

    /// The lists to save, by key.
    public var saved: [String: NativeCatalog] { entries.compactMapValues(\.catalog) }
}

/// `model-catalogs.json`: each scope's list by its opaque key, with the time it was read.
public enum NativeCatalogFile {
    static let version = 1

    private struct File: Codable {
        var version: Int
        var catalogs: [Catalog]
    }
    private struct Catalog: Codable {
        var key: String
        var checkedAt: Date
        var models: [Model]
    }
    private struct Model: Codable {
        var id: String
        var name: String
        /// As the CLI names them, so an effort this BotChu doesn't know is skipped, not fatal.
        var efforts: [String]
        /// Whether it has the Fast tier; nil in lists saved before #249, which offer it until read again.
        var fast: Bool?
    }

    public static func encode(_ catalogs: [String: NativeCatalog]) -> Data? {
        let file = File(version: version, catalogs: catalogs.sorted { $0.key < $1.key }.map { key, catalog in
            Catalog(key: key, checkedAt: catalog.checkedAt,
                    models: catalog.models.map { Model(id: $0.id, name: $0.name, efforts: $0.efforts.map(\.rawValue), fast: $0.fast) })
        })
        return try? JSONEncoder().encode(file)
    }

    /// The lists saved by this version of the file; nothing from another version or a damaged file.
    public static func decode(_ data: Data) -> [String: NativeCatalog] {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.version == version else { return [:] }
        return Dictionary(file.catalogs.compactMap { catalog -> (String, NativeCatalog)? in
            let models = catalog.models.filter { !$0.id.isEmpty }.map {
                ModelOption(id: $0.id, name: $0.name, efforts: $0.efforts.compactMap(ReasoningEffort.init), fast: $0.fast ?? true)
            }
            return models.isEmpty ? nil : (catalog.key, NativeCatalog(models: models, checkedAt: catalog.checkedAt))
        }) { $1 }
    }
}
