import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// #138: Activity's run reviews are one summary line (when the next review is, or the real
    /// reason one waits) with Review now, rows only for reviews with news (memory updated, a change
    /// proposed, a failure), and one line counting the week's others; Home's says it covers all the
    /// bot's work, and a task's lists the reviews that covered it. In light and dark, at the
    /// narrowest status sidebar. Settings ▸ Run reviews sets the review time.
    @Test func activityShowsRunReviewsAsASummaryNewsAndCountsAndSettingsSetTheReviewTime() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-run-reviews-\(UUID().uuidString)")
        let domain = "BotChu.RunReviewsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let scout = Bot(name: "Scout", emoji: "🦊", title: "Curious researcher", accountID: "codex-dev", workspace: root.appendingPathComponent("scout").path)
        let task = BotTask(for: scout, repo: "octocat/Orbit", checkout: root.path, work: nil, brief: "Tidy the onboarding flow")
        let other = BotTask(for: scout, repo: "octocat/Atlas", checkout: root.path, work: nil, brief: "Speed up the map")
        let home = BotHome(workspace: scout.workspace)
        try home.save(scout)
        try home.save(task)
        try home.save(other)
        try store.saveIndex([Store.Entry(id: scout.id, workspace: scout.workspace)])
        let onTask = ReviewConversation(botID: scout.id, taskID: task.id)

        // A week of reviews as saved: three with news, and four without, which are only counted.
        let now = Date()
        func record(_ title: String, hoursAgo: Double, covering: [ReviewConversation] = [onTask], _ change: (inout EvaluationRecord) -> Void) throws -> EvaluationRecord {
            var record = EvaluationRecord(.day(botID: scout.id), bot: scout, title: title, at: now.addingTimeInterval(-hoursAgo * 3_600))
            record.phase = .done
            record.outcome = .noChange
            record.finishedAt = record.createdAt.addingTimeInterval(120)
            record.attempts = 1
            record.covered = covering.map { ReviewCoverage(conversation: $0, title: $0.taskID == task.id ? "“\(task.title)”" : "Home",
                                                           through: UUID(), throughDate: record.createdAt, subagents: [], signal: true) }
            change(&record)
            try home.save(record)
            return record
        }
        let updated = try record("the work up to Sat, Oct 25, 4:00 AM", hoursAgo: 6) { record in
            record.outcome = .memoryUpdated
            record.cited = ["“\(task.title)”", "Home"]
            record.findings = EvaluationFindings(summary: "It reproduced the bug before fixing it, but ran the whole suite three times.",
                                                 worked: ["Reproduced with a focused test"], didNotWork: ["Ran the whole suite after every edit"],
                                                 evidence: ["[T3] Bash: swift test → failed (exit 1)"])
            record.applied = [AppliedChange(destination: .memory, path: scout.workspace + "/MEMORY.md",
                                            hunks: [AppliedChange.Hunk(section: "# Scout", before: "- Uses pnpm", added: ["- Run the focused test before the whole suite"])])]
        }
        let proposed = try record("the work up to Fri, Oct 24, 4:00 AM", hoursAgo: 30) { record in
            record.outcome = .proposed
            record.cited = ["“\(task.title)”"]
            record.proposals = [EvaluationChange(destination: .instructions, text: "Ask before force-pushing a shared branch", why: "The owner corrected it twice",
                                                 evidence: ["M4"], held: "Only the owner changes INSTRUCTIONS.md: a review proposes what to add")]
        }
        let failed = try record("the work up to Thu, Oct 23, 4:00 AM", hoursAgo: 54) { record in
            record.phase = .failed
            record.outcome = nil
            record.failure = EvaluationFailure(.authentication, "Error: Not logged in. Run `codex login`.")
        }
        for (hours, outcome) in [(78.0, EvaluationRecord.Outcome.noChange), (102, .noChange), (126, .noSignal)] {
            _ = try record("the work of a quiet day", hoursAgo: hours, covering: [ReviewConversation(botID: scout.id)]) { $0.outcome = outcome }
        }
        _ = try record("the work before Sat, Oct 18", hoursAgo: 140, covering: [ReviewConversation(botID: scout.id)]) { record in
            record.phase = .skipped
            record.outcome = nil
            record.expired = true
            record.skipReason = "Not reviewed within 7 days"
        }
        // And work waiting for the next review, in both tasks.
        try home.save(ReviewState(stretches: [
            ReviewStretch(conversation: onTask, from: UUID(), through: UUID(), throughDate: now.addingTimeInterval(-3_600), since: now.addingTimeInterval(-3_600)),
            ReviewStretch(conversation: ReviewConversation(botID: scout.id, taskID: other.id), from: UUID(), through: UUID(),
                          throughDate: now.addingTimeInterval(-1_800), since: now.addingTimeInterval(-1_800)),
        ], handled: ReviewTime.standard.handled(atOrBefore: now, in: .current)))

        let settings = AppSettings(defaults: defaults)
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") },
                           openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in await ProjectGitHub.command(["/usr/bin/false"], body: nil) },
                           openWorkLookup: { _ in .failure(TaskWorktree.Failure(step: "Open work isn't read in tests", output: "")) },
                           workDetailLookup: { _, _, _ in .failure(TaskWorktree.Failure(step: "Details aren't read in tests", output: "")) })
        defer { app.stopAll() }
        let homeTarget = ChatTarget.home(scout.id), taskTarget = ChatTarget.task(task.id, of: scout.id)
        // Without a runner (tests, review copies) reviews are off, but what they found shows.
        #expect(app.reviewStatus(for: homeTarget) == .off)
        app.evaluator.runner = { _ in #"<evaluation>{"summary": "Fine", "changes": []}</evaluation>"# }

        // The summary line, the news and the counts, as Home shows them.
        let status = app.reviewStatus(for: homeTarget)
        guard case .next(let next, conversations: 2) = status else { Issue.record("\(status)"); return }
        #expect(next > now && next.timeIntervalSince(now) <= 86_400)
        #expect(status.text() == "Next review at \(ReviewTime.timeText(next, in: .current)) · 2 conversations with unreviewed work")
        #expect(app.canReviewNow(homeTarget) && app.canReviewNow(taskTarget))
        #expect(app.evaluations(for: homeTarget).filter(\.isNews).map(\.id) == [updated.id, proposed.id, failed.id])
        #expect(app.reviewCounts(for: homeTarget) == ReviewCounts(noChange: 2, noSignal: 1, notReviewed: 1))
        #expect(app.reviewCounts(for: homeTarget).text == "This week: 2 days with no change · 1 without signal · 1 not reviewed in time")
        // A task's: the reviews that covered it, and its own work waiting.
        #expect(app.evaluations(for: taskTarget).filter(\.isNews).map(\.id) == [updated.id, proposed.id, failed.id])
        #expect(app.reviewCounts(for: taskTarget).isEmpty)
        #expect(app.reviewStatus(for: taskTarget).text().hasSuffix(" · 1 conversation with unreviewed work"))

        let host = NSHostingView(rootView: RunReviewsHarness(target: homeTarget, app: app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle(_ name: String) async throws -> CGFloat {
            try await Task.sleep(for: .milliseconds(250))
            window.setContentSize(host.fittingSize)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            try captureRunReviews(host, name: name)
            return host.fittingSize.height
        }
        var heights: [CGFloat] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            heights.append(try await settle("run-reviews-home-\(appearance == .aqua ? "light" : "dark")"))
            #expect(host.fittingSize.width <= 280)
        }
        window.appearance = nil
        #expect(heights[0] == heights[1])
        // Rows for the news alone: opening one shows its saved change and Revert.
        host.rootView = RunReviewsHarness(target: taskTarget, app: app)
        let taskHeight = try await settle("run-reviews-task")
        #expect(taskHeight < heights[0], "No counts line and no note that it covers all the bot's work")

        // Review now: the account is busy, so it waits, saying so, and Review now goes.
        app.runStates[ChatTarget.task(other.id, of: scout.id)] = RunState(hasOutput: true, activity: .coding)
        host.rootView = RunReviewsHarness(target: homeTarget, app: app)
        app.reviewNow(homeTarget)
        #expect(app.reviewStatus(for: homeTarget) == .waiting(.busy(account: "Codex Dev"), conversations: 2))
        #expect(!app.canReviewNow(homeTarget) && !app.canReviewNow(taskTarget))
        let waiting = try await settle("run-reviews-waiting")
        #expect(waiting < heights[0], "Review now is gone while one waits")
        #expect(app.evaluations(for: homeTarget).filter(\.isNews).count == 3, "A waiting review adds no row")
        // Once the account is idle (for the delay, none in tests) it runs: the work here has no
        // transcript to show, so no signal, which adds no row either and is only counted.
        app.evaluator.limits.delay = 0
        app.runStates[ChatTarget.task(other.id, of: scout.id)] = nil
        app.evaluator.pump()
        await app.evaluator.settle()
        #expect(app.reviewStatus(for: homeTarget) == .upToDate)
        #expect(app.reviewCounts(for: homeTarget).noSignal == 2)
        #expect(app.evaluations(for: homeTarget).filter(\.isNews).count == 3)
        _ = try await settle("run-reviews-up-to-date")

        // Settings ▸ Run reviews: on, and the review time, which the summary line follows.
        let form = NSHostingView(rootView: Form { RunReviewSettings() }.formStyle(.grouped).frame(width: 600).environment(app))
        window.contentView = form
        window.setContentSize(NSSize(width: 600, height: 400))
        try await Task.sleep(for: .milliseconds(300))
        form.layoutSubtreeIfNeeded()
        let picker = try #require(descendants(of: form).compactMap { $0 as? NSDatePicker }.first)
        let shown = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        #expect(shown.hour == 4 && shown.minute == 0, "04:00 by default")
        #expect(picker.isEnabled)
        picker.dateValue = try #require(Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: Date()))
        _ = picker.sendAction(picker.action, to: picker.target)
        try await Task.sleep(for: .milliseconds(150))
        #expect(settings.reviewTime == ReviewTime(hour: 6, minute: 30))
        #expect(AppSettings(defaults: defaults).reviewTime == ReviewTime(hour: 6, minute: 30), "Kept for the next launch")
        // A turn ends (nothing of it on disk here), so there is work for the next review.
        app.evaluator.turnEnded(onTask, prompt: UUID(), last: UUID(), accountID: "codex-dev")
        guard case .next(let later, _) = app.reviewStatus(for: homeTarget) else { Issue.record("no next review"); return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: later)
        #expect(parts.hour == 6 && parts.minute == 30)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(200))
            try captureRunReviews(form, name: "run-reviews-settings-\(appearance == .aqua ? "light" : "dark")")
        }
        window.appearance = nil
        // Turned off, the time can't be changed, and Activity says reviews are off.
        settings.evaluateRuns = false
        try await Task.sleep(for: .milliseconds(200))
        #expect(!picker.isEnabled)
        #expect(app.reviewStatus(for: homeTarget) == .off)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func captureRunReviews(_ view: NSView, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"],
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
    }
}

/// The Run reviews section alone, at the status sidebar's narrowest.
private struct RunReviewsHarness: View {
    let target: ChatTarget
    let app: AppModel

    var body: some View {
        RunReviewsSection(target: target)
            .frame(width: 280)
            .background(Palette.sidebar)
            .environment(app)
    }
}
