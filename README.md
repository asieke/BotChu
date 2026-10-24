# BotChu

A minimal, open-source, native macOS app for persistent AI bots, in the spirit of Grok Bot and
[rakazo](https://github.com/elie222/rakazo). Bots are listed down the left; the selected bot's chat
fills the window. Each bot is driven by a coding-agent CLI that is already installed and signed in on
the Mac, and runs in its own workspace folder on this Mac. A bot can also work on tasks in your
GitHub repositories, in parallel, each in its own git worktree and nested under its bot in the left
sidebar: on this Mac, or on another computer it reaches over SSH. A task can also review a pull request.

## Scope
- Does:
  - **Workspace:** the left sidebar has **Projects**, **Agents**, and **Providers**, followed by
    the bots’ conversations, in sections (below). Opening a gallery keeps the selected conversation and unsent draft;
    turns that finish while a gallery is shown still get an unread badge. In dark mode the sidebar
    takes the status sidebar's darker shade, with a hairline along its edge, so it stands apart from
    the chat; light mode keeps the standard sidebar.
  - **Sections:** bots can be grouped into sections you name, each a heading of its own in the
    sidebar. A bot's **Move to Section** menu lists Conversations (no section) and the sections,
    with its own checked, and **New Section…**, which names a section and moves the bot into it;
    a moved bot goes last in its section. Bots in no section, new bots among them, come first,
    under Conversations, so a sidebar without sections looks as before. A section heading's menu
    renames it (another section's name merges the two), moves it up or down, or removes it, which
    returns its bots to Conversations and deletes nothing. Names are trimmed and matched whatever
    their case, and no section can be called Conversations. Headings collapse, and stay collapsed
    across launches, but what is selected from elsewhere (Agents, a new bot or task, ⌃Tab) shows
    in its section.
    Sections are kept in `index.json` with the sidebar's order, so a bot whose folder is missing
    comes back in its section.
  - **Projects:** one project per non-archived GitHub repository returned by `gh` for your account
    and organizations, in a sortable table modeled on GitChu's (or a gallery of cards). Columns show
    where it deploys (local machines by their BotChu name, Vercel, registry), the owner, open issues
    and pull requests, last push, type, merge policy, the computer its tasks work on (with whether
    the checkout exists on this Mac), and the bots' open tasks there; columns can be hidden,
    reordered and resized, and that is remembered. Cards show the description and visibility
    from GitHub, and the name, type and status from `PROJECT.md` on the default branch. **Docs** is
    non-code; **Library**, **Local app**, and **Hosted app** are code. Unclassified repositories can
    get a minimal project record, without claiming the repository meets the workspace standard.
    The list shows active projects (`status: active` in `PROJECT.md`) unless its status filter says
    otherwise: every status, or only paused, maintenance, deprecated or unclassified ones (no
    `PROJECT.md`); the choice is remembered. A repository whose `PROJECT.md` isn't read yet appears
    once it is known to be active.
    **Pull Requests** and **Issues** list the open ones across the repositories (up to 30 most
    recently updated per repository, saying so when there are more), with checks, review state,
    labels, author and any bot's task on them, filtered by repository or search. Selecting one opens
    it in the repository's sidebar, and double-click on GitHub; its menu reviews a pull request
    (**Review with**, **Review and Comment with**), continues it (unless it comes from a fork) or
    starts a task on an issue with a bot, opening New Task with it chosen, or opens the task already
    on it. These are read with one GraphQL query per page of repositories and one per ten busy
    repositories, at most every ten minutes unless refreshed.
  - **Project sidebar:** selecting a repository, in the table or the gallery, shows it on the right
    with three tabs; closing the sidebar deselects it, and an issue or pull request count in the
    table opens that tab. **Overview** has its open work, its type, status, merge policy and
    deployment, where its tasks work, the open tasks on it, **Start Task with**, **Edit Metadata…**
    and GitHub. **Issues** and **PRs** list the open ones read for it (saying so when there are
    more), with their labels, checks and the bots on them; each opens in place, read with `gh issue
    view` or `gh pr view`: its description, labels and conversation, and a pull request's branches,
    checks, changed files and reviews. An issue's **Fix with** starts a task on it with an agent, and
    **Fix All** one task in which the agent hands each listed issue that no task works on to a
    parallel sub-agent of its own (`botchu-subagent spawn`, at most four at once), each in its own
    worktree and branch with a pull request that closes its issue. A pull request's **Review**
    reviews it with an agent, here or also on GitHub (**Continue** works on its branch, unless it
    comes from a fork), and **Review All** starts one task that reviews each pull request no task is
    reviewing yet with parallel sub-agents, each in a detached worktree of its own. Every start
    opens New Task with the agent, the repository and the issue, pull request or fan-out brief
    chosen, so the account and workspace can be checked (and the brief edited) first. Its tasks work
    where the project deploys; when that computer isn't connected in Settings ▸ Hosts, New Task says
    so and offers **Work on This Mac**, which is remembered for the project.
  - **Project metadata:** **Edit Metadata…** edits the name, type, status, deployment, and merge
    policy in `PROJECT.md`. **Create Metadata PR** uses `gh api` to create a documentation branch,
    commit only that file, and open a PR; it never clones the repo or runs its test suite. Repository
    checks and merge requirements still apply. Other frontmatter and the Markdown body are preserved;
    ambiguous YAML and a file changed since editing began are refused. Interrupted saves can retry
    the same branch without duplicate commits or PRs. The project and task placement update only
    after the metadata PR merges and **Refresh** reads the default branch again. BotChu needs write
    access for this flow; forks can be used through GitHub. The editor creates no commits directly
    on the default branch and never merges metadata PRs.
  - **Agents:** a searchable gallery of the existing bots, showing their personality summary,
    provider, activity and task count, with **Open Chat**, **Edit…** and **New Agent**. A bot’s own
    conversation continues to work without a project.
  - **Providers:** gallery/list views of CLI profiles with their logo, command, availability and usage,
    sharing the same allowance cache and refresh limits as the conversation inspector. **Add CLI**
    adds a named profile of Claude Code, Codex, Antigravity, Muse or Pi, with an installed command or
    wrapper and **Test Command**. Sign in through that CLI in Terminal; BotChu does not create its
    login. Added profiles appear in bot/task account pickers, host command overrides, and Settings;
    Codex profiles can also draw pets. Bots and tasks retain a copy of their custom profile’s CLI
    family and command across relaunches. Command overrides remain editable in Settings. Pi profiles
    use the shared OpenRouter key. Provider usage refreshes while visible, with Muse’s existing
    brief request and hourly automatic limit.
  - **Bots:** create, edit and delete bots. A bot has a name, an emoji, a one-line title, private
    instructions, an account, an optional model and a workspace folder (default `~/BotChu/<name>`).
    A new bot introduces itself in one reply, so a misread role shows up at once. Instructions are
    the bot's role and job in Markdown, kept in `INSTRUCTIONS.md` in its workspace and edited in
    **Edit Bot** or from the status sidebar's **Memory** tab; a bot from before that file has the
    instructions in its `bot.json` moved into it once, after which the file is the only source. An
    empty or missing file tells the bot to ask its owner what they need.
  - **Pets:** a bot can have an animated character in place of its emoji, shown in a circle: its
    face in the sidebar and the chat, and larger at the top of the status sidebar. It is a set of
    short looping videos, one per activity, like the character in Meta's Muse: idle; thinking;
    researching (reading and searching files); browsing (web search and fetch); coding (editing
    files, commits: at a laptop, with headphones on); testing (builds, tests, linters); working
    (anything else); a wave when its bot is selected and a cheer when a turn ends, which play once;
    and a deflated loop after a failed turn. Selection gives the wave five seconds, and reactions
    finish their full clip before returning to idle. The activity comes from each tool call the CLI reports,
    and a tool's clip shows for at least 2.5 seconds. Clips loop without a seam, cross-fade when the
    activity changes, and play muted. A clip shows once its video has a frame; until then the clip
    before it stays, or the pose's still, so a pet never blinks out, as when its bot is selected.
    A missing clip falls back to a close one, then idle. Only the
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
    Wherever an account or a CLI family is shown, so is the family's logo, as in GitChu: Claude's
    spark, OpenAI's knot for Codex, Google's G for Antigravity, Facebook's f for Muse, and π for Pi.
  - **Chat:** one continuous thread per bot (its **Home**), and one per task. Replies stream in, rendered as Markdown (each reply
    is parsed once, and recent ones ahead of time, so showing a conversation again doesn't parse it again); the
    agent's tool work shows as activity (below). Headings, nested lists, quotes,
    tables and fenced code use native block layouts; code has a Copy button. Replies have soft rounded
    bubbles. Inline and display math use bundled KaTeX; Mermaid code fences display diagrams with
    source/copy and fit/actual-size controls. Both render offline in system WebKit, including inside
    tables and lists; a reply's web view is made as it nears the visible part of the chat, with only
    the renderer it uses, and shows once the reply has rendered, at its final height, so neither a
    blank page nor the source flashes first. Rendered replies' web views are kept, hidden, when
    their conversation closes, so opening it again shows them at once: up to about 200 MB of them
    (a reply with a diagram takes about 85, one with math alone about 20), each for ten minutes,
    and none once macOS reports memory pressure. Unsupported or incomplete expressions and diagrams stay
    readable as source. While a turn works and nothing of its reply shows yet, three dots in a
    bubble rise and brighten in turn (with Reduce Motion they only brighten). Switching
    conversations redraws only the conversation: the toolbar's buttons stay as they are, the
    message box takes focus as the conversation appears, and a long chat opens at its very end.
    Antigravity subagent
    launch cards finish when the CLI acknowledges the launch; the bot reports the workers' results
    in its replies. A missing completion record shows a neutral question mark, not a tool failure.
    A turn can be stopped. The
    thread and the CLI's session id are saved, so the next message (also after a relaunch) resumes
    the same CLI session; quitting mid-turn saves what the turn printed so far. A CLI's output is
    parsed off the main thread and reaches the window a few times a second, and each conversation
    is observed on its own, so turns running elsewhere don't slow the one shown.
  - **Agent activity:** tool calls, of every CLI, are folded by what they are for. Consecutive
    read-only calls (reading, listing, searching, fetching, and shell commands known only to read,
    such as `cat`, `tail`, `sed -n`, `rg`, `find`, `ls` or `git status`) form one **Explored** group
    that names its counts, the folders it touched and its duration, with chips for the first seven
    files (`+N more`); a file read again right away shows once, `×2`, with the line ranges merged.
    Reply text, a command with side effects (builds, tests, git writes, redirects, and unknown or
    long commands), an edit, a sub-agent or a question ends a group. Failed calls keep a line of their
    own even in a folded group, merged by cause (`7 not found` and the files); a search that finds
    nothing isn't a failure. Commands stand alone with what ran, the exit code and time, the first
    line of output and `+N lines`; edits with the file and the lines added and removed. Each sub-agent
    BotChu runs (`botchu-subagent`) is one card where it was started, with its identity, task,
    status, time and tool calls, whose **Open** shows its thread in the Sub-agents tab; Claude
    Code's and Antigravity's own sub-agents are cards too. While a turn explores, its group stays open
    with its last three calls and a spinner on the current one, then folds into its summary in place.
    **View ▸ Chat Density** (also in the toolbar) chooses Compact (headers only), Detailed (the
    default: headers, files and errors) or Raw (every call with its arguments, as before); a click on
    a group or card opens or closes it whatever the density, and an opened card shows each call's
    arguments and output (the first 20 KB, with Copy for all of it). For this, each tool call keeps its
    arguments (long text shortened, an edit's text as the lines it adds and removes), exit code and
    duration; older threads show what they recorded. The chat opens at its newest items, as many as
    lay out quickly, with **Show earlier** above them. Only the messages after the last settled item
    are regrouped as a turn streams in, and a conversation shown again keeps its grouping and opened
    cards. A reader at the bottom follows new content; one reading earlier content keeps their place
    while a turn goes on, and **Follow Live** takes them back.
  - **Tasks:** besides its Home, a bot can work on tasks, several at once: each in one of your
    GitHub repositories, with its own conversation and CLI session, in its own git worktree, so
    tasks never share files. BotChu does all of this itself, with no other app. **New Task** (⌘T)
    asks only for the repository (from the ones `gh` lists for your account and your organizations,
    newest push first) and what to do, in one box that takes images as the message box does; they
    go with the task's first message, and ⌘↩ starts it. Opened from Projects for an issue or pull
    request, it works on that, and the box adds to it. The task runs on its bot's account (change
    it in the status sidebar), and BotChu names and manages branches automatically. A repository
    is worked on where you chose for it
    (Settings lists those choices), else where its `PROJECT.md` deploys it (`local:<machine>:<path>`,
    on this Mac or a host of that machine name), else in the repositories folder on this Mac
    (`~/Desktop/WORKSPACE` by default); BotChu clones it there if it isn't yet (`gh repo clone`, or
    `git clone` over HTTPS). BotChu makes the worktree before the first
    turn, in `.claude/worktrees/<type>-<slug>` of the checkout: with the repository's own
    `scripts/worktree.sh` when it follows the workspace standard (which also links a new
    `<type>/<number>-<slug>` branch to its issue on GitHub), else with git; a pull request's task
    works on the pull request's branch. An issue, pull request or branch has at most one open task
    (BotChu refuses a second), and a branch named from a brief gets a number when the name is
    taken, so tasks never share a worktree. The main checkout stays on its branch, and BotChu writes
    nothing into the repository: a task's first message opens with the bot's identity, instructions
    and memory (which stays in the bot's folder), where the task is and what it is, as the workspace
    standard hands work to an agent. Open tasks nest below their bot's row in the left sidebar
    (⌃Tab moves between Home and its open tasks). Each row shows activity, elapsed time while running, failure or unread state;
    the bot row counts running tasks. Only a bot with open tasks has a disclosure arrow, which expands
    without changing the conversation; a bot without any is a single row, whose first task comes from
    **New Task** (⌘T or the row's menu). The bot row opens Home, and **+ New task** after its tasks
    starts another. Task context menus keep workspace,
    browser, new-session and close actions. Closing a task keeps its record, conversation and worktree;
    Home's status lists closed tasks to open again. A worktree goes once its pull request merges, with the repository's
    `scripts/worktree.sh --tidy`; if it is gone, the task's next message makes it again.
  - **Pull request reviews:** a pull request's menu in Projects ▸ Pull Requests, or its **Review** in
    the project sidebar, can also **Review with** or **Review and Comment with** a bot, opening New
    Task for that review. The review works
    in a temporary worktree detached at the pull request's head (also
    from a fork), records that commit, and follows the workspace standard's review steps: the first
    gives the review in the task's conversation and posts nothing; the second also posts it on the
    pull request as one review, without asking again. Closing a review task removes its worktree.
  - **Hosts:** Settings ▸ Hosts lists other computers tasks can work on, reached with `ssh` and
    your keys, never a password: a nickname, the SSH host (an alias from `~/.ssh/config`, a host
    name or `user@host`), the folder repositories are checked out in there (`~/apps` by default),
    the machine name a `PROJECT.md` deploy target calls it (**Test Connection** reads it), and each
    account's command there when it isn't the same as on this Mac. A task on a host makes its
    worktree there and runs its CLI there, in that user's login shell; its output streams back, and
    Stop interrupts the CLI there. The bot's folder stays on this Mac: the task's first message
    brings the bot's identity, instructions and memory and a recap of its Home conversation, and
    notes the bot writes in `<remember>…</remember>` in a reply are applied to its `MEMORY.md` here
    (deduplicating existing bullets, updating entries in place with `Replace: old -> new`, removing
    entries with `Forget: old`, and dropping credentials/secrets).
    The status sidebar names the computer, and **Terminal** opens a shell in the
    worktree there. The OpenRouter key never leaves this Mac, so Pi on a host needs that host's own
    `OPENROUTER_API_KEY`.
  - **Home coordinates:** a bot asks for a task itself by writing a JSON request into
    `.botchu/dispatch/` in its folder (`{"repo": "owner/name", "issue": 48, "task": "…"}`, or
    `"review": 12` with `"comment": true` to post it, and `"machine"` for a host), as its
    `AGENTS.md` explains. While a Home turn runs, BotChu takes requests within seconds and starts
    each in its own sidebar row. Home gets a receipt when a task starts, ends a turn or fails (with an Open
    link to its conversation), or can't start, and its next turn opens with a report on those tasks: their
    state, pull request and the start of their last reply. A new Home session also lists the open
    tasks. The sidebar row counts the bot's conversations with news.
  - **Sub-agents:** Home, tasks and delegated runs can call another configured bot with
    `botchu-subagent call`, or launch several with `spawn` and collect their handoffs with `wait`.
    `list` shows the available bots. Each child uses the called bot's identity, soul, memory, account,
    model and effort in a fresh CLI session; its Home conversation is separate. By default it works
    in the caller's workspace, on the same machine; `--workspace bot_home` uses the called bot's
    folder on this Mac. Shared-workspace delegates should own separate files or review without editing.
    The **Sub-agents** inspector shows expandable nested runs, live tools/replies, duration, handoffs,
    Copy and Stop. Runs under way come first; finished ones fold into one **Finished** row, newest
    first, which counts any failures. A run that finishes while the tab shows it stays in view until
    the tab is shown again, as does one opened from the chat. Home also groups delegations
    belonging to its tasks. These runs never add left sidebar rows. Stop cascades through
    descendants; callers must wait before finishing their turn.
    Three nesting levels, twelve concurrent children and sixty-four delegations per root turn bound
    runaway fan-out. Interrupted records become stopped on relaunch. The helper needs Python 3 on
    each execution machine; SSH mailboxes are polled independently of CLI output. See
    [delegation protocol](docs/subagents.md) for lifecycle and persistence details.
  - **Message box:** a multiline writing area with account, model/effort and send/stop controls in
    its bottom row. Return sends; Shift-Return (or Option-Return) inserts a new line. The box grows with your draft, its first line staying in place as lines are added or removed, then scrolls at its maximum height with the line being typed in view; the report and New Task boxes do the same. Send stays available during a
    run: follow-ups appear in a queue above the composer and reach the bot on their own, in order,
    in the same CLI session. Where the CLI takes input mid-turn (Claude Code on This Mac, through
    `--input-format stream-json`), a follow-up reaches it at its next tool call, like steering in
    Claude Code itself; it shows as **Sent** until the CLI takes it, then joins the conversation
    where it was read. Every other account (Codex, Antigravity, Muse, Pi, and any task over SSH)
    gets it as the next turn, as soon as the running one ends. Pending messages can be edited or
    removed until they are sent. Only Stop and a failed turn pause the queue (**Paused · send when
    you're ready**), and a paused queue stays paused across relaunches; messages left queued when
    BotChu quit go out on their own after it starts again. **Send next** resumes a paused queue.
    Each Home and task has its own queue, saved beside its thread in `queued.jsonl` (with
    `queued.paused` while paused). A worktree being prepared finishes setup before follow-ups can run.
  - **Images:** use the **+** button, paste an image (⌘V, such as a copied screenshot) or image
    files, or drop them into the message box. Copied text still pastes as text when its app adds a
    picture of it after the text (as spreadsheets do), and other files paste as text too.
    Previews can be removed before sending; image-only messages work too. Up to eight images travel
    with each message, including queued messages restored after relaunch. Click a sent image to open it.
    Files up to 30 MB are decoded locally, resized to at most 2048 pixels on the longest edge, and saved
    as PNG copies (up to 5 MB each) in the bot's `.botchu/attachments/`; originals stay untouched.
    Animated images use a still frame. Copies stay with the bot when its folder moves.
    Claude receives image content on stdin; Codex, Muse and Pi receive image-file arguments;
    Antigravity is asked to open the attached files with its file reader. For file-based providers
    on SSH hosts, copies are stored in `~/.cache/botchu/attachments/` and retained for resumed sessions.
    Image understanding depends on the selected model's vision support.
  - **Model controls:** separate model and reasoning-effort buttons below the writing area and compact
    text selectors in the status sidebar's **Runs on** card open the same pickers. Both stay in sync
    for the shown Home or task conversation; choices are saved for its next turn, including resumed sessions.
    Model search matches names and IDs, with a checkmark on the current selection and a custom-ID
    option. OpenRouter shows the actual model inherited from Settings (for example **Flint (free)**),
    and searches its public catalog of text models with tool support, with context sizes. Catalog
    requests contain no key or conversation data, are cached in memory for an hour, and preserve
    current/custom choices when unavailable. Other providers offer starter choices and label an
    unspecified model as the account's default. **Auto** effort leaves the choice to the account;
    explicit levels include short explanations, and unsupported effort controls are disabled.
    Search supports arrow keys and Return; Escape dismisses a picker. Controls wait until the shown
    conversation's turn ends. The card's **Account** selector changes the account for Home or a task,
    including custom CLI profiles; the next message starts a session on that account. Other tasks
    keep their accounts. Switching CLI families resets model and effort choices. For known
    Antigravity models, effort also selects the matching model-ID suffix.
  - **The bot's folder is the bot:** BotChu keeps each bot's settings (`bot.json`), its whole
    conversation (`thread.jsonl`, one message per line), its tasks (`tasks/<id>/`: `task.json` with
    the repository, computer, branch, worktree, session and pull request, and the task's
    `thread.jsonl`), the
    task requests it writes (`dispatch/`), a log of every turn (`logs/<date>.log`:
    the command, where it ran, how long it took, the exit status, any error and the CLI's error output) and its
    pet (`pet/`: `video.json`, `stills/<pose>.png`, `clips/<activity>.mp4` and the appearance it
    was made from) in `.botchu/` inside its workspace, with a `.gitignore` so a repository never commits them. The bot
    is told it can search them for earlier conversations. **History & Logs** in the status sidebar
    opens the folder. Each bot needs its own workspace, and not the bots folder itself; moving a
    bot's workspace in its editor moves its `.botchu/`, `INSTRUCTIONS.md`, `MEMORY.md` and `SOUL.md` with it. Moving
    waits until its turns finish and refuses to overwrite files at the destination. Deleting a bot
    puts only its `.botchu/` in the Trash.
  - **Memory and personality:** each bot's workspace has a `MEMORY.md` for facts and notes it keeps
    itself, and an editable `SOUL.md` for its personality and voice. New bots get a starter soul based
    on their name and title; existing files are preserved, including intentionally empty ones.
    The bots folder's `MEMORY.md` (`~/BotChu/MEMORY.md` by default) is shared by every bot. Both
    memory files and the soul, with the bot's identity and instructions, open every new Home, task
    or sub-agent CLI session (including tasks over SSH). Every session shares the same memory capture
    policy: save stable owner preferences, confirmed facts, reusable lessons and durable decisions;
    keep temporary task progress in the conversation and repository rules in the repository; never
    save secrets/credentials, raw tool output, unverified guesses as facts, or anything the owner
    asks not to retain (sensitive details are omitted unless explicitly requested, and explicit
    requests never override exclusions); require evidence or confirmation for inferred notes while
    preserving relevant uncertainty; and update or remove outdated/conflicting bullets in place
    (or through `Replace:` and `Forget:` in `<remember>`). Memory remains data, not instructions.
    The workspace's `AGENTS.md`, `CLAUDE.md` and `GEMINI.md` carry the bot's `INSTRUCTIONS.md` and
    direct the agent to read the others, so it keeps them across its own context compaction; they
    are rewritten before every turn.
  - **Team playbook:** `TEAM.md` in the bots folder, beside the shared `MEMORY.md`, is the process
    every bot follows: its stages, handoffs, who calls whom with `botchu-subagent`, and when work is
    done. Unlike memory, it is given as instructions: in every bot's Home `AGENTS.md`, and at the
    start of every task and sub-agent session. It is left out entirely while it is missing or empty,
    and BotChu never creates it. Edit it from any bot's **Memory** tab or in Settings (**Shared by
    every bot**), where the shared `MEMORY.md` is edited too. Bots are told not to change
    `INSTRUCTIONS.md` or `TEAM.md` unless asked. A new
    session (new bot, account switch, or **New Session**) also gets the recent conversation, so
    switching accounts keeps the thread's continuity.
  - **Status sidebar:** on the right of the chat (View ▸ Show Status, ⌥⌘I). It opens at its widest,
    380 points; drag its edge to narrow it, down to 280. A card at the top shows
    a large character (its pet, playing, or its emoji) on the left, beside the bot name and current
    activity. Tasks show the repository as a larger title, with the issue or task title beneath it
    in smaller text. The ring says its state (grey when idle, a spinning violet arc while it
    works, red after a failed turn); plain text gives its activity and running time, last activity,
    or error. The character and ring convey status
    without a dot or status pill. The card and pet animation reflect only the shown Home or task;
    the bot list still shows activity across its tasks. Five icon tabs sit below the character,
    in a rounded bar with a raised selected segment: **Activity** (tasks and conversation stats), **Sub-agents** (delegated work),
    **Model & Usage** (account, agent, model, reasoning and allowance), **Session** (the CLI session
    and workspace controls), and **Memory** (instructions, personality, memory and the team
    playbook). Hover for tab names, or
    focus the bar and use Left/Right arrows. The selected area is remembered across conversations
    and launches; its data always belongs to the shown Home or task. The character, tabs and bottom
    actions stay visible while the selected area's content scrolls. Home keeps Edit and New Session;
    tasks keep Close Task and New Session. Task Activity includes the repository, computer and
    linked issue. Home and task accounts can change in Model & Usage; Session keeps Finder, Terminal and
    remote SSH controls. Branch names, review commits, generated pull request metadata and task
    authorship are managed internally and omitted from the task form, cards, headers, sidebar tooltips
    and new automatic progress notes. Explicitly choosing a pull request to continue or review is
    still available in New Task. Colors follow light and dark mode.
    Sections within each area, and Status above the tabs, still collapse from their headings, with
    their expansion remembered. **Memory** has four cards matching
    Conversation: the bot's **INSTRUCTIONS.md**, **SOUL.md** and **MEMORY.md**, and **TEAM.md**, the
    playbook every bot shares (the same file as in Settings), followed by a summary of what bots
    save in memory and what stays out. Each opens an in-app Markdown editor at half the
    parent window's width and height, with Save (⌘S), Cancel (Escape), and Reload. Saving preserves exact
    Markdown and refuses to overwrite a file changed on disk since it was opened. Saved changes
    apply at the next new session; **New Session** applies them to an existing conversation. The
    window is never narrower than the sidebar, chat and status
    need, so it widens when they do.
  - **Account usage:** the selected account's allowance used and reset times, shared by all bots
    on that account. Claude Code and Antigravity use their native `/usage` commands; Codex uses
    `account/rateLimits/read`. They run the command configured in Settings, with the CLI managing
    its own login. Checks run in a temporary folder, outside bot conversations, every five minutes
    while **Model & Usage** is visible, after turns while that area is open, or with Refresh (at most
    once every 30 seconds).
    Muse needs one brief `Reply with OK.` request to learn its allowance: it uses isolated,
    temporary host state, checks hourly automatically, and at most once every five minutes after
    a turn or with Refresh. This spends a small amount of its allowance. OpenRouter shows the
    saved key's spending allowance and any reported shared budgets, with resets at midnight UTC;
    an uncapped key says so, without claiming unlimited account credits. Saving a different key
    clears its previous readout. Failed checks retain the last successful reading marked stale;
    an expired window hides its old percentage until a new reading arrives. CLI output,
    credentials and usage readings are not written to disk by BotChu.
  - **Settings:** **GitHub ▸ Test Connection** checks that `gh` is available and can authenticate to
    github.com, then shows its version and signed-in username. Connection failures give install/login
    guidance without displaying credentials. Settings also contains the bots folder, the repositories folder, the hosts and where you chose to work
    on repositories, each account's command, the Codex account that draws pets' stills, the
    OpenRouter model that animates them (with its cost per pet), the OpenRouter API key (Keychain)
    and default OpenRouter model.
  - **Reporting bugs and features:** the ladybug button at the toolbar's trailing end, on every
    screen, or **Help ▸ Report a Bug or Feature…** opens a sheet with one field, which takes up to
    eight images as the message box does. **Submit** (⌘↩)
    files it as an issue in `asieke/BotChu` with `gh issue create`, titled from its first line or
    sentence (cut at a word, 72 characters at most), with its images after the text, and links the
    new issue; when gh fails, the report stays, with gh's reason. gh attaches the images itself
    (`--attach`, gh 2.99 or later, which needs write access to the repository), each as
    `image-<n>.png` from a private folder that goes afterwards; if one doesn't upload, the issue is
    made without it, and the sheet says so. The repository is public, so besides the images you add,
    the issue adds only the app state
    the sheet shows before it goes, as categories and counts: the version and commit, macOS, the
    screen and status sidebar area, the conversation's kind (Home, or a task on this Mac or a host
    and its kind of work), CLI family, starter model and effort, its turn's state (an error by kind
    only), message and queue counts, the window's size and appearance, and how many bots and turns
    there are. Conversations, instructions, memory, prompts, tool calls, error text, paths and the
    names of bots, tasks, accounts, hosts and repositories never go into it.
- Does not: run a bot's Home anywhere but this Mac, or tasks anywhere but this Mac and SSH hosts
  (no containers or cloud), schedule routines, ask for approval of tool calls (every CLI runs with
  its permission prompts bypassed, inside the bot's folder or the task's worktree), or keep any
  secret outside the Keychain and the CLIs' own logins.

## Architecture
- `macOS/` is a Swift package (Swift 6 toolchain, macOS 14+):
  - `Sources/BotChuCore/` — Foundation only, unit-tested: accounts and the command line each CLI
    runs with (`Accounts.swift`), generation choices and public OpenRouter model metadata
    (`GenerationOptions.swift`, `ModelCatalog.swift`), the bot and message model (`Models.swift`), the
    sections the sidebar groups bots into (`BotSections.swift`), one stream parser per
    CLI turning its JSON lines into chat events (`StreamParsers.swift`), what a tool call does and how
    the chat names it: read-only or not, files, folders, line ranges, diffs, failures and delegations
    (`ToolActivity.swift`, reading shell command lines with `ShellCommand.swift`), the chat's activity
    items, with exploration folded into groups and kept up to date at the tail
    (`ActivityTranscript.swift`), the identity, instructions,
    team playbook, memory and recap that open a session (`BotContext.swift`), the editable Markdown
    files of a bot and of every bot (`BotDocument.swift`), account allowance parsing and native queries
    (`ProviderUsage.swift`, `ProviderUsageClient.swift`) with a throttled in-memory cache
    (`UsageCache.swift`), per-conversation pending-message delivery (`MessageQueue.swift`), how tall
    the message box is for its draft and how far its text may scroll (`ComposerLayout.swift`), what
    the status sidebar shows about a bot, from a summary of its thread kept as the thread grows, and
    its `MEMORY.md` (`BotStatus.swift`), replies' parsed Markdown, cached by their text
    (`MarkdownCache.swift`), pets: the activity a tool call means
    and the clips that show it (`Pet.swift`), making a pet: its poses and clips, the Codex prompt
    for the stills, the OpenRouter request and job, the cost estimate, the manifest and install
    (`PetVideo.swift`), tasks: the task, its title
    and branch names, its pull request, receipts, dispatch requests and the briefs of tasks that fan
    out to sub-agents (`Tasks.swift`), hosts and
    where a repository is worked on, from a `PROJECT.md`'s deploy targets (`Hosts.swift`), running
    a command on this Mac or a host, the checkouts in the repositories folder, cloning, task and
    review worktrees, and what `gh` says about your repositories, issues and pull requests
    (`Repositories.swift`), preserving/validating project metadata (`ProjectRecord.swift`) and reading
    or proposing it through GitHub with retryable, metadata-only PRs (`ProjectGitHub.swift`), the Projects
    tables' rows, their status filter and the open pull requests and issues across repositories (`ProjectOverview.swift`),
    an issue or pull request in full as the project sidebar shows it (`WorkDetail.swift`), the JSON store (`Store.swift`), and the `Process` runner that launches
    a CLI through the login shell, `zsh -l`, or on a host over `ssh`, parsing its output off the
    main thread and delivering it in batches (`AgentRun.swift`). Delegation models, validation, persistence and the Python helper are in
    `Subagents.swift`, `Store.swift`, `SubagentArchive.swift` (transcripts saved off the main thread
    while they stream), `SubagentHook.swift` and `BotContext.swift`; `SubagentTransport.swift`
    handles isolated local and SSH mailboxes with bounded reads, timeout and cancellation.
    Reports filed from the app (their title, description, app state and `gh issue create`) are in
    `IssueReport.swift`.
  - `Sources/BotChu/` — the SwiftUI app, a standard `NavigationSplitView` window with an inspector,
    in standard system materials: `App/` (the app, window, model, each conversation's state, observed
    on its own (`Conversations.swift`), settings, Keychain, dev hooks, making
    pets and the OpenRouter video client, and where tasks work: your GitHub repositories and their
    computers, `TaskPlaces.swift`, and what a report says about the app, `IssueReports.swift`),
    `Sidebar/` (workspace destinations and bot conversations), `Library/` (Projects with its repository sidebar, Agents and Providers), `Chat/` (messages, the activity cards and their density, the shown part of the transcript, rich replies' web views and the pool that keeps them, and the composer, whose image-taking writing area the report and New Task sheets share), `Inspector/` (the
    status sidebar, a bot's and a task's), `Editor/` (the bot, Markdown, New Task and report sheets), `Settings/` (with
    the hosts), and
    `Shared/` (layout constants, the avatar, the status badge, the pet's looping video, and the
    providers' logos, drawn in code after GitChu's: the marks are their owners' trademarks, shown
    only to identify the CLI an account runs).
    `Resources/ChatRenderer/` bundles pinned Mermaid and KaTeX distributions, their fonts and licenses. Its README records provenance and update steps; no JavaScript package
    install or network access is needed at runtime. The rendering document blocks remote resources
    and model-supplied scripts, uses Mermaid's strict mode and disables trusted TeX commands.
  - `Sources/botchu-smoke/` — a command-line check, not shipped in the app, that runs two real
    turns on each account named the way the app does (see **Test**).
  - `Tests/BotChuCoreTests/` — parser tests against captured output of every CLI, command lines,
    context and store, and tasks: naming, dispatch requests, checkouts, `gh`'s output, and worktrees
    made in throwaway repositories, the project status filter, issues and pull requests read in
    full from `gh`'s output, and fan-out briefs; and hosts: their `ssh` command lines, deploy targets, clones,
    worktrees, reviews and turns on a host through a stand-in `ssh` that runs here, and notes kept
    from a remote task; reports: their titles, app state, and filing (with attached images) through a stand-in `gh`;
    output parsed off the main thread and delivered in batches, thread summaries, the Markdown cache
    and sub-agent checkpoints; and the chat's activity: how each CLI's tool calls (and shell
    commands) are described and grouped, failures, repeated reads, sub-agent cards, and that a
    streamed update regroups only the tail; the sidebar's sections of bots; and how tall the
    message box grows and how far its text scrolls.
  - `Tests/BotChuRenderingTests/` — actual WebKit math/diagram layout, streaming updates, source
    fallback and offline restrictions, web views made only near the visible chat, conversations and
    sub-agents streaming without invalidating other conversations' views, what quitting mid-turn
    saves, model-picker keyboard interaction and persisted choices, the message box's text staying
    put while it is typed (narrow and wide, past its maximum and back),
    Markdown editor sizing and Save/Cancel, collapsing status sections, the sidebar's sections of
    bots (their menus, the alert that names them, collapsing and revealing), inspector tab navigation and
    restored selection, conversation-scoped allowance reads, automatic task branch creation, the
    main window's layout at its narrowest, galleries that preserve conversation state, the project
    sidebar's tabs, details and fan-out tasks, custom profile persistence, provider logos in both
    appearances and in account menus, the report
    sheet, filing with a stand-in, images pasted with Edit ▸ Paste into the composer, the report
    and New Task (through a stand-in for the general pasteboard, so no test touches the clipboard)
    and what pastes as text instead, New Task starting a task from a project and a brief with an
    image, the activity chat at every density, light and dark and at its
    narrowest, a chat that follows new content only for a reader at the bottom, a Sub-agents
    tab that folds finished runs and scrolls to one the chat opens, and switching without a flash:
    the toolbar kept, the message box focused in the same update, the chat at its very end, pets
    that never blink out while a clip loads, rich replies shown only once rendered and shown
    again at once from those kept, within their budget, and typing dots that move. Set
    `BOTCHU_TEST_SNAPSHOTS=<temporary folder>` when running
    `swift test --package-path macOS --filter galleriesKeepConversationStateAndCustomProfilesPersist`
    (or `projectSidebarShowsTabsDetailsAndFanOutTasks`, or `activityChatRendersGroupsCardsAndLiveWork`)
    to render isolated gallery/table (sidebar, or chat) screenshots with sample data. These
    share a serialized suite because AppKit
    window focus is global; all use isolated windows and no real bot data.
  - `build.sh [outdir]` builds the release binary and wraps it into `{outdir}/BotChu.app` (default
    `macOS/build/`), signed with the local "Apple Development" certificate when there is one, ad hoc
    otherwise. It records the SDK the app was linked against in the binary (`vtool`), because
    SwiftPM's default build system records the deployment target there instead, and macOS then
    runs the app with the old window design, whose toolbar overhangs the sidebar. It also records the commit it
    was built from (`BotChuCommit` in Info.plist, `-dirty` with uncommitted changes), which reports name. `install.sh` builds into `~/Applications`, restarts BotChu if it was running, and
    smoke-tests that it starts; it goes by the installed copy's path, so review copies and builds run
    from a checkout are neither counted nor quit. `test.sh` runs the unit tests. `ui-review.sh` opens a build on
    throwaway data for checking its screens (see **Test**).
- Data: each bot's `.botchu/` folder in its workspace (above), and `index.json` in
  `~/Library/Application Support/BotChu/`, which only lists the bots' workspaces in sidebar order,
  with the section each is in.
  Versions before bot folders kept everything in `bots.json` and `threads/` there; the first launch
  moves them into the bots' folders and keeps the old files in `backup-before-bot-folders/`.
  Project metadata stays in each repository’s `PROJECT.md` on GitHub; its fetched catalog is cached
  in memory. Settings, with added CLI profiles, the hosts and where you chose to work on repositories, are in the `defaults` domain
  `local.BotChu`; the OpenRouter key is in the Keychain (service `local.BotChu`). Bot workspaces are
  under `~/BotChu/` by default; tasks run in worktrees of checkouts on this Mac or on a host. No
  database and no port.
- Each turn runs one headless CLI process in the bot's folder, or a task's worktree. On a host,
  BotChu runs it as `ssh -T <host> 'cd <worktree> && exec "${SHELL:-/bin/sh}" -lc …'`, with
  `BatchMode` (no password prompts) and one shared connection per host (`~/.ssh/botchu-*`):
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
- `macOS/test.sh` requires every test bundle to finish and rejects explicit failure summaries,
  even if SwiftPM returns success. The native-click sidebar test runs in its own process because
  AppKit's window-animation callbacks can stop the Swift test runner's event loop during later
  tests; all its assertions still run. The script also runs the project-loading regression tests in Release. They check every
  repository result, the four-request limit, and completion of children when navigating away or
  cancelling a load. Swift 6.4 has an [optimizer bug](https://github.com/swiftlang/swift/issues/93208)
  in task-group children returning String-first tuples from `do`/`catch`; project and pet loading
  use named results with one return to avoid it. Debug tests alone cannot detect this regression.
- Accounts end to end: `swift run --package-path macOS botchu-smoke [account id …]` runs, for each
  account (all of them when none is named), a new session that opens with the bot's context and
  runs a shell command, then a resumed session that must recall a code word from the first, and
  prints both threads. It spends the accounts' own allowance, so it is not part of `check`;
  OpenRouter needs `OPENROUTER_API_KEY` in its environment. To exercise explicit generation
  settings, prefix the command with `BOTCHU_SMOKE_EFFORT=low` and optionally
  `BOTCHU_SMOKE_MODEL=<model id>`; both settings apply to the new and resumed turns.
  To test image delivery, set `BOTCHU_SMOKE_IMAGE=/absolute/path/to/fixture.png` and optionally
  `BOTCHU_SMOKE_IMAGE_EXPECT=<word visible in the image>`; both turns attach the fixture and must
  read that word as well as recall the session's code word.
- Screens: `macOS/ui-review.sh ["message"]` builds the app into a temporary folder and opens it on
  throwaway data (`BOTCHU_DATA_DIR`, with its own settings domain, `local.BotChu.dev`) with two demo
  bots in the old layout, so every run also exercises the migration into bot folders, the first
  with a short sample conversation and memory and two tasks in a throwaway repository (with a local
  origin, so nothing reaches GitHub), optionally sending it a message (a real turn on
  Claude Dev); the app writes a PNG of each of its windows into the printed folder every second
  (`BOTCHU_SNAPSHOT`), so screens can be checked without screen-recording permission.
  `BOTCHU_OPEN=editor`, `BOTCHU_OPEN=task` or `BOTCHU_OPEN=settings` opens the bot editor, New
  Task or Settings instead (`BOTCHU_TASK_REPO=<owner/name>` picks New Task's repository).
  `BOTCHU_OPEN=projects`, `agents` or `providers` opens the corresponding workspace gallery;
  with `projects`, `BOTCHU_PROJECT=<owner/name>` shows that repository's sidebar, and
  `BOTCHU_PROJECT_TAB=issues` (or `pulls`, `overview`) with `BOTCHU_PROJECT_ITEM=<number>` opens a
  tab and an issue or pull request there, read with your `gh` login.
  `BOTCHU_OPEN=memory` or `soul` opens the selected bot's Markdown editor.
  `BOTCHU_SECTION=<name>` moves the first bot into a sidebar section of that name.
  `BOTCHU_TAB=<n>` shows the first bot's nth conversation (and the message goes there), and
  `BOTCHU_TASK="hello-world|<task>"` starts a task in the throwaway repository (a real turn).
  Hosts: `BOTCHU_HOST="<nickname>|<ssh host>|<repositories folder>|<machine>|<account>=<command>,…"`
  (several separated by `;`) sets Settings ▸ Hosts, and `BOTCHU_TASK="<owner/name>|<task>|<nickname>"`
  starts a task there, cloning the repository into that folder: a real turn on a real host.
  `BOTCHU_FAKE_HOST=1` adds a host, "Far Mac", whose `ssh` is a stand-in that runs the command here
  (`BOTCHU_SSH`), with a clone of the throwaway repository in its folder, so
  `BOTCHU_TASK="hello-world|<task>|Far Mac"` exercises a task on a host without one (a real turn
  here).
  `BOTCHU_PET=<pet folder>` gives the first bot that pet (`video.json`, `stills/`, `clips/`), and
  `BOTCHU_DRAW_PET="<appearance>"` makes it one (a real Codex run and real OpenRouter clips, which
  cost credit). The window's picture leaves out the sidebar's rows and background, and video layers,
  so the rows are drawn on their own, on the sidebar's background, into `sidebar.png`, each pet's
  current frame is drawn into its circle, and
  `pets.txt` lists each pet player's clip, state and time.
  `BOTCHU_APPEARANCE=dark` (or `light`) reviews that appearance without changing the system setting.
  `BOTCHU_USAGE=sample` (or `stale`, `expired`, `unavailable`) reviews allowance states without
  querying any account. Usage fixtures are ignored outside throwaway data runs.
  `BOTCHU_ACCOUNT`, `BOTCHU_MODEL` and `BOTCHU_EFFORT` set the first demo bot's generation choices;
  `BOTCHU_DEFAULT_MODEL` supplies an isolated OpenRouter default. `BOTCHU_OPEN=model` or `effort`
  opens the composer's picker, and `inspector-model` or `inspector-effort` opens the sidebar's.
  `BOTCHU_INSPECTOR=activity`, `subagents`, `model`, `session` or `memory` selects a status sidebar tab;
  `inspector-model` and `inspector-effort` also select Model & Usage before opening the picker.
  `BOTCHU_WINDOW=compact` checks the minimum window width. `BOTCHU_DRAFT=<text>` puts that draft in
  the message box (`\n` for a new line), to check how it grows and scrolls.
  `BOTCHU_OPEN=report` opens Report a Bug or Feature, and `BOTCHU_REPORT="<report>"` files one at
  launch. A review copy files reports only with a stand-in `gh`, which keeps them (and the images it
  attaches) in `reports/` in
  its data folder and prints a made-up issue's link (with `BOTCHU_REPORT_FAIL=1`, it fails as a
  signed-out gh does), so no review creates a real issue.
  `BOTCHU_DEMO=activity` makes the shown conversation a long agent run, in memory (exploration with
  failures, a build, an edit, three sub-agents and a live group), and `BOTCHU_DENSITY=compact` (or
  `detailed`, `raw`) chooses the chat density for the run.
- Chat latency: `BOTCHU_BENCHMARK=<file> swift test --configuration release --package-path macOS
  --filter chatBenchmark` times, from the change until the window has drawn it, switching to long
  conversations (1,500 messages; outputs of 200 KB to 1 MB; a 400-call exploration; seventeen running
  sub-agents), a streamed delta, a new call in a live exploration, a sub-agent's update, and opening
  a large group or output, and writes the table to the file. `BOTCHU_BENCHMARK_SCOPE=chat` times the
  chat column without the sidebars. It asserts nothing about time, which varies with load, and isn't
  part of `check`. The targets, for a release build: switching under 150 ms, a streamed delta or
  new call within a frame (16 ms), opening a group under 100 ms.
- Account allowance end to end: `swift run --package-path macOS botchu-smoke --usage [account id …]`
  reads each account's usage through the same client as the inspector. It prints only the normalized
  usage fields, never raw CLI output or credentials. Muse makes its brief usage request; OpenRouter
  needs `OPENROUTER_API_KEY` in the environment. This is separate from the two-turn conversation smoke.
- Smoke test after deploy: `macOS/install.sh` fails unless the installed app starts (launched hidden,
  found by its executable's path in `ps`, so a review copy running meanwhile doesn't count, and
  quit again unless it was already open).

## Deploy
- **Host machine:** `Alexs-MacBook-Pro-92440`. The live checkout is `~/Desktop/WORKSPACE/BotChu`, which always stays on `main`; the app is installed to `~/Applications/BotChu.app`.
- **Secrets:** None in the repository or `.env`. The OpenRouter key lives in the Keychain, entered in Settings.
- **Deploy only on request:** `scripts/deploy.sh` sets `DEPLOY_ON_REQUEST=1`, because installing restarts BotChu and stops any bot mid-turn. A full `scripts/sync.sh` fetches and reports how far `origin/main` is ahead of what is live, and changes nothing; run `scripts/deploy.sh` in the live checkout to test and install `main` (`--force` reinstalls anyway). Every attempt is a line in `.git/deploys`.
- **Sync first:** run `scripts/sync.sh` before running or restarting the app or using its live data, and after merging a pull request. It refuses if `~/Desktop/WORKSPACE/BotChu` has local edits or commits not on `origin/main`; fix those through a pull request. Unless it refuses, it then removes worktrees whose pull request merged. Run from a worktree, it removes them too, but does not deploy.
- **Session start:** Claude Code runs `scripts/sync.sh --inspect`, and every other agent runs it first. It fetches and reports the live checkout's state and what a full sync would do, but deploys nothing, so a session that only reviews or inspects never touches the app. A full sync that refuses blocks live-app operations, not reviews.
- **Scheduled jobs:** none.
- **Branch work:** Every task runs in its own worktree: for example, `scripts/worktree.sh feat/12-add-login` creates `~/Desktop/WORKSPACE/BotChu/.claude/worktrees/feat-12-add-login` from `origin/main`, with `.env` linked. Never edit `~/Desktop/WORKSPACE/BotChu` directly; changes only reach the live app by merging a pull request to `main` and deploying.
