import Foundation
@testable import BotChuCore

/// Real tool calls from sub-agent transcripts (2026-10), as BotChu saved them in `thread.jsonl`.
/// Only the home folder is renamed `/Users/me`, and long heredoc bodies (data, not commands) are
/// shortened where marked.
enum RunGitFactsSamples {
    // MARK: Claude Code (claude-personal), run folder /Users/me/Desktop/BOTS/ceo-bot

    static let claudeFolder = "/Users/me/Desktop/BOTS/ceo-bot"

    static let claude: [ChatMessage] = [
        ChatMessage(role: .user, text: "Fix asieke/kids-post#13: show $15/month per child."),
        ChatMessage(role: .tool, toolName: "Bash",
            toolInput: "cd ~/Desktop/WORKSPACE/kids-post && gh issue develop 13 --name feat/13-price-fifteen-dollars --base main && git fetch origin && git worktree add .claude/worktrees/feat-13-price-fifteen-dollars feat/13-price-fifteen-dollars && cd .claude/worktrees/feat-13-price-fifteen-dollars && git status -sb && bun install --frozen-lockfile 2>&1 | tail -2",
            toolOutput: "github.com/asieke/kids-post/tree/feat/13-price-fifteen-dollars\nFrom https://github.com/asieke/kids-post\n * [new branch]      feat/13-price-fifteen-dollars -> origin/feat/13-price-fifteen-dollars\nPreparing worktree (new branch 'feat/13-price-fifteen-dollars')\nbranch 'feat/13-price-fifteen-dollars' set up to track 'origin/feat/13-price-fifteen-dollars'.\nHEAD is now at 0a27fab Retire the workspace framework: plain bun checks, pointer-only AGENTS.md (#11)\n## feat/13-price-fifteen-dollars...origin/feat/13-price-fifteen-dollars\n\n244 packages installed [1267.00ms]\nShell cwd was reset to /Users/me/Desktop/BOTS/ceo-bot",
            toolState: .done,
            toolArguments: #"{"command":"cd ~/Desktop/WORKSPACE/kids-post && gh issue develop 13 --name feat/13-price-fifteen-dollars --base main && git fetch origin && git worktree add .claude/worktrees/feat-13-price-fifteen-dollars feat/13-price-fifteen-dollars && cd .claude/worktrees/feat-13-price-fifteen-dollars && git status -sb && bun install --frozen-lockfile 2>&1 | tail -2","description":"Create linked branch and worktree, install deps"}"#),
        // The PR body in the heredoc is shortened.
        ChatMessage(role: .tool, toolName: "Bash",
            toolInput: "cd ~/Desktop/WORKSPACE/kids-post/.claude/worktrees/feat-13-price-fifteen-dollars && git add PROJECT.md && git commit -q -m \"docs: record the 2026-10-27 product decisions, including \\$15/month per child\n\nRefs #13\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\" && git push -q origin HEAD 2>&1 | tail -2\ncat > /tmp/kp13-body.md <<'EOF'\n## What\n- Replaces PROJECT.md's **Open decisions** with CEO Bot's 2026-10-27 decisions.\n\n## Testing\n- Vercel preview: PREVIEW_URL\nEOF\ngh pr create --base main --head feat/13-price-fifteen-dollars --title \"docs: record the 2026-10-27 product decisions, including \\$15/month per child\" --body-file /tmp/kp13-body.md",
            toolOutput: "https://github.com/asieke/kids-post/pull/14\nShell cwd was reset to /Users/me/Desktop/BOTS/ceo-bot",
            toolState: .done,
            toolArguments: #"{"command":"cd ~/Desktop/WORKSPACE/kids-post/.claude/worktrees/feat-13-price-fifteen-dollars && git add PROJECT.md && git commit -q -m \"docs: record the 2026-10-27 product decisions, including \\$15/month per child\n\nRefs #13\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\" && git push -q origin HEAD 2>&1 | tail -2\ncat > /tmp/kp13-body.md <<'EOF'\n## What\n- Replaces PROJECT.md's **Open decisions** with …","description":"Commit, push, open PR"}"#),
        ChatMessage(role: .tool, toolName: "Bash",
            toolInput: "cd ~/Desktop/WORKSPACE/kids-post && code=$(curl -s -o /dev/null -w '%{http_code}' https://kids-post-git-feat-13-price-fifteen-dollars-asiekes-projects.vercel.app); echo \"preview HTTP $code\"; sed -i '' \"s|PREVIEW_URL|https://kids-post-git-feat-13-price-fifteen-dollars-asiekes-projects.vercel.app (built green)|\" /tmp/kp13-body.md && gh pr edit 14 --body-file /tmp/kp13-body.md >/dev/null && gh pr merge 14 --squash && gh pr view 14 --json state,mergeCommit -q '.state+\" \"+.mergeCommit.oid'; gh issue view 13 --json state -q .state",
            toolOutput: "preview HTTP 302\nMERGED f3926e95bd6aa4ba288e2eea81f3c9b1d05e3872\nCLOSED\nShell cwd was reset to /Users/me/Desktop/BOTS/ceo-bot",
            toolState: .done),
        ChatMessage(role: .assistant, text: "Merged https://github.com/asieke/kids-post/pull/14."),
    ]

    // MARK: Codex (codex-work), run folder /Users/me/Desktop/WORKSPACE/protagonist-v2/.claude/worktrees/feat-what-are-open-issues

    static let codexFolder = "/Users/me/Desktop/WORKSPACE/protagonist-v2/.claude/worktrees/feat-what-are-open-issues"

    static let codex: [ChatMessage] = [
        ChatMessage(role: .tool, toolName: "Shell",
            toolInput: "git fetch origin && gh issue develop 81 --repo Humanist-Venture-Studio/protagonist-v2 --name feat/81-fafsa-copilot --base main && git fetch origin && git worktree add /Users/me/Desktop/WORKSPACE/protagonist-v2/.claude/worktrees/feat-81-fafsa-copilot feat/81-fafsa-copilot",
            toolOutput: "github.com/Humanist-Venture-Studio/protagonist-v2/tree/feat/81-fafsa-copilot\nFrom https://github.com/Humanist-Venture-Studio/protagonist-v2\n * [new branch]      feat/81-fafsa-copilot -> origin/feat/81-fafsa-copilot\nPreparing worktree (new branch 'feat/81-fafsa-copilot')\nbranch 'feat/81-fafsa-copilot' set up to track 'origin/feat/81-fafsa-copilot'.\nHEAD is now at a3b6ecc Merge pull request #88 from Humanist-Venture-Studio/feat/86-school-catalog\n",
            toolState: .done, toolExitCode: 0),
        // The heredoc is shortened; it still names `gh pr merge` as text, which never ran.
        ChatMessage(role: .tool, toolName: "Shell",
            toolInput: "\"cat > /tmp/pv2-skills-t1xwrm15/81-eval.md <<'\"'MD'\n# FAFSA #81 \u{2014} exact evaluation additions for parent integration\n\nImplementation branch: \"'`feat/81-fafsa-copilot`.\n\n## Parent release ownership\n\nParent integrates shared Ideas/catalog/evaluation files, runs full Linux suite sequentially through the shared gate in a disposable checkout, performs any authorized model evaluation, merges with \"'`gh pr merge --merge`, and owns cleanup/deployment.\nMD'",
            toolOutput: "", toolState: .done, toolExitCode: 0),
        ChatMessage(role: .tool, toolName: "Shell",
            toolInput: "git status -sb && git rev-parse HEAD && tail -8 /tmp/pv2-fafsa-evidence.noindex/tests.log && git ls-files skills/fafsa && git push -u origin feat/81-fafsa-copilot && gh pr create --repo Humanist-Venture-Studio/protagonist-v2 --base main --head feat/81-fafsa-copilot --title 'feat: add year-pinned FAFSA copilot and EN/ES family guides' --body-file /tmp/pv2-fafsa-evidence.noindex/pr-body.md",
            toolOutput: "## feat/81-fafsa-copilot...origin/feat/81-fafsa-copilot [ahead 1]\na1207b4af4b071bddbabe8ba6a01b176ae6583c0\n\u{2139} tests 20\n\u{2139} suites 0\n\u{2139} pass 20\n\u{2139} fail 0\n\u{2139} cancelled 0\n\u{2139} skipped 0\n\u{2139} todo 0\n\u{2139} duration_ms 916.905875\nskills/fafsa/SKILL.md\nskills/fafsa/bin/pell-estimate.mjs\nskills/fafsa/input-format.md\nskills/fafsa/sources.md\nskills/fafsa/tables/2026-27.json\nskills/fafsa/tables/2027-28.json\nskills/fafsa/templates/family.en.html\nskills/fafsa/templates/family.es.html\nTo https://github.com/Humanist-Venture-Studio/protagonist-v2.git\n   a3b6ecc..a1207b4  feat/81-fafsa-copilot -> feat/81-fafsa-copilot\nbranch 'feat/81-fafsa-copilot' set up to track 'origin/feat/81-fafsa-copilot'.\nhttps://github.com/Humanist-Venture-Studio/protagonist-v2/pull/92\n",
            toolState: .done, toolExitCode: 0),
    ]

    /// Another Codex run: a relative worktree, then a merge by number.
    static let codexMerge: [ChatMessage] = [
        ChatMessage(role: .tool, toolName: "Shell",
            toolInput: "gh issue develop 102 --repo Humanist-Venture-Studio/protagonist-v2 --name feat/102-college-arc-admin --base main && git fetch origin && git worktree add .claude/worktrees/feat-102-college-arc-admin feat/102-college-arc-admin",
            toolOutput: "github.com/Humanist-Venture-Studio/protagonist-v2/tree/feat/102-college-arc-admin\nFrom https://github.com/Humanist-Venture-Studio/protagonist-v2\n * [new branch]      feat/102-college-arc-admin -> origin/feat/102-college-arc-admin\nPreparing worktree (new branch 'feat/102-college-arc-admin')\nbranch 'feat/102-college-arc-admin' set up to track 'origin/feat/102-college-arc-admin'.\nHEAD is now at 9ee3966 Merge pull request #101 from Humanist-Venture-Studio/fix/100-college-arc-inline-plan\n",
            toolState: .done, toolExitCode: 0),
        ChatMessage(role: .tool, toolName: "Shell",
            toolInput: "gh pr create --repo Humanist-Venture-Studio/protagonist-v2 --base main --head feat/102-college-arc-admin --title 'Add Humanist-only College Arc activity admin' --body-file /tmp/college-arc-102-pr.md",
            toolOutput: "https://github.com/Humanist-Venture-Studio/protagonist-v2/pull/104\n", toolState: .done, toolExitCode: 0),
        ChatMessage(role: .tool, toolName: "Shell",
            toolInput: "gh pr merge 104 --repo Humanist-Venture-Studio/protagonist-v2 --merge --match-head-commit 82fc7d7e4cffd186ee0690569d5536d7347e86cc && gh pr view 104 --repo Humanist-Venture-Studio/protagonist-v2 --json state,mergeCommit,url",
            toolOutput: "{\"mergeCommit\":{\"oid\":\"3a358c65f671f255c69cf6b7e15d5e22d8f2b3fb\"},\"state\":\"MERGED\",\"url\":\"https://github.com/Humanist-Venture-Studio/protagonist-v2/pull/104\"}\n",
            toolState: .done, toolExitCode: 0),
    ]

    // MARK: git worktree list --porcelain (git 2.54.0)

    /// Three branch worktrees (one locked, one whose folder was deleted) and a detached one.
    static let porcelain = """
        worktree /private/tmp/rgf/porc/repo
        HEAD 05a0ad850af3b6e34ec5e566139977f4274dec8c
        branch refs/heads/main

        worktree /private/tmp/rgf/porc/pr-102
        HEAD 05a0ad850af3b6e34ec5e566139977f4274dec8c
        detached

        worktree /private/tmp/rgf/porc/repo/.claude/worktrees/chore-gone
        HEAD 05a0ad850af3b6e34ec5e566139977f4274dec8c
        branch refs/heads/chore/gone
        prunable gitdir file points to non-existent location

        worktree /private/tmp/rgf/porc/repo/.claude/worktrees/feat-86-school-catalog
        HEAD 05a0ad850af3b6e34ec5e566139977f4274dec8c
        branch refs/heads/feat/86-school-catalog

        worktree /private/tmp/rgf/porc/repo/.claude/worktrees/fix-90-login
        HEAD 05a0ad850af3b6e34ec5e566139977f4274dec8c
        branch refs/heads/fix/90-login
        locked on a USB disk


        """
}
