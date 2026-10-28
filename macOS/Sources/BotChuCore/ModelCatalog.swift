import Foundation

/// Model metadata shared by OpenRouter's public list and Sail's key-scoped list.
public struct CatalogModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int?

    public init(id: String, name: String, contextLength: Int? = nil) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
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
            return CatalogModel(id: entry.id, name: entry.name, contextLength: entry.context_length)
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
    public let selectedID: String
    public let effectiveID: String
    public let title: String
    /// What the title stands for: the ID and, for an alias or default, what it resolved to.
    public let detail: String
    public let choices: [Choice]

    /// `resolved` is the model the CLI reported for this selection (`RunSettings.resolvedModel`).
    /// `native` is a Codex profile's own list once read (#220): it replaces the starters, which stand
    /// in only while it is nil; the selection and the default stay choices either way.
    /// `catalog` is Sail's list; Pi uses its selected profile/provider's `native` list.
    public init(kind: AgentKind, model: String, openRouterDefault: String, sailDefault: String = "",
                catalog: [CatalogModel] = [], native: [ModelOption]? = nil, resolved: String? = nil, provider: String? = nil) {
        self.kind = kind
        let native = native.map { RuntimeAdapters.adapter(for: kind).models(in: $0, provider: provider) }
        let selectedID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedID = selectedID
        let usesPiDefault = kind == .pi && (provider ?? "openrouter") == "openrouter"
        self.effectiveID = kind == .pi && !usesPiDefault ? selectedID : GenerationOptions.effectiveModel(model, kind: kind, openRouterDefault: openRouterDefault, sailDefault: sailDefault)
        let usesSettingsDefault = usesPiDefault || kind == .sail
        let available = kind == .sail ? catalog : []
        func label(_ id: String) -> ModelLabel {
            if let found = available.first(where: { $0.id == id }) { return ModelLabel(title: found.title, detail: found.detail) }
            return GenerationOptions.label(for: id, kind: kind, resolved: id == selectedID ? resolved : nil, catalog: native)
        }
        let current = kind == .pi && !usesPiDefault && effectiveID.isEmpty
            ? ModelLabel(title: "Choose model", detail: "Choose a model for \(provider ?? "this provider")") : label(effectiveID)
        self.title = current.title
        self.detail = usesSettingsDefault && selectedID.isEmpty && !effectiveID.isEmpty ? "Default from Settings · \(current.detail)" : current.detail
        let defaultID = kind == .pi && !usesPiDefault ? "" : GenerationOptions.effectiveModel("", kind: kind, openRouterDefault: openRouterDefault, sailDefault: sailDefault)
        var choices = [Choice(id: "", title: kind == .pi && !usesPiDefault ? "Choose a model" : usesSettingsDefault ? "Use default from Settings" : "Use account default",
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
        for option in GenerationOptions.models(for: kind, catalog: native) where seen.insert(option.id).inserted {
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
