import AppKit
import Observation
import BotChuCore

/// Every profile's own model list (#220, #248, #326), Sail's and Pi's providers' included, shared by
/// every picker set to it (Home, task, inspector, bot editor, jobs, Agents, Quick tasks) and saved
/// between launches in `model-catalogs.json`. A list a day old is checked again at launch, on wake,
/// by the hourly look while BotChu runs, and as a picker opens; Refresh models (or an agent's
/// `botchu-models refresh`) checks at once. A failed check keeps the last list, else the starters.
@MainActor @Observable
final class ModelCatalog {
    private(set) var native = NativeCatalogBook()
    /// What lists a profile's models; nil starts no check (tests, and review copies without
    /// `BOTCHU_CODEX_MODELS`), so the lists saved before, or the starters, stay.
    @ObservationIgnored var listModels: (@Sendable (ModelCatalogScope) async throws -> [ModelOption])?
    /// The profiles in Settings, each with its command, and those of hosts that open tasks run on.
    @ObservationIgnored var scopes: @MainActor () -> [ModelCatalogScope] = { [] }
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private let writes = DispatchQueue(label: "BotChu.model-catalogs", qos: .utility)
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var wake: NSObjectProtocol?

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
        guard let listModels, (scope.machine.isRemote || scopes().contains(scope)), let token = native.begin(scope, force: force) else { return }
        let result: Result<[ModelOption], ModelListFailure>
        do { result = .success(try await listModels(scope)) }
        catch let failure as ModelListFailure { result = .failure(failure) }
        catch { result = .failure(ModelListFailure("\(scope.kind.displayName) couldn’t list its models.")) }
        if native.finish(scope, token: token, result) { save() }
    }

    /// Checks every list now, or those of the profiles in `accountIDs`, as Refresh models does each
    /// (`botchu-models refresh`), and waits for them; returns the scopes checked. A check already
    /// running is waited for rather than started again.
    func refreshAll(accountIDs: Set<String>? = nil) async -> [ModelCatalogScope] {
        let chosen = scopes().filter { accountIDs?.contains($0.accountID) ?? true }
        let checks = chosen.map { scope in Task { await refresh(scope, force: true) } }
        for check in checks { await check.value }
        let deadline = Date().addingTimeInterval(60)
        while chosen.contains(where: { native.status(for: $0).checking }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return chosen
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
    func preparePiModels(for settings: any RunSettings) async {
        guard settings.runtimeAdapter.offersProviders, settings.reasoningEffort != nil,
              let scope = modelCatalogScope(for: settings) else { return }
        await modelCatalog.refresh(scope)
    }

    /// The selected profile's own list. A task or run on a host has its host's, read there with the
    /// command its turns run; this Mac's command, configuration and credentials never describe it.
    func modelCatalogScope(for settings: any RunSettings) -> ModelCatalogScope? {
        if let task = settings as? BotTask, task.isRemote {
            return modelCatalogScope(for: settings.account, hostID: task.hostID, folder: task.folder ?? "~")
        }
        if let run = settings as? SubagentRun, let hostID = run.hostID {
            return modelCatalogScope(for: settings.account, hostID: hostID, folder: run.workingDirectory)
        }
        return modelCatalogScope(for: settings.account)
    }

    func modelCatalogScope(for account: Account) -> ModelCatalogScope? {
        NativeModelList.lists(account.kind)
            ? ModelCatalogScope(accountID: account.id, command: settings.command(for: account), kind: account.kind, configurationDirectory: account.configurationDirectory,
                usesLegacyOpenRouterKey: RuntimeAdapters.adapter(for: account.kind).usesLegacyOpenRouterKey(account: account, provider: nil),
                credentialRevision: settings.sailUsageCredentialRevision) : nil
    }

    /// A host's own list of the profile (#326). Pi's is its folder's, as its providers can be; the
    /// others' are the host's home folder's. Sail's list is its API's, not a host's, so none.
    private func modelCatalogScope(for account: Account, hostID: UUID?, folder: String) -> ModelCatalogScope? {
        let adapter = RuntimeAdapters.adapter(for: account.kind)
        guard adapter.listsModels, account.kind != .sail, let host = settings.host(hostID) else { return nil }
        return ModelCatalogScope(accountID: account.id,
            command: adapter.command(local: settings.command(for: account), host: host.command(for: account), remote: true),
            kind: account.kind, machine: Machine(destination: host.destination), folder: adapter.offersProviders ? folder : "~")
    }

    /// The lists kept fresh: each profile's in Settings, and each host's that an open task runs on.
    func modelCatalogScopes() -> [ModelCatalogScope] {
        var keys = Set<String>()
        let local = settings.accounts.compactMap(modelCatalogScope(for:))
        let hosts = tasks.values.joined().filter { $0.isRemote && !$0.isArchived }.compactMap { modelCatalogScope(for: $0) }
        return (local + hosts).filter { keys.insert($0.key).inserted }
    }

    /// The list `settings`' pickers choose from in place of the starters, once read.
    func nativeModels(for settings: any RunSettings) -> [ModelOption]? {
        modelCatalog.models(for: modelCatalogScope(for: settings)).map { settings.runtimeAdapter.models(in: $0, provider: settings.provider) }
    }

    /// `botchu-models refresh` (#326): checks the lists of the profiles asked for, or every list, now,
    /// and reports each as its picker shows it: the list read, else the starters.
    func refreshModelLists(_ request: ModelRefreshRequest) async -> ModelRefreshResult {
        let asked = Set(request.accountIDs)
        let listing = Set(modelCatalogScopes().map(\.accountID))
        if let unknown = asked.subtracting(listing).sorted().first {
            return ModelRefreshResult(id: request.id, errorMessage: "no profile \(unknown) lists models; the profiles are "
                + listing.sorted().joined(separator: ", "))
        }
        let checked = await modelCatalog.refreshAll(accountIDs: asked.isEmpty ? nil : asked)
        return ModelRefreshResult(id: request.id, entries: checked.map { scope in
            let status = modelCatalog.status(for: scope)
            let host = scope.machine.destination.map { destination in settings.hosts.first { $0.destination == destination }?.nickname ?? destination }
            let listed = modelCatalog.models(for: scope) ?? GenerationOptions.models(for: scope.kind)
            return ModelRefreshEntry(accountID: scope.accountID, name: settings.account(scope.accountID).name + (host.map { " on \($0)" } ?? ""),
                                     models: listed.map(\.id), status: status.summary(at: Date()), failure: status.failure)
        })
    }

    /// The key a list is read with, read only for the list that needs it: the legacy OpenRouter one
    /// for such a Pi profile, Sail's for Sail's; none for a host's, or any other.
    func modelListKeys(for scope: ModelCatalogScope) -> [String: String] {
        guard !scope.machine.isRemote else { return [:] }
        if scope.usesLegacyOpenRouterKey, let key = openRouterKey() { return ["OPENROUTER_API_KEY": key] }
        if scope.kind == .sail, let key = sailKey() { return [Sail.keyVariable: key] }
        return [:]
    }

    /// Reads the saved lists and, in the real app or a review copy with sample lists, keeps them fresh.
    func configureModelCatalogs(file: URL, live: Bool) {
        modelCatalog.configure(file: file, scopes: { [weak self] in self?.modelCatalogScopes() ?? [] },
                               listModels: DevHooks.modelLists ?? (live ? { @Sendable [weak self] scope in
            let keys = await self?.modelListKeys(for: scope) ?? [:]
            return try await RuntimeAdapters.adapter(for: scope.kind).catalog(scope, environment: keys)
        } : nil))
    }
}
