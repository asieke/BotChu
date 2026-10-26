import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// #154: an issue's menu in Projects' Issues table and in the sidebar's list, and the issue
    /// detail's Delete, ask first, naming the repository and number, then delete it with gh (a
    /// stand-in here); it leaves the table, the counts and projects.json at once. One GitHub
    /// refuses stays, and an alert says why.
    @Test func issuesAreDeletedFromTheirMenuAndDetailAfterConfirming() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-issue-deletion-\(UUID().uuidString)")
        let domain = "BotChu.IssueDeletionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let scout = Bot(name: "Scout", emoji: "🦊", workspace: root.appendingPathComponent("scout").path)
        try BotHome(workspace: scout.workspace).save(scout)
        try store.saveIndex([Store.Entry(id: scout.id, workspace: scout.workspace)])

        // A saved catalog, synced just now: Orbit with three open issues, #3 updated last.
        let orbit = "octocat/Orbit"
        let items = [(3, "Remember the last workspace"), (4, "Invite teammates by email"), (5, "Dark mode for the dashboard")].map { number, title in
            GitHubLookup.OpenItem(repo: orbit, number: number, title: title, url: URL(string: "https://github.com/\(orbit)/issues/\(number)")!,
                                  isPullRequest: false, author: "hubot", createdAt: .now.addingTimeInterval(-86_400),
                                  updatedAt: .now.addingTimeInterval(-Double(number) * 3600))
        }
        var snapshot = ProjectSnapshot(login: "octocat")
        snapshot.takeList([ProjectSnapshot.Page(etag: "", repos: [ProjectSnapshot.Listed(nameWithOwner: orbit, description: "Orbit’s repository",
                                                                                         pushedAt: .now, updatedAt: .now, openCount: 3)])], complete: true)
        snapshot.takeWork([orbit], .success(GitHubLookup.OpenWork(items: items, counts: [orbit: .init(issues: 3, pullRequests: 0)])), under: [:], etags: [:])
        snapshot.syncedAt = .now
        snapshot.fullSyncedAt = .now
        let catalog = store.root.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: catalog)

        // gh deletes any issue but #5, which needs admin rights the account doesn't have.
        let gh = Requests()
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), usage: UsageCache { _, _ in ProviderUsage(windows: []) },
                           projectGitHub: ProjectGitHub { arguments, _ in
            await gh.add(arguments)
            guard arguments.starts(with: ["gh", "issue", "delete"]) else {
                Issue.record("Projects must not ask GitHub for anything else: \(arguments)")
                return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
            }
            if arguments[3] == "5" {
                return await ProjectGitHub.command(["/bin/sh", "-c", "echo 'GraphQL: octocat does not have the correct permissions to execute `DeleteIssue` (deleteIssue)' >&2; exit 1"], body: nil)
            }
            return await ProjectGitHub.command(["/usr/bin/true"], body: nil)
        }, workDetailLookup: { repo, number, _ in
            .failure(TaskWorktree.Failure(step: "Couldn't read issue #\(number) of \(repo) with gh", output: ""))
        })
        app.destination = .projects
        defaults.set("issues", forKey: "projectsScope")
        let host = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 860), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await until { app.openItems?.count == 3 }
        try await Task.sleep(for: .milliseconds(350))
        func table() throws -> NSTableView {
            try #require(deletionTables(in: host).first { $0.tableColumns.contains { $0.title == "Title" } })
        }
        #expect(try table().numberOfRows == 3)

        /// Chooses Delete Issue… in the menu of the table's row, and returns the dialog it opens.
        func askToDelete(row: Int) async throws -> NSWindow {
            let menu = try deletionMenu(at: try table().rowView(atRow: row, makeIfNecessary: false), in: host)
            #expect(menu.items.map(\.title) == ["Open on GitHub", "Copy Link", "", "Start Task with", "", "Archive Issue…", "Mark Obsolete…", "Delete Issue…"])
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Delete Issue…"))
            try await Task.sleep(for: .milliseconds(400))
            return try #require(window.attachedSheet)
        }

        // The second row, #4: the dialog names it and its repository, and says it can't be undone.
        var dialog = try await askToDelete(row: 1)
        #expect(app.issueDeletion == IssueDeletion(repo: orbit, number: 4, title: "Invite teammates by email"))
        var text = deletionTexts(in: dialog).joined(separator: "\n")
        #expect(text.contains("Delete issue #4 of octocat/Orbit?"))
        #expect(text.contains("can’t be undone"))
        try deletionCapture(dialog, name: "issue-delete-confirm")
        // Cancel deletes nothing.
        try #require(deletionButtons(inSheet: dialog).first { $0.title == "Cancel" }).performClick(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.attachedSheet == nil)
        #expect(app.issueDeletion == nil)
        #expect(await gh.all.isEmpty)

        // Delete Issue deletes it on GitHub, and it leaves the table, the count and the saved catalog.
        dialog = try await askToDelete(row: 1)
        try #require(deletionButtons(inSheet: dialog).first { $0.title == "Delete Issue" }).performClick(nil)
        try await until { app.openItems?.count == 2 }
        #expect(await gh.all == [["gh", "issue", "delete", "4", "--repo", orbit, "--yes"]])
        #expect(app.openItems?.map(\.number) == [3, 5])
        #expect(app.repositories?.first?.openIssues == 2)
        #expect(app.openIssueStatus?["octocat/orbit"] == OpenIssueStatus(count: 2))
        try await Task.sleep(for: .milliseconds(350))
        #expect(window.attachedSheet == nil)
        #expect(try table().numberOfRows == 2)
        var saved = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: catalog))
        #expect(saved.openItems.map(\.number).sorted() == [3, 5])

        // GitHub refuses #5: nothing is removed, and an alert says why.
        dialog = try await askToDelete(row: 1)
        #expect(deletionTexts(in: dialog).joined().contains("Delete issue #5 of octocat/Orbit?"))
        try #require(deletionButtons(inSheet: dialog).first { $0.title == "Delete Issue" }).performClick(nil)
        try await until { app.issueDeletion?.failure != nil }
        try await Task.sleep(for: .milliseconds(400))
        let alert = try #require(window.attachedSheet)
        text = deletionTexts(in: alert).joined(separator: "\n")
        #expect(text.contains("Couldn’t Delete Issue #5"))
        #expect(text.contains("only a repository's admins"))
        try deletionCapture(alert, name: "issue-delete-refused")
        #expect(app.openItems?.map(\.number) == [3, 5])
        try #require(deletionButtons(inSheet: alert).first { $0.title == "OK" }).performClick(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.attachedSheet == nil)
        #expect(app.issueDeletion == nil)

        // The sidebar's issue detail deletes #3 with Delete, the last button in its bar, and the
        // sidebar goes back to the list.
        let repo = try #require(app.repositories?.first)
        app.selectProject(orbit, tab: .issues, item: 3)
        let detail = NSHostingView(rootView: WorkDetailView(repo: repo, number: 3, pulls: false).modifier(IssueDeletionPrompt())
            .frame(width: 340, height: 500).environment(app))
        window.contentView = detail
        try await Task.sleep(for: .milliseconds(400))
        try deletionCapture(window, name: "issue-detail")
        let trash = detail.convert(NSPoint(x: detail.bounds.width - 21, y: detail.isFlipped ? 17 : detail.bounds.height - 17), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: trash, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(app.issueDeletion == IssueDeletion(repo: orbit, number: 3, title: "Remember the last workspace"))
        dialog = try #require(window.attachedSheet)
        #expect(deletionTexts(in: dialog).joined().contains("Delete issue #3 of octocat/Orbit?"))
        try #require(deletionButtons(inSheet: dialog).first { $0.title == "Delete Issue" }).performClick(nil)
        try await until { app.openItems?.count == 1 }
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues))
        #expect(app.openItems?.map(\.number) == [5])
        #expect(app.repositories?.first?.openIssues == 1)
        #expect(await gh.all.map { $0[3] } == ["4", "5", "3"])
        saved = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: catalog))
        #expect(saved.openItems.map(\.number) == [5])
        try await Task.sleep(for: .milliseconds(350))

        // A row of the sidebar's list has the table's menu.
        let list = NSHostingView(rootView: ProjectWorkList(repo: repo, pulls: false).frame(width: 340, height: 400).environment(app))
        window.contentView = list
        try await Task.sleep(for: .milliseconds(350))
        let menu = try deletionMenu(at: NSPoint(x: 120, y: list.isFlipped ? 80 : list.bounds.height - 80), in: list)
        #expect(menu.items.map(\.title) == ["Open on GitHub", "Copy Link", "", "Start Task with", "", "Archive Issue…", "Mark Obsolete…", "Delete Issue…"])
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Delete Issue…"))
        #expect(app.issueDeletion == IssueDeletion(repo: orbit, number: 5, title: "Dark mode for the dashboard"))
        app.issueDeletion = nil
    }

    /// #162: the non-destructive actions keep GitHub history, update all open-work views and
    /// surface a denied close without removing anything. Neither path can call issue delete.
    @Test func issuesCanBeArchivedOrMarkedObsoleteWithoutDeletingThem() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-issue-closure-\(UUID().uuidString)")
        let domain = "BotChu.IssueClosureTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root)
        let orbit = "octocat/Orbit"
        let items = [3, 4, 5].map { number in
            GitHubLookup.OpenItem(repo: orbit, number: number, title: "Old idea \(number)", url: URL(string: "https://github.com/\(orbit)/issues/\(number)")!,
                                  isPullRequest: false, author: "hubot", createdAt: .now, updatedAt: .now.addingTimeInterval(-Double(number)))
        }
        var snapshot = ProjectSnapshot(login: "octocat")
        snapshot.takeList([ProjectSnapshot.Page(etag: "", repos: [ProjectSnapshot.Listed(nameWithOwner: orbit, description: "Orbit",
                                                                                         pushedAt: .now, updatedAt: .now, openCount: 3)])], complete: true)
        snapshot.takeWork([orbit], .success(GitHubLookup.OpenWork(items: items, counts: [orbit: .init(issues: 3, pullRequests: 0)])), under: [:], etags: [:])
        snapshot.syncedAt = .now
        snapshot.fullSyncedAt = .now
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("projects.json")
        try JSONEncoder().encode(snapshot).write(to: catalog)
        let gh = Requests()
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), usage: UsageCache { _, _ in ProviderUsage(windows: []) },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { arguments, _ in
            await gh.add(arguments)
            #expect(arguments.starts(with: ["gh", "issue", "close"]))
            #expect(Array(arguments.suffix(2)) == ["--reason", "not planned"])
            if arguments[3] == "5" {
                return await ProjectGitHub.command(["/bin/sh", "-c", "echo 'Resource not accessible by integration (closeIssue)' >&2; exit 1"], body: nil)
            }
            return await ProjectGitHub.command(["/usr/bin/true"], body: nil)
        })
        defer { app.stopAll() }
        app.destination = .projects
        defaults.set("issues", forKey: "projectsScope")
        let host = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 860), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await until { app.openItems?.count == 3 && deletionTables(in: host).contains { $0.numberOfRows == 3 } }

        func ask(_ action: String) async throws -> NSWindow {
            let table = try #require(deletionTables(in: host).first { $0.tableColumns.contains { $0.title == "Title" } })
            let menu = try deletionMenu(at: table.rowView(atRow: 0, makeIfNecessary: true), in: host)
            let index = menu.indexOfItem(withTitle: action + "…")
            #expect(index >= 0)
            menu.performActionForItem(at: index)
            try await until { window.attachedSheet != nil }
            return try #require(window.attachedSheet)
        }

        var dialog = try await ask("Archive Issue")
        #expect(deletionTexts(in: dialog).joined().contains("comments and link stay on GitHub"))
        try #require(deletionButtons(inSheet: dialog).first { $0.title == "Cancel" }).performClick(nil)
        try await until { window.attachedSheet == nil }
        #expect(await gh.all.isEmpty)
        #expect(app.openItems?.count == 3)

        for (offset, disposition) in IssueClosure.Disposition.allCases.enumerated() {
            let number = 3 + offset
            dialog = try await ask(disposition.action)
            #expect(app.issueClosure?.number == number)
            #expect(app.issueClosure?.disposition == disposition)
            // A detail opened while the request was being confirmed goes back to its list too.
            app.projectSelection = ProjectSelection(repo: orbit, tab: .issues, item: number)
            try #require(deletionButtons(inSheet: dialog).first { $0.title == disposition.action }).performClick(nil)
            try await until { app.openItems?.count == 2 - offset && window.attachedSheet == nil }
            #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues))
            #expect(app.repositories?.first?.openIssues == 2 - offset)
            let saved = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: catalog))
            #expect(!saved.openItems.contains { $0.number == number })
            app.projectSelection = nil
            try await until { deletionTables(in: host).first { $0.tableColumns.contains { $0.title == "Title" } }?.numberOfRows == 2 - offset }
        }
        #expect(await gh.all.map { $0[3] } == ["3", "4"])
        dialog = try await ask("Mark Obsolete")
        try #require(deletionButtons(inSheet: dialog).first { $0.title == "Mark Obsolete" }).performClick(nil)
        try await until { app.issueClosure?.failure != nil }
        #expect(app.issueClosure?.failure?.contains("permission to close") == true)
        #expect(app.openItems?.map(\.number) == [5])
        #expect(app.updatingIssues.isEmpty)
        app.issueClosure = nil
        try await until { window.attachedSheet == nil }
    }

    /// Waits (up to five seconds) until `condition` holds.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }

    /// The context menu a right click shows: at the middle of a row view, or at a point in `host`.
    private func deletionMenu(at row: NSView?, in host: NSView) throws -> NSMenu {
        let row = try #require(row)
        return try deletionMenu(at: host.convert(row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil), from: nil), in: host)
    }

    private func deletionMenu(at point: NSPoint, in host: NSView) throws -> NSMenu {
        let location = host.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: host.window?.windowNumber ?? 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        var view = host.hitTest(host.superview?.convert(location, from: nil) ?? location)
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        return try #require(menu)
    }

    private func deletionTables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(deletionTables)
    }

    private func deletionButtons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(deletionButtons)
    }

    private func deletionButtons(inSheet window: NSWindow) -> [NSButton] { window.contentView.map { deletionButtons(in: $0) } ?? [] }

    private func deletionTexts(in window: NSWindow) -> [String] {
        func texts(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts) }
        return window.contentView.map(texts) ?? []
    }

    private func deletionCapture(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"], let view = window.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
    }
}

/// The gh commands Projects ran, in order.
private actor Requests {
    private(set) var all: [[String]] = []
    func add(_ arguments: [String]) { all.append(arguments) }
}
