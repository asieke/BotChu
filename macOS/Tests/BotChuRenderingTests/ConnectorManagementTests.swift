import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// #212: a conversation's Manage opens Providers on its profile and its exact folder and host;
    /// Providers checks that folder only, folds System, hands management to the provider, checks
    /// again on return, and shows the saved check after a relaunch without checking.
    @Test func connectorManagementKeepsItsScopeAndHandsOffToTheProvider() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-connectors-\(UUID().uuidString)")
        let suite = "BotChu.Connectors.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let scout = Bot(name: "Scout", accountID: "claude-personal", workspace: root.appendingPathComponent("Scout").path)
        let other = Bot(name: "Other", accountID: "claude-personal", workspace: root.appendingPathComponent("Other").path)
        let remote = SSHHost(nickname: "Far Mac", destination: "test.invalid")
        let task = BotTask(title: "Remote work", repo: "fixture/project", checkout: "~/apps/project", branch: "feat/x",
                           folder: "~/apps/project/.claude/worktrees/feat-x", accountID: "claude-work", model: "sonnet",
                           hostID: remote.id, hostName: remote.nickname)
        for bot in [scout, other] { try BotHome(workspace: bot.workspace).save(bot) }
        try BotHome(workspace: scout.workspace).save(task)
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: scout.id, workspace: scout.workspace), Store.Entry(id: other.id, workspace: other.workspace)])
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.hosts = [remote]
        let probe = ManagementConnectorProbe()
        func makeModel() -> AppModel {
            let model = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("Not in this test.") },
                                 openRouterKey: { nil })
            model.connectorBoard.checkProfile = { kind, command, folder in await probe.check(kind, command, folder) }
            return model
        }
        let model = makeModel()
        var terminals: [ConnectorHandoffRequest] = []
        var opened: [URL] = []
        model.openTerminal = { terminals.append($0); return true }
        model.openURL = { opened.append($0); return true }
        let account = settings.account("claude-personal")

        // Manage from Scout's Home: Providers, its profile, its folder.
        model.manageConnectors(of: .home(scout.id))
        #expect(model.destination == .providers)
        #expect(model.providerSelection == "claude-personal")
        let scoutScope = try #require(model.connectorScope(of: .home(scout.id)))
        #expect(model.connectorWorkspace(for: account).scope == scoutScope)
        #expect(model.connectorWorkspace(for: account).title == "Scout")
        // Both Homes on the profile, then the home folder, are there to choose; the remote task is another profile's.
        #expect(model.connectorWorkspaces(for: account).map(\.title) == ["Scout", "Other", "Home folder"])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: AnyView(ProviderConnectorsSection(account: account).frame(width: 300)
            .environment(model).defaultAppStorage(defaults)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await waitForCalls(probe, 1)
        #expect(await probe.calls == ["claude \(scoutScope.command) \(scout.workspace)"])
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let folded = host.fittingSize.height
        // System is folded until opened, and opening it shows its three entries' rows.
        defaults.set(true, forKey: "inspector.expanded.provider.connectors.system")
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > folded + 3 * 30)
        let card = model.connectorCard(of: model.connectorWorkspace(for: account), kind: .claude)
        #expect(card.report?.listed(.system).map(\.name) == ["link", "node_repl", "Pets"])
        #expect(card.report?.listed(.tool).map(\.name) == ["Computer Use"])
        #expect(card.report?.listed(.connection).map(\.name) == ["Slack", "Gmail"])
        // The sidebar's narrowest and widest, light and dark: its rows fit, and they can be looked at.
        // So does the conversation's compact card, from the same check, without checking again.
        for (appearance, width) in [(NSAppearance.Name.aqua, 280.0), (.darkAqua, 280), (.aqua, 480), (.darkAqua, 480)] {
            host.appearance = NSAppearance(named: appearance)
            for (name, view) in [("providers", AnyView(ProviderConnectorsSection(account: account))),
                                 ("conversation", AnyView(ConnectorsSection(target: .home(scout.id))))] {
                host.rootView = AnyView(view.frame(width: width).environment(model).defaultAppStorage(defaults))
                try await Task.sleep(for: .milliseconds(150))
                host.setFrameSize(NSSize(width: width, height: host.fittingSize.height))
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width <= width + 0.5)
                if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"],
                   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let file = "connectors-\(name)-\(appearance == .aqua ? "light" : "dark")-\(Int(width)).png"
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(file))
                }
            }
        }
        #expect(await probe.calls.count == 1)
        host.rootView = AnyView(ProviderConnectorsSection(account: account).frame(width: 300).environment(model).defaultAppStorage(defaults))

        // Choosing Other checks there; Scout again shows its own check without another (A, B, A).
        model.providerConnectorWorkspace = model.connectorWorkspaces(for: account).first { $0.title == "Other" }
        try await waitForCalls(probe, 2)
        let otherScope = try #require(model.connectorScope(of: .home(other.id)))
        model.providerConnectorWorkspace = model.connectorWorkspaces(for: account).first { $0.title == "Scout" }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await probe.calls.count == 2)

        // Sign In: the profile's own `mcp login` with the raw name, in Scout's folder, in Terminal.
        let slack = try #require(card.report?.connectors.first { $0.name == "Slack" })
        let action = try #require(ConnectorAction.make(for: slack, kind: .claude, local: true))
        #expect(action == .signIn)
        model.perform(action, connector: slack, scope: scoutScope, kind: .claude)
        let request = try #require(terminals.last)
        #expect(request.scope == scoutScope)
        #expect(request.script.contains("cd -- '\(scout.workspace)' || exit 1"))
        #expect(request.script.contains("\(scoutScope.command) 'mcp' 'login' 'claude.ai Slack'"))
        // Every folder of the profile is out of date now, its list kept meanwhile.
        for scope in [scoutScope, otherScope] {
            #expect(model.connectorBoard.evidence.check(for: scope)?.invalidated == true)
            #expect(model.connectorBoard.evidence.check(for: scope)?.report?.connectors.isEmpty == false)
        }
        // Back in BotChu: the folder it was for is checked again; the other waits until it shows.
        model.connectorBoard.returned()
        try await waitForCalls(probe, 3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.calls.last == "claude \(scoutScope.command) \(scout.workspace)")
        #expect(model.connectorBoard.evidence.check(for: scoutScope)?.invalidated == false)
        #expect(model.connectorBoard.evidence.check(for: otherScope)?.invalidated == true)

        // The remote task's Manage: its own profile, folder and host; nothing runs there from here.
        let taskTarget = ChatTarget.task(task.id, of: scout.id)
        model.manageConnectors(of: taskTarget)
        #expect(model.providerSelection == "claude-work")
        let work = settings.account("claude-work")
        let remoteWorkspace = model.connectorWorkspace(for: work)
        #expect(remoteWorkspace.scope.hostID == remote.id && remoteWorkspace.scope.folder == task.folder)
        #expect(model.connectorCard(of: remoteWorkspace, kind: .claude) == .notReported)
        let before = terminals.count
        model.perform(.terminal, connector: nil, scope: remoteWorkspace.scope, kind: .claude)
        #expect(terminals.count == before)
        model.perform(.settings(.claudeAI), connector: nil, scope: remoteWorkspace.scope, kind: .claude)
        #expect(opened == [URL(string: "https://claude.ai/customize/connectors")!])
        // Leaving Providers forgets the folder Manage chose; coming back directly uses the default.
        model.destination = .agents
        model.destination = .providers
        #expect(model.connectorWorkspace(for: account).scope == scoutScope)
        #expect(model.connectorWorkspace(for: work).title == "Home folder")

        // Relaunched: the saved checks come back by scope; Scout's is fresh, so showing it checks
        // nothing, while Other, invalidated before, is checked once shown.
        model.connectorBoard.flush()
        window.contentView = nil
        let relaunched = makeModel()
        #expect(relaunched.connectorBoard.evidence.check(for: scoutScope)?.report?.connected.map(\.name) == ["Gmail", "link", "node_repl", "Pets"])
        let calls = await probe.calls.count
        await relaunched.connectorBoard.check(scoutScope, kind: .claude)
        #expect(await probe.calls.count == calls)
        await relaunched.connectorBoard.check(otherScope, kind: .claude)
        #expect(await probe.calls.count == calls + 1)
        let saved = try String(contentsOf: root.appendingPathComponent("index/connectors.json"), encoding: .utf8)
        #expect(!saved.contains(scout.workspace) && !saved.contains("claude-personal") && !saved.contains(root.path))
    }

    /// #212: a handoff while a check of the folder runs, and the return from it, never run two checks
    /// of one folder at once. The running check's answer is dropped, the list before it stays (as
    /// stale) meanwhile, and one fresh check follows it. A profile removed, or its command changed,
    /// while a return or a queued check waits has nothing run for it.
    @Test func aCheckOvertakenByManagementFinishesBeforeTheFreshOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-connectors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("connectors.json")
        let scope = ConnectorScope(accountID: "codex-personal", command: "codex-personal", folder: root.path)
        // The list checked two hours ago: shown, and due.
        let old = Date().addingTimeInterval(-7_200)
        let seed = ConnectorCheck(report: SuspendedConnectorChecker.report(["Gmail"], at: old), triedAt: old)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(ConnectorCacheFile.encode([scope.key: seed])).write(to: file)
        let checker = SuspendedConnectorChecker()
        var profiles: Set<String> = [scope.key.profile]
        let board = ConnectorBoard(file: file)
        board.profiles = { profiles }
        board.checkProfile = { _, _, _ in await checker.check() }
        func shown() -> [String]? { board.evidence.check(for: scope)?.report?.connectors.map(\.name) }
        func wait(_ what: String, until done: () async -> Bool) async throws {
            for _ in 0..<100 where !(await done()) { try await Task.sleep(for: .milliseconds(20)) }
            #expect(await done(), "\(what)")
        }

        // A check runs and doesn't answer yet; the owner is handed to the provider and comes back.
        let first = Task { await board.check(scope, kind: .codex) }
        try await wait("the first check started") { await checker.calls == 1 }
        board.handedOff(scope, kind: .codex)
        #expect(board.evidence.check(for: scope)?.invalidated == true && shown() == ["Gmail"])
        board.returned()
        // Shown or refreshed meanwhile: started apart, as the views do, so a second check would show here.
        let showing = Task { await board.check(scope, kind: .codex) }
        let refreshed = Task { await board.check(scope, kind: .codex, force: true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await checker.calls == 1)
        #expect(board.evidence.isChecking(scope))
        // The overtaken check answers: dropped, and the fresh one starts only now.
        #expect(await checker.answer("Old"))
        try await wait("the fresh check started") { await checker.calls == 2 }
        #expect(shown() == ["Gmail"] && board.evidence.check(for: scope)?.invalidated == true)
        #expect(await checker.answer("Slack"))
        try await wait("the checks ended") { !board.evidence.isChecking(scope) }
        #expect(shown() == ["Slack"] && board.evidence.check(for: scope)?.invalidated == false)
        #expect(await checker.calls == 2)
        #expect(await checker.most == 1)
        board.flush()
        #expect(ConnectorCacheFile.decode(try Data(contentsOf: file))[scope.key]?.report?.connectors.map(\.name) == ["Slack"])

        // A handoff, then the profile's command changes before the owner is back: the return runs nothing.
        board.handedOff(scope, kind: .codex)
        profiles = [ConnectorScope.profile(accountID: scope.accountID, command: "codex-personal --profile x")]
        board.prune()
        #expect(board.awaitingReturn == nil && board.evidence.check(for: scope) == nil)
        board.returned()
        let again = Task { await board.check(scope, kind: .codex) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await checker.calls == 2)

        // A check queued behind an overtaken one, for a profile removed meanwhile, doesn't run either.
        profiles = [scope.key.profile]
        let third = Task { await board.check(scope, kind: .codex) }
        try await wait("the third check started") { await checker.calls == 3 }
        board.handedOff(scope, kind: .codex)
        board.returned()
        try await Task.sleep(for: .milliseconds(100))
        #expect(board.evidence.queued == [scope.key])
        profiles = []
        board.prune()
        #expect(await checker.answer("Removed"))
        try await wait("the check ended") { !board.evidence.isChecking(scope) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await checker.calls == 3)
        #expect(await checker.most == 1)
        #expect(board.evidence.check(for: scope) == nil && !board.evidence.isChecking(scope))
        // Whatever still waits (a second check where there shouldn't be one) is answered, so none hangs.
        for _ in 0..<5 {
            while await checker.answer("Left") {}
            try await Task.sleep(for: .milliseconds(20))
        }
        for task in [first, showing, refreshed, again, third] { task.cancel() }
    }

    private func waitForCalls(_ probe: ManagementConnectorProbe, _ count: Int) async throws {
        for _ in 0..<50 where await probe.calls.count < count { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await probe.calls.count == count)
    }
}

private actor ManagementConnectorProbe {
    var calls: [String] = []

    func check(_ kind: AgentKind, _ command: String, _ folder: String) -> ConnectorReport {
        calls.append("\(kind.rawValue) \(command) \(folder)")
        return ConnectorReport(connectors: [
            Connector(name: "Slack", state: .needsAuth, origin: .claudeAI, id: "claude.ai Slack"),
            Connector(name: "Gmail", state: .connected, origin: .claudeAI, toolCount: 2, id: "claude.ai Gmail"),
            Connector(name: "Computer Use", state: .configured, origin: .mcpServer, toolCount: 0, id: "computer-use"),
            Connector(name: "link", state: .connected, origin: .mcpServer, toolCount: 4),
            Connector(name: "node_repl", state: .connected, origin: .mcpServer, toolCount: 4),
            Connector(name: "Pets", state: .connected, origin: .mcpServer, id: "pets"),
        ])
    }
}

/// A checker whose checks wait until the test answers them, counting how many run at once.
private actor SuspendedConnectorChecker {
    private(set) var calls = 0
    private(set) var most = 0
    private var running = 0
    private var waiting: [CheckedContinuation<ConnectorReport, Never>] = []

    static func report(_ names: [String], at date: Date = Date()) -> ConnectorReport {
        ConnectorReport(connectors: names.map { Connector(name: $0, state: .connected, origin: .codexApp, id: "asdk_app_\($0)") }, at: date)
    }

    func check() async -> ConnectorReport {
        calls += 1
        running += 1
        most = max(most, running)
        let report = await withCheckedContinuation { waiting.append($0) }
        running -= 1
        return report
    }

    /// Answers the oldest waiting check; false when none waits.
    func answer(_ names: String...) -> Bool {
        guard !waiting.isEmpty else { return false }
        waiting.removeFirst().resume(returning: Self.report(names))
        return true
    }
}
