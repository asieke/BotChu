import Foundation

/// Public model metadata only. The catalog request never needs a key or reads a CLI's login.
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

/// The picker and composer share this resolution, including inherited and unlisted model IDs.
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
    public let choices: [Choice]

    public init(kind: AgentKind, model: String, openRouterDefault: String, catalog: [CatalogModel] = []) {
        self.kind = kind
        self.selectedID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.effectiveID = GenerationOptions.effectiveModel(model, kind: kind, openRouterDefault: openRouterDefault)
        let available = kind == .pi ? catalog : []
        func name(_ id: String) -> String {
            if id.isEmpty { return "\(kind.displayName) default" }
            return available.first(where: { $0.id == id })?.title ?? GenerationOptions.name(for: id, kind: kind)
        }
        self.title = name(effectiveID)
        let defaultID = GenerationOptions.effectiveModel("", kind: kind, openRouterDefault: openRouterDefault)
        var choices = [Choice(id: "", title: kind == .pi ? "Use default from Settings" : "Use account default",
                              detail: kind == .pi ? name(defaultID) : "Chosen by \(kind.displayName)")]
        var seen: Set<String> = [""]
        // Keep the current model reachable even if it is custom, retired, or the catalog is offline.
        for id in [selectedID, defaultID] where !id.isEmpty && seen.insert(id).inserted {
            let found = available.first { $0.id == id }
            choices.append(Choice(id: id, title: name(id), detail: found?.detail ?? id))
        }
        for entry in available where seen.insert(entry.id).inserted {
            choices.append(Choice(id: entry.id, title: entry.title, detail: entry.detail))
        }
        for option in GenerationOptions.models(for: kind) where seen.insert(option.id).inserted {
            choices.append(Choice(id: option.id, title: option.name, detail: option.id))
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
