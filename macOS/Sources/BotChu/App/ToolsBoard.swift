import Foundation
import BotChuCore

/// Skills & Tools' tools (#246): the owner's policy (`tools.json`), where the catalog's commands are
/// on This Mac, the checks of approved tools (`tool-checks.json`), and what a local turn starts
/// with: the profile that blocks the tools that are off, and what agents are told. Turns on a host
/// get neither; nothing here restricts SSH.
@MainActor @Observable final class ToolsBoard {
    private(set) var policy: ToolPolicy
    /// Why `tools.json` couldn't be read: turns on This Mac don't start until it can be, since
    /// what it would block is unknown. Nil once it reads or is saved anew.
    private(set) var unreadable: String?
    /// Why the last change couldn't be saved; nil once one is.
    private(set) var saveFailure: String?
    private(set) var catalogLocations: [String: [ToolLocation]] = [:]
    private(set) var declaredLocations: [String: ToolLocation] = [:]
    /// When the commands were last looked for; nil before the first time.
    private(set) var locatedAt: Date?
    private(set) var checks: [String: ToolCheck]
    /// The approved tools being checked, by id.
    private(set) var checking: Set<String> = []

    /// Looks for the catalog's commands and `names`; tests and reviews replace it.
    @ObservationIgnored var locate: @Sendable (_ names: [String]) async -> (catalog: [String: [ToolLocation]], declared: [String: ToolLocation]) =
        { names in
            let locator = ToolLocator(loginPath: await ToolsBoard.loginPath.value)
            return (locator.catalogLocations(), locator.firstLocations(of: names))
        }
    @ObservationIgnored var probe: ToolProbe
    @ObservationIgnored private let folder: URL?

    init(folder: URL?, probe: ToolProbe? = nil) {
        self.folder = folder
        let loginPath = ToolsBoard.loginPath
        self.probe = probe ?? ToolProbe { path, arguments, environment in
            // Under the login shell's PATH, so a tool that runs on node finds it.
            var environment = environment
            if let path = await loginPath.value { environment["PATH"] = path }
            return await ToolProbe.execute(path, arguments, environment: environment)
        }
        checks = folder.map(ToolCheck.load(from:)) ?? [:]
        do {
            policy = try folder.map { try ToolPolicy.load(from: $0) } ?? ToolPolicy()
        } catch {
            policy = ToolPolicy()
            unreadable = "BotChu couldn’t read its tool settings (\(ToolPolicy.fileName)): \(error.localizedDescription)"
        }
    }

    /// PATH as the login shell sets it, found once per launch.
    private static let loginPath = Task.detached { await ToolLocator.loginPath() }

    func inventory(declarations: [(skill: String, tools: [String])] = []) -> ToolInventory {
        ToolInventory(policy: policy, catalogLocations: catalogLocations, declaredLocations: declaredLocations, declarations: declarations)
    }

    /// Looks for the catalog's commands and the ones skills declare, without running any.
    func refresh(declaring names: [String] = []) async {
        let found = await locate(names)
        catalogLocations = found.catalog
        declaredLocations = found.declared
        locatedAt = Date()
    }

    /// Changes the policy and saves it. A policy that couldn't be read is replaced only by a
    /// change, so the owner sees it first.
    func change(_ edit: (inout ToolPolicy) -> Void) {
        var next = policy
        edit(&next)
        guard next != policy || unreadable != nil else { return }
        policy = next
        guard let folder else { return }
        do {
            try policy.save(in: folder)
            unreadable = nil
            saveFailure = nil
        } catch {
            saveFailure = "Couldn’t save the tool settings: \(error.localizedDescription)"
        }
    }

    /// Checks an approved catalog tool's version (and gh's sign-in). A failure keeps the reading
    /// before it, shown as stale. An executable the owner chose is never run.
    func check(_ tool: ApprovedTool) async {
        guard let catalog = tool.catalog, !checking.contains(tool.id) else { return }
        if locatedAt == nil { await refresh() }
        let previous = checks[tool.id] ?? ToolCheck(reading: nil, failure: nil, attemptedAt: .distantPast)
        guard let location = catalogLocations[catalog.id]?.first else {
            checks[tool.id] = previous.updated(with: .failure(ToolProbe.Failure("\(catalog.id) isn’t installed on This Mac.")), at: Date())
            return saveChecks()
        }
        checking.insert(tool.id)
        let result = await probe.check(catalog, at: location)
        checking.remove(tool.id)
        checks[tool.id] = previous.updated(with: result, at: Date())
        saveChecks()
    }

    /// Checks every approved catalog tool, at most once every ten minutes unless `force`.
    func checkAll(force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for tool in policy.tools where tool.catalog != nil {
                if !force, let last = checks[tool.id]?.attemptedAt, Date().timeIntervalSince(last) < 600 { continue }
                group.addTask { await self.check(tool) }
            }
        }
    }

    private func saveChecks() {
        guard let folder else { return }
        try? ToolCheck.save(checks.filter { id, _ in policy.approved(id) != nil }, in: folder)
    }

    // MARK: Turns

    /// The profile a turn of `kind` on This Mac starts with, for the commands where they are now;
    /// nil while the policy isn't enforced. Throws when its settings can't be read, or this Mac or
    /// the CLI can't block (`ToolSandbox.SandboxedCLI`).
    func turnProfile(for kind: AgentKind) async throws -> String? {
        if let unreadable { throw TurnBlocked(message: unreadable + " Fix or remove it in Skills & Tools first.") }
        guard policy.isEnforced else { return nil }
        catalogLocations = await locate([]).catalog
        return try ToolSandbox.profile(for: inventory(), kind: kind)
    }

    /// What a local turn is told about tools and SSH destinations; nil when there is nothing.
    func instructions() -> String? {
        inventory().agentInstructions()
    }

    /// What a resumed session is told when what it was told before no longer holds.
    static let cleared = "The command-line tools and SSH destinations you were told about earlier no longer apply."

    struct TurnBlocked: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
