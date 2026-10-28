import Foundation

/// Pi's own RPC protocol, independent of Codex/Muse's JSON-RPC and of its turn stream parser.
/// No model turn, credentials, extensions, project context or MCP connections are requested.
public enum PiModelList {
    public static func list(command: String, configurationDirectory: String? = nil, folder: String = NSHomeDirectory(),
                            timeout: TimeInterval = NativeModelList.timeout) async throws -> [ModelOption] {
        try await Task.detached(priority: .utility) {
            let environment = configurationDirectory.map { ["PI_CODING_AGENT_DIR": ($0 as NSString).expandingTildeInPath] } ?? [:]
            let process: UsageProcess
            do {
                process = try UsageProcess(command: command,
                    arguments: ["--mode", "rpc", "--no-session", "--no-extensions", "--no-mcp", "--no-skills",
                                "--no-prompt-templates", "--no-context-files", "--offline"],
                    directory: URL(fileURLWithPath: folder), environment: environment,
                    unsetEnvironment: configurationDirectory == nil ? [] : AgentRun.modelCredentialNames.sorted(), timeout: timeout, frameLimit: 8 << 20)
            } catch { throw ModelListFailure.failed("Pi") }
            defer { process.stop() }
            do {
                try process.send(["id": "botchu-catalog", "type": "get_available_models"])
                while true {
                    guard let frame = try process.next(), frame["id"] as? String == "botchu-catalog" else { continue }
                    return try parse(frame)
                }
            } catch let failure as ModelListFailure { throw failure }
            catch { throw ModelListFailure.failed("Pi") }
        }.value
    }

    public static func parse(_ frame: [String: Any]) throws -> [ModelOption] {
        guard frame["type"] as? String == "response", frame["command"] as? String == "get_available_models",
              frame["success"] as? Bool == true, let data = frame["data"] as? [String: Any],
              let entries = data["models"] as? [[String: Any]] else { throw ModelListFailure.unrecognized("Pi") }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let provider = entry["provider"] as? String, !provider.isEmpty,
                  let id = entry["id"] as? String, !id.isEmpty,
                  seen.insert(provider + "\0" + id).inserted else { return nil }
            // Pi's basic levels work for reasoning models. Extended levels depend on the exact
            // model adapter; a reasoning boolean alone is not evidence for xhigh or max.
            let efforts: [ReasoningEffort] = entry["reasoning"] as? Bool == true ? [.off, .minimal, .low, .medium, .high] : []
            return ModelOption(id: id, name: entry["name"] as? String ?? id, efforts: efforts, providerID: provider)
        }.sorted { ($0.providerID ?? "", $0.name) < ($1.providerID ?? "", $1.name) }
    }
}
