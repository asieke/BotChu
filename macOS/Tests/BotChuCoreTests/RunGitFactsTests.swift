import Foundation
import Testing
@testable import BotChuCore

/// #401: a sub-agent run knows the worktree, branch and pull request its own transcript shows.
@Suite struct RunGitFactsTests {
    private let checkout = "/w/repo"

    private func shell(_ command: String, output: String = "", state: ChatMessage.ToolState = .done, exit: Int? = nil,
                       name: String = "Bash") -> ChatMessage {
        ChatMessage(role: .tool, toolName: name, toolInput: command, toolOutput: output, toolState: state, toolExitCode: exit)
    }

    private func parse(_ messages: [ChatMessage], home: String? = nil) -> RunGitFacts {
        RunGitFacts.parse(messages, checkout: checkout, home: home)
    }

    // MARK: Real transcripts

    @Test func aClaudeRunThatMadeAWorktreeOpenedAndMergedItsPullRequest() {
        let facts = RunGitFacts.parse(RunGitFactsSamples.claude, checkout: RunGitFactsSamples.claudeFolder, home: "/Users/me")
        #expect(facts == RunGitFacts(worktree: "/Users/me/Desktop/WORKSPACE/kids-post/.claude/worktrees/feat-13-price-fifteen-dollars",
                                     branch: "feat/13-price-fifteen-dollars", pullRequest: 14, pullRequestState: .merged))
        // Without a home (a run on a host), `~` stays for that host to expand.
        let remote = RunGitFacts.parse(RunGitFactsSamples.claude, checkout: RunGitFactsSamples.claudeFolder)
        #expect(remote.worktree == "~/Desktop/WORKSPACE/kids-post/.claude/worktrees/feat-13-price-fifteen-dollars")
        // Before the merge it was open.
        let opened = RunGitFacts.parse(Array(RunGitFactsSamples.claude.prefix(3)), checkout: RunGitFactsSamples.claudeFolder)
        #expect(opened.pullRequest == 14 && opened.pullRequestState == .open)
    }

    @Test func aCodexRunsPullRequestStaysOpenWhenAHeredocOnlyNamesAMerge() {
        let facts = RunGitFacts.parse(RunGitFactsSamples.codex, checkout: RunGitFactsSamples.codexFolder, home: "/Users/me")
        #expect(facts == RunGitFacts(worktree: "/Users/me/Desktop/WORKSPACE/protagonist-v2/.claude/worktrees/feat-81-fafsa-copilot",
                                     branch: "feat/81-fafsa-copilot", pullRequest: 92, pullRequestState: .open))
    }

    @Test func aCodexRunMergedItsPullRequestByNumber() {
        let facts = RunGitFacts.parse(RunGitFactsSamples.codexMerge, checkout: "/Users/me/Desktop/WORKSPACE/protagonist-v2")
        #expect(facts == RunGitFacts(worktree: "/Users/me/Desktop/WORKSPACE/protagonist-v2/.claude/worktrees/feat-102-college-arc-admin",
                                     branch: "feat/102-college-arc-admin", pullRequest: 104, pullRequestState: .merged))
    }

    // MARK: Acceptance criteria

    @Test func theWorktreeAndBranchOfAWorktreeAdd() {
        let facts = parse([shell("git worktree add .claude/worktrees/fix-86-x -b fix/86-x origin/main")])
        #expect(facts == RunGitFacts(worktree: "/w/repo/.claude/worktrees/fix-86-x", branch: "fix/86-x"))
    }

    @Test func theBranchOfAnIssueDevelop() {
        let facts = parse([shell("gh issue develop 86 --name fix/86-x", output: "github.com/o/r/tree/fix/86-x\n")])
        #expect(facts == RunGitFacts(branch: "fix/86-x"))
        #expect(parse([shell("gh issue develop 86 --name=fix/86-x --base main")]).branch == "fix/86-x")
        // Then its worktree.
        let both = parse([shell("gh issue develop 86 --name fix/86-x"), shell("git fetch origin && git worktree add .claude/worktrees/fix-86-x fix/86-x")])
        #expect(both == RunGitFacts(worktree: "/w/repo/.claude/worktrees/fix-86-x", branch: "fix/86-x"))
    }

    @Test func thePullRequestOfAURL() {
        let facts = parse([ChatMessage(role: .assistant, text: "Opened https://github.com/asieke/BotChu/pull/102 for review.")])
        #expect(facts == RunGitFacts(pullRequest: 102))
        #expect(parse([shell("gh pr view 102 --json url", output: "{\"url\":\"https://github.com/o/r/pull/102\"}")]).pullRequest == 102)
    }

    @Test func mergedAfterAMerge() {
        let created = shell("gh pr create --fill", output: "https://github.com/o/r/pull/102\n")
        #expect(parse([created]).pullRequestState == .open)
        #expect(parse([created, shell("gh pr merge --squash")]) == RunGitFacts(pullRequest: 102, pullRequestState: .merged))
        #expect(parse([shell("gh pr merge https://github.com/o/r/pull/7 --squash")]) == RunGitFacts(pullRequest: 7, pullRequestState: .merged))
        #expect(parse([shell("gh pr merge -s", output: "✓ Squashed and merged pull request o/r#9 (Fix it)\n")])
            == RunGitFacts(pullRequest: 9, pullRequestState: .merged))
        // Auto-merge hasn't merged anything yet; a refused merge didn't either.
        #expect(parse([created, shell("gh pr merge 102 --auto --squash")]).pullRequestState == .open)
        #expect(parse([created, shell("gh pr merge 102 --squash", output: "Pull request is not mergeable", state: .failed)]).pullRequestState == .open)
        #expect(parse([created, shell("gh pr close 102 --comment 'Superseded'")]).pullRequestState == .closed)
    }

    @Test func nothingForATranscriptWithoutGit() {
        let messages = [
            ChatMessage(role: .user, text: "Summarize the parser."),
            shell("ls Sources && swift test --filter ParserTests", output: "Test run with 12 tests passed\n"),
            ChatMessage(role: .tool, toolName: "Read", toolInput: "Sources/Parser.swift", toolOutput: "struct Parser {}", toolState: .done),
            ChatMessage(role: .assistant, text: "The parser reads one line at a time."),
        ]
        #expect(parse(messages).isEmpty)
        #expect(parse([]).isEmpty)
    }

    // MARK: Edges

    @Test func aFailedCallCountsOnlyForWhatItsOutputConfirms() {
        // git refused: no worktree.
        let refused = shell("git worktree add .claude/worktrees/fix-86-x -b fix/86-x", output: "fatal: '.claude/worktrees/fix-86-x' already exists\n",
                            state: .failed, exit: 128, name: "Shell")
        #expect(parse([refused]).isEmpty)
        // The worktree was made; what failed was a later step.
        let later = shell("git worktree add .claude/worktrees/fix-86-x -b fix/86-x && npm ci",
                          output: "Preparing worktree (new branch 'fix/86-x')\nHEAD is now at 0a27fab Init\nnpm ERR! missing lockfile\n", state: .failed)
        #expect(parse([later]) == RunGitFacts(worktree: "/w/repo/.claude/worktrees/fix-86-x", branch: "fix/86-x"))
        // A pull request that already exists is still the one it works on.
        let exists = shell("gh pr create --fill", output: "a pull request for branch \"fix/86-x\" into branch \"main\" already exists:\nhttps://github.com/o/r/pull/88\n", state: .failed)
        #expect(parse([exists]) == RunGitFacts(pullRequest: 88, pullRequestState: .open))
    }

    @Test func aDetachedTestMergeKeepsTheRunsOwnWorktree() {
        let messages = [
            shell("git worktree add .claude/worktrees/feat-401-x -b feat/401-x origin/main"),
            shell(#"git worktree add --detach "$(mktemp -d)/pa-check" origin/main && cd "$(mktemp -d)/pa-check" && git merge --no-commit --no-ff feat/401-x"#),
            shell("git worktree add --detach /tmp/review-5 FETCH_HEAD"),
        ]
        #expect(parse(messages) == RunGitFacts(worktree: "/w/repo/.claude/worktrees/feat-401-x", branch: "feat/401-x"))
        // A review run's only worktree is detached.
        #expect(parse([shell("git worktree add --detach /tmp/review-5 FETCH_HEAD")]) == RunGitFacts(worktree: "/tmp/review-5"))
    }

    @Test func pathsAndBranchesAsGitReadsThem() {
        #expect(RunGitFacts.worktreeAdd(["-C", "/w/repo", "worktree", "add", "../x", "feat/existing"], in: "/elsewhere")
            == .init(path: "/w/x", branch: "feat/existing"))
        // Without a commit, git names the branch after the folder.
        #expect(RunGitFacts.worktreeAdd(["worktree", "add", "-q", "--track", "../hotfix"], in: "/w/repo") == .init(path: "/w/hotfix", branch: "hotfix"))
        #expect(RunGitFacts.worktreeAdd(["worktree", "add", "./wt", "abc1234"], in: "/w/repo") == .init(path: "/w/repo/wt", branch: nil))
        #expect(RunGitFacts.worktreeAdd(["worktree", "add", "--lock", "--reason", "usb", "-B", "fix/1-a", "wt"], in: "/w/repo")
            == .init(path: "/w/repo/wt", branch: "fix/1-a"))
        #expect(RunGitFacts.worktreeAdd(["worktree", "list"], in: "/w/repo") == nil)
        #expect(RunGitFacts.worktreeAdd(["status"], in: "/w/repo") == nil)
        // A `cd` earlier in the line, and a folder the tool call names.
        #expect(parse([shell("cd sub && git worktree add ../wt -b b")]).worktree == "/w/repo/wt")
        let codex = ChatMessage(role: .tool, toolName: "exec_command", toolInput: #"{"cmd":"git worktree add wt -b b","workdir":"/w/other"}"#, toolState: .done)
        #expect(parse([codex]).worktree == "/w/other/wt")
        // Environment and quoting.
        #expect(parse([shell("GIT_TRACE=0 git worktree add 'my wt' -b b")]).worktree == "/w/repo/my wt")
        #expect(RunGitFacts.normalized("/a/./b/../c/") == "/a/c")
        #expect(RunGitFacts.expand("~/x/../y", home: "/Users/me") == "/Users/me/y")
    }

    // MARK: The run's record

    @Test func aRecordTakesInItsTranscriptAndKeepsWhatItNoLongerShows() throws {
        let bot = Bot(name: "10x", workspace: "/tmp/10x")
        var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Fix #86", brief: "Fix it", workingDirectory: checkout)
        run.recordGitFacts(from: [ChatMessage(role: .user, text: "Fix it")])
        #expect(run.gitFacts.isEmpty)
        run.recordGitFacts(from: [shell("git worktree add .claude/worktrees/fix-86-x -b fix/86-x"),
                                  shell("gh pr create --fill", output: "https://github.com/o/r/pull/102\n")])
        #expect(run.gitFacts == RunGitFacts(worktree: "/w/repo/.claude/worktrees/fix-86-x", branch: "fix/86-x", pullRequest: 102, pullRequestState: .open))
        // A resumed run's messages may start after those calls: it keeps them, and takes the merge in.
        run.recordGitFacts(from: [shell("gh pr merge --squash")])
        #expect(run.gitFacts == RunGitFacts(worktree: "/w/repo/.claude/worktrees/fix-86-x", branch: "fix/86-x", pullRequest: 102, pullRequestState: .merged))
        // Mentioning another pull request doesn't take it off the one it opened.
        run.recordGitFacts(from: [ChatMessage(role: .assistant, text: "Like https://github.com/o/r/pull/90 did.")])
        #expect(run.pullRequest == 102 && run.pullRequestState == .merged)

        // Saved and read back; a record saved before #401 still reads, with none of them.
        let decoded = try SubagentIPC.decode(SubagentRun.self, from: SubagentIPC.encode(run))
        #expect(decoded.gitFacts == run.gitFacts)
        var object = try #require(try JSONSerialization.jsonObject(with: SubagentIPC.encode(run)) as? [String: Any])
        for key in ["worktree", "branch", "pullRequest", "pullRequestState"] { object[key] = nil }
        let old = try SubagentIPC.decode(SubagentRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.gitFacts.isEmpty && old.id == run.id)
    }

    @Test func theSharedPullRequestScanStillLimitsATaskToItsRepository() {
        let text = "https://github.com/a/b/pull/1 and https://github.com/asieke/BotChu/pull/2 then https://github.com/a/b/pull/3"
        #expect(TaskNaming.pullRequests(in: text, repo: nil) == [1, 2, 3])
        #expect(TaskNaming.pullRequests(in: text, repo: "asieke/BotChu") == [2])
        #expect(TaskNaming.pullRequests(in: "no links", repo: nil).isEmpty)
    }
}
