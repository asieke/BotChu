import Foundation
import BotChuCore

/// Owns one utility worker for the app. Scans wait for idle, credentials are read on a utility
/// task, and the main actor only answers small activity/profile/location snapshots.
@MainActor
final class OpenRouterBilling {
    private var work: Task<Void, Never>?

    init(model: AppModel, client: OpenRouterCost = OpenRouterCost(),
         key: @escaping @Sendable () async -> String? = {
             await Task.detached(priority: .utility) { Keychain.get(Keychain.openRouterAccount) }.value
         }) {
        let scheduler = OpenRouterCostScheduler(client: client, isActive: { [weak model] candidate in
            await Self.isActive(candidate, model: model)
        }, credential: { [weak model] accountID in
            guard await Self.permits(accountID, model: model) else { return nil }
            return await key()
        }, amend: { [weak model] candidate, cost in
            guard let (home, storage) = await Self.destination(candidate, model: model) else { return false }
            return await OpenRouterCostLedger.amend(candidate, cost: cost, in: home, queue: storage)
        })
        work = Task.detached(priority: .utility) { [weak model] in
            // Startup and completed turns get the same minimum grace period. No launch scan.
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            var candidates: [OpenRouterCostScheduler.Candidate] = []
            var nextScan = Date.distantPast
            var previousAccounts: [Account] = []
            var previousRevision: Int?
            while !Task.isCancelled {
                guard let snapshot = await Self.snapshot(model) else { return }
                for account in snapshot.accounts where previousRevision != snapshot.revision || !previousAccounts.contains(account) {
                    await scheduler.reset(accountID: account.id)
                }
                previousAccounts = snapshot.accounts
                previousRevision = snapshot.revision
                if let homes = snapshot.idleHomes, Date() >= nextScan {
                    var pending: [OpenRouterCostScheduler.Candidate] = []
                    for (id, home) in homes {
                        // Activity can begin while a previous bot's file is being read.
                        guard await Self.idle(model) else { break }
                        pending += await OpenRouterCostLedger.pending(in: home, ownerBotID: id,
                            accounts: snapshot.accounts, queue: snapshot.storage)
                    }
                    candidates = pending.sorted { $0.endedAt < $1.endedAt }
                    nextScan = Date().addingTimeInterval(60)
                }
                await scheduler.tick(candidates)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    deinit { work?.cancel() }
    func stop() { work?.cancel(); work = nil }

    private struct Snapshot: Sendable {
        var accounts: [Account]
        var revision: Int
        var idleHomes: [(UUID, BotHome)]?
        var storage: StorageQueue
    }

    private static func idle(_ model: AppModel?) -> Bool {
        guard let model, !model.terminating else { return false }
        return !model.bots.contains { model.isBusy($0.id) }
    }

    private static func snapshot(_ model: AppModel?) -> Snapshot? {
        guard let model, !model.terminating else { return nil }
        return Snapshot(accounts: model.settings.accounts, revision: model.settings.usageCredentialRevision,
            idleHomes: idle(model) ? model.bots.filter { !$0.isRemoteQueue }.map { ($0.id, BotHome(workspace: $0.persistencePath)) } : nil,
            storage: model.storage)
    }

    private static func permits(_ accountID: String, model: AppModel?) -> Bool {
        guard let model, !model.terminating else { return false }
        return model.settings.accounts.contains { $0.id == accountID && OpenRouterCostLedger.permits($0) }
    }

    private static func destination(_ candidate: OpenRouterCostScheduler.Candidate, model: AppModel?) -> (BotHome, StorageQueue)? {
        guard !isActive(candidate, model: model), let model, let bot = model.bot(candidate.ownerBotID) else { return nil }
        return (BotHome(workspace: bot.persistencePath), model.storage)
    }

    private static func isActive(_ candidate: OpenRouterCostScheduler.Candidate, model: AppModel?) -> Bool {
        guard let model, !model.terminating, let owner = model.bot(candidate.ownerBotID),
              let bot = model.bot(candidate.botID), !owner.isRemoteQueue, !bot.isRemoteQueue else { return true }
        return model.isBusy(owner.id) || model.isBusy(bot.id)
    }
}
