import Foundation

/// A connector a CLI profile already has (an MCP server, a claude.ai connector, a Codex app), as
/// its provider reported it (#183). BotChu shows them; it never installs, signs in or configures
/// them, and keeps only names, states and tool counts: no endpoints, commands or credentials.
public struct Connector: Hashable, Sendable {
    /// What the provider's evidence says about it. A connection is what was true when it was
    /// reported or checked, never a promise that every tool is callable now.
    public enum State: Int, Hashable, Sendable, CaseIterable {
        /// Connected when reported (Claude Code), or enabled with a callable tool when checked (Codex).
        case connected
        case needsAuth
        case failed
        /// Turned off in its configuration.
        case off
        /// Configured but not confirmed: pending, not started, cancelled, or enabled with no callable tool.
        case unconfirmed

        /// A status row's word; connected names show as tokens instead.
        public var label: String {
            switch self {
            case .connected: "Connected"
            case .needsAuth: "Needs sign-in"
            case .failed: "Failed"
            case .off: "Off"
            case .unconfirmed: "Not confirmed"
            }
        }
    }

    public enum Origin: Hashable, Sendable {
        case claudeAI, plugin, mcpServer, codexApp

        public var label: String {
            switch self {
            case .claudeAI: "claude.ai connector"
            case .plugin: "Plugin"
            case .mcpServer: "MCP server"
            case .codexApp: "Codex app"
            }
        }
    }

    public var name: String
    public var state: State
    public var origin: Origin
    /// How many tools the report listed for it, where it says; never proof of completeness.
    public var toolCount: Int?

    public init(name: String, state: State, origin: Origin, toolCount: Int? = nil) {
        self.name = name
        self.state = state
        self.origin = origin
        self.toolCount = toolCount
    }

    /// What its tooltip says: where it comes from and how many tools were listed.
    public var detail: String {
        guard let toolCount else { return origin.label }
        return "\(origin.label) · \(toolCount) \(toolCount == 1 ? "tool" : "tools") listed"
    }
}

/// Where a list of connectors applies: the conversation's profile, the command it runs (a host's
/// own included), its folder and its host. Evidence from one scope never shows for another.
public struct ConnectorScope: Hashable, Sendable {
    public var accountID: String
    public var command: String
    public var folder: String
    /// The SSH host it runs on; nil on this Mac.
    public var hostID: UUID?

    public init(accountID: String, command: String, folder: String, hostID: UUID? = nil) {
        self.accountID = accountID
        self.command = command
        self.folder = folder
        self.hostID = hostID
    }
}

/// The connectors a provider reported, at one moment.
public struct ConnectorReport: Equatable, Sendable {
    public var connectors: [Connector]
    public var at: Date

    public init(connectors: [Connector], at: Date = Date()) {
        self.connectors = connectors
        self.at = at
    }

    /// Connected names, sorted so they don't reshuffle between reports.
    public var connected: [Connector] { sorted(connectors.filter { $0.state == .connected }) }

    /// The other states, in the order the card lists them, each with its names; empty ones left out.
    public var rows: [(state: Connector.State, connectors: [Connector])] {
        Connector.State.allCases.dropFirst().compactMap { state in
            let matching = connectors.filter { $0.state == state }
            return matching.isEmpty ? nil : (state, sorted(matching))
        }
    }

    private func sorted(_ list: [Connector]) -> [Connector] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The connectors one Claude Code session reported at its latest turn's start, with the scope
/// the turn ran in.
public struct SessionConnectorReport: Equatable, Sendable {
    public var scope: ConnectorScope
    public var sessionID: String?
    public var report: ConnectorReport

    public init(scope: ConnectorScope, sessionID: String?, report: ConnectorReport) {
        self.scope = scope
        self.sessionID = sessionID
        self.report = report
    }
}

/// A profile check's result: the last list it read (kept, as stale, when a later check fails),
/// the last error, and when it last tried.
public struct ConnectorCheck: Equatable, Sendable {
    public var report: ConnectorReport?
    public var error: String?
    public var triedAt: Date

    public init(report: ConnectorReport? = nil, error: String? = nil, triedAt: Date = Date()) {
        self.report = report
        self.error = error
        self.triedAt = triedAt
    }

    /// How old a check may be before showing the section checks again.
    public static let freshFor: TimeInterval = 3_600
    /// How soon after a check Refresh may check again.
    public static let retryAfter: TimeInterval = 60

    public var isStale: Bool { error != nil }

    public func isDue(at now: Date) -> Bool {
        guard let report else { return now.timeIntervalSince(triedAt) >= Self.retryAfter }
        return now.timeIntervalSince(report.at) >= Self.freshFor && now.timeIntervalSince(triedAt) >= Self.retryAfter
    }

    public func canRetry(at now: Date) -> Bool { now.timeIntervalSince(triedAt) >= Self.retryAfter }

    /// The check that followed this one: its list, or this list kept with the new error.
    public func next(_ result: Result<ConnectorReport, ConnectorFailure>, at now: Date = Date()) -> ConnectorCheck {
        switch result {
        case .success(let report): ConnectorCheck(report: report, triedAt: now)
        case .failure(let failure): ConnectorCheck(report: report, error: failure.message, triedAt: now)
        }
    }
}

/// What BotChu knows of connectors, by conversation and by scope: each conversation's latest
/// session report, each scope's last check, and the checks running. A check answers for its own
/// scope alone, so one that ends after the inspector moved to another conversation never shows
/// there, and a failed one keeps the list before it, as stale.
public struct ConnectorEvidence<Target: Hashable & Sendable>: Sendable {
    public private(set) var sessions: [Target: SessionConnectorReport] = [:]
    public private(set) var checks: [ConnectorScope: ConnectorCheck] = [:]
    public private(set) var checking: Set<ConnectorScope> = []

    public init() {}

    /// What a turn's CLI reported as it started, in the scope the turn ran in.
    public mutating func record(_ connectors: [Connector], scope: ConnectorScope, sessionID: String?, for target: Target, at date: Date = Date()) {
        sessions[target] = SessionConnectorReport(scope: scope, sessionID: sessionID, report: ConnectorReport(connectors: connectors, at: date))
    }

    /// Starts a check of `scope` when one is due (`force`: Refresh, within its limit) and none is running.
    public mutating func begin(_ scope: ConnectorScope, force: Bool = false, now: Date = Date()) -> Bool {
        guard !checking.contains(scope) else { return false }
        if let last = checks[scope], !(force ? last.canRetry(at: now) : last.isDue(at: now)) { return false }
        checking.insert(scope)
        return true
    }

    public mutating func finish(_ scope: ConnectorScope, _ result: Result<ConnectorReport, ConnectorFailure>, at now: Date = Date()) {
        checking.remove(scope)
        checks[scope] = (checks[scope] ?? ConnectorCheck(triedAt: .distantPast)).next(result, at: now)
    }
}

public struct ConnectorFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// What a conversation's Connectors card shows, from the evidence BotChu has for its scope.
public enum ConnectorCard: Equatable, Sendable {
    /// BotChu has no discovery for this CLI family; says nothing about the CLI itself.
    case unavailable(AgentKind)
    /// A profile check that only runs on this Mac, for a Codex conversation on a host.
    case notChecked(host: String)
    /// No report from a turn in this scope yet.
    case notReported
    /// Claude Code's report from a turn in this scope on a host: this session's (`current`) or an earlier one's.
    case session(ConnectorReport, current: Bool)
    /// A check of this profile in this folder on this Mac, separate from any session; nil before the first.
    case profile(ConnectorCheck?)

    public var title: String {
        switch self {
        case .unavailable(let kind): "Discovery unavailable for \(kind.displayName)"
        case .notChecked(let host): "Not checked on \(host)"
        case .notReported: "Not reported yet"
        case .session(_, let current): current ? "Connected at last report" : "Last session report"
        case .profile: "Enabled for this profile"
        }
    }

    /// Picks the card for a conversation of `kind` in `scope`, on `host` (nil on this Mac),
    /// running in session `sessionID`. On this Mac, Claude Code and Codex profiles are checked
    /// (Claude Code's init lists most connectors as still pending, and can leave claude.ai ones
    /// out). On a host, Claude Code's session report is all there is: one from another scope, or
    /// none, is "Not reported yet", and one from an earlier session in this scope says so.
    public static func make(kind: AgentKind, scope: ConnectorScope, host: String?, sessionID: String?,
                            session: SessionConnectorReport?, check: ConnectorCheck?) -> ConnectorCard {
        switch kind {
        case .claude:
            guard host != nil else { return .profile(check) }
            guard let session, session.scope == scope else { return .notReported }
            return .session(session.report, current: session.sessionID != nil && session.sessionID == sessionID)
        case .codex:
            if let host { return .notChecked(host: host) }
            return .profile(check)
        case .antigravity, .muse, .pi:
            return .unavailable(kind)
        }
    }
}

public enum ConnectorParser {
    /// Claude Code's `system/init` `mcp_servers`, which include claude.ai connectors and plugins'
    /// servers, with the `mcp__…` tools of `tools`. Nil when the init has no such list (an older
    /// Claude Code), which is unknown, not none.
    public static func claudeInit(_ object: [String: Any]) -> [Connector]? {
        guard let servers = object["mcp_servers"] as? [[String: Any]] else { return nil }
        let tools = (object["tools"] as? [String] ?? []).filter { $0.hasPrefix("mcp__") }
        return servers.compactMap { server in
            guard let name = server["name"] as? String, !name.isEmpty else { return nil }
            let state: Connector.State = switch server["status"] as? String {
            case "connected": .connected
            case "needs-auth": .needsAuth
            case "failed": .failed
            case "disabled": .off
            default: .unconfirmed
            }
            let origin: Connector.Origin = switch server["source"] as? String {
            case "claudeai": .claudeAI
            case "plugin": .plugin
            default: name.hasPrefix("claude.ai ") ? .claudeAI : name.hasPrefix("plugin:") ? .plugin : .mcpServer
            }
            let prefix = "mcp__\(toolPrefix(name))__"
            let count = tools.filter { $0.hasPrefix(prefix) }.count
            return Connector(name: displayName(name), state: state, origin: origin,
                             toolCount: state == .connected ? count : nil)
        }
    }

    /// `claude mcp list`, which health-checks each server it may connect to (claude.ai connectors
    /// and plugins' servers among them) without starting a model turn: `<name>: <command or URL>
    /// - <status>`. Only the name and the status are kept, never the target or the error after it.
    public static func claudeList(_ output: String) throws -> [Connector] {
        let markers: [(String, Connector.State)] = [
            ("✔ Connected", .connected), ("! Connected", .unconfirmed), ("! Needs authentication", .needsAuth),
            ("⏸ Pending approval", .unconfirmed), ("- Not configured", .unconfirmed), ("⊘ Disabled", .off),
            ("✘ Rejected", .off), ("✘ ", .failed), ("! ", .unconfirmed),
        ]
        var connectors: [Connector] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let colon = line.range(of: ": ") else { continue }
            let name = String(line[..<colon.lowerBound])
            let rest = line[colon.upperBound...]
            // The earliest status after the target; an error's text follows the status.
            let found = markers.compactMap { marker, state in rest.range(of: " - " + marker).map { ($0.lowerBound, state) } }
                .min { $0.0 < $1.0 }
            guard let state = found?.1, !name.isEmpty else { continue }
            let origin: Connector.Origin = name.hasPrefix("claude.ai ") ? .claudeAI : name.hasPrefix("plugin:") ? .plugin : .mcpServer
            connectors.append(Connector(name: displayName(name), state: state, origin: origin))
        }
        if connectors.isEmpty, !output.contains("No MCP servers configured") { throw ConnectorFailure.claudeUnrecognized }
        return connectors
    }

    /// Codex app-server's `app/installed` apps and `mcpServerStatus/list` pages. `codex_apps` is
    /// the server Codex reaches its apps through, so its apps stand for it.
    public static func codex(installed: [String: Any], servers pages: [[String: Any]]) throws -> [Connector] {
        guard let apps = installed["apps"] as? [[String: Any]] else { throw ConnectorFailure.unrecognized }
        var connectors = apps.compactMap { app -> Connector? in
            guard let id = app["id"] as? String else { return nil }
            let enabled = app["enabled"] as? Bool ?? false
            let callable = app["callable"] as? Bool ?? false
            let name = (app["runtimeName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return Connector(name: name, state: !enabled ? .off : callable ? .connected : .unconfirmed, origin: .codexApp)
        }
        for page in pages {
            guard let data = page["data"] as? [[String: Any]] else { throw ConnectorFailure.unrecognized }
            for server in data {
                guard let name = server["name"] as? String, !name.isEmpty, name != "codex_apps" else { continue }
                let tools = (server["tools"] as? [String: Any])?.count ?? 0
                let toolsFailed = (server["toolsError"] as? String).map { !$0.isEmpty } ?? false
                let state: Connector.State
                switch server["runtimeStatus"] as? String {
                case "connected": state = .connected
                case "authenticationRequired": state = .needsAuth
                case "failed": state = .failed
                case "disabled": state = .off
                case "notStarted", "starting", "cancelled": state = .unconfirmed
                default:
                    // No runtime state outside a thread: its tool listing and sign-in say how the check went.
                    if server["authStatus"] as? String == "notLoggedIn" { state = .needsAuth }
                    else if toolsFailed { state = .failed }
                    else { state = tools > 0 ? .connected : .unconfirmed }
                }
                connectors.append(Connector(name: name, state: state, origin: server["pluginId"] is String ? .plugin : .mcpServer,
                                            toolCount: toolsFailed ? nil : tools))
            }
        }
        return connectors
    }

    /// As reported, without the `claude.ai ` and `plugin:<plugin>:` prefixes (the origin says those).
    static func displayName(_ name: String) -> String {
        if name.hasPrefix("claude.ai ") { return String(name.dropFirst("claude.ai ".count)) }
        if name.hasPrefix("plugin:"), let last = name.split(separator: ":", omittingEmptySubsequences: false).last, !last.isEmpty {
            return String(last)
        }
        return name
    }

    /// How Claude Code names a server in its tools' names: anything but letters, digits, `_` and `-` becomes `_`.
    static func toolPrefix(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")) ? Character(scalar) : "_"
        })
    }
}

extension ConnectorFailure {
    static let unrecognized = ConnectorFailure("Codex answered in a form BotChu doesn’t recognize.")
    static let claudeUnrecognized = ConnectorFailure("Claude Code listed its connectors in a form BotChu doesn’t recognize.")
    /// A Codex without `app/installed` or `mcpServerStatus/list` (before 0.164).
    static let unsupported = ConnectorFailure("This version of Codex can’t list its connectors.")
}

/// Asks a profile which connectors it has, on demand, in the conversation's folder on this Mac:
/// bounded, read-only native queries that start no model turn and call no connector's tool.
/// Nothing they read is written anywhere.
public enum ConnectorClient {
    public static let timeout: TimeInterval = 20
    /// `mcpServerStatus/list` pages read at most.
    static let pageLimit = 20

    /// The check for `kind`; nil for a CLI family BotChu has no discovery for.
    public static func check(_ kind: AgentKind, command: String, folder: String, timeout: TimeInterval = timeout) async throws -> ConnectorReport {
        switch kind {
        case .claude: try await claude(command: command, folder: folder, timeout: timeout)
        case .codex: try await codex(command: command, folder: folder, timeout: timeout)
        case .antigravity, .muse, .pi: throw ConnectorFailure("BotChu can’t ask \(kind.displayName) which connectors it has.")
        }
    }

    /// `claude mcp list`.
    public static func claude(command: String, folder: String, timeout: TimeInterval = timeout) async throws -> ConnectorReport {
        try await Task.detached(priority: .utility) {
            let process = try start(command: command, arguments: ["mcp", "list"], folder: folder, timeout: timeout, cli: "Claude Code")
            defer { process.stop() }
            let started = Date()
            let output: Data
            do { output = try process.output() } catch {
                throw Date().timeIntervalSince(started) >= timeout - 1
                    ? ConnectorFailure("Claude Code didn’t answer within \(Int(timeout)) seconds.")
                    : ConnectorFailure("Claude Code couldn’t list its connectors. Check its sign-in and command.")
            }
            return ConnectorReport(connectors: try ConnectorParser.claudeList(String(decoding: output, as: UTF8.self)))
        }.value
    }

    private static func start(command: String, arguments: [String], folder: String, timeout: TimeInterval,
                              cli: String, frameLimit: Int = 2 << 20) throws -> UsageProcess {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw ConnectorFailure("The conversation’s folder isn’t there to check in.")
        }
        do {
            return try UsageProcess(command: command, arguments: arguments, directory: URL(fileURLWithPath: folder, isDirectory: true),
                                    timeout: timeout, frameLimit: frameLimit)
        } catch {
            throw ConnectorFailure("Could not start \(cli). Check the profile’s command in Settings.")
        }
    }

    public static func codex(command: String, folder: String, timeout: TimeInterval = timeout) async throws -> ConnectorReport {
        try await Task.detached(priority: .utility) { try checkCodex(command: command, folder: folder, timeout: timeout) }.value
    }

    private static func checkCodex(command: String, folder: String, timeout: TimeInterval) throws -> ConnectorReport {
        let started = Date()
        let process = try start(command: command, arguments: ["app-server"], folder: folder, timeout: timeout, cli: "Codex", frameLimit: 32 << 20)
        defer { process.stop() }
        do {
            _ = try process.call("initialize", ["clientInfo": ["name": "botchu", "title": "BotChu", "version": "1"],
                                                "capabilities": ["experimentalApi": true]])
            try process.send(["jsonrpc": "2.0", "method": "initialized"])
            var pages: [[String: Any]] = []
            var cursor: String?
            repeat {
                var params: [String: Any] = ["detail": "toolsAndAuthOnly"]
                if let cursor { params["cursor"] = cursor }
                let page = try call(process, "mcpServerStatus/list", params)
                pages.append(page)
                cursor = (page["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            } while cursor != nil && pages.count < pageLimit
            if cursor != nil { throw ConnectorFailure("Codex listed more MCP servers than BotChu reads.") }
            // Refreshed first: the snapshot a new app-server starts with can be behind.
            let installed = try call(process, "app/installed", ["forceRefresh": true])
            return ConnectorReport(connectors: try ConnectorParser.codex(installed: installed, servers: pages))
        } catch let failure as ConnectorFailure {
            throw failure
        } catch {
            throw Date().timeIntervalSince(started) >= timeout - 1
                ? ConnectorFailure("Codex didn’t answer within \(Int(timeout)) seconds.")
                : ConnectorFailure("Codex couldn’t list its connectors. Check its sign-in and command.")
        }
    }

    /// One JSON-RPC call, telling a Codex too old for a method from any other error.
    private static func call(_ process: UsageProcess, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = Int.random(in: 1_000...Int(Int32.max))
        try process.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            guard let frame = try process.next(), frame["id"] as? Int == id else { continue }
            if let error = frame["error"] as? [String: Any] {
                throw error["code"] as? Int == -32601 || (error["message"] as? String)?.contains("unknown variant") == true
                    ? ConnectorFailure.unsupported : ConnectorFailure("Codex couldn’t list its connectors. Check its sign-in and command.")
            }
            guard let result = frame["result"] as? [String: Any] else { throw ConnectorFailure.unrecognized }
            return result
        }
    }
}
