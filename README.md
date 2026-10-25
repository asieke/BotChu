# BotChu

A minimal, open-source, native macOS app for persistent AI bots, in the spirit of Grok Bot and
[rakazo](https://github.com/elie222/rakazo). Bots are listed down the left; the selected bot's chat
fills the window. Each bot is driven by a coding-agent CLI that is already installed and signed in on
the Mac, and runs in its own workspace folder on this Mac. A bot can also work on tasks in your
GitHub repositories, in parallel, each in its own git worktree and nested under its bot in the left
sidebar: on this Mac, or on another computer it reaches over SSH. A task can also review a pull request.

## Scope
- Does:
  - **Workspace:** the left sidebar has **Projects**, **Agents**, **Providers**, **Skills** and **Jobs**, followed by
    the bots’ conversations, in sections (below). Opening a gallery keeps the selected conversation and unsent draft;
    turns that finish while a gallery is shown still get an unread badge. In dark mode the sidebar
    takes the status sidebar's darker shade, with a hairline along its edge, so it stands apart from
    the chat; light mode keeps the standard sidebar.
  - **Sections:** bots can be grouped into sections you name, each a heading of its own in the
    sidebar and in **Agents**, which edits the same sections (below). A bot's **Move to Section** menu lists Conversations (no section) and the sections,
    with its own checked, and **New Section…**, which names a section and moves the bot into it;
    a moved bot goes last in its section. Bots in no section, new bots among them, come first,
    under Conversations, so a sidebar without sections looks as before. A section heading's menu
    renames it (another section's name merges the two), moves it up or down, or removes it, which
    returns its bots to Conversations and deletes nothing. Names are trimmed and matched whatever
    their case, and no section can be called Conversations. Headings collapse, and stay collapsed
    across launches, but what is selected from elsewhere (Agents, a new bot or task, ⌃Tab) shows
    in its section.
    Sections are kept in `index.json` with the sidebar's order, so a bot whose folder is missing
    comes back in its section. When `index.json` can't be saved (a full disk, a folder without
    write access), the change still shows, and a banner above **New Bot** (and in Agents) says it isn't saved,
    which file and why; this goes for new, moved and deleted bots too. **Try Again**, the next
    change, or quitting BotChu saves the whole sidebar as it is then, each bot once, with the
    missing bots' entries; the banner goes once it saves.
  - **Projects:** one project per non-archived GitHub repository returned by `gh` for your account
    and organizations, in a sortable table modeled on GitChu's (or a gallery of cards). Columns show
    where it deploys (local machines by their BotChu name, Vercel, registry), the owner, open issues
    and pull requests, last push, type, merge policy, the computer its tasks work on (with whether
    the checkout exists on this Mac), and the bots' open tasks there; columns can be hidden,
    reordered and resized, and that is remembered. Cards show the description and visibility
    from GitHub, and the name, type and status from `PROJECT.md` on the default branch. **Docs** is
    non-code; **Library**, **Local app**, and **Hosted app** are code. Unclassified repositories can
    get a minimal project record.
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
    on it. They are read with one GraphQL query per ten repositories whose open work changed (below).
  - **Saved and synced:** the repositories, their `PROJECT.md`, and the open pull requests and
    issues with GitHub's counts are kept on this Mac (`projects.json`) for the account `gh` is signed
    in to, with when they were last synced, so Projects, New Task and Home's task requests have them
    at once after a relaunch, and a sync goes on behind them, after GitChu's: at launch and when
    Projects opens, if what was saved is over two minutes old; every two minutes while Projects
    shows; and with **Refresh**. A sync asks who is signed in and for GitHub's repository list with
    the ETags from last time, and probes each repository with anything open (its most recently
    updated issue or pull request), which cost nothing when nothing changed; it then reads only the
    `PROJECT.md` of a repository pushed to since, and the open work of one whose list entry or probe
    moved or whose pull request's checks are running, four and two requests at a time, and shows
    each answer as it arrives. Refresh, and a sync over half an hour after the last such one, also
    read the list afresh, so a repository that is gone goes (once GitHub confirms it), and try again
    what failed. Refresh is never disabled: asked for during a sync, it runs once that ends, however
    often. The header says when it was last synced. A sync that fails (offline, signed out, a GitHub
    error) or reads only part keeps what it has and says why; it never empties the list. When `gh` is
    signed in to another account, the saved catalog goes and that account's is read; a missing or
    unreadable file starts empty.
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
    on this Mac, wherever the project deploys.
  - **Project metadata:** **Edit Metadata…** edits the name, type, status, deployment, and merge
    policy in `PROJECT.md`. **Create Metadata PR** uses `gh api` to create a documentation branch,
    commit only that file, and open a PR; it never clones the repo or runs its test suite. Repository
    checks and merge requirements still apply. Other frontmatter and the Markdown body are preserved;
    ambiguous YAML and a file changed since editing began are refused. Interrupted saves can retry
    the same branch without duplicate commits or PRs. The project and task placement update only
    after the metadata PR merges and a sync reads the default branch again. BotChu needs write
    access for this flow; forks can be used through GitHub. The editor creates no commits directly
    on the default branch and never merges metadata PRs.
  - **Agents:** a gallery of the existing bots, grouped under the sidebar's sections, in its order,
    with Conversations ("Not in a section") first while any bot is in none, showing their
    personality summary, provider, activity and task count, with **Open Chat**, **Edit…** and
    **New Agent**. Sections are edited here with the sidebar's own menus: a card's folder button, or
    a right click on it, moves its bot to a section, back to Conversations, or into a **New
    Section…** it names; a heading's ⋯ button, or a right click on it, renames, moves or removes its
    section. A change in either place shows in both and is saved in `index.json`. Search finds
    bots by name, title or provider, within their sections, and a section, Conversations among
    them, by its name, with all its bots. A bot’s own conversation continues to work without a
    project.
  - **Providers:** one compact table of CLI profiles, a row each, under 100 points high whatever
    its state: the logo, name and CLI family; the command, and whether the login shell finds it;
    a line per allowance window, with its use and reset (the reset when the column has room, and
    at most four lines, the rest in the tooltip), whose bars, percentages and resets line up from
    row to row; when it was read, marked stale or failed (with
    the error in a tooltip and a popover); and Refresh. It shares the conversation inspector's
    allowance cache and refresh limits, and searches by name or family. **Add CLI**
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
    is parsed once, and recent ones ahead of time, so showing a conversation again doesn't parse it again; parsed replies are
    kept within about 64 MB, and none once macOS reports memory pressure); the
    agent's tool work shows as activity (below). A reply being written is parsed off the main thread, two replies at a time
    across every conversation and only the newest revision of each, so a long reply never holds up typing, switching or
    Stop: its last rendering shows meanwhile, and once the reply is over 16 KB the text written since shows as it is until
    the rendering catches up. A reply of 256 blocks or more is laid out in chunks of 128, each apart from the rest of
    the chat and only at the width it is shown at, so typing, another row or the next delta doesn't lay out the chunks
    already written again. Headings, nested lists, quotes,
    tables and fenced code use native block layouts; code has a Copy button. A table's cells stay on
    one line, each row ruled straight across whatever its cells hold (empty, or inline code), and a
    table wider than the chat scrolls sideways. Replies have soft rounded
    bubbles. Inline and display math use bundled KaTeX; Mermaid code fences display diagrams with
    source/copy and fit/actual-size controls. Both render offline in system WebKit, including inside
    tables and lists; a reply's web view is made as it nears the visible part of the chat, with only
    the renderer it uses, and shows once the reply has rendered, at its final height, so neither a
    blank page nor the source flashes first. It renders one revision of its reply at a time (the
    newest written meanwhile follows), keeping the blocks that haven't changed, with their math and
    diagrams. Rendered replies' web views are kept, hidden, when
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
    lay out quickly, with **Show earlier** above them. However many earlier pages are open and items
    arrive meanwhile, the chat lays out only the rows near what is visible: those within three
    quarters of its height (at least 400 points) above and below it, at most 160 unless the visible
    part itself holds more. A message, a card or a folded group is a row; an opened group is its
    header, a row per call and its failures, every call there to scroll to (no page of them to ask
    for), and in Raw every call is a row. The rest is space as tall as its rows were measured at, or
    estimated, each height kept with what its row showed (its text's length, a group's revision, a
    call's state and output, whether it is opened) and the width, density and appearance, so it is
    used only for the same; a call's opened details stay open as its row goes and comes back. A
    reader paused in earlier content keeps their place by the row they read and how far into it,
    while rows above it are measured, render math or a diagram late, or reflow at another width, as
    earlier items go in above it, and after memory pressure. As a turn streams in, only what it changed is
    grouped again: a new call joins a live group, and one that finishes is taken out of the group's
    summary and put back, so a call costs the same in an exploration of 5,000 calls as in one of 5,
    and so do its sub-agents' card placement and tool counts. A conversation shown again keeps its
    grouping and opened cards; a long one opened anew shows its newest items at once, with a spinner
    where earlier ones go while they are grouped off the main thread. A reader at the bottom follows
    new content; one reading earlier content keeps their place while a turn goes on, and **Follow
    Live** takes them back.
  - **Tasks:** besides its Home, a bot can work on tasks, several at once: each in one of your
    GitHub repositories, with its own conversation and CLI session, in its own git worktree, so
    tasks never share files. BotChu does all of this itself, with no other app. **New Task** (⌘T)
    asks only for the repository (from the ones `gh` lists for your account and your organizations,
    newest push first) and what to do, in one box that takes images as the message box does; they
    go with the task's first message, and ⌘↩ starts it. Opened from Projects for an issue or pull
    request, it works on that, and the box adds to it. The task runs on its bot's account (change
    it in the status sidebar), and BotChu names and manages branches automatically. A repository
    is worked on where you chose for it (Settings lists those choices), else in the repositories
    folder on this Mac (`~/Desktop/WORKSPACE` by default), whatever its `PROJECT.md` deploys: a
    host's live checkout is for running the app, not for work. BotChu clones it there if it isn't
    yet (`gh repo clone`, or `git clone` over HTTPS). BotChu makes the worktree before the first
    turn, in `.claude/worktrees/<type>-<slug>` of the checkout, with git, from origin's default
    branch, and links the main checkout's `.env` files into it; a new `<type>/<number>-<slug>`
    branch is first made on GitHub linked to its issue (`gh issue develop`) when `gh` is there. A
    pull request's task works on the pull request's branch. An issue, pull request or branch has at most one open task
    (BotChu refuses a second), and a branch named from a brief gets a number when the name is
    taken, so tasks never share a worktree. The main checkout stays on its branch, and BotChu writes
    nothing into the repository: a task's first message opens with the bot's identity, instructions
    and memory (which stays in the bot's folder), where the task is and what it is. Open tasks nest below their bot's row in the left sidebar
    (⌃Tab moves between Home and its open tasks). Each row shows activity, elapsed time while running, failure or unread state;
    the bot row counts running tasks. Only a bot with open tasks has a disclosure arrow, which expands
    without changing the conversation; a bot without any is a single row, whose first task comes from
    **New Task** (⌘T or the row's menu). The bot row opens Home, and **+ New task** after its tasks
    starts another. Task context menus keep workspace,
    browser, new-session and close actions. Closing a task keeps its record, conversation and worktree;
    Home's status lists closed tasks to open again. Once its pull request merges, the agent removes
    its worktree (`git worktree remove`); if it is gone, the task's next message makes it again.
  - **Pull request reviews:** a pull request's menu in Projects ▸ Pull Requests, or its **Review** in
    the project sidebar, can also **Review with** or **Review and Comment with** a bot, opening New
    Task for that review. The review works
    in a temporary worktree detached at the pull request's head (also
    from a fork), records that commit, and reviews it against its merge base: the first
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
    notes the bot writes in `<remember>…</remember>` in a reply are saved to its `MEMORY.md` here,
    as from every conversation (see **Saving memory**).
    The status sidebar names the computer, and **Terminal** opens a shell in the
    worktree there. The OpenRouter key never leaves this Mac, so Pi on a host needs that host's own
    `OPENROUTER_API_KEY`.
  - **Home coordinates:** a bot asks for a task itself by writing a JSON request into
    `.botchu/dispatch/` in its folder (`{"repo": "owner/name", "issue": 48, "task": "…"}`, or
    `"review": 12` with `"comment": true` to post it, and `"machine"` for a host), as its
    `AGENTS.md` explains. While any turn runs, of any bot, BotChu takes requests within seconds,
    whichever conversation wrote them, and starts each in its own sidebar row; `"agent"` hands the
    task to another bot (below). Home gets a receipt when a task starts, ends a turn or fails (with an Open
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
  - **Tasks for other bots:** a conversation hands work to another bot in one of two ways, each
    with its own command, and an `@bot` mention only names the bot. "New task @bot" (or "hand this
    off to @bot as a new task") makes a **Task**: `botchu-task create --agent <bot> --repo
    owner/name --brief …` (or `--issue`, `--pr`, `--review`, with `--title` and `--machine`), from
    Home, a task (also on a host) or a sub-agent run. The Task is the named bot's own, in the left
    sidebar under it, on its account, model and effort, in its own worktree, as if its Home had
    asked, and goes on after the asking turn ends or stops; nothing reaches that bot's Home but the
    usual receipts. It records which conversation asked (shown to the bot in its first message).
    The asking conversation gets a receipt that opens the Task, and the command prints the bot, the
    Task and whether it was created, its first turn started, or why not: pending, created, started,
    start failed, or failed (with nothing made, so it can be run again). The same command run again
    from the same conversation, also in a later turn or after a relaunch, returns the same Task
    rather than a second. "New subagent @bot" (or "delegate this to @bot as a sub-agent") is a
    **sub-agent run** (above): child work of the turn, in its Sub-agents inspector, with no sidebar
    row. A batch goes to one bot as one Task, whose turn spawns a sub-agent run per issue.
  - **Jobs:** an agent can own scheduled jobs, saved instructions it runs on a schedule, such as a
    morning issue triage on weekdays at 9:00. **Jobs** in the sidebar is one table of every agent's
    jobs: the job, its agent, its schedule and time zone, its next run, its state (on, paused,
    waiting or running) and how its last run went, filtered by agent, by state or by search. A row's
    menu runs it now (also a paused job, which stays paused), pauses or resumes it, stops its run
    (which leaves its schedule alone), edits or deletes it, or opens its history (also a
    double-click): its runs, newest first, each with the time it was for and the time it started,
    how late that was, how long it took, what it ran on and its transcript, live while it runs.
    Opening Jobs or a history never runs anything. An agent's card in **Agents** counts its jobs
    (opening Jobs filtered to it) and its menu has **New Job…**; its status sidebar's **Activity**
    lists them under its tasks, with **New Job…** and **All Jobs**. The editor sets the agent (chosen
    already from an agent's own places, and fixed once the job exists), title, instructions, how often
    it runs (every day, weekdays or chosen days at a time; every so many minutes, from 5, or hours,
    from a start time), its time zone (the Mac's at first, shown with the job everywhere), missed
    times, the time limit and whether it is on, with the schedule in words and its next three times.
    BotChu runs jobs itself, only while it is open and the Mac is awake: there is no background
    helper or login item, and Jobs says so. It looks for due jobs every 20 seconds, when the Mac
    wakes and when the clock changes. A job keeps its own time zone, so travelling or changing the
    Mac's never moves it; a time a daylight-saving change skips runs when the clock jumps, a time it
    repeats runs once, and every so many minutes or hours counts true durations from the start time.
    **Run once if missed** (the default) runs once for the latest time missed while BotChu was closed
    or the Mac asleep, if that was within its catch-up window (seven days unless set shorter), and
    tells the agent when the run was meant for and how late it is; **Skip missed runs** records them
    skipped. Earlier missed times are never made up, nor are times while a job was paused, or before
    its schedule changed. Each run is a fresh CLI session of its agent's, with its identity,
    instructions, team playbook, personality, memory and skills, then the job's instructions, but not
    its Home conversation, on the agent's account, model and effort (recorded with the run), in its
    workspace; it never resumes Home's session or touches Home's queue, draft or receipts, and gets
    nothing written to it while it runs. A job never overlaps itself (a time due while its run waits
    or runs is recorded skipped, once however many); one agent's runs go one at a time, and wait
    (**Waiting**) for its Home turn or a sub-agent in its workspace to finish; at most two run at
    once. A run is stopped at its time limit (30 minutes by default) and counts as failed; three
    failed runs in a row pause the job, saying why. BotChu never runs one again on its own. A run
    asks for repository work as Home does, with a task request (which names the job), and BotChu
    starts the task when the run ends. Every run is kept, with how it was started (on schedule,
    caught up, or Run Now) and how it went: succeeded, nothing to report, failed (with what to do:
    sign in, wait for the allowance, fix the command, check the network or the disk), stopped,
    skipped or interrupted, and a line about it; the history keeps the latest 50 and always the last
    success. A run whose reply ends with `NOTHING_TO_REPORT` stays in the history only. A finding, a
    failure or an interrupted run adds one receipt to its agent's Home, with **Open Run**, marked as
    news, which Home's next turn hears of; an empty reply counts as failed, not quiet. Before a run
    starts, its time is reserved in the job's `job.json`, in one save, so a timer, a wake or a
    relaunch never starts it twice; when that save fails, nothing starts and the job says why. After
    a quit or a crash, a run that was running is recorded interrupted (it may have done part of its
    work) and isn't run again. Jobs are kept in their agent's folder, so they move with its
    workspace and stay its own when it is renamed; deleting the agent deletes them, as its
    confirmation says, and a job whose folder has gone doesn't run.
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
    `queued.paused` while paused). A follow-up the CLI has taken stays saved beside them, in
    `taken.jsonl`, until the conversation is saved with it: when the conversation can't be saved (a
    full disk, a folder without write access), the chat says which file and why, the pending
    messages pause, and the next launch puts that follow-up back into the conversation rather than
    sending it again. A worktree being prepared finishes setup before follow-ups can run. A message
    shows in the queue as soon as it is sent and goes to the bot once its queue is saved; when that
    can't be saved, it goes back into the message box, before anything typed since, and the chat says
    why. Its turn starts only once the saved conversation holds it; when that can't be saved, it stays
    queued, paused, and the chat says so. Until then the conversation is busy, and Stop withdraws it.
  - **Mentions:** in a Home or task message box, `@` lists your other agents and `#` your projects,
    in a short list just above the line being typed, over the chat, so the box neither moves nor
    grows. Agents match by name or title, in the sidebar's order, with their avatar and title (and
    the start of their ID beside a namesake); projects match by name or `owner/name`, from the whole
    saved Projects catalog whatever Projects' search and filter show, with the task's own repository
    and active projects first. Exact and prefix matches come first. Up and Down choose, Return or Tab
    inserts the chosen one, a click inserts it, and Escape closes the list and leaves the text; Return
    that inserts never sends, and with no list Return sends as before. Only typing opens the list:
    email addresses, URLs and their fragments, Markdown headings, issue numbers such as `#123` and
    pasted text don't, nor does an input method's composition. A chosen agent reads `@QA Duck` and a
    project `#asieke/BotChu`, in the accent color on a faint tint, linked to the agent's ID or the
    repository: renaming the agent keeps the link, and editing inside the label turns it back into
    plain text (undo brings the link back). Copying gives readable text, and pasting it into a message
    box keeps its links. A message keeps its links in the queue, its saved thread and across
    relaunches, and when it is sent (in a new session, a resumed one, or as a follow-up mid-turn) its
    bot is told what each points at, once each: an agent's name, title and ID, so it can delegate to
    it with `botchu-subagent` when the message asks, and never its memory, instructions or
    conversations; a repository's URL, project name and where its tasks work. A mention starts,
    switches, clones and sends nothing. A link to a deleted agent, or to a project the current GitHub
    account's catalog doesn't list, is never moved to another: the box shows it dotted, says why,
    and offers **Unlink** and **Refresh Projects**. Without a saved catalog, `#` offers **Load
    Projects**; a saved one stays searchable and says when it was synced. Suggestions come from what
    is saved, never from GitHub while you type. The report and New Task sheets have no completion.
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
    unspecified model as the account's default.
    Models are shown by their full name and version (Claude Opus 5.5, GPT-6.1 Sol, Muse Spark 1.3) in
    the picker, the composer, the **Runs on** card, Edit Bot and sub-agent cards. A version shows only
    when the ID pins one or the CLI has reported the model it ran: Claude Code offers each moving
    alias (**Claude Opus · latest**, `opus`) beside the version it resolved to when checked
    (**Claude Opus 5.5**, `claude-opus-5-5`), and once a turn has run, the alias or account default
    reads as what ran (**Claude Opus 5.5 · latest**, **Claude Opus 5.5 · default**). Claude Code
    reports the model that wrote its replies and Muse the one its usage counted; until a turn
    reports one, and always for Codex and Antigravity, the version shows as unresolved. The report
    is kept with the conversation for the account and choice it was made for, so changing either
    shows it unresolved again; a label never changes which model a turn asks for. **Auto** effort
    leaves the choice to the account; explicit levels include short explanations, and unsupported
    effort controls are disabled.
    Search supports arrow keys and Return; Escape dismisses a picker. Controls wait until the shown
    conversation's turn ends. The card's **Account** selector changes the account for Home or a task,
    including custom CLI profiles; the next message starts a session on that account. Other tasks
    keep their accounts. Switching CLI families resets model and effort choices. For known
    Antigravity models, effort also selects the matching model-ID suffix.
  - **The bot's folder is the bot:** BotChu keeps each bot's settings (`bot.json`), its whole
    conversation (`thread.jsonl`, one message per line, with its index beside it,
    `thread.index.json`: see **Loading**), its tasks (`tasks/<id>/`: `task.json` with
    the repository, computer, branch, worktree, session and pull request, and the task's
    `thread.jsonl` and index), the
    task requests it writes (`dispatch/`), its scheduled jobs (`jobs/<id>/`: `job.json` with the
    job, where its schedule is up to and its runs, and each run's transcript in `runs/<run>.jsonl`),
    a log of every turn and job run (`logs/<date>.log`:
    the command, where it ran, how long it took, the exit status, any error and the CLI's error output), notes
    it couldn't save to memory yet (`memory-unsaved.json`, `shared-memory-unsaved.json`), the reviews of its runs (`evaluations/`, below) and its
    pet (`pet/`: `video.json`, `stills/<pose>.png`, `clips/<activity>.mp4` and the appearance it
    was made from) in `.botchu/` inside its workspace, with a `.gitignore` so a repository never commits them. The bot
    is told it can search them for earlier conversations. **History & Logs** in the status sidebar
    opens the folder. An entry BotChu can't read in a conversation's file (a line that isn't JSON,
    or a message this version doesn't know, such as one with a newer role) is never lost when the
    conversation is next saved, nor is a file it can't read at all: BotChu first keeps the original,
    unchanged, beside it as `<name>.unreadable-<time>.jsonl` (moving a file it can't read there),
    and the conversation says, in a note, how many entries it left out and where the original is.
    This holds for Home's, tasks' and sub-agents' threads and for pending messages, including those
    the bot took before the conversation could be saved, whose note goes in their conversation; a
    missing or empty file is just an empty conversation. Each bot needs
    its own workspace, and not the bots folder itself; moving a bot's workspace in its editor moves its `.botchu/`, `INSTRUCTIONS.md`, `MEMORY.md`, `SOUL.md` and `skills/` with it. Moving
    waits until its turns finish and refuses to overwrite files at the destination. Deleting a bot
    puts only its `.botchu/` in the Trash.
  - **Saving:** conversations and their queues, bots' and tasks' settings, the turn log, memory
    notes, sub-agents' and jobs' transcripts and run reviews' records are written off the main
    thread, so typing, switching conversations and Stop never wait for the disk, however long a
    conversation is. Each file's writes keep the order they were asked in, and different
    conversations' go side by side. A file is written whole, and a newer state of it takes the place
    of one not written yet (one already written isn't written again), so a late save never overwrites
    a newer one and at most two states of a file are held at once, one being written and one waiting.
    A conversation's change is on disk once the write under way and its own are done (about 10 ms for
    1,500 messages, 35 to 40 ms for 5,000 or for 12 MB of tool output, on an M4 Max); a streaming
    sub-agent's within a second, a job run's within five. A turn's end, what it asked to remember and
    its review's hand-over happen off the main thread too; the conversation stays busy until its end
    is saved. Quitting waits up to five seconds for what is being written and lists any file it
    couldn't finish in the system log, leaving it as it was last saved, never taken as saved.
    Deleting a bot drops what waits to be written in its folder and waits for what is being written;
    moving one waits for its writes, so neither leaves the old folder behind. A job's run is still
    reserved in its `job.json` before it starts, at once, and never twice.
  - **Loading:** a launch reads the bots' and tasks' settings and puts the window up; conversations
    are read when they are needed, off the main thread, in order with their writes. Each Home's and
    open task's queue is recovered first: its transcript is read then only when messages wait in it
    (or the CLI took one the transcript lacks), and what waits goes out once its own conversation is
    recovered, never before, even when it is never opened. The conversation shown is read first;
    another is read when it is shown, with a spinner where its messages go (never an empty
    conversation), while typing and switching go on. Sidebar rows and Home's reports on its tasks
    come from each conversation's index (`thread.index.json`): its counts, last activity and error,
    and the start of its last reply, with the size, dates and inode of the transcript it was made from
    and a hash of its end and of all of it. A transcript changed since, by BotChu or anything else,
    even to the same size with its dates kept, is never described by an old index: it is read again,
    and its index made again; a missing one (a folder from before) is made in the background, one
    conversation at a time. What changes a conversation not read yet (a task's or job's receipt, a
    note, a Telegram message, which is checked against its whole history) or its queue before its
    recovery (a send, Stop, an edit of the queue) waits until it is, in the order asked, so nothing is
    lost, sent twice or saved over the full transcript, and a read that ends after its bot was deleted
    or moved, or after a newer read, is dropped (a moved one is read again where it is). Stop
    withdraws a turn waiting for its conversation to be read. A closed task's history and queue are
    read when it opens again, and only then does what waits in it go out. Finished sub-agents'
    transcripts are read when something shows them (a handoff goes back from its run's record); one a
    relaunch interrupted is read, then closed, once. Inactive conversations' histories beyond 48 MB,
    and finished sub-agents' transcripts beyond 16 MB, leave memory, the least recently shown first,
    never the one shown, one with a turn or a sub-agent under way, or one not saved; drafts, queues,
    sessions and summaries stay, and the history is read again when it is shown. The replies parsed
    ahead are the shown conversation's latest 60, up to 256 KB of them. This Mac's name (`scutil`) is
    looked up off the main thread, and a task request naming this Mac waits for it. With eight bots,
    forty open tasks and a hundred finished sub-agents (101 MB) on an M4 Max, the window is up in
    about 220 ms (it was 800) and the shown conversation in about 330, having read one transcript
    (it read all 148).
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
    (or through `Replace:` and `Forget:` in `<remember>`); and keep multi-step workflows and tool
    runbooks in skills (below) instead. Memory remains data, not instructions.
    The workspace's `AGENTS.md`, `CLAUDE.md` and `GEMINI.md` carry the bot's `INSTRUCTIONS.md` and
    direct the agent to read the others, so it keeps them across its own context compaction; they
    are rewritten before every turn.
  - **Saving memory:** a bot saves a note as soon as it is established: a clear statement from the
    owner of how it should work from now on needs no "remember this", and the bot saves it in the
    reply in which it agrees, keeping its scope; when it's unclear whether something is lasting, or
    how far it reaches, the bot asks first. Every conversation saves the same way (Home, tasks on
    this Mac or a host, and sub-agents): the bot writes each note, correction or removal in its reply
    between `<remember>` and `</remember>`, or `<remember scope="shared">` for the shared memory, and
    BotChu writes it when the turn ends. It re-reads the file just before writing, so what other
    conversations or the owner changed meanwhile is kept, skips duplicates of existing bullets,
    updates a bullet in place for `Replace: old -> new`, removes one for `Forget: old`, and leaves out
    what looks like a secret, a question, a transcript or command output, or a note over 1,000
    characters, saying how many and why (never repeating a secret). Tags in code are examples, and
    only the turn's own replies count, so an old request in the conversation never brings back
    something forgotten. BotChu reads the file back to check the change held, then confirms it under
    the reply ("Saved to QA Duck's memory: …"), and the conversation's next turn (for a sub-agent,
    its bot's Home) hears what was saved, left out or couldn't be saved, so a bot never takes asking
    for a save as a save. When the file can't be written, or exists but can't be read (it is never
    overwritten then), memory stays as it was, the conversation says why, and the notes wait in the
    bot's `.botchu/` (in memory if that fails too): BotChu tries them again, first and in order, after
    each of the bot's turns (saying so only once they are saved), and **Retry** above the message box
    tries them at once. A bot edits a
    memory file itself only to reorganize it when asked. Whether a reply recognizes an established
    preference is up to the bot's model, which its instructions ask; saving it is BotChu's.
  - **Run reviews:** a minute after a task's turn or a sub-agent's run ends, if it used tools or
    failed, BotChu reviews it in the background: what went well, what didn't, and whether anything
    should change in how the bot works. The turn's receipt, the handoff, queued messages and
    switching conversations never wait for it, and a review's failure never changes how the run
    is reported. One review runs at a time across all bots, as a new session on the account the run
    used, with no tools at all, which the CLI itself enforces: Claude Code without its built-in tools
    (`--tools ""`), with every tool denied, no MCP servers, skills or commands, and nothing approved
    (`dontAsk`); Codex in its read-only sandbox approving nothing, without your Codex configuration
    (its MCP servers and plugins) or rules, with its shell, code mode, sub-agents, apps, browser and
    web search turned off; Muse in its empty preset, with its shell, writes and web tools off.
    Nothing bypasses permissions, and no review session is saved. A review that still reports a tool
    call is stopped at once and fails (**tool use**), keeping nothing. Antigravity has no such mode,
    and Pi's (`--no-tools`) hasn't been checked with a real run, so their runs are recorded as not
    reviewed, spending nothing. A review runs in an empty temporary folder (removed afterwards),
    without the delegation helper, at utility priority, and only while that account has no turn,
    sub-agent or scheduled job running: at most 12 model calls a day per account, retries included, each review
    stopped after 5 minutes (its CLI interrupted, then terminated, then killed), with one automatic
    retry; an account out of allowance waits an hour, and a review still waiting 48 hours after its
    run (or after its **Retry**) is skipped. A review is neither a task turn nor a sub-agent, so it is never reviewed itself,
    and BotChu's turn log records it as a "run review", without lines that look like secrets. It sees
    a snapshot of up to 24,000 characters: how the run ended (a finished turn isn't proof the work
    succeeded; a stopped run is neither a failure nor finished work, and isn't continued), the brief,
    the owner's messages and corrections, the bot's replies and handoff, and each tool call with its
    exit code (and the end of a failed one's output), each labelled so the review cites them as
    evidence. Lines that look like secrets are left out before anything is shortened; text from the
    run is indented and BotChu's own tags in it are neutralized, so it can't pose as a label or end
    the snapshot, and only the labels BotChu wrote count as evidence. With it come the bot's
    instructions and memory as they are now, the shared memory and `TEAM.md`, all as evidence rather
    than instructions. The result is **No durable change**, **Memory updated**, **Change proposed**,
    or a failure, with sign-in, allowance, the review itself, tool use and saving told apart. BotChu
    applies at most three changes a run, each citing evidence, verified, general and one line of
    plain text, and only to the bot's own `MEMORY.md` (which sessions read as data, not
    instructions), through the same writer as **Saving memory** (above): notes, and corrections and
    removals of a note that is there exactly, once (never one that merely contains it). Every change
    to `INSTRUCTIONS.md` is a proposal for you, as are the shared memory, `TEAM.md`, the bot that
    delegated the run, the repository's own documents (which change through its pull requests; a
    review never edits a repository), an unverified hypothesis, a change without evidence, a
    correction of a note that has changed since, and any line that could loosen a safeguard, widen
    what the bot may do, or name a web address or a command to run. A change of more than one line,
    or with Markdown or HTML structure (a heading, list item, quote, table row, code fence or tag) or
    control characters, is left out before anything is written, as are one-off details; secrets,
    transcripts and command output are left out, as in memory, and a secret is never quoted; and a
    note memory lost since the run (a correction or `Forget:`) isn't saved again. A sub-agent's run
    is reviewed about the bot it ran as, on its account, and the caller's own turns about the caller,
    so a lesson isn't saved to every bot that took part. Each review is saved at every step in
    `.botchu/evaluations/<run>.json` in that bot's folder, without lines that look like secrets, so a
    relaunch neither repeats one nor applies one twice (quitting stops a running review, which runs
    again after the next launch); the newest 50 a bot are kept, and any that called the model in
    the last 24 hours, which the daily limit still counts. A change that couldn't be saved stays
    with its review, whose **Retry** saves it, rather than waiting with the conversations' notes, and
    conversations' notes still waiting for the file are saved first, on their own. **Activity ▸ Run
    reviews** in the status sidebar lists them (Home: those about the bot; a task: those of its turns
    and of its sub-agents), each opening to its summary, what worked and didn't, the evidence it
    cited, every line it added and removed (read from the file just before and just after the save,
    so a review that wrote anything never shows as no change, and no copy of the file is kept), its
    proposals (with Copy) and what it left out, with **Revert**, which undoes each of its changes only
    where the file still holds exactly what it left, in the same section, and lists any you have
    changed since as not reverted, keeping your edit; and **Retry**. Home gets a note for a change
    made or proposed, and for a failure once per kind until a review succeeds; reviews that change
    nothing stay quiet. Saved notes reach the bot's next new session, never a running one. Settings ▸
    **Run reviews** turns them off; they are on by default, since the CLIs enforce the tool-free
    sessions and only memory notes change by themselves, and they spend the account's allowance.
    Only the installed app runs reviews, never tests or review copies.
  - **Team playbook:** `TEAM.md` in the bots folder, beside the shared `MEMORY.md`, is the process
    every bot follows: its stages, handoffs, who calls whom with `botchu-subagent`, and when work is
    done. Unlike memory, it is given as instructions: in every bot's Home `AGENTS.md`, and at the
    start of every task and sub-agent session. It is left out entirely while it is missing or empty,
    and BotChu never creates it. Edit it from any bot's **Memory** tab or in Settings (**Shared by
    every bot**), where the shared `MEMORY.md` is edited too. Bots are told not to change
    `INSTRUCTIONS.md` or `TEAM.md` unless asked. A new
    session (new bot, account switch, or **New Session**) also gets the recent conversation, so
    switching accounts keeps the thread's continuity.
  - **Skills:** reusable workflows and tool runbooks, each a `SKILL.md` in a `skills/<name>/` folder
    (with any helper scripts or references beside it), in the format of Claude Code's skills: YAML
    frontmatter with `name` and a one-line `description` of when to use it, then the
    steps. Those in the bots folder's `skills/` (`~/BotChu/skills/` by default) are shared by every
    bot; those in a bot's own workspace's `skills/` are only its own, and take the place of a shared
    one of the same folder name. Only a catalog (each skill's name, `SKILL.md` path and description)
    goes into the workspace's `AGENTS.md` and `GEMINI.md` and opens every Home, task and sub-agent
    session; the agent reads a skill's file when it matches what it is doing. A task or sub-agent on
    an SSH host can't open the files on this Mac, so it gets the active skills' `SKILL.md` in full
    instead, up to 16,000 characters together (the rest by name and description); their helper files
    stay on this Mac. Memory capture tells bots that multi-step workflows go in a skill of their
    own, not in `MEMORY.md`; they change shared skills only when you ask. **Skills** in the sidebar lists them as cards (shared, or a bot's own, with a
    search and a filter), with the number of files beside each `SKILL.md`; **New Skill** makes one,
    shared or for one bot, from a template and opens it in the Markdown editor, as do a card's
    **Edit…** and double-click; a shared skill's **Bots** menu turns it on or off for each bot (kept in
    `bot.json` as `disabledSkills`; every shared skill is on until turned off), and its menu shows it
    in Finder or puts its folder in the Trash. **Shared Folder** opens the bots folder's `skills/`.
    BotChu creates no skill on its own; an example, `aside-web-browsing`, is in
    [docs/skills](docs/skills/aside-web-browsing/SKILL.md), to copy into that folder.
  - **Status sidebar:** on the right of the chat (View ▸ Show Status, ⌥⌘I). It opens at its widest,
    380 points; drag its edge to narrow it, down to 280. A card at the top shows
    a large character (its pet, playing, or its emoji) on the left, beside the bot name and current
    activity. Tasks show the repository as a larger title, with the issue or task title beneath it
    in smaller text. The ring says its state (grey when idle, a spinning violet arc while it
    works, red after a failed turn); plain text gives its activity and running time, last activity,
    or error. The character and ring convey status
    without a dot or status pill. The card and pet animation reflect only the shown Home or task;
    the bot list still shows activity across its tasks. Five icon tabs sit below the character,
    in a rounded bar with a raised selected segment: **Activity** (tasks, run reviews and conversation stats), **Sub-agents** (delegated work),
    **Model & Usage** (account, agent, model, reasoning and allowance), **Session** (the CLI session
    and workspace controls), and **Memory** (instructions, personality, memory, the team
    playbook and skills). Hover for tab names, or
    focus the bar and use Left/Right arrows. The selected area is remembered across conversations
    and launches; its data always belongs to the shown Home or task. The character, tabs and bottom
    actions stay visible while the selected area's content scrolls. Home keeps Edit and New Session;
    tasks keep Close Task and New Session. Task Activity includes the repository, computer and
    linked issue, then the repository's open issues, from the saved Projects catalog: **Issues · N**,
    GitHub's count of its open issues (pull requests aside), which stays in the heading when the
    section is collapsed, then the five most recently updated, each a number and title that opens it
    in the Projects sidebar, **View All Issues** (with the count when there are more), which opens
    the repository's Issues there, and Refresh, which syncs Projects. Going to Projects keeps the task
    and its draft to come back to. Until the count is read, the heading says why instead (reading,
    not read, couldn't read, or unavailable for a repository `gh` doesn't list), never zero; an empty
    repository shows **No open issues**, and a sync that fails keeps what was read, marked not
    updated, with why, and Refresh tries again. Showing it checks the catalog is current, at most
    every two minutes, like Projects. Home and task accounts can change in Model & Usage; Session keeps Finder, Terminal and
    remote SSH controls. Branch names, review commits, generated pull request metadata and task
    authorship are managed internally and omitted from the task form, cards, headers, sidebar tooltips
    and new automatic progress notes. Explicitly choosing a pull request to continue or review is
    still available in New Task. Colors follow light and dark mode.
    Sections within each area, and Status above the tabs, still collapse from their headings, with
    their expansion remembered. **Memory** has four cards matching
    Conversation: the bot's **INSTRUCTIONS.md**, **SOUL.md** and **MEMORY.md**, and **TEAM.md**, the
    playbook every bot shares (the same file as in Settings), followed by a summary of what bots
    save in memory and what stays out. **Skills** below them lists the bot's own skills and the
    shared ones, each with a switch that turns it on or off for this bot, and **Manage Skills**
    opens the Skills gallery. Each card and skill opens an in-app Markdown editor at half the
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
    a turn or with Refresh. This spends a small amount of its allowance. Muse reports the
    reading from its answer on, often only when that turn winds down after it, so the check keeps
    asking until then (within 90 seconds). OpenRouter shows the
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
    and default OpenRouter model, whether finished work gets a run review, and the Telegram gateway (below).
  - **Telegram:** an opt-in gateway, in Settings ▸ **Telegram**, lets you message bots from
    Telegram through a Telegram bot of your own (made with BotFather) while BotChu runs on this
    Mac. There is no server or webhook: BotChu asks Telegram for new messages itself (long
    polling). The bot token is kept in the Keychain and never goes into a log, a conversation or a
    prompt. Only the private chats listed there reach BotChu, each reaching the bot chosen for it,
    in its Home (not its tasks). Anything else (another person, a group, a bot) is ignored before
    BotChu reads it or says anything, and Settings lists the chats it refused since launch, with
    **Allow** for your own. A message goes into the Home through its queue, as one typed in BotChu
    does, so it resumes the Home's CLI session and waits behind a turn under way (the chat is told).
    While a turn works, Telegram shows "typing…". When it ends, the turn's reply goes back to that
    chat as plain text, in messages of up to 4,096 characters (at most eight, then "the rest is in
    BotChu"). A failed or stopped turn says so, without its error. It takes text only: photos, files
    and edits get a reply saying so, and `/start` or `/help` says where messages go. Where its
    updates are up to and the replies it owes are kept in `telegram.json`, so a relaunch neither
    misses a message nor starts a turn twice: a message Telegram sends again has the same ID in
    the conversation. A reply that fails is tried again, and one Telegram won't take is noted in the
    conversation. While the Mac sleeps or BotChu isn't running, messages wait on Telegram for up to
    a day. See [Telegram gateway](docs/telegram.md) for setup and troubleshooting.
  - **Reporting bugs and features:** the ladybug button at the toolbar's trailing end, on every
    screen, or **Help ▸ Report a Bug or Feature…** opens a sheet with one field, which takes up to
    eight images as the message box does. Just before the sheet opens, BotChu takes a screenshot of
    the window it was opened from, as it shows then (its sidebar, conversation or gallery, and
    status sidebar, scrolled as they were), and puts it first among the report's images, one of the
    eight, where its preview's × removes it. It is taken once a report, never again on Submit or a
    retry, and only of that window: not other apps, BotChu's other windows or the desktop. macOS
    doesn't ask for Screen Recording to take it (it needs macOS 14.4 or later); when it can't be
    taken, the sheet says that no screenshot is attached, and the report goes without it. It is
    kept in memory, not in a file, and nothing is uploaded before **Submit**. **Submit** (⌘↩)
    files it as an issue in `asieke/BotChu` with `gh issue create`, titled from its first line or
    sentence (cut at a word, 72 characters at most), with its images after the text, and links the
    new issue; when gh fails, the report stays, with gh's reason. gh attaches the images itself
    (`--attach`, gh 2.99 or later, which needs write access to the repository), each as
    `image-<n>.png` from a private folder that goes afterwards; if one doesn't upload, the issue is
    made without it, and the sheet says so. The repository is public: anyone can see the issue's
    images, as the sheet says beneath them, and the screenshot shows whatever the window showed,
    conversations and names included. Besides the images, the issue adds only the app state
    the sheet shows before it goes, as categories and counts: the version and commit, macOS, the
    screen and status sidebar area, the conversation's kind (Home, or a task on this Mac or a host
    and its kind of work), CLI family, starter model and effort, its turn's state (an error by kind
    only), message and queue counts, the window's size and appearance, and how many bots and turns
    there are. Conversations, instructions, memory, prompts, tool calls, error text, paths and the
    names of bots, tasks, accounts, hosts and repositories never go into the app state.
- Does not: run a bot's Home anywhere but this Mac, or tasks anywhere but this Mac and SSH hosts
  (no containers or cloud), run scheduled jobs while BotChu is quit or the Mac asleep, ask for approval of tool calls (every CLI runs with
  its permission prompts bypassed, inside the bot's folder or the task's worktree), or keep any
  secret outside the Keychain and the CLIs' own logins.

## Architecture
- `macOS/` is a Swift package (Swift 6 toolchain, macOS 14+):
  - `Sources/BotChuCore/` — Foundation only, unit-tested: accounts and the command line each CLI
    runs with (`Accounts.swift`), generation choices, how a model is named (its full name and
    version, an alias's or default's once reported) and public OpenRouter model metadata
    (`GenerationOptions.swift`, `ModelCatalog.swift`), the bot and message model, with the model a
    conversation's CLI last reported running (`Models.swift`), the
    sections the sidebar and Agents group bots into, where a new bot goes and what a search of them
    finds (`BotSections.swift`), skills: finding them, reading their frontmatter, which a bot uses,
    and making one (`Skills.swift`), one stream parser per
    CLI turning its JSON lines into chat events (`StreamParsers.swift`), what a tool call does and how
    the chat names it: read-only or not, files, folders, line ranges, diffs, failures and delegations
    (`ToolActivity.swift`, reading shell command lines with `ShellCommand.swift`), the chat's activity
    items, with exploration folded into groups whose summaries are kept as calls join and leave them,
    updated only for new messages, running calls and the last message (an edit of the thread is
    verified), where delegated runs' cards go, worked out again only when their calls or records
    change, and sub-agents' tool counts kept as they stream (`ActivityTranscript.swift`, in chunked
    storage that copies a chunk, not every element, when shared: `ChunkedArray.swift`), which of its
    rows the chat lays out, their heights kept by what they showed and how, and the reader's row and
    offset into it (`TranscriptViewport.swift`), the identity, instructions,
    team playbook, memory, skill catalog and recap that open a session (`BotContext.swift`), the editable Markdown
    files of a bot and of every bot (`BotDocument.swift`), account allowance parsing and native queries,
    and the lines Providers shows, lined up across its rows (`ProviderUsage.swift`, `ProviderUsageClient.swift`) with a throttled in-memory cache
    (`UsageCache.swift`), per-conversation pending-message delivery, keeping a follow-up the CLI
    took until a saved transcript holds it (`MessageQueue.swift`, saved in that order by
    `Store.swift`), how tall the message box is for its draft and how far its text may scroll
    (`ComposerLayout.swift`), what
    the status sidebar shows about a bot, from a summary of its thread kept as the thread grows, and
    its `MEMORY.md` (`BotStatus.swift`), replies' parsed Markdown, cached by their text within a
    budget of bytes (`MarkdownCache.swift`), and parsed off the main thread as they are written, one
    revision at a time for each reply (`MarkdownPreparation.swift`), pets: the activity a tool call means
    and the clips that show it (`Pet.swift`), making a pet: its poses and clips, the Codex prompt
    for the stills, the OpenRouter request and job, the cost estimate, the manifest and install
    (`PetVideo.swift`), scheduled jobs: their schedules in their own time zones, runs, history and
    storage, what is due, a run's context and how it went (`Jobs.swift`), and the scheduler that
    reserves a time before its run starts, makes runs wait, records how they end and recovers after
    a quit (`JobEngine.swift`), tasks: the task, its title
    and branch names, its pull request, receipts, dispatch requests and the briefs of tasks that fan
    out to sub-agents (`Tasks.swift`), hosts and
    where a repository is worked on (`Hosts.swift`), running
    a command on this Mac or a host, the checkouts in the repositories folder, cloning, task and
    review worktrees, and what `gh` says about your repositories, issues and pull requests
    (`Repositories.swift`), preserving/validating project metadata (`ProjectRecord.swift`) and reading
    or proposing it through GitHub with retryable, metadata-only PRs (`ProjectGitHub.swift`), the Projects
    tables' rows, their status filter and the open pull requests and issues across repositories (`ProjectOverview.swift`),
    the saved Projects catalog, what a sync reads again and how it takes the answers, GitHub's REST
    answers, and the projects offline readers such as completion see (`ProjectCatalog.swift`), and the
    sync that keeps it on disk and in step with GitHub, with its ETags, probes, bounded requests and
    coalesced refreshes (`ProjectSync.swift`), a repository's open issues at a glance as a task's
    Activity shows them, from that catalog (`IssuePreview.swift`),
    an issue or pull request in full as the project sidebar shows it (`WorkDetail.swift`), the JSON store, with
    the index saved whole or a failure to show (`Store.swift`), with conversations' files read without losing
    what can't be read (`Transcript.swift`), the writer that saves files off the main thread, each
    target's in its own lane and in order, newer states of a file taking the place of waiting ones
    (`StorageQueue.swift`), and a conversation's transcript and queue saved through it, with the
    messages a written transcript holds taken out of the queue as it is then (`ConversationStorage.swift`),
    what a conversation not in memory is known by, its index and how it is checked against its
    transcript, reading one and recovering its queue after a launch, where its history is and which
    read is taken, and which inactive histories leave memory (`ConversationHistory.swift`), what was
    read, decoded, written and copied, per file (`HistoryCounters.swift`),
    and the `Process` runner that launches
    a CLI through the login shell, `zsh -l`, or on a host over `ssh`, parsing its output off the
    main thread and delivering it in batches (`AgentRun.swift`). Delegation models, validation, persistence and the Python helper are in
    `Subagents.swift`, `Store.swift`, `SubagentArchive.swift` (each run's transcript and record saved in
    a lane of its own, off the main thread, while they stream and at their start and end), `SubagentHook.swift` and `BotContext.swift`; `SubagentTransport.swift`
    handles isolated local and SSH mailboxes with bounded reads, timeout and cancellation. A Task
    handed to another bot (`botchu-task create`, the same helper under a second name) goes through
    the same mailbox; `TaskHandoff.swift` reads and checks the request, recognizes it when asked
    again, and holds what is written back.
    What replies ask to remember (`MemoryNotes`, in `BotContext.swift`) is saved to memory files
    by `MemoryWriter.swift`: one save at a time, read back to check it held, with notes that wait
    and are tried again. Run reviews are in `RunEvaluation.swift`: what a review sees of a run, its
    prompt, reading its reply, which changes are applied and which are proposals, the saved record,
    handing a run over (claimed once, with what it sees built off the main actor, and only while
    reviews are on), the queue with its limits, retries and relaunch, applying through the writer
    (`MemoryWriter.saveReviewed`), the exact diff it records and its revert (`AppliedChange`), and the
    review's own CLI run, whose tool-free command lines are in `Accounts.swift`
    (`CommandBuilder.toolFreeInvocation`).
    Reports filed from the app (their title, description, app state, the size their window's
    screenshot is taken at, and `gh issue create`) are in `IssueReport.swift`. The Telegram gateway is in `Telegram.swift` (the Bot API client: long
    polling, sending, and errors that never hold the token) and `TelegramGateway.swift` (which chats
    may reach which bot, message IDs that recognize a repeated update, replies cut to Telegram's
    limit, the saved offset and replies owed, and retries). `@` and `#` mentions are in
    `Mentions.swift`: the link a message keeps, where a query starts and ends, matching and ranking,
    what a choice inserts, whether a link still resolves, and what a sent message tells its bot
    about them.
  - `Sources/BotChu/` — the SwiftUI app, a standard `NavigationSplitView` window with an inspector,
    in standard system materials: `App/` (the app, window, model, each conversation's state, observed
    on its own, with whether its history is in memory and what waits for it (`Conversations.swift`), settings, Keychain, dev hooks, making
    pets and the OpenRouter video client, and where tasks work: your GitHub repositories and their
    computers, `TaskPlaces.swift`, Tasks handed to other bots, `TaskHandoffs.swift`, what a report says about the app, `IssueReports.swift`, and the
    screenshot of its window, through ScreenCaptureKit, `WindowCapture.swift`, the
    skills the app lists and edits, `SkillLibrary.swift`, the Telegram gateway in the app,
    `TelegramBridge.swift`, what mentions complete from and tell a bot, `Mentions.swift`, the runs
    of scheduled jobs, `JobRuntime.swift`, and handing finished runs to run reviews, `Evaluations.swift`),
    `Sidebar/` (workspace destinations and bot conversations, and the sections' menus and naming alert, which Agents shares), `Library/` (Projects with its repository sidebar, Agents grouped by section, Providers, Skills, and Jobs with its history), `Chat/` (messages, the activity cards and their density, the shown part of the transcript and the rows of it laid out, with the scroll view's watcher that keeps the reader's row in place, `ChatScrollProbe.swift`, rich replies' web views and the pool that keeps them, and the composer, whose image-taking writing area the report and New Task sheets share, with `@` and `#` completion in the chat's alone, `MentionCompletion.swift`), `Inspector/` (the
    status sidebar, a bot's and a task's, with a bot's jobs and its run reviews, and a task's repository's open issues), `Editor/` (the bot, Markdown, New Task, job and report sheets), `Settings/` (with
    the hosts and Telegram), and
    `Shared/` (layout constants, the avatar, the status badge, the pet's looping video, and the
    providers' logos, drawn in code after GitChu's: the marks are their owners' trademarks, shown
    only to identify the CLI an account runs).
    `Resources/ChatRenderer/` bundles pinned Mermaid and KaTeX distributions, their fonts and licenses. Its README records provenance and update steps; no JavaScript package
    install or network access is needed at runtime. The rendering document blocks remote resources
    and model-supplied scripts, uses Mermaid's strict mode and disables trusted TeX commands.
  - `Sources/botchu-smoke/` — a command-line check, not shipped in the app, that runs two real
    turns on each account named the way the app does (see **Test**).
  - `Tests/BotChuCoreTests/` — parser tests against captured output of every CLI (with the model
    Claude Code and Muse report running), how models are named, command lines,
    context and store, and tasks: naming, dispatch requests, Tasks handed to other bots (the
    helper's request and every answer it prints, checks, and the same request recognized), checkouts, `gh`'s output, and worktrees
    made in throwaway repositories, the project status filter, issues and pull requests read in
    full from `gh`'s output, and fan-out briefs; the Projects catalog and its sync through a stand-in
    `gh` (the saved catalog shown before any request completes, checks for changes that read only
    what changed, failures, removals, coalesced refreshes, another account, a missing or unreadable
    file, and the four-request limit); and hosts: their `ssh` command lines, where a repository is worked on, clones,
    worktrees, reviews and turns on a host through a stand-in `ssh` that runs here, and notes kept
    from a remote task; memory: #88's Home sequence (a routing preference saved in the turn that
    agrees, and recalled by a fresh session), what is left out, bot or shared scope, repeats,
    corrections and forgets, concurrent saves, and saves that fail, wait (also across a relaunch)
    and are tried again; reports: their titles, app state, the size of their window's screenshot, and filing (with attached images) through a stand-in `gh`;
    output parsed off the main thread and delivered in batches, thread summaries, the Markdown cache
    within its budget (ten 128 KB replies written in revisions, then memory pressure), replies being
    written parsed off the main thread (100 rapid deltas coalesced, the worker's limit shared, a slow
    earlier revision never shown over a newer one, the last always settling as a full parse), one
    parse for replies without math (shell code with `$HOME`, prices, the word Mermaid) and hundreds
    of expressions put back in one pass, and sub-agent checkpoints; and the chat's activity: how each CLI's tool calls (and shell
    commands) are described and grouped, failures, repeated reads, sub-agent cards, and that an
    update does work only for what changed (counted for live groups of 400, 1,000 and 5,000 calls),
    shows what grouping the thread afresh shows through random turns (calls finishing out of order,
    failing, their kind arriving late, stopped turns, edits of the thread), sees changes of the same
    length, lets go of a settled group's running state, and leaves sub-agent placement and counts
    alone while a reply streams; the rows the chat lays out: within their bound through ten pages of
    5,000 messages, 1,000 items arriving and a group of 5,000 calls in Raw and opened again and again,
    every row reached scrolling down and up again, heights never reused for other content, layout
    inputs or an edited thread, measurements of rows gone dropped, and the reader's row (or the end)
    kept as rows above it change, are forgotten or move; the sidebar's sections of bots, and searching them; follow-ups the CLI
    took, kept through a transcript that can't be saved and a relaunch, in Home and in tasks;
    conversations' files with a line that isn't JSON, an unknown role, or no readable text, kept
    before the next save, also in a queue going through a relaunch; saving off the main thread: each
    file's writes in order and different files' side by side, newer states taking the place of waiting
    ones, repeats skipped, quitting's wait, a deleted bot's folder never made again, a sub-agent's end
    never written behind another's, and the conversation's guarantees above with writes and the CLI's
    messages interleaved and each write failing in turn; run reviews handed over without building
    anything while reviews are off, claimed once, and built off the main actor; a section change or a new
    bot while `index.json` can't be saved, then the retry and a reload; how tall the message box
    grows and how far its text scrolls; each account's allowance, with Muse's check through a
    stand-in `muse serve`: a reading that comes long after the answer, or announced while a read is
    answered empty, and none at all; the widths that line up Providers' allowance lines in every
    row; skills: their frontmatter, finding and making them, which a
    bot uses, and the catalog, or (on a host) the files in full, that sessions get; the Telegram
    gateway against a stand-in Bot API: round trips, refused and revoked chats, each chat's own bot,
    busy conversations, repeated updates, cancelled batches, relaunches, forwarded input,
    pending-work limits, shared rate-limit waits, reconnecting, failed sends and checkpoints, and
    long replies; mentions: where a query starts (not in email addresses, URLs, headings or
    `#123`), agents with spaces and namesakes, ranking, what a choice inserts, trimming and taking a
    message back into the draft, links that no longer resolve, and the context a message carries,
    kept through the queue and the saved thread; scheduled jobs, with a fake clock and store and
    no CLI: times across daylight-saving changes and in their own zones, chosen days, intervals that
    stay true durations, missed times run once or skipped within a window, a reservation saved before
    a run starts (and nothing started when it can't be), repeated ticks and relaunches that start
    nothing twice, runs waiting for their agent's workspace and a slot, a job that never overlaps
    itself, pausing, resuming and editing that never make up time, Run Now while paused, failures
    that pause a job, the history's bounds, crash recovery, jobs moving with their agent, a run's
    context (its agent, when it was meant for, how late, no Home), its fresh session, and quiet,
    empty and failed results; a task's glance at its repository's open issues: GitHub's count
    whatever the preview and the read list hold, pull requests left out, loading, not read,
    unavailable, zero and kept after a failed read, and another repository's answer never showing
    under the one switched to; and run reviews, with stand-in reviewers (no test
    runs a real review): the bounded snapshot of finished, failed and stopped runs, and labels and
    tags in a run's text that can't pass for its own, handing a run over without waiting, one review
    despite repeated ends and relaunches, a review cut short by quitting, no-change outcomes, which
    changes are applied or proposed (evidence, verification, scope, safeguards, addresses and
    commands, instructions always proposed), changes of more than one plain line, every write
    recorded in full, edits made meanwhile, exact corrections and a revert that keeps later edits,
    secrets left out before shortening and from everything saved and logged, forgotten notes, a
    failed save and its retry, failures told apart, the account limits counting every model call,
    reading replies, recall by a fresh session, the tool-free command lines, runs on CLIs without
    them, a review that reports a tool call, and the review's own session through a stand-in CLI,
    killed at its timeout; and loading histories: a digest and its report, an index saved with its
    transcript and read without it, one made stale by a change of the same size with the dates kept,
    or by its end, version or contents, made again from an older folder without repairing or copying
    a damaged transcript, recovery that reads a transcript only when messages wait or were taken,
    which read is taken, the history budget and counters kept per folder.
  - `Tests/BotChuRenderingTests/` — actual WebKit math/diagram layout, native tables ruled straight
    across every column, streaming updates (a long reply being written never parsed on the main
    thread, its chunks laid out only at the width it is shown at, also when the window asks for its
    ideal size, and a rich reply's web view rendering one revision at a time, ignoring late heights),
    history laid out a screenful at a time (rows counted as they appear and go): ten pages of 5,000
    messages, a reader paused at an old message while 1,000 items arrive and a reply streams, with what
    they see unmoved, every row reached scrolling both ways, back at the newest after switching away
    and back; a group of 5,000 calls in Raw and opened again and again, a call's details kept open; and
    rich replies rendering above the reader, after memory pressure, narrower and dark, without moving
    them or leaving blank space, source
    fallback and offline restrictions, web views made only near the visible chat, conversations and
    sub-agents streaming without invalidating other conversations' views, what quitting mid-turn
    saves, a follow-up taken while the transcript can't be saved (back in it after a relaunch), model-picker keyboard interaction and persisted choices,
    the message box's text staying put while it is typed (narrow and wide, past its maximum and back),
    Markdown editor sizing and Save/Cancel, collapsing status sections, the sidebar's sections of
    bots (their menus, the alert that names them, collapsing and revealing, and changes that can't
    be saved, shown until Try Again or quitting saves them), Agents grouped under them and editing
    them with the same menus and alert, inspector tab navigation and
    restored selection, conversation-scoped allowance reads, automatic task branch creation, the
    main window's layout at its narrowest, galleries that preserve conversation state, the project
    sidebar's tabs, details and fan-out tasks, custom profile persistence, the Providers table's
    rows under 100 points in every state and at its narrowest, provider logos in both
    appearances and in account menus, the report
    sheet, with a stand-in screenshot (taken of its window before the sheet opens, removed, not
    taken again on a retry, new for the next report, and a report without one when it can't be
    taken) and a real one of a test window through ScreenCaptureKit, filing with a stand-in, images pasted with Edit ▸ Paste into the composer, the report
    and New Task (through a stand-in for the general pasteboard, so no test touches the clipboard)
    and what pastes as text instead, New Task starting a task from a project and a brief with an
    image, the activity chat at every density, light and dark and at its
    narrowest, a chat that follows new content only for a reader at the bottom, a long
    conversation opened anew that shows its newest items at once and groups its history off the
    main thread, then regroups only a streaming reply, a Sub-agents
    tab that folds finished runs and scrolls to one the chat opens, and switching without a flash:
    the toolbar kept, the message box focused in the same update, the chat at its very end, pets
    that never blink out while a clip loads, rich replies shown only once rendered and shown
    again at once from those kept, within their budget, and typing dots that move, a Telegram
    message answered in its bot's Home, with stand-ins for the CLI and Telegram, `@` and `#`
    completion: Return and Tab that insert and never send, Escape, an edited label unlinked and undo
    linking it again (and redo unlinking it), a draft taken back from the queue shown linked, pasted
    text that opens nothing, links kept through copy and paste, a message's
    links and their context through sending, and the report and New Task boxes without it, a job
    made for its agent, shown in Jobs, delivered to Home as a receipt that leaves Home's draft and
    queue alone, and deleted with its agent, a sub-agent's handoff and a task's receipt that
    don't wait for their run reviews, a task's Activity listing its repository's open issues:
    one or all opened in Projects and back to the task with its draft, switching tasks, a failed
    refresh keeping what was read, and no GitHub request from showing or updating it, a Task handed
    to another bot whose Home is idle, from Home, a task and a task on a host, that goes on after
    the asking turn (also a batch whose workers are its own sub-agent runs, stopped with it), asked
    for again, a bot or repository that can't be found, and a dispatch file in another bot's folder
    that no longer waits for its Home; and, with writes slowed to 250 ms each or failing: a turn that
    starts only once its message is saved, sending and Stop that never wait for a write, a message
    that can't be queued coming back to the composer, typing and switching while four conversations
    save, quitting through the real notification waiting for writes and saying which it couldn't,
    deleting and moving a bot with writes under way, and a handoff that goes back only once saved;
    and, with reads held back: a launch that decodes only the shown conversation and an interrupted
    sub-agent, also with ten times the closed tasks' history, a conversation shown with a spinner
    while typing and switching go on, a receipt and a note to a conversation not read yet that wait
    for it and keep its history, sends, Stop and queue edits before recovery that keep their order
    and start nothing stopped, an unopened task's queued message that goes out after its own
    recovery, reads dropped after a deletion and made again after a move, histories leaving memory
    with their draft, queue and session kept, Home's report on its tasks from their digests, and
    Telegram recognizing a repeated message in a Home not read yet. Set
    `BOTCHU_TEST_SNAPSHOTS=<temporary folder>` when running
    `swift test --package-path macOS --filter galleriesKeepConversationStateAndCustomProfilesPersist`
    (or `projectSidebarShowsTabsDetailsAndFanOutTasks`, `providersTableRowsStayCompact`,
    `activityChatRendersGroupsCardsAndLiveWork`, `agentsGroupsAgentsUnderTheSidebarsSectionsAndEditsThem`,
    `jobsBelongToTheirAgentAndReachHomeOnlyAsReceipts`, or `taskActivityShowsItsRepositorysOpenIssues`)
    to render isolated gallery/table (sidebar, chat, or Agents' sections, wide and narrow) screenshots
    with sample data. These
    share a serialized suite because AppKit
    window focus is global; all use isolated windows and no real bot data. Providers and OpenRouter
    inspector fixtures inject both the usage cache and the key lookup, so tests never read Keychain.
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
  with the section each is in, and `telegram.json` there: where the Telegram gateway's updates are
  up to and the replies it owes (IDs only, no text).
  Versions before bot folders kept everything in `bots.json` and `threads/` there; the first launch
  moves them into the bots' folders and keeps the old files in `backup-before-bot-folders/`.
  Project metadata stays in each repository’s `PROJECT.md` on GitHub; what Projects read from GitHub
  for the signed-in account is saved in `projects.json` there, written off the main thread. Settings,
  with added CLI profiles, the hosts, where you chose to work on repositories and the Telegram
  chats, are in the `defaults` domain `local.BotChu`; the OpenRouter key and the Telegram bot token
  are in the Keychain (service `local.BotChu`). Bot workspaces are
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
- A run review runs one of those CLIs on this Mac in a new session without tools, which nothing
  saves: `claude -p … --tools "" --disallowedTools "*" --strict-mcp-config --disable-slash-commands
  --permission-mode dontAsk --no-session-persistence`; `codex exec --json --sandbox read-only -c
  approval_policy="never" -c web_search="disabled" --ephemeral --ignore-user-config --ignore-rules`,
  with `--disable` for its shell, unified exec, code mode, sub-agents, apps, plugins, browser,
  computer use, images, goals, sleep, tool suggestions, skills and hooks; and `muse exec --json
  --preset empty --disable-shell --disable-write --disable-web-tools --disable-request-user-input
  --disable-reminders --no-session-log`. None runs on Antigravity or Pi.

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
- `scripts/test.sh` runs everything: shell syntax for every script, `macOS/test.sh` (the unit and
  rendering tests) and `macOS/build.sh` into a temporary folder. There is no CI: the tests need a Mac
  with full Xcode. The rendering tests need window focus, so when other agents test on the same Mac,
  run it through the shared test gate (`/tmp/botchu-coord/gate.sh start scripts/test.sh`).
- `macOS/test.sh` requires every test bundle to finish and rejects explicit failure summaries,
  even if SwiftPM returns success. The native-click sidebar test runs in its own process because
  AppKit's window-animation callbacks can stop the Swift test runner's event loop during later
  tests; all its assertions still run. The script also runs the project-loading regression tests in Release. They check every
  repository result, the four-request limit, and that a sync finishes when the view that asked for
  it goes away. The run review tests run in Release too, for the review's timeout. Swift 6.4 has an [optimizer bug](https://github.com/swiftlang/swift/issues/93208)
  in task-group children returning String-first tuples from `do`/`catch`; the Projects sync and pet
  loading use named results with one return to avoid it. Debug tests alone cannot detect this regression.
- Accounts end to end: `swift run --package-path macOS botchu-smoke [account id …]` runs, for each
  account (all of them when none is named), a new session that opens with the bot's context and
  runs a shell command, then a resumed session that must recall a code word from the first, and
  prints both threads, each with the model it ran as the chat names it. It spends the accounts' own
  allowance, so it is not part of `check`; OpenRouter needs `OPENROUTER_API_KEY` in its environment. To exercise explicit generation
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
  `BOTCHU_OPEN=projects`, `agents`, `providers`, `skills` or `jobs` opens that workspace screen;
  with `projects`, `BOTCHU_PROJECT=<owner/name>` shows that repository's sidebar, and
  `BOTCHU_PROJECT_TAB=issues` (or `pulls`, `overview`) with `BOTCHU_PROJECT_ITEM=<number>` opens a
  tab and an issue or pull request there, read with your `gh` login.
  `BOTCHU_OPEN=memory` or `soul` opens the selected bot's Markdown editor.
  `BOTCHU_JOBS=sample` gives the demo bots sample jobs, with a history of every kind of run and a
  receipt in the first bot's Home, and runs no job (Run Now records a failed run), so nothing starts a CLI; `BOTCHU_OPEN=job-editor`
  or `job-history` opens a new job's editor or the first job's history.
  `BOTCHU_SECTION=<name>` moves the first bot into a sidebar section of that name, and
  `BOTCHU_SEARCH=<text>` opens Agents (`BOTCHU_OPEN=agents`) with that search.
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
  querying any account; `mixed` gives Providers a row in each state (more windows than a row
  shows, stale, failed, stale after a failed check, and a key without a limit). Usage fixtures
  are ignored outside throwaway data runs. `BOTCHU_PROFILE="<name>|<family>|<command>"` (several
  separated by `;`, `family` one of `claude`, `codex`, `antigravity`, `muse`, `pi`) adds CLI
  profiles to the run, such as one with a long name or a command that isn't installed.
  `BOTCHU_ACCOUNT`, `BOTCHU_MODEL` and `BOTCHU_EFFORT` set the first demo bot's generation choices;
  `BOTCHU_DEFAULT_MODEL` supplies an isolated OpenRouter default. `BOTCHU_OPEN=model` or `effort`
  opens the composer's picker, and `inspector-model` or `inspector-effort` opens the sidebar's.
  `BOTCHU_INSPECTOR=activity`, `subagents`, `model`, `session` or `memory` selects a status sidebar tab;
  `inspector-model` and `inspector-effort` also select Model & Usage before opening the picker.
  `BOTCHU_WINDOW=compact` checks the minimum window width. `BOTCHU_DRAFT=<text>` puts that draft in
  the message box (`\n` for a new line), to check how it grows and scrolls.
  `BOTCHU_OPEN=report` opens Report a Bug or Feature, and `BOTCHU_REPORT="<report>"` files one,
  two seconds after launch, each with the window's screenshot (`BOTCHU_SCREENSHOT_FAIL=1` shows a
  report whose screenshot couldn't be taken). A review copy files reports only with a stand-in `gh`, which keeps them (and the images it
  attaches) in `reports/` in
  its data folder and prints a made-up issue's link (with `BOTCHU_REPORT_FAIL=1`, it fails as a
  signed-out gh does), so no review creates a real issue.
  `BOTCHU_TYPE="<text>"` types into the shown conversation's message box a moment after launch, a
  character at a time, so `@` and `#` completion opens (`{down}`, `{up}`, `{tab}`, `{return}` and
  `{escape}` press those keys).
  `BOTCHU_DEMO=activity` makes the shown conversation a long agent run, in memory (exploration with
  failures, a build, an edit, three sub-agents and a live group), and `BOTCHU_DENSITY=compact` (or
  `detailed`, `raw`) chooses the chat density for the run.
- Chat latency: `BOTCHU_BENCHMARK=<file> swift test --configuration release --package-path macOS
  --filter chatBenchmark` times, from the change until the window has drawn it, switching to long
  conversations (1,500 messages; outputs of 200 KB to 1 MB; explorations of 400 and 5,000 calls;
  seventeen running sub-agents; the 1,500 messages with twenty finished and seventeen running
  sub-agents), again with their grouping forgotten (and until their earlier items are grouped), a
  streamed delta, a new call in a live exploration, a sub-agent's update, and opening a large group
  or output; and, in Core alone, a call joining and finishing in a live group of 400, 1,000 and
  5,000 calls, apart from comparing the group before and after, grouping each afresh, and the memory
  a 5,000-call projection keeps; and writes the table to the file. It also streams 100 rapid deltas into a 128 KB
  reply, until the last delta's rendering is drawn, with the worker's counts; then 30 more at 5 a second
  while a key is pressed in the message box every 40 ms, with how long from each delta's time and each
  key press until it is drawn, and how long the main thread keeps other work waiting meanwhile (and with
  nothing streaming), and how long the main thread is held to show each revision the worker prepares;
  then 60 deltas into a 32 KB reply with 282 equations, until WebKit has drawn the last, with WebKit's
  counts. It opens the 400- and 5,000-call groups in the chat, and shows the 5,000 calls in Raw, with
  the rows laid out. In a 5,000-message conversation it clicks **Show earlier** ten times, pauses at
  an old message while 1,000 items arrive and the reply streams (with how far the reader's row moved),
  scrolls 40 points at a time 300 times (with the steps over a 60 Hz frame), jumps to the newest, and
  switches away and back 30 times, until drawn, its next update and a key press in the message box,
  with the process's memory before and after; and the most rows laid out at each step, counted as
  they appear and go. `BOTCHU_BENCHMARK_SCOPE=chat` times the
  chat column without the sidebars. It asserts nothing about time, which varies with load, and isn't
  part of `check`. The targets, for a release build: switching under 150 ms, a streamed delta or
  new call within a frame (16 ms), opening a group under 100 ms.
- Launching: `BOTCHU_LAUNCH_BENCHMARK=<file> swift test --configuration release --package-path macOS
  --filter launchBenchmark` builds eight bots, forty open tasks, sixteen closed ones and a hundred
  finished sub-agents (101 MB), opens each Home and open task once and reads the process's memory,
  then launches 30 times (`BOTCHU_LAUNCH_SAMPLES`), timing the model, the first window, the first
  keystroke, the shown conversation's messages and opening a conversation not shown yet, and five
  more without indexes, as a first launch after the upgrade, with what each read, decoded, wrote and
  copied; and writes the table to the file. It asserts nothing about time and isn't part of `check`.
- Markdown: `BOTCHU_MARKDOWN_BENCHMARK=<file> swift test --configuration release --package-path macOS
  --filter markdownBenchmark` times converting the next revision of prose, code, shell code with
  `$HOME`, equation-heavy, and table-and-diagram replies of 2 to 128 KB, gives a 128 KB reply 100
  rapid deltas (with the worker's counts and the main thread's time for each), and measures what
  ten 128 KB replies keep, then release under memory pressure. It needs no window, asserts nothing
  about time and isn't part of `check`.
- Saving: `BOTCHU_PERSISTENCE_BENCHMARK=<file> swift test --configuration release --package-path macOS
  --filter persistenceBenchmark` times, for 1,500- and 5,000-message conversations and 12 MB of tool
  output, what a save costs the main thread (now, and as it was when it wrote there), how long it takes
  to be written, the bytes, writes and states a burst of 30 saves leaves, and what handing a 300-call
  turn to run reviews costs the main thread, and writes the table to the file. Run with the same
  variable, the rendering test `typingAndSwitchingStayResponsiveWhileFourConversationsSave` writes
  typing and switching times while four conversations save beside it, as `<file>.responsiveness`.
  The benchmark asserts nothing about time and isn't part of `check`.
- Projects loading: `BOTCHU_PROJECTS_BENCHMARK=<file> swift test --package-path macOS --filter
  projectsBenchmark` times, with your `gh` login (read-only) and a temporary catalog, a first sync
  (until the list shows, and until everything is read), a relaunch (until the saved catalog shows),
  a check for changes and a full sync, three times, and writes the table to the file. It asserts
  nothing about time and isn't part of `check`.
- Account allowance end to end: `swift run --package-path macOS botchu-smoke --usage [account id …]`
  reads each account's usage through the same client as the inspector. It prints only the normalized
  usage fields, never raw CLI output or credentials. Muse makes its brief usage request; OpenRouter
  needs `OPENROUTER_API_KEY` in the environment. This is separate from the two-turn conversation smoke.
- Run reviews without tools: `swift run --package-path macOS botchu-smoke --review [account id …]`
  runs one turn on each account the way a run review does, asking the CLI to read a file outside its
  folder, and passes when the CLI answers without a tool call and without the file's word. Accounts
  whose CLI has no tool-free mode are skipped. It spends a little of each account's allowance and
  isn't part of `check`; run it after changing how reviews run a CLI.
- Telegram end to end: the gateway's tests use stand-ins for Telegram, so a real exchange is
  checked by hand, with your own Telegram bot: see
  [Checking it end to end](docs/telegram.md#checking-it-end-to-end).
- Smoke test after deploy: `macOS/install.sh` fails unless the installed app starts (launched hidden,
  found by its executable's path in `ps`, so a review copy running meanwhile doesn't count, and
  quit again unless it was already open).

## Deploy
- **Live checkout:** `Alexs-MacBook-Pro-92440` runs the app from `~/Desktop/WORKSPACE/BotChu`, which stays on `main` and is never edited; the app is installed to `~/Applications/BotChu.app`.
- **Secrets:** None in the repository or `.env`. The OpenRouter key and the Telegram bot token live in the Keychain, entered in Settings.
- **Deploy:** `scripts/deploy.sh`, run in `~/Desktop/WORKSPACE/BotChu`, fast-forwards it to `origin/main`, runs `macOS/test.sh`, installs the app with `macOS/install.sh` (which restarts BotChu if it was open and smoke-tests that it starts), and appends `<UTC time> <commit> ok|failed` to `.git/deploys`. Success: it exits 0, the last line of `.git/deploys` is that commit with `ok`, and `BotChuCommit` in `~/Applications/BotChu.app/Contents/Info.plist` is that commit. Nothing else deploys. Restarting BotChu stops every turn under way, its bots' tasks and sub-agents included, so deploy only when the owner asks and no turns are running. It refuses if `~/Desktop/WORKSPACE/BotChu` has local edits or commits; fix those through a pull request.
- **Recovery:** After a failed deploy, fix it (or revert the change) through a pull request and deploy again; `scripts/deploy.sh` retries, and reinstalls what is checked out when nothing new merged.
- **Scheduled jobs:** none.
- **Development:** On this Mac, in task worktrees of `~/Desktop/WORKSPACE/BotChu` (`.claude/worktrees/<type>-<slug>`, from `origin/main`). Changes reach the live app only by merging a pull request to `main` and deploying it.
