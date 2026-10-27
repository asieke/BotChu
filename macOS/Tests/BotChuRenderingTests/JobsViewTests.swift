import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// Scheduled jobs (#87) as the app keeps them: made for an agent from its context, saved in its
    /// folder, shown in Jobs filtered to it, delivered to Home as a receipt that leaves Home's draft and
    /// queue alone, and gone with the agent. The job is paused, so no tick ever starts a CLI. With
    /// `BOTCHU_TEST_SNAPSHOTS` set it writes Jobs, the editor and the history as PNGs there.
    @Test func jobsBelongToTheirAgentAndReachHomeOnlyAsReceipts() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-jobs-\(UUID().uuidString)")
        let domain = "BotChu.JobsViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "QA Duck", emoji: "🦆", title: "A Duck that QAs", workspace: root.appendingPathComponent("duck").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            Issue.record("Job fixtures must not request GitHub")
            return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })

        // New Job… from the agent's Activity tab chooses that agent.
        app.jobs.newJob(for: bot.id)
        var job = try #require(app.jobs.editor?.job)
        #expect(job.botID == bot.id)
        #expect(app.jobs.editor?.isNew == true)
        job.title = "Morning issue triage"
        job.prompt = "Triage the issues opened since yesterday."
        job.schedule = JobSchedule(kind: .weekdays, hour: 9, minute: 0, timeZone: "America/New_York")
        job.enabled = false
        try app.jobs.save(job)
        #expect(BotHome(workspace: bot.workspace).loadJobs(of: bot.id).map(\.title) == ["Morning issue triage"])
        #expect(app.jobs.jobs(of: bot.id).count == 1)
        #expect(!app.isBusy(bot.id))

        // Agents' count and the Activity tab's All Jobs open Jobs for the agent.
        app.showJobs(for: bot.id)
        #expect(app.destination == .jobs)
        #expect(app.jobs.agentFilter == bot.id)

        // A finding reaches Home as one receipt with its run; Home's draft and queue stay as they were.
        let home = ChatTarget.home(bot.id)
        app.drafts[home] = "Keep this draft"
        // Home is read off the main thread after the launch (#109); a receipt to it in memory shows at once.
        let before = await app.loadedThread(home)?.count ?? 0
        let run = UUID()
        app.postJobReceipt("Job “Morning issue triage” · 9:00 AM: One new issue needs you.", job: job.id, run: run, to: bot.id)
        #expect(app.thread(home).count == before + 1)
        #expect(app.thread(home).last?.role == .receipt)
        #expect(app.thread(home).last?.jobRun == JobRunLink(job: job.id, run: run))
        await app.storage.settle()
        #expect(BotHome(workspace: bot.workspace).loadThread().last?.jobRun == JobRunLink(job: job.id, run: run))
        #expect(app.drafts[home] == "Keep this draft")
        #expect(app.messageQueues[home]?.messages.isEmpty ?? true)
        #expect(app.unread.contains(home))
        #expect(app.runStates[home] == nil)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .resizable, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let snapshots = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        func show(_ view: some View, name: String, size: NSSize) async throws {
            window.contentView = NSHostingView(rootView: view.environment(app).defaultAppStorage(defaults))
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            guard let snapshots, let content = window.contentView,
                  let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: image)
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try image.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("\(name).png"))
        }
        try await show(JobsView(), name: "jobs", size: NSSize(width: 1100, height: 700))
        try await show(JobsView(), name: "jobs-narrow", size: NSSize(width: 620, height: 600))
        try await show(JobEditor(request: JobEditorRequest(job: job, isNew: false)), name: "job-editor", size: NSSize(width: 560, height: 700))
        try await show(JobHistorySheet(request: JobHistoryRequest(jobID: job.id, runID: nil)), name: "job-history", size: NSSize(width: 860, height: 620))
        // Opening Jobs, the editor or the history runs nothing.
        #expect(app.jobs.job(job.id)?.runs.isEmpty == true)

        // Deleting the agent stops and removes its jobs with its folder.
        app.delete(bot.id)
        #expect(app.jobs.jobs.isEmpty)
        #expect(app.jobs.agentFilter == nil)
    }

    /// #196: a job deleted from its row's menu in Jobs, as the window shows it: the last row, the
    /// first and then the only one. A deleted row is laid out once more as it goes, without the
    /// window's environment; its Agent cell read the model there and stopped BotChu ("No Observable
    /// object of type AppModel found"), so the cell is given the model.
    @Test func jobsDeletedFromTheirRowsLeaveWithoutStoppingBotChu() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-job-deletion-\(UUID().uuidString)")
        let domain = "BotChu.JobDeletionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "QA Duck", emoji: "🦆", title: "A Duck that QAs", workspace: root.appendingPathComponent("duck").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            Issue.record("Job fixtures must not request GitHub")
            return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        // Three paused jobs, so no tick ever starts a CLI.
        for title in ["Morning issue triage", "Evening review", "Weekly digest"] {
            app.jobs.newJob(for: bot.id)
            var job = try #require(app.jobs.editor?.job)
            job.title = title
            job.prompt = "Do the \(title.lowercased())."
            job.schedule = JobSchedule(kind: .weekdays, hour: 9, minute: 0, timeZone: "America/New_York")
            job.enabled = false
            try app.jobs.save(job)
            app.jobs.editor = nil
        }
        app.destination = .jobs
        let host = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 860), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func table() -> NSTableView? { jobTables(in: host).first { $0.tableColumns.contains { $0.title == "Job" } } }
        func wait(until condition: () -> Bool) async throws {
            for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
            #expect(condition())
        }
        try await wait { table()?.numberOfRows == 3 }

        /// Chooses Delete… in the row's menu and answers its dialog with `button`.
        func delete(row: Int, button: String = "Delete") async throws {
            let table = try #require(table())
            let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: true))
            let location = rowView.convert(NSPoint(x: 60, y: rowView.bounds.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            var view = host.hitTest(host.superview?.convert(location, from: nil) ?? location)
            var menu: NSMenu?
            while let current = view, menu == nil {
                menu = current.menu(for: event)
                view = current.superview
            }
            let found = try #require(menu)
            #expect(found.items.map(\.title).last == "Delete…")
            found.performActionForItem(at: found.indexOfItem(withTitle: "Delete…"))
            try await wait { window.attachedSheet != nil }
            let dialog = try #require(window.attachedSheet?.contentView)
            try #require(jobButtons(in: dialog).first { $0.title == button }).performClick(nil)
            try await wait { window.attachedSheet == nil }
            try await Task.sleep(for: .milliseconds(300))
        }

        try await delete(row: 2, button: "Cancel")
        #expect(app.jobs.jobs.count == 3)
        for (row, left) in [(2, 2), (0, 1), (0, 0)] {
            try await delete(row: row)
            #expect(app.jobs.jobs.count == left)
            #expect(BotHome(workspace: bot.workspace).loadJobs(of: bot.id).count == left)
        }
        try await wait { table() == nil }
        #expect(app.destination == .jobs)
    }

    private func jobTables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(jobTables)
    }

    private func jobButtons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(jobButtons)
    }
}
