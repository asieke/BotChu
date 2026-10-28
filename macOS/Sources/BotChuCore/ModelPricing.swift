import Foundation

/// A token-only market estimate in USD, not the account's actual bill or subscription charge.
public struct PricedCost: Equatable, Sendable {
    public let usd: Double
    public let model: String
    public let displayName: String
    public let snapshotDate: String
}

public enum ModelPricing {
    public static var snapshotDate: String { ModelPrices.snapshotDate }

    /// The same offline rates and context thresholds used by `price`, for dashboard comparisons.
    public static var catalog: [AnalyticsModelPrice] {
        ModelPrices.entries.keys.sorted().compactMap { key in
            guard let entry = ModelPrices.entries[key], let slash = key.firstIndex(of: "/") else { return nil }
            let source = String(key[..<slash]), model = String(key[key.index(after: slash)...])
            let kind: AgentKind = source == "openrouter" ? .pi : source == "sail" ? .sail : source == "anthropic" ? .claude : source == "google" ? .antigravity : .codex
            return AnalyticsModelPrice(source: source, model: model,
                                       displayName: ModelPickerData(kind: kind, model: model, openRouterDefault: "").title,
                                       rates: .init(entry.rates), tiers: entry.tiers.map { .init(aboveInput: $0.aboveInput, rates: .init($0.rates)) })
        }
    }

    /// Prices one request, using its total input to select a context tier for all its tokens.
    /// Unknown models or a used bucket without a published rate remain unpriced. Missing counts
    /// contribute nothing; completely absent usage is not a measured zero. Reasoning is already
    /// included in output, and one-hour writes are already included in total cache writes.
    public static func price(_ usage: ModelUsage, provider: AgentKind, backend: String? = nil) -> PricedCost? {
        guard let (model, entry) = resolve(usage.model, provider: provider, backend: backend) else { return nil }
        return price(usage, provider: provider, model: model, entry: entry)
    }

    static func price(_ usage: ModelUsage, provider: AgentKind, model: String, entry: ModelPrice) -> PricedCost? {
        let counts = [usage.uncachedInput, usage.cacheRead, usage.cacheWrite,
                      usage.cacheWrite1h, usage.output, usage.reasoning]
        guard counts.contains(where: { $0 != nil }), counts.allSatisfy({ ($0 ?? 0) >= 0 }) else { return nil }
        let input = Double(usage.uncachedInput ?? 0)
        let read = Double(usage.cacheRead ?? 0)
        let hour = Double(usage.cacheWrite1h ?? 0)
        // Some providers only report the 1h subset. It still establishes that much total writing.
        let write = Double(usage.cacheWrite ?? usage.cacheWrite1h ?? 0)
        let output = Double(usage.output ?? usage.reasoning ?? 0)
        guard hour <= write, Double(usage.reasoning ?? 0) <= output else { return nil }
        let totalInput = input + read + write
        let rates = entry.tiers.last(where: { totalInput > Double($0.aboveInput) })?.rates ?? entry.rates
        let buckets: [(Double, Double?)] = [
            (input, rates.input), (read, rates.cacheRead), (write - hour, rates.cacheWrite),
            (hour, rates.cacheWrite1h ?? rates.input * 2), (output, rates.output)
        ]
        var usd = 0.0
        for (count, rate) in buckets where count > 0 {
            guard let rate else { return nil }
            usd += count * rate / 1_000_000
        }
        guard usd.isFinite else { return nil }
        return PricedCost(usd: usd, model: model,
                          displayName: ModelPickerData(kind: provider, model: model, openRouterDefault: "").title,
                          snapshotDate: ModelPrices.snapshotDate)
    }

    private static func resolve(_ raw: String, provider: AgentKind, backend: String?) -> (String, ModelPrice)? {
        let sources: [String]
        switch provider {
        case .pi:
            switch backend {
            case nil, "openrouter": sources = ["openrouter"]
            case "anthropic", "openai", "google": sources = [backend!]
            default: return nil
            }
        case .sail: sources = ["sail"]
        case .claude, .codex, .antigravity, .muse: sources = ["anthropic", "openai", "google"]
        }
        var candidates = [raw.trimmingCharacters(in: .whitespacesAndNewlines)]
        // Exact IDs always win, including Pi's dotted version slugs and published -thinking IDs.
        var normalized = candidates[0]
        while true {
            let next = normalized
                .replacingOccurrences(of: #"\[1m\]$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"-(?:none|minimal|low|medium|high|xhigh|max|ultra|thinking(?:-(?:\d+|low|medium|high))?)$"#,
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
            guard next != normalized else { break }
            normalized = next
            candidates.append(next)
        }
        for candidate in candidates {
            for source in sources {
                // Keep OpenRouter/Sail publisher namespaces: they are part of their model IDs.
                let ids: [String]
                if source == "openrouter" || source == "sail" {
                    ids = [candidate, candidate.hasPrefix(source + "/") ? String(candidate.dropFirst(source.count + 1)) : candidate]
                } else {
                    ids = [candidate, candidate.split(separator: "/", maxSplits: 1).last.map(String.init) ?? candidate]
                }
                for id in ids {
                    if let found = ModelPrices.entries[source + "/" + id] { return (id, found) }
                }
            }
        }
        return nil
    }
}

/// All rates are USD per million tokens; nil is unknown, never an implicit free rate.
struct ModelPriceRates: Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?
    let cacheWrite1h: Double?

    init(_ input: Double, _ output: Double, _ cacheRead: Double? = nil,
         _ cacheWrite: Double? = nil, _ cacheWrite1h: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
    }
}

struct ModelPrice: Sendable {
    struct Tier: Sendable {
        let aboveInput: Int
        let rates: ModelPriceRates
    }
    let rates: ModelPriceRates
    let tiers: [Tier]

    init(_ rates: ModelPriceRates, tiers: [Tier] = []) {
        self.rates = rates
        self.tiers = tiers
    }
}

/// A JSON-safe pricebook entry. All rates are USD per million; missing cache rates stay unknown.
public struct AnalyticsModelPrice: Codable, Equatable, Sendable {
    public struct Rates: Codable, Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double?
        public var cacheWrite: Double?
        public var cacheWrite1h: Double?
        init(_ rates: ModelPriceRates) {
            input = rates.input; output = rates.output; cacheRead = rates.cacheRead
            cacheWrite = rates.cacheWrite; cacheWrite1h = rates.cacheWrite1h
        }
    }
    public struct Tier: Codable, Equatable, Sendable {
        public var aboveInput: Int
        public var rates: Rates
    }
    public var source: String
    public var model: String
    public var displayName: String
    public var rates: Rates
    public var tiers: [Tier]
}
