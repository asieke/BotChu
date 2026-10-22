import Foundation

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case off, none, minimal, low, medium, high, xhigh, max, ultra

    public var title: String {
        switch self {
        case .xhigh: "Extra high"
        default: rawValue.capitalized
        }
    }
}

public struct ModelOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let efforts: [ReasoningEffort]
}

/// Starter choices verified against the installed CLIs. Custom ids remain available because
/// catalogs and account access change independently of BotChu. No login files are read.
public enum GenerationOptions {
    public static func models(for kind: AgentKind) -> [ModelOption] {
        let common: [ReasoningEffort] = [.low, .medium, .high]
        let extended = common + [.xhigh, .max]
        switch kind {
        case .claude:
            return [ModelOption(id: "opus", name: "Opus", efforts: extended),
                    ModelOption(id: "sonnet", name: "Sonnet", efforts: extended),
                    ModelOption(id: "haiku", name: "Haiku", efforts: [])]
        case .codex:
            return [ModelOption(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", efforts: extended + [.ultra]),
                    ModelOption(id: "gpt-6-astra", name: "GPT-6 Astra", efforts: extended + [.ultra]),
                    ModelOption(id: "gpt-6-sol", name: "GPT-6 Sol", efforts: extended + [.ultra]),
                    ModelOption(id: "gpt-6-luna", name: "GPT-6 Luna", efforts: extended),
                    ModelOption(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", efforts: extended + [.ultra])]
        case .antigravity:
            return [ModelOption(id: "gemini-4-argon-medium", name: "Gemini 4 Argon", efforts: common),
                    ModelOption(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash", efforts: common),
                    ModelOption(id: "claude-opus-5-5-medium", name: "Claude Opus 5.5", efforts: common),
                    ModelOption(id: "claude-sonnet-5-5-medium", name: "Claude Sonnet 5.5", efforts: common),
                    ModelOption(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B", efforts: [.medium])]
        case .muse:
            return [ModelOption(id: "muse-spark-1.3", name: "Muse Spark 1.3", efforts: [.none, .minimal] + extended + [.ultra])]
        case .pi:
            return [ModelOption(id: CommandBuilder.defaultOpenRouterModel, name: "Claude Sonnet 4.5", efforts: [.off, .minimal] + common + [.xhigh, .max])]
        }
    }

    public static func efforts(for kind: AgentKind, model: String) -> [ReasoningEffort] {
        if let option = option(for: model, kind: kind) { return option.efforts }
        switch kind {
        case .claude, .antigravity: return [.low, .medium, .high, .xhigh, .max]
        case .codex: return [.low, .medium, .high, .xhigh, .max, .ultra]
        case .muse: return [.none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra]
        case .pi: return [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        }
    }

    private static func option(for model: String, kind: AgentKind) -> ModelOption? {
        let options = models(for: kind)
        if let exact = options.first(where: { $0.id == model }) { return exact }
        guard kind == .antigravity else { return nil }
        return options.first { antigravityFamily($0.id) == antigravityFamily(model) }
    }

    private static func antigravityFamily(_ model: String) -> String {
        for suffix in ["-low", "-medium", "-high"] where model.hasSuffix(suffix) {
            return String(model.dropLast(suffix.count))
        }
        return model
    }

    /// AGY rejects a suffixed model id that disagrees with --effort. Resolve known model
    /// families to the matching variant; preserve custom ids and the default verbatim.
    public static func modelArgument(_ model: String, kind: AgentKind, effort: ReasoningEffort?) -> String {
        guard kind == .antigravity, let effort, let option = option(for: model, kind: kind),
              option.efforts.contains(effort) else { return model }
        return antigravityFamily(option.id) + "-" + effort.rawValue
    }

    public static func name(for model: String, kind: AgentKind) -> String {
        option(for: model, kind: kind)?.name ?? (model.isEmpty ? "Default model" : model)
    }

    /// The model sent on the next turn. Native CLI defaults stay unspecified; OpenRouter always
    /// receives a model, inherited from Settings or the built-in fallback when Settings is blank.
    public static func effectiveModel(_ model: String, kind: AgentKind, openRouterDefault: String) -> String {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .pi, selected.isEmpty else { return selected }
        let fallback = openRouterDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? CommandBuilder.defaultOpenRouterModel : fallback
    }
}

extension RunSettings {
    public mutating func selectModel(_ model: String) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reasoningEffort, !GenerationOptions.efforts(for: account.kind, model: self.model).contains(reasoningEffort) {
            self.reasoningEffort = nil
        }
    }

    public mutating func selectAccount(_ accountID: String) {
        selectAccount(Accounts.account(id: accountID))
    }

    public mutating func selectAccount(_ selected: Account) {
        let oldKind = account.kind
        self.accountID = selected.id
        self.accountProfile = Accounts.all.contains(where: { $0.id == selected.id }) ? nil : selected
        if account.kind != oldKind {
            model = ""
            reasoningEffort = nil
        }
    }
}
