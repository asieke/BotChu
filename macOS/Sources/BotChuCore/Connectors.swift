import Foundation

/// A connector a CLI profile already has (an MCP server, a claude.ai connector, a Codex app), as
/// its provider reported it (#183). BotChu shows them and hands their management to the provider
/// (#212); it never installs, signs in or configures them itself, and keeps only identifiers,
/// names, states and tool counts: no endpoints, commands or credentials.
public struct Connector: Hashable, Sendable, Codable {
    /// What the provider's evidence says about it. A connection is what was true when it was
    /// reported or checked, never a promise that every tool is callable now.
    public enum State: String, Hashable, Sendable, CaseIterable, Codable {
        /// Connected when reported (Claude Code), or enabled with a callable tool when checked (Codex).
        case connected
        case needsAuth
        case failed
        /// Waiting for the owner to approve it in the CLI (a project's `.mcp.json` server).
        case pending
        /// Turned off in its configuration.
        case off
        /// Not confirmed: not started, starting, cancelled, or enabled with no callable tool.
        case unconfirmed
        /// Configured, with nothing reported about it outside a turn: neither working nor broken.
        case configured

        /// A status row's word; connected names show as tokens instead.
        public var label: String {
            switch self {
            case .connected: "Connected"
            case .needsAuth: "Needs sign-in"
            case .failed: "Failed"
            case .pending: "Pending approval"
            case .off: "Off"
            case .unconfirmed: "Not confirmed"
            case .configured: "Configured · not checked"
            }
        }

        /// Needs the owner: shown first, with its action.
        public var needsAttention: Bool { self == .needsAuth || self == .failed || self == .pending }
    }

    public enum Origin: String, Hashable, Sendable, Codable {
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

    /// Services the owner connected, tools that act on this Mac, and the provider's own plumbing.
    public enum Category: String, Hashable, Sendable, CaseIterable {
        case connection, tool, system

        public var title: String {
            switch self {
            case .connection: "Connections"
            case .tool: "Tools"
            case .system: "System"
            }
        }
    }

    /// The provider's own identifier: the server's name as configured (`claude.ai Slack`,
    /// `plugin:github:github`) or the app's id. What native management is asked about, never shown.
    public var id: String
    public var name: String
    public var state: State
    public var origin: Origin
    /// How many tools the report listed for it, where it says; never proof of completeness.
    public var toolCount: Int?

    public init(name: String, state: State, origin: Origin, toolCount: Int? = nil, id: String? = nil) {
        self.id = id ?? name
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

    /// Known internal entries by exact normalized name or id; anything else stays in view.
    public var category: Category {
        let names = [Self.normalized(id), Self.normalized(name)]
        if names.contains(where: Self.toolNames.contains) { return .tool }
        switch origin {
        case .codexApp: return id.hasPrefix("connector_openai_") ? .system : .connection
        case .mcpServer, .plugin: return names.contains(where: Self.systemNames.contains) ? .system : .connection
        case .claudeAI: return .connection
        }
    }

    /// Servers by these names are Codex's own: link, node_repl, Hotline, Pets, and the bridge to its
    /// apps; its own apps are told by their ids (`connector_openai_…`).
    static let systemNames: Set<String> = ["hotline", "link", "noderepl", "pets", "codexapps"]
    static let toolNames: Set<String> = ["computeruse"]

    /// Lowercased letters and digits only, so `node_repl`, `node-repl` and `Node REPL` are one name.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
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

    public var isLocal: Bool { hostID == nil }

    /// How the scope is saved: opaque, so `connectors.json` holds no command or path.
    public var key: ConnectorKey {
        ConnectorKey(scope: Self.hash([accountID, command, folder, hostID?.uuidString ?? "local"]),
                     profile: Self.profile(accountID: accountID, command: command), local: isLocal)
    }

    /// A profile as its command runs it, whose sign-ins every folder on this Mac shares.
    public static func profile(accountID: String, command: String) -> String { hash([accountID, command]) }

    /// FNV-1a, 64 bits: stable across launches, unlike `Hasher`.
    static func hash(_ fields: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in fields.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// A scope as it is saved: its own key, its profile's, and whether it is on this Mac.
public struct ConnectorKey: Hashable, Sendable, Codable {
    public var scope: String
    public var profile: String
    public var local: Bool
}

/// The connectors a provider reported, at one moment.
public struct ConnectorReport: Equatable, Sendable, Codable {
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

    /// One category's connectors: those needing the owner first, then connected, then the rest,
    /// each by name.
    public func listed(_ category: Connector.Category) -> [Connector] {
        let order = Dictionary(uniqueKeysWithValues: Connector.State.allCases.enumerated().map { ($1, $0) })
        let rank = { (connector: Connector) in
            (connector.state.needsAttention ? 0 : connector.state == .connected ? 10 : 20) + (order[connector.state] ?? 0)
        }
        return connectors.filter { $0.category == category }.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let names = a.name.localizedCaseInsensitiveCompare(b.name)
            return names == .orderedSame ? a.id < b.id : names == .orderedAscending
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
public struct ConnectorCheck: Equatable, Sendable, Codable {
    public var report: ConnectorReport?
    /// BotChu's own sentence about the last failure, never the CLI's text.
    public var error: String?
    public var triedAt: Date
    /// Its provider's settings were opened since: the list may be out of date, and it is checked again.
    public var invalidated: Bool

    public init(report: ConnectorReport? = nil, error: String? = nil, triedAt: Date = Date(), invalidated: Bool = false) {
        self.report = report
        self.error = error
        self.triedAt = triedAt
        self.invalidated = invalidated
    }

    /// How old a check may be before showing the section checks again.
    public static let freshFor: TimeInterval = 3_600
    /// How soon after a check Refresh may check again.
    public static let retryAfter: TimeInterval = 60
    /// How long a check is kept, unchecked, between launches.
    public static let keptFor: TimeInterval = 7 * 86_400

    /// The list shown may no longer be so: the last check failed, it is over an hour old, or its
    /// provider's settings were opened since.
    public func isStale(at now: Date) -> Bool {
        guard let report else { return false }
        return error != nil || invalidated || now.timeIntervalSince(report.at) >= Self.freshFor
    }

    public func isDue(at now: Date) -> Bool {
        if invalidated { return true }
        guard let report else { return now.timeIntervalSince(triedAt) >= Self.retryAfter }
        return now.timeIntervalSince(report.at) >= Self.freshFor && now.timeIntervalSince(triedAt) >= Self.retryAfter
    }

    public func canRetry(at now: Date) -> Bool { invalidated || now.timeIntervalSince(triedAt) >= Self.retryAfter }

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
/// there, and a failed one keeps the list before it, as stale. Checks are kept by opaque key
/// (`ConnectorKey`), so they can be saved and read back after a relaunch; session reports aren't.
public struct ConnectorEvidence<Target: Hashable & Sendable>: Sendable {
    public private(set) var sessions: [Target: SessionConnectorReport] = [:]
    public private(set) var checks: [ConnectorKey: ConnectorCheck]
    /// The checks running, each with its token: an answer whose token isn't there any more was
    /// overtaken (its scope was invalidated or forgotten) and changes nothing.
    public private(set) var checking: [ConnectorKey: Int] = [:]
    private var tokens = 0

    public init(checks: [ConnectorKey: ConnectorCheck] = [:]) {
        self.checks = checks
    }

    public func check(for scope: ConnectorScope) -> ConnectorCheck? { checks[scope.key] }
    public func isChecking(_ scope: ConnectorScope) -> Bool { checking[scope.key] != nil }

    /// What a turn's CLI reported as it started, in the scope the turn ran in.
    public mutating func record(_ connectors: [Connector], scope: ConnectorScope, sessionID: String?, for target: Target, at date: Date = Date()) {
        sessions[target] = SessionConnectorReport(scope: scope, sessionID: sessionID, report: ConnectorReport(connectors: connectors, at: date))
    }

    /// The latest session report in exactly this scope, whichever conversation's.
    public func session(in scope: ConnectorScope) -> SessionConnectorReport? {
        sessions.values.filter { $0.scope == scope }.max { $0.report.at < $1.report.at }
    }

    /// Starts a check of `scope` when one is due (`force`: Refresh, within its limit) and none is
    /// running; its token, which `finish` needs, or nil when it shouldn't start.
    public mutating func begin(_ scope: ConnectorScope, force: Bool = false, now: Date = Date()) -> Int? {
        let key = scope.key
        guard checking[key] == nil else { return nil }
        if let last = checks[key], !(force ? last.canRetry(at: now) : last.isDue(at: now)) { return nil }
        tokens += 1
        checking[key] = tokens
        return tokens
    }

    /// Records a check's answer, unless it was overtaken; whether it was recorded.
    @discardableResult
    public mutating func finish(_ scope: ConnectorScope, token: Int, _ result: Result<ConnectorReport, ConnectorFailure>, at now: Date = Date()) -> Bool {
        let key = scope.key
        guard checking[key] == token else { return false }
        checking[key] = nil
        checks[key] = (checks[key] ?? ConnectorCheck(triedAt: .distantPast)).next(result, at: now)
        return true
    }

    /// After its provider's settings or CLI were opened for `scope`: every folder of that profile on
    /// this Mac shares its sign-ins, so each one's list is marked out of date (kept, to show
    /// meanwhile) and checked again when next shown, and checks under way are overtaken.
    public mutating func invalidate(profileOf scope: ConnectorScope) {
        let profile = scope.key.profile
        for key in checks.keys where key.local && key.profile == profile { checks[key]?.invalidated = true }
        for key in checking.keys where key.local && key.profile == profile { checking[key] = nil }
    }

    /// Keeps the checks of the given profiles only (`ConnectorScope.profile`): a removed profile's,
    /// or one whose command changed, go, with any check of theirs still running.
    public mutating func retain(profiles: Set<String>) {
        checks = checks.filter { profiles.contains($0.key.profile) }
        checking = checking.filter { profiles.contains($0.key.profile) }
    }
}

/// `connectors.json`: each scope's last check by opaque key, as `ConnectorEvidence` keeps them.
/// It holds names, states, tool counts and BotChu's own error sentences only. A file that can't be
/// read is no checks, never an error.
public enum ConnectorCacheFile {
    private struct Entry: Codable {
        var key: ConnectorKey
        var check: ConnectorCheck
    }

    public static func decode(_ data: Data) -> [ConnectorKey: ConnectorCheck] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(entries.filter(\.key.local).map { ($0.key, $0.check) }) { $1 }
    }

    /// The checks tried within `ConnectorCheck.keptFor`, in a stable order.
    public static func encode(_ checks: [ConnectorKey: ConnectorCheck], now: Date = Date()) -> Data? {
        let kept = checks.filter { $0.key.local && now.timeIntervalSince($0.value.triedAt) < ConnectorCheck.keptFor }
            .map { Entry(key: $0.key, check: $0.value) }
            .sorted { $0.key.scope < $1.key.scope }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return try? encoder.encode(kept)
    }
}

public struct ConnectorFailure: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Where a provider manages its connections itself, in the browser. Its account there is
/// whichever is signed in, which needn't be the profile's.
public enum ConnectorSettings: String, Hashable, Sendable {
    case claudeAI, chatGPT

    public init?(_ kind: AgentKind) {
        switch kind {
        case .claude: self = .claudeAI
        case .codex: self = .chatGPT
        case .antigravity, .muse, .pi: return nil
        }
    }

    public var url: URL {
        switch self {
        case .claudeAI: URL(string: "https://claude.ai/customize/connectors")!
        case .chatGPT: URL(string: "https://chatgpt.com/#settings/Connectors")!
        }
    }

    public var title: String {
        switch self {
        case .claudeAI: "Manage on claude.ai"
        case .chatGPT: "Open ChatGPT Settings"
        }
    }
}

/// What a connector's row offers, from what its provider supports; never an action BotChu would
/// carry out itself, and nothing for a row that needs none.
public enum ConnectorAction: Hashable, Sendable {
    /// The CLI's own `mcp login <id>`, in Terminal, as the profile in its folder.
    case signIn
    /// The profile's CLI in its folder, in Terminal, where `/mcp` approves or turns servers on.
    case terminal
    /// The provider's settings in the browser.
    case settings(ConnectorSettings)
    /// Checks the profile again: the same discovery, never a connector's tool.
    case retry

    public var title: String {
        switch self {
        case .signIn: "Sign In…"
        case .terminal: "Open in Terminal"
        case .settings: "Manage"
        case .retry: "Retry"
        }
    }

    /// The action for `connector`, from a profile of `kind`, checked on this Mac (`local`) or
    /// reported from a host. A host's CLI is never run from here, nor checked again.
    public static func make(for connector: Connector, kind: AgentKind, local: Bool) -> ConnectorAction? {
        guard let settings = ConnectorSettings(kind) else { return nil }
        let cli: ConnectorAction? = local && ConnectorHandoff.isSafe(connector.id) ? .terminal : nil
        switch connector.state {
        case .needsAuth:
            if connector.origin == .codexApp { return .settings(settings) }
            if cli != nil { return .signIn }
            return connector.origin == .claudeAI ? .settings(settings) : nil
        case .failed:
            return local ? .retry : nil
        case .pending:
            return cli
        case .off:
            return connector.origin == .claudeAI || connector.origin == .codexApp ? .settings(settings) : cli
        case .unconfirmed:
            return connector.origin == .codexApp ? .settings(settings) : nil
        case .connected, .configured:
            return nil
        }
    }
}

/// What Terminal runs to hand a connector's management to the profile's CLI: the profile's own
/// command (shell syntax, as Settings has it), in the checked folder, with each argument quoted.
public enum ConnectorHandoff {
    /// An identifier or folder that can be passed as one word: no line breaks or control characters.
    public static func isSafe(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// A `.command` script for Terminal; it removes itself as it starts. Nil when the command,
    /// folder or an argument can't be passed safely.
    public static func script(command: String, folder: String, arguments: [String] = []) -> String? {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard isSafe(command), isSafe(folder), arguments.allSatisfy(isSafe) else { return nil }
        let line = ([command] + arguments.map(Shell.quote)).joined(separator: " ")
        return """
        #!/bin/zsh -l
        rm -f -- "$0"
        cd -- \(Shell.quote(folder)) || exit 1
        \(line)

        """
    }

    /// The arguments for `action` on `connector`: `mcp login <id>` to sign in, none to open the CLI.
    public static func arguments(for action: ConnectorAction, connector: Connector?) -> [String]? {
        switch action {
        case .signIn: connector.map { ["mcp", "login", $0.id] }
        case .terminal: []
        case .settings, .retry: nil
        }
    }
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

    /// The report it shows, if any.
    public var report: ConnectorReport? {
        switch self {
        case .session(let report, _): report
        case .profile(let check): check?.report
        case .unavailable, .notChecked, .notReported: nil
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
                             toolCount: state == .connected ? count : nil, id: name)
        }
    }

    /// `claude mcp list`, which health-checks each server it may connect to (claude.ai connectors
    /// and plugins' servers among them) without starting a model turn: `<name>: <command or URL>
    /// - <status>`. Only the name and the status are kept, never the target or the error after it.
    public static func claudeList(_ output: String) throws -> [Connector] {
        let markers: [(String, Connector.State)] = [
            ("✔ Connected", .connected), ("! Connected", .unconfirmed), ("! Needs authentication", .needsAuth),
            ("⏸ Pending approval", .pending), ("- Not configured", .unconfirmed), ("⊘ Disabled", .off),
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
            connectors.append(Connector(name: displayName(name), state: state, origin: origin, id: name))
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
            return Connector(name: name, state: !enabled ? .off : callable ? .connected : .unconfirmed, origin: .codexApp, id: id)
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
                    // No runtime state outside a thread: its tool listing and sign-in say how the check went,
                    // and a server that lists no tools (as Computer Use doesn't) is configured, nothing more.
                    if server["authStatus"] as? String == "notLoggedIn" { state = .needsAuth }
                    else if toolsFailed { state = .failed }
                    else { state = tools > 0 ? .connected : .configured }
                }
                connectors.append(Connector(name: displayName(name), state: state, origin: server["pluginId"] is String ? .plugin : .mcpServer,
                                            toolCount: toolsFailed ? nil : tools, id: name))
            }
        }
        return connectors
    }

    /// As reported, without the `claude.ai ` and `plugin:<plugin>:` prefixes (the origin says those),
    /// and Computer Use by its name rather than its server's.
    static func displayName(_ name: String) -> String {
        if name.hasPrefix("claude.ai ") { return String(name.dropFirst("claude.ai ".count)) }
        if name.hasPrefix("plugin:"), let last = name.split(separator: ":", omittingEmptySubsequences: false).last, !last.isEmpty {
            return displayName(String(last))
        }
        return Connector.toolNames.contains(Connector.normalized(name)) ? "Computer Use" : name
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
