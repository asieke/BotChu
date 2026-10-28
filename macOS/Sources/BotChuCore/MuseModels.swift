import Foundation

/// Muse's `model/list` over `muse serve` (#248): the catalog of models its host accepts. Muse answers
/// from its own data folder, which keeps the provider's catalog; without one it falls back to a
/// bundled list of a single model, which isn't taken as the profile's list.
public enum MuseModelList {
    /// Catalog sources that aren't the account's own, so aren't its list. The enum is open: a new
    /// source is taken as the account's.
    static let fallbackSources: Set<String> = ["bundledCatalog", "fakeCatalog", "unresolvedCatalog"]

    /// The result's rows, in Muse's order (newest first): the model ID, its name (Muse labels a row
    /// with its ID, so that is spelled out) and the efforts it lists (the family's when it lists none).
    public static func parse(_ result: [String: Any]) throws -> [ModelOption] {
        guard let rows = result["models"] as? [[String: Any]] else { throw ModelListFailure.unrecognized("Muse") }
        if let source = result["source"] as? String, fallbackSources.contains(source) {
            throw ModelListFailure("Muse couldn’t reach its model catalog. Check its sign-in.")
        }
        var models: [ModelOption] = []
        var seen = Set<String>()
        for row in rows {
            guard let id = (row["modelId"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            let label = (row["displayLabel"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = label.isEmpty || label == id ? GenerationOptions.museName(id) ?? id : label
            let efforts: [ReasoningEffort]
            if let variants = row["variants"] as? [String] {
                var unique: [ReasoningEffort] = []
                for effort in variants.compactMap(ReasoningEffort.init) where !unique.contains(effort) { unique.append(effort) }
                efforts = unique
            } else {
                efforts = GenerationOptions.efforts(for: .muse, model: id)
            }
            models.append(ModelOption(id: id, name: name, efforts: efforts))
        }
        guard !models.isEmpty else { throw ModelListFailure.unrecognized("Muse") }
        return models
    }

    /// The profile's models, run from `folder` (the home folder) without a session log.
    public static func list(command: String, folder: String = NSHomeDirectory(),
                            timeout: TimeInterval = NativeModelList.timeout) async throws -> [ModelOption] {
        try await NativeModelList.query("Muse", command: command, arguments: ["serve", "--no-session-log"], capabilities: [:],
                                        folder: folder, timeout: timeout) { call in
            try parse(call("model/list", [:]))
        }
    }
}
