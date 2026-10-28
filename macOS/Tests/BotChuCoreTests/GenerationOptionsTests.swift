import Foundation
import Testing
@testable import BotChuCore

@Suite struct GenerationOptionsTests {
    @Test(arguments: AgentKind.allCases)
    func effortIsPassedOnNewAndResumedTurns(kind: AgentKind) {
        for session in [nil, "saved-session"] {
            let invocation = CommandBuilder.invocation(kind: kind, prompt: "hello", model: "custom-model",
                                                       sessionID: session, reasoningEffort: .high)
            let expected: [String]
            switch kind {
            case .claude, .antigravity, .sail: expected = ["--effort", "high"]
            case .codex: expected = ["-c", "model_reasoning_effort=\"high\""]
            case .muse: expected = ["--reasoning-effort", "high"]
            case .pi: expected = ["--thinking", "high"]
            }
            let args = invocation.arguments
            let index = args.firstIndex(of: expected[0])
            #expect(index != nil)
            if let index { #expect(Array(args[index...].prefix(2)) == expected) }
            #expect(args.contains("custom-model"))
            if let session { #expect(args.contains(session)) }
        }
    }

    /// Codex always gets a tier (#249): Fast, or its standard one, so a profile's own `service_tier`
    /// never decides it; no other CLI gets one.
    @Test(arguments: AgentKind.allCases)
    func fastIsPassedOnNewAndResumedCodexTurns(kind: AgentKind) {
        for session in [nil, "saved-session"] {
            for fast in [false, true] {
                let args = CommandBuilder.invocation(kind: kind, prompt: "hello", model: "custom-model", sessionID: session,
                                                     reasoningEffort: .high, fast: fast).arguments
                let tiers = args.filter { $0.hasPrefix("service_tier=") }
                if kind == .codex {
                    #expect(tiers == [fast ? #"service_tier="fast""# : #"service_tier="default""#])
                    if let index = args.firstIndex(of: tiers[0]) { #expect(args[index - 1] == "-c") }
                    #expect(args.last == "hello")
                } else {
                    #expect(tiers.isEmpty)
                }
            }
        }
    }

    @Test(arguments: [ReasoningEffort.low, .medium, .high])
    func antigravityModelVariantMatchesEffort(effort: ReasoningEffort) {
        for session in [nil, "saved-session"] {
            let invocation = CommandBuilder.invocation(kind: .antigravity, prompt: "hello",
                model: "gemini-4-argon-medium", sessionID: session, reasoningEffort: effort)
            #expect(invocation.arguments.contains("gemini-4-argon-" + effort.rawValue))
        }
        #expect(GenerationOptions.efforts(for: .antigravity, model: "gemini-4-argon-high") == [.low, .medium, .high])
        #expect(GenerationOptions.modelArgument("custom", kind: .antigravity, effort: effort) == "custom")
    }

    @Test func changingModelPreservesSessionAndClearsUnsupportedEffort() {
        var bot = Bot(name: "Test", accountID: "claude-dev", model: "opus", reasoningEffort: .high,
                      workspace: "/tmp/test", sessionID: "s", sessionAccountID: "claude-dev")
        bot.selectModel(" sonnet ")
        #expect(bot.model == "sonnet")
        #expect(bot.reasoningEffort == .high)
        #expect(bot.resumableSessionID == "s")
        bot.selectModel("haiku")
        #expect(bot.reasoningEffort == nil)
    }

    @Test func providerChangeClearsProviderSpecificSettings() {
        var bot = Bot(name: "Test", accountID: "claude-dev", model: "opus", reasoningEffort: .high, workspace: "/tmp/test")
        bot.selectAccount("claude-personal")
        #expect(bot.model == "opus")
        bot.selectAccount("google")
        #expect(bot.model.isEmpty)
        #expect(bot.reasoningEffort == nil)
    }

    @Test func savedBotsWithoutEffortStillLoad() throws {
        let bot = Bot(name: "Test", workspace: "/tmp/test")
        let encoder = JSONEncoder()
        let data = try encoder.encode(bot)
        #expect(!String(decoding: data, as: UTF8.self).contains("reasoningEffort"))
        #expect(try JSONDecoder().decode(Bot.self, from: data).reasoningEffort == nil)
        var changed = bot
        changed.reasoningEffort = .high
        #expect(try JSONDecoder().decode(Bot.self, from: encoder.encode(changed)) == changed)
    }

    @Test func unknownOldSubagentCompletionIsNotInvented() {
        var message = ChatMessage(role: .tool, toolName: "invoke_subagent", toolState: .failed)
        #expect(message.displayedToolState(for: .antigravity) == .interrupted)
        #expect(message.displayedToolState(for: .claude) == .failed)
        message.toolOutput = "Launch failed"
        #expect(message.displayedToolState(for: .antigravity) == .failed)
    }
}
