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
        invocation.environment.merge(settings.account.runtimeEnvironment) { _, new in new }
        if hasProviderSelection {
            invocation.unsetEnvironment = settings.account.configurationDirectory != nil
                ? AgentRun.modelCredentialNames.sorted()
                : settings.usesLegacyOpenRouterKey ? [] : ["OPENROUTER_API_KEY"]
        }
        return invocation
    }
}

extension AgentKind {
    public var adapter: RuntimeAdapter { RuntimeAdapter(kind: self) }
}
