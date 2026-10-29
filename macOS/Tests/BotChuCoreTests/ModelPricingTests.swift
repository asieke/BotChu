import Foundation
import Testing
@testable import BotChuCore

@Suite struct ModelPricingTests {
    @Test func haikuMatchesClaudeCodesReportedCost() throws {
        let usage = ModelUsage(model: "claude-haiku-5-5", uncachedInput: 2, cacheRead: 11_382,
                               cacheWrite: 8_673, cacheWrite1h: 8_673, output: 4)
        let result = try #require(ModelPricing.price(usage, provider: .claude))
        #expect(abs(result.usd - 0.00185062) < 1e-12)
        #expect(result.displayName == "Claude Haiku 5.5")
        #expect(result.snapshotDate == "2026-10-28")
    }

    @Test func longContextUsesAllInputBucketsAndStrictThreshold() throws {
        let boundary = ModelUsage(model: "gpt-6-astra", uncachedInput: 2, cacheRead: 271_998, output: 4)
        let over = ModelUsage(model: "gpt-6-astra", uncachedInput: 2, cacheRead: 271_998, cacheWrite: 1, output: 4)
        #expect(abs(try #require(ModelPricing.price(boundary, provider: .codex)).usd - 0.272218) < 1e-12)
        #expect(abs(try #require(ModelPricing.price(over, provider: .codex)).usd - 0.544361) < 1e-12)
        let hour = ModelUsage(model: "claude-haiku-5-5", uncachedInput: 1, cacheWrite: 100_000, cacheWrite1h: 100_000)
        #expect(abs(try #require(ModelPricing.price(hour, provider: .claude)).usd - 0.1000005) < 1e-12)
    }

    @Test func piKeepsDottedSlugsAndLegacySailUsageDefaultsToFlex() throws {
        let pi = ModelUsage(model: "deepseek/deepseek-v4.1-flash-1017", uncachedInput: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(try #require(ModelPricing.price(pi, provider: .pi)).usd - 0.753) < 1e-12)
        #expect(ModelPricing.price(pi, provider: .sail) == nil)
        let sail = ModelUsage(model: "deepseek-ai/DeepSeek-V4.1-Flash-1017", uncachedInput: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        #expect(abs(try #require(ModelPricing.price(sail, provider: .sail)).usd - 0.204) < 1e-12)
        #expect(ModelPricing.price(sail, provider: .pi) == nil)
    }

    @Test func decorationsNormalizeWithoutGuessingModelVersions() throws {
        for model in ["claude-haiku-5-5-20261001[1m]", "anthropic/claude-haiku-5-5-high",
                      "claude-haiku-5-5-thinking-16384", "claude-haiku-5-5-low", "claude-haiku-5-5-medium"] {
            let result = try #require(ModelPricing.price(ModelUsage(model: model, output: 2), provider: .antigravity))
            #expect(result.model == "claude-haiku-5-5")
            #expect(abs(result.usd - 0.000001) < 1e-12)
        }
        for (model, kind) in [("gemini-3.5-pro", AgentKind.antigravity), ("muse-spark-1.3-high", .muse),
                              ("unknown", .codex), ("haiku", .claude), ("claude-haiku-55", .claude)] {
            #expect(ModelPricing.price(ModelUsage(model: model, output: 2), provider: kind) == nil)
        }
    }

    @Test func piPricesBelongToTheSelectedServiceRatherThanTheRuntime() throws {
        let usage = ModelUsage(model: "deepseek/deepseek-v4.1-flash-1017", output: 1_000_000)
        var bot = Bot(name: "Pricing", accountID: "openrouter", workspace: "/tmp/pricing")
        let legacy = try #require(ModelPricing.price(usage, settings: bot))
        #expect(ModelPricing.price(usage, provider: .pi, providerID: "openrouter") == legacy)
        bot.selectProvider("radius")
        #expect(ModelPricing.price(usage, settings: bot) == nil)
        bot.selectProvider("anthropic")
        let direct = ModelUsage(model: "claude-haiku-5-5", output: 1_000_000)
        #expect(try #require(ModelPricing.price(direct, settings: bot)).usd == ModelPricing.price(direct, provider: .claude)?.usd)
    }

    @Test func subsetsAreNotChargedTwiceAndMissingHourRateUsesTwiceInput() throws {
        // Inject rates to exercise the documented fallback independently of snapshot contents.
        let entry = ModelPrice(.init(2, 10, 0.2, 2.5), tiers: [.init(aboveInput: 100, rates: .init(4, 15, 0.4, 5))])
        let usage = ModelUsage(model: "test", cacheWrite: 10, cacheWrite1h: 6, output: 5, reasoning: 3)
        let result = try #require(ModelPricing.price(usage, provider: .claude, model: "test", entry: entry))
        #expect(abs(result.usd - 0.000084) < 1e-12)
        let over = ModelUsage(model: "test", cacheWrite: 101, cacheWrite1h: 101)
        #expect(abs(try #require(ModelPricing.price(over, provider: .claude, model: "test", entry: entry)).usd - 0.000808) < 1e-12)
    }

    @Test func unknownAndInvalidUsageDoesNotBecomeZero() throws {
        let model = "claude-haiku-5-5"
        #expect(ModelPricing.price(ModelUsage(model: model), provider: .claude) == nil)
        #expect(ModelPricing.price(ModelUsage(model: model, output: -1), provider: .claude) == nil)
        #expect(ModelPricing.price(ModelUsage(model: model, cacheWrite: 1, cacheWrite1h: 2), provider: .claude) == nil)
        #expect(ModelPricing.price(ModelUsage(model: model, output: 1, reasoning: 2), provider: .claude) == nil)
        #expect(try #require(ModelPricing.price(ModelUsage(model: model, output: 0), provider: .claude)).usd == 0)
        let entry = ModelPrice(.init(1, 2))
        #expect(ModelPricing.price(ModelUsage(model: model, cacheRead: 1), provider: .claude, model: model, entry: entry) == nil)
        // Adding input counts uses Double, so huge malformed counts cannot overflow an Int sum.
        #expect(ModelPricing.price(ModelUsage(model: model, uncachedInput: Int.max, cacheRead: Int.max), provider: .claude) != nil)
    }

    @Test func usagePreservesMissingAndExplicitZeroBuckets() throws {
        let usage = ModelUsage(model: "model", uncachedInput: 0, cacheWrite: 8, cacheWrite1h: 2, output: 5, reasoning: 3)
        #expect(try JSONDecoder().decode(ModelUsage.self, from: JSONEncoder().encode(usage)) == usage)
        let minimal = try JSONDecoder().decode(ModelUsage.self, from: Data(#"{"model":"old"}"#.utf8))
        #expect(minimal.uncachedInput == nil && minimal.output == nil)
    }
}
