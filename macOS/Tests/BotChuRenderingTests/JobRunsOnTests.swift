import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// A job's own account, model and effort (#132), as the app runs it: Run Now starts its CLI on the
    /// job's account with its model and effort, and once that account is gone, on its agent's, saying
    /// why in the run and on the job. A stand-in Codex records each run's arguments. With
    /// `BOTCHU_TEST_SNAPSHOTS` set it writes the editor for each choice as PNGs there.
    @Test func aJobRunsOnItsOwnChoiceOrItsAgentsSayingWhy() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-job-runs-on-\(UUID().uuidString)")
        let domain = "BotChu.JobRunsOnTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "QA Duck", emoji: "🦆", accountID: "codex-dev", model: "gpt-6-luna", reasoningEffort: .medium,
                      workspace: root.appendingPathComponent("duck").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let settings = AppSettings(defaults: defaults)
        let script = root.appendingPathComponent("codex.py")
        try Self.recordingCodex.write(to: script, atomically: true, encoding: .utf8)
        // Each account's command says which it is, first among the arguments it records.
        for account in ["codex-dev", "codex-work"] { settings.commands[account] = "/usr/bin/python3 \(Shell.quote(script.path)) \(account)" }
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            Issue.record("Job fixtures must not request GitHub")
            return await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }

        // A new job runs on its agent's until others are chosen; the editor chooses them on the job.
        app.jobs.newJob(for: bot.id)
        var job = try #require(app.jobs.editor?.job)
        #expect(job.runsOn == nil)
        job.title = "Deploy check"
        job.prompt = "Check the deploy."
        job.enabled = false
        job.selectAccount(settings.account("codex-work"), agent: bot)
        job.selectModel("gpt-6-astra", agent: bot)
        job.selectReasoningEffort(.ultra, agent: bot, openRouterDefault: settings.openRouterModel)
        try app.jobs.save(job)
        #expect(BotHome(workspace: bot.workspace).loadJobs(of: bot.id).first?.runsOn
            == JobRunsOn(accountID: "codex-work", model: "gpt-6-astra", reasoningEffort: .ultra))
        #expect(app.jobs.fallback(of: job) == nil)

        func runNow() async throws -> (run: JobRun, arguments: [String], note: String?) {
            let before = app.jobs.job(job.id)?.runs.count ?? 0
            app.jobs.runNow(job.id)
            for _ in 0..<500 {
                if let saved = app.jobs.job(job.id), saved.runs.count > before, let run = saved.runs.last, !run.outcome.isActive {
                    let calls = try String(contentsOfFile: (bot.workspace as NSString).appendingPathComponent("calls.jsonl"), encoding: .utf8)
                    let last = try #require(calls.split(separator: "\n").last)
                    let arguments = try JSONDecoder().decode([String].self, from: Data(last.utf8))
                    return (run, arguments, app.jobs.thread(of: run.id, in: saved).first?.text)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("The run didn't finish")
            throw CocoaError(.executableLoad)
        }

        // Its run is on the job's account, with its model and effort, and says so.
        let own = try await runNow()
        #expect(own.run.outcome == .succeeded, "\(own.run.summary)")
        #expect(own.arguments.first == "codex-work")
        #expect(own.arguments.contains("gpt-6-astra"))
        #expect(own.arguments.contains("model_reasoning_effort=\"ultra\""))
        #expect(!own.arguments.contains("gpt-6-luna"))
        #expect(own.run.accountID == "codex-work")
        #expect(own.run.model == "gpt-6-astra")
        #expect(own.run.reasoningEffort == .ultra)
        #expect(own.note == "Started on Codex Work")
        #expect(app.bot(bot.id)?.accountID == "codex-dev", "The agent's own choice stays as it was")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let snapshots = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        func show(_ job: Job, name: String) async throws {
            window.contentView = NSHostingView(rootView: JobEditor(request: JobEditorRequest(job: job, isNew: false)).environment(app))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            guard let snapshots, let content = window.contentView,
                  let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: image)
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            try image.representation(using: .png, properties: [:])?.write(to: snapshots.appendingPathComponent("\(name).png"))
        }
        try await show(try #require(app.jobs.job(job.id)), name: "job-editor-own")

        // Its CLI profile gone, its run is on the agent's account, model and effort, never another
        // provider, and the run and the job say why.
        job = try #require(app.jobs.job(job.id))
        job.runsOn = JobRunsOn(accountID: "custom-research", accountProfile: Account(id: "custom-research", name: "Research", kind: .claude,
                               defaultCommand: "/usr/bin/false", symbol: "terminal"), model: "opus", reasoningEffort: .max)
        try app.jobs.save(job)
        let reason = "Research is no longer in Providers, so this job runs on QA Duck's account, model and effort."
        #expect(app.jobs.fallback(of: job) == reason)
        try await show(try #require(app.jobs.job(job.id)), name: "job-editor-gone")
        let fallback = try await runNow()
        #expect(fallback.run.outcome == .succeeded, "\(fallback.run.summary)")
        #expect(fallback.arguments.first == "codex-dev")
        #expect(fallback.arguments.contains("gpt-6-luna"))
        #expect(fallback.arguments.contains("model_reasoning_effort=\"medium\""))
        #expect(!fallback.arguments.contains("opus"))
        #expect(fallback.run.accountID == "codex-dev")
        #expect(fallback.run.reasoningEffort == .medium)
        #expect(fallback.note == "Started on Codex Dev. " + reason)
        #expect(app.jobs.job(job.id)?.runsOn?.accountID == "custom-research", "The job keeps its choice for when the profile is back")

        // Back on the agent's, it follows the agent.
        job = try #require(app.jobs.job(job.id))
        job.selectAccount(nil, agent: bot)
        try app.jobs.save(job)
        #expect(app.jobs.fallback(of: job) == nil)
        try await show(try #require(app.jobs.job(job.id)), name: "job-editor-agent")
    }

    /// Records its arguments in its folder, then answers as Codex does.
    static let recordingCodex = #"""
    import json, sys
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    print(json.dumps({"type":"thread.started", "thread_id":"job-session"}), flush=True)
    print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"Deploy looks fine."}}), flush=True)
    print(json.dumps({"type":"turn.completed"}), flush=True)
    """#
}
