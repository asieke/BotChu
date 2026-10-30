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
    func effectiveModel(_ model: String, provider: String?, openRouterDefault: String, sailDefault: String) -> String
    func invocation(for settings: any RunSettings, prompt: String, model: String, sessionID: String?, remote: Bool,
                    openRouterKey: String?, sailKey: String?, liveInput: Bool, catalog: [ModelOption]?, newID: () -> String) -> Invocation
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
    public func effectiveModel(_ model: String, provider: String?, openRouterDefault: String, sailDefault: String) -> String {
        GenerationOptions.effectiveModel(model, kind: kind, openRouterDefault: openRouterDefault, sailDefault: sailDefault)
    }
    public func invocation(for settings: any RunSettings, prompt: String, model: String, sessionID: String?, remote: Bool,
                           openRouterKey: String?, sailKey: String?, liveInput: Bool, catalog: [ModelOption]?, newID: () -> String) -> Invocation {
        var invocation = CommandBuilder.invocation(kind: kind, prompt: prompt, model: model, sessionID: sessionID,
            reasoningEffort: settings.reasoningEffort, fast: settings.fastMode == true,
            openRouterKey: !remote && settings.usesLegacyOpenRouterKey ? openRouterKey : nil,
            sailKey: remote ? nil : sailKey, sailCompletionWindow: settings.effectiveSailCompletionWindow, liveInput: liveInput, providerID: settings.resolvedProvider,
            catalog: catalog, newID: newID)
        if !remote {
            invocation.environment.merge(profileEnvironment(account: settings.account, providerID: settings.providerID,
                                                            openRouterKey: openRouterKey)) { _, new in new }
            invocation.unsetEnvironment = unsetEnvironment(account: settings.account, providerID: settings.providerID)
        }
        return invocation
    }

    public func readiness(command: String, provider: String?, model: String, machine: Machine, folder: String,
                          environment: [String: String]) async -> String? { nil }

    public var hasProviderSelection: Bool { offersProviders }
    /// Every family lists its own models (#326): the CLI's own query, or Sail's API.
    public var listsModels: Bool { true }
    public var takesInputMidTurn: Bool { kind == .claude }
    public var runsToolFree: Bool { kind == .claude || kind == .codex || kind == .muse }
    public func parser() -> any StreamParser { StreamParsers.make(for: kind) }
    public func resumeID(invocation: Invocation, reported: String) -> String {
        CommandBuilder.resumeID(kind: kind, invocation: invocation, reported: reported)
    }
    public func canResume(from previous: RunSessionScope, to current: RunSessionScope) -> Bool {
        previous.runtime == kind && current.runtime == kind && previous == current
    }
    public func authenticationProblem(account: Account, providerID: String?, command: String,
                                      machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                                      openRouterKey: String? = nil) async -> String? {
        guard offersProviders else { return nil }
        return await PiAuthentication.problem(account: account, providerID: providerID, command: command,
            machine: machine, folder: folder, openRouterKey: openRouterKey)
    }
    func profileEnvironment(account: Account, providerID: String?, openRouterKey: String?) -> [String: String] {
        var environment = account.runtimeEnvironment
        if usesLegacyOpenRouterKey(account: account, provider: providerID), let openRouterKey, !openRouterKey.isEmpty {
            environment["OPENROUTER_API_KEY"] = openRouterKey
        }
        return environment
    }
    func unsetEnvironment(account: Account, providerID: String?) -> [String] {
        guard offersProviders else { return [] }
        return account.configurationDirectory != nil ? AgentRun.modelCredentialNames.sorted()
            : usesLegacyOpenRouterKey(account: account, provider: providerID) ? [] : ["OPENROUTER_API_KEY"]
    }
    public func invocation(for settings: any RunSettings, prompt: String, sessionID: String?,
                           openRouterDefault: String, sailDefault: String = "", catalog: [ModelOption]? = nil,
                           openRouterKey: String? = nil, sailKey: String? = nil, liveInput: Bool = false,
                           newID: () -> String = { UUID().uuidString.lowercased() }) -> Invocation {
        invocation(for: settings, prompt: prompt,
            model: settings.effectiveModel(openRouterDefault: openRouterDefault, sailDefault: sailDefault),
            sessionID: sessionID, remote: false, openRouterKey: openRouterKey, sailKey: sailKey,
            liveInput: liveInput, catalog: catalog, newID: newID)
    }

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
public struct SailRuntimeAdapter: RuntimeAdapter {
    public let kind = AgentKind.sail
    /// The models Settings ▸ Sail's key can use (`GET /models`), the key given as `SAIL_API_KEY` in
    /// `environment`. Sail doesn't say which efforts a model takes, so the family's stand.
    public func catalog(_ scope: ModelCatalogScope, environment: [String: String]) async throws -> [ModelOption] {
        guard !scope.machine.isRemote else { throw ModelListFailure.unsupported("Sail on a host") }
        guard let key = environment[Sail.keyVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ModelListFailure("Save a Sail API key in Settings ▸ Sail to list its models.")
        }
        do { return Self.options(try await SailClient(key: key).models()) }
        catch let failure as SailFailure { throw ModelListFailure(failure.message) }
        catch { throw ModelListFailure.failed("Sail") }
    }

    /// Sail's rows as a profile's list: names without their publisher, and each context window.
    static func options(_ models: [CatalogModel]) -> [ModelOption] {
        models.map { ModelOption(id: $0.id, name: $0.title, efforts: [], effortsKnown: false, contextLength: $0.contextLength) }
    }
}

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
        let selection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runtimeAdapter.offersProviders, !selection.isEmpty, resolvedProvider != selection else { return false }
        let portable = runtimeAdapter.sessionsArePortable(from: resolvedProvider, to: selection)
        provider = selection
        model = ""
        reasoningEffort = nil
        fastMode = nil
        reportedModel = nil
        if !portable { clearSession() }
        return !portable
    }

    public func effectiveModel(openRouterDefault: String, sailDefault: String = "") -> String {
        runtimeAdapter.effectiveModel(model, provider: provider, openRouterDefault: openRouterDefault, sailDefault: sailDefault)
    }

    /// The same launch policy for Home, task, job and delegated turns. A key supplied by a caller
    /// can never cross profile ownership or SSH boundaries, even if the caller passes one in error.
    public func invocation(prompt: String, model: String, sessionID: String?, remote: Bool = false,
                           openRouterKey: String? = nil, sailKey: String? = nil, liveInput: Bool = false, catalog: [ModelOption]? = nil) -> Invocation {
        runtimeAdapter.invocation(for: self, prompt: prompt, model: model, sessionID: sessionID, remote: remote,
                                  openRouterKey: openRouterKey, sailKey: sailKey, liveInput: liveInput, catalog: catalog,
                                  newID: { UUID().uuidString.lowercased() })
    }
}

public struct PiRuntimeAdapter: RuntimeAdapter {
    public let kind = AgentKind.pi
    public var offersProviders: Bool { true }
    public func catalog(_ scope: ModelCatalogScope, environment: [String: String]) async throws -> [ModelOption] {
        var environment = scope.machine.isRemote ? [:] : environment
        if !scope.usesLegacyOpenRouterKey { environment.removeValue(forKey: "OPENROUTER_API_KEY") }
        return try await PiModelList.list(command: scope.command, machine: scope.machine, folder: scope.folder,
            environment: environment.merging(scope.profileEnvironment) { _, scoped in scoped },
            unsetEnvironment: scope.unsetEnvironment)
    }
    public func command(local: String, host: String?, remote: Bool) -> String { remote ? host ?? "pi" : local }
    public func resolvedProvider(_ selection: String?) -> String? { ModelProvider.effectiveID(selection, runtime: .pi) }
    public func effectiveModel(_ model: String, provider: String?, openRouterDefault: String, sailDefault: String) -> String {
        guard resolvedProvider(provider) == "openrouter" else { return model.trimmingCharacters(in: .whitespacesAndNewlines) }
        return GenerationOptions.effectiveModel(model, kind: kind, openRouterDefault: openRouterDefault, sailDefault: sailDefault)
    }
    public func usesLegacyOpenRouterKey(account: Account, provider: String?) -> Bool {
        account.credentialOwnership != .runtime && resolvedProvider(provider) == "openrouter"
    }

    /// Pi's actual accepted names, used only for transport validation, never as a model's menu.
    static let thinkingLevels: [ReasoningEffort] = [.off, .minimal, .low, .medium, .high, .xhigh, .max]

    public func readiness(command: String, provider: String?, model: String, machine: Machine, folder: String,
                          environment: [String: String]) async -> String? {
        let provider = resolvedProvider(provider)!
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Choose a model for Pi provider \(provider) before starting a turn." }
        return await PiAuthentication.check(provider: provider, command: command, machine: machine, folder: folder,
            environment: machine.isRemote ? [:] : environment,
            unsetEnvironment: environment["PI_CODING_AGENT_DIR"] != nil ? AgentRun.modelCredentialNames.sorted()
                : environment["OPENROUTER_API_KEY"] == nil ? ["OPENROUTER_API_KEY"] : [])
    }
}

extension AgentKind {
    public var adapter: any RuntimeAdapter { RuntimeAdapters.adapter(for: self) }
}
