# BotChu

A minimal, open-source, native macOS app for persistent AI bots, in the spirit of Grok Bot and
[rakazo](https://github.com/elie222/rakazo). Bots are listed down the left; the selected bot's chat
fills the window. Each bot is driven by a coding-agent CLI that is already installed and signed in on
the Mac, and runs in its own workspace folder on this Mac.

## Scope
- Does:
  - **Bots:** create, edit and delete bots. A bot has a name, an emoji, a one-line title, private
    instructions, an account, an optional model and a workspace folder (default `~/BotChu/<name>`).
    A new bot introduces itself in one reply, so a misread role shows up at once.
  - **Accounts:** any bot can run on any account, switchable at any time from the chat header:
    Claude Personal, Claude Dev and Claude Work (`claude-personal`, `claude-dev`, `claude-work`),
    Codex Personal, Codex Dev and Codex Work (`codex-personal`, `codex-dev`, `codex-work`), Google
    (Antigravity, `agy`), Muse (`muse`), and OpenRouter (the Pi agent, `pi`, with an OpenRouter key
    and any OpenRouter model). Each account's command can be changed in Settings.
  - **Chat:** one continuous thread per bot. Replies stream in, rendered as Markdown; each tool the
    agent runs shows as a collapsible card with its input and output. A turn can be stopped. The
    thread and the CLI's session id are saved, so the next message (also after a relaunch) resumes
    the same CLI session.
  - **Memory:** each bot's workspace has a `MEMORY.md` it keeps itself, and `~/BotChu/MEMORY.md` is
    shared by every bot. Both, with the bot's identity and instructions, open every new CLI session
    and are written to the workspace's `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`, so the agent keeps
    them across its own context compaction. A new session (new bot, account switch, or **New
    Session**) also gets the recent conversation, so switching accounts keeps the thread's continuity.
  - **Status sidebar:** on the right of the chat (View ▸ Show Status, ⌥⌘I), the selected bot's
    state (idle, starting, working with the turn's running time, or the last turn's error), the
    account, agent and model it runs on, whether the next message continues its CLI session, its
    message and tool-call counts and last activity, what its `MEMORY.md` holds, and its workspace,
    with Edit and New Session.
  - **Settings:** the bots folder, each account's command, the OpenRouter API key (Keychain) and
    default OpenRouter model.
- Does not: run bots anywhere but this Mac (yet), schedule routines, ask for approval of tool calls
  (every CLI runs with its permission prompts bypassed, inside the bot's folder), or keep any secret
  outside the Keychain and the CLIs' own logins.

## Architecture
- `macOS/` is a Swift package (Swift 6 toolchain, macOS 14+, no third-party dependencies):
  - `Sources/BotChuCore/` — Foundation only, unit-tested: accounts and the command line each CLI
    runs with (`Accounts.swift`), the bot and message model (`Models.swift`), one stream parser per
    CLI turning its JSON lines into chat events (`StreamParsers.swift`), the identity, memory and
    recap that open a session (`BotContext.swift`), what the status sidebar shows about a bot and
    its `MEMORY.md` (`BotStatus.swift`), the JSON store (`Store.swift`), and the `Process` runner
    that launches a CLI through the login shell, `zsh -l` (`AgentRun.swift`).
  - `Sources/BotChu/` — the SwiftUI app, a standard `NavigationSplitView` window with an inspector,
    in standard system materials: `App/` (the app, window, model, settings, Keychain, dev hooks),
    `Sidebar/` (the bot list), `Chat/` (messages and the composer), `Inspector/` (the status
    sidebar), `Editor/` (the bot sheet), `Settings/`, and `Shared/` (layout constants, the avatar
    and the status badge).
  - `Sources/botchu-smoke/` — a command-line check, not shipped in the app, that runs two real
    turns on each account named the way the app does (see **Test**).
  - `Tests/BotChuCoreTests/` — parser tests against captured output of every CLI, command lines,
    context and store.
  - `build.sh [outdir]` builds the release binary and wraps it into `{outdir}/BotChu.app` (default
    `macOS/build/`), signed with the local "Apple Development" certificate when there is one, ad hoc
    otherwise. `install.sh` builds into `~/Applications`, restarts BotChu if it was running, and
    smoke-tests that it starts. `test.sh` runs the unit tests. `ui-review.sh` opens a build on
    throwaway data for checking its screens (see **Test**).
- Data: `~/Library/Application Support/BotChu/` holds `bots.json` and one `threads/<bot id>.json` per
  bot. Settings are in the `defaults` domain `local.BotChu`; the OpenRouter key is in the Keychain
  (service `local.BotChu`). Bot workspaces are under `~/BotChu/` by default. No database and no port.
- Each turn runs one headless CLI process in the bot's folder:
  - Claude: `claude -p … --output-format stream-json --verbose --include-partial-messages --dangerously-skip-permissions`, `--session-id` then `--resume`.
  - Codex: `codex exec --json --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check`, then `codex exec resume <thread id>`.
  - Antigravity: `agy -p … --output-format stream-json --dangerously-skip-permissions`, then `--conversation <id>`.
  - Muse: `muse exec --json --session-id <uuid>` (the same id resumes it).
  - Pi: `pi -p --mode json --provider openrouter --model <id> --session-id <uuid>`, with `OPENROUTER_API_KEY` from the Keychain.

## Run locally
- Prerequisites: macOS 14 or later with full Xcode 16 or later (`xcode-select -p` must point into
  Xcode.app), and whichever agent CLIs you want to use, installed and signed in (on Alex's Mac the
  profile wrappers live in `~/.local/bin`).
- Folder access: each CLI runs as BotChu's child, so when a CLI's own settings point into a
  protected folder (for example a Claude Code plugin under `~/Desktop`), macOS asks once whether
  BotChu may access that folder, and the turn waits until you answer. A bot that has printed nothing
  after 20 seconds says so in its chat. Because the app is signed with the same certificate every
  build, the answer survives reinstalls.
- Install: nothing to install; the package has no dependencies.
- Configure: nothing in `.env`. The OpenRouter key goes in BotChu ▸ Settings.
- Run from a checkout without touching the installed copy:
  ```sh
  pkill -x BotChu; macOS/build.sh && open macOS/build/BotChu.app
  ```

## Test
- `scripts/check.sh` runs the standard gate (`scripts/gate.sh`), shell syntax for every script, then
  `macOS/test.sh` (the unit tests) and `macOS/build.sh` into a temporary folder. `scripts/check.sh
  --report` posts the `check` status a PR needs before merging. `scripts/verify-pr.sh`, given a PR
  number, tests someone else's PR on this machine and posts its `check` status; with `--no-report`
  first, it posts nothing (for reviews). There is no CI: the checks need a Mac with full Xcode.
- Accounts end to end: `swift run --package-path macOS botchu-smoke [account id …]` runs, for each
  account (all of them when none is named), a new session that opens with the bot's context and
  runs a shell command, then a resumed session that must recall a code word from the first, and
  prints both threads. It spends the accounts' own allowance, so it is not part of `check`;
  OpenRouter needs `OPENROUTER_API_KEY` in its environment.
- Screens: `macOS/ui-review.sh ["message"]` builds the app into a temporary folder and opens it on
  throwaway data (`BOTCHU_DATA_DIR`) with two demo bots, the first with a short sample
  conversation and memory, optionally sending it a message (a real turn on Claude Dev); the app writes a PNG of each of its windows into the printed folder every second
  (`BOTCHU_SNAPSHOT`), so screens can be checked without screen-recording permission.
  `BOTCHU_OPEN=editor` or `BOTCHU_OPEN=settings` opens the bot editor or Settings instead.
- Smoke test after deploy: `macOS/install.sh` fails unless the installed app starts (launched hidden,
  checked with `pgrep -x BotChu`, and quit again unless it was already open).

## Deploy
- **Host machine:** `Alexs-MacBook-Pro-92440`. The live checkout is `~/Desktop/WORKSPACE/BotChu`, which always stays on `main`; the app is installed to `~/Applications/BotChu.app`.
- **Secrets:** None in the repository or `.env`. The OpenRouter key lives in the Keychain, entered in Settings.
- **Deploy only on request:** `scripts/deploy.sh` sets `DEPLOY_ON_REQUEST=1`, because installing restarts BotChu and stops any bot mid-turn. A full `scripts/sync.sh` fetches and reports how far `origin/main` is ahead of what is live, and changes nothing; run `scripts/deploy.sh` in the live checkout to test and install `main` (`--force` reinstalls anyway). Every attempt is a line in `.git/deploys`.
- **Sync first:** run `scripts/sync.sh` before running or restarting the app or using its live data, and after merging a pull request. It refuses if `~/Desktop/WORKSPACE/BotChu` has local edits or commits not on `origin/main`; fix those through a pull request. Unless it refuses, it then removes worktrees whose pull request merged. Run from a worktree, it removes them too, but does not deploy.
- **Session start:** Claude Code runs `scripts/sync.sh --inspect`, and every other agent runs it first. It fetches and reports the live checkout's state and what a full sync would do, but deploys nothing, so a session that only reviews or inspects never touches the app. A full sync that refuses blocks live-app operations, not reviews.
- **Scheduled jobs:** none.
- **Branch work:** Every task runs in its own worktree: for example, `scripts/worktree.sh feat/12-add-login` creates `~/Desktop/WORKSPACE/BotChu/.claude/worktrees/feat-12-add-login` from `origin/main`, with `.env` linked. Never edit `~/Desktop/WORKSPACE/BotChu` directly; changes only reach the live app by merging a pull request to `main` and deploying.
