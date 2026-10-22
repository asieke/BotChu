import Foundation
import Observation
import BotChuCore

/// Shared by Home and task pickers. Keep the last catalog on failure and retry on the next opening.
@MainActor @Observable
final class ModelCatalog {
    private(set) var models: [CatalogModel] = []
    private(set) var loading = false
    private(set) var unavailable = false
    private var checkedAt: Date?

    func load() async {
        guard !loading, checkedAt.map({ Date().timeIntervalSince($0) >= (unavailable ? 30 : 3_600) }) ?? true else { return }
        loading = true
        defer { loading = false }
        do {
            models = try await OpenRouterCatalog.fetch()
            unavailable = false
            checkedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            unavailable = true
            checkedAt = Date()
        }
    }
}
