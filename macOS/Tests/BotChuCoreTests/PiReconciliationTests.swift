import Foundation
import Testing
@testable import BotChuCore

@Suite struct PiReconciliationTests {
    @Test func shippedProfileProviderAndSessionFieldsSurviveCompatibilityAccessors() throws {
        let profile = try JSONDecoder().decode(Account.self, from: Data(#"{"id":"pi-new","name":"New Pi","kind":"pi","defaultCommand":"pi-wrapper","symbol":"terminal","configurationDirectory":"~/.pi/botchu-profiles/pi-new","credentialSource":"runtime"}"#.utf8))
        var bot = Bot(name: "Saved", accountID: profile.id, model: "kimi-k3", reasoningEffort: .max,
                      workspace: "/tmp/pi", sessionID: "radius-session", sessionAccountID: profile.id)
        bot.accountProfile = profile
        bot.providerID = "radius"
        bot.sessionScope = RunSessionScope(account: profile, providerID: "radius")
        bot.recordReportedModel("kimi-k3", requested: bot.model)
        let saved = try JSONEncoder().encode(bot)
        let json = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(json["providerID"] as? String == "radius")
        #expect(json["provider"] == nil)
        let restored = try JSONDecoder().decode(Bot.self, from: saved)
        #expect(restored == bot)
        #expect(restored.provider == "radius" && restored.resolvedProvider == "radius")
        #expect(restored.account.credentialOwnership == .runtime)
        #expect(restored.resumableSessionID == "radius-session" && restored.resolvedModel == "kimi-k3")
        #expect(!restored.usesLegacyOpenRouterKey(remote: false))
        var changed = restored
        changed.accountProfile?.configurationDirectory = "~/.pi/another"
        #expect(changed.resumableSessionID == nil)
        changed = restored
        changed.provider = "meta"
        #expect(changed.providerID == "meta" && changed.resolvedModel == nil && changed.resumableSessionID == nil)
    }

    @Test func remoteInvocationAndCatalogCannotCarryMacConfigurationOrCredentials() {
        let profile = Account(id: "pi-profile", name: "Profile", kind: .pi, defaultCommand: "/mac-only/pi",
                              symbol: "terminal", configurationDirectory: "~/mac-only/pi-config", credentialSource: .legacyOpenRouter)
        var bot = Bot(name: "Remote", accountID: profile.id, model: "vendor/model", workspace: "/tmp/pi")
        bot.accountProfile = profile
        let launch = bot.invocation(prompt: "hi", model: bot.model, sessionID: nil, remote: true,
                                    openRouterKey: "test-only-key")
        #expect(launch.environment.isEmpty && launch.unsetEnvironment.isEmpty)
        #expect(!bot.usesLegacyOpenRouterKey(remote: true))
        let command = bot.runtimeAdapter.command(local: profile.defaultCommand, host: nil, remote: true)
        #expect(command == "pi")
        let scope = ModelCatalogScope(accountID: profile.id, command: command, kind: .pi,
            configurationDirectory: profile.configurationDirectory, legacyOpenRouterCredential: true,
            machine: Machine(destination: "host"), folder: "~/work")
        #expect(scope.configurationDirectory == nil && scope.profileEnvironment.isEmpty && scope.unsetEnvironment.isEmpty)
        #expect(!scope.usesLegacyOpenRouterKey)
        let remote = PiModelList.launch(command: command, arguments: ["--mode", "rpc", "--no-session"], machine: scope.machine, folder: scope.folder)
        #expect(!remote.arguments.joined().contains("mac-only"))
    }

    @Test func readinessRejectsUnknownMalformedOrDifferentProviderResponses() {
        for frame: [String: Any] in [[:], ["status": "ready"], ["provider": "other", "status": "ready"],
                                     ["provider": "radius", "status": "unknown"]] {
            #expect(PiAuthentication.problem(frame, provider: "radius")?.contains("radius") == true)
        }
    }
}
