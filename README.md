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
  - **Pets:** a bot can have an animated character in place of its emoji: its head in the sidebar
    and the chat, and its whole figure at the top of the status sidebar. It acts out what the bot is
    doing in a turn, judged from each tool call the CLI reports: thinking, researching (reading and
    searching files), browsing (web search and fetch), coding (editing files, commits), testing
    (builds, tests, linters), working (anything else); it celebrates when a turn ends, looks
    deflated after a failed one, and waves when its bot is selected. A pet is a Codex pet (the
    `hatch-pet` skill's 8 × 9 or 8 × 11 atlas of 192 × 208 cells), plus optional extra animations
    BotChu adds for these activities; missing ones fall back to the closest atlas row. **Import
    Codex Pet…** in **Edit Bot** copies one in (for example from `~/.codex/pets/<name>`), and the
    bot's **Appearance** text says how it looks. Reduce Motion shows a still frame. Only the
    selected bot and busy bots move in the sidebar.
  - **Accounts:** any bot can run on any account, switchable in **Edit Bot**:
    Claude Personal, Claude Dev and Claude Work (`claude-personal`, `claude-dev`, `claude-work`),
    Codex Personal, Codex Dev and Codex Work (`codex-personal`, `codex-dev`, `codex-work`), Google
    (Antigravity, `agy`), Muse (`muse`), and OpenRouter (the Pi agent, `pi`, with an OpenRouter key
    and any OpenRouter model). Each account's command can be changed in Settings.
  - **Chat:** one continuous thread per bot. Replies stream in, rendered as Markdown; each tool the
    agent runs shows as a collapsible card with its input and output. Headings, nested lists, quotes,
    tables and fenced code use native block layouts; code has a Copy button. Antigravity subagent
    launch cards finish when the CLI acknowledges the launch; the bot reports the workers' results
    in its replies. A missing completion record shows a neutral question mark, not a tool failure.
    A turn can be stopped. The
    thread and the CLI's session id are saved, so the next message (also after a relaunch) resumes
    the same CLI session.
  - **Model controls:** below the message field, choose a model and reasoning effort for the bot's
    existing account. Choices are saved and applied on the next turn, including resumed sessions.
    The menu has starter model choices and a custom model ID field for the current CLI; it cannot
    switch accounts or CLI providers. Defaults leave the choice to the CLI (or the OpenRouter model
    in Settings). Effort choices depend on the provider/model, and controls wait until a turn ends.
    For known Antigravity models, the effort also selects the matching model-ID suffix.
  - **The bot's folder is the bot:** BotChu keeps each bot's settings (`bot.json`), its whole
    conversation (`thread.jsonl`, one message per line), a log of every turn (`logs/<date>.log`:
    the command, how long it took, the exit status, any error and the CLI's error output) and its
    pet (`pet/`: `pet.json`, the spritesheet, and `activities.json` with `activities/<id>/NN.png`
    for extra animations) in `.botchu/` inside its workspace, with a `.gitignore` so a repository never commits them. The bot
    is told it can search them for earlier conversations. **History & Logs** in the status sidebar
    opens the folder. Each bot needs its own workspace, and not the bots folder itself; moving a
    bot's workspace in its editor moves its `.botchu/` with it, and deleting a bot puts only its
    `.botchu/` in the Trash.
  - **Memory:** each bot's workspace has a `MEMORY.md` it keeps itself, and the bots folder's
    `MEMORY.md` (`~/BotChu/MEMORY.md` by default) is shared by every bot. Both, with the bot's identity and instructions, open every new CLI session
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
    its `MEMORY.md` (`BotStatus.swift`), pets: the atlas rows, BotChu's extra animations, the
    activity a tool call means and the pet folder (`Pet.swift`), the JSON store (`Store.swift`), and the `Process` runner
    that launches a CLI through the login shell, `zsh -l` (`AgentRun.swift`).
  - `Sources/BotChu/` — the SwiftUI app, a standard `NavigationSplitView` window with an inspector,
    in standard system materials: `App/` (the app, window, model, settings, Keychain, dev hooks),
    `Sidebar/` (the bot list), `Chat/` (messages and the composer), `Inspector/` (the status
    sidebar), `Editor/` (the bot sheet), `Settings/`, and `Shared/` (layout constants, the avatar,
    the status badge, and the pet sprite: atlas decoding and the animated view).
  - `Sources/botchu-smoke/` — a command-line check, not shipped in the app, that runs two real
    turns on each account named the way the app does (see **Test**).
  - `Tests/BotChuCoreTests/` — parser tests against captured output of every CLI, command lines,
    context and store.
  - `build.sh [outdir]` builds the release binary and wraps it into `{outdir}/BotChu.app` (default
    `macOS/build/`), signed with the local "Apple Development" certificate when there is one, ad hoc
    otherwise. It records the SDK the app was linked against in the binary (`vtool`), because
    SwiftPM's default build system records the deployment target there instead, and macOS then
    runs the app with the old window design, whose toolbar overhangs the sidebar. `install.sh` builds into `~/Applications`, restarts BotChu if it was running, and
    smoke-tests that it starts. `test.sh` runs the unit tests. `ui-review.sh` opens a build on
    throwaway data for checking its screens (see **Test**).
- Data: each bot's `.botchu/` folder in its workspace (above), and `index.json` in
  `~/Library/Application Support/BotChu/`, which only lists the bots' workspaces in sidebar order.
  Versions before bot folders kept everything in `bots.json` and `threads/` there; the first launch
  moves them into the bots' folders and keeps the old files in `backup-before-bot-folders/`.
  Settings are in the `defaults` domain `local.BotChu`; the OpenRouter key is in the Keychain
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
  OpenRouter needs `OPENROUTER_API_KEY` in its environment. To exercise explicit generation
  settings, prefix the command with `BOTCHU_SMOKE_EFFORT=low` and optionally
  `BOTCHU_SMOKE_MODEL=<model id>`; both settings apply to the new and resumed turns.
- Screens: `macOS/ui-review.sh ["message"]` builds the app into a temporary folder and opens it on
  throwaway data (`BOTCHU_DATA_DIR`, with its own settings domain, `local.BotChu.dev`) with two demo
  bots in the old layout, so every run also exercises the migration into bot folders, the first
  with a short sample conversation and memory, optionally sending it a message (a real turn on
  Claude Dev); the app writes a PNG of each of its windows into the printed folder every second
  (`BOTCHU_SNAPSHOT`), so screens can be checked without screen-recording permission.
  `BOTCHU_OPEN=editor` or `BOTCHU_OPEN=settings` opens the bot editor or Settings instead.
  `BOTCHU_PET=~/.codex/pets/<name>` gives the first bot that Codex pet. The window's picture leaves
  out the sidebar's rows, so they are drawn on their own into `sidebar.png`.
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
