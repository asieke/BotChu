import Foundation
import Testing
@testable import BotChuCore

/// #138: each bot's work is reviewed once a day, in one pass over every conversation since its
/// last review, and only when that work has signal.
@Suite @MainActor struct DailyReviewTests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let newYork = TimeZone(identifier: "America/New_York")!

    static func message(_ role: ChatMessage.Role, _ text: String = "", at seconds: TimeInterval) -> ChatMessage {
        ChatMessage(role: role, text: text, date: base.addingTimeInterval(seconds))
    }

    static func tool(at seconds: TimeInterval, failed: Bool = false, duration: Double? = nil) -> ChatMessage {
        var tool = ChatMessage(role: .tool, toolID: UUID().uuidString, toolName: "Bash", toolInput: "make", toolState: failed ? .failed : .done,
                               toolExitCode: failed ? 1 : 0)
        tool.date = base.addingTimeInterval(seconds)
        tool.toolDuration = duration
        return tool
    }

    /// A New York moment.
    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in zone: TimeZone = newYork) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: The stretch and its cursor

    @Test func aStretchRunsFromAfterItsCursorToTheEndOfItsLastFinishedTurn() throws {
        let conversation = ReviewConversation(botID: UUID(), taskID: UUID())
        // Three turns: messages 0-2, 3-6 and 7-9.
        let transcript = (0..<10).map { i in Self.message([0, 3, 7].contains(i) ? .user : .assistant, "\(i)", at: TimeInterval(i * 10)) }
        let ids = transcript.map(\.id)
        let first = ReviewStretch(conversation: conversation, from: ids[3], through: ids[6], throughDate: transcript[6].date, since: transcript[6].date)
        #expect(first.range(in: transcript) == 3..<7)
        // Started from a turn's output (a folded per-turn review), it starts at that turn's prompt.
        var output = first
        output.from = ids[4]
        #expect(output.range(in: transcript) == 3..<7)
        // Reviewed, nothing is left of it; a turn that ended while it was read stays, after the cursor.
        #expect(first.advanced(past: first.coverage()) == nil)
        var grown = first
        grown.through = ids[9]
        grown.throughDate = transcript[9].date
        let left = try #require(grown.advanced(past: first.coverage()))
        #expect(left.cursor == ids[6] && left.from == nil)
        #expect(left.range(in: transcript) == 7..<10, "Nothing twice, nothing between two reviews missed")
        // The cursor never moves back, whatever an older review covered.
        var older = first.coverage()
        older.through = ids[2]
        older.throughDate = transcript[2].date
        #expect(left.advanced(past: older)?.cursor == ids[6])
        // A transcript that no longer holds the cursor's message is read from its turn's end.
        let rewritten = transcript.filter { $0.id != ids[6] }
        #expect(left.range(in: rewritten) == 6..<9)
        // A stretch folded from per-turn reviews ends when their newest turn ended.
        let folded = ReviewStretch(conversation: conversation, from: ids[4], throughDate: transcript[6].date.addingTimeInterval(1), since: transcript[6].date)
        #expect(folded.range(in: transcript) == 3..<7)
        // One with only sub-agent runs has no turns in it.
        let runs = ReviewStretch(conversation: conversation, subagents: [UUID()], since: Self.base)
        #expect(runs.range(in: transcript).isEmpty && runs.hasWork && !runs.hasTurns)
    }

    @Test func eachReviewSeesOnlyWhatEndedSinceTheLastOne() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        fixture.answer(ReviewFixture.reply())
        try fixture.turn(ReviewFixture.turn("Alpha"))
        _ = await fixture.review()
        #expect(fixture.lastSnapshot?.contains("Owner: Alpha") == true)
        fixture.clock = fixture.clock.addingTimeInterval(600)
        let bravo = ReviewFixture.turn("Bravo")
        try fixture.turn(bravo)
        try fixture.turn(ReviewFixture.turn("Charlie"))
        let stretch = try #require(fixture.evaluator.states[fixture.bot.id]?.unreviewed().first)
        #expect(stretch.from == bravo[0].id, "It starts at the first turn since the last review")
        _ = await fixture.review()
        let text = try #require(fixture.lastSnapshot)
        #expect(text.contains("Owner: Bravo") && text.contains("Owner: Charlie"))
        #expect(!text.contains("Alpha"))
        #expect(fixture.calls.count == 2)
    }

    // MARK: Signal

    @Test func theSignalGateFindsFailuresStopsSteeringAndLongRuns() {
        let limits = RunEvaluator.Limits()
        func signals(_ messages: [ChatMessage], task: Bool = true) -> ReviewSignals {
            ReviewSignals(ReviewSignals.turns(messages[...], task: task, opening: messages.first?.id))
        }
        let brief = Self.message(.user, "Fix it", at: 0)
        // A finished turn with a tool call: nearly every run is one, and it isn't signal.
        let quiet = signals([brief, Self.tool(at: 10), Self.message(.assistant, "Done", at: 20)])
        #expect(quiet == ReviewSignals(toolCalls: 1, time: 20))
        #expect(!quiet.hasSignal(limits) && quiet.words(limits).isEmpty)
        // A failed turn, by its last word; an error the CLI recovered from isn't a failure.
        #expect(signals([brief, Self.message(.error, "Exited with status 1", at: 5)]).failures == 1)
        #expect(signals([brief, Self.message(.error, "Reconnecting", at: 5), Self.message(.assistant, "Done", at: 6)]).failures == 0)
        // A run the owner stopped.
        let stopped = signals([brief, Self.tool(at: 2), Self.message(.note, "Stopped", at: 3)])
        #expect(stopped.stops == 1 && stopped.hasSignal(limits))
        // The owner steering a task after its brief; Home's messages are new requests, not steering.
        let steered = [brief, Self.message(.assistant, "On it", at: 1), Self.message(.user, "Use the other API", at: 2), Self.message(.assistant, "OK", at: 3)]
        #expect(signals(steered).steering == 1)
        #expect(signals(steered).words(limits) == ["the owner steered once"])
        #expect(signals(steered, task: false).steering == 0 && !signals(steered, task: false).hasSignal(limits))
        // Failed tool calls, tool calls and time at work, by the thresholds.
        #expect(!signals([brief] + (0..<2).map { Self.tool(at: Double($0), failed: true) }).hasSignal(limits))
        #expect(signals([brief] + (0..<3).map { Self.tool(at: Double($0), failed: true) }).words(limits) == ["3 failed tool calls"])
        #expect(!signals([brief] + (0..<59).map { Self.tool(at: Double($0)) }).hasSignal(limits))
        #expect(signals([brief] + (0..<60).map { Self.tool(at: Double($0)) }).words(limits) == ["60 tool calls"])
        #expect(!signals([brief, Self.message(.assistant, "Done", at: 44 * 60)]).hasSignal(limits))
        #expect(signals([brief, Self.message(.assistant, "Done", at: 45 * 60)]).words(limits) == ["45 min at work"])
        // A tool's own time counts, to its end.
        #expect(signals([brief, Self.tool(at: 60, duration: 44 * 60)]).hasSignal(limits))
        var lower = limits
        lower.toolCalls = 2
        #expect(quiet.hasSignal(lower) == false && signals([brief, Self.tool(at: 1), Self.tool(at: 2)]).hasSignal(lower))

        // Sub-agent runs: failed (a handoff that couldn't be saved fails its run) or stopped are
        // signal; one still running isn't a run yet.
        let bot = Bot(name: "Worker", workspace: "/tmp/worker")
        var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Look", brief: "Look", workingDirectory: "/tmp")
        run.phase = .running
        #expect(ReviewSignals.run(run, messages: []) == nil)
        run.phase = .completed
        #expect(!ReviewSignals([ReviewSignals.run(run, messages: [Self.tool(at: 0)])!]).hasSignal(limits))
        run.phase = .failed
        run.errorMessage = "Couldn't save the handoff: disk full"
        #expect(ReviewSignals([ReviewSignals.run(run, messages: [])!]).failures == 1)
        run.phase = .stopped
        #expect(ReviewSignals([ReviewSignals.run(run, messages: [])!]).stops == 1)
    }

    @Test func aDayWithoutSignalAsksNoModelAndIsCountedNotListed() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        fixture.answer(ReviewFixture.reply())
        // Home's turns are reviewed too, and pass the same gate: a quiet chat and a task turn that
        // only ran a few tools have no signal.
        try fixture.homeTurn([ChatMessage(role: .user, text: "What's on today?"), ChatMessage(role: .assistant, text: "Two reviews.")])
        try fixture.turn([ChatMessage(role: .user, text: ReviewFixture.task.brief), ReviewFixture.tool("Bash", "swift test", exit: 0),
                          ChatMessage(role: .assistant, text: "Tests pass.")])
        fixture.reachReviewTime()
        await fixture.evaluator.settle()
        let record = try #require(fixture.evaluator.records.values.first)
        #expect(record.phase == .done && record.outcome == .noSignal)
        #expect(record.attempts == 0 && record.attemptTimes.isEmpty, "No model call, nor one counted against the daily limit")
        #expect(fixture.calls.count == 0)
        #expect(record.notice == nil && !record.isNews)
        #expect(fixture.evaluator.states[fixture.bot.id]?.unreviewed().isEmpty == true, "Its cursors moved")
        #expect(ReviewCounts([record], since: .distantPast) == ReviewCounts(noSignal: 1))
        // A failure in Home is signal.
        try fixture.homeTurn([ChatMessage(role: .user, text: "Deploy it"), ChatMessage(role: .error, text: "codex exited with status 1")])
        let failed = try #require(await fixture.review())
        #expect(failed.outcome == .noChange && fixture.calls.count == 1)
        #expect(fixture.lastSnapshot?.contains("Conversation 1: Dev Bot's Home · signal: 1 failed turn or run") == true)
    }

    // MARK: When

    @Test func theReviewTimeIsDueOnceADayAndOnceAfterMissedDays() {
        let time = ReviewTime.standard
        #expect(time == ReviewTime(hour: 4, minute: 0))
        let handled = time.handled(atOrBefore: Self.at(2027, 1, 15, 3), in: Self.newYork)
        #expect(handled == ReviewTime.Handled(occurrence: Self.at(2027, 1, 14, 4), day: "2027-01-14"))
        #expect(time.due(now: Self.at(2027, 1, 15, 3, 59), in: Self.newYork, after: handled) == .none)
        let today = ReviewTime.Handled(occurrence: Self.at(2027, 1, 15, 4), day: "2027-01-15")
        #expect(time.due(now: Self.at(2027, 1, 15, 4), in: Self.newYork, after: handled) == .review(today, missed: 0))
        #expect(time.due(now: Self.at(2027, 1, 15, 23), in: Self.newYork, after: today) == .none, "Never twice for one day")
        #expect(time.next(after: Self.at(2027, 1, 15, 10), in: Self.newYork, handled: today) == Self.at(2027, 1, 16, 4))
        // Closed or asleep for three review times: due once, at the first chance afterwards.
        let late = time.due(now: Self.at(2027, 1, 18, 10), in: Self.newYork, after: today)
        #expect(late == .review(ReviewTime.Handled(occurrence: Self.at(2027, 1, 18, 4), day: "2027-01-18"), missed: 2))

        // The Mac's time zone moves west after the day's review: that day's 04:00 there is handled,
        // not reviewed again; the next day's is.
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let west = time.due(now: Self.at(2027, 1, 15, 7, 30, in: losAngeles), in: losAngeles, after: today)
        let westHandled = ReviewTime.Handled(occurrence: Self.at(2027, 1, 15, 4, in: losAngeles), day: "2027-01-15")
        #expect(west == .handled(westHandled))
        #expect(time.due(now: Self.at(2027, 1, 16, 4, in: losAngeles), in: losAngeles, after: westHandled)
                == .review(ReviewTime.Handled(occurrence: Self.at(2027, 1, 16, 4, in: losAngeles), day: "2027-01-16"), missed: 0))
        // East: the new zone's 04:00 that day came before the one handled.
        let reviewedWest = ReviewTime.Handled(occurrence: Self.at(2027, 1, 15, 4, in: losAngeles), day: "2027-01-15")
        #expect(time.due(now: Self.at(2027, 1, 15, 8), in: Self.newYork, after: reviewedWest) == .none)
        #expect(time.next(after: Self.at(2027, 1, 15, 8), in: Self.newYork, handled: reviewedWest) == Self.at(2027, 1, 16, 4))

        // Daylight saving: a time the clock skips is due as it jumps; one it repeats, once.
        let skipped = ReviewTime(hour: 2, minute: 30)
        let march = ReviewTime.Handled(occurrence: Self.at(2027, 3, 13, 2, 30), day: "2027-03-13")
        let jump = skipped.due(now: Self.at(2027, 3, 14, 3, 10), in: Self.newYork, after: march)
        guard case .review(let spring, 0) = jump else { Issue.record("\(jump)"); return }
        #expect(spring.day == "2027-03-14" && spring.occurrence == Self.at(2027, 3, 14, 3))
        #expect(skipped.due(now: Self.at(2027, 3, 14, 23), in: Self.newYork, after: spring) == .none)
        let repeated = ReviewTime(hour: 1, minute: 30)
        let november = ReviewTime.Handled(occurrence: Self.at(2027, 11, 6, 1, 30), day: "2027-11-06")
        let firstPass = Self.at(2027, 11, 7, 1, 40)
        guard case .review(let fall, 0) = repeated.due(now: firstPass, in: Self.newYork, after: november) else { Issue.record("fall back"); return }
        #expect(fall.day == "2027-11-07")
        #expect(repeated.due(now: firstPass.addingTimeInterval(3_600), in: Self.newYork, after: fall) == .none, "The repeated hour runs it once")
    }

    @Test func aReviewThatCantRunBeforeTheNextReviewTimeIsFoldedIntoIt() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        var busy = true
        fixture.evaluator.isAccountBusy = { _ in busy }
        fixture.answer(ReviewFixture.reply())
        try fixture.turn(ReviewFixture.turn("Alpha"))
        fixture.reachReviewTime()
        let first = try #require(fixture.evaluator.records.values.first)
        #expect(first.phase == .pending && first.scheduledFor == fixture.clock)
        #expect(fixture.evaluator.status(of: fixture.bot.id) == .waiting(.busy(account: "Codex Dev"), conversations: 1))
        // The next day: more work, and the account still busy at the review time.
        fixture.clock = fixture.clock.addingTimeInterval(8 * 3_600)
        try fixture.turn(ReviewFixture.turn("Bravo"))
        fixture.reachReviewTime()
        #expect(fixture.evaluator.records.count == 1, "At most one waiting review a bot")
        let folded = try #require(fixture.evaluator.records[first.id])
        #expect(folded.phase == .pending && folded.coalesced == 1 && folded.scheduledFor == fixture.clock)
        #expect(folded.title.hasSuffix(" (2 days)"))
        busy = false
        fixture.evaluator.pump()
        await fixture.evaluator.settle()
        #expect(fixture.calls.count == 1)
        let text = try #require(fixture.lastSnapshot)
        #expect(text.contains("Owner: Alpha") && text.contains("Owner: Bravo"), "Both days, since the cursors hadn't moved")
        #expect(fixture.evaluator.records[first.id]?.phase == .done)

        // Changing the review time after the day's review never reviews that day again.
        fixture.clock = fixture.clock.addingTimeInterval(3_600)
        try fixture.turn(ReviewFixture.turn("Charlie"))
        fixture.evaluator.reviewTime = { ReviewTime(hour: 10, minute: 0) }
        fixture.clock = fixture.clock.addingTimeInterval(6 * 3_600)
        fixture.evaluator.pump()
        await fixture.evaluator.settle()
        #expect(fixture.evaluator.records.count == 1 && fixture.calls.count == 1)
        fixture.clock = fixture.clock.addingTimeInterval(24 * 3_600)
        fixture.evaluator.pump()
        await fixture.evaluator.settle()
        #expect(fixture.calls.count == 2, "The next day's, at the new time")
    }

    @Test func workLeftUnreviewedForSevenDaysIsSkippedAndCountedAndRetryRestartsTheWait() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        fixture.evaluator.runner = { _ in throw EvaluationRunError("Error: Not logged in. Run `codex login`.") }
        try fixture.turn(ReviewFixture.turn("Old work"))
        // Its reviews fail every day: the work waits, and its cursor stays.
        for _ in 0..<6 {
            fixture.reachReviewTime()
            await fixture.evaluator.settle()
        }
        #expect(fixture.evaluator.records.values.filter { $0.phase == .failed }.count == 6)
        #expect(fixture.evaluator.states[fixture.bot.id]?.unreviewed().count == 1)
        // Retry restarts the wait of the work it covers.
        let last = try #require(fixture.evaluator.records.values.max { $0.createdAt < $1.createdAt })
        fixture.evaluator.retry(last.id)
        await fixture.evaluator.settle()
        fixture.clock = fixture.clock.addingTimeInterval(2 * 86_400)
        fixture.evaluator.pump()
        await fixture.evaluator.settle()
        #expect(fixture.evaluator.states[fixture.bot.id]?.unreviewed().count == 1, "Retried, it may wait 7 days from then")
        // Untouched 7 days after that, it is skipped: its cursor moves, and it is counted.
        fixture.clock = fixture.clock.addingTimeInterval(6 * 86_400)
        fixture.evaluator.pump()
        await fixture.evaluator.settle()
        #expect(fixture.evaluator.states[fixture.bot.id]?.unreviewed().isEmpty == true)
        let skipped = try #require(fixture.evaluator.records.values.first { $0.expired == true })
        #expect(skipped.phase == .skipped && !skipped.isNews && !skipped.canRetry)
        #expect(skipped.skipReason?.hasPrefix("Not reviewed within 7 days") == true)
        let counts = ReviewCounts(fixture.evaluator.records(aboutBot: fixture.bot.id), since: fixture.clock.addingTimeInterval(-7 * 86_400))
        #expect(counts.notReviewed == 1)
        #expect(counts.text == "This week: 0 days with no change · 0 without signal · 1 not reviewed in time")
    }

    @Test func aReviewStartsOnlyOnceItsAccountHasBeenIdleForTheDelay() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        var busy = false
        fixture.evaluator.isAccountBusy = { _ in busy }
        fixture.evaluator.limits.delay = 60
        fixture.answer(ReviewFixture.reply())
        // A turn ends: a review asked for at that instant waits.
        try fixture.turn()
        #expect(fixture.evaluator.reviewNow(fixture.bot.id))
        let record = try #require(fixture.evaluator.records.values.first)
        #expect(fixture.evaluator.waitReason(record) == .busy(account: "Codex Dev"))
        fixture.clock = fixture.clock.addingTimeInterval(59)
        fixture.evaluator.pump()
        #expect(fixture.calls.count == 0)
        // A scheduled job ends on the account meanwhile, and a sub-agent's run: the wait starts again.
        fixture.evaluator.accountActivity("codex-dev")
        fixture.clock = fixture.clock.addingTimeInterval(59)
        fixture.evaluator.pump()
        #expect(fixture.calls.count == 0)
        var run = SubagentRun(rootBotID: fixture.bot.id, depth: 1, targetBot: fixture.bot, title: "Look", brief: "Look", workingDirectory: "/tmp")
        run.phase = .completed
        fixture.evaluator.subagentEnded(run)
        fixture.clock = fixture.clock.addingTimeInterval(59)
        fixture.evaluator.pump()
        #expect(fixture.calls.count == 0)
        // Something runs on it, seen as reviews are looked at: the wait counts from then.
        busy = true
        fixture.clock = fixture.clock.addingTimeInterval(30)
        fixture.evaluator.pump()
        busy = false
        fixture.clock = fixture.clock.addingTimeInterval(59)
        fixture.evaluator.pump()
        #expect(fixture.calls.count == 0)
        #expect(fixture.evaluator.waitReason(record) == .busy(account: "Codex Dev"))
        fixture.clock = fixture.clock.addingTimeInterval(1)
        fixture.evaluator.pump()
        await fixture.evaluator.settle()
        #expect(fixture.calls.count == 1)
        #expect(fixture.evaluator.records[record.id]?.phase == .done)
    }

    // MARK: Review now

    @Test func reviewNowCoversATasksStretchAloneAndMovesOnlyItsCursor() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        fixture.answer(ReviewFixture.reply())
        let other = BotTask(repo: "asieke/GitChu", checkout: "/tmp/GitChu", brief: "Speed up the sync.", accountID: "codex-dev")
        try fixture.turn()
        try fixture.turn(ReviewFixture.turn(other.brief), task: other)
        try fixture.homeTurn([ChatMessage(role: .user, text: "Status?"), ChatMessage(role: .assistant, text: "Two tasks open.")])
        #expect(fixture.evaluator.status(of: fixture.bot.id).text(in: fixture.zone, locale: Locale(identifier: "en_GB"))
                == "Next review at 04:00 · 3 conversations with unreviewed work")
        #expect(fixture.evaluator.canReviewNow(fixture.bot.id, task: ReviewFixture.task.id))
        let record = try #require(await fixture.review(task: ReviewFixture.task.id))
        #expect(record.subject.kind == .task && record.requested == true)
        #expect(record.title.hasPrefix("the work on “\(ReviewFixture.task.title)” up to "))
        #expect(record.covered?.map(\.conversation) == [ReviewConversation(botID: fixture.bot.id, taskID: ReviewFixture.task.id)])
        #expect(fixture.lastSnapshot?.contains("Speed up the sync") == false)
        // Only its cursor moved: the other task and Home wait for the daily review.
        let left = fixture.evaluator.states[fixture.bot.id]?.unreviewed().map(\.conversation.taskID) ?? []
        #expect(Set(left) == [other.id, nil])
        #expect(fixture.evaluator.status(of: fixture.bot.id, task: ReviewFixture.task.id) == .upToDate)
        #expect(!fixture.evaluator.canReviewNow(fixture.bot.id, task: ReviewFixture.task.id))
        #expect(fixture.evaluator.records(ofTask: ReviewFixture.task.id).map(\.id) == [record.id])
        fixture.reachReviewTime()
        await fixture.evaluator.settle()
        let day = try #require(fixture.evaluator.records.values.first { $0.subject.kind == .day })
        #expect(Set(day.covered?.map(\.conversation.taskID) ?? []) == [other.id, nil])
        #expect(fixture.evaluator.records(ofTask: other.id).map(\.id) == [day.id])
        #expect(fixture.evaluator.records(ofTask: ReviewFixture.task.id).map(\.id) == [record.id], "The day didn't cover it again")
        #expect(fixture.evaluator.status(of: fixture.bot.id) == .upToDate)
        #expect(fixture.calls.count == 2)
    }

    // MARK: What Activity says

    @Test func waitReasonAndTheSummaryLineSayWhatTheReviewsAreDoing() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let british = Locale(identifier: "en_GB")
        func line(_ task: UUID? = nil) -> String { fixture.evaluator.status(of: fixture.bot.id, task: task).text(in: fixture.zone, locale: british) }
        #expect(line() == "Off in Settings ▸ Run reviews", "No runner, or turned off")
        let gate = Gate(), calls = fixture.calls
        fixture.evaluator.runner = { job in
            calls.record(job)
            await gate.wait()
            return ReviewFixture.reply()
        }
        #expect(line() == "Up to date")
        try fixture.turn()
        #expect(line() == "Next review at 04:00 · 1 conversation with unreviewed work")
        fixture.evaluator.isEnabled = { false }
        #expect(line() == "Off in Settings ▸ Run reviews")
        fixture.evaluator.isEnabled = { true }
        fixture.evaluator.reviewNow(fixture.bot.id)
        try await fixture.until { calls.count == 1 }
        #expect(line() == "Reviewing on Codex Dev…")
        #expect(line(ReviewFixture.task.id) == "Reviewing on Codex Dev…", "A task's line says so while its work is being reviewed")
        await gate.release()
        await fixture.evaluator.settle()
        #expect(line() == "Up to date")
        let tomorrow = fixture.clock.addingTimeInterval(3_600)
        #expect(ReviewStatus.waiting(.dailyLimit(until: tomorrow), conversations: 1).text(in: fixture.zone, locale: british) == "Waiting · daily limit, next at 04:00")
        #expect(ReviewStatus.waiting(.busy(account: "Claude Personal"), conversations: 2).text() == "Waiting · Claude Personal is busy")
        #expect(ReviewStatus.waiting(.allowance(account: "Codex Dev", until: tomorrow), conversations: 1).text(in: fixture.zone, locale: british)
                == "Waiting · Codex Dev is out of allowance, next try at 04:00")
        #expect(ReviewStatus.waiting(.retrying(at: tomorrow), conversations: 1).text(in: fixture.zone, locale: british) == "Waiting · retrying at 04:00")
        #expect(ReviewStatus.waiting(.another, conversations: 1).text() == "Waiting · another review is running")
        #expect(ReviewStatus.waiting(.unavailable(.antigravity), conversations: 1).text() == "Not reviewed · Antigravity can't run a review without tools")
        #expect(ReviewStatus.waiting(.saving, conversations: 1).text() == "Saving the review…")
        #expect(ReviewCounts(noChange: 5, noSignal: 2).text == "This week: 5 days with no change · 2 without signal · 0 not reviewed in time")
        #expect(ReviewCounts(noChange: 1).text.hasPrefix("This week: 1 day with no change"))
    }

    // MARK: Upgrade

    @Test func perTurnReviewsWaitingFromBeforeTheUpgradeFoldIntoTheNextDailyReviewWithoutAModelCall() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        let home = BotHome(workspace: fixture.bot.workspace)
        let task = ReviewFixture.task
        try home.save(task)
        // Before #138: three turns, the second and third still waiting for their reviews, and a
        // sub-agent run that waited too; the first turn's was done.
        let turns = [ReviewFixture.turn("Reviewed already"), ReviewFixture.turn("Waiting first"), ReviewFixture.turn("Waiting second")]
        try home.saveThread(turns.flatMap { $0 }, task: task.id)
        var run = SubagentRun(rootBotID: fixture.bot.id, rootTaskID: task.id, depth: 1, targetBot: fixture.bot, title: "Look", brief: "Look",
                              workingDirectory: "/tmp")
        run.phase = .failed
        run.errorMessage = "It ran out of time"
        try home.saveSubagent(run)
        func legacy(_ subject: EvaluationSubject, _ phase: EvaluationRecord.Phase, at offset: TimeInterval) throws -> EvaluationRecord {
            var record = EvaluationRecord(subject, bot: fixture.bot, title: "“\(task.title)” turn", at: fixture.clock.addingTimeInterval(offset))
            record.ending = .finished
            record.phase = phase
            if phase == .done { record.outcome = .noChange } else {
                record.snapshot = EvaluationSnapshot(text: "Run: a turn", evidence: [:], toolCalls: 4, failedToolCalls: 1)
            }
            try home.save(record)
            return record
        }
        let done = try legacy(.taskTurn(botID: fixture.bot.id, taskID: task.id, turnID: turns[0][1].id), .done, at: -300)
        let first = try legacy(.taskTurn(botID: fixture.bot.id, taskID: task.id, turnID: turns[1][1].id), .pending, at: -200)
        let second = try legacy(.taskTurn(botID: fixture.bot.id, taskID: task.id, turnID: turns[2][1].id), .running, at: -100)
        let subagent = try legacy(.subagent(run), .pending, at: -150)
        // A record saved before #138 reads as it was.
        let old = try String(contentsOf: home.evaluationURL(first.id), encoding: .utf8)
        #expect(!old.contains("covered") && !old.contains("scheduledFor"))

        fixture.answer(ReviewFixture.reply())
        fixture.evaluator.load(bots: [(fixture.bot.id, fixture.bot.workspace)])
        #expect(fixture.calls.count == 0)
        for id in [first.id, second.id, subagent.id] { #expect(fixture.evaluator.records[id]?.phase == .folded) }
        #expect(fixture.evaluator.records[done.id] == done, "Finished ones stay as they are")
        let stretch = try #require(fixture.evaluator.states[fixture.bot.id]?.unreviewed().first)
        #expect(stretch.from == turns[1][1].id, "From before its oldest waiting turn")
        #expect(stretch.subagents == [run.id])
        #expect(!(fixture.evaluator.records.values.contains { $0.isNews }))
        await fixture.evaluator.storage.settle()
        #expect(BotHome(workspace: fixture.bot.workspace).loadEvaluations().filter { $0.phase == .folded }.count == 3)

        // The bot's next daily review covers them, at the review time.
        fixture.reachReviewTime()
        await fixture.evaluator.settle()
        #expect(fixture.calls.count == 1)
        let text = try #require(fixture.lastSnapshot)
        #expect(text.contains("Owner: Waiting first") && text.contains("Owner: Waiting second"))
        #expect(!text.contains("Reviewed already"))
        #expect(text.contains("Sub-agent run “Look” of Dev Bot"))
        #expect(fixture.evaluator.states[fixture.bot.id]?.unreviewed().isEmpty == true)
    }

    // MARK: Load

    @Test func thirtyFiveRunsADayStayAtOneWaitingReviewPerBotAndOneModelCallADay() async throws {
        let fixture = try ReviewFixture()
        defer { fixture.remove() }
        fixture.evaluator.limits.delay = 60
        let worker = try fixture.addBot("Worker", accountID: "codex-dev")
        var busy = false
        fixture.evaluator.isAccountBusy = { _ in busy }
        fixture.answer(ReviewFixture.reply())
        let tasks = (0..<3).map { BotTask(repo: "asieke/Repo\($0)", checkout: "/tmp/r\($0)", brief: "Work on repository \($0).", accountID: "codex-dev") }
        let home = BotHome(workspace: fixture.bot.workspace)
        var mostWaiting = 0
        for day in 0..<4 {
            // From 08:00, 35 runs over the day: turns across three tasks and Home, five of them
            // delegating a sub-agent to Worker; the account busy most of the time.
            fixture.clock = fixture.clock.addingTimeInterval(5 * 3_600)
            for run in 0..<35 {
                busy = run % 5 != 0
                fixture.clock = fixture.clock.addingTimeInterval(20 * 60)
                let text = "Day \(day) run \(run)"
                if run % 7 == 6 {
                    var subagent = SubagentRun(rootBotID: fixture.bot.id, rootTaskID: tasks[0].id, depth: 1, targetBot: worker, title: text,
                                               brief: text, workingDirectory: "/tmp/r0")
                    subagent.phase = run % 2 == 0 ? .failed : .completed
                    try home.saveSubagent(subagent)
                    try home.saveSubagentThread([ChatMessage(role: .user, text: text), ReviewFixture.tool("Bash", "ls", exit: 0)], id: subagent.id,
                                                taskID: tasks[0].id)
                    fixture.evaluator.subagentEnded(subagent)
                } else if run % 4 == 3 {
                    try fixture.homeTurn([ChatMessage(role: .user, text: text), ChatMessage(role: .assistant, text: "Done.")])
                } else {
                    try fixture.turn(ReviewFixture.turn(text), task: tasks[run % 3])
                }
                fixture.evaluator.pump()
                #expect(fixture.evaluator.records.values.allSatisfy { !$0.phase.isWaiting }, "More runs never add reviews")
            }
            // The night: idle, then the review time.
            busy = false
            fixture.reachReviewTime()
            for bot in [fixture.bot.id, worker.id] {
                mostWaiting = max(mostWaiting, fixture.evaluator.records.values.filter { $0.botID == bot && $0.phase.isWaiting }.count)
            }
            fixture.clock = fixture.clock.addingTimeInterval(60)
            fixture.evaluator.pump()
            await fixture.evaluator.settle()
            fixture.evaluator.pump()
            await fixture.evaluator.settle()
            let calls = fixture.calls.all
            #expect(calls.filter { $0.botID == fixture.bot.id }.count == day + 1, "One model call a day for the bot")
            #expect(calls.filter { $0.botID == worker.id }.count == day + 1, "And one for Worker, whose sub-agent runs had signal")
            #expect(fixture.evaluator.states.values.allSatisfy { $0.unreviewed().isEmpty }, "Every day's work reviewed")
        }
        #expect(mostWaiting == 1, "At most one review a bot waits")
        #expect(fixture.evaluator.records.values.filter { $0.phase == .done }.count == 8)
        #expect(fixture.calls.count == 8)
    }
}
