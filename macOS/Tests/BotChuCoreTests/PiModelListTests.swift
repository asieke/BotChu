import Foundation
import Testing
@testable import BotChuCore

@Suite struct PiModelListTests {
    @Test func catalogUsesPiProtocolAndProfileDirectoryWithoutStartingATurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-pi-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("pi.py")
        let log = root.appendingPathComponent("request.json")
        let profile = root.appendingPathComponent("profile").path
        let fixture = root.appendingPathComponent("models.json")
        try Data(PiModelSamples.available.utf8).write(to: fixture)
        try #"""
        import json, os, sys, time
        from pathlib import Path
        request = json.loads(sys.stdin.readline())
        Path(sys.argv[1]).write_text(json.dumps({"args": sys.argv[3:], "request": request,
            "directory": os.environ.get("PI_CODING_AGENT_DIR")}))
        answer = json.loads(Path(sys.argv[2]).read_text())
        answer["id"] = request["id"]
        print(json.dumps(answer), flush=True)
        time.sleep(60)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let command = "/usr/bin/python3 " + [script.path, log.path, fixture.path].map(Shell.quote).joined(separator: " ")
        let models = try await PiModelList.list(command: command, configurationDirectory: profile, timeout: 10)
        #expect(models.count == 3)
        let asked = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])
        #expect(asked["directory"] as? String == profile)
        #expect((asked["request"] as? [String: String]) == ["id": "botchu-catalog", "type": "get_available_models"])
        #expect(asked["args"] as? [String] == ["--mode", "rpc", "--no-session", "--no-extensions", "--no-mcp", "--no-skills",
                                             "--no-prompt-templates", "--no-context-files", "--offline"])
    }

    @Test func catalogFailureDoesNotExposeRawProviderErrors() throws {
        let error: [String: Any] = ["type": "response", "command": "get_available_models", "success": false,
                                    "error": "secret-test-value"]
        #expect(throws: ModelListFailure.unrecognized("Pi")) { try PiModelList.parse(error) }
    }
}
