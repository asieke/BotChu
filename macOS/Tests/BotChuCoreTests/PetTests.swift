import Foundation
import Testing
@testable import BotChuCore

@Suite struct PetActivityTests {
    @Test func claudeToolsByName() {
        #expect(BotActivity.classify(toolName: "Read", input: "README.md") == .researching)
        #expect(BotActivity.classify(toolName: "Grep", input: "foo") == .researching)
        #expect(BotActivity.classify(toolName: "Glob", input: "**/*.swift") == .researching)
        #expect(BotActivity.classify(toolName: "WebSearch", input: "swift") == .browsing)
        #expect(BotActivity.classify(toolName: "WebFetch", input: "https://x") == .browsing)
        #expect(BotActivity.classify(toolName: "Edit", input: "a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "Write", input: "a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "MultiEdit", input: "a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "TodoWrite", input: "") == .thinking)
        #expect(BotActivity.classify(toolName: "Task", input: "explore") == .working)
        #expect(BotActivity.classify(toolName: "mcp__linear__get_issue", input: "") == .working)
    }

    @Test func otherCLIsToolNames() {
        // Codex (StreamParsers names its items), Antigravity, Muse and Pi.
        #expect(BotActivity.classify(toolName: "Edit files", input: "update a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "Web search", input: "weather") == .browsing)
        #expect(BotActivity.classify(toolName: "Shell", input: "swift test") == .testing)
        #expect(BotActivity.classify(toolName: "run_command", input: "ls -la") == .researching)
        #expect(BotActivity.classify(toolName: "invoke_subagent", input: "") == .working)
        #expect(BotActivity.classify(toolName: "view_file", input: "a") == .researching)
        #expect(BotActivity.classify(toolName: "replace_file_content", input: "a") == .coding)
        #expect(BotActivity.classify(toolName: "bash", input: "git commit -m x") == .coding)
        #expect(BotActivity.classify(toolName: "read", input: "a") == .researching)
        #expect(BotActivity.classify(toolName: "github.search_issues", input: "") == .researching)
    }

    @Test func shellCommands() {
        #expect(BotActivity.classify(command: "ls -la") == .researching)
        #expect(BotActivity.classify(command: "cat tests/fixture.json") == .researching)
        #expect(BotActivity.classify(command: "grep -rn foo . | head -20") == .researching)
        #expect(BotActivity.classify(command: "git status && git diff") == .researching)
        #expect(BotActivity.classify(command: "sed -n 1,40p a.swift") == .researching)
        #expect(BotActivity.classify(command: "sed -i '' s/a/b/ a.swift") == .coding)
        #expect(BotActivity.classify(command: "cat > notes.md <<'EOF'") == .coding)
        #expect(BotActivity.classify(command: "git add -A && git commit -m wip") == .coding)
        #expect(BotActivity.classify(command: "cd macOS && swift test") == .testing)
        #expect(BotActivity.classify(command: "scripts/check.sh") == .testing)
        #expect(BotActivity.classify(command: "npm run build") == .testing)
        #expect(BotActivity.classify(command: "pytest -q tests/") == .testing)
        #expect(BotActivity.classify(command: "ls && make") == .testing)
        #expect(BotActivity.classify(command: "curl -s https://example.com") == .browsing)
        #expect(BotActivity.classify(command: "python3 tool.py") == .working)
        #expect(BotActivity.classify(command: "echo latest version") == .researching)
        #expect(BotActivity.classify(command: "") == .working)
    }

    @Test func eventsMoveTheActivity() {
        #expect(BotActivity.next(after: .textDelta("hi")) == .thinking)
        #expect(BotActivity.next(after: .toolStarted(id: "1", name: "Read", input: "a")) == .researching)
        #expect(BotActivity.next(after: .toolFinished(id: "1", name: "Read", output: "", isError: false)) == .thinking)
        #expect(BotActivity.next(after: .session("s")) == nil)
        #expect(BotActivity.next(after: .finished) == nil)
        // #255: waiting on background tasks shows the most telling of them.
        #expect(BotActivity.next(after: .backgroundTasks([.working, .testing])) == .testing)
        #expect(BotActivity.next(after: .backgroundTasks([])) == nil)
    }

    @Test func clipsFallBackToACloseOneThenIdle() {
        #expect(BotActivity.coding.animations == ["coding", "idle"])
        #expect(BotActivity.browsing.animations == ["browsing", "researching", "idle"])
        #expect(BotActivity.testing.animations == ["testing", "coding", "idle"])
        #expect(BotActivity.idle.animations == ["idle"])
        #expect(BotActivity.allCases.allSatisfy { $0.animations.first == $0.rawValue && $0.animations.last == "idle" })
        #expect(BotActivity.browsing.animation(among: ["idle", "researching"]) == "researching")
        #expect(BotActivity.testing.animation(among: ["idle"]) == "idle")
        #expect(BotActivity.done.animation(among: []) == nil)
    }

    @Test func toolActivityShowsLongEnoughToSee() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var run = RunState(startedAt: start)
        #expect(run.move(to: .coding, at: start.addingTimeInterval(1)) == nil)
        #expect(run.activity == .coding)
        // The edit finished at once: thinking waits.
        let wait = run.move(to: .thinking, at: start.addingTimeInterval(1.5))
        #expect(wait == RunState.minimumShow - 0.5)
        #expect(run.activity == .coding)
        run.settle(at: start.addingTimeInterval(2))
        #expect(run.activity == .coding)
        run.settle(at: start.addingTimeInterval(3.5))
        #expect(run.activity == .thinking)
        // Another tool before the wait is over takes over at once.
        _ = run.move(to: .researching, at: start.addingTimeInterval(4))
        _ = run.move(to: .thinking, at: start.addingTimeInterval(4.2))
        #expect(run.move(to: .testing, at: start.addingTimeInterval(4.4)) == nil)
        #expect(run.activity == .testing)
        #expect(run.pending == nil)
        // A tool that ran long goes back to thinking at once.
        #expect(run.move(to: .thinking, at: start.addingTimeInterval(9)) == nil)
        #expect(run.activity == .thinking)
    }

    @Test func statusShowsTheActivity() {
        let bot = Bot(name: "B", workspace: "/tmp/b")
        #expect(BotStatus.make(bot: bot, messages: [], run: nil).activity == .idle)
        #expect(BotStatus.make(bot: bot, messages: [], run: RunState(activity: .coding)).activity == .coding)
        #expect(BotStatus.make(bot: bot, messages: [], run: nil, reaction: .done).activity == .done)
        let failed = [ChatMessage(role: .error, text: "boom")]
        #expect(BotStatus.make(bot: bot, messages: failed, run: nil).activity == .failed)
        #expect(BotStatus.make(bot: bot, messages: failed, run: RunState()).activity == .thinking)
    }
}

@Suite struct BotAppearanceTests {
    @Test func botsWithoutAppearanceStillDecode() throws {
        let json = #"{"id":"8C1F6A2E-5B7D-4E8A-9C3B-2A1D0F4E6B71","name":"Scout","emoji":"🔭","title":"","instructions":"","accountID":"claude-dev","model":"","workspace":"/tmp/s","createdAt":"2026-10-22T03:00:00Z"}"#
        let bot = try Store.decoder.decode(Bot.self, from: Data(json.utf8))
        #expect(bot.appearance == nil)
        var drawn = bot
        drawn.appearance = "A small brass robot"
        let again = try Store.decoder.decode(Bot.self, from: Store.encoder.encode(drawn))
        #expect(again.appearance == "A small brass robot")
    }
}
