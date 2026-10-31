import Foundation
import Testing
@testable import BotChuCore

/// #368: a run BotChu interrupted ends Interrupted, saying how far it got, and a loaded Mac's late
/// heartbeat doesn't make a waiting helper give up on runs still going.
@Suite struct SubagentInterruptionTests {
    private let bot = Bot(name: "QA Bot", workspace: "/tmp/qa")
    private let started = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ phase: SubagentPhase = .stopped, directory: String = "/Users/me/repo/.claude/worktrees/feat-x") -> SubagentRun {
        var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Fix the parser", brief: "Fix it",
                              workingDirectory: directory, phase: phase)
        run.startedAt = started
        return run
    }

    @Test func oldRecordsDecodeAndInterruptedRunsStayStoppedOnDisk() throws {
        // A record saved before #368 has no interruption: it still says Stopped.
        var old = run()
        old.errorMessage = "Stopped"
        let saved = try SubagentIPC.decode(SubagentRun.self, from: SubagentIPC.encode(old))
        #expect(saved.interruption == nil && !saved.isInterrupted)
        #expect(SubagentRowState(saved).word == "Stopped")
        #expect(SubagentRowState(saved).kind == .stopped)

        var interrupted = run()
        interrupted.interruption = SubagentInterruption(cause: .owner, at: started.addingTimeInterval(750), toolCalls: 84,
                                                        lastAction: "Ran `bun run test`")
        let data = try SubagentIPC.encode(interrupted)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Every reader and installed helper keeps reading a stopped run.
        #expect(object["phase"] as? String == "stopped")
        let decoded = try SubagentIPC.decode(SubagentRun.self, from: data)
        #expect(decoded.isInterrupted)
        #expect(decoded.interruption?.toolCalls == 84)
        #expect(SubagentRowState(decoded).word == "Interrupted" && SubagentRowState(decoded).kind == .interrupted)
        // Only a stopped run is Interrupted; a failure with the same facts still says Failed.
        var failed = interrupted
        failed.phase = .failed
        #expect(!failed.isInterrupted && SubagentRowState(failed).word == "Failed")
    }

    @Test func anInterruptionFromALaterBotChuStillDecodes() throws {
        let json = #"{"cause":"somethingNew","at":"2027-01-15T08:00:00Z","toolCalls":3,"extra":true}"#
        let decoded = try SubagentIPC.decode(SubagentInterruption.self, from: Data(json.utf8))
        #expect(decoded.cause == .failed && decoded.toolCalls == 3 && decoded.lastAction == nil)
    }

    @Test func theResultSaysInterruptedAndOlderResultsDecode() throws {
        var interrupted = run()
        interrupted.interruption = SubagentInterruption(cause: .parentEnded)
        #expect(interrupted.result.interrupted == true)
        #expect(run(.completed).result.interrupted == nil)
        let old = #"{"id":"6E1F0A2B-3C4D-4E5F-8A9B-0C1D2E3F4A5B","targetBotName":"QA","phase":"stopped","handoffOutput":"","finishedAt":"2027-01-15T08:00:00Z"}"#
        #expect(try SubagentIPC.decode(SubagentResult.self, from: Data(old.utf8)).interrupted == nil)
    }

    @Test func theOutcomeSaysWhatStoppedItHowFarItGotAndWhatItLeft() {
        let record = run()
        let workspace = SubagentWorkspaceState(branch: "feat/x", head: "abc1234 Fix parser", uncommitted: ["a.swift", "b.swift", "c.swift"])
        let owner = SubagentInterruption(cause: .owner, at: started.addingTimeInterval(750), toolCalls: 84,
                                         lastAction: "`bun run test`", workspace: workspace)
        #expect(owner.outcome(for: record) == "The owner stopped it after 84 tool calls in 12m 30s. Last action: `bun run test`. "
            + "Workspace: /Users/me/repo/.claude/worktrees/feat-x on `feat/x` at `abc1234 Fix parser`, 3 uncommitted: `a.swift`, `b.swift`, `c.swift`.")
        let clean = SubagentInterruption(cause: .parentEnded, at: started.addingTimeInterval(5), toolCalls: 1,
                                         workspace: SubagentWorkspaceState(branch: "main", head: "f00ba44 Init"))
        #expect(clean.outcome(for: record) == "The turn that called it ended before its handoff, after 1 tool call in 5s. "
            + "Workspace: /Users/me/repo/.claude/worktrees/feat-x on `main` at `f00ba44 Init`, nothing uncommitted.")
        let restart = SubagentInterruption(cause: .restart, at: started.addingTimeInterval(3_700))
        #expect(restart.outcome(for: record) == "BotChu quit or restarted while it ran, before any tool call. "
            + "Workspace: /Users/me/repo/.claude/worktrees/feat-x.")
        let many = SubagentWorkspaceState(uncommitted: (1...25).map { "file\($0).swift" }, uncommittedCount: 40)
        let text = SubagentInterruption(cause: .parentStopped, workspace: many).outcome(for: record)
        #expect(text.contains("40 uncommitted: `file1.swift`") && text.contains("`file20.swift` and 20 more."))
        #expect(!text.contains("file21"))
    }

    /// The D-5 failure: Claude Code's result says only `[ede_diagnostic] … stop_reason=tool_use`.
    @Test func aRawDiagnosticBecomesWhatHappenedWithTheRunsFacts() {
        let record = run(.failed)
        let failed = SubagentInterruption(cause: .failed, at: started.addingTimeInterval(42), toolCalls: 1, lastAction: "`ls`")
        let text = failed.outcome(for: record, failure: "[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use")
        #expect(!text.contains("ede_diagnostic"))
        #expect(text == "Its CLI ended its turn in the middle of a tool call, without a reply.\n\n"
            + "It ended after 1 tool call in 42s. Last action: `ls`. Workspace: /Users/me/repo/.claude/worktrees/feat-x.")
        // Any other failure keeps what it said, first.
        let plain = failed.outcome(for: record, failure: "Codex Work ended without a successful handoff (exit 1). quota exceeded")
        #expect(plain.hasPrefix("Codex Work ended without a successful handoff (exit 1). quota exceeded\n\nIt ended after 1 tool call"))
        #expect(SubagentInterruption.failureText("boom\n[ede_diagnostic] result_type=user") == "boom Its CLI ended its turn without a reply.")
    }

    @Test func itsFactsComeFromTheTranscriptAndAreBoundedToOneLine() {
        let messages = [
            ChatMessage(role: .tool, toolName: "Read", toolInput: "/Users/me/repo/README.md", toolState: .done),
            ChatMessage(role: .assistant, text: "Running the tests"),
            ChatMessage(role: .tool, toolName: "Bash", toolInput: "swift test\n--filter `Parser`", toolState: .interrupted),
        ]
        let interruption = SubagentInterruption.of(messages, toolCalls: 12, cause: .owner, root: "/Users/me/repo")
        #expect(interruption.toolCalls == 12)
        // The command as it ran, on one line, its own backticks unable to end the code span.
        #expect(interruption.lastAction == "`swift test --filter 'Parser'`")
        #expect(SubagentInterruption.of(messages, cause: .owner).toolCalls == 2)
        #expect(SubagentInterruption.action(messages[0], root: "/Users/me/repo").contains("README.md"))
        let long = ChatMessage(role: .tool, toolName: "Bash", toolInput: String(repeating: "x", count: 500))
        #expect(SubagentInterruption.action(long).count == 152)
    }

    @Test func theWorkspaceIsReadFromPorcelainStatus() {
        let output = "branch\tfeat/368-x\nhead\tabc1234 Add `thing`\n M macOS/a.swift\n?? new file.txt\nR  old.swift -> renamed.swift\n"
        let state = SubagentWorkspaceState.parse(output)
        #expect(state?.branch == "feat/368-x")
        #expect(state?.head == "abc1234 Add 'thing'")
        #expect(state?.uncommitted == ["macOS/a.swift", "new file.txt", "renamed.swift"])
        #expect(state?.uncommittedCount == 3)
        // Detached, nothing committed yet: no branch, no head.
        #expect(SubagentWorkspaceState.parse("branch\t\nhead\t\n") == SubagentWorkspaceState())
        // Not a checkout: the script prints nothing.
        #expect(SubagentWorkspaceState.parse("") == nil)
    }

    @Test func theWorkspaceOfARealCheckoutAndOfAPlainFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-368-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await SubagentWorkspaceState.read(folder.path) == nil)
        func git(_ arguments: String...) async {
            _ = await ChildProcess.run("/usr/bin/git", ["-c", "user.name=T", "-c", "user.email=t@example.com"] + arguments, in: folder.path,
                                       environment: ["PATH": "/usr/bin:/bin", "HOME": folder.path], timeout: 30)
        }
        await git("init", "-q", "-b", "feat/resume")
        try Data("one".utf8).write(to: folder.appendingPathComponent("a.txt"))
        await git("add", "a.txt")
        await git("commit", "-q", "-m", "First commit")
        try Data("two".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("new".utf8).write(to: folder.appendingPathComponent("b.txt"))
        let state = try #require(await SubagentWorkspaceState.read(folder.path))
        #expect(state.branch == "feat/resume")
        #expect(state.head?.hasSuffix(" First commit") == true)
        #expect(state.uncommitted.sorted() == ["a.txt", "b.txt"])
        // Reading it wrote nothing: no index lock left behind, nothing staged.
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git/index.lock").path))
    }

    @MainActor @Test func aStoppedTurnsNoteSaysHowFarItGot() {
        var stream = TurnStream(account: Accounts.account(id: "codex-dev"), invocation: Invocation(arguments: []))
        var state: RunState? = RunState()
        var messages: [ChatMessage] = []
        let events: [AgentEvent] = [
            .toolStarted(id: "1", name: "Bash", input: "ls"), .toolFinished(id: "1", name: "Bash", output: "", isError: false),
            .toolStarted(id: "2", name: "Bash", input: "bun run test"),
            // The same call again, as Claude Code reports its input once known: one call.
            .toolStarted(id: "2", name: "Bash", input: "bun run test"),
        ]
        _ = stream.apply(events, state: &state) { write in write(&messages) }
        let note = stream.endNote(status: 130, stderr: "", stopped: true, byOwner: true, lingered: false)
        #expect(note?.text.hasPrefix("Stopped after 2 tool calls. Last action: ") == true)
        #expect(note?.text.contains("bun run test") == true)
        #expect(note?.stopped == true && note?.isStopNote == true)
        // A turn that ran no tools still says just "Stopped".
        let quiet = TurnStream(account: Accounts.account(id: "codex-dev"), invocation: Invocation(arguments: []))
        #expect(quiet.endNote(status: 130, stderr: "", stopped: true, byOwner: false, lingered: false)?.text == "Stopped")
        // Readers that look for the stop note find the longer one, and only notes.
        #expect(ChatMessage(role: .note, text: "Stopped after 3 tool calls.").isStopNote)
        #expect(!ChatMessage(role: .assistant, text: "Stopped after 3 tool calls.").isStopNote)
        #expect(!ChatMessage(role: .note, text: "Stopped by the owner? No.").isStopNote)
    }
}
