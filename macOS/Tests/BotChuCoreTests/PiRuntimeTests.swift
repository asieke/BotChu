import Foundation
import Testing
@testable import BotChuCore

@Suite struct PiRuntimeTests {
    func legacy(_ id: String = "custom-pi") throws -> Account {
        try JSONDecoder().decode(Account.self, from: Data("""
        {"id":"\(id)","name":"Old Pi","kind":"pi","defaultCommand":"pi-profile","symbol":"terminal"}
        """.utf8))
    }

    @Test func nilProviderMigratesEveryOldProfileWithoutSplittingModelOrLosingSession() throws {
        for account in [Accounts.account(id: "openrouter"), try legacy()] {
            var bot = Bot(name: "Old", accountID: account.id, model: "vendor/model", reasoningEffort: .high,
                          workspace: "/tmp/old", sessionID: "saved", sessionAccountID: account.id)
            bot.accountProfile = account
            let restored = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
            #expect(restored.provider == nil)
            #expect(restored.resolvedProvider == "openrouter")
            #expect(restored.model == "vendor/model")
            #expect(restored.reasoningEffort == .high)
            #expect(restored.resumableSessionID == "saved")
            #expect(restored.usesLegacyOpenRouterKey(remote: false))
            #expect(!restored.usesLegacyOpenRouterKey(remote: true))
        }
    }

    @Test func credentialsBelongToProfileProviderAndHost() throws {
        var bot = Bot(name: "Pi", workspace: "/tmp/pi")
        let fresh = Account(id: "new", name: "New", kind: .pi, defaultCommand: "my-pi", symbol: "terminal")
        for account in [Accounts.account(id: "openrouter"), try legacy(), fresh] {
            bot.selectAccount(account)
            for provider in [nil, "openrouter", "moonshotai"] as [String?] {
                bot.provider = provider
                for remote in [false, true] {
                    let invocation = bot.invocation(prompt: "hi", model: "chosen/model", sessionID: nil,
                                                    remote: remote, openRouterKey: "test-key")
                    let expectsKey = account.credentialOwnership != .runtime && !remote && (provider ?? "openrouter") == "openrouter"
                    #expect((invocation.environment["OPENROUTER_API_KEY"] != nil) == expectsKey)
                    let index = try #require(invocation.arguments.firstIndex(of: "--provider"))
                    #expect(invocation.arguments[index + 1] == (provider ?? "openrouter"))
                    #expect(invocation.arguments.contains("chosen/model"))
                }
            }
        }
        #expect(try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(fresh)).credentialOwnership == .runtime)
        #expect(!UsageRequest(account: fresh, command: "pi", openRouterKeyRevision: 7).usesLegacyOpenRouterKey)
        #expect(UsageRequest(account: fresh, command: "pi", openRouterKeyRevision: 7).credentialRevision == 0)
    }

    @Test func allowanceNeverReadsMacCredentialsForRemoteOrOtherBackends() async {
        let account = Accounts.account(id: "openrouter")
        let legacy = UsageRequest(account: account, command: "pi", openRouterKeyRevision: 7)
        let radius = UsageRequest(account: account, command: "pi", openRouterKeyRevision: 7, providerID: "radius")
        let remote = UsageRequest(account: account, command: "must-not-run", openRouterKeyRevision: 7, remote: true)
        #expect(legacy.usesLegacyOpenRouterKey && legacy.credentialRevision == 7)
        #expect(!radius.usesLegacyOpenRouterKey && radius.credentialRevision == 0)
        #expect(!remote.usesLegacyOpenRouterKey && remote.credentialRevision == 0)
        #expect(legacy != radius && legacy != remote)
        for request in [radius, remote] {
            do {
                _ = try await ProviderUsageClient.read(request, openRouterKey: "must-not-use")
                Issue.record("A scoped-out allowance must not make a request")
            } catch let failure as UsageFailure {
                #expect(failure.message.contains(request.remote == true ? "host" : "Pi manages"))
            } catch { Issue.record("Expected a plain unavailable allowance reason") }
        }
    }

    @Test func providerChangeResetsSessionAndSelectionButSameProviderKeepsThem() {
        var bot = Bot(name: "Pi", accountID: "openrouter", model: "vendor/model", reasoningEffort: .high,
                      workspace: "/tmp/pi", sessionID: "saved", sessionAccountID: "openrouter")
        let same = bot.selectProvider("openrouter")
        #expect(!same)
        #expect(bot.resumableSessionID == "saved")
        let changed = bot.selectProvider("moonshotai")
        #expect(changed)
        #expect(bot.model.isEmpty)
        #expect(bot.reasoningEffort == nil)
        #expect(bot.resumableSessionID == nil)
        #expect(bot.effectiveModel(openRouterDefault: "old/model").isEmpty)
    }

    @Test func nullMapIsExactAndForeignEffortsAreNeverMapped() throws {
        let response: [String: Any] = ["success": true, "data": ["models": [
            ["id": "kimi-k3", "provider": "moonshotai", "reasoning": true,
             "thinkingLevelMap": ["off": NSNull(), "minimal": NSNull(), "low": "low", "medium": NSNull(),
                                  "high": "high", "xhigh": NSNull(), "max": "max"]],
            ["id": "kimi-k3", "provider": "another", "reasoning": false],
            ["id": "ordinary", "provider": "moonshotai", "reasoning": true,
             "thinkingLevelMap": ["none": "off", "ultra": "max"]]
        ]]]
        let models = try PiModelList.parse(response)
        #expect(models[0].efforts == [.low, .high, .max])
        #expect(models[1].efforts == [.off])
        #expect(models[2].efforts == [.off, .minimal, .low, .medium, .high])
        let adapter = RuntimeAdapters.adapter(for: .pi)
        #expect(adapter.providers(in: models) == ["another", "moonshotai"])
        let filtered = adapter.models(in: models, provider: "moonshotai")
        #expect(filtered.map(\.id) == ["kimi-k3", "ordinary"])
        let picker = ModelPickerData(kind: .pi, model: "", openRouterDefault: "vendor/old", native: models, provider: "another")
        #expect(picker.choices.map(\.id) == ["", "kimi-k3"])
        #expect(picker.effectiveID.isEmpty && picker.title == "Choose model")
        var bot = Bot(name: "Pi", accountID: "openrouter", reasoningEffort: .max, workspace: "/tmp/pi")
        bot.selectModel("kimi-k3", catalog: filtered)
        #expect(bot.reasoningEffort == .max)
        #expect(GenerationOptions.efforts(for: .pi, model: "unlisted").isEmpty)
    }

    @Test func providerTravelsToJobsTasksAndDelegations() throws {
        var bot = Bot(name: "Pi", accountID: "openrouter", model: "kimi-k3", workspace: "/tmp/pi")
        bot.provider = "moonshotai"
        let choice = try JSONDecoder().decode(JobRunsOn.self, from: JSONEncoder().encode(JobRunsOn(bot)))
        #expect(choice.provider == "moonshotai")
        #expect(choice.applied(to: bot).resolvedProvider == "moonshotai")
        let run = SubagentRun(rootBotID: bot.id, depth: 1, targetBot: bot, title: "Test", brief: "test", workingDirectory: "/tmp")
        #expect(run.resolvedProvider == "moonshotai")
    }

    @Test func capturedMetadataKeepsOpenRouterEffortsWithoutInventingDirectProviderMapping() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(PiModelSamples.openRouter.utf8)) as? [String: Any])
        let models = try PiModelList.parse(object)
        #expect(models[0].efforts == [.off, .minimal, .low, .medium, .high])
        #expect(models[1].efforts == [.off, .low, .high, .max])
        #expect(models[1].id == "moonshotai/kimi-k3")
        #expect(models[1].provider == "openrouter")
    }

    @Test func remoteCommandAndScopeNeverUseMacConfiguration() {
        let adapter = RuntimeAdapters.adapter(for: .pi)
        #expect(adapter.command(local: "PI_CODING_AGENT_DIR=/Mac/profile /Mac/bin/pi", host: nil, remote: true) == "pi")
        #expect(adapter.command(local: "/Mac/bin/pi", host: "host-pi", remote: true) == "host-pi")
        let scope = ModelCatalogScope(accountID: "legacy", command: "pi", kind: .pi,
            machine: Machine(destination: "host"), folder: "~/project", usesLegacyOpenRouterKey: true)
        #expect(!scope.usesLegacyOpenRouterKey)
        let launch = PiModelList.launch(command: "pi", arguments: ["auth", "check", "--provider", "moonshotai", "--json", "--no-refresh"],
            machine: scope.machine, folder: scope.folder)
        #expect(launch.arguments.last?.contains("--credentials") == false)
        #expect(launch.arguments.last?.contains("/Mac/") == false)
        #expect(launch.arguments.last?.contains("moonshotai") == true)
    }

    @Test func emptyRealRPCSampleIsValid() throws {
        // Captured from the selected profile's Pi 1.4.0 RPC, 2026-10-28, with no configured credentials.
        let sample = #"{"id":"catalog","type":"response","command":"get_available_models","success":true,"data":{"models":[]}}"#
        #expect(try PiModelList.parse(JSONSerialization.jsonObject(with: Data(sample.utf8)) as! [String: Any]).isEmpty)
    }

    @Test func profileRPCAndAuthUseSafeCommandsAndOnlyExplicitEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = root.appendingPathComponent("pi-profile")
        let arguments = root.appendingPathComponent("arguments")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(Shell.quote(arguments.path))
        if [ "$1" = auth ]; then
            test "$OPENROUTER_API_KEY" = test-only || exit 1
            printf '%s\\n' '{"status":"ready"}'
        else
            read request
            printf '%s\\n' '{"id":"botchu-models","success":true,"data":{"models":[{"id":"model","name":"Selected profile model","provider":"custom-backend","reasoning":false}]}}'
        fi
        """
        try script.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let models = try await PiModelList.list(command: Shell.quote(command.path), folder: root.path)
        #expect(models.map(\.provider) == ["custom-backend"])
        #expect(try String(contentsOf: arguments, encoding: .utf8) == "--mode\nrpc\n--no-session\n")
        let adapter = RuntimeAdapters.adapter(for: .pi)
        let ready = await adapter.readiness(command: Shell.quote(command.path), provider: "custom-backend", model: "model",
            machine: .thisMac, folder: root.path, environment: ["OPENROUTER_API_KEY": "test-only"])
        #expect(ready == nil)
        #expect(try String(contentsOf: arguments, encoding: .utf8) == "auth\ncheck\n--provider\ncustom-backend\n--json\n--no-refresh\n")
        let missing = await adapter.readiness(command: Shell.quote(command.path), provider: "custom-backend", model: "model",
            machine: .thisMac, folder: root.path, environment: [:])
        #expect(missing?.contains("custom-backend") == true)
    }

    @Test func authReadinessNamesProviderAndRequiresModel() async {
        let adapter = RuntimeAdapters.adapter(for: .pi)
        let issue = await adapter.readiness(command: "false", provider: "moonshotai", model: "", machine: .thisMac,
                                            folder: "/tmp", environment: [:])
        #expect(issue == "Choose a model for Pi provider moonshotai before starting a turn.")
    }
}
