import Foundation

/// A runtime owns backend selection, discovery, credential readiness and session portability.
/// Adding another multi-provider CLI does not add provider branches at each launch site.
public protocol RuntimeAdapter: Sendable {
    var kind: AgentKind { get }
    var offersProviders: Bool { get }
    func catalog(_ scope: ModelCatalogScope, environment: [String: String]) async throws -> [ModelOption]
    func command(local: String, host: String?, remote: Bool) -> String
    func resolvedProvider(_ selection: String?) -> String?
    func usesLegacyOpenRouterKey(account: Account, provider: String?) -> Bool
    func sessionsArePortable(from: String?, to: String?) -> Bool
    func readiness(command: String, provider: String?, model: String, machine: Machine, folder: String,
                   environment: [String: String]) async -> String?
}

extension RuntimeAdapter {
    public var offersProviders: Bool { false }
    public func catalog(_ scope: ModelCatalogScope, environment: [String: String]) async throws -> [ModelOption] {
        try await NativeModelList.list(scope)
    }
    public func command(local: String, host: String?, remote: Bool) -> String { host ?? local }
    public func resolvedProvider(_ selection: String?) -> String? { nil }
    public func usesLegacyOpenRouterKey(account: Account, provider: String?) -> Bool { false }
    public func sessionsArePortable(from: String?, to: String?) -> Bool { from == to }
    public func readiness(command: String, provider: String?, model: String, machine: Machine, folder: String,
                          environment: [String: String]) async -> String? { nil }

    public func providers(in models: [ModelOption]) -> [String] {
        Array(Set(models.compactMap(\.provider))).sorted()
    }
    public func models(in catalog: [ModelOption], provider: String?) -> [ModelOption] {
        offersProviders ? catalog.filter { $0.provider == resolvedProvider(provider) } : catalog
    }
}

public struct ClaudeRuntimeAdapter: RuntimeAdapter { public let kind = AgentKind.claude }
public struct CodexRuntimeAdapter: RuntimeAdapter { public let kind = AgentKind.codex }
public struct AntigravityRuntimeAdapter: RuntimeAdapter { public let kind = AgentKind.antigravity }
public struct MuseRuntimeAdapter: RuntimeAdapter { public let kind = AgentKind.muse }
public struct SailRuntimeAdapter: RuntimeAdapter { public let kind = AgentKind.sail }

public enum RuntimeAdapters {
    public static func adapter(for kind: AgentKind) -> any RuntimeAdapter {
        switch kind {
        case .claude: ClaudeRuntimeAdapter()
        case .codex: CodexRuntimeAdapter()
        case .antigravity: AntigravityRuntimeAdapter()
        case .muse: MuseRuntimeAdapter()
        case .pi: PiRuntimeAdapter()
        case .sail: SailRuntimeAdapter()
        }
    }
}

extension RunSettings {
    public var runtimeAdapter: any RuntimeAdapter { RuntimeAdapters.adapter(for: account.kind) }
    /// The backend, distinct from the CLI family (AgentKind); never split a saved model slug.
    public var resolvedProvider: String? { runtimeAdapter.resolvedProvider(provider) }

    /// Call this before reading the Keychain. A remote runtime uses only its host's credentials.
    public func usesLegacyOpenRouterKey(remote: Bool) -> Bool {
        !remote && runtimeAdapter.usesLegacyOpenRouterKey(account: account, provider: provider)
    }

    @discardableResult
    public mutating func selectProvider(_ selection: String) -> Bool {
        guard runtimeAdapter.offersProviders, resolvedProvider != selection else { return false }
        let portable = runtimeAdapter.sessionsArePortable(from: resolvedProvider, to: selection)
        provider = selection
        model = ""
        reasoningEffort = nil
        reportedModel = nil
        if !portable { sessionID = nil; sessionAccountID = nil }
        return !portable
    }

    public func effectiveModel(openRouterDefault: String, sailDefault: String = "") -> String {
        if runtimeAdapter.offersProviders, resolvedProvider != "openrouter" { return model.trimmingCharacters(in: .whitespacesAndNewlines) }
        return GenerationOptions.effectiveModel(model, kind: account.kind, openRouterDefault: openRouterDefault, sailDefault: sailDefault)
    }

    /// The same launch policy for Home, task, job and delegated turns. A key supplied by a caller
    /// can never cross profile ownership or SSH boundaries, even if the caller passes one in error.
    public func invocation(prompt: String, model: String, sessionID: String?, remote: Bool = false,
                           openRouterKey: String? = nil, sailKey: String? = nil, liveInput: Bool = false) -> Invocation {
        CommandBuilder.invocation(kind: account.kind, prompt: prompt, model: model, sessionID: sessionID,
            reasoningEffort: reasoningEffort, fast: fastMode == true, provider: resolvedProvider,
            openRouterKey: usesLegacyOpenRouterKey(remote: remote) ? openRouterKey : nil,
            sailKey: remote ? nil : sailKey, liveInput: liveInput)
    }
}

public struct PiRuntimeAdapter: RuntimeAdapter {
    public let kind = AgentKind.pi
    public var offersProviders: Bool { true }
    public func catalog(_ scope: ModelCatalogScope, environment: [String: String]) async throws -> [ModelOption] {
        try await PiModelList.list(command: scope.command, machine: scope.machine, folder: scope.folder, environment: environment)
    }
    public func command(local: String, host: String?, remote: Bool) -> String { remote ? host ?? "pi" : local }
    public func resolvedProvider(_ selection: String?) -> String? { selection ?? "openrouter" }
    public func usesLegacyOpenRouterKey(account: Account, provider: String?) -> Bool {
        account.credentialOwnership != .runtime && resolvedProvider(provider) == "openrouter"
    }

    /// Pi's actual accepted names, used only for transport validation, never as a model's menu.
    static let thinkingLevels: [ReasoningEffort] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]

    public func readiness(command: String, provider: String?, model: String, machine: Machine, folder: String,
                          environment: [String: String]) async -> String? {
        let provider = resolvedProvider(provider)!
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Choose a model for Pi provider \(provider) before starting a turn." }
        return await Task.detached(priority: .utility) {
            do {
                let launch = PiModelList.launch(command: command,
                    arguments: ["auth", "check", "--provider", provider, "--json", "--no-refresh"], machine: machine, folder: folder)
                let process = try UsageProcess(command: launch.command, arguments: launch.arguments,
                    directory: URL(fileURLWithPath: machine.isRemote ? NSHomeDirectory() : folder),
                    environment: machine.isRemote ? [:] : environment, timeout: 20)
                defer { process.stop() }
                // Never include raw auth output/errors in UI or logs: only the status is needed.
                let data = try process.output()
                if let response = try JSONSerialization.jsonObject(with: data) as? [String: Any], response["status"] as? String == "ready" { return nil }
            } catch { }
            return "Pi provider \(provider) is not ready. Sign in to this profile on \(machine.isRemote ? "its host" : "this Mac") or configure its credentials."
        }.value
    }
}

public enum PiModelList {
    /// Exact `getSupportedThinkingLevels`: null disables a base level; upper levels require an
    /// explicit non-null entry. Missing map entries differ from JSON null. No foreign aliases.
    public static func efforts(reasoning: Bool, map: [String: Any]?) -> [ReasoningEffort] {
        guard reasoning else { return [.off] }
        return PiRuntimeAdapter.thinkingLevels.filter { level in
            if let value = map?[level.rawValue] { return !(value is NSNull) }
            return level != .xhigh && level != .max
        }
    }

    public static func parse(_ response: [String: Any]) throws -> [ModelOption] {
        guard response["success"] as? Bool == true,
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
        }
    }

    static func launch(command: String, arguments: [String], machine: Machine, folder: String) -> (command: String, arguments: [String]) {
        guard machine.isRemote else { return (command, arguments) }
        return (Shell.quote(Machine.ssh), Machine.sshOptions + [machine.destination ?? "",
            Machine.remoteCommand(script: CommandBuilder.shellScript(command: command), arguments: arguments, in: folder)])
    }

    public static func list(command: String, machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                            environment: [String: String] = [:], timeout: TimeInterval = 20) async throws -> [ModelOption] {
        try await Task.detached(priority: .utility) {
            let launch = launch(command: command, arguments: ["--mode", "rpc", "--no-session"], machine: machine, folder: folder)
            let process = try UsageProcess(command: launch.command, arguments: launch.arguments,
                directory: URL(fileURLWithPath: machine.isRemote ? NSHomeDirectory() : folder),
                environment: machine.isRemote ? [:] : environment, timeout: timeout, frameLimit: 16 << 20)
            defer { process.stop() }
            try process.send(["id": "botchu-models", "type": "get_available_models"])
            while true {
                guard let response = try process.next(), response["id"] as? String == "botchu-models" else { continue }
                return try parse(response)
            }
        }.value
    }
}
