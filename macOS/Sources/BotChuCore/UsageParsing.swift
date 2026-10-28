import Foundation

/// Reads dictionaries the stream parser already decoded. No extra JSON decode, I/O or pricing.
enum UsageParsing {
    static func count(_ json: JSON, _ key: String) -> Int? {
        guard let number = json[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }

    static func cost(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    static func uncached(_ input: Int?, _ cached: Int?) -> Int? {
        input.map { max(0, $0 - (cached ?? 0)) }
    }

    static func turn(_ model: ModelUsage, cost: Double? = nil, cumulative: Bool = false, ids: [String] = []) -> TurnUsage? {
        guard model.hasReportedTokens || cost != nil else { return nil }
        return TurnUsage(models: model.hasReportedTokens ? [model] : [], reportedCostUSD: cost, cumulative: cumulative, generationIDs: ids)
    }

    static func claude(_ obj: JSON) -> TurnUsage? {
        // Since-last-result wins even when empty: the other map may contain earlier turns.
        let models = (obj["model_usage_since_last_result"] as? JSON) ?? (obj["modelUsage"] as? JSON)
        if let models {
            var result = TurnUsageAccumulator()
            for name in models.keys.sorted() {
                guard let entry = models[name] as? JSON else { continue }
                let model = ModelUsage(model: name, uncachedInput: count(entry, "inputTokens"),
                    cacheRead: count(entry, "cacheReadInputTokens"), cacheWrite: count(entry, "cacheCreationInputTokens"),
                    cacheWrite1h: count(entry, "cacheCreationEphemeral1hInputTokens"), output: count(entry, "outputTokens"),
                    reasoning: count(entry, "thinkingTokens"))
                if let usage = turn(model, cost: cost(entry["costUSD"])) { result.add(usage) }
            }
            return result.value
        }
        guard let entry = obj["usage"] as? JSON else { return nil }
        let model = ModelUsage(model: "", uncachedInput: count(entry, "input_tokens"),
            cacheRead: count(entry, "cache_read_input_tokens"), cacheWrite: count(entry, "cache_creation_input_tokens"),
            cacheWrite1h: (entry["cache_creation"] as? JSON).flatMap { count($0, "ephemeral_1h_input_tokens") },
            output: count(entry, "output_tokens"),
            reasoning: (entry["output_tokens_details"] as? JSON).flatMap { count($0, "thinking_tokens") })
        return turn(model)
    }

    static func codex(_ obj: JSON) -> TurnUsage? {
        guard let entry = obj["usage"] as? JSON else { return nil }
        let cached = count(entry, "cached_input_tokens")
        return turn(ModelUsage(model: "", uncachedInput: uncached(count(entry, "input_tokens"), cached),
            cacheRead: cached, cacheWrite: count(entry, "cache_write_input_tokens"), output: count(entry, "output_tokens"),
            reasoning: count(entry, "reasoning_output_tokens")), cumulative: true)
    }

    static func antigravity(_ obj: JSON?) -> TurnUsage? {
        guard let entry = obj?["usage"] as? JSON else { return nil }
        // agy's wire buckets are disjoint, unlike raw Gemini API promptTokenCount.
        // Verified by the captured per-step cache hit and its final summed result.
        return turn(ModelUsage(model: "", uncachedInput: count(entry, "input_tokens"),
            cacheRead: count(entry, "cache_read_tokens"), output: count(entry, "output_tokens"), reasoning: count(entry, "thinking_tokens")))
    }

    static func muse(_ obj: JSON) -> TurnUsage? {
        let models = (obj["models"] as? [JSON] ?? []).compactMap { entry -> ModelUsage? in
            let cached = count(entry, "cached_tokens")
            let model = ModelUsage(model: entry["model"] as? String ?? "",
                uncachedInput: uncached(count(entry, "input_tokens"), cached), cacheRead: cached,
                output: count(entry, "output_tokens"), reasoning: count(entry, "reasoning_tokens"))
            return model.hasReportedTokens ? model : nil
        }
        return models.isEmpty ? nil : TurnUsage(models: models)
    }

    static func pi(_ message: JSON) -> TurnUsage? {
        guard let entry = message["usage"] as? JSON else { return nil }
        let model = ModelUsage(model: message["model"] as? String ?? "", uncachedInput: count(entry, "input"),
            cacheRead: count(entry, "cacheRead"), cacheWrite: count(entry, "cacheWrite"),
            output: count(entry, "output"), reasoning: count(entry, "reasoning"))
        return turn(model, cost: cost((entry["cost"] as? JSON)?["total"]),
                    ids: (message["responseId"] as? String).map { $0.isEmpty ? [] : [$0] } ?? [])
    }
}
