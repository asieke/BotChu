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
        if let option = models(for: kind).first(where: { $0.id == model }) { return option.efforts }
        switch kind {
        case .claude, .antigravity: return [.low, .medium, .high, .xhigh, .max]
        case .codex: return [.low, .medium, .high, .xhigh, .max, .ultra]
        case .muse: return [.none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra]
        case .pi: return [.off, .minimal, .low, .medium, .high, .xhigh, .max]
        }
    }

    public static func name(for model: String, kind: AgentKind) -> String {
        models(for: kind).first { $0.id == model }?.name ?? (model.isEmpty ? "Default model" : model)
    }
}

extension Bot {
    public mutating func selectModel(_ model: String) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reasoningEffort, !GenerationOptions.efforts(for: account.kind, model: self.model).contains(reasoningEffort) {
            self.reasoningEffort = nil
        }
    }

    public mutating func selectAccount(_ accountID: String) {
        let oldKind = account.kind
        self.accountID = accountID
        if account.kind != oldKind {
            model = ""
            reasoningEffort = nil
        }
    }
}
