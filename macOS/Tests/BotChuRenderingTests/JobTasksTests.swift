import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// A job's run as a task of its agent (#146), as the app runs it: Run Now starts a stand-in
    /// Codex in the agent's workspace, and the run is a new task beside the agent's chat, in its
    /// Tasks column with the job's menu, whose conversation is the run, saved as the task's own and
    /// opened from Home's receipt and the history. Home hears only the job's receipt, and keeps its
    /// draft, queue and session. The job's next run takes its place in Tasks unless the owner wrote
    /// in it, and a closed run's task goes with the run the history lets go. With
    /// `BOTCHU_TEST_SNAPSHOTS` set it writes the agent's chat with the run's task as a PNG there.
    @Test func aJobsRunIsANewTaskInItsAgentsTasks() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-job-tasks-\(UUID().uuidString)")
        let domain = "BotChu.JobTasksTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Product Fox", emoji: "🦊", accountID: "codex-dev", workspace: root.appendingPathComponent("fox").path)
        let files = BotHome(workspace: bot.workspace)
        try files.save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let settings = AppSettings(defaults: defaults)
        let script = root.appendingPathComponent("codex.py")
        try Self.findingCodex.write(to: script, atomically: true, encoding: .utf8)
        settings.commands["codex-dev"] = "/usr/bin/python3 \(Shell.quote(script.path))"
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            Issue.record("Job fixtures must not request GitHub")
            return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        let home = ChatTarget.home(bot.id)
        app.drafts[home] = "Keep this draft"
        let homeBefore = await app.loadedThread(home)?.count ?? 0

        app.jobs.newJob(for: bot.id)
        var job = try #require(app.jobs.editor?.job)
        job.title = "10x Product Analysis"
        job.prompt = "Deploy a sub-agent for each repo and recommend one feature."
        job.enabled = false
        try app.jobs.save(job)
        app.jobs.editor = nil

        func runNow() async throws -> JobRun {
            let before = app.jobs.job(job.id)?.runs.count ?? 0
            app.jobs.runNow(job.id)
            for _ in 0..<500 {
                if let saved = app.jobs.job(job.id), saved.runs.count > before, let run = saved.runs.last, !run.outcome.isActive,
                   let taskID = run.taskID, !app.isRunning(.task(taskID, of: bot.id)) {
                    return run
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("The run didn't finish")
            throw CocoaError(.executableLoad)
        }

        // The run is a new task of the agent's, in its workspace, its conversation the run.
        let run = try await runNow()
        #expect(run.outcome == .succeeded, "\(run.summary)")
        let target = ChatTarget.task(try #require(run.taskID), of: bot.id)
        let task = try #require(app.task(target))
        #expect(app.openTasks(of: bot.id).map(\.id) == [task.id])
        #expect(task.jobRun?.jobID == job.id && task.jobRun?.runID == run.id && task.jobRun?.trigger == .manual)
        #expect(task.title.hasPrefix("10x Product Analysis · "))
        #expect(task.brief == job.prompt)
        #expect(task.folder == bot.workspace)
        #expect(task.accountID == "codex-dev")
        // Its next message resumes the run's session.
        #expect(task.sessionID == "job-session")
        #expect(app.thread(target).map(\.role) == [.note, .user, .assistant])
        #expect(app.thread(target)[1].text == job.prompt)
        #expect(app.thread(target).last?.text == "Recommend a saved-search bar for Projects.")
        #expect(app.jobs.thread(of: run.id, in: try #require(app.jobs.job(job.id))) == app.thread(target))
        #expect(app.unread.contains(target), "A finding is news in its tab too")
        await app.storage.settle()
        // Saved as the task's own conversation, not as a run's transcript beside the job.
        #expect(files.loadTasks().first { $0.id == task.id }?.jobRun?.runID == run.id)
        #expect(files.loadThread(task: task.id).last?.text == "Recommend a saved-search bar for Projects.")
        #expect(!FileManager.default.fileExists(atPath: files.jobRunThreadURL(job: job.id, run: run.id).path))
        // Home hears only the job's receipt; its draft, queue and session stay as they were.
        #expect(app.thread(home).count == homeBefore + 1)
        #expect(app.thread(home).last?.jobRun == JobRunLink(job: job.id, run: run.id))
        #expect(!app.thread(home).contains { $0.taskID == task.id })
        #expect(app.drafts[home] == "Keep this draft")
        #expect(app.messageQueues[home]?.messages.isEmpty ?? true)
        #expect(app.bot(bot.id)?.sessionID == nil)

        // Its tab in the Tasks column names the job and the time it was for, with the job's menu.
        let tab = try #require(app.conversationTab(of: target))
        #expect(tab.isJob && tab.title == "10x Product Analysis" && tab.numberText == nil)
        #expect(tab.subject.hasPrefix("Run Now · "))
        #expect(tab.state.kind == .news)
        #expect(ChatView.placeholder(bot: bot, task: task) == "Message Product Fox about 10x Product Analysis")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ConversationSplit(botID: bot.id) { Color.clear }.environment(app).defaultAppStorage(defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        // The first row under the heading is the run's task.
        let menu = try jobTabMenu(at: NSPoint(x: 120, y: 124), in: host)
        #expect(menu.items.map(\.title) == ["Show Run in Job History", "Show Task Folder in Finder", "Open Task in Terminal", "", "New Session", "Close Task"])
        #expect(menu.items.filter { !$0.isEnabled && !$0.isSeparatorItem }.isEmpty)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Show Run in Job History"))
        #expect(app.jobs.history?.jobID == job.id && app.jobs.history?.runID == run.id)

        // Home's Open Run, and the history's Open Task, open the task.
        app.jobs.open(run: run.id, of: job.id)
        #expect(app.jobs.history == nil)
        #expect(app.tab(of: bot.id) == target)
        #expect(!app.unread.contains(target))
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            window.setContentSize(NSSize(width: 1800, height: 900))
            window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
            try await Task.sleep(for: .milliseconds(600))
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("job-task"))
            window.contentView = host
        }

        // Its next run takes its place in Tasks; the earlier one is closed and found in the history,
        // not among the closed tasks.
        app.show(home)
        let second = try await runNow()
        let secondTarget = ChatTarget.task(try #require(second.taskID), of: bot.id)
        #expect(app.openTasks(of: bot.id).map(\.id) == [secondTarget.taskID])
        #expect(app.task(target)?.isArchived == true)
        #expect(app.closedTasks(of: bot.id).isEmpty)

        // A run's task the owner writes in is theirs: it resumes the run's session, and the job's
        // next run leaves it open.
        #expect(app.send("Which repo first?", to: secondTarget))
        for _ in 0..<500 where app.isRunning(secondTarget) || app.thread(secondTarget).filter({ $0.role == .assistant }).count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(app.thread(secondTarget).filter { $0.role == .assistant }.count == 2)
        #expect(app.task(secondTarget)?.jobRun?.continued == true)
        let calls = try String(contentsOfFile: (bot.workspace as NSString).appendingPathComponent("calls.jsonl"), encoding: .utf8)
        #expect(calls.split(separator: "\n").last?.contains("job-session") == true, "\(calls)")
        let third = try await runNow()
        #expect(app.openTasks(of: bot.id).map(\.id) == [secondTarget.taskID, third.taskID])

        // A closed run's task goes with its run once the history lets the run go; never the workspace.
        var stale = JobTasks.task(for: bot, job: job, run: JobRun(trigger: .manual, scheduledFor: nil, timeZone: job.schedule.timeZone,
                                                                   reservedAt: Date()), startedAt: Date())
        stale.archivedAt = Date()
        try files.save(stale)
        app.tasks[bot.id]?.append(stale)
        job = try #require(app.jobs.job(job.id))
        job.title = "10x Product Analysis (weekly)"
        try app.jobs.save(job)
        #expect(app.task(stale.id, of: bot.id) == nil)
        #expect(app.task(target) != nil, "A run the history keeps keeps its task")
        await app.storage.settle()
        #expect(!FileManager.default.fileExists(atPath: files.taskURL(stale.id).path))
        #expect(FileManager.default.fileExists(atPath: files.taskURL(task.id).path))
        #expect(FileManager.default.fileExists(atPath: bot.workspace))
    }

    /// Records its arguments in its folder, then answers as Codex does, with a finding.
    static let findingCodex = #"""
    import json, sys
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    print(json.dumps({"type":"thread.started", "thread_id":"job-session"}), flush=True)
    print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"Recommend a saved-search bar for Projects."}}), flush=True)
    print(json.dumps({"type":"turn.completed"}), flush=True)
    """#

    /// The context menu a right click at a point (from the host's top-left corner) shows, as AppKit
    /// asks the views under the pointer for it.
    private func jobTabMenu(at point: NSPoint, in host: NSView) throws -> NSMenu {
        let location = host.convert(NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                       windowNumber: host.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        var view = host.hitTest(host.convert(event.locationInWindow, from: nil))
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        return try #require(menu)
    }
}
