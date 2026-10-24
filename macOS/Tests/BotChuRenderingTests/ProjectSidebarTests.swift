import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// Projects shows active projects unless told otherwise, and the repository selected in a sidebar:
    /// its overview, its open issues and pull requests, each one read in full, and Fix All and Review
    /// All, which open New Task with a brief for one task that fans out to sub-agents.
    @Test func projectSidebarShowsTabsDetailsAndFanOutTasks() async throws {
        _ = NSApplication.shared
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-project-sidebar-\(UUID().uuidString)")
        let domain = "BotChu.ProjectSidebarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let scout = Bot(name: "Scout", emoji: "🦊", title: "Curious researcher", workspace: root.appendingPathComponent("scout").path)
        let builder = Bot(name: "Builder", emoji: "🛠️", title: "Builds small, complete changes", workspace: root.appendingPathComponent("builder").path)
        let orbit = "octocat/Orbit", botchu = "octocat/BotChu"
        // Builder already works on Orbit #3, and reviews BotChu #8.
        let onIssue = BotTask(for: builder, repo: orbit, checkout: root.path, work: BotTask.Work(number: 3, isPullRequest: false, repo: orbit), brief: "")
        let onReview = BotTask(for: builder, repo: botchu, checkout: root.path, work: BotTask.Work(number: 8, isPullRequest: true, repo: botchu),
                               brief: "", review: .review)
        for bot in [scout, builder] { try BotHome(workspace: bot.workspace).save(bot) }
        try BotHome(workspace: builder.workspace).save(onIssue)
        try BotHome(workspace: builder.workspace).save(onReview)
        try store.saveIndex([Store.Entry(id: scout.id, workspace: scout.workspace), Store.Entry(id: builder.id, workspace: builder.workspace)])

        func item(_ repo: String, _ number: Int, _ title: String, pull: Bool, hours: Double, draft: Bool = false, labels: [GitHubLookup.OpenItem.Label] = [],
                  checks: GitHubLookup.OpenItem.Checks = .none, review: String? = nil) -> GitHubLookup.OpenItem {
            GitHubLookup.OpenItem(repo: repo, number: number, title: title, url: URL(string: "https://github.com/\(repo)/\(pull ? "pull" : "issues")/\(number)")!,
                                  isPullRequest: pull, isDraft: draft, author: pull ? "octocat" : "hubot", createdAt: .now.addingTimeInterval(-hours * 7200),
                                  updatedAt: .now.addingTimeInterval(-hours * 3600), comments: number % 3, labels: labels, reviewDecision: review,
                                  checks: checks, branch: pull ? "feat/\(number)-work" : nil, additions: pull ? 120 : 0, deletions: pull ? 8 : 0)
        }
        let items = [
            item(botchu, 7, "Show open pull requests in Projects", pull: true, hours: 1, labels: [.init(name: "enhancement", color: "a2eeef")],
                 checks: .failure, review: "REVIEW_REQUIRED"),
            item(botchu, 8, "Draft: speed up the sidebar", pull: true, hours: 5, draft: true, checks: .pending),
            item(orbit, 4, "Invite teammates by email, with a long title that wraps onto a second line", pull: false, hours: 2,
                 labels: [.init(name: "bug", color: "d73a4a"), .init(name: "good first issue", color: "7057ff"), .init(name: "onboarding", color: "fbca04")]),
            item(orbit, 5, "Dark mode for the dashboard", pull: false, hours: 30),
            item(orbit, 3, "Remember the last workspace", pull: false, hours: 60),
        ]
        let read = Date.now.addingTimeInterval(-3000)
        let details: [String: GitHubLookup.WorkDetail] = [
            "\(botchu)#7": GitHubLookup.WorkDetail(
                repo: botchu, number: 7, title: "Show open pull requests in Projects",
                body: "## What\n<!-- What changes, and why -->\nLists each repository's open pull requests, with checks and reviews.\n\n- One query per ten repositories\n- `gh` signs in as you",
                url: URL(string: "https://github.com/\(botchu)/pull/7")!, isPullRequest: true, author: "octocat", createdAt: read, updatedAt: read,
                labels: [.init(name: "enhancement", color: "a2eeef")],
                conversation: [.init(author: "hubot", body: "Could this also show **drafts**?", date: read.addingTimeInterval(600)),
                               .init(author: "monalisa", body: "The query reads 30 per repository; say so when there are more.", date: read.addingTimeInterval(1200),
                                     review: "CHANGES_REQUESTED")],
                head: "feat/7-projects", base: "main", additions: 120, deletions: 8, changedFiles: 3, reviewDecision: "CHANGES_REQUESTED",
                checks: [.init(name: "lint", workflow: "Lint", state: .failure, url: URL(string: "https://github.com/\(botchu)/actions/runs/1")),
                         .init(name: "build (macos-14)", workflow: "Tests", state: .success, url: URL(string: "https://github.com/\(botchu)/actions/runs/2")),
                         .init(name: "check", state: .success)],
                files: [.init(path: "macOS/Sources/BotChu/Library/ProjectsView.swift", additions: 90, deletions: 6),
                        .init(path: "macOS/Sources/BotChuCore/ProjectOverview.swift", additions: 28, deletions: 2), .init(path: "README.md", additions: 2, deletions: 0)]),
            "\(orbit)#4": GitHubLookup.WorkDetail(
                repo: orbit, number: 4, title: "Invite teammates by email, with a long title that wraps onto a second line",
                body: "Teams need a way to invite people.\n\n```swift\ninvite(email: \"ada@example.com\")\n```",
                url: URL(string: "https://github.com/\(orbit)/issues/4")!, isPullRequest: false, author: "hubot", createdAt: read, updatedAt: read,
                labels: [.init(name: "bug", color: "d73a4a"), .init(name: "good first issue", color: "7057ff"), .init(name: "onboarding", color: "fbca04")],
                conversation: [.init(author: "octocat", body: "Should invites expire?", date: read.addingTimeInterval(300))]),
        ]
        let asked = Asked()
        let settings = AppSettings(defaults: defaults)
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in ProviderUsage(windows: []) }, projectGitHub: ProjectGitHub { _, _ in
            Issue.record("The project sidebar must not request GitHub")
            return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: items)) }, workDetailLookup: { repo, number, pull in
            await asked.add("\(repo)#\(number)")
            if let detail = details["\(repo)#\(number)"], detail.isPullRequest == pull { return .success(detail) }
            return .failure(TaskWorktree.Failure(step: "Couldn't read \(pull ? "pull request" : "issue") #\(number) of \(repo) with gh", output: ""))
        })
        let sample: [(String, ProjectMetadata.Kind, ProjectMetadata.Status?, Int, Int)] = [
            ("BotChu", .local, .active, 0, 2), ("Orbit", .hosted, .active, 3, 0), ("Archive", .docs, .paused, 0, 0), ("Scratch", .library, nil, 0, 0),
        ]
        app.repositories = sample.map { GitHubLookup.Repo(nameWithOwner: "octocat/\($0.0)", description: "\($0.0)’s repository", openIssues: $0.3, openPullRequests: $0.4) }
        app.repositoriesReadAt = Date()
        app.openItems = items
        for (name, kind, status, _, _) in sample {
            let repo = "octocat/\(name)"
            // Scratch has no PROJECT.md.
            guard let status else { app.projectRecords[repo] = ProjectRecord(text: "", sha: nil); continue }
            let metadata = ProjectMetadata(name: name, kind: kind, status: status, deploy: kind == .hosted ? "vercel:orbit" : "none", merge: "agent")
            app.projectRecords[repo] = ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(metadata), sha: name)
        }
        app.destination = .projects
        defaults.set("table", forKey: "projectsLayoutV2")
        let host = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 860), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            #expect(window.frame.width >= window.contentMinSize.width)
            try captureSidebar(window, name: name)
        }

        // Active projects by default; the paused and the unclassified show under other statuses.
        try await settle("projects-active")
        #expect(app.openItems?.count == items.count)
        defaults.set(ProjectStatusFilter.all.rawValue, forKey: "projectsStatus")
        try await settle("projects-all-statuses")
        defaults.set(ProjectStatusFilter.active.rawValue, forKey: "projectsStatus")

        // A repository's sidebar: its overview, then its pull requests, then one of them in full.
        app.selectProject(botchu)
        #expect(app.projectSelection == ProjectSelection(repo: botchu, tab: .overview))
        try await settle("sidebar-overview")
        app.selectProject(botchu, tab: .pulls)
        try await settle("sidebar-pulls")
        app.selectProject(botchu, tab: .pulls, item: 7)
        try await settle("sidebar-pull-detail")
        #expect(app.workDetails["\(botchu)#7"]?.checksState == .failure)
        // Another repository keeps the tab, and nothing opened in the last one.
        app.selectProject(orbit)
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .pulls))
        app.selectProject(orbit, tab: .issues)
        try await settle("sidebar-issues")
        app.selectProject(orbit, tab: .issues, item: 4)
        try await settle("sidebar-issue-detail")
        // One it can't read says why, beside what Projects read about it.
        app.selectProject(orbit, tab: .issues, item: 5)
        try await settle("sidebar-issue-unread")
        #expect(await asked.all == ["\(botchu)#7", "\(orbit)#4", "\(orbit)#5"])
        NSApp.appearance = NSAppearance(named: .darkAqua)
        app.selectProject(botchu, tab: .pulls, item: 7)
        try await settle("sidebar-pull-detail-dark")
        app.selectProject(orbit, tab: .overview)
        try await settle("sidebar-overview-dark")
        NSApp.appearance = nil
        // The narrowest window still fits the sidebar beside the table.
        window.setContentSize(NSSize(width: 820, height: 600))
        try await settle("sidebar-compact")
        window.setContentSize(NSSize(width: 1340, height: 860))
        // The cross-repository tables open what's selected in the sidebar.
        defaults.set("issues", forKey: "projectsScope")
        app.selectProject(orbit, tab: .issues, item: 5)
        try await settle("projects-issues-with-sidebar")
        defaults.set("repositories", forKey: "projectsScope")

        // Fix All: one task for every issue no task works on (not #3), each with a sub-agent.
        #expect(app.issuesToFix(in: orbit).map(\.number) == [4, 5])
        app.fixAllIssues(in: orbit, with: scout.id)
        let fixAll = try #require(app.taskSheet)
        app.taskSheet = nil
        #expect(fixAll.botID == scout.id && fixAll.repo == orbit && fixAll.work == nil)
        #expect(fixAll.brief == FanOutBrief.fixIssues([items[2].work, items[3].work], repo: orbit, agent: "Scout"))
        // Review All: every pull request no task reviews yet (not #8), posted when asked.
        #expect(app.pullRequestsToReview(in: botchu).map(\.number) == [7])
        app.reviewAllPullRequests(in: botchu, with: builder.id, comment: true)
        let reviewAll = try #require(app.taskSheet)
        app.taskSheet = nil
        #expect(reviewAll.botID == builder.id && reviewAll.repo == botchu)
        #expect(reviewAll.brief == FanOutBrief.reviewPullRequests([items[0].work], repo: botchu, agent: "Builder", comment: true))
        // A single one goes to New Task with it chosen, as the tables' menus do.
        app.newTask(for: scout.id, repo: botchu, work: items[0].work, purpose: .review)
        #expect(app.taskSheet?.work?.number == 7 && app.taskSheet?.purpose == .review && app.taskSheet?.brief == "")
        app.taskSheet = nil
        // A bot whose name finds another bot too is named by its id.
        #expect(app.subagentName(of: scout) == "Scout")
        app.bots.append(Bot(name: "scout", workspace: root.appendingPathComponent("scout-2").path))
        #expect(app.subagentName(of: scout) == scout.id.uuidString)
        app.bots.removeLast()
        // Closing the sidebar deselects the repository.
        app.selectProject(nil)
        #expect(app.projectSelection == nil)
        try await settle("sidebar-closed")
    }

    private func captureSidebar(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"], let view = window.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
    }
}

/// The issues and pull requests the sidebar asked about, in order.
private actor Asked {
    private(set) var all: [String] = []
    func add(_ key: String) { all.append(key) }
}
