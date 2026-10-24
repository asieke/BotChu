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
        let before = app.thread(home).count
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
}
