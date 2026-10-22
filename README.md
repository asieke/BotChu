# BotChu

A minimal, open-source, native macOS app for persistent AI bots, in the spirit of Grok Bot and
[rakazo](https://github.com/elie222/rakazo). Bots are listed down the left; the selected bot's chat
fills the window. Each bot is driven by a coding-agent CLI that is already installed and signed in on
the Mac, and runs in its own workspace folder on this Mac. A bot can also work on tasks in
repositories, in parallel, each in its own git worktree and in a tab beside its own conversation.

## Scope
- Does:
  - **Bots:** create, edit and delete bots. A bot has a name, an emoji, a one-line title, private
    instructions, an account, an optional model and a workspace folder (default `~/BotChu/<name>`).
    A new bot introduces itself in one reply, so a misread role shows up at once.
  - **Pets:** a bot can have an animated character in place of its emoji, shown in a circle: its
    face in the sidebar and the chat, and larger at the top of the status sidebar. It is a set of
    short looping videos, one per activity, like the character in Meta's Muse: idle; thinking;
    researching (reading and searching files); browsing (web search and fetch); coding (editing
    files, commits: at a laptop, with headphones on); testing (builds, tests, linters); working
    (anything else); a wave when its bot is selected and a cheer when a turn ends, which play once;
    and a deflated loop after a failed turn. The activity comes from each tool call the CLI reports,
    and a tool's clip shows for at least 2.5 seconds. Clips loop without a seam, cross-fade when the
    activity changes, and play muted. A missing clip falls back to a close one, then idle. Only the
    selected bot and busy bots move in the sidebar, the chat shows still frames, and Reduce Motion
    shows stills everywhere.
  - **Making a pet:** describe the bot's look in **Appearance** in **Edit Bot** and choose **Make
    Pet…** (or **Create and Make Pet** when creating a bot with an appearance); BotChu asks first,
    with the estimated cost. One `codex exec` on a Codex account draws eight square stills of the
    character, one per pose, with its built-in image generation (on that account's ChatGPT
    allowance). BotChu then sends each still to an image-to-video model on OpenRouter, as both the
    first and last frame of a 4 or 5 second clip, so it loops; all ten clips at once. A request
    that fails for a passing reason (a rate limit, a server error, a dropped connection) is tried
    twice more, 5 and 15 seconds later. Each clip is
    scaled down to 256 × 256 pixels after downloading. The default model, Seedance 1.5 Pro at
    480p, costs about $0.06 a clip, about $0.56 a pet; Kling 3.0 Standard at 720p is about $4. It
    takes about 10 minutes. A remake with the same appearance keeps the character: the current
    pet's idle still (or, for a bot whose pet was drawn before video pets, its base image) goes to
    Codex as the reference. It works in `.botchu/pet-making/` and replaces the pet only once its idle
    clip exists, so chat goes on and the old pet stays meanwhile; the bot's log records the Codex
    run, each clip and its cost. Progress shows in the editor and the status sidebar, with Cancel
    (clips already started on OpenRouter still finish and are charged; drawn stills are kept for
    the next try). A bot on a Codex account draws with its own account; others use the one in
    Settings. It needs the OpenRouter key in Settings.
  - **Accounts:** any bot can run on any account, switchable in **Edit Bot**:
    Claude Personal, Claude Dev and Claude Work (`claude-personal`, `claude-dev`, `claude-work`),
    Codex Personal, Codex Dev and Codex Work (`codex-personal`, `codex-dev`, `codex-work`), Google
    (Antigravity, `agy`), Muse (`muse`), and OpenRouter (the Pi agent, `pi`, with an OpenRouter key
    and any OpenRouter model). Each account's command can be changed in Settings.
  - **Chat:** one continuous thread per bot (its **Home**), and one per task. Replies stream in, rendered as Markdown; each tool the
    agent runs shows as a collapsible card with its input and output. Headings, nested lists, quotes,
    tables and fenced code use native block layouts; code has a Copy button. Replies have soft rounded
    bubbles. Inline and display math use bundled KaTeX; Mermaid code fences display diagrams with
    source/copy and fit/actual-size controls. Both render offline in system WebKit, including inside
    tables and lists. Unsupported or incomplete expressions and diagrams stay readable as source.
    Antigravity subagent
    launch cards finish when the CLI acknowledges the launch; the bot reports the workers' results
    in its replies. A missing completion record shows a neutral question mark, not a tool failure.
    A turn can be stopped. The
    thread and the CLI's session id are saved, so the next message (also after a relaunch) resumes
    the same CLI session.
  - **Tasks:** besides its Home, a bot can work on tasks, several at once: each in a repository
    checked out in the repositories folder (`~/Desktop/WORKSPACE` by default), with its own
    conversation and CLI session, in its own git worktree, so tasks never share files. BotChu does
    all of this itself, with no other app. **New Task** (⌘T) picks the repository, an open issue or pull request there (listed with
    `gh`) or something new, the branch and the account. BotChu makes the worktree before the first
    turn, in `.claude/worktrees/<type>-<slug>` of the checkout: with the repository's own
    `scripts/worktree.sh` when it follows the workspace standard (which also links a new
    `<type>/<number>-<slug>` branch to its issue on GitHub), else with git; a pull request's task
    works on the pull request's branch. An issue, pull request or branch has at most one open task
    (BotChu refuses a second), and a branch named from a brief gets a number when the name is
    taken, so tasks never share a worktree. The main checkout stays on its branch, and BotChu writes
    nothing into the repository: a task's first message opens with the bot's identity, instructions
    and memory (which stays in the bot's folder), where the task is and what it is, as the workspace
    standard hands work to an agent. Tasks show as tabs above the chat (⌃Tab moves between them),
    each with a light: working, failed, news since you last looked, or a pull request it opened.
    Closing a tab keeps the task's record, conversation and worktree; Home's status lists closed
    tasks to open again. A worktree goes once its pull request merges, with the repository's
    `scripts/worktree.sh --tidy`; if it is gone, the task's next message makes it again.
  - **Home coordinates:** a bot asks for a task itself by writing a JSON request into
    `.botchu/dispatch/` in its folder (`{"repo": "owner/name", "issue": 48, "task": "…"}`), as its
    `AGENTS.md` explains. While a Home turn runs, BotChu takes requests within seconds and starts
    each in its own tab. Home gets a receipt when a task starts, ends a turn or fails (with an Open
    link to its tab), or can't start, and its next turn opens with a report on those tasks: their
    state, pull request and the start of their last reply. A new Home session also lists the open
    tasks. The sidebar row counts the bot's conversations with news.
  - **Message box:** a multiline writing area with account, model/effort and send/stop controls in
    its bottom row. Return sends; Option-Return inserts a new line.
  - **Model controls:** separate model and reasoning-effort buttons below the writing area and in
    the status sidebar's **Runs on** card open the same pickers. Both stay in sync for the shown
    Home or task conversation; choices are saved for its next turn, including resumed sessions.
    Model search matches names and IDs, with a checkmark on the current selection and a custom-ID
    option. OpenRouter shows the actual model inherited from Settings (for example **Flint (free)**),
    and searches its public catalog of text models with tool support, with context sizes. Catalog
    requests contain no key or conversation data, are cached in memory for an hour, and preserve
    current/custom choices when unavailable. Other providers offer starter choices and label an
    unspecified model as the account's default. **Auto** effort leaves the choice to the account;
    explicit levels include short explanations, and unsupported effort controls are disabled.
    Search supports arrow keys and Return; Escape dismisses a picker. Controls wait until a turn
    ends and cannot switch accounts or providers. For known Antigravity models, effort also selects
    the matching model-ID suffix.
  - **The bot's folder is the bot:** BotChu keeps each bot's settings (`bot.json`), its whole
    conversation (`thread.jsonl`, one message per line), its tasks (`tasks/<id>/`: `task.json` with
    the repository, branch, worktree, session and pull request, and the task's `thread.jsonl`), the
    task requests it writes (`dispatch/`), a log of every turn (`logs/<date>.log`:
    the command, where it ran, how long it took, the exit status, any error and the CLI's error output) and its
    pet (`pet/`: `video.json`, `stills/<pose>.png`, `clips/<activity>.mp4` and the appearance it
    was made from) in `.botchu/` inside its workspace, with a `.gitignore` so a repository never commits them. The bot
    is told it can search them for earlier conversations. **History & Logs** in the status sidebar
    opens the folder. Each bot needs its own workspace, and not the bots folder itself; moving a
    bot's workspace in its editor moves its `.botchu/` with it, and deleting a bot puts only its
    `.botchu/` in the Trash.
  - **Memory:** each bot's workspace has a `MEMORY.md` it keeps itself, and the bots folder's
    `MEMORY.md` (`~/BotChu/MEMORY.md` by default) is shared by every bot. Both, with the bot's identity and instructions, open every new CLI session
    and are written to the workspace's `AGENTS.md`, `CLAUDE.md` and `GEMINI.md`, so the agent keeps
    them across its own context compaction. A new session (new bot, account switch, or **New
    Session**) also gets the recent conversation, so switching accounts keeps the thread's continuity.
  - **Status sidebar:** on the right of the chat (View ▸ Show Status, ⌥⌘I). A card at the top shows
    the selected bot's face (its pet, playing, or its emoji) in a ring that says its state (grey when idle, a
    spinning violet arc while it works, red after a failed turn), its name and title, a pill while
    working or after an error, and a line on what it is doing with the turn's running time
    (or when it was last active, or the
    error). Grouped cards below give the account, agent and model it runs on, **Usage** (between
    **Runs on** and **Session**), whether the next message continues its CLI session (with its id
    to copy), its open tasks, its message and tool-call counts, last
    activity and creation date, what its `MEMORY.md` holds, and its workspace, with Edit and New
    Session. On a task's tab it shows the task instead: its repository, issue, branch, pull request
    (and whether it is open, merged or closed), the account (which can change there), that account's
    usage, session and worktree (in Finder or Terminal), with Close Task and New Session. Its colors
    follow light and dark mode. The window is never narrower than the sidebar, chat and status
    need, so it widens when they do.
  - **Account usage:** the selected account's allowance used and reset times, shared by all bots
    on that account. Claude Code and Antigravity use their native `/usage` commands; Codex uses
    `account/rateLimits/read`. They run the command configured in Settings, with the CLI managing
    its own login. Checks run in a temporary folder, outside bot conversations, every five minutes
    while the status sidebar is open, after turns, or with Refresh (at most once every 30 seconds).
    Muse needs one brief `Reply with OK.` request to learn its allowance: it uses isolated,
    temporary host state, checks hourly automatically, and at most once every five minutes after
    a turn or with Refresh. This spends a small amount of its allowance. OpenRouter shows the
    saved key's spending allowance and any reported shared budgets, with resets at midnight UTC;
    an uncapped key says so, without claiming unlimited account credits. Saving a different key
    clears its previous readout. Failed checks retain the last successful reading marked stale;
    an expired window hides its old percentage until a new reading arrives. CLI output,
    credentials and usage readings are not written to disk by BotChu.
  - **Settings:** the bots folder, the repositories folder, each account's command, the Codex
    account that draws pets' stills, the OpenRouter model that animates them (with its cost per
    pet), the OpenRouter API key (Keychain) and default OpenRouter model.
- Does not: run bots or tasks anywhere but this Mac (yet: SSH hosts, set up in BotChu itself, come
  later in #16), clone repositories, schedule routines, ask for approval of tool calls (every
  CLI runs with its permission prompts bypassed, inside the bot's folder or the task's worktree), or
  keep any secret outside the Keychain and the CLIs' own logins.

## Architecture
- `macOS/` is a Swift package (Swift 6 toolchain, macOS 14+):
  - `Sources/BotChuCore/` — Foundation only, unit-tested: accounts and the command line each CLI
    runs with (`Accounts.swift`), generation choices and public OpenRouter model metadata
    (`GenerationOptions.swift`, `ModelCatalog.swift`), the bot and message model (`Models.swift`), one stream parser per
    CLI turning its JSON lines into chat events (`StreamParsers.swift`), the identity, memory and
    recap that open a session (`BotContext.swift`), account allowance parsing and native queries
    (`ProviderUsage.swift`, `ProviderUsageClient.swift`) with a throttled in-memory cache
    (`UsageCache.swift`), what the status sidebar shows about a bot and
    its `MEMORY.md` (`BotStatus.swift`), pets: the activity a tool call means
    and the clips that show it (`Pet.swift`), making a pet: its poses and clips, the Codex prompt
    for the stills, the OpenRouter request and job, the cost estimate, the manifest and install
    (`PetVideo.swift`), tasks: the task, its title
    and branch names, its pull request, receipts and dispatch requests (`Tasks.swift`), the
    checkouts in the repositories folder, task worktrees and what `gh` says about issues and pull
    requests (`Repositories.swift`), the JSON store (`Store.swift`), and the `Process` runner
    that launches a CLI through the login shell, `zsh -l` (`AgentRun.swift`).
  - `Sources/BotChu/` — the SwiftUI app, a standard `NavigationSplitView` window with an inspector,
    in standard system materials: `App/` (the app, window, model, settings, Keychain, dev hooks, making
    pets and the OpenRouter video client),
    `Sidebar/` (the bot list), `Chat/` (the tab bar, messages and the composer), `Inspector/` (the
    status sidebar, a bot's and a task's), `Editor/` (the bot sheet and New Task), `Settings/`, and
    `Shared/` (layout constants, the avatar, the status badge, and the pet's looping video).
    `Resources/ChatRenderer/` bundles pinned Mermaid and KaTeX distributions, their fonts and licenses. Its README records provenance and update steps; no JavaScript package
    install or network access is needed at runtime. The rendering document blocks remote resources
    and model-supplied scripts, uses Mermaid's strict mode and disables trusted TeX commands.
  - `Sources/botchu-smoke/` — a command-line check, not shipped in the app, that runs two real
    turns on each account named the way the app does (see **Test**).
  - `Tests/BotChuCoreTests/` — parser tests against captured output of every CLI, command lines,
    context and store, and tasks: naming, dispatch requests, checkouts, `gh`'s output, and worktrees
    made in throwaway repositories.
  - `Tests/BotChuRenderingTests/` — actual WebKit math/diagram layout, streaming updates, source
    fallback and offline restrictions, model-picker keyboard interaction and persisted choices,
    and the main window's layout at its narrowest. These share a serialized suite because AppKit
    window focus is global; all use isolated windows and no real bot data.
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
  (service `local.BotChu`). Bot workspaces are under `~/BotChu/` by default; tasks run in worktrees
  of the checkouts in the repositories folder. No database and no port.
- Each turn runs one headless CLI process in the bot's folder, or a task's worktree:
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
- Install: no dependency installation is needed; the renderer assets are included in the repository.
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
  with a short sample conversation and memory and two tasks in a throwaway repository (with a local
  origin, so nothing reaches GitHub), optionally sending it a message (a real turn on
  Claude Dev); the app writes a PNG of each of its windows into the printed folder every second
  (`BOTCHU_SNAPSHOT`), so screens can be checked without screen-recording permission.
  `BOTCHU_OPEN=editor`, `BOTCHU_OPEN=task` or `BOTCHU_OPEN=settings` opens the bot editor, New
  Task or Settings instead. `BOTCHU_TAB=<n>` shows the first bot's nth tab (and the message goes
  there), and `BOTCHU_TASK="hello-world|<task>"` starts a task in the throwaway repository (a real
  turn).
  `BOTCHU_PET=<pet folder>` gives the first bot that pet (`video.json`, `stills/`, `clips/`), and
  `BOTCHU_DRAW_PET="<appearance>"` makes it one (a real Codex run and real OpenRouter clips, which
  cost credit). The window's picture leaves out the sidebar's rows and video layers, so the rows
  are drawn on their own into `sidebar.png`, each pet's current frame is drawn into its circle, and
  `pets.txt` lists each pet player's clip, state and time.
  `BOTCHU_APPEARANCE=dark` (or `light`) reviews that appearance without changing the system setting.
  `BOTCHU_USAGE=sample` (or `stale`, `expired`, `unavailable`) reviews allowance states without
  querying any account. Usage fixtures are ignored outside throwaway data runs.
  `BOTCHU_ACCOUNT`, `BOTCHU_MODEL` and `BOTCHU_EFFORT` set the first demo bot's generation choices;
  `BOTCHU_DEFAULT_MODEL` supplies an isolated OpenRouter default. `BOTCHU_OPEN=model` or `effort`
  opens the composer's picker, and `inspector-model` or `inspector-effort` opens the sidebar's.
  `BOTCHU_WINDOW=compact` checks the minimum window width.
- Account allowance end to end: `swift run --package-path macOS botchu-smoke --usage [account id …]`
  reads each account's usage through the same client as the inspector. It prints only the normalized
  usage fields, never raw CLI output or credentials. Muse makes its brief usage request; OpenRouter
  needs `OPENROUTER_API_KEY` in the environment. This is separate from the two-turn conversation smoke.
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
