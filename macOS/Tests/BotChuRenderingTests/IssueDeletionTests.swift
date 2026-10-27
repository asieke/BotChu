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
        let listed = ProjectSnapshot.Listed(nameWithOwner: orbit, description: "Orbit’s repository", pushedAt: .now, updatedAt: .now, openCount: 3)
        snapshot.takeList([ProjectSnapshot.Page(etag: "", repos: [listed])], complete: true)
        // An active project, so Projects' default scope covers its issues (#186).
        snapshot.takeRecord(orbit, .success(try activeRecord("Orbit")), under: listed.fingerprint)
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
        // sidebar goes back to the list. This is the inspector the window shows (#196).
        app.selectProject(orbit, tab: .issues, item: 3)
        try await Task.sleep(for: .milliseconds(400))
        try deletionCapture(window, name: "issue-detail")
        try await clickSidebarTrash(in: host) { app.issueDeletion != nil }
        #expect(app.issueDeletion == IssueDeletion(repo: orbit, number: 3, title: "Remember the last workspace"))
        try await until { window.attachedSheet != nil }
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

        // A row of the sidebar's list has the table's menu; its Cancel deletes nothing.
        let menu = try sidebarRowMenu(in: host)
        #expect(menu.items.map(\.title) == ["Open on GitHub", "Copy Link", "", "Start Task with", "", "Archive Issue…", "Mark Obsolete…", "Delete Issue…"])
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Delete Issue…"))
        #expect(app.issueDeletion == IssueDeletion(repo: orbit, number: 5, title: "Dark mode for the dashboard"))
        try await until { window.attachedSheet != nil }
        dialog = try #require(window.attachedSheet)
        try #require(deletionButtons(inSheet: dialog).first { $0.title == "Cancel" }).performClick(nil)
        try await until { window.attachedSheet == nil }
        #expect(app.issueDeletion == nil)
        #expect(await gh.all.count == 3)
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
        let listed = ProjectSnapshot.Listed(nameWithOwner: orbit, description: "Orbit", pushedAt: .now, updatedAt: .now, openCount: 3)
        snapshot.takeList([ProjectSnapshot.Page(etag: "", repos: [listed])], complete: true)
        snapshot.takeRecord(orbit, .success(try activeRecord("Orbit")), under: listed.fingerprint)
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
            guard arguments.starts(with: ["gh", "issue", "close"]), arguments.count == 8 else {
                Issue.record("Unexpected GitHub command: \(arguments)")
                return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
            }
            #expect(Array(arguments.suffix(2)) == ["--reason", "not planned"])
            if arguments[3] == "5" {
                return await ProjectGitHub.command(["/bin/sh", "-c", "echo 'Resource not accessible by integration (closeIssue)' >&2; exit 1"], body: nil)
            }
            return await ProjectGitHub.command(["/usr/bin/true"], body: nil)
        }, workDetailLookup: { _, number, _ in
            .failure(TaskWorktree.Failure(step: "Issue #\(number) isn't read in this test", output: ""))
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
            // The closure is done once nothing is updating: the list shrinks a moment before the detail goes.
            try await until { app.openItems?.count == 2 - offset && window.attachedSheet == nil && app.updatingIssues.isEmpty }
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

    /// #196: GitHub answers a deletion (or an archive) only after the owner has moved on: chosen
    /// another issue or repository, closed the sidebar or gone to Jobs. Each route (the table's
    /// menu, the sidebar list's menu, the sidebar detail's Delete) sends one command when confirmed
    /// and none when cancelled; what was chosen meanwhile stays chosen, a deleted issue's detail
    /// goes back to its list, and a refusal is still said once Projects shows again.
    @Test func issueDeletionAnsweredAfterMovingOnKeepsWhereTheOwnerWent() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-issue-deletion-later-\(UUID().uuidString)")
        let domain = "BotChu.IssueDeletionLaterTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root)
        // Orbit with four open issues, #3 updated last; Nova with one.
        let orbit = "octocat/Orbit", nova = "octocat/Nova"
        let items = [(orbit, 3), (orbit, 4), (orbit, 5), (orbit, 6), (nova, 7)].map { repo, number in
            GitHubLookup.OpenItem(repo: repo, number: number, title: "Idea \(number)", url: URL(string: "https://github.com/\(repo)/issues/\(number)")!,
                                  isPullRequest: false, author: "hubot", createdAt: .now.addingTimeInterval(-86_400),
                                  updatedAt: .now.addingTimeInterval(-Double(number) * 3600))
        }
        var snapshot = ProjectSnapshot(login: "octocat")
        let listed = [orbit, nova].map {
            ProjectSnapshot.Listed(nameWithOwner: $0, description: $0, pushedAt: .now, updatedAt: .now, openCount: $0 == orbit ? 4 : 1)
        }
        snapshot.takeList([ProjectSnapshot.Page(etag: "", repos: listed)], complete: true)
        // Active projects, so Projects' default scope covers their issues (#186).
        for repo in listed {
            snapshot.takeRecord(repo.nameWithOwner, .success(try activeRecord(String(repo.nameWithOwner.split(separator: "/").last!))), under: repo.fingerprint)
        }
        snapshot.takeWork([orbit, nova], .success(GitHubLookup.OpenWork(items: items, counts: [orbit: .init(issues: 4, pullRequests: 0),
                                                                                              nova: .init(issues: 1, pullRequests: 0)])),
                          under: [:], etags: [:])
        snapshot.syncedAt = .now
        snapshot.fullSyncedAt = .now
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("projects.json")
        try JSONEncoder().encode(snapshot).write(to: catalog)
        // gh answers each command when the test says, deleting (or closing) it or refusing.
        let github = HeldAnswers()
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), usage: UsageCache { _, _ in ProviderUsage(windows: []) },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { arguments, _ in
            guard arguments.starts(with: ["gh", "issue", "delete"]) || arguments.starts(with: ["gh", "issue", "close"]) else {
                Issue.record("Projects must not ask GitHub for anything else: \(arguments)")
                return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
            }
            if await github.ask(arguments) { return await ProjectGitHub.command(["/usr/bin/true"], body: nil) }
            return await ProjectGitHub.command(["/bin/sh", "-c", "echo 'GraphQL: octocat does not have the correct permissions to execute `DeleteIssue` (deleteIssue)' >&2; exit 1"], body: nil)
        }, workDetailLookup: { repo, number, _ in
            .failure(TaskWorktree.Failure(step: "Couldn't read issue #\(number) of \(repo) with gh", output: ""))
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
        func rows() -> Int? { deletionTables(in: host).first { $0.tableColumns.contains { $0.title == "Title" } }?.numberOfRows }
        try await until { app.openItems?.count == 5 && rows() == 5 }

        /// Confirms (or cancels) the dialog the window shows, and waits until it's gone.
        func answerDialog(_ button: String) async throws {
            try await until { window.attachedSheet != nil }
            let dialog = try #require(window.attachedSheet)
            try #require(deletionButtons(inSheet: dialog).first { $0.title == button }).performClick(nil)
            try await until { window.attachedSheet == nil }
        }
        /// Confirms the deletion asked for, and waits until gh is asked to delete `number`.
        func confirm(_ number: Int, button: String = "Delete Issue") async throws {
            try await answerDialog(button)
            try await until(asking: { await github.isWaiting(number) })
        }
        /// Shows the issue detail of `number` in the sidebar, and chooses its Delete.
        func trash(_ number: Int, of repo: String) async throws {
            app.selectProject(repo, tab: .issues, item: number)
            try await Task.sleep(for: .milliseconds(400))
            try await clickSidebarTrash(in: host) { app.issueDeletion != nil }
            #expect(app.issueDeletion?.number == number)
        }

        // The table's menu, with #3 open in the sidebar: Cancel sends nothing; Delete Issue, one
        // command. Choosing #5 while GitHub answers keeps #5 open once #4 is gone.
        app.selectProject(orbit, tab: .issues, item: 3)
        try await Task.sleep(for: .milliseconds(400))
        func askInTable(row: Int) throws {
            let table = try #require(deletionTables(in: host).first { $0.tableColumns.contains { $0.title == "Title" } })
            let menu = try deletionMenu(at: table.rowView(atRow: row, makeIfNecessary: true), in: host)
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Delete Issue…"))
        }
        try askInTable(row: 1)
        #expect(app.issueDeletion?.number == 4)
        try await answerDialog("Cancel")
        #expect(await github.asked.isEmpty)
        try askInTable(row: 1)
        try await confirm(4)
        app.selectProject(orbit, tab: .issues, item: 5)
        await github.answer(4, ok: true)
        try await until { app.openItems?.contains { $0.number == 4 } == false && rows() == 4 && app.updatingIssues.isEmpty }
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues, item: 5))
        #expect(app.issueDeletion == nil)

        // The sidebar list's menu: closing the sidebar while GitHub refuses keeps it closed, and
        // the alert still says why.
        app.selectProject(orbit, tab: .issues)
        try await Task.sleep(for: .milliseconds(400))
        var menu = try sidebarRowMenu(in: host)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Delete Issue…"))
        #expect(app.issueDeletion?.number == 3)
        try await confirm(3)
        app.selectProject(nil)
        await github.answer(3, ok: false)
        try await until { app.issueDeletion?.failure != nil && window.attachedSheet != nil && app.updatingIssues.isEmpty }
        #expect(deletionTexts(in: window.attachedSheet).joined(separator: "\n").contains("Couldn’t Delete Issue #3"))
        #expect(app.projectSelection == nil)
        #expect(app.openItems?.contains { $0.number == 3 } == true)
        try await answerDialog("OK")
        #expect(app.issueDeletion == nil)
        // Choosing again once the alert has gone.
        try await Task.sleep(for: .milliseconds(500))

        // The sidebar detail's Delete, then Jobs: Jobs stays shown once #3 is gone, and Projects'
        // sidebar is back on the list, with nothing of #3 kept.
        try await trash(3, of: orbit)
        try await confirm(3)
        app.destination = .jobs
        try await Task.sleep(for: .milliseconds(300))
        await github.answer(3, ok: true)
        try await until { app.openItems?.contains { $0.number == 3 } == false && app.updatingIssues.isEmpty }
        #expect(app.destination == .jobs)
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues))
        #expect(app.workDetails["\(orbit)#3"] == nil)
        app.destination = .projects
        try await until { rows() == 3 }
        #expect(window.attachedSheet == nil)
        #expect(try sidebarRowMenu(in: host).indexOfItem(withTitle: "Delete Issue…") >= 0)

        // Another repository chosen while GitHub answers stays chosen.
        try await trash(5, of: orbit)
        try await confirm(5)
        app.selectProject(nova, tab: .issues)
        await github.answer(5, ok: true)
        try await until { app.openItems?.contains { $0.number == 5 } == false && rows() == 2 && app.updatingIssues.isEmpty }
        #expect(app.projectSelection == ProjectSelection(repo: nova, tab: .issues))

        // A refusal answered while Jobs shows is said once Projects shows again; #6 stays open.
        try await trash(6, of: orbit)
        try await confirm(6)
        app.destination = .jobs
        try await Task.sleep(for: .milliseconds(300))
        await github.answer(6, ok: false)
        try await until { app.issueDeletion?.failure != nil && app.updatingIssues.isEmpty }
        #expect(window.attachedSheet == nil)
        app.destination = .projects
        try await until { window.attachedSheet != nil }
        #expect(deletionTexts(in: window.attachedSheet).joined(separator: "\n").contains("Couldn’t Delete Issue #6"))
        try await answerDialog("OK")
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues, item: 6))

        // Nova's only issue, from its sidebar list: the last row of that list goes.
        app.selectProject(nova, tab: .issues)
        try await Task.sleep(for: .milliseconds(400))
        menu = try sidebarRowMenu(in: host)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Delete Issue…"))
        #expect(app.issueDeletion?.number == 7)
        try await confirm(7)
        await github.answer(7, ok: true)
        try await until { app.openItems?.contains { $0.repo == nova } == false && rows() == 1 && app.updatingIssues.isEmpty }
        #expect(app.repositories?.first { $0.id == nova }?.openIssues == 0)

        // Archive Issue… from the sidebar list, with the issue opened before GitHub answers: the
        // table's last row goes (Nothing open shows), and the sidebar goes back to the empty list.
        app.selectProject(orbit, tab: .issues)
        try await Task.sleep(for: .milliseconds(400))
        menu = try sidebarRowMenu(in: host)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Archive Issue…"))
        #expect(app.issueClosure?.number == 6)
        try await confirm(6, button: "Archive Issue")
        app.selectProject(orbit, tab: .issues, item: 6)
        await github.answer(6, ok: true)
        try await until { app.openItems?.isEmpty == true && rows() == nil && app.updatingIssues.isEmpty }
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues))
        #expect(app.updatingIssues.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        try deletionCapture(window, name: "issue-deletion-all-gone")

        // One command for each confirmation, none for the cancel.
        #expect(await github.asked.map { "\($0[2]) \($0[3])" } == ["delete 4", "delete 3", "delete 3", "delete 5", "delete 6", "delete 7", "close 6"])
        let saved = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: catalog))
        #expect(saved.openItems.isEmpty)
    }

    /// #195: Archive Issue and Mark Obsolete take the issue out of the table, the counts and its
    /// sidebar page as soon as they are confirmed, before GitHub answers; asking again meanwhile
    /// sends nothing, and the page the owner opened meanwhile stays open. A refusal brings the
    /// issue back with an alert whose Try Again asks GitHub once more.
    @Test func closedIssuesLeaveBeforeGitHubAnswersAndComeBackWhenRefused() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-issue-closure-pending-\(UUID().uuidString)")
        let domain = "BotChu.IssueClosurePendingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root)
        let orbit = "octocat/Orbit"
        let items = [3, 4, 5].map { number in
            GitHubLookup.OpenItem(repo: orbit, number: number, title: "Old idea \(number)", url: URL(string: "https://github.com/\(orbit)/issues/\(number)")!,
                                  isPullRequest: false, author: "hubot", createdAt: .now, updatedAt: .now.addingTimeInterval(-Double(number)))
        }
        var snapshot = ProjectSnapshot(login: "octocat")
        let listed = ProjectSnapshot.Listed(nameWithOwner: orbit, description: "Orbit", pushedAt: .now, updatedAt: .now, openCount: 3)
        snapshot.takeList([ProjectSnapshot.Page(etag: "", repos: [listed])], complete: true)
        snapshot.takeRecord(orbit, .success(try activeRecord("Orbit")), under: listed.fingerprint)
        snapshot.takeWork([orbit], .success(GitHubLookup.OpenWork(items: items, counts: [orbit: .init(issues: 3, pullRequests: 0)])), under: [:], etags: [:])
        snapshot.syncedAt = .now
        snapshot.fullSyncedAt = .now
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = root.appendingPathComponent("projects.json")
        try JSONEncoder().encode(snapshot).write(to: catalog)
        func saved() throws -> [Int] { try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: catalog)).openItems.map(\.number).sorted() }
        // gh answers each close when the test says: closed, or refused.
        let github = HeldAnswers()
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), usage: UsageCache { _, _ in ProviderUsage(windows: []) },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { arguments, _ in
            guard arguments.starts(with: ["gh", "issue", "close"]) else {
                Issue.record("Unexpected GitHub command: \(arguments)")
                return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
            }
            if await github.ask(arguments) { return await ProjectGitHub.command(["/usr/bin/true"], body: nil) }
            return await ProjectGitHub.command(["/bin/sh", "-c", "echo 'Resource not accessible by integration (closeIssue)' >&2; exit 1"], body: nil)
        }, workDetailLookup: { _, number, _ in
            .failure(TaskWorktree.Failure(step: "Issue #\(number) isn't read in this test", output: ""))
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
        func rows() -> Int? { deletionTables(in: host).first { $0.tableColumns.contains { $0.title == "Title" } }?.numberOfRows }
        try await until { app.openItems?.count == 3 && rows() == 3 }
        func answerDialog(_ button: String) async throws {
            try await until { window.attachedSheet != nil }
            let dialog = try #require(window.attachedSheet)
            try #require(deletionButtons(inSheet: dialog).first { $0.title == button }).performClick(nil)
            try await until { window.attachedSheet == nil }
        }

        // Archive #3 from its sidebar page: it goes from the table, the count and the sidebar while
        // GitHub hasn't answered, and stays saved until it has.
        app.selectProject(orbit, tab: .issues, item: 3)
        try await Task.sleep(for: .milliseconds(400))
        app.askToCloseIssue(3, of: orbit, title: "Old idea 3", as: .archive)
        try await answerDialog("Archive Issue")
        try await until(asking: { await github.isWaiting(3) })
        try await until { rows() == 2 && app.openItems?.map(\.number).sorted() == [4, 5] }
        #expect(app.repositories?.first?.openIssues == 2)
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues))
        #expect(app.updatingIssues == ["\(orbit)#3"])
        #expect(try saved() == [3, 4, 5])
        // Asking again meanwhile sends nothing; another issue opened meanwhile stays open.
        await app.closeIssue(IssueClosure(repo: orbit, number: 3, title: "Old idea 3", disposition: .archive))
        app.selectProject(orbit, tab: .issues, item: 4)
        await github.answer(3, ok: true)
        try await until { app.updatingIssues.isEmpty }
        #expect(app.projectSelection == ProjectSelection(repo: orbit, tab: .issues, item: 4))
        #expect(rows() == 2)
        #expect(app.repositories?.first?.openIssues == 2)
        #expect(try saved() == [4, 5])

        // Mark Obsolete #5, which GitHub refuses: it goes, then comes back, and the alert's Try
        // Again asks once more.
        app.selectProject(orbit, tab: .issues)
        app.askToCloseIssue(5, of: orbit, title: "Old idea 5", as: .obsolete)
        try await answerDialog("Mark Obsolete")
        try await until(asking: { await github.isWaiting(5) })
        try await until { rows() == 1 && app.openItems?.map(\.number) == [4] }
        #expect(app.repositories?.first?.openIssues == 1)
        await github.answer(5, ok: false)
        try await until { app.issueClosure?.failure != nil && window.attachedSheet != nil && app.updatingIssues.isEmpty }
        #expect(deletionTexts(in: window.attachedSheet).joined(separator: "\n").contains("Couldn’t Close Issue #5"))
        #expect(app.issueClosure?.failure?.contains("permission to close") == true)
        try await until { rows() == 2 && app.openItems?.map(\.number).sorted() == [4, 5] }
        #expect(app.repositories?.first?.openIssues == 2)
        try await answerDialog("Try Again")
        try await until(asking: { await github.isWaiting(5) })
        try await until { rows() == 1 }
        await github.answer(5, ok: true)
        try await until { app.updatingIssues.isEmpty && app.openItems?.map(\.number) == [4] }
        #expect(app.issueClosure == nil)
        #expect(window.attachedSheet == nil)
        #expect(app.repositories?.first?.openIssues == 1)
        #expect(try saved() == [4])
        #expect(await github.asked.map { "\($0[2]) \($0[3])" } == ["close 3", "close 5", "close 5"])
    }

    /// The PROJECT.md of an active app project.
    private func activeRecord(_ name: String) throws -> ProjectRecord {
        let metadata = ProjectMetadata(name: name, kind: .hosted, status: .active, deploy: "none", merge: "agent")
        return ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(metadata), sha: name)
    }

    /// Waits (up to five seconds) until `condition` holds.
    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, asking condition: () async -> Bool) async throws {
        for _ in 0..<100 where !(await condition()) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await condition(), sourceLocation: sourceLocation)
    }

    /// The context menu a right click shows: at the middle of a row view, or at a point in `host`.
    private func deletionMenu(at row: NSView?, in host: NSView) throws -> NSMenu {
        let row = try #require(row)
        return try deletionMenu(at: host.convert(row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil), from: nil), in: host)
    }

    private func deletionMenu(at point: NSPoint, in host: NSView) throws -> NSMenu {
        try #require(menu(at: point, in: host))
    }

    private func menu(at point: NSPoint, in host: NSView) -> NSMenu? {
        let location = host.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                             windowNumber: host.window?.windowNumber ?? 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        var view = host.hitTest(host.superview?.convert(location, from: nil) ?? location)
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        return menu
    }

    /// The menu of the first row in the Projects sidebar's list (`ProjectWorkList` in the window's
    /// inspector), found going down the sidebar.
    private func sidebarRowMenu(in host: NSView) throws -> NSMenu {
        let found = stride(from: 100.0, through: 600.0, by: 10.0).lazy.compactMap { y in
            self.menu(at: NSPoint(x: host.bounds.width - 150, y: host.isFlipped ? y : host.bounds.height - y), in: host)
        }.first { $0.indexOfItem(withTitle: "Delete Issue…") >= 0 }
        return try #require(found)
    }

    /// Clicks Delete, the last button in the bar of the issue detail the Projects sidebar shows,
    /// going down the sidebar's right edge until `asked`.
    private func clickSidebarTrash(in host: NSView, until asked: () -> Bool) async throws {
        let window = try #require(host.window)
        for y in stride(from: 100.0, through: 140.0, by: 4.0) where !asked() {
            let location = host.convert(NSPoint(x: host.bounds.width - 21, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(asked())
    }

    private func deletionTables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(deletionTables)
    }

    private func deletionButtons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(deletionButtons)
    }

    private func deletionButtons(inSheet window: NSWindow) -> [NSButton] { window.contentView.map { deletionButtons(in: $0) } ?? [] }

    private func deletionTexts(in window: NSWindow?) -> [String] {
        func texts(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts) }
        return window?.contentView.map(texts) ?? []
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

/// The gh commands Projects ran, each answered when a test says: done, or refused.
private actor HeldAnswers {
    private(set) var asked: [[String]] = []
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]

    func ask(_ arguments: [String]) async -> Bool {
        asked.append(arguments)
        return await withCheckedContinuation { waiting[arguments[3]] = $0 }
    }

    func isWaiting(_ number: Int) -> Bool { waiting["\(number)"] != nil }

    func answer(_ number: Int, ok: Bool) { waiting.removeValue(forKey: "\(number)")?.resume(returning: ok) }
}
