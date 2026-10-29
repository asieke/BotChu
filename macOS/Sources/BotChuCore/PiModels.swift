import Foundation

public enum PiModelList {
    public static let thinkingLevels = PiRuntimeAdapter.thinkingLevels
    static func supportedEfforts(reasoning: Bool, map: [String: Any]?) -> [ReasoningEffort] { efforts(reasoning: reasoning, map: map) }
    /// Exact `getSupportedThinkingLevels`: null disables a base level; upper levels require an
    /// explicit non-null entry. Missing map entries differ from JSON null. No foreign aliases.
    public static func efforts(reasoning: Bool, map: [String: Any]?) -> [ReasoningEffort] {
        guard reasoning else { return [.off] }
        return PiRuntimeAdapter.thinkingLevels.filter { level in
            if let value = map?[level.rawValue] { return !(value is NSNull) }
            return level != .xhigh && level != .max
        }
    }

    public static func list(command: String, configurationDirectory: String?, folder: String = NSHomeDirectory(),
                            openRouterKey: String? = nil, timeout: TimeInterval = NativeModelList.timeout) async throws -> [ModelOption] {
        var environment = configurationDirectory.map { ["PI_CODING_AGENT_DIR": ($0 as NSString).expandingTildeInPath] } ?? [:]
        if let openRouterKey, !openRouterKey.isEmpty { environment["OPENROUTER_API_KEY"] = openRouterKey }
        return try await list(command: command, folder: folder, environment: environment,
            unsetEnvironment: configurationDirectory == nil ? [] : AgentRun.modelCredentialNames.sorted(), timeout: timeout)
    }

    public static func parse(_ response: [String: Any]) throws -> [ModelOption] {
        guard response["type"] as? String == "response", response["command"] as? String == "get_available_models",
              response["success"] as? Bool == true,
              let data = response["data"] as? [String: Any], let rows = data["models"] as? [[String: Any]] else {
            throw ModelListFailure.unrecognized("Pi")
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                  let provider = row["provider"] as? String, !provider.isEmpty,
                  seen.insert(provider + "\u{0}" + id).inserted else { return nil }
            return ModelOption(id: id, name: row["name"] as? String ?? id,
                efforts: efforts(reasoning: row["reasoning"] as? Bool ?? false, map: row["thinkingLevelMap"] as? [String: Any]), provider: provider)
        }.sorted { ($0.providerID ?? "", $0.name) < ($1.providerID ?? "", $1.name) }
    }

    static func launch(command: String, arguments: [String], machine: Machine, folder: String) -> (command: String, arguments: [String]) {
        guard machine.isRemote else { return (command, arguments) }
        return (Shell.quote(Machine.ssh), Machine.sshOptions + [machine.destination ?? "",
            Machine.remoteCommand(script: CommandBuilder.shellScript(command: command), arguments: arguments, in: folder)])
    }

    public static func list(command: String, machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                            environment: [String: String] = [:], unsetEnvironment: [String] = [], timeout: TimeInterval = 20) async throws -> [ModelOption] {
        try await Task.detached(priority: .utility) {
            let process = try UsageProcess(command: command, arguments: ["--mode", "rpc", "--no-session"],
                directory: URL(fileURLWithPath: machine.isRemote ? NSHomeDirectory() : folder),
                environment: machine.isRemote ? [:] : environment, unsetEnvironment: machine.isRemote ? [] : unsetEnvironment, machine: machine, remoteFolder: folder, timeout: timeout, frameLimit: 16 << 20)
            defer { process.stop() }
            try process.send(["id": "botchu-models", "type": "get_available_models"])
            while true {
                guard let response = try process.next(), response["id"] as? String == "botchu-models" else { continue }
                return try parse(response)
            }
        }.value
    }
}
