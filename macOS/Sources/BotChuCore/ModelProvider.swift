import Foundation

/// A model service, independent of the runtime that supplies tools, protocol and session handling.
/// Pi provider IDs come from its own registry, including providers installed by the profile owner.
public struct ModelProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String {
        switch id {
        case "openrouter": "OpenRouter"
        case "radius": "Radius"
        case "kimi-coding": "Kimi Coding"
        case "moonshotai": "Moonshot AI"
        case "moonshotai-cn": "Moonshot AI (China)"
        default: id
        }
    }
    public init(id: String) { self.id = id }
    public static let openRouter = Self(id: "openrouter")

    /// Older Pi saves had no provider and always used OpenRouter. Fixed-provider runtimes have no
    /// provider setting: their adapter and signed-in profile own their model namespace.
    public static func effectiveID(_ saved: String?, runtime: AgentKind) -> String? {
        guard runtime.adapter.hasProviderSelection else { return nil }
        let value = saved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? openRouter.id : value
    }

    public static func choices(models: [ModelOption], selected: String?) -> [Self] {
        Set(models.compactMap(\.providerID) + [openRouter.id] + (selected.map { [$0] } ?? []))
            .sorted().map(Self.init)
    }
}

/// A session is owned by a runtime, profile and provider; a model/effort change can resume it.
public struct RunSessionScope: Codable, Hashable, Sendable {
    public var accountID: String
    public var runtime: AgentKind
    public var providerID: String?
    public var configurationDirectory: String?
    public var credentialSource: Account.CredentialSource?

    public init(account: Account, providerID: String?) {
        accountID = account.id
        runtime = account.kind
        self.providerID = ModelProvider.effectiveID(providerID, runtime: account.kind)
        configurationDirectory = account.configurationDirectory
        credentialSource = account.kind == .pi ? account.effectiveCredentialSource : nil
    }
}

public enum PiLaunch {
    /// Pi requires an explicit model with --provider. Never let a blank model choose a different
    /// provider from Pi's defaults. The CLI remains responsible for access and exact model support.
    public static func problem(settings: any RunSettings, effectiveModel: String) -> String? {
        guard settings.account.kind == .pi else { return nil }
        if effectiveModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a model for \(settings.modelProvider?.name ?? "Pi") before starting a turn."
        }
        return nil
    }
}
