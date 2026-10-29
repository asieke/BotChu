import Foundation

/// Model metadata shared by OpenRouter's public list and Sail's key-scoped list.
public struct CatalogModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int?
    public var supportsReasoning: Bool?

    public init(id: String, name: String, contextLength: Int? = nil, supportsReasoning: Bool? = nil) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.supportsReasoning = supportsReasoning
    }

    public var title: String {
        // OpenRouter names often repeat their publisher ("Anthropic: Claude Sonnet …").
        let parts = name.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : name
    }

    public var detail: String {
        guard let contextLength, contextLength > 0 else { return id }
        let count = contextLength >= 1_000_000
            ? "\((Double(contextLength) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M"
            : "\(contextLength / 1_000)K"
        return "\(id) · \(count) context"
    }
}

public enum OpenRouterCatalog {
    public static func fetch() async throws -> [CatalogModel] {
        let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text&supported_parameters=tools&limit=1000")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogError.unavailable }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> [CatalogModel] {
        struct Response: Decodable { let data: [Entry] }
        struct Entry: Decodable {
            let id: String
            let name: String
            let context_length: Int?
            let supported_parameters: [String]?
            let architecture: Architecture?
        }
        struct Architecture: Decodable { let output_modalities: [String]? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var seen = Set<String>()
        let models = response.data.compactMap { entry -> CatalogModel? in
            guard !entry.id.isEmpty, !entry.name.isEmpty,
                  entry.supported_parameters?.contains("tools") != false,
                  entry.architecture?.output_modalities?.contains("text") != false,
                  seen.insert(entry.id).inserted else { return nil }
            return CatalogModel(id: entry.id, name: entry.name, contextLength: entry.context_length,
                                supportsReasoning: entry.supported_parameters.map { $0.contains("reasoning") || $0.contains("reasoning_effort") })
        }
        guard !models.isEmpty else { throw CatalogError.unavailable }
        return models.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public enum CatalogError: Error { case unavailable }
}

/// The picker and composer share this resolution, including inherited and unlisted model IDs. A
/// moving alias or default shows a version only once its CLI has reported it (`resolved`).
public struct ModelPickerData: Sendable {
    public struct Choice: Identifiable, Equatable, Sendable {
        /// Empty means inherit the account's default, not a literal model ID.
        public let id: String
        public let title: String
        public let detail: String
    }

    public let kind: AgentKind
    public let providerID: String?
    public let selectedID: String
    public let effectiveID: String
    public let title: String
    /// What the title stands for: the ID and, for an alias or default, what it resolved to.
    public let detail: String
    public let choices: [Choice]

    /// `resolved` is the model the CLI reported for this selection (`RunSettings.resolvedModel`).
    /// `native` is a Codex profile's own list once read (#220): it replaces the starters, which stand
    /// in only while it is nil; the selection and the default stay choices either way.
    /// `catalog` is the list for this kind: OpenRouter's for Pi, Sail's for Sail.
    public init(kind: AgentKind, model: String, openRouterDefault: String, sailDefault: String = "",
                catalog: [CatalogModel] = [], native: [ModelOption]? = nil, resolved: String? = nil, providerID: String? = nil, provider: String? = nil) {
        self.kind = kind
        let providerID = providerID ?? provider
        self.providerID = ModelProvider.effectiveID(providerID, runtime: kind)
        let selectedID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedID = selectedID
        self.effectiveID = GenerationOptions.effectiveModel(model, kind: kind, openRouterDefault: openRouterDefault, sailDefault: sailDefault, providerID: providerID)
        let usesSettingsDefault = (kind == .pi && self.providerID == "openrouter") || kind == .sail
        let available = kind == .sail ? catalog : []
        let native = kind == .pi ? native.map { GenerationOptions.models(for: kind, catalog: $0, providerID: providerID) } : native
        func label(_ id: String) -> ModelLabel {
            if kind == .pi, id.isEmpty, ModelProvider.effectiveID(providerID, runtime: kind) != "openrouter" {
                return ModelLabel(title: "Choose model", detail: "Choose a model for \(ModelProvider.effectiveID(providerID, runtime: kind) ?? "Pi")")
            }
            if let found = available.first(where: { $0.id == id }) { return ModelLabel(title: found.title, detail: found.detail) }
            if kind == .pi, let found = native?.first(where: { $0.id == id }) { return ModelLabel(title: found.name, detail: id) }
            return GenerationOptions.label(for: id, kind: kind, resolved: id == selectedID ? resolved : nil, catalog: native)
        }
        let current = label(effectiveID)
        self.title = current.title
        self.detail = usesSettingsDefault && selectedID.isEmpty && !effectiveID.isEmpty ? "Default from Settings · \(current.detail)" : current.detail
        let defaultID = GenerationOptions.effectiveModel("", kind: kind, openRouterDefault: openRouterDefault, sailDefault: sailDefault, providerID: providerID)
        var choices = [Choice(id: "", title: usesSettingsDefault ? "Use default from Settings" : kind == .pi ? "Choose model" : "Use account default",
                              detail: usesSettingsDefault && !defaultID.isEmpty ? label(defaultID).title : label("").detail)]
        var seen: Set<String> = [""]
        // Keep the current model reachable even if it is custom, retired, or the catalog is offline.
        for id in [selectedID, defaultID] where !id.isEmpty && seen.insert(id).inserted {
            let found = label(id)
            choices.append(Choice(id: id, title: found.title, detail: found.detail))
        }
        for entry in available where seen.insert(entry.id).inserted {
            choices.append(Choice(id: entry.id, title: entry.title, detail: entry.detail))
        }
        for option in GenerationOptions.models(for: kind, catalog: native, providerID: providerID) where seen.insert(option.id).inserted {
            let found = label(option.id)
            choices.append(Choice(id: option.id, title: found.title, detail: found.detail))
        }
        self.choices = choices
    }

    public func matching(_ query: String) -> [Choice] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return choices.filter { choice in
            let text = "\(choice.title) \(choice.detail) \(choice.id)"
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }
}
