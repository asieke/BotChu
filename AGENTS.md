# Agent workflow

Read @PROJECT.md (purpose, type, status, merge) and @README.md (scope, run, test, deploy) before starting any work. This repository follows the standard at https://github.com/asieke/workspace/blob/main/STANDARD.md. When the prompt that started this session says where you are (a folder, a branch, a worktree), check it before changing anything (`git rev-parse --show-toplevel`, `git status -sb`); where the two disagree, the checkout is right, so say so and work from what you found.

**For `local` projects, and any project whose `deploy` lists a `local:` target, sync before anything:** at session start, run `scripts/sync.sh --inspect` (Claude Code runs it automatically through `.claude/settings.json`). It fetches and reports the checkout's state without deploying anything. Before running, restarting, or deploying the app, using its live data, or running a scheduled job, run the full `scripts/sync.sh` and follow its output. If it reports `REFUSED`, stop those operations and report to the owner; do not stash, reset, or delete anything. A refusal does not block reviewing a pull request (see **Reviewing a pull request**). Never edit the live checkout: work in a worktree (step 2), and run scheduled jobs as `scripts/sync.sh <command>`.

1. **Check or create an Issue (for larger tasks):** If you are picking up a task from the backlog or starting a larger multi-step change, use a GitHub Issue: read it and its whole discussion (`gh issue view <number> --comments`), and start its branch with the Issue's number (step 2). That links the branch to the Issue on GitHub, whose **Development** section then shows that someone is on it, so no claiming comment is needed. For a small, self-contained change requested directly in chat, you can skip creating an Issue.
2. **Create a branch from the latest `origin/main`, in its own worktree:**
   `dir=$(scripts/worktree.sh <type>/<slug>) && cd "$dir"`
   - `type` must be `feat`, `fix`, `chore`, or `docs`.
   - `slug` is two to five plain words in kebab-case, starting with the Issue number when one exists (for example, `feat/12-add-login` or `fix/login-timeout`).
   - This creates `.claude/worktrees/<type>-<slug>` with `.env` linked from the main checkout, or reopens it to resume the task. Work only there, and leave the main checkout on `main`. A new branch that starts with an Issue number is created on GitHub, linked to that Issue (`gh issue develop`); without `gh`, it is made locally, and the pull request's `Closes #<number>` links it instead.
   - In a checkout cloned just for this session (such as a cloud session), skip the worktree: for an Issue, `gh issue develop <number> --name <type>/<slug> --base main --checkout`; otherwise, or without `gh`, `git fetch origin && git switch -c <type>/<slug> origin/main`. If the branch already exists (a launcher such as GitChu may have created it), `git fetch origin && git switch <type>/<slug>`.
   - If your session or tool started on an auto-generated branch name such as `claude/...` or `worktree-...`, rename it first (`git branch -m <type>/<slug>`), and in a worktree run `scripts/worktree.sh --env`. You have standing permission to push the renamed branch.
   - Use one branch per task and one agent per branch. Local checkouts are disposable—always push your work to GitHub.
3. **Make the smallest complete change** that solves the task, and update any documentation affected by your change.
4. **Run `scripts/check.sh`** and fix any failures. Never skip, disable, or weaken a check.
5. **Push with `git push -u origin <branch>` and open a pull request to `main`** using the PR template. Fill in the **What**, **Decisions**, and **Agent session** sections. Then run `scripts/check.sh --report`, which posts the `check` status that merging requires (there is no CI). If you cannot run the checks here (for example, no Xcode or no `gh`), say so in the PR; the owner runs `scripts/verify-pr.sh <number>` on a machine that can.
   - If `merge: owner` in `PROJECT.md`, leave the PR open—only the owner merges.
   - If `merge: agent` in `PROJECT.md`, you may merge the PR yourself (`gh pr merge --squash`) once the template is filled out and the `check` status is green. GitHub deletes the merged branch; do not add `--delete-branch`, which fails inside a worktree.
   - Before pushing follow-up edits in the same session, check `gh pr view --json state`; if the previous PR was already merged, branch fresh from `origin/main` and open a new PR.
6. **If you stop before finishing:** Push your branch, leave its worktree in place, and leave a comment on the Issue summarizing what is done, what is next, any blockers, and the branch name. (If you already opened or merged a passing PR, no extra Issue comment is needed.)
7. **After the PR merges:** `scripts/worktree.sh --tidy`, run from the main checkout, removes worktrees whose pull request merged, along with their branches, and lists the rest. In `local` projects, every full `scripts/sync.sh` (before live-app operations and in every scheduled job) runs it. It never removes a worktree with uncommitted files or unmerged commits.

## Reviewing a pull request

A review is not a task, so skip the workflow steps above: it needs no full sync, Issue, branch, commit, push, or new pull request.
- **Read** the pull request, its discussion, its reviews, its checks (`gh pr view <number> --comments`, `gh pr checks <number>`), and its diff, then as much of the code around it as you need to judge it, and run the relevant tests. Record the head commit you reviewed (`gh pr view <number> --json headRefOid`).
- **Look for** bugs; regressions in what used to work; problems of design (whether it fits how the code is organized, and is the smallest complete change); security issues; edge cases it does not handle; missing or weak tests; and anything against `PROJECT.md`, `README.md`, this file, or the standard, including documents the change should have updated.
- **Report** each finding with its severity (high, medium, or low), `file:line`, what is wrong, and how to fix it, most severe first, then a verdict: ready to merge, or what must change first.
- **Test in isolation, so the main checkout stays on `main`:** `scripts/verify-pr.sh --no-report <number>` runs `scripts/check.sh` in a temporary worktree and posts nothing. For targeted tests, use a detached review worktree (`git fetch origin pull/<number>/head && git worktree add --detach "$(mktemp -d)/pr-<number>" FETCH_HEAD`) and remove it with `git worktree remove` when done. Never check the PR out in the main checkout. Run `scripts/verify-pr.sh <number>`, which posts the `check` status, only when asked to verify the PR.
- **Compare against the merge base** (what `gh pr diff <number>` shows, or `git diff origin/main...<head>`), not the current `main`. Report integration with the current `main` separately: textual conflicts (`gh pr view <number> --json mergeable`) and changes merged since the merge base that break the PR. Do not ask for a rebase just because `main` moved.
- **Publishing:** "Review this PR" returns the review in the conversation and posts nothing to GitHub. "Review and comment on this PR" also posts it to that PR without asking again, as one review: `gh api repos/<owner>/<repo>/pulls/<number>/reviews --method POST --input <file> --jq .html_url`, where the file, outside the checkout, holds JSON with `commit_id` (the head you reviewed), `"event": "COMMENT"` (GitHub refuses an approval or a change request on your own pull request, so the verdict goes in the body), `body` (the verdict, the reviewed commit, and one line per finding with its severity and `file:line`), and `comments` (each finding on a line the change adds or modifies, with `path`, `line`, `"side": "RIGHT"`, and `body`; an empty list when there are none).
  - Just before posting, check the head again; if it has moved, re-check each finding against the new head and post against that commit instead.
  - If GitHub refuses an inline comment, post again with every finding in the body only. A review with no findings is posted too.
  - Give the review's URL. If posting fails, say so with the error and give the review in the conversation; never present it as posted.
  - Neither request lets you change source files, commit, push, merge, deploy, or post a status. A review told to "post nothing" posts no comments and no status, so it tests only with `scripts/verify-pr.sh --no-report`.

## Writing an issue

When asked to write up an Issue, file one GitHub Issue and do nothing else: change no files, branches, or commits, and open no pull request.
- Read as much of the code and documents as you need to write it well. Check the open Issues first (`gh issue list`); if one already covers it, name it instead of filing a duplicate.
- Follow `.github/ISSUE_TEMPLATE/task.md`: a short, specific title, then **Outcome** (what is true when it is done, in the owner's terms rather than as an implementation), **Acceptance criteria**, and **Dependencies**.
- File it with `gh issue create --title <title> --body-file <file>`, and give its URL.

## Rules

- Never commit secrets to the repository. Put environment variable names in `.env.example`.
- Never edit `.env`; in a worktree it is a link to the main checkout's file. If a change needs a new variable, add its name to `.env.example` and say so in the PR, so the owner can set the value before merging.
- Never commit directly to `main`, never force-push, and never rewrite another agent's branch.
- Follow the deployment and testing instructions in `README.md` under `Deploy` and `Test`.
- Branch names must use only lowercase letters, numbers, and hyphens (up to 50 characters), with no person names, dates, machine names, or random words.

## Ways of working

This project follows the standard defined in https://github.com/asieke/workspace. To create, convert, audit, list, or refresh projects, to review a whole repository (as a product manager, a security reviewer, or a code reviewer), or to research a topic for it, clone a fresh copy of `asieke/workspace` into a temporary directory and follow `skills/<name>/SKILL.md` (`create-project`, `convert-project`, `audit`, `portfolio`, `refresh`, `review-repo`, or `research`). Always use a fresh clone of `main` and delete the temporary folder when done.

Everything in this file up to here is `templates/common/AGENTS.md` from that standard, unchanged, and its `scripts/upgrade.sh` replaces it whenever the standard changes, so do not edit it in this project. Put this project's own instructions after it, under `## Project rules`.

- The app is the Swift package in `macOS/`. Keep `Sources/BotChuCore/` Foundation-only and unit-tested; the SwiftUI app in `Sources/BotChu/` stays thin over it.
- When a CLI's headless output format changes, capture a real sample into the parser tests (`macOS/Tests/BotChuCoreTests/`) before changing its parser.
- Never copy, read aloud or log the CLIs' auth files or the OpenRouter key; each profile owns its own login.
