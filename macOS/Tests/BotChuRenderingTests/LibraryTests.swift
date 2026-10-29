import AppKit
import SwiftUI
import Testing
import Vision
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func galleriesKeepConversationStateAndCustomProfilesPersist() async throws {
        _ = NSApplication.shared
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-library-\(UUID().uuidString)")
        let domain = "BotChu.LibraryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Scout", emoji: "🦊", title: "Curious researcher and thoughtful collaborator", workspace: root.appendingPathComponent("bot").path)
        let second = Bot(name: "Builder", emoji: "🛠️", title: "Builds small, complete changes", workspace: root.appendingPathComponent("builder").path)
        let task = BotTask(for: bot, repo: "octocat/BotChu", checkout: root.path, work: nil, brief: "Add projects")
        try BotHome(workspace: bot.workspace).save(bot)
        try BotHome(workspace: bot.workspace).save(task)
        try BotHome(workspace: second.workspace).save(second)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace), Store.Entry(id: second.id, workspace: second.workspace)])
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        let account = Account(id: "custom-research", name: "Research Codex", kind: .codex, defaultCommand: "codex-research", symbol: "terminal")
        settings.customAccounts = [account]
        #expect(AppSettings(defaults: defaults).accounts.last == account)
        var keyReads = 0
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, keys in
            #expect(keys == UsageKeys(), "A Codex profile needs no key")
            return ProviderUsage(windows: [UsageWindow(id: "session", title: "5-hour", usedPercent: 24, resetsAt: .now.addingTimeInterval(7200)), UsageWindow(id: "week", title: "Weekly", usedPercent: 68, resetsAt: .now.addingTimeInterval(259200))])
        }, openRouterKey: { keyReads += 1; return nil }, projectGitHub: ProjectGitHub { _, _ in
            Issue.record("Library fixtures must not request GitHub")
            return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in
            Issue.record("Library fixtures must not request GitHub")
            return .success(GitHubLookup.OpenWork(items: []))
        })
        app.sailKey = { nil }
        // The open pull requests and issues as saved, which Projects shows without syncing.
        let url = URL(string: "https://github.com/octocat/BotChu/pull/7")!
        let openItems: [GitHubLookup.OpenItem] = [
            GitHubLookup.OpenItem(repo: "octocat/BotChu", number: 7, title: "Show open pull requests in Projects", url: url, isPullRequest: true,
                                  isDraft: false, author: "octocat", authorAvatar: nil, createdAt: .now.addingTimeInterval(-7200),
                                  updatedAt: .now.addingTimeInterval(-600), comments: 1, labels: [.init(name: "enhancement", color: "a2eeef")],
                                  reviewDecision: "REVIEW_REQUIRED", checks: .success, branch: "feat/7-projects", fromFork: false, additions: 120, deletions: 8),
            GitHubLookup.OpenItem(repo: "octocat/Orbit", number: 3, title: "Invite teammates by email", url: URL(string: "https://github.com/octocat/Orbit/issues/3")!,
                                  isPullRequest: false, isDraft: false, author: "hubot", authorAvatar: nil, createdAt: .now.addingTimeInterval(-90000),
                                  updatedAt: .now.addingTimeInterval(-86400), comments: 4, labels: [], reviewDecision: nil, checks: .none,
                                  branch: nil, fromFork: false, additions: 0, deletions: 0),
        ]
        let sample: [(String, String, ProjectMetadata.Kind, String)] = [
            ("BotChu", "Persistent agents, projects, and conversations on your Mac.", .local, "local:my-mac:~/apps/BotChu"),
            ("Fieldnotes", "Research notes and ideas for the next big thing.", .docs, "none"),
            ("Orbit", "A welcoming home for your team's work.", .hosted, "vercel:orbit"),
            ("TinyKit", "Small Swift tools that make a difference.", .library, "registry:swift"),
        ]
        app.repositories = sample.map { GitHubLookup.Repo(nameWithOwner: "octocat/\($0.0)", description: $0.1, isPrivate: $0.0 == "Fieldnotes",
                                                          openIssues: $0.0 == "Orbit" ? 1 : 0, openPullRequests: $0.0 == "BotChu" ? 1 : 0) }
        app.repositoriesReadAt = Date()
        app.openItems = openItems
        for (name, _, kind, deploy) in sample {
            let metadata = ProjectMetadata(name: name, kind: kind, deploy: deploy)
            app.projectRecords["octocat/\(name)"] = ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(metadata), sha: name)
        }
        let target = ChatTarget.task(task.id, of: bot.id)
        app.show(target)
        app.drafts[target] = "Keep this draft"
        let host = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for destination in LibraryDestination.allCases {
            app.destination = destination
            app.unread.insert(target)
            #expect(app.visibleBotID == nil)
            #expect(app.tab(of: bot.id) == target)
            try await Task.sleep(for: .milliseconds(350))
            window.layoutIfNeeded()
            #expect(window.frame.width >= window.contentMinSize.width)
            try captureLibrary(window, name: destination.rawValue)
            if destination == .projects {
                defaults.set("table", forKey: "projectsLayoutV2")
                try await Task.sleep(for: .milliseconds(200))
                try captureLibrary(window, name: "projects-table")
                window.setContentSize(NSSize(width: 820, height: 600))
                try await Task.sleep(for: .milliseconds(200))
                #expect(window.frame.width >= window.contentMinSize.width)
                try captureLibrary(window, name: "projects-compact")
                window.setContentSize(NSSize(width: 1240, height: 800))
                #expect(app.openItems?.count == 2)
                for scope in ["pulls", "issues"] {
                    defaults.set(scope, forKey: "projectsScope")
                    try await Task.sleep(for: .milliseconds(200))
                    window.layoutIfNeeded()
                    try captureLibrary(window, name: "projects-\(scope)")
                }
                defaults.set("repositories", forKey: "projectsScope")
            }
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        defaults.set("gallery", forKey: "projectsLayoutV2")
        app.destination = .projects
        try await Task.sleep(for: .milliseconds(200))
        try captureLibrary(window, name: "projects-dark")
        app.destination = .providers
        try await Task.sleep(for: .milliseconds(200))
        try captureLibrary(window, name: "providers-dark")
        #expect(keyReads > 0) // A missing test key must never fall back to Keychain.
        NSApp.appearance = nil
        app.show(target)
        #expect(app.destination == nil)
        #expect(!app.unread.contains(target))
        #expect(app.drafts[target] == "Keep this draft")
        #expect(app.tab(of: bot.id) == target)
        app.setAccount(account.id, for: target)
        // Saved off the main thread (#107).
        app.storage.wait(timeout: 5)
        #expect(BotHome(workspace: bot.workspace).loadTasks().first?.account == account)
        app.newTask(for: bot.id, repo: "octocat/Fieldnotes")
        #expect(app.taskSheet?.repo == "octocat/Fieldnotes")
        let pull = try #require(app.openItems?.first { $0.isPullRequest })
        app.newTask(for: bot.id, repo: pull.repo, work: pull.work, purpose: .comment)
        #expect(app.taskSheet?.work?.number == 7)
        #expect(app.taskSheet?.purpose == .comment)
        let issue = try #require(app.openItems?.first { !$0.isPullRequest })
        app.newTask(for: bot.id, repo: issue.repo, work: issue.work, purpose: .review)
        #expect(app.taskSheet?.purpose == .work)
        app.taskSheet = nil
        let record = try #require(app.projectRecords["octocat/BotChu"])
        let metadata = try record.metadata(repoName: "BotChu")
        window.contentView = NSHostingView(rootView: ProjectMetadataEditor(repo: app.repositories![0], original: record, metadata: metadata).environment(app))
        window.setContentSize(NSSize(width: 580, height: 590))
        try await Task.sleep(for: .milliseconds(200))
        try captureLibrary(window, name: "metadata-editor")
        window.contentView = NSHostingView(rootView: AddProviderSheet().environment(app))
        window.setContentSize(NSSize(width: 540, height: 410))
        try await Task.sleep(for: .milliseconds(200))
        try captureLibrary(window, name: "add-provider")
        app.destination = .agents
        app.delete(bot.id)
        #expect(app.destination == .agents)
        #expect(app.visibleBotID == nil)
    }

    /// Settings is a page of the window (#191): it keeps the conversation shown, its draft and its
    /// tab; it opens on the page asked for or the one shown last; a key typed and not saved stays
    /// while pages change and goes when Settings closes; and its rail folds into a menu when narrow.
    @Test func settingsIsAPageOfTheWindowThatKeepsTheConversationAndKeyDrafts() async throws {
        _ = NSApplication.shared
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-settings-\(UUID().uuidString)")
        let domain = "BotChu.SettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Scout", emoji: "🦊", workspace: root.appendingPathComponent("bot").path)
        let task = BotTask(for: bot, repo: "octocat/BotChu", checkout: root.path, work: nil, brief: "Add settings")
        try BotHome(workspace: bot.workspace).save(bot)
        try BotHome(workspace: bot.workspace).save(task)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        // Never the owner's Keychain: every key Settings reads comes from here.
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") },
                           openRouterKey: { "sk-or-saved" })
        defer { app.stopAll() }
        app.telegram.readToken = { nil }
        app.remoteQueue.readToken = { nil }
        let target = ChatTarget.task(task.id, of: bot.id)
        app.show(target)
        app.drafts[target] = "Keep this draft"
        let host = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        // The gear, ⌘, and the app menu all do this: General the first time, in the window.
        app.openSettings()
        #expect(app.destination == .settings)
        #expect(app.sidebarSelection == .library(.settings))
        #expect(app.settings.settingsPage == .general)
        #expect(app.visibleBotID == nil)
        #expect(app.tab(of: bot.id) == target)
        try await Task.sleep(for: .milliseconds(400))
        var text = try await settingsText(host)
        for label in ["Workspace", "Bots", "Archive", "Move existing", "Storage Janitor"] {
            #expect(shows(text, label), "\(label) in \(text.sorted())")
        }
        // The rail, with its pages; no status sidebar beside Settings.
        for page in ["GitHub", "Hosts", "Run reviews", "Telegram", "Remote queue"] { #expect(shows(text, page), "\(page) in \(text.sorted())") }
        #expect(!shows(text, "Activity"))
        try captureLibrary(window, name: "settings-general")

        // A link opens its page; a key typed there survives a change of page.
        app.openSettings(.openRouter)
        try await Task.sleep(for: .milliseconds(300))
        var field = try #require(secureFields(in: host).first)
        #expect(field.stringValue == "sk-or-saved")
        field.stringValue = "sk-or-typed"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(150))
        app.openSettings(.telegram)
        try await Task.sleep(for: .milliseconds(300))
        text = try await settingsText(host)
        #expect(shows(text, "Reach bots from Telegram"), "\(text.sorted())")
        app.openSettings(.openRouter)
        try await Task.sleep(for: .milliseconds(300))
        field = try #require(secureFields(in: host).first)
        #expect(field.stringValue == "sk-or-typed", "Kept while pages change")
        try captureLibrary(window, name: "settings-openrouter-unsaved")

        // Back at the bot: its tab and draft as they were. Settings comes back on the last page,
        // without the key that wasn't saved.
        app.show(target)
        #expect(app.destination == nil)
        #expect(app.tab(of: bot.id) == target)
        #expect(app.drafts[target] == "Keep this draft")
        try await Task.sleep(for: .milliseconds(200))
        app.openSettings()
        #expect(app.settings.settingsPage == .openRouter)
        #expect(AppSettings(defaults: defaults).settingsPage == .openRouter, "Remembered across launches")
        try await Task.sleep(for: .milliseconds(300))
        field = try #require(secureFields(in: host).first)
        #expect(field.stringValue == "sk-or-saved")

        // Narrow and dark: the rail folds into the title's menu, and nothing is cut off.
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 820, height: 600))
        app.openSettings(.general)
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        #expect(window.frame.width >= window.contentMinSize.width)
        text = try await settingsText(host)
        #expect(shows(text, "General"), "\(text.sorted())")
        #expect(!shows(text, "Remote queue"), "No rail when narrow: \(text.sorted())")
        #expect(shows(text, "Choose."), "The folder's button is whole: \(text.sorted())")
        try captureLibrary(window, name: "settings-compact-dark")
    }

    /// The text drawn in the window, as Vision reads its pixels (SwiftUI's text isn't consistently
    /// exposed to in-process accessibility).
    private func settingsText(_ host: NSView) async throws -> Set<String> {
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let pixels = try #require(image.cgImage)
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: pixels).perform([request])
            return Set((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
        }.value
    }

    /// Whether a line read contains `words`: Vision reads a rail item's symbol into its line.
    private func shows(_ text: Set<String>, _ words: String) -> Bool { text.contains { $0.contains(words) } }

    private func secureFields(in view: NSView) -> [NSSecureTextField] {
        ((view as? NSSecureTextField).map { [$0] } ?? []) + view.subviews.flatMap(secureFields)
    }

    private func captureLibrary(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"], let view = window.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
    }
}
