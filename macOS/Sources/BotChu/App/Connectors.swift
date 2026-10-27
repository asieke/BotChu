import Foundation
import BotChuCore

/// The connectors evidence BotChu has (#183), in memory only (`ConnectorEvidence`): each
/// conversation's latest Claude Code session report and each scope's profile check.
@MainActor @Observable final class ConnectorBoard {
    private(set) var evidence = ConnectorEvidence<ChatTarget>()
    /// Tests and reviews inject this so they never start a CLI (`BOTCHU_CONNECTORS`).
    @ObservationIgnored var checkProfile: @Sendable (_ kind: AgentKind, _ command: String, _ folder: String) async throws -> ConnectorReport =
        DevHooks.connectorCheck ?? { try await ConnectorClient.check($0, command: $1, folder: $2) }

    func record(_ connectors: [Connector], scope: ConnectorScope, sessionID: String?, for target: ChatTarget) {
        evidence.record(connectors, scope: scope, sessionID: sessionID, for: target)
    }

    /// Checks the profile in `scope` when that is due (`force`: Refresh, within its limit).
    func check(_ scope: ConnectorScope, kind: AgentKind, force: Bool = false) async {
        guard evidence.begin(scope, force: force) else { return }
        let result: Result<ConnectorReport, ConnectorFailure>
        do { result = .success(try await checkProfile(kind, scope.command, scope.folder)) }
        catch let failure as ConnectorFailure { result = .failure(failure) }
        catch { result = .failure(ConnectorFailure("\(kind.displayName) couldn’t list its connectors.")) }
        evidence.finish(scope, result)
    }
}

extension AppModel {
    /// The command a conversation's CLI runs: on a host, its own for the account when it has one.
    func effectiveCommand(for account: Account, task: BotTask?) -> String {
        task.flatMap { settings.host($0.hostID)?.command(for: account) } ?? settings.command(for: account)
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
        let task = task(target)
        let host = task?.isRemote == true ? task.map { machineName($0.hostID, fallback: $0.hostName) } : nil
        let evidence = connectorBoard.evidence
        return ConnectorCard.make(kind: current.account.kind, scope: scope, host: host, sessionID: current.resumableSessionID,
                                  session: evidence.sessions[target], check: evidence.checks[scope])
    }
}
