import Foundation
import Testing
@testable import BotChuCore

@Suite struct GenerationOptionsTests {
    private static let claudeProfiles = Accounts.all.filter { $0.kind == .claude } + [
        Account(id: "custom-claude", name: "Custom Claude", kind: .claude, defaultCommand: "my-claude", symbol: "sparkle")
    ]

    @Test(arguments: claudeProfiles)
    func fableIsAvailableWithoutChangingProfileDefaultsOrSelections(account: Account) throws {
        var bot = Bot(name: "Test", workspace: "/tmp/test")
        bot.selectAccount(account)
        #expect(bot.account == account)
        #expect(bot.model.isEmpty)
        #expect(bot.reasoningEffort == nil)
        #expect(QuickTasks.suggestedModel(for: account.kind) == "haiku")
        for chosen in ["", "opus", "my-custom-model", "fable", "claude-fable-5-1"] {
            let picker = ModelPickerData(kind: bot.account.kind, model: chosen, openRouterDefault: "")
            #expect(picker.selectedID == chosen)
            #expect(picker.effectiveID == chosen)
            #expect(picker.choices.first?.id == "")
            #expect(picker.choices.contains { $0.id == chosen })
            #expect(picker.matching("fable").map(\.id).sorted() == ["claude-fable-5-1", "fable"])
            let quickChoices = QuickTasks.models(for: bot.account.kind, catalog: nil, chosen: chosen)
            #expect(quickChoices.contains { $0.id == "fable" })
            #expect(quickChoices.contains { $0.id == "claude-fable-5-1" })
            if !chosen.isEmpty {
                #expect(quickChoices.contains { $0.id == chosen })
                let quick = try #require(QuickTasks(accountID: account.id, model: chosen, accounts: [account]))
                #expect(quick.account == account)
                #expect(quick.model == chosen)
            }
        }
    }

    @Test(arguments: claudeProfiles, ["fable", "claude-fable-5-1"])
    func fableSelectionsKeepHomeAndTaskSessionsAndReachTheCLI(account: Account, model: String) throws {
        var bot = Bot(name: "Test", accountID: account.id, model: "opus", reasoningEffort: .max,
                      workspace: "/tmp/test", sessionID: "home-session", sessionAccountID: account.id)
        var task = BotTask(repo: "owner/repo", checkout: "/tmp/repo", accountID: account.id, model: "sonnet",
                           reasoningEffort: .max, sessionID: "task-session", sessionAccountID: account.id)
        bot.accountProfile = account
        task.accountProfile = account
        bot.selectModel(model)
        task.selectModel(model)
        #expect(bot.model == model)
        #expect(task.model == model)
        #expect(bot.reasoningEffort == .max)
        #expect(task.reasoningEffort == .max)
        #expect(bot.resumableSessionID == "home-session")
        #expect(task.resumableSessionID == "task-session")
        #expect(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot)).model == model)
        #expect(try JSONDecoder().decode(BotTask.self, from: JSONEncoder().encode(task)).model == model)

        let conversations: [any RunSettings] = [bot, task]
        let efforts: [ReasoningEffort?] = [nil, .low, .medium, .high, .xhigh, .max]
        for settings in conversations {
            for session in [nil, settings.resumableSessionID] {
                for effort in efforts {
                    var selected = settings
                    selected.reasoningEffort = effort
                    let args = CommandBuilder.invocation(for: selected, prompt: "hello", sessionID: session,
                                                         openRouterDefault: "").arguments
                    let index = try #require(args.firstIndex(of: "--model"))
                    #expect(args[index + 1] == model)
                    if let effort {
                        let index = try #require(args.firstIndex(of: "--effort"))
                        #expect(args[index + 1] == effort.rawValue)
                    } else {
                        #expect(!args.contains("--effort"))
                    }
                    if let session {
                        let index = try #require(args.firstIndex(of: "--resume"))
                        #expect(args[index + 1] == session)
                    } else {
                        #expect(args.contains("--session-id"))
                        #expect(!args.contains("--resume"))
                    }
                }
            }
        }
    }

    @Test(arguments: AgentKind.allCases)
    func effortIsPassedOnNewAndResumedTurns(kind: AgentKind) {
        for session in [nil, "saved-session"] {
            let invocation = CommandBuilder.invocation(kind: kind, prompt: "hello", model: "custom-model",
                                                       sessionID: session, reasoningEffort: .high,
                                                       catalog: kind == .pi ? [ModelOption(id: "custom-model", name: "Custom", efforts: [.high], providerID: "openrouter")] : nil)
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
            let settings = invocation.arguments.firstIndex(of: "--settings")
            #expect(settings.map { invocation.arguments[$0 + 1] } == #"{"enableTerminalSandbox":false}"#)
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
