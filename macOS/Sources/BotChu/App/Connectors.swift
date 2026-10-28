import AppKit
import BotChuCore

/// The connectors evidence BotChu has (#183, `ConnectorEvidence`): each conversation's latest
/// Claude Code session report, in memory, and each scope's profile check, saved between launches
/// in `connectors.json` by opaque key (#212). A check of a scope shows there alone.
@MainActor @Observable final class ConnectorBoard {
    private(set) var evidence: ConnectorEvidence<ChatTarget>
    /// Tests and reviews inject this so they never start a CLI (`BOTCHU_CONNECTORS`).
    @ObservationIgnored var checkProfile: @Sendable (_ kind: AgentKind, _ command: String, _ folder: String) async throws -> ConnectorReport =
        DevHooks.connectorCheck ?? { try await ConnectorClient.check($0, command: $1, folder: $2) }
    /// The profiles in Settings now (`ConnectorScope.profile`); checks of any other are dropped as saved.
    @ObservationIgnored var profiles: @MainActor () -> Set<String>? = { nil }
    /// The scope whose provider was handed management last, checked again once BotChu is back in front.
    @ObservationIgnored private(set) var awaitingReturn: (scope: ConnectorScope, kind: AgentKind)?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let writes = DispatchQueue(label: "BotChu.connectors", qos: .utility)
    @ObservationIgnored private var activation: NSObjectProtocol?

    init(file: URL? = nil) {
        self.file = file
        evidence = ConnectorEvidence(checks: file.flatMap { try? Data(contentsOf: $0) }.map(ConnectorCacheFile.decode) ?? [:])
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returned() }
        }
    }

    func record(_ connectors: [Connector], scope: ConnectorScope, sessionID: String?, for target: ChatTarget) {
        evidence.record(connectors, scope: scope, sessionID: sessionID, for: target)
    }

    /// Checks the profile in `scope` when that is due (`force`: Refresh, within its limit). One
    /// check of a scope runs at a time; asking meanwhile starts nothing, unless the running one was
    /// overtaken by a handoff, when one more check follows it.
    func check(_ scope: ConnectorScope, kind: AgentKind, force: Bool = false) async {
        guard scope.isLocal, isKnown(scope), var token = evidence.begin(scope, force: force) else { return }
        while true {
            let result: Result<ConnectorReport, ConnectorFailure>
            do { result = .success(try await checkProfile(kind, scope.command, scope.folder)) }
            catch let failure as ConnectorFailure { result = .failure(failure) }
            catch { result = .failure(ConnectorFailure("\(kind.displayName) couldn’t list its connectors.")) }
            let finish = evidence.finish(scope, token: token, result)
            if finish.recorded { save() }
            guard finish.again, isKnown(scope), let next = evidence.begin(scope, force: true) else { return }
            token = next
        }
    }

    /// The provider's settings or CLI were opened for `scope`: every folder's list for its profile
    /// is out of date, and `scope` is checked again when the owner comes back.
    func handedOff(_ scope: ConnectorScope, kind: AgentKind) {
        guard scope.isLocal else { return }
        evidence.invalidate(profileOf: scope)
        awaitingReturn = (scope, kind)
        save()
    }

    /// BotChu is in front again after a handoff: the scope it was for is checked again, if its
    /// profile and command are still in Settings.
    func returned() {
        guard let (scope, kind) = awaitingReturn else { return }
        awaitingReturn = nil
        Task { await check(scope, kind: kind) }
    }

    /// Drops the checks of profiles no longer in Settings, or whose command changed, and a return
    /// awaited for one.
    func prune() {
        guard let profiles = profiles() else { return }
        if let scope = awaitingReturn?.scope, !profiles.contains(scope.key.profile) { awaitingReturn = nil }
        let before = evidence.checks.count
        evidence.retain(profiles: profiles)
        if evidence.checks.count != before { save() }
    }

    /// Whether `scope`'s profile, with its command, is in Settings now.
    private func isKnown(_ scope: ConnectorScope) -> Bool {
        profiles().map { $0.contains(scope.key.profile) } ?? true
    }

    /// Writes every check off the main thread, in order; one that can't be written stays in memory.
    private func save() {
        guard let file else { return }
        if let profiles = profiles() { evidence.retain(profiles: profiles) }
        guard let data = ConnectorCacheFile.encode(evidence.checks) else { return }
        writes.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Waits for the writes queued so far (tests).
    func flush() { writes.sync {} }
}

/// A folder a profile's connectors can be checked in: a conversation's (its Home's or a task's,
/// on a host too), or the home folder.
struct ConnectorWorkspace: Hashable, Identifiable {
    var scope: ConnectorScope
    /// The bot's or the task's name, or "Home folder".
    var title: String
    /// The conversation it comes from, whose session reports count on a host.
    var target: ChatTarget?
    var id: ConnectorScope { scope }
}

/// A Terminal handoff: the script it runs and what it is for.
struct ConnectorHandoffRequest: Equatable {
    var script: String
    var scope: ConnectorScope
}

extension AppModel {
    /// The command a conversation's CLI runs: on a host, its own for the account when it has one.
    func effectiveCommand(for account: Account, task: BotTask?) -> String {
        RuntimeAdapters.adapter(for: account.kind).command(local: settings.command(for: account),
            host: task.flatMap { settings.host($0.hostID)?.command(for: account) }, remote: task?.isRemote == true)
    }

    /// The profile, command, folder and host the conversation's next turn runs in; nil for a task
    /// whose workspace isn't made yet.
    func connectorScope(of target: ChatTarget) -> ConnectorScope? {
        guard let bot = bot(target.botID), let account = runSettings(of: target)?.account else { return nil }
        let task = task(target)
        guard let folder = task == nil ? bot.workspace : task?.folder else { return nil }
        return ConnectorScope(accountID: account.id, command: effectiveCommand(for: account, task: task), folder: folder, hostID: task?.hostID)
    }

    /// What the conversation's Connectors card shows.
    func connectorCard(of target: ChatTarget) -> ConnectorCard {
        guard let current = runSettings(of: target), let scope = connectorScope(of: target) else { return .notReported }
        return connectorCard(kind: current.account.kind, scope: scope, sessionID: current.resumableSessionID,
                             session: connectorBoard.evidence.sessions[target])
    }

    /// The card for `workspace` in Providers: a host's session reports in exactly its scope, or the
    /// check of its folder on this Mac.
    func connectorCard(of workspace: ConnectorWorkspace, kind: AgentKind) -> ConnectorCard {
        let session = workspace.target.flatMap { runSettings(of: $0)?.resumableSessionID }
        return connectorCard(kind: kind, scope: workspace.scope, sessionID: session,
                             session: connectorBoard.evidence.session(in: workspace.scope))
    }

    private func connectorCard(kind: AgentKind, scope: ConnectorScope, sessionID: String?, session: SessionConnectorReport?) -> ConnectorCard {
        let host = scope.hostID.map { id in settings.host(id)?.nickname ?? tasks.values.joined().first { $0.hostID == id }?.hostName ?? "a host" }
        return ConnectorCard.make(kind: kind, scope: scope, host: host, sessionID: sessionID, session: session,
                                  check: connectorBoard.evidence.check(for: scope))
    }

    /// The profiles in Settings, each by its command now, whose checks are kept.
    var connectorProfiles: Set<String> {
        Set(settings.accounts.map { ConnectorScope.profile(accountID: $0.id, command: settings.command(for: $0)) })
    }

    /// The folders `account`'s connectors can be checked in, as Providers lists them: the Homes and
    /// open tasks set to it, in sidebar order, then the home folder; a conversation's scope that
    /// Manage opened stays among them.
    func connectorWorkspaces(for account: Account) -> [ConnectorWorkspace] {
        var list: [ConnectorWorkspace] = []
        for bot in bots where !bot.isRemoteQueue {
            let targets = [ChatTarget.home(bot.id)] + (tasks[bot.id] ?? []).filter { !$0.isArchived }.map { .task($0.id, of: bot.id) }
            for target in targets {
                guard runSettings(of: target)?.account.id == account.id, let scope = connectorScope(of: target),
                      !list.contains(where: { $0.scope == scope }) else { continue }
                list.append(ConnectorWorkspace(scope: scope, title: task(target)?.title ?? bot.name, target: target))
            }
        }
        let home = ConnectorScope(accountID: account.id, command: settings.command(for: account), folder: NSHomeDirectory())
        if !list.contains(where: { $0.scope == home }) { list.append(ConnectorWorkspace(scope: home, title: "Home folder")) }
        if let chosen = providerConnectorWorkspace, chosen.scope.accountID == account.id, !list.contains(where: { $0.scope == chosen.scope }) {
            list.insert(chosen, at: 0)
        }
        return list
    }

    /// The folder Providers checks `account` in: the one Manage or the menu chose, else the first
    /// Home or task on this Mac set to it, else the home folder.
    func connectorWorkspace(for account: Account) -> ConnectorWorkspace {
        let list = connectorWorkspaces(for: account)
        if let chosen = providerConnectorWorkspace, let match = list.first(where: { $0.scope == chosen.scope }) { return match }
        return list.first { $0.scope.isLocal } ?? list[0]
    }

    /// A conversation's Manage: Providers, with its profile selected and its scope (folder and host) checked.
    func manageConnectors(of target: ChatTarget) {
        guard let scope = connectorScope(of: target), let bot = bot(target.botID) else { return }
        providerConnectorWorkspace = ConnectorWorkspace(scope: scope, title: task(target)?.title ?? bot.name, target: target)
        providerSelection = scope.accountID
        destination = .providers
    }

    /// Carries out a row's or the section's action for `scope`, a profile of `kind`. Management is
    /// the provider's: BotChu opens its settings or its CLI in Terminal, and checks again on return.
    func perform(_ action: ConnectorAction, connector: Connector?, scope: ConnectorScope, kind: AgentKind) {
        switch action {
        case .retry:
            Task { await connectorBoard.check(scope, kind: kind, force: true) }
        case .settings(let settings):
            guard openURL(settings.url) else { return }
            connectorBoard.handedOff(scope, kind: kind)
        case .signIn, .terminal:
            guard scope.isLocal, let arguments = ConnectorHandoff.arguments(for: action, connector: connector),
                  let script = ConnectorHandoff.script(command: scope.command, folder: scope.folder, arguments: arguments),
                  openTerminal(ConnectorHandoffRequest(script: script, scope: scope)) else { return }
            connectorBoard.handedOff(scope, kind: kind)
        }
    }

    /// Runs a handoff's script in a new Terminal window, through a self-removing `.command` file.
    static func openInTerminal(_ request: ConnectorHandoffRequest) -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BotChu-\(UUID().uuidString).command")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(request.script.utf8), attributes: [.posixPermissions: 0o700]),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
