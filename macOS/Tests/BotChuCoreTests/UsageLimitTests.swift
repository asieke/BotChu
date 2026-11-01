import Foundation
import Testing
@testable import BotChuCore

/// #442: a turn or run whose account hit a usage limit pauses until the limit resets, then carries
/// on; any other failed turn is retried once.
@Suite struct UsageLimitTests {
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: Parsing the CLIs' failure text

    /// Real samples: the v1.1 batch's sub-agent handoff (/Users/…/batch-v1.1/428-handoff.txt) and
    /// failed turns in the bots' transcripts, with the times they failed at (UTC).
    @Test func claudeLimitFailuresGiveTheirReset() {
        let handoff = """
            === Sub-agent: 10x Engineer Bot (6097fd33-c64a-4df8-81b0-4f02cfd01233) ===
            You've hit your 5-hour limit · resets 12:10am (America/New_York)
            Error: You've hit your 5-hour limit · resets 12:10am (America/New_York)

            It ended after 52 tool calls in 14m 49s.
            Status: failed
            """
        #expect(UsageLimit.resetDate(in: handoff, now: date("2026-11-01T02:40:00Z")) == date("2026-11-01T04:10:00Z"))
        #expect(UsageLimit.resetDate(in: "You've hit your 5-hour limit · resets 2pm (America/New_York)",
                                     now: date("2026-10-28T16:55:11Z")) == date("2026-10-28T18:00:00Z"))
        #expect(UsageLimit.resetDate(in: "You've hit your session limit · resets 8:30pm (America/New_York)",
                                     now: date("2026-10-24T21:48:24Z")) == date("2026-10-25T00:30:00Z"))
        #expect(UsageLimit.resetDate(in: "You've hit your session limit · resets 10:30am (America/New_York)",
                                     now: date("2026-10-24T13:14:37Z")) == date("2026-10-24T14:30:00Z"))
        // Claude Code's earlier JSON result (RunEvaluationTests keeps the same sample).
        #expect(UsageLimit.resetDate(in: "Error: Claude AI usage limit reached|1761318000") == Date(timeIntervalSince1970: 1_761_318_000))
    }

    @Test func aTimeOfDayIsTheNextOneButOneJustPassedIsToday() {
        let text = "You've hit your 5-hour limit · resets 12:10am (America/New_York)"
        // Before midnight: tonight's. Two minutes after: the one that just passed, not tomorrow's.
        #expect(UsageLimit.resetDate(in: text, now: date("2026-11-01T03:59:00Z")) == date("2026-11-01T04:10:00Z"))
        #expect(UsageLimit.resetDate(in: text, now: date("2026-11-01T04:12:00Z")) == date("2026-11-01T04:10:00Z"))
        #expect(UsageLimit.resetDate(in: text, now: date("2026-11-01T05:00:00Z")) == date("2026-11-02T05:10:00Z"))
        // Without a zone, the Mac's.
        #expect(UsageLimit.resetDate(in: "You've hit your 5-hour limit · resets 3pm", now: date("2026-10-28T16:00:00Z"),
                                     timeZone: newYork) == date("2026-10-28T19:00:00Z"))
    }

    /// The form a reset that isn't today takes (weekly limits); no real sample captured yet.
    @Test func aResetWithADateIsThatDay() {
        #expect(UsageLimit.resetDate(in: "You've hit your weekly limit · resets Nov 3, 9am (America/New_York)",
                                     now: date("2026-11-01T12:00:00Z")) == date("2026-11-03T14:00:00Z"))
        #expect(UsageLimit.resetDate(in: "You've hit your weekly limit · resets Jan 2, 9am (America/New_York)",
                                     now: date("2026-12-30T12:00:00Z")) == date("2027-01-02T14:00:00Z"))
    }

    @Test func otherFailuresAreNoLimitWithAReset() {
        #expect(UsageLimit.resetDate(in: "Reconnecting... 5/5 (stream disconnected before completion: error sending request)") == nil)
        #expect(UsageLimit.resetDate(in: "usage limit reached") == nil)
        #expect(UsageLimit.resetDate(in: "429 Too Many Requests: usage limit reached") == nil)
        #expect(UsageLimit.resetDate(in: "The build resets at 3pm every day.") == nil)
        #expect(UsageLimit.resetDate(in: "") == nil)
    }

    @Test func pausedTimesReadAsTheCLIsDo() {
        let now = date("2026-10-31T23:00:00Z")
        #expect(UsageLimit.pausedText(until: date("2026-11-01T04:10:00Z"), now: date("2026-11-01T03:00:00Z"), timeZone: newYork)
            == "Paused until 12:10am")
        #expect(UsageLimit.timeText(date("2026-10-31T22:00:00Z"), now: now, timeZone: newYork) == "6pm")
        #expect(UsageLimit.timeText(date("2026-11-01T04:10:00Z"), now: now, timeZone: newYork) == "12:10am")
        #expect(UsageLimit.timeText(date("2026-11-03T14:00:00Z"), now: now, timeZone: newYork) == "Tue 9am")
        #expect(UsageLimit.timeText(date("2026-11-20T14:00:00Z"), now: now, timeZone: newYork) == "Nov 20, 9am")
    }

    // MARK: Heartbeat

    @Test func aLimitFailurePausesUntilAMinuteAfterTheReset() {
        let reset = date("2026-11-01T04:10:00Z"), now = date("2026-11-01T02:40:00Z")
        let turn = Heartbeat.Turn(reply: nil, failed: true, limitResetsAt: reset)
        #expect(Heartbeat.next(after: turn, now: now) == .paused(until: reset, resume: date("2026-11-01T04:11:00Z")))
        // Also when it answered a heartbeat: each reset is a new chance.
        #expect(Heartbeat.next(after: .init(reply: nil, pulse: 1, limitResetsAt: reset), now: now)
            == .paused(until: reset, resume: date("2026-11-01T04:11:00Z")))
        #expect(Heartbeat.next(after: .init(reply: nil, stopped: true, limitResetsAt: reset), now: now) == .none)
    }

    @Test func aResetThatJustPassedWaitsFiveMinutes() {
        let reset = date("2026-11-01T04:10:00Z")
        #expect(Heartbeat.resumeDate(after: reset, now: date("2026-11-01T04:12:00Z")) == date("2026-11-01T04:17:00Z"))
        #expect(Heartbeat.resumeDate(after: reset, now: date("2026-11-01T04:10:30Z")) == date("2026-11-01T04:11:00Z"))
    }

    @Test func anyOtherFailureIsRetriedOnceThenLeftFailed() {
        #expect(Heartbeat.next(after: .init(reply: "Working on it", failed: true)) == .pulse(number: 1, after: 120, stall: .failed))
        // The retry failed too: no more pulses.
        #expect(Heartbeat.next(after: .init(reply: nil, pulse: 1, failed: true)) == .none)
    }

    @Test func theRetryAndResetHeartbeatsSayWhatHappened() {
        let retry = Heartbeat.prompt(.failed, number: 1, error: "stream disconnected\nmore detail")
        #expect(retry.contains("your last turn failed (“stream disconnected”)"))
        #expect(!retry.contains("more detail"))
        #expect(retry.hasSuffix("reply with just HEARTBEAT_OK."))
        #expect(Heartbeat.label(number: 1, text: retry) == "Heartbeat: retrying the failed turn")

        let bot = Bot(name: "10x Engineer Bot", workspace: "/bots/10x")
        let run = SubagentRun(rootBotID: bot.id, depth: 1, targetBot: bot, title: "#442", brief: "Fix", workingDirectory: "/repo")
        let reset = Heartbeat.limitPrompt(turnPaused: true, resumed: [run])
        #expect(reset.contains("paused your last turn has reset"))
        #expect(reset.contains("- \(run.id.uuidString.lowercased()) “#442” (10x Engineer Bot)"))
        #expect(reset.contains("botchu-subagent wait <id>"))
        #expect(reset.hasSuffix("reply with just HEARTBEAT_OK."))
        #expect(Heartbeat.limitPrompt(turnPaused: false, resumed: [run]).contains("paused sub-agent runs you started has reset"))
        #expect(Heartbeat.label(number: 1, text: reset) == "Heartbeat: carrying on after the usage limit reset")
        #expect(Heartbeat.label(number: 2, text: Heartbeat.prompt(.promised, number: 2)) == "Heartbeat 2 of 3: checking on unfinished work")
    }

    // MARK: Runs

    private let bot = Bot(name: "10x Engineer Bot", workspace: "/bots/10x")
    private let limit = "You've hit your 5-hour limit · resets 12:10am (America/New_York)"

    private func failed(_ error: String, pauses: Bool = true, parent: SubagentRun? = nil, now: Date) -> SubagentRun {
        var record = SubagentRun(rootBotID: bot.id, parentSubagentID: parent?.id, depth: (parent?.depth ?? 0) + 1, targetBot: bot,
                                 title: "#442", brief: "Fix", workingDirectory: "/repo", phase: .failed)
        record.startedAt = now.addingTimeInterval(-600)
        record.errorMessage = error
        var messages = [ChatMessage(role: .tool, text: "Bash", toolName: "Bash", toolInput: "swift test")]
        SubagentTerminalOutcome.apply(to: &record, messages: &messages, toolCalls: 52, cause: nil, workspace: nil,
                                      pausesOnLimit: pauses, now: now)
        return record
    }

    @Test func aRunThatHitALimitIsPausedAndResumable() throws {
        let now = date("2026-11-01T02:40:00Z")
        let run = failed(limit, now: now)
        #expect(run.pausedUntil == date("2026-11-01T04:10:00Z"))
        #expect(run.isResumable)
        #expect(run.errorMessage?.hasPrefix(limit) == true)
        #expect(run.errorMessage?.contains("BotChu resumes it then") == true)
        let row = SubagentRowState(run, now: now)
        #expect(row.kind == .paused)
        #expect(row.word == "Paused until " + UsageLimit.timeText(date("2026-11-01T04:10:00Z"), now: now))
        #expect(LimitResume.resumeDate(of: run) == date("2026-11-01T04:11:00Z"))
        // The reset survives the record's save and a relaunch's read.
        let decoded = try JSONDecoder().decode(SubagentRun.self, from: JSONEncoder().encode(run))
        #expect(decoded.pausedUntil == run.pausedUntil)

        // Off (the heartbeat setting), or another failure: Failed, as before.
        #expect(failed(limit, pauses: false, now: now).pausedUntil == nil)
        let other = failed("stream disconnected", now: now)
        #expect(other.pausedUntil == nil)
        #expect(other.isResumable)
        #expect(SubagentRowState(other).kind == .failed)
        // Relaunched, it is under way and no longer paused.
        var resumed = run
        resumed.phase = .preparing
        #expect(resumed.pausedUntil == nil)
    }

    @Test func anInterruptionSavedBeforeHasNoReset() throws {
        let older = Data(#"{"cause":"failed","at":0,"toolCalls":3}"#.utf8)
        #expect(try JSONDecoder().decode(SubagentInterruption.self, from: older).resetsAt == nil)
    }

    @Test func pausedRunsStayInViewWithoutCountingAsFailed() {
        let now = date("2026-11-01T02:40:00Z")
        let parent = SubagentRun(rootBotID: bot.id, depth: 1, targetBot: bot, title: "Batch", brief: "Run", workingDirectory: "/repo",
                                 phase: .completed)
        let child = failed(limit, parent: parent, now: now)
        let overview = SubagentOverview(runs: [parent, child])
        #expect(overview.failedBelow(parent.id) == 0)
        #expect(overview.finished.isEmpty)
        #expect(overview.visible.flatMap(\.roots).map(\.id) == [parent.id])
    }

    // MARK: Carrying on

    @Test func dueTurnsAndRunsAreGroupedByConversationAndChildrenLeftToTheirParent() {
        let now = date("2026-11-01T02:40:00Z")
        let parent = failed(limit, now: now)
        let child = failed(limit, parent: parent, now: now)
        let other = failed("stream disconnected", now: now)
        #expect(LimitResume.candidates([parent, child, other], tried: []).map(\.id) == [parent.id])
        #expect(LimitResume.candidates([parent, child, other], tried: [parent.id]).isEmpty)

        let task = UUID()
        var book = LimitPauseBook()
        book.pause(.init(botID: bot.id, taskID: nil, resetsAt: date("2026-11-01T04:10:00Z"), resumeAt: date("2026-11-01T04:11:00Z")))
        book.pause(.init(botID: bot.id, taskID: task, resetsAt: date("2026-11-01T09:00:00Z"), resumeAt: date("2026-11-01T09:01:00Z")))
        #expect(LimitResume.nextWake(book: book, runs: [parent, child], tried: []) == date("2026-11-01T04:11:00Z"))
        let early = LimitResume.due(book: &book, runs: [parent, child], tried: [], now: date("2026-11-01T04:00:00Z"))
        #expect(early.isEmpty)

        let due = LimitResume.due(book: &book, runs: [parent, child, other], tried: [], now: date("2026-11-01T04:11:01Z"))
        #expect(due == [LimitResume.Due(botID: bot.id, taskID: nil, turnPaused: true, runs: [parent.id])])
        #expect(book.entries.map(\.taskID) == [task])
        #expect(LimitResume.nextWake(book: book, runs: [parent, child], tried: Set([parent.id, child.id])) == date("2026-11-01T09:01:00Z"))
    }

    @Test func aRunPausedAloneStillWakesItsConversation() {
        let run = failed(limit, now: date("2026-11-01T02:40:00Z"))
        var book = LimitPauseBook()
        let due = LimitResume.due(book: &book, runs: [run], tried: [], now: date("2026-11-01T04:12:00Z"))
        #expect(due == [LimitResume.Due(botID: bot.id, taskID: nil, turnPaused: false, runs: [run.id])])
    }

    /// Given BotChu relaunches before the reset, the pause survives and still fires.
    @Test func aPauseOutlivesARelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("limit-pauses.json")
        #expect(LimitPauseBook.load(url).entries.isEmpty)
        var book = LimitPauseBook()
        let task = UUID()
        book.pause(.init(botID: bot.id, taskID: task, resetsAt: date("2026-11-01T04:10:00Z"), resumeAt: date("2026-11-01T04:11:00Z")))
        try book.save(url)

        var relaunched = LimitPauseBook.load(url)
        #expect(relaunched == book)
        #expect(LimitResume.nextWake(book: relaunched, runs: [], tried: []) == date("2026-11-01T04:11:00Z"))
        let due = LimitResume.due(book: &relaunched, runs: [], tried: [], now: date("2026-11-01T04:11:00Z"))
        #expect(due.map(\.taskID) == [task])
        // Once nothing is paused, the file goes.
        try relaunched.save(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A message to the conversation ends its pause; a deleted conversation's goes.
        book.pause(.init(botID: bot.id, taskID: nil, resetsAt: Date(), resumeAt: Date()))
        let cleared = book.clear(botID: bot.id, taskID: nil), again = book.clear(botID: bot.id, taskID: nil)
        #expect(cleared && !again)
        book.prune { _, taskID in taskID != task }
        #expect(book.entries.isEmpty)
    }
}
