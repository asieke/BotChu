import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// A task's Activity lists its repository's open issues (#113), from the saved Projects catalog:
    /// GitHub's count, the five most recently updated, each opening in Projects with the task kept
    /// to come back to, View All Issues and Refresh. Switching tasks switches all of it, a failed
    /// refresh keeps what was read, and showing or updating the task asks GitHub for nothing.
    @Test func taskActivityShowsItsRepositorysOpenIssues() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-task-issues-\(UUID().uuidString)")
        let domain = "BotChu.TaskIssuesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let scout = Bot(name: "Scout", emoji: "🦊", title: "Curious researcher", workspace: root.appendingPathComponent("scout").path)
        let far = SSHHost(nickname: "Far Mac", destination: "test.invalid")
        let orbit = "octocat/Orbit", botchu = "octocat/BotChu", gone = "octocat/Gone"
        // A task with no linked issue, one over SSH on an issue, and one on a repository gh doesn't list.
        let onOrbit = BotTask(for: scout, repo: orbit, checkout: root.path, work: nil, brief: "Tidy the onboarding flow")
        let onBotChu = BotTask(for: scout, repo: botchu, checkout: "~/apps/BotChu",
                               work: BotTask.Work(number: 12, title: "Speed up the sidebar", url: URL(string: "https://github.com/\(botchu)/issues/12")!,
                                                  isPullRequest: false), brief: "", host: far)
        let onGone = BotTask(for: scout, repo: gone, checkout: root.path, work: nil, brief: "Archive it")
        let home = BotHome(workspace: scout.workspace)
        try home.save(scout)
        for task in [onOrbit, onBotChu, onGone] { try home.save(task) }
        try store.saveIndex([Store.Entry(id: scout.id, workspace: scout.workspace)])
        let settings = AppSettings(defaults: defaults)
        settings.hosts = [far]
        let requests = GitHubRequests()
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { arguments, _ in
                               await requests.add(arguments)
                               return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
                           }, openWorkLookup: { _ in .failure(TaskWorktree.Failure(step: "Open work isn't read in tests", output: "")) },
                           workDetailLookup: { _, number, _ in .failure(TaskWorktree.Failure(step: "Issue #\(number) isn't read in tests", output: "")) })
        defer { app.stopAll() }
        // The saved catalog (none here) is read first; then the catalog as a sync left it.
        try await Task.sleep(for: .milliseconds(100))
        func item(_ repo: String, _ number: Int, _ title: String, hours: Double, pull: Bool = false) -> GitHubLookup.OpenItem {
            GitHubLookup.OpenItem(repo: repo, number: number, title: title, url: URL(string: "https://github.com/\(repo)/\(pull ? "pull" : "issues")/\(number)")!,
                                  isPullRequest: pull, author: "hubot", createdAt: .now.addingTimeInterval(-hours * 7200),
                                  updatedAt: .now.addingTimeInterval(-hours * 3600))
        }
        let orbitIssues = [
            item(orbit, 41, "Invite teammates by email, with a title long enough that it can't fit the narrowest sidebar", hours: 1),
            item(orbit, 7, "Dark mode for the dashboard", hours: 3),
            item(orbit, 112, "Remember the last workspace", hours: 5),
            item(orbit, 9, "Crash when the network drops during sync", hours: 8),
            item(orbit, 3, "Typo in the welcome screen", hours: 20),
            item(orbit, 2, "Older than the preview", hours: 90),
        ]
        app.projectsLogin = "octocat"
        app.repositoriesReadAt = Date()
        app.repositories = [GitHubLookup.Repo(nameWithOwner: orbit, openIssues: 7, openPullRequests: 1),
                            GitHubLookup.Repo(nameWithOwner: botchu, openIssues: 0, openPullRequests: 1)]
        app.openItems = orbitIssues + [item(orbit, 50, "A pull request isn't an issue", hours: 0.5, pull: true),
                                       item(botchu, 13, "Neither is this one", hours: 2, pull: true)]
        // GitHub counts 7 open issues in Orbit (the sync read 6) and none in BotChu.
        app.openIssueStatus = [orbit.lowercased(): OpenIssueStatus(count: 7), botchu.lowercased(): OpenIssueStatus(count: 0)]
        defaults.set(InspectorTab.activity.rawValue, forKey: InspectorTab.storageKey)

        // The section on its own, at the narrowest status sidebar.
        let host = NSHostingView(rootView: IssuesHarness(repo: orbit, app: app, defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle(_ name: String) async throws -> CGFloat {
            try await Task.sleep(for: .milliseconds(250))
            window.setContentSize(host.fittingSize)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            try captureIssues(host, name: name)
            return host.fittingSize.height
        }
        /// Clicks `x` points from the left and `fromBottom` points above the section's bottom edge.
        func click(x: CGFloat, fromBottom: CGFloat) {
            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? host.bounds.height - fromBottom : fromBottom), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
            }
        }

        let preview = app.issuePreview(of: orbit)
        #expect(preview.heading == "Issues · 7")
        #expect(preview.issues.map(\.number) == [41, 7, 112, 9, 3])
        #expect(preview.hasMore)
        let full = try await settle("task-issues-orbit")
        #expect(host.fittingSize.width <= 280)
        // Five rows of at least 34 points above View All: the first row opens that issue in Projects.
        click(x: 120, fromBottom: 36 + 6 + 5 * 34 - 17)
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.destination == .projects)
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues, item: 41))
        app.destination = nil
        // View All Issues opens the repository's Issues in Projects.
        click(x: 60, fromBottom: 18)
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.destination == .projects)
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues))
        app.destination = nil

        // Switching tasks switches the repository, its count and its rows together.
        host.rootView = IssuesHarness(repo: botchu, app: app, defaults: defaults)
        let empty = try await settle("task-issues-zero")
        #expect(app.issuePreview(of: botchu).heading == "Issues · 0")
        #expect(app.issuePreview(of: botchu).issues.isEmpty)
        #expect(empty < full - 100)
        host.rootView = IssuesHarness(repo: gone, app: app, defaults: defaults)
        _ = try await settle("task-issues-unavailable")
        #expect(app.issuePreview(of: gone).count == .unavailable)
        // Showing and switching read only what was saved.
        #expect(await requests.all.isEmpty)

        // Refresh syncs through Projects; when that fails, what was read stays, saying so.
        host.rootView = IssuesHarness(repo: orbit, app: app, defaults: defaults)
        #expect(try await settle("task-issues-orbit-again") == full)
        click(x: 268, fromBottom: 18)
        for _ in 0..<50 where app.repositoriesError == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await requests.all.contains { $0.last == "user" })
        let stale = app.issuePreview(of: orbit)
        #expect(stale.count == .known(7))
        #expect(stale.issues.count == 5)
        #expect(stale.note == "Not updated")
        #expect(try await settle("task-issues-stale") > full)
        app.repositoriesError = nil

        // Nothing read yet, while a sync reads it: no count, and not a zero.
        let saved = app.openIssueStatus
        app.openIssueStatus = nil
        app.projectsLoading = true
        _ = try await settle("task-issues-loading")
        #expect(app.issuePreview(of: orbit).count == .loading)
        #expect(app.issuePreview(of: orbit).heading == "Issues")
        app.openIssueStatus = saved
        app.projectsLoading = false

        // In the task's Activity, below Task: a running turn's updates ask GitHub for nothing.
        await requests.clear()
        let orbitTarget = ChatTarget.task(onOrbit.id, of: scout.id)
        app.show(orbitTarget)
        let inspector = NSHostingView(rootView: TaskInspector(target: orbitTarget).environment(app).defaultAppStorage(defaults))
        window.contentView = inspector
        window.setContentSize(NSSize(width: 280, height: 900))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            app.runStates[orbitTarget] = RunState(hasOutput: true, activity: .coding)
            for index in 0..<5 {
                app.append(ChatMessage(role: .assistant, text: "Working on step \(index)…"), to: orbitTarget)
                try await Task.sleep(for: .milliseconds(80))
            }
            app.runStates[orbitTarget] = nil
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
            #expect(inspector.fittingSize.width <= 380)
            try captureIssues(inspector, name: "task-activity-\(appearance == .aqua ? "light" : "dark")")
        }
        window.appearance = nil
        let remoteTarget = ChatTarget.task(onBotChu.id, of: scout.id)
        app.show(remoteTarget)
        inspector.rootView = TaskInspector(target: remoteTarget).environment(app).defaultAppStorage(defaults)
        try await Task.sleep(for: .milliseconds(250))
        try captureIssues(inspector, name: "task-activity-ssh")
        #expect(await requests.all.isEmpty)

        // Opening an issue goes to Projects and keeps the task, with its draft, to come back to.
        app.show(orbitTarget)
        app.drafts[orbitTarget] = "Half-written reply"
        let content = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.contentView = content
        window.setContentSize(NSSize(width: 1240, height: 800))
        try await Task.sleep(for: .milliseconds(250))
        app.showIssues(of: orbit.uppercased(), number: 7)
        try await Task.sleep(for: .milliseconds(300))
        try captureIssues(content, name: "task-issues-in-projects")
        #expect(app.destination == .projects)
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues, item: 7))
        #expect(app.selection == scout.id)
        #expect(app.openTask[scout.id] == onOrbit.id)
        app.show(orbitTarget)
        try await Task.sleep(for: .milliseconds(250))
        #expect(app.destination == nil)
        #expect(app.tab(of: scout.id) == orbitTarget)
        #expect(app.drafts[orbitTarget] == "Half-written reply")
        #expect(await requests.all.isEmpty)
    }

    private func captureIssues(_ view: NSView, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"],
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
    }
}

/// The Issues section alone, at the status sidebar's narrowest.
private struct IssuesHarness: View {
    let repo: String
    let app: AppModel
    let defaults: UserDefaults

    var body: some View {
        TaskIssuesSection(repo: repo)
            .frame(width: 280)
            .background(Palette.sidebar)
            .environment(app)
            .defaultAppStorage(defaults)
    }
}

/// What the stand-in gh was asked, in order.
private actor GitHubRequests {
    private(set) var all: [[String]] = []
    func add(_ arguments: [String]) { all.append(arguments) }
    func clear() { all = [] }
}
