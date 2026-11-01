import Foundation
import Testing
@testable import BotChuCore

/// #405: when BotChu removes a worktree by itself, and what the Worktrees list reads to decide it.
@Suite struct WorktreeCleanupPolicyTests {
    static let head = "8243145b0d46a1f2a6ae63805871b052a91c8982"
    static let entry = WorktreeEntry(path: "/repo/.claude/worktrees/feat-86-school", branch: "feat/86-school", head: head)

    /// Clean × merged × unowned: only all three remove it.
    @Test(arguments: [false, true], [false, true])
    func onlyCleanMergedAndUnownedIsRemoved(clean: Bool, merged: Bool) {
        let row = WorktreeRow(entry: Self.entry, isDirty: !clean)
        let pullRequest = BranchPullRequest(number: 413, state: merged ? .merged : .open, head: Self.head)
        for owned in [false, true] {
            #expect(WorktreeCleanupPolicy.removes(row, pullRequest: pullRequest, isOwned: owned) == (clean && merged && !owned),
                    "clean \(clean), merged \(merged), owned \(owned)")
        }
    }

    @Test func neverTheMainCheckoutNorALockedDetachedOrUnreadOne() {
        let merged = BranchPullRequest(number: 1, state: .merged, head: Self.head)
        var main = Self.entry
        main.isMain = true
        #expect(!WorktreeCleanupPolicy.removes(WorktreeRow(entry: main, isDirty: false), pullRequest: merged, isOwned: false))
        #expect(!WorktreeCleanupPolicy.canRemove(main))
        #expect(WorktreeCleanupPolicy.canRemove(Self.entry))
        var locked = Self.entry
        locked.isLocked = true
        #expect(!WorktreeCleanupPolicy.removes(WorktreeRow(entry: locked, isDirty: false), pullRequest: merged, isOwned: false))
        var detached = Self.entry
        detached.branch = nil
        detached.isDetached = true
        #expect(!WorktreeCleanupPolicy.removes(WorktreeRow(entry: detached, isDirty: false), pullRequest: merged, isOwned: false))
        var gone = Self.entry
        gone.isPrunable = true
        #expect(!WorktreeCleanupPolicy.removes(WorktreeRow(entry: gone, isDirty: nil), pullRequest: merged, isOwned: false))
        // Its status couldn't be read: not known to be clean.
        #expect(!WorktreeCleanupPolicy.removes(WorktreeRow(entry: Self.entry, isDirty: nil), pullRequest: merged, isOwned: false))
        // No pull request, or a closed one.
        #expect(!WorktreeCleanupPolicy.removes(WorktreeRow(entry: Self.entry, isDirty: false), pullRequest: nil, isOwned: false))
        #expect(!WorktreeCleanupPolicy.removes(WorktreeRow(entry: Self.entry, isDirty: false),
                                               pullRequest: BranchPullRequest(number: 1, state: .closed, head: Self.head), isOwned: false))
    }

    @Test func onlyWhenItMergedAtTheWorktreesCommit() {
        let row = WorktreeRow(entry: Self.entry, isDirty: false)
        // A commit made after the merge would be lost with the branch.
        #expect(!WorktreeCleanupPolicy.removes(row, pullRequest: BranchPullRequest(number: 1, state: .merged, head: "0000"), isOwned: false))
        #expect(!WorktreeCleanupPolicy.removes(row, pullRequest: BranchPullRequest(number: 1, state: .merged, head: nil), isOwned: false))
        #expect(WorktreeCleanupPolicy.removes(row, pullRequest: BranchPullRequest(number: 1, state: .merged, head: Self.head), isOwned: false))
    }

    @Test func theSameFolderHoweverItIsWritten() {
        #expect(WorktreeCleanupPolicy.samePath("/private/tmp/r/wt", "/tmp/r/wt/"))
        #expect(WorktreeCleanupPolicy.samePath("/private/var/folders/x", "/var/folders/x"))
        #expect(WorktreeCleanupPolicy.samePath("~/Desktop/WORKSPACE/r", "/Users/me/Desktop/WORKSPACE/r", home: "/Users/me"))
        #expect(WorktreeCleanupPolicy.samePath("/a/b/../c", "/a/c"))
        #expect(!WorktreeCleanupPolicy.samePath("/a/wt", "/a/wt-2"))
    }

    @Test func theOwnerIsTheNewestRunningRunInIt() {
        let bot = Bot(name: "10x Engineer Bot", emoji: "🛠", workspace: "/tmp/bot")
        func run(_ worktree: String?, _ phase: SubagentPhase, started: TimeInterval) -> SubagentRun {
            var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Fix", brief: "", workingDirectory: "/repo", phase: phase)
            run.worktree = worktree
            run.startedAt = Date(timeIntervalSince1970: started)
            return run
        }
        let path = "/private/tmp/repo/.claude/worktrees/feat-x"
        let older = run("/tmp/repo/.claude/worktrees/feat-x", .running, started: 1)
        let newer = run(path, .running, started: 2)
        let done = run(path, .completed, started: 3)
        let elsewhere = run("/tmp/repo/.claude/worktrees/feat-y", .running, started: 4)
        #expect(WorktreeCleanupPolicy.owner(of: path, among: [older, newer, done, elsewhere])?.id == newer.id)
        #expect(WorktreeCleanupPolicy.owner(of: path, among: [done, elsewhere]) == nil)
    }

    /// #431: a run's row says where it works, paired with its worktree's row; the Worktrees list
    /// keeps only the worktrees no running run works in.
    @Test func eachRunIsPairedWithItsWorktreeAndOnlyUnownedOnesAreListed() {
        let bot = Bot(name: "10x Engineer Bot", emoji: "🛠", workspace: "/tmp/bot")
        func run(_ worktree: String?, _ phase: SubagentPhase, branch: String? = nil) -> SubagentRun {
            var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Fix", brief: "", workingDirectory: "/repo", phase: phase)
            run.worktree = worktree
            run.branch = branch
            return run
        }
        let main = WorktreeRow(entry: WorktreeEntry(path: "/repo", branch: "main", isMain: true), isDirty: false)
        let owned = WorktreeRow(entry: WorktreeEntry(path: "/private/tmp/repo/.claude/worktrees/feat-430-card", branch: "feat/430-card"), isDirty: true)
        let leftover = WorktreeRow(entry: WorktreeEntry(path: "/tmp/repo/.claude/worktrees/fix-9-old", branch: "fix/9-old"), isDirty: false)
        let gone = WorktreeRow(entry: WorktreeEntry(path: "/tmp/repo/.claude/worktrees/chore-gone", isPrunable: true))
        let rows = [main, owned, leftover, gone]
        let running = run("/tmp/repo/.claude/worktrees/feat-430-card/", .running)
        let finished = run(leftover.entry.path, .completed, branch: "fix/9-old")

        // The row gives the branch the run didn't name and its changes; the branch's pull request wins.
        let open = BranchPullRequest(number: 432, state: .open)
        #expect(SubagentWorkplace.of(running, rows: rows, pullRequests: ["feat/430-card": open])
            == SubagentWorkplace(name: "feat/430-card", isDirty: true, pullRequest: 432, pullRequestState: .open))
        var named = finished
        named.pullRequest = 12
        #expect(SubagentWorkplace.of(named, rows: rows) == SubagentWorkplace(name: "fix/9-old", pullRequest: 12))
        // Unread rows: the run's own word, then its worktree's folder; nothing without either.
        #expect(SubagentWorkplace.of(running) == SubagentWorkplace(name: "feat-430-card"))
        #expect(SubagentWorkplace.of(run(nil, .running, branch: "docs/x")) == SubagentWorkplace(name: "docs/x"))
        #expect(SubagentWorkplace.of(run(nil, .running)) == nil)

        // The running run's worktree and the main checkout aren't listed; a finished run's leftover is.
        #expect(WorktreeCleanupPolicy.unowned(rows, among: [running, finished]).map(\.id) == [leftover.id, gone.id])
        #expect(WorktreeCleanupPolicy.unowned(rows, among: []).map(\.id) == [owned.id, leftover.id, gone.id])
        #expect(WorktreeCleanupPolicy.unowned([main], among: []).isEmpty)
    }

    // MARK: Reading them

    @Test func theStatusScriptsOutputGivesEachWorktreeWithItsChanges() {
        let output = RunGitFactsSamples.porcelain + "\n--botchu-status\n"
            + "clean /private/tmp/rgf/porc/repo\n"
            + "dirty /private/tmp/rgf/porc/repo/.claude/worktrees/feat-86-school-catalog\n"
            + "clean /private/tmp/rgf/porc/repo/.claude/worktrees/fix-90-login\n"
        let rows = WorktreeStatus.parse(output)
        #expect(rows.map(\.entry) == WorktreeList.parse(porcelain: RunGitFactsSamples.porcelain))
        #expect(rows.map(\.isDirty) == [false, nil, nil, true, false])
        #expect(WorktreeStatus.parse("").isEmpty)
        // Without the status part, every worktree is listed with its changes unknown.
        #expect(WorktreeStatus.parse(RunGitFactsSamples.porcelain).allSatisfy { $0.isDirty == nil })
    }

    @Test func theStatusScriptRunsOnARealCheckout() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-status-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let setup = """
            set -e
            mkdir -p "$1/repo" && cd "$1/repo"
            git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
            git worktree add -q -b feat/a .claude/worktrees/feat-a
            git worktree add -q -b feat/b .claude/worktrees/feat-b
            touch .claude/worktrees/feat-b/new.txt
            """
        let made = await Machine.thisMac.script(setup, arguments: [folder], in: "/")
        try #require(made.ok, "\(made.report("setup"))")
        let checkout = (folder as NSString).appendingPathComponent("repo")
        let run = await Machine.thisMac.script(WorktreeStatus.script(checkout: checkout), in: checkout)
        try #require(run.ok, "\(run.report("status"))")
        let rows = WorktreeStatus.parse(run.output)
        #expect(rows.map(\.entry.branch) == ["main", "feat/a", "feat/b"])
        #expect(rows.first?.entry.isMain == true)
        // The main checkout has the untracked worktrees folder git excludes for it only when told: dirty.
        #expect(rows.map(\.isDirty).dropFirst() == [false, true])
    }

    /// What `gh pr list --head <branch> --state all --limit 1 --json number,state,headRefOid` printed
    /// (gh 2.x, asieke/BotChu, 2026-10-31), and for a branch without one.
    static let pullRequests = """
        --botchu-branch feat/402-project-areas-column
        [{"headRefOid":"8243145b0d46a1f2a6ae63805871b052a91c8982","number":413,"state":"MERGED"}]
        --botchu-branch feat/no-such-branch
        []
        --botchu-branch fix/87-financial-aid
        [{"headRefOid":"bb43eff91273e249f22fbf15a6a4ebcaf3c6ff6f","number":102,"state":"OPEN"}]
        --botchu-branch chore/gone
        [{"headRefOid":"cc","number":7,"state":"CLOSED"}]
        """

    @Test func eachBranchsNewestPullRequest() {
        let found = WorktreeStatus.parsePullRequests(Self.pullRequests)
        #expect(found == [
            "feat/402-project-areas-column": BranchPullRequest(number: 413, state: .merged, head: "8243145b0d46a1f2a6ae63805871b052a91c8982"),
            "fix/87-financial-aid": BranchPullRequest(number: 102, state: .open, head: "bb43eff91273e249f22fbf15a6a4ebcaf3c6ff6f"),
            "chore/gone": BranchPullRequest(number: 7, state: .closed, head: "cc"),
        ])
        #expect(WorktreeStatus.parsePullRequests("").isEmpty)
        #expect(WorktreeStatus.parsePullRequests("--botchu-branch x\nnot json\n").isEmpty)
    }
}

/// #405: a sub-agent run's one-line card.
@Suite struct RunCardTests {
    static let bot = Bot(name: "10x Engineer Bot", emoji: "🛠", workspace: "/tmp/bot")

    static func run(_ phase: SubagentPhase, pullRequest: Int? = nil, state: PullRequestState? = nil, branch: String? = nil) -> SubagentRun {
        var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "#86 School catalog", brief: "", workingDirectory: "/repo",
                              phase: phase, createdAt: Date(timeIntervalSince1970: 0))
        run.pullRequest = pullRequest
        run.pullRequestState = state
        run.branch = branch
        return run
    }

    @Test func thePillFollowsTheRun() {
        #expect(RunPill.of(Self.run(.queued), needsInput: false) == .queued)
        #expect(RunPill.of(Self.run(.preparing), needsInput: false) == .queued)
        #expect(RunPill.of(Self.run(.running), needsInput: false) == .running)
        #expect(RunPill.of(Self.run(.running), needsInput: true) == .needsYou)
        #expect(RunPill.of(Self.run(.completed), needsInput: true) == .needsYou)
        #expect(RunPill.of(Self.run(.completed, pullRequest: 101, state: .open), needsInput: false) == .pullRequest(101))
        #expect(RunPill.of(Self.run(.completed, pullRequest: 101), needsInput: false) == .pullRequest(101))
        #expect(RunPill.of(Self.run(.completed, pullRequest: 101, state: .merged), needsInput: false) == .merged)
        #expect(RunPill.of(Self.run(.completed, pullRequest: 101, state: .closed), needsInput: false) == .done)
        #expect(RunPill.of(Self.run(.completed), needsInput: false) == .done)
        #expect(RunPill.of(Self.run(.failed), needsInput: true) == .failed)
        #expect(RunPill.of(Self.run(.stopped), needsInput: false) == .failed)
        #expect(RunPill.pullRequest(101).label == "PR #101")
        #expect(RunPill.needsYou.label == "Needs you")
    }

    @Test func theLinesOtherParts() {
        let merged = Self.run(.completed, pullRequest: 101, state: .merged, branch: "feat/79-onboarding")
        #expect(RunCard.detail(merged, pill: .merged) == "PR #101")
        let running = Self.run(.running, branch: "fix/86-school-catalog")
        #expect(RunCard.detail(running, pill: .running) == "fix/86-school-catalog")
        #expect(RunCard.detail(Self.run(.running), pill: .running) == "")
        #expect(RunCard.shortName("10x Engineer Bot") == "10x")
        #expect(RunCard.shortName("Scout") == "Scout")
        var timed = running
        timed.startedAt = Date(timeIntervalSince1970: 100)
        #expect(RunCard.elapsed(timed, now: Date(timeIntervalSince1970: 145)) == "45s")
        #expect(RunCard.elapsed(timed, now: Date(timeIntervalSince1970: 100 + 125)) == "2m")
        timed.phase = .completed
        timed.finishedAt = Date(timeIntervalSince1970: 100 + 3900)
        #expect(RunCard.elapsed(timed, now: Date(timeIntervalSince1970: 1_000_000)) == "1h 5m")
    }

    @Test func itNeedsYouWhenItOrARunItStartedAsksYou() {
        let parent = Self.run(.running)
        var child = SubagentRun(rootBotID: parent.rootBotID, parentSubagentID: parent.id, depth: 2, targetBot: Self.bot, title: "child",
                                brief: "", workingDirectory: "/repo")
        child.phase = .running
        var grandchild = SubagentRun(rootBotID: parent.rootBotID, parentSubagentID: child.id, depth: 3, targetBot: Self.bot, title: "g",
                                     brief: "", workingDirectory: "/repo")
        grandchild.phase = .running
        let other = Self.run(.running)
        let runs = [grandchild, other, child, parent]
        #expect(RunCard.tree(of: parent, among: runs) == [parent.id, child.id, grandchild.id])
        #expect(RunCard.needsInput(parent, among: runs, waiting: [grandchild.id]))
        #expect(!RunCard.needsInput(parent, among: runs, waiting: [other.id]))
        #expect(!RunCard.needsInput(parent, among: runs, waiting: []))
    }

    @Test func aDeliveryKeepsTheRunThatSentItAndOldOnesHaveNone() throws {
        let run = UUID()
        let delivery = Delivery(botID: UUID(), title: "Which?", question: Delivery.Question(text: "A or B?"), runID: run)
        let data = try JSONEncoder().encode(delivery)
        #expect(try JSONDecoder().decode(Delivery.self, from: data).runID == run)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["runID"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Delivery.self, from: old).runID == nil)
    }
}
