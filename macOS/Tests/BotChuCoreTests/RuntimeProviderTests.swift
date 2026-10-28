import Foundation
import Testing
@testable import BotChuCore

@Suite struct RuntimeProviderTests {
    private func pi() -> Bot {
        Bot(name: "Identity stays", instructions: "Remember who you are", accountID: "openrouter",
            model: "anthropic/claude-sonnet-4.5", reasoningEffort: .high, workspace: "/tmp/provider-test",
            sessionID: "legacy-session", sessionAccountID: "openrouter")
    }

    @Test func legacyPiDecodesAsOpenRouterWithoutRewritingItsIdentityOrSession() throws {
        let bot = pi()
        let saved = try JSONEncoder().encode(bot)
        #expect(!String(decoding: saved, as: UTF8.self).contains("providerID"))
        let restored = try JSONDecoder().decode(Bot.self, from: saved)
        #expect(restored == bot)
        #expect(restored.account.id == "openrouter")
        #expect(restored.account.name == "Pi")
        #expect(restored.account.runtime == .pi)
        #expect(restored.effectiveProviderID == "openrouter")
        #expect(restored.resumableSessionID == "legacy-session")
        #expect(restored.model == bot.model && restored.reasoningEffort == .high)
        let profile = try JSONDecoder().decode(Account.self, from: Data(#"{"id":"old-pi","name":"Old Pi","kind":"pi","defaultCommand":"pi-old","symbol":"terminal"}"#.utf8))
        #expect(profile.configurationDirectory == nil)
        #expect(profile.defaultCommand == "pi-old")
    }

    @Test func changingProviderResetsGenerationAndSessionButKeepsBotIdentity() throws {
        var bot = pi()
        let original = bot
        bot.recordReportedModel("resolved", requested: bot.model)
        bot.selectProvider("radius")
        #expect(bot.id == original.id && bot.name == original.name && bot.instructions == original.instructions && bot.workspace == original.workspace)
        #expect(bot.accountID == "openrouter" && bot.effectiveProviderID == "radius")
        #expect(bot.model.isEmpty && bot.reasoningEffort == nil && bot.reportedModel == nil)
        #expect(bot.sessionID == nil && bot.resumableSessionID == nil)
        #expect(try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot)) == bot)
        bot.selectAccount("codex-work")
        #expect(bot.providerID == nil && bot.effectiveProviderID == nil)
        bot.selectProvider("radius")
        #expect(bot.providerID == nil)
    }

    @Test func sessionsBindToRuntimeProfileAndProviderWhileModelChangesCanResume() {
        var bot = pi()
        bot.providerID = "radius"
        #expect(bot.resumableSessionID == nil) // an old, unscoped session was OpenRouter's
        bot.sessionScope = bot.executionScope
        #expect(bot.resumableSessionID == "legacy-session")
        bot.selectModel("kimi-k3", catalog: [ModelOption(id: "kimi-k3", name: "Kimi K3", efforts: [.high], providerID: "radius")])
        #expect(bot.resumableSessionID == "legacy-session")
        #expect(bot.reasoningEffort == .high)
        bot.providerID = "meta"
        #expect(bot.resumableSessionID == nil)
        bot.providerID = "radius"
        bot.selectAccount(Account(id: "pi-private", name: "Pi private", kind: .pi, defaultCommand: "pi-private", symbol: "terminal"))
        #expect(bot.providerID == "radius" && bot.model == "kimi-k3" && bot.reasoningEffort == .high)
        #expect(bot.resumableSessionID == nil && bot.sessionID == nil)
    }

    @Test func everyDelegatedSurfaceCopiesProviderWithoutCopyingTheHomeSession() throws {
        var bot = pi()
        bot.selectProvider("radius")
        bot.model = "kimi-k3"
        bot.reasoningEffort = .high
        bot.sessionID = "new-session"; bot.sessionAccountID = bot.accountID; bot.sessionScope = bot.executionScope
        let task = BotTask(for: bot, repo: "owner/repo", checkout: "/tmp/repo", work: nil, brief: "Work")
        let child = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Work", brief: "Work", workingDirectory: "/tmp/repo")
        let job = JobRunsOn(bot)
        #expect(task.providerID == "radius" && task.model == "kimi-k3" && task.sessionID == nil)
        #expect(child.providerID == "radius" && child.reasoningEffort == .high && child.sessionID == nil)
        #expect(job.providerID == "radius" && job.applied(to: bot).sessionID == nil)
        #expect(job.unavailable(accounts: Accounts.all, catalog: [CatalogModel(id: "unrelated", name: "OpenRouter model")]) == nil)
        #expect(try JSONDecoder().decode(BotTask.self, from: JSONEncoder().encode(task)) == task)
        #expect(try JSONDecoder().decode(SubagentRun.self, from: JSONEncoder().encode(child)) == child)
        #expect(try JSONDecoder().decode(JobRunsOn.self, from: JSONEncoder().encode(job)) == job)
        var old = task; old.providerID = nil; old.sessionID = "old-task"; old.sessionAccountID = "openrouter"
        #expect(try JSONDecoder().decode(BotTask.self, from: JSONEncoder().encode(old)).resumableSessionID == "old-task")
        let legacyJob = try JSONDecoder().decode(JobRunsOn.self, from: Data(#"{"accountID":"openrouter","model":"old/model","reasoningEffort":"high"}"#.utf8))
        #expect(legacyJob.providerID == nil && legacyJob.model == "old/model" && legacyJob.reasoningEffort == .high)
    }

    @Test func onlyTheLegacyProfileOnOpenRouterReceivesItsKey() {
        var bot = pi()
        func launch(_ bot: Bot) -> Invocation {
            CommandBuilder.invocation(for: bot, prompt: "Hello", sessionID: nil, openRouterDefault: "default/model", openRouterKey: "test-only-key")
        }
        #expect(launch(bot).environment["OPENROUTER_API_KEY"] == "test-only-key")
        bot.selectProvider("radius"); bot.model = "kimi-k3"
        #expect(launch(bot).environment["OPENROUTER_API_KEY"] == nil)
        #expect(launch(bot).arguments.contains("radius"))
        bot.selectAccount(Account(id: "pi-private", name: "Private", kind: .pi, defaultCommand: "pi", symbol: "terminal",
                                  configurationDirectory: "/tmp/private-pi"))
        bot.selectProvider("openrouter")
        let invocation = launch(bot)
        #expect(invocation.environment == ["PI_CODING_AGENT_DIR": "/tmp/private-pi"])
        #expect(!invocation.arguments.contains("test-only-key"))
        #expect(invocation.unsetEnvironment.contains("OPENROUTER_API_KEY"))
        #expect(invocation.unsetEnvironment.contains("META_API_KEY"))
        let shell = AgentRun.profileShellPrefix(invocation.environment, unset: invocation.unsetEnvironment)
        #expect(shell.contains("export PI_CODING_AGENT_DIR='/tmp/private-pi'"))
        #expect(!shell.contains("test-only-key"))
        let job = JobLaunch.invocation(for: bot, prompt: "Job", openRouterDefault: "default/model", openRouterKey: "test-only-key")
        #expect(job.environment == invocation.environment)
        #expect(bot.account.loginCommand(command: "pi") == "PI_CODING_AGENT_DIR='/tmp/private-pi' pi")
    }

    @Test func loginShellCannotReplaceTheSelectedCredentialOrLeakItToACustomProfile() throws {
        for legacy in [false, true] {
            let environment = legacy ? ["OPENROUTER_API_KEY": "test-only-selected"] : ["PI_CODING_AGENT_DIR": "/tmp/profile with spaces"]
            let prefix = AgentRun.profileShellPrefix(environment, unset: legacy ? [] : AgentRun.modelCredentialNames.sorted())
            #expect(!prefix.contains("test-only-selected"))
            let check = #"import os,sys; expected=sys.argv[1]=='legacy'; key=os.environ.get('OPENROUTER_API_KEY'); ok=(key=='test-only-selected') if expected else (key is None and os.environ.get('PI_CODING_AGENT_DIR')=='/tmp/profile with spaces' and os.environ.get('META_API_KEY') is None); sys.exit(0 if ok and 'BOTCHU_LAUNCH_OPENROUTER_API_KEY' not in os.environ else 1)"#
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", "export OPENROUTER_API_KEY=test-only-global META_API_KEY=test-only-global PI_CODING_AGENT_DIR=/wrong; "
                + prefix + "exec /usr/bin/python3 -c " + Shell.quote(check) + (legacy ? " legacy" : " custom")]
            process.environment = AgentRun.childEnvironment(ProcessInfo.processInfo.environment).merging(AgentRun.profileEnvironment(environment)) { $1 }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    @Test func piProviderDefaultsCatalogsAndEffortsNeverBleedAcrossProviders() throws {
        let frame = try #require(JSONSerialization.jsonObject(with: Data(PiModelSamples.available.utf8)) as? [String: Any])
        let models = try PiModelList.parse(frame)
        #expect(Set(models.compactMap(\.providerID)) == ["meta", "radius", "garcon"])
        #expect(models.allSatisfy { !$0.efforts.contains(.max) && !$0.efforts.contains(.xhigh) })
        let picker = ModelPickerData(kind: .pi, model: "", openRouterDefault: "openrouter/default",
                                    catalog: [CatalogModel(id: "wrong", name: "Wrong")], native: models, providerID: "radius")
        #expect(picker.effectiveID.isEmpty)
        #expect(picker.choices.map(\.id) == ["", "kimi-k3"])
        #expect(picker.choices.last?.title == "Kimi K3")
        var bot = pi(); bot.selectProvider("radius")
        #expect(PiLaunch.problem(settings: bot, effectiveModel: picker.effectiveID) != nil)
        bot.model = "kimi-k3"; bot.reasoningEffort = .max
        let max = CommandBuilder.invocation(for: bot, prompt: "Hi", sessionID: nil, openRouterDefault: "other", catalog: models)
        #expect(!max.arguments.contains("--thinking"))
        bot.reasoningEffort = .high
        let high = CommandBuilder.invocation(for: bot, prompt: "Hi", sessionID: "resume", openRouterDefault: "other", catalog: models)
        #expect(high.arguments.contains("--thinking") && high.arguments.contains("high") && high.arguments.contains("resume"))
        #expect(GenerationOptions.efforts(for: .pi, model: "unknown", catalog: models, providerID: "radius").isEmpty)
        let scope = ModelCatalogScope(accountID: "a", command: "pi", kind: .pi, configurationDirectory: "/tmp/a")
        let other = ModelCatalogScope(accountID: "a", command: "pi", kind: .pi, configurationDirectory: "/tmp/b")
        #expect(scope.key != other.key)
        let data = try #require(NativeCatalogFile.encode([scope.key: NativeCatalog(models: models, checkedAt: .now)]))
        #expect(NativeCatalogFile.decode(data)[scope.key]?.models == models)
    }

    @Test func piCatalogRetainsOnlyMetadataAndKeepsEqualModelIDsInSeparateProviders() throws {
        let frame: [String: Any] = ["type": "response", "command": "get_available_models", "success": true,
            "data": ["models": [
                ["id": "same-model", "provider": "one", "name": "One", "reasoning": false,
                 "headers": ["Authorization": "secret-test-marker"], "apiKey": "secret-test-marker"],
                ["id": "same-model", "provider": "two", "name": "Two", "reasoning": true]
            ]]]
        let listed = try PiModelList.parse(frame)
        #expect(listed.count == 2)
        #expect(listed.first?.efforts.isEmpty == true)
        let saved = try #require(NativeCatalogFile.encode(["test": NativeCatalog(models: listed, checkedAt: .now)]))
        #expect(!String(decoding: saved, as: UTF8.self).contains("secret-test-marker"))
        let choices = ModelPickerData(kind: .pi, model: "same-model", openRouterDefault: "", native: listed, providerID: "two")
        #expect(choices.choices.map(\.id) == ["", "same-model"])
        #expect(choices.title == "Two")
    }

    @Test func nonOpenRouterUsageNeverAsksForTheLegacyKeyBalance() async throws {
        let pi = Accounts.account(id: "openrouter")
        let legacy = UsageRequest(account: pi, command: "pi", openRouterKeyRevision: 5)
        let radius = UsageRequest(account: pi, command: "pi", openRouterKeyRevision: 5, providerID: "radius")
        #expect(legacy.usesLegacyOpenRouterKey && legacy.credentialRevision == 5)
        #expect(!radius.usesLegacyOpenRouterKey && radius.credentialRevision == 0)
        #expect(legacy != radius)
        #expect(legacy == UsageRequest(account: pi, command: "pi", openRouterKeyRevision: 5, providerID: "openrouter"))
        do {
            _ = try await ProviderUsageClient.read(radius, openRouterKey: "must-not-be-sent")
            Issue.record("Pi provider usage should not use OpenRouter")
        } catch let failure as UsageFailure {
            #expect(failure.message.contains("provider allowance"))
        }
        let remote = UsageRequest(account: pi, command: "pi", openRouterKeyRevision: 5, remote: true)
        #expect(!remote.usesLegacyOpenRouterKey && remote.credentialRevision == 0)
        do {
            _ = try await ProviderUsageClient.read(remote, openRouterKey: "must-not-be-sent")
            Issue.record("Remote usage should not use a local credential")
        } catch let failure as UsageFailure {
            #expect(failure.message.contains("host’s own login"))
        }
        let env = AgentRun.childEnvironment(["PI_CODING_AGENT_DIR": "/other/profile", "GEMINI_API_KEY": "test",
                                             "META_API_KEY": "test", "OPENROUTER_API_KEY": "test", "PATH": "/bin", "GH_TOKEN": "tool-token"])
        #expect(env == ["PATH": "/bin", "GH_TOKEN": "tool-token"])
    }
}
