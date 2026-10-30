import Foundation
import Testing
@testable import BotChuCore

/// #345: the loop a chat turn, a sub-agent's run and a job's run share, fed the CLIs' captured
/// output in batches as `AgentRun` delivers it.
@MainActor @Suite struct TurnStreamTests {
    /// One turn: its parser, its stream, and the conversation and run state it writes.
    @MainActor final class Feed {
        var stream: TurnStream
        var parser: any StreamParser
        var messages: [ChatMessage] = []
        var state: RunState? = RunState()
        var ledger: InputLedger?
        private(set) var writes = 0

        init(_ accountID: String, invocation: Invocation = Invocation(arguments: []), takesInput: Bool = false) {
            stream = TurnStream(account: Accounts.account(id: accountID), invocation: invocation)
            parser = stream.parser()
            ledger = takesInput ? InputLedger() : nil
        }

        func events(_ lines: [String]) -> [AgentEvent] { lines.flatMap { parser.parse(line: $0) } }

        func apply(_ events: [AgentEvent], stopped: Bool = false, followUp: @escaping () -> ChatMessage? = { nil }) -> TurnStream.Batch? {
            stream.apply(events, state: &state, stopped: stopped, ledger: &ledger, followUp: followUp) { write in
                writes += 1
                write(&messages)
            }
        }

        func apply(_ lines: [String], stopped: Bool = false, followUp: @escaping () -> ChatMessage? = { nil }) -> TurnStream.Batch? {
            apply(events(lines), stopped: stopped, followUp: followUp)
        }
    }

    @Test func aClaudeTurnGivesItsSessionAndEnds() throws {
        let feed = Feed("claude-personal")
        let batch = try #require(feed.apply(ClaudeParserTests().lines))
        #expect(batch.sessions == ["51e64f5b-b2d8-4840-ba1a-81f82d98972a"])
        #expect(batch.followUps.isEmpty)
        #expect(!batch.closesInput)
        #expect(feed.messages.map(\.role) == [.tool, .assistant])
        #expect(feed.messages.last?.text == "Empty.")
        #expect(feed.stream.outcome.ended)
        #expect(feed.stream.outcome.failure == nil)
        #expect(feed.state?.hasOutput == true)
    }

    @Test func aCodexTurnResumesByTheIDItReportsAndAnErrorItRecoveredFromIsNoFailure() throws {
        let feed = Feed("codex-dev")
        let batch = try #require(feed.apply(CodexParserTests().lines))
        #expect(batch.sessions == ["01a16190-3b37-70b1-b6c1-9b751c29d226"])
        #expect(feed.messages.map(\.role) == [.assistant, .tool, .assistant])
        #expect(feed.stream.outcome.ended)

        // #43: a reconnect before the turn completed (a sub-agent's run once failed for it).
        let reconnected = Feed("codex-dev")
        _ = reconnected.apply([
            #"{"type":"thread.started","thread_id":"t"}"#,
            #"{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion)"}"#,
            #"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"Done"}}"#,
            #"{"type":"turn.completed","usage":{}}"#,
        ])
        #expect(reconnected.stream.outcome.ended)
        #expect(reconnected.stream.outcome.failure == nil)
    }

    /// Muse, Pi and Sail resume by the id BotChu gave them; the others by the one they report.
    @Test func sessionsAreTheIDsTheirTurnsResumeBy() throws {
        let given = Invocation(arguments: [], sessionID: "given")
        for (accountID, expected) in [("muse", "given"), ("openrouter", "given"), ("sail", "given"),
                                      ("claude-personal", "reported"), ("codex-dev", "reported"), ("google", "reported")] {
            let batch = try #require(Feed(accountID, invocation: given).apply([AgentEvent.session("reported")]))
            #expect(batch.sessions == [expected], "\(accountID)")
        }
    }

    @Test func theModelTheCLIReportsAndAnAntigravityTurnThatWaitedForItsBackgroundTask() throws {
        let claude = Feed("claude-personal")
        #expect(try #require(claude.apply(ClaudeInputSamples.followUpDuringALongTool)).reportedModel == "claude-haiku-5-5")

        let antigravity = Feed("google")
        _ = antigravity.apply(CLIExitTests.backgroundTurn)
        #expect(antigravity.stream.outcome.ended)
        #expect(antigravity.messages.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
            .contains("Background command `sleep 40` has finished (exit code 0)."))
    }

    /// The CLI's first output can hold no events: it has started, and nothing is written.
    @Test func aBatchWithoutEventsOnlyMarksTheRunStarted() {
        let feed = Feed("claude-personal")
        #expect(feed.apply([AgentEvent]()) == nil)
        #expect(feed.state?.hasOutput == true)
        #expect(feed.writes == 0)
        #expect(feed.messages.isEmpty)
    }

    /// A tool's activity shows at least `RunState.minimumShow`, then thinking takes over.
    @Test func thinkingWaitsUntilATooQuickToolHasShown() throws {
        let feed = Feed("claude-personal")
        let batch = try #require(feed.apply([.toolStarted(id: "t", name: "Edit", input: "README.md"),
                                             .toolFinished(id: "t", name: "Edit", output: "ok", isError: false)]))
        #expect(feed.state?.activity == .coding)
        #expect(feed.state?.pending == .thinking)
        #expect(batch.settles.count == 1)
        #expect(batch.settles.allSatisfy { $0 > RunState.minimumShow - 0.5 && $0 <= RunState.minimumShow })
    }

    @Test func settleCallsBackOnceEachWaitIsOver() async {
        var batch = TurnStream.Batch()
        batch.settles = [0.01, 0.02]
        var calls = 0
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            batch.settle {
                calls += 1
                if calls == 2 { done.resume() }
            }
        }
        #expect(calls == 2)
    }

    /// After Stop, a CLI's failure is about the interruption; the "Stopped" note says it.
    @Test func afterStopTheCLIsFailureIsLeftOut() {
        let events: [AgentEvent] = [.textDelta("Partial"), .failed("Interrupted")]
        let stopped = Feed("google")
        _ = stopped.apply(events, stopped: true)
        #expect(stopped.messages.map(\.role) == [.assistant])
        #expect(!stopped.stream.outcome.ended)

        let failed = Feed("google")
        _ = failed.apply(events)
        #expect(failed.messages.map(\.role) == [.assistant, .error])
        #expect(failed.stream.outcome.failure == "Interrupted")
    }

    /// #223: a follow-up written during a long tool call joins the thread where the CLI took it,
    /// after the call's result and before the reply, and the CLI's input closes as the turn ends.
    @Test func aFollowUpJoinsTheThreadWhereTheCLITookIt() throws {
        let lines = ClaudeInputSamples.followUpDuringALongTool
        let feed = Feed("claude-personal", takesInput: true)
        let steer = ChatMessage(role: .user, text: "Also add the word PELICAN to your final reply.")
        var asked = 0
        let followUp = { () -> ChatMessage? in asked += 1; return steer }
        // The prompt's echo and the tool call: it takes follow-ups from now on.
        let first = try #require(feed.apply(Array(lines.prefix(2)), followUp: followUp))
        #expect(feed.state?.takesInput == true)
        #expect(first.followUps.isEmpty)
        #expect(asked == 0)
        #expect(feed.ledger?.acceptsFollowUps == true)
        feed.ledger?.wrote()

        let rest = try #require(feed.apply(Array(lines.dropFirst(2)), followUp: followUp))
        #expect(asked == 1)
        #expect(rest.followUps == [steer])
        #expect(feed.messages.map(\.role) == [.tool, .user, .assistant])
        #expect(feed.messages.last?.text == "slept PELICAN")
        #expect(rest.closesInput)
        #expect(feed.state?.takesInput == false)
        #expect(feed.stream.outcome.ended)
    }

    /// #223: Stop while a follow-up waits on stdin: the CLI never takes it, so it stays queued.
    @Test func aFollowUpTheStoppedCLINeverTookStaysQueued() throws {
        let lines = ClaudeInputSamples.stoppedWithAnUntakenFollowUp
        let feed = Feed("claude-personal", takesInput: true)
        _ = feed.apply(Array(lines.prefix(1)))
        feed.ledger?.wrote()
        let rest = try #require(feed.apply(Array(lines.dropFirst()), stopped: true, followUp: { Issue.record("Not taken"); return nil }))
        #expect(rest.followUps.isEmpty)
        #expect(!rest.closesInput)
        #expect(!feed.messages.contains { $0.role == .error })
    }

    @Test func closingEndsTheReplyAndInterruptsToolsStillRunning() {
        let feed = Feed("codex-dev")
        _ = feed.apply([.toolStarted(id: "t", name: "Shell", input: "sleep 90"), .textDelta("Waiting \n")])
        feed.stream.close(&feed.messages)
        #expect(feed.messages.map(\.toolState) == [.interrupted, nil])
        #expect(feed.messages.last?.text == "Waiting")
    }

    @Test func theEndNoteSaysWhyTheTurnEndedAsItDid() {
        let refused = "ssh: connect to host studio port 22: Connection refused\n"
        let silent = TurnStream(account: Accounts.account(id: "codex-dev"), invocation: Invocation(arguments: []))
        func note(_ stream: TurnStream = silent, status: Int32 = 0, stderr: String = "", stopped: Bool = false, byOwner: Bool = true,
                  lingered: Bool = false, host: String? = nil) -> ChatMessage? {
            stream.endNote(status: status, stderr: stderr, stopped: stopped, byOwner: byOwner, lingered: lingered, host: host)
        }
        #expect(note(stopped: true)?.text == "Stopped")
        #expect(note(stopped: true)?.stopped == true)
        // BotChu stopped it to quit, or Interrupt & send did.
        #expect(note(stopped: true, byOwner: false)?.stopped == nil)
        #expect(note(stopped: true, lingered: true)?.text == "Stopped")
        // #145: its turn stands.
        #expect(note(status: 15, lingered: true)?.role == .note)
        #expect(note(status: 15, lingered: true)?.text == "Codex Dev didn't exit after its reply, so BotChu ended it.")
        #expect(note(status: 255, stderr: refused, host: "Studio")?.text == "Couldn't reach Studio over SSH:\nssh: connect to host studio port 22: Connection refused")
        #expect(note(status: 255, host: "Studio")?.text == "Couldn't reach Studio over SSH.")
        #expect(note(status: 255, stderr: refused)?.text == "Codex Dev exited with status 255:\nssh: connect to host studio port 22: Connection refused")
        #expect(note(status: 1)?.role == .error)
        #expect(note(status: 1)?.text == "Codex Dev exited with status 1 without replying.")

        // The stream said the turn ended: an exit status after it says nothing more.
        let feed = Feed("codex-dev")
        _ = feed.apply([.finished])
        #expect(note(feed.stream, status: 1, stderr: "warning") == nil)
        #expect(note(feed.stream, status: 255, host: "Studio") == nil)
    }

    @Test func lastLinesKeepsTheLastFewLinesThatSaySomething() {
        let stderr = (1...10).map { "  line \($0)  " }.joined(separator: "\n\n") + "\n"
        #expect(TurnStream.lastLines(stderr) == (3...10).map { "line \($0)" }.joined(separator: "\n"))
        #expect(TurnStream.lastLines(stderr, count: 2) == "line 9\nline 10")
        #expect(TurnStream.lastLines(" \n\n") == "")
    }
}
