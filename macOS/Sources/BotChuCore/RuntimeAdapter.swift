import Foundation

/// Runtime integration boundary. Account owns a login, RunSettings owns provider/model/effort,
/// and this adapter owns the executable protocol, tools, catalog and session compatibility.
/// Dispatch stays in the tested per-runtime command/parser implementations. A future OpenCode
/// runtime supplies its own implementations here; a Pi provider never selects a CLI protocol.
public struct RuntimeAdapter: Sendable {
    public let kind: AgentKind

    public var hasProviderSelection: Bool { kind == .pi }
    public var listsModels: Bool { kind == .codex || kind == .muse || kind == .pi }
    public var takesInputMidTurn: Bool { kind == .claude }
    public var runsToolFree: Bool { kind == .claude || kind == .codex || kind == .muse }

    public func authenticationProblem(account: Account, providerID: String?, command: String,
                                      machine: Machine = .thisMac, folder: String = NSHomeDirectory(),
                                      openRouterKey: String? = nil) async -> String? {
        guard kind == .pi else { return nil }
        return await PiAuthentication.problem(account: account, providerID: providerID, command: command,
            machine: machine, folder: folder, openRouterKey: openRouterKey)
    }

    func profileEnvironment(account: Account, providerID: String?, openRouterKey: String?) -> [String: String] {
        var environment = account.runtimeEnvironment
        if account.usesLegacyOpenRouterKey(providerID: providerID), let openRouterKey, !openRouterKey.isEmpty {
            environment["OPENROUTER_API_KEY"] = openRouterKey
        }
        return environment
    }

    func unsetEnvironment(account: Account, providerID: String?) -> [String] {
        guard hasProviderSelection else { return [] }
        return account.configurationDirectory != nil ? AgentRun.modelCredentialNames.sorted()
            : account.usesLegacyOpenRouterKey(providerID: providerID) ? [] : ["OPENROUTER_API_KEY"]
    }

    public func parser() -> any StreamParser { StreamParsers.make(for: kind) }

    public func resumeID(invocation: Invocation, reported: String) -> String {
        CommandBuilder.resumeID(kind: kind, invocation: invocation, reported: reported)
    }

    /// BotChu currently opens a fresh CLI session on a provider or profile change, carrying the
    /// visible conversation into its preamble. Model/effort changes do not change this scope.
    public func canResume(from previous: RunSessionScope, to current: RunSessionScope) -> Bool {
        previous.runtime == kind && current.runtime == kind && previous == current
    }

    public func invocation(for settings: any RunSettings, prompt: String, sessionID: String?,
                           openRouterDefault: String, sailDefault: String = "", catalog: [ModelOption]? = nil,
                           openRouterKey: String? = nil, sailKey: String? = nil, liveInput: Bool = false,
                           newID: () -> String = { UUID().uuidString.lowercased() }) -> Invocation {
        var invocation = CommandBuilder.invocation(kind: kind, prompt: prompt,
            model: GenerationOptions.effectiveModel(settings.model, kind: kind,
                openRouterDefault: openRouterDefault, sailDefault: sailDefault, providerID: settings.providerID),
            sessionID: sessionID, reasoningEffort: settings.reasoningEffort, fast: settings.fastMode == true,
            openRouterKey: settings.usesLegacyOpenRouterKey ? openRouterKey : nil, sailKey: sailKey,
            liveInput: liveInput, providerID: settings.effectiveProviderID, catalog: catalog, newID: newID)
        invocation.environment.merge(profileEnvironment(account: settings.account, providerID: settings.providerID,
                                                        openRouterKey: openRouterKey)) { _, new in new }
        invocation.unsetEnvironment = unsetEnvironment(account: settings.account, providerID: settings.providerID)
        return invocation
    }
}

extension AgentKind {
    public var adapter: RuntimeAdapter { RuntimeAdapter(kind: self) }
}
