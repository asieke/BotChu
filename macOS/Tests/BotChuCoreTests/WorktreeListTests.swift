import Foundation
import Testing
@testable import BotChuCore

/// #401: a checkout's worktrees, as `git worktree list --porcelain` lists them.
@Suite struct WorktreeListTests {
    @Test func aRealListMainFirstWithItsFlags() {
        let entries = WorktreeList.parse(porcelain: RunGitFactsSamples.porcelain)
        let head = "05a0ad850af3b6e34ec5e566139977f4274dec8c"
        #expect(entries == [
            WorktreeEntry(path: "/private/tmp/rgf/porc/repo", branch: "main", head: head, isMain: true),
            WorktreeEntry(path: "/private/tmp/rgf/porc/pr-102", head: head, isDetached: true),
            WorktreeEntry(path: "/private/tmp/rgf/porc/repo/.claude/worktrees/chore-gone", branch: "chore/gone", head: head, isPrunable: true),
            WorktreeEntry(path: "/private/tmp/rgf/porc/repo/.claude/worktrees/feat-86-school-catalog", branch: "feat/86-school-catalog", head: head),
            WorktreeEntry(path: "/private/tmp/rgf/porc/repo/.claude/worktrees/fix-90-login", branch: "fix/90-login", head: head, isLocked: true),
        ])
        #expect(entries.filter(\.isMain).count == 1)
    }

    @Test func listsWithoutTheLastBlankLineAndEmptyOnes() {
        let bare = "worktree /srv/repo.git\nbare\n\nworktree /srv/wt\nHEAD abc\nbranch refs/heads/x"
        #expect(WorktreeList.parse(porcelain: bare) == [
            WorktreeEntry(path: "/srv/repo.git", isMain: true),
            WorktreeEntry(path: "/srv/wt", branch: "x", head: "abc"),
        ])
        #expect(WorktreeList.parse(porcelain: "").isEmpty)
        #expect(WorktreeList.parse(porcelain: "\n").isEmpty)
        #expect(WorktreeList.parse(porcelain: "worktree /a\r\nHEAD abc\r\nbranch refs/heads/main\r\n") == [
            WorktreeEntry(path: "/a", branch: "main", head: "abc", isMain: true),
        ])
    }

    @Test func theScriptQuotesTheCheckoutAndLeavesHomeToTheShell() {
        #expect(WorktreeList.script(checkout: "/Users/me/My Repo") == "git -C '/Users/me/My Repo' worktree list --porcelain")
        #expect(WorktreeList.script(checkout: "~/WORKSPACE/BotChu") == #"git -C "$HOME"/'WORKSPACE/BotChu' worktree list --porcelain"#)
    }

    @Test func theScriptListsARealCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let setup = await Machine.thisMac.script("""
            git init -q -b main . && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init \
            && git worktree add -q .claude/worktrees/fix-86-x -b fix/86-x && git worktree add -q --detach ../check HEAD
            """, in: repo)
        try #require(setup.ok, "\(setup.errors)")
        let listed = await Machine.thisMac.script(WorktreeList.script(checkout: repo), in: "~")
        try #require(listed.ok, "\(listed.errors)")
        let entries = WorktreeList.parse(porcelain: listed.output)
        // The main checkout first, then the others by path.
        #expect(entries.map(\.branch) == ["main", nil, "fix/86-x"])
        #expect(entries.map(\.isMain) == [true, false, false])
        #expect(entries.map(\.isDetached) == [false, true, false])
        #expect(entries[1].path.hasSuffix("/check") && entries[2].path.hasSuffix("/repo/.claude/worktrees/fix-86-x"))
    }

    @Test func cleanOnlyWhenStatusPrintsNothing() {
        #expect(WorktreeList.isClean(statusPorcelain: ""))
        #expect(WorktreeList.isClean(statusPorcelain: "\n"))
        #expect(!WorktreeList.isClean(statusPorcelain: "?? x.txt\n"))
        #expect(!WorktreeList.isClean(statusPorcelain: " M Sources/a.swift\n"))
        #expect(!WorktreeList.isClean(statusPorcelain: "A  new.swift"))
    }
}
