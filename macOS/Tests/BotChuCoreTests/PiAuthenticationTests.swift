import Foundation
import Testing
@testable import BotChuCore

@Suite struct PiAuthenticationTests {
    @Test func realReadinessRepliesNameTheMissingProviderWithoutKeepingRawDetails() throws {
        let ready = try #require(JSONSerialization.jsonObject(with: Data(PiModelSamples.authReady.utf8)) as? [String: Any])
        let missing = try #require(JSONSerialization.jsonObject(with: Data(PiModelSamples.authMissing.utf8)) as? [String: Any])
        #expect(PiAuthentication.problem(ready, provider: "radius") == nil)
        #expect(PiAuthentication.problem(missing, provider: "kimi-coding") == "Sign in to Kimi Coding in this Pi profile before starting a turn.")
        #expect(PiAuthentication.problem(missing, provider: "radius") == nil)
        #expect(PiAuthentication.problem(["provider": "radius", "status": "invalid", "reason": "secret-test-value"],
                                        provider: "radius") == "Pi could not use the Radius login. Sign in again in this profile.")
        #expect(PiAuthentication.problem(["provider": "unknown", "status": "not_ready", "reason": "provider_not_found"],
                                        provider: "unknown") == "Pi does not recognize provider unknown. Check this profile's provider ID.")
    }

    @Test(arguments: [false, true], [false, true])
    func checksTheProfilesOwnLoginWithoutRequestingOrLoggingCredentials(legacy: Bool, remote: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-pi-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("pi.py")
        let log = root.appendingPathComponent("request.json")
        let profile = root.appendingPathComponent("profile").path
        try #"""
        import json, os, sys
        from pathlib import Path
        Path(sys.argv[1]).write_text(json.dumps({"args": sys.argv[2:],
            "directory": os.environ.get("PI_CODING_AGENT_DIR"),
            "keyMatches": os.environ.get("OPENROUTER_API_KEY") == "test-only-key"}))
        print(json.dumps({"provider": "openrouter", "status": "not_ready", "reason": "credentials_not_configured"}), flush=True)
        sys.exit(1)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let command = "/usr/bin/python3 " + [script.path, log.path].map(Shell.quote).joined(separator: " ")
        let account = Account(id: "test", name: "Test Pi", kind: .pi, defaultCommand: command, symbol: "terminal",
                              configurationDirectory: profile, credentialSource: legacy ? .legacyOpenRouter : .runtime)
        let problem = await account.runtime.adapter.authenticationProblem(account: account, providerID: "openrouter",
            command: command, machine: remote ? FakeSSH.machine : .thisMac, folder: root.path, openRouterKey: "test-only-key")
        #expect(problem == "Sign in to OpenRouter in this Pi profile before starting a turn.")
        let asked = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])
        if remote { #expect(asked["directory"] as? String != profile) }
        else { #expect(asked["directory"] as? String == profile) }
        #expect(asked["keyMatches"] as? Bool == (legacy && !remote))
        #expect(asked["args"] as? [String] == ["auth", "check", "--provider", "openrouter", "--json", "--no-refresh"])
    }

    @Test func anOlderWrapperStillLetsTheTurnHandleItsLogin() async {
        let account = Accounts.account(id: "openrouter")
        #expect(await PiAuthentication.problem(account: account, providerID: "radius", command: "/usr/bin/false", timeout: 1) == nil)
        #expect(await AgentKind.muse.adapter.authenticationProblem(account: Accounts.account(id: "muse"),
            providerID: nil, command: "/a/nonexistent/command") == nil)
    }
}
