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
    /// The full name with its version, or for a moving alias the name without one.
    public let name: String
    public let efforts: [ReasoningEffort]
    public var providerID: String?
    public var provider: String? {
        get { providerID }
        set { providerID = newValue }
    }
    /// False when only a public model name/reasoning flag is known, without runtime capabilities.
    public var effortsKnown: Bool
    /// A CLI alias that moves to newer versions, such as Claude Code's `opus`, not a pinned version.
    public var moving = false
    /// Whether it has Codex's Fast tier (#249).
    public var fast = false
    /// The context window a list reported (Sail's), in tokens.
    public var contextLength: Int?

    public init(id: String, name: String, efforts: [ReasoningEffort], moving: Bool = false, fast: Bool = false,
                providerID: String? = nil, effortsKnown: Bool = true, provider: String? = nil, contextLength: Int? = nil) {
        self.id = id
        self.name = name
        self.efforts = efforts
        self.moving = moving
        self.fast = fast
        self.providerID = providerID ?? provider
        self.effortsKnown = effortsKnown
        self.contextLength = contextLength
    }
}

/// How a model choice reads wherever it is chosen or shown. The title has a version number only
/// when the ID pins one or the CLI reported the one it ran; a moving alias says "latest", and the
/// account's default says so. The detail gives the ID and, for an alias or default, what resolved.
public struct ModelLabel: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// Starter choices verified against the installed CLIs. Custom ids remain available because
/// catalogs and account access change independently of BotChu. No login files are read. A profile's
/// own list (`catalog`, #220, #248, #326) replaces its starters once read; they stand in until then.
public enum GenerationOptions {
    public static func models(for kind: AgentKind, catalog: [ModelOption]?, providerID: String? = nil) -> [ModelOption] {
        if kind == .pi {
            let provider = ModelProvider.effectiveID(providerID, runtime: kind)
            if let catalog { return catalog.filter { $0.providerID == provider || ($0.providerID == nil && provider == "openrouter") } }
            return provider == "openrouter" ? models(for: kind) : []
        }
        if NativeModelList.lists(kind), let catalog, !catalog.isEmpty { return catalog }
        return models(for: kind)
    }

    public static func models(for kind: AgentKind) -> [ModelOption] {
        let common: [ReasoningEffort] = [.low, .medium, .high]
        let extended = common + [.xhigh, .max]
        switch kind {
        case .claude:
            // Each alias, then the version it resolved to on every Claude profile (2026-10-24;
            // Fable and its efforts: Claude Code 2.1.312, 2026-10-29), which stays put when the alias moves on.
            return [ModelOption(id: "opus", name: "Claude Opus", efforts: extended, moving: true),
                    ModelOption(id: "claude-opus-5-5", name: "Claude Opus 5.5", efforts: extended),
                    ModelOption(id: "fable", name: "Claude Fable", efforts: extended, moving: true),
                    ModelOption(id: "claude-fable-5-1", name: "Claude Fable 5.1", efforts: extended),
                    ModelOption(id: "sonnet", name: "Claude Sonnet", efforts: extended, moving: true),
                    ModelOption(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", efforts: extended),
                    ModelOption(id: "haiku", name: "Claude Haiku", efforts: [], moving: true),
                    ModelOption(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", efforts: [])]
        case .codex:
            // Each lists the Fast tier (2026-10-28).
            return [ModelOption(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", efforts: extended + [.ultra], fast: true),
                    ModelOption(id: "gpt-6-astra", name: "GPT-6 Astra", efforts: extended + [.ultra], fast: true),
                    ModelOption(id: "gpt-6-sol", name: "GPT-6 Sol", efforts: extended + [.ultra], fast: true),
                    ModelOption(id: "gpt-6-luna", name: "GPT-6 Luna", efforts: extended, fast: true),
                    ModelOption(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", efforts: extended + [.ultra], fast: true)]
        case .antigravity:
            return [ModelOption(id: "gemini-4-argon-medium", name: "Gemini 4 Argon", efforts: common),
                    ModelOption(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash", efforts: common),
                    ModelOption(id: "claude-opus-5-5-medium", name: "Claude Opus 5.5", efforts: common),
                    ModelOption(id: "claude-sonnet-5-5-medium", name: "Claude Sonnet 5.5", efforts: common),
                    ModelOption(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B", efforts: [.medium])]
        case .muse:
            // As `model/list` gave them on 2026-10-28 (#248), newest first.
            let listed: [ReasoningEffort] = [.minimal] + extended
            return [ModelOption(id: "muse-wonder-1.0", name: "Muse Wonder 1.0", efforts: listed),
                    ModelOption(id: "muse-wonder-full-1.0", name: "Muse Wonder Full 1.0", efforts: listed),
                    ModelOption(id: "muse-spark-1.3", name: "Muse Spark 1.3", efforts: listed),
                    ModelOption(id: "muse-spark-1.2", name: "Muse Spark 1.2", efforts: [.minimal, .low, .medium, .high, .xhigh])]
        case .pi:
            return []
        case .sail:
            // Sail's models depend on the key: Settings ▸ Sail lists them, and any ID can be typed.
            return []
        }
    }

    public static func efforts(for kind: AgentKind, model: String, catalog: [ModelOption]? = nil, providerID: String? = nil) -> [ReasoningEffort] {
        if kind == .pi {
            return models(for: kind, catalog: catalog, providerID: providerID).first { $0.id == model }?.efforts ?? []
        }
        // A list that doesn't say (Sail's) leaves the family's.
        if let option = option(for: model, kind: kind, catalog: catalog), option.effortsKnown { return option.efforts }
        switch kind {
        case .claude, .antigravity: return [.low, .medium, .high, .xhigh, .max]
        case .codex: return [.low, .medium, .high, .xhigh, .max, .ultra]
        case .muse: return [.none, .minimal, .low, .medium, .high, .xhigh, .max, .ultra]
        case .pi: return []
        case .sail: return [.low, .medium, .high]
        }
    }

    /// Preserve a saved custom Pi choice while metadata is unavailable. It must still be valid
    /// Pi syntax; when the runtime lists the model, its exact capabilities take precedence.
    public static func effectiveEffort(_ effort: ReasoningEffort?, kind: AgentKind, model: String,
                                       catalog: [ModelOption]? = nil, providerID: String? = nil) -> ReasoningEffort? {
        guard let effort else { return nil }
        if kind == .pi {
            let option = models(for: kind, catalog: catalog, providerID: providerID).first { $0.id == model }
            if option == nil || option?.effortsKnown == false {
                return PiModelList.thinkingLevels.contains(effort) ? effort : nil
            }
        }
        return efforts(for: kind, model: model, catalog: catalog, providerID: providerID).contains(effort) ? effort : nil
    }

    /// Whether Fast can be turned on (#249): on Codex, for a model its list gives the Fast tier, and
    /// for the default or a model it doesn't list, which Codex judges itself when the turn starts.
    public static func offersFast(for kind: AgentKind, model: String, catalog: [ModelOption]? = nil) -> Bool {
        guard kind == .codex else { return false }
        return option(for: model.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, catalog: catalog)?.fast ?? true
    }

    private static func option(for model: String, kind: AgentKind, catalog: [ModelOption]? = nil) -> ModelOption? {
        let options = models(for: kind, catalog: catalog)
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
    /// families (the profile's list, else the starters) to the matching variant; preserve custom
    /// ids and the default verbatim.
    public static func modelArgument(_ model: String, kind: AgentKind, effort: ReasoningEffort?, catalog: [ModelOption]? = nil) -> String {
        guard kind == .antigravity, let effort, let option = option(for: model, kind: kind, catalog: catalog),
              option.efforts.contains(effort) else { return model }
        return antigravityFamily(option.id) + "-" + effort.rawValue
    }

    /// `model` is the ID sent to the CLI, empty for the account's default; `resolved` is the ID the
    /// CLI reported running for it (`RunSettings.resolvedModel`), if it has. Nothing here guesses a
    /// version: without a report, an alias or default shows none.
    public static func label(for model: String, kind: AgentKind, resolved: String? = nil, catalog: [ModelOption]? = nil) -> ModelLabel {
        func fullName(_ model: String, kind: AgentKind) -> String { Self.fullName(model, kind: kind, catalog: catalog) }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = resolved.flatMap { $0.isEmpty ? nil : $0 }
        // Claude Code and Muse report the model a turn ran; the others never say, so stay unresolved.
        let pending = "version unresolved"
        if model.isEmpty, kind == .sail {
            // Sail has no default of its own: the turn runs Settings ▸ Sail's model.
            return ModelLabel(title: "Default from Settings", detail: "Settings ▸ Sail" + (resolved.map { " · last ran \($0)" } ?? ""))
        }
        if model.isEmpty {
            if let resolved {
                return ModelLabel(title: "\(fullName(resolved, kind: kind)) · default",
                                  detail: "Chosen by \(kind.displayName) · last ran \(resolved)")
            }
            return ModelLabel(title: "\(kind.displayName) default", detail: "Chosen by \(kind.displayName) · \(pending)")
        }
        if let alias = movingAlias(model, kind: kind, catalog: catalog) {
            if let resolved {
                return ModelLabel(title: "\(fullName(resolved, kind: kind)) · latest",
                                  detail: "\(model) · moving alias · last ran \(resolved)")
            }
            return ModelLabel(title: "\(alias) · latest", detail: "\(model) · moving alias · \(pending)")
        }
        // An ID the CLI ran as something else is an alias too, if not one BotChu knows.
        if let resolved, resolved != model, fullName(resolved, kind: kind) != fullName(model, kind: kind) {
            return ModelLabel(title: "\(fullName(resolved, kind: kind)) · \(model)", detail: "\(model) · alias · last ran \(resolved)")
        }
        return ModelLabel(title: fullName(model, kind: kind), detail: model)
    }

    /// The full name and version of a model ID: a starter choice's name, a Claude or Muse ID spelled
    /// out (`claude-opus-5-5` is Claude Opus 5.5), else the ID itself.
    public static func fullName(_ model: String, kind: AgentKind, catalog: [ModelOption]? = nil) -> String {
        if let option = option(for: model, kind: kind, catalog: catalog), !option.moving { return option.name }
        return claudeName(model) ?? (kind == .muse ? museName(model) : nil) ?? model
    }

    /// Claude Code's aliases, which follow the newest version it knows for the account: those its
    /// list reports, the starters, and those it documents besides (any with `[1m]` for 1M context).
    private static func movingAlias(_ model: String, kind: AgentKind, catalog: [ModelOption]?) -> String? {
        guard kind == .claude else { return nil }
        if let option = catalog?.first(where: { $0.id == model }), option.moving { return option.name }
        let (base, context) = model.lowercased().hasSuffix("[1m]") ? (String(model.dropLast(4)), " (1M context)") : (model, "")
        let names = ["opus": "Claude Opus", "sonnet": "Claude Sonnet", "haiku": "Claude Haiku", "fable": "Claude Fable"]
        return names[base.lowercased()].map { $0 + context }
    }

    /// `claude-opus-5-5`, `claude-sonnet-4-5-20250929` and `claude-3-5-haiku-20241022` as Claude
    /// Opus 5.5, Claude Sonnet 4.5 and Claude Haiku 3.5; nil for anything else.
    static func claudeName(_ model: String) -> String? {
        var id = model.lowercased()
        var context = ""
        if id.hasSuffix("[1m]") { id.removeLast(4); context = " (1M context)" }
        var parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts.removeFirst() == "claude" else { return nil }
        if let last = parts.last, last.count == 8, last.allSatisfy(isDigit) { parts.removeLast() }
        let numbers = parts.filter { !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(isDigit) }
        let words = parts.filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
        guard words.count == 1, (1...2).contains(numbers.count), numbers.count + words.count == parts.count else { return nil }
        return "Claude \(words[0].capitalized) \(numbers.joined(separator: "."))\(context)"
    }

    private static func isDigit(_ character: Character) -> Bool { character.isASCII && character.isNumber }

    /// `muse-wonder-full-1.0` as Muse Wonder Full 1.0; nil for anything else.
    static func museName(_ model: String) -> String? {
        let parts = model.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0].lowercased() == "muse",
              parts.allSatisfy({ $0.allSatisfy { $0.isLetter || isDigit($0) || $0 == "." } }) else { return nil }
        return parts.map { $0.first?.isLetter == true ? $0.capitalized : $0 }.joined(separator: " ")
    }

    /// The model sent on the next turn. Native CLI defaults stay unspecified; OpenRouter always
    /// receives a model, inherited from Settings or the built-in fallback when Settings is blank.
    /// Sail inherits Settings ▸ Sail's (`sailDefault`), and has none when that is blank.
    public static func effectiveModel(_ model: String, kind: AgentKind, openRouterDefault: String, sailDefault: String = "", providerID: String? = nil) -> String {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected.isEmpty else { return selected }
        switch kind {
        case .pi:
            guard ModelProvider.effectiveID(providerID, runtime: kind) == "openrouter" else { return "" }
            let fallback = openRouterDefault.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? CommandBuilder.defaultOpenRouterModel : fallback
        case .sail:
            return sailDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        case .claude, .codex, .antigravity, .muse:
            return selected
        }
    }
}

extension RunSettings {
    /// `catalog`: the profile's own list, when read (#220), whose efforts the model offers.
    public mutating func selectModel(_ model: String, catalog: [ModelOption]? = nil) {
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        reasoningEffort = GenerationOptions.effectiveEffort(reasoningEffort, kind: account.kind, model: self.model,
                                                             catalog: catalog, providerID: providerID)
        if fastMode == true, !GenerationOptions.offersFast(for: account.kind, model: self.model, catalog: catalog) {
            fastMode = nil
        }
    }

    public mutating func selectAccount(_ accountID: String) {
        selectAccount(Accounts.account(id: accountID))
    }

    public mutating func selectAccount(_ selected: Account) {
        let oldScope = executionScope
        let oldKind = account.kind
        self.accountID = selected.id
        self.accountProfile = Accounts.all.contains(where: { $0.id == selected.id }) ? nil : selected
        if account.kind != oldKind {
            providerID = nil
            model = ""
            reasoningEffort = nil
            fastMode = nil
            sailCompletionWindow = nil
        }
        if executionScope != oldScope { invalidateSession(previous: oldScope) }
    }

    private mutating func invalidateSession(previous: RunSessionScope) {
        // Keep the previous owner as a status marker, but never a resumable ID.
        if sessionID != nil { sessionScope = sessionScope ?? previous }
        sessionID = nil
        reportedModel = nil
    }

    public mutating func clearSession() {
        sessionID = nil
        sessionAccountID = nil
        sessionScope = nil
        reportedModel = nil
    }
}
