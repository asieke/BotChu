import AppKit
import Observation
import BotChuCore

/// Shared by Home and task pickers. Keep the last catalog on failure and retry on the next opening.
@MainActor @Observable
final class ModelCatalog {
    private(set) var models: [CatalogModel] = []
    private(set) var loading = false
    private(set) var unavailable = false
    private var checkedAt: Date?

    /// Each local Codex or Muse profile's own list (#220, #248), shared by every picker set to it and
    /// saved between launches in `model-catalogs.json`. A list a day old is checked again at launch, on
    /// wake, by the hourly look while BotChu runs, and as a picker opens; Refresh models checks at once.
    private(set) var native = NativeCatalogBook()
    /// What lists a profile's models; nil starts no check (tests, and review copies without
    /// `BOTCHU_CODEX_MODELS`), so the lists saved before, or the starters, stay.
    @ObservationIgnored var listModels: (@Sendable (ModelCatalogScope) async throws -> [ModelOption])?
    /// The local profiles in Settings whose CLIs list their models, each with its command.
    @ObservationIgnored var scopes: @MainActor () -> [ModelCatalogScope] = { [] }
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private let writes = DispatchQueue(label: "BotChu.model-catalogs", qos: .utility)
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var wake: NSObjectProtocol?

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

    /// Reads the saved lists; with `listModels`, also looks for stale ones shortly after launch, on
    /// wake and hourly.
    func configure(file: URL?, scopes: @escaping @MainActor () -> [ModelCatalogScope],
                   listModels: (@Sendable (ModelCatalogScope) async throws -> [ModelOption])?) {
        self.file = file
        self.scopes = scopes
        self.listModels = listModels
        native = NativeCatalogBook(saved: file.flatMap { try? Data(contentsOf: $0) }.map(NativeCatalogFile.decode) ?? [:])
        if native.retain(Set(scopes().map(\.key))) { save() }
        guard listModels != nil else { return }
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStale() }
        }
        watch = Task { [weak self] in
            // After launch's own work, not during it.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                self?.refreshStale()
                do { try await Task.sleep(for: .seconds(3_600)) } catch { break }
            }
        }
    }

    func models(for scope: ModelCatalogScope?) -> [ModelOption]? { scope.flatMap(native.models(for:)) }

    func status(for scope: ModelCatalogScope) -> NativeCatalogStatus { native.status(for: scope) }

    /// Checks every profile in Settings whose list is due, dropping those of profiles gone since.
    func refreshStale() {
        let current = scopes()
        if native.retain(Set(current.map(\.key))) { save() }
        for scope in current where native.isDue(scope) {
            Task { await refresh(scope) }
        }
    }

    /// Checks `scope`'s list when it is due (`force`: Refresh models). Asking while a check of it runs
    /// starts nothing; a failure keeps the list there was.
    func refresh(_ scope: ModelCatalogScope, force: Bool = false) async {
        guard let listModels, scopes().contains(scope), let token = native.begin(scope, force: force) else { return }
        let result: Result<[ModelOption], ModelListFailure>
        do { result = .success(try await listModels(scope)) }
        catch let failure as ModelListFailure { result = .failure(failure) }
        catch { result = .failure(ModelListFailure("\(scope.kind.displayName) couldn’t list its models.")) }
        if native.finish(scope, token: token, result) { save() }
    }

    /// Writes the lists off the main thread, in order; a list that can't be written stays in memory.
    private func save() {
        guard let file, let data = NativeCatalogFile.encode(native.saved) else { return }
        writes.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Waits for the writes queued so far (tests).
    func flush() { writes.sync {} }
}

extension AppModel {
    /// The profile on this Mac whose own list a conversation's or job's pickers show; nil for a
    /// family that doesn't list its models, and for a task on a host, which a list read here says
    /// nothing about.
    func modelCatalogScope(for settings: any RunSettings) -> ModelCatalogScope? {
        (settings as? BotTask)?.isRemote == true ? nil : modelCatalogScope(for: settings.account)
    }

    func modelCatalogScope(for account: Account) -> ModelCatalogScope? {
        NativeModelList.lists(account.kind)
            ? ModelCatalogScope(accountID: account.id, command: settings.command(for: account), kind: account.kind) : nil
    }

    /// The list `settings`' pickers choose from in place of the starters, once read.
    func nativeModels(for settings: any RunSettings) -> [ModelOption]? {
        modelCatalog.models(for: modelCatalogScope(for: settings))
    }

    /// Reads the saved lists and, in the real app or a review copy with sample lists, keeps them fresh.
    func configureModelCatalogs(file: URL, live: Bool) {
        modelCatalog.configure(file: file, scopes: { [weak self] in
            self.map { model in model.settings.accounts.compactMap(model.modelCatalogScope(for:)) } ?? []
        }, listModels: DevHooks.modelLists ?? (live ? { @Sendable scope in try await NativeModelList.list(scope) } : nil))
    }
}
