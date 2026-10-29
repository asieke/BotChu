import Foundation

/// The bridge between passive turn records and billing. Historical host and credential ownership
/// must be known; the current task's location or a different profile's key cannot substitute.
public enum OpenRouterCostLedger {
    public static func permits(_ account: Account) -> Bool {
        account.kind == .pi && RuntimeAdapters.adapter(for: account.kind)
            .usesLegacyOpenRouterKey(account: account, provider: "openrouter")
    }

    public static func candidate(_ entry: UsageLedger.Entry, ownerBotID: UUID, at now: Date) -> OpenRouterCostScheduler.Candidate? {
        guard entry.provider == .pi, entry.providerID == "openrouter", !entry.remote, entry.usesLegacyOpenRouterKey,
              now.timeIntervalSince(entry.at) >= 60, now.timeIntervalSince(entry.at) <= 86_400,
              let usage = entry.usage, !usage.cumulative, !usage.generationIDs.isEmpty,
              usage.generationIDs.allSatisfy(OpenRouterCost.supports) else { return nil }
        return .init(id: entry.id, ownerBotID: ownerBotID, botID: entry.botID, accountID: entry.accountID,
                     endedAt: entry.at, generationIDs: usage.generationIDs)
    }

    /// Called only on the idle worker. Serialized with append/amend, including pending turn saves.
    public static func pending(in home: BotHome, ownerBotID: UUID, accounts: [Account], at now: Date = Date(),
                               queue: StorageQueue = .shared) async -> [OpenRouterCostScheduler.Candidate] {
        let allowed = Set(accounts.filter(permits).map(\.id))
        guard !allowed.isEmpty else { return [] }
        return (try? await queue.perform(UsageLedger.lane(in: home), label: "OpenRouter billing scan") {
            let ledger = try UsageLedger.read(in: home)
            let amended = Set(ledger.amendments.map(\.amends))
            return ledger.entries.compactMap { entry in
                guard allowed.contains(entry.accountID), !amended.contains(entry.id) else { return nil }
                return candidate(entry, ownerBotID: ownerBotID, at: now)
            }
        }) ?? []
    }

    public static func amend(_ candidate: OpenRouterCostScheduler.Candidate, cost: Double, in home: BotHome,
                             at now: Date = Date(), queue: StorageQueue = .shared) async -> Bool {
        await withCheckedContinuation { continuation in
            UsageLedger.amend(.init(amends: candidate.id, actualCostUSD: cost), at: now, in: home, queue: queue) { result in
                continuation.resume(returning: (try? result.get()) != nil)
            }
        }
    }
}
