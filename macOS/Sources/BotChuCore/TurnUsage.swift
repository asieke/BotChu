import Foundation

/// Usage reported by a CLI for one turn. Capture is passive; pricing and cumulative-session
/// differences belong to readers of the usage ledger. An empty model ID means it wasn't reported.
public struct TurnUsage: Codable, Equatable, Sendable {
    public var models: [ModelUsage]
    /// The provider or CLI's estimate, not necessarily the amount billed.
    public var reportedCostUSD: Double?
    public var cumulative: Bool
    public var generationIDs: [String]

    public init(models: [ModelUsage], reportedCostUSD: Double? = nil, cumulative: Bool = false,
                generationIDs: [String] = []) {
        self.models = models
        self.reportedCostUSD = reportedCostUSD
        self.cumulative = cumulative
        self.generationIDs = generationIDs
    }
}

/// Adds only reported buckets; absent usage must never become a fabricated zero.
struct TurnUsageAccumulator {
    private(set) var value: TurnUsage?
    private struct ModelKey: Hashable { let model: String; let window: SailCompletionWindow? }
    private var overflowingBuckets: [ModelKey: Set<WritableKeyPath<ModelUsage, Int?>>] = [:]
    private var overflowingCost = false

    mutating func add(_ usage: TurnUsage) {
        // This accumulator is for per-request totals. A cumulative report replaces its predecessor;
        // it must never be added to it (Codex's session difference is computed by ledger readers).
        guard !usage.cumulative, value?.cumulative != true else { value = usage; return }
        guard var total = value else { value = usage; return }
        for model in usage.models {
            let modelKey = ModelKey(model: model.model, window: model.sailCompletionWindow)
            if let index = total.models.firstIndex(where: { $0.model == model.model && $0.sailCompletionWindow == model.sailCompletionWindow }) {
                for key in [\ModelUsage.uncachedInput, \.cacheRead, \.cacheWrite, \.cacheWrite1h, \.output, \.reasoning] {
                    if let count = model[keyPath: key], overflowingBuckets[modelKey]?.contains(key) != true {
                        let (sum, overflow) = (total.models[index][keyPath: key] ?? 0).addingReportingOverflow(count)
                        total.models[index][keyPath: key] = overflow ? nil : sum
                        if overflow { overflowingBuckets[modelKey, default: []].insert(key) }
                    }
                }
            } else { total.models.append(model) }
        }
        if let cost = usage.reportedCostUSD, !overflowingCost {
            let sum = (total.reportedCostUSD ?? 0) + cost
            overflowingCost = !sum.isFinite
            total.reportedCostUSD = overflowingCost ? nil : sum
        }
        total.generationIDs += usage.generationIDs.filter { !total.generationIDs.contains($0) }
        value = total
    }
}

extension ModelUsage {
    var hasReportedTokens: Bool {
        [uncachedInput, cacheRead, cacheWrite, cacheWrite1h, output, reasoning].contains { $0 != nil }
    }
}
