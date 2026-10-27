# BotChu

A minimal, open-source, native macOS app for persistent AI bots, in the spirit of Grok Bot and
[rakazo](https://github.com/elie222/rakazo). Bots are listed down the left; the selected bot's chat
fills the window. Each bot is driven by a coding-agent CLI that is already installed and signed in on
the Mac, and runs in its own workspace folder on this Mac. A bot can also work on tasks in your
GitHub repositories, in parallel, each in its own git worktree and a tab beside its bot's chat: on
this Mac, or on another computer it reaches over SSH. A task can also review a pull request.

## Scope
- Does:
  - **Workspace:** the left sidebar has **Inbox**, **Projects**, **Agents**, **Providers**, **Skills** and **Jobs**, followed by
    the bots, one row each, in sections (below); a bot's Home and tasks are the tabs beside its chat
    (**Tasks**). A bot's row says on its second line what it is doing ("Working on #113", "2 tasks
    running", its Home's activity, "4 tasks", or its account), with a small dot at the row's end,
    centred on it, for each of its conversations that isn't idle, in the tabs' colours, at most four,
    then +N. Selecting a bot
    shows the conversation it showed last. Opening a gallery keeps the selected conversation and unsent draft;
    turns that finish while a gallery is shown still show as news (a blue dot). In dark mode the sidebar
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
    once it is known to be active. The type filter (all projects, code or non-code) is remembered too;
    a repository without a readable `PROJECT.md` has no type, so it shows only under all projects.
    **Pull Requests** and **Issues** list the open ones across the repositories (up to 30 most
    recently updated per repository, saying so when there are more), with checks, review state,
    labels, author and any bot's task on them, filtered by repository or search. They cover the same
    repositories as the list, by the same status and type filters, which all three views show (#186):
    the repository menu, the counts beside their names (GitHub's totals) and the note about what
    wasn't read leave the others out, and a chosen repository narrows that further. A repository
    chosen before the filters left it out counts as all repositories until they cover it again. When
    the filters leave out everything open, the view says so and offers **Show All Projects**. The
    search matches an item's title, number, labels, author or branch. Selecting one opens
    it in the repository's sidebar, and double-click on GitHub; its menu reviews a pull request
    (**Review with**, **Review and Comment with**), continues it (unless it comes from a fork) or
    starts a task on an issue with a bot, opening New Task with it chosen, or opens the task already
    on it. They are read with one GraphQL query per ten repositories whose open work changed (below).
    An issue’s menu has **Archive Issue…** and **Mark Obsolete…** (#162). Both close it as **not planned**
    on GitHub, preserving its description, comments and link; it can be reopened on GitHub. After
    confirming, it leaves the open lists, counts and its sidebar page at once, before GitHub answers
    (#195); a sync meanwhile can't bring it back. Once GitHub has closed it, it leaves the saved
    catalog too, so a relaunch before then shows it again until a sync asks GitHub. Asking again
    while GitHub answers sends no second request. If GitHub refuses or is unreachable, it comes back
    (with whatever a sync read meanwhile), and an alert says why and offers **Try Again**; a late
    answer after another account signed in changes nothing. The archive menu beside Delete on an
    issue’s sidebar page offers the same actions.
    An issue's menu also has **Delete Issue…**, as its page in the sidebar has Delete (#154): after
    an alert naming the repository and number says it can't be undone, `gh issue delete <n> --repo
    <owner/name> --yes` deletes it on GitHub for good. It then leaves the lists, the counts and
    `projects.json` at once, without a sync (one under way that read it before doesn't bring it
    back), and the sidebar showing it goes back to its Issues. When GitHub refuses (it lets only a
    repository's admins delete issues) or can't be reached, nothing is removed and an alert says why.
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
    more), with their labels, checks and the bots on them, and the tables' menu; each opens in place, read with `gh issue
    view` or `gh pr view`: its description, labels and conversation, and a pull request's branches,
    checks, changed files and reviews. An open issue's bar has Delete (the trash), which deletes it
    as **Delete Issue…** does (above). An issue's **Fix with** starts a task on it with an agent, and
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
  - **Providers:** one table of CLI profiles, a row each, with their allowance windows in columns:
    the logo and name, with the CLI family below it, or what is wrong; the model groups the
    profile's limits cover (All models, Fable, Gemini, Claude & GPT), each named once, a daily
    window's saying so ("Images · Daily"); **5-hour** and **Weekly**, a meter per group in each:
    an 8-point bar of at most 250 points, with a tick for the share of the window gone by when its
    length is known and its reset is ahead within it (fill past the tick is use ahead of the time;
    the tooltip says both shares), the share used, the time left and when the reset is ("in 1d 10h",
    "Mon 5:00 PM": the time alone today, a weekday within six days, else the date), each in a slot
    of its own so they line up down the column, and "Reset at 5:40 AM" once a window has reset, until
    the next reading; **Credits & resets**, a line each for the money left under an OpenRouter key's
    spending limit, Codex's usage credits and its free resets of the limits (or that it has none),
    the amount brighter while there is some, and the soonest free reset's day when it expires
    within three days; and **Agents**, the faces of the agents set to the profile (four at most,
    then +N). Rows are 56 points, 74 with three groups; an OpenRouter key's limit is under Weekly
    whatever its reset. The columns have fixed widths for a compact, regular or wide table and
    Agents takes the rest; in a narrower window Agents goes first, then the meters' reset time and
    time left, which their tooltips keep. Provider sorts by name, 5-hour and Weekly by the row's
    highest share used. The heading says when the newest reading was made ("Updated 3m ago"), with
    **Refresh**, which checks every profile again within its own limit (Muse at most every five
    minutes); a row adds its age only when its reading is 10 minutes older than that. While all is
    well a row's second line is its family, and its plan when the CLI itself reports one (Codex's
    plan type: "Codex · Pro"; never worked out from allowance, prices or names, so Claude,
    Antigravity, Muse and OpenRouter rows show none); otherwise, in the warning colour, **Stale · 2h ago**
    (older than the background's interval, or a later check failed; its bars and shares are
    dimmed), **Usage unavailable** or **Command not found**, a button that shows why, with **Try
    Again** (labelled with the time the profile's limit allows it) and, for a missing command,
    **Change Command…**; a profile not read yet says Checking…, over empty tracks. Selecting a
    profile shows it on the right: its family and plan, its allowance as **Model & Usage** shows it, its
    **Connectors** (below), the agents set to
    it, each opening its Home, and its command, with Copy and Change… (Settings ▸ Accounts). A row's
    menu has Refresh, Copy Command and Change Command…; **Assign to Agent**, the local agents with
    those set to the profile checked, which moves the chosen agent's Home and the Tasks it starts
    afterwards to the profile (Tasks under way keep theirs; an agent whose Home is running can't be
    chosen until it is idle; a profile of another family clears its model and effort); and, for a
    profile added here, **Remove Profile…**, which asks first; agents set to a removed profile keep its CLI family and command.
    Readings are saved between launches (`usage.json` beside the bot index; usage fields only; one
    saved before windows had model groups takes them from its windows' titles) and kept current in
    the background, every 15 minutes for a CLI profile and hourly for Muse, and every 5 minutes
    while Providers shows, so it opens on the last numbers and updates them in place; a
    conversation's **Model & Usage** shows the same readings, with the same refresh limits. It
    searches by name or family. **New Profile** adds a named profile of Claude Code, Codex,
    Antigravity, Muse or Pi, with an installed command or wrapper and **Test Command**. Sign in through that CLI in Terminal; BotChu does not create its
    login. Added profiles appear in bot/task account pickers, host command overrides, and Settings;
    Codex profiles can also draw pets. Bots and tasks retain a copy of their custom profile’s CLI
    family and command across relaunches. Command overrides remain editable in Settings. Pi profiles
    use the shared OpenRouter key. Muse is checked with its existing brief request, at most
    hourly by itself.
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
    tables and fenced code use native block layouts; code has a Copy button. A reply's text is
    selected as one text, across its lines and blocks (#156): a drag or Shift-click selects across
    paragraphs, headings, list items, quotes, code and tables, a double click selects a word and a
    triple click a paragraph (in code, a line), ⌘A selects the reply clicked in, and ⌘C, Edit ▸ Copy
    or Copy in its right-click menu copies the selection in reading order, with a blank line between
    blocks, a line break between list items (a tab in for each level of nesting) and table rows, a
    space after an item's bullet or number, and a tab between cells. A click on a link opens it. One
    reply has a selection at a time (selecting in another clears it), and it stays as its reply is
    written; long replies select across their chunks. (SwiftUI selects within one `Text` only, so
    the reply's texts take no clicks, and a view behind them finds the text under the mouse from
    SwiftUI's layout of it and shows the selection. In a long reply's chunks each text gives its
    layout as it is drawn, as asking SwiftUI for them would lay every chunk out again with each
    delta.) Rich replies, in WebKit, select as web pages do. A table's cells stay on
    one line, each row ruled straight across whatever its cells hold (empty, or inline code), and a
    table wider than the chat scrolls sideways. Replies have soft rounded
    bubbles, as wide as their text up to the chat's width (a table, code block or rich reply
    fills it). Inline and display math use bundled KaTeX; Mermaid code fences display diagrams with
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
    A turn can be stopped: its CLI is interrupted, terminated 3 seconds later and killed, with
    what it started, 5 seconds after that. A CLI still running 30 seconds after it said its turn
    ended (Antigravity once printed its result and never exited, #145) is terminated, then killed
    5 seconds later; the turn stands as it said, with a note in its conversation. The
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
    where earlier ones go while they are grouped off the main thread. A reader at the end stays
    there as a reply streams, calls and groups grow, sub-agents report and the window or message box
    resize. Scrolling up by their own hand leaves it: then nothing that arrives moves them, until they
    scroll back to the end or click **Jump to Latest** (**Follow Live** while the bot works). Sending a
    message, and opening or switching to a conversation, takes them to the newest content from
    wherever they were.
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
    and memory (which stays in the bot's folder), where the task is and what it is. While a bot has
    an open task, its conversations are tabs in a column between the bot list and the chat: Home
    pinned at the top, then a **Tasks** heading with their count, **+** (New Task, ⌘T) and **«**
    (collapse), then the open tasks in the order they were opened, which scroll. A tab's first,
    prominent line is the repository it works in and its issue's or pull request's number
    ("BotChu #113"; a review's with an eye, a host's name after it); a task's second says what it
    is about: its summary, a label of three or four words saved when it started (see Quick tasks,
    below), or for a task without one its issue's title or a brief's words; its third says what it
    is doing, with a time on the right that is never cut off: making the worktree or starting (a
    violet ring), working (violet, what it is doing and its elapsed time, ticking each second),
    finished since it was last shown (blue, with its pull request), or its last turn failed (red,
    until its next turn starts); while idle (a faint ring), **Idle** and its last activity (2m, 1h,
    1d). Home's tab has two lines: Home, then its account, or its own turn's state. The rows are inset 8 points from both of the column's edges, and the selected
    one is a card with its edge all round, as the rail's selected tile is. Dots hold still; when a
    turn ends, its dot pops once (with Reduce Motion, it only crossfades). A click, **⌘1** (Home) to **⌘9** (the first eight tasks, in the Bot menu), ⌃Tab,
    and ↑ and ↓ while a tab has keyboard focus switch conversations. Hovering a task's tab turns its
    dot into a close button, unless its turn is running, and its tooltip says what it is about,
    then the repository, the issue, the machine and the shortcut; its context menu keeps the issue, pull request, branch,
    folder, Terminal, new-session and close actions. Closing the shown task shows the tab above it.
    The column is 240 points wide; drag its edge to make it 200 to 320, which is remembered. **«**
    or **View ▸ Collapse Tasks** folds it into a 56-point rail of tiles (a house for Home, each
    task's number, or a checklist for a brief, then **+**), with a dot in the corner of each tile
    that isn't idle and the tab's lines on hover; **»** or **View ▸ Expand Tasks** brings it
    back, and the choice survives a relaunch. The column also becomes the rail by itself while the
    chat beside it would be less than 600 points wide to read, and comes back when the window
    widens; as the chat's text never grows past 760 points, on windows of 1,680 points and wider
    the column takes only space the chat wasn't using. A bot without an open task has no column,
    and its chat is as before, with **New Task** in the toolbar (also ⌘T and the bot's menu); once
    it has one, New Task is the column's **+**. A task's chat opens with its repository and issue
    or pull request (`asieke/BotChu · Issue #113`) above the title as its headline, and its message
    box reads "Message 10x Engineer Bot about #113". Closing a task keeps its record, conversation and worktree;
    Home's status lists closed tasks to open again. Once its pull request merges, the agent removes
    its worktree (`git worktree remove`); if it is gone, the task's next message makes it again.
    A scheduled job's run is a task too (**Jobs**, below), in the bot's workspace rather than a
    repository's worktree: its tab names the job, with a clock (a clock on its rail tile), and while
    idle the time it was for ("Oct 24 at 9:00 AM", "· caught up", or "Run Now ·"); its chat opens
    with "Scheduled job · Scheduled for Fri, Oct 24 at 9:00 AM EDT · History" above the job's title,
    its message box reads "Message Product Fox about Morning triage", its menu has **Show Run in Job
    History** in place of the issue and branch, and its status sidebar names the job and the run.
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
    whichever conversation wrote them, and starts each in its own tab; `"agent"` hands the
    task to another bot (below). Home gets a receipt when a task starts, ends a turn or fails (with an Open
    link to its conversation), or can't start, and its next turn opens with a report on those tasks: their
    state, pull request and the start of their last reply. A new Home session also lists the open
    tasks. The bot's row shows a blue dot for each of its conversations with news.
  - **Sub-agents:** Home, tasks and delegated runs can call another configured bot with
    `botchu-subagent call`, or launch several with `spawn` and collect their handoffs with `wait`.
    `list` shows the available bots. Each child uses the called bot's identity, soul, memory, account,
    model and effort in a fresh CLI session; its Home conversation is separate. By default it works
    in the caller's workspace, on the same machine; `--workspace bot_home` uses the called bot's
    folder on this Mac. Shared-workspace delegates should own separate files or review without editing.
    The **Sub-agents** inspector lists each run as a compact row (its title, its bot, and its state in
    a word and a time) with the runs it delegated to beneath it, grouped by the turn that started
    them (older records by day). The turn under way comes first; a tree that ends completed or stopped
    with no failure folds into **Finished** at once, newest turn first, while a tree with a failure
    anywhere stays in view, open down to it, until Clear Run removes it. A row, or the chat's
    **Open**, shows that run's details in place of the list: its handoff, error or stop reason first,
    then the runs it delegated to, its transcript, brief and run facts, with Copy and Stop. Back
    (Escape, ⌘[) returns to the list where it was, opening Finished if the run moved there meanwhile.
    A row's context menu opens, copies, stops or clears it. Home also lists its tasks with runs, each
    opening its own list. These runs never add tabs. Stop cascades through
    descendants; callers must wait before finishing their turn. A run whose CLI said its turn
    ended but doesn't exit is ended as a turn's is (above), and its handoff goes back.
    Three nesting levels, twelve concurrent children and sixty-four delegations per root turn bound
    runaway fan-out. Interrupted records become stopped on relaunch. The helper needs Python 3 on
    each execution machine; SSH mailboxes are polled independently of CLI output. See
    [delegation protocol](docs/subagents.md) for lifecycle and persistence details.
  - **Tasks for other bots:** a conversation hands work to another bot in one of two ways, each
    with its own command, and an `@bot` mention only names the bot. "New task @bot" (or "hand this
    off to @bot as a new task") makes a **Task**: `botchu-task create --agent <bot> --repo
    owner/name --brief …` (or `--issue`, `--pr`, `--review`, with `--title` and `--machine`), from
    Home, a task (also on a host) or a sub-agent run. The Task is the named bot's own, a tab beside
    its chat, on its account, model and effort, in its own worktree, as if its Home had
    asked, and goes on after the asking turn ends or stops; nothing reaches that bot's Home but the
    usual receipts. It records which conversation asked (shown to the bot in its first message).
    The asking conversation gets a receipt that opens the Task, and the command prints the bot, the
    Task and whether it was created, its first turn started, or why not: pending, created, started,
    start failed, or failed (with nothing made, so it can be run again, or with the open task already
on that pull request's branch to continue in instead). The same command run again
    from the same conversation, also in a later turn or after a relaunch, returns the same Task
    rather than a second. "New subagent @bot" (or "delegate this to @bot as a sub-agent") is a
    **sub-agent run** (above): child work of the turn, in its Sub-agents inspector, with no tab of
    its own. A batch goes to one bot as one Task, whose turn spawns a sub-agent run per issue.
  - **Deliveries:** a bot hands the owner something on purpose with `botchu-inbox send` (the same
    helper under a third name, found from the conversation's environment as the others are): its
    `--purpose` (`needs-input`, a decision, access or information the bot can't go on without, with
    the one question it needs answered; `review`, work that needs the owner's judgment; `completed`,
    a meaningful finished outcome, looking at it optional; `fyi`, an important finding that needs no
    answer), a `--title`, a Markdown `--note` (or `--note-file`), `--file`s, which are copied as they are when
    sent (up to 20 MB each, so later edits don't change what the owner reviews), `--pr` and
    `--issue` links (`owner/name#n`, a number in the current checkout, or a GitHub URL), and an
    `--ask` (Needs input or For review) with `--choice`s and the `--recommend`ed one, which is
    offered in one click too. Every session's instructions ask for a 25–50-word note (the outcome,
    its context or recommendation, the next action), with the evidence in files and links, and keep
    routine starts, progress and minor notes out of the Inbox. It prints the delivery's ID; the
    same title sent again in the turn updates that delivery, and so does `--update <id>` in a later
    turn (only a delivery of the same conversation). An update that says something new is unread
    and out of Done again, its question unanswered; one that says nothing new keeps its state.
    Deliveries kept before purposes read as Needs input when they ask something, else For review.
    Sent from a sub-agent run, it is the delivery of the conversation at
    the top of the chain, crediting the sub-agent's bot (and its files are kept under that bot's
    name); `--credit <bot>` credits others. A delivery is kept in the sending bot's
    `.botchu/inbox/<id>/` (`delivery.json` and `files/`), works from a task on a host too (its files
    are fetched over SSH), and shows as a card in the sending conversation's chat after the turn's
    reply. A reply to it goes into that conversation through its queue like any message, marked
    with the delivery, and the bot reads which delivery it answers. Once the queue has saved it (it
    may wait there while the bot is busy), the delivery is answered and Done, and what the bot does
    with it shows in that conversation; its answer doesn't bring the delivery back out of Done, only
    a new delivery asks for the owner again. One unread state: reading a delivery clears its conversation's news dot,
    and showing the conversation reads what it delivered. What the owner did with each delivery
    (read, done, replied) is in `inbox.json` beside `index.json`. Every session's instructions
    describe the helper.
    While BotChu isn't the active app, each new delivery (not one updated in the turn) shows a macOS
    banner: the sender (with the bots it credits), the title, and the question or the start of the
    note as plain text, with the sender's pet still when it has a pet. It has a button per choice,
    which sends that choice as the reply word for word, and Reply, whose placeholder names the bot;
    clicking it brings BotChu forward on the delivery in the Inbox. An answer from a banner that
    launched BotChu is sent once the deliveries are read. BotChu asks for notifications the first
    time a delivery arrives, not at launch. The Dock tile's badge shows the unread deliveries.
  - **Inbox:** first under Workspace (⇧⌘I), with how many deliveries aren't Done, read or not (none
    shown at zero). A 392-point list
    (320 in a narrower window) in the tasks column's idiom: **Needs input** (Needs input deliveries
    not answered since they were sent), **Today**, **Yesterday**, then each earlier day, newest first, with
    **Done** collapsed at the end with its count. Reading never files a delivery as Done; only Done
    or a reply does, and Done means handled, never approval. A row has the sender's pet (a credited bot's on its
    corner), the sender, the conversation it came from (Home, a task or a job's run) and the time,
    the title (semibold while unread, with a blue dot), its purpose (**Needs input**, **For
    review**, **Completed** or **FYI**, in colour while it waits on the owner; **Working** while
    the bot works on a reply), **Not sent** for a reply the queue didn't take, and chips for what
    came with it. The row being read keeps its place until the owner leaves it; as in Gmail, J or ↓
    and K or ↑ move through the list (past a closed Done, never into it), and E files the one being
    read as **Done**, once (never one already Done), and reads the next one not Done; the keys do
    nothing with a modifier, while a reply or other text is typed, in a delivered page that has the
    keyboard, or with a sheet open. The reading pane shows the purpose, the repository and issue, the title, the sender with
    whom it credits, where and when; the note in the chat's Markdown; then a card for each file
    (a document's first 260 points, then **Show all**; an HTML page in a web view with its scripts on
    and the network off, links opening in the browser; an image; any other file) and for each
    repository's pull requests or issues, read from GitHub, each opening in Projects. A question's
    choices (the recommended one filled) sit above a composer that names where a reply goes; a choice (also ⌘1 to ⌘9) is sent as
    the reply, word for word, and once its conversation's queue holds the reply the delivery is
    Done and that conversation opens (Home, the task, opened again if it was closed, or the job's
    run). One reply goes at a time; one the queue can't take keeps the draft and the choices and
    says so, with **Try Again**. Answered, the question says when. The toolbar opens the conversation (**Open Home**, **Open
    Task** or **Open Run**, ⌘O) and files the delivery as **Done** (E, or ⌃⌘A while typing); its menu marks it read or
    unread and finds the copies and the originals. With nothing left to read it says when the last
    delivery came, with **Show Done**. In the sending conversation's chat, a delivery is a card with
    **Show in Inbox** and its question's choices until it is answered, each sent as from the Inbox,
    and a reply from the Inbox shows under a "Reply from your Inbox" line.
  - **Jobs:** an agent can own scheduled jobs, saved instructions it runs on a schedule, such as a
    morning issue triage on weekdays at 9:00. **Jobs** in the sidebar is one table of every agent's
    jobs: the job, its agent, its schedule and time zone, its next run, its state (on, paused,
    waiting or running) and how its last run went, filtered by agent, by state or by search. A row's
    menu runs it now (also a paused job, which stays paused), pauses or resumes it, stops its run
    (which leaves its schedule alone), edits or deletes it, or opens its history (also a
    double-click): its runs, newest first, each with the time it was for and the time it started,
    how late that was, how long it took, what it ran on and its transcript, live while it runs (its
    task's conversation, below, with **Open Task**).
    Opening Jobs or a history never runs anything. An agent's card in **Agents** counts its jobs
    (opening Jobs filtered to it) and its menu has **New Job…**; its status sidebar's **Activity**
    lists them under its tasks, with **New Job…** and **All Jobs**. The editor sets the agent (chosen
    already from an agent's own places, and fixed once the job exists), the account, model and
    reasoning effort its runs use (**Same as** the agent, as they are when each run starts, until
    others are chosen, from the same accounts and model and effort pickers as a conversation's; the
    efforts offered are those the chosen account and model take, and another CLI family clears the
    model and effort), title, instructions, how often
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
    its Home conversation, on the job's account, model and effort, else the agent's (recorded with
    the run), in its workspace; it never resumes Home's session or touches Home's queue, draft or
    receipts, and gets nothing written to it while it runs. Each run starts as a new task of its
    agent's (#146), in its **Tasks** beside Home: titled after the job and the time it was for
    ("Morning triage · Oct 24 at 9:00 AM"), with the job's instructions as its first message and its
    brief, its transcript live in the task while it runs, on the run's account, model and effort, in
    the agent's workspace (a job's run needs no repository, so no worktree is made); the task says
    which job and scheduled time it came from (see **Tasks**). Home gets no receipt of the task, only
    the job's own (below), and a finding or a failure also marks the task as news. Stop in the task
    stops the run, as Stop in Jobs does. A message written in the task while the run goes waits in
    its queue until the run ends, then resumes the run's session; from the owner's first message
    there the task is theirs. A job keeps one open task in Tasks, its latest run's: a new run closes
    the task of the one before, unless the owner wrote in it, it is shown, or it holds a draft or
    queued messages. A closed run's task is found in the job's history, whose rows open it (**Open
    Task**, or a double-click), as Home's **Open Run** does, rather than among Home's closed tasks;
    when the history lets a run go, its task goes with it (its record and conversation, never the
    workspace), unless the owner wrote in it, which then stays among the closed tasks. Deleting the
    job leaves its runs' tasks, as it leaves the tasks it asked for. Runs from before runs were tasks
    keep their transcripts in the history, and a run that never started (its agent's folder gone, or
    in a review copy) has only its reason there. A job's own choice is saved with it, and a
    job saved before jobs had one runs on its agent's. When its account is gone from Providers, or
    OpenRouter's catalog no longer lists its OpenRouter model, its runs use the agent's account,
    model and effort instead, never another provider, and the editor (which shows the choice as
    unavailable), the job's row, its history and the run's first line say so; it keeps the choice for
    when the account is back. A CLI's own models and custom IDs run as chosen: one the CLI rejects
    fails the run with its reason. A job never overlaps itself (a time due while its run waits
    or runs is recorded skipped, once however many); one agent's runs go one at a time, and wait
    (**Waiting**) for its Home turn, a turn of one of its runs' tasks or a sub-agent in its workspace
    to finish; at most two run at once. A run is stopped at its time limit (30 minutes by default)
    and counts as failed; three failed runs in a row pause the job, saying why. BotChu never runs one again on its own. A run
    asks for repository work as Home does, with a task request (which names the job), and BotChu
    starts the task when the run ends. A run has the helpers, mailbox and environment a turn has, as
    its task's (#170): it can call sub-agents, ask for Tasks, message remote bots and deliver to the
    Inbox with `botchu-inbox send`, whose deliveries are its task's (the owner's reply goes back to
    the task), their cards after its reply. Its mailbox closes when it ends, once the deliveries
    still in it (a helper that stopped waiting) are in the Inbox. Every run is kept, with how it was started (on schedule,
    caught up, or Run Now) and how it went: succeeded, nothing to report, failed (with what to do:
    sign in, wait for the allowance, fix the command, check the network or the disk), stopped,
    skipped or interrupted, and a line about it; the history keeps the latest 50 and always the last
    success. A run whose reply ends with `NOTHING_TO_REPORT` stays in the history and its task, with
    nothing marked as news, and nothing in the Inbox. A finding the run delivered nothing of itself
    is delivered by BotChu: its whole final reply, as its task's FYI delivery titled after the job, once
    (its ID is the run's). Until the Inbox has it the run keeps it waiting in `job.json`; a save that
    fails says so in the task and is tried again at each tick and launch. A finding, a failure or an interrupted run adds one receipt to its
    agent's Home, with **Open Run** (which opens the run's task), marked as news, which Home's next
    turn hears of; an empty reply counts as failed, not quiet. Before a run
    starts, its time is reserved in the job's `job.json`, in one save, so a timer, a wake or a
    relaunch never starts it twice; when that save fails, nothing starts and the job says why. After
    a quit or a crash, a run that was running is recorded interrupted (it may have done part of its
    work), which its task says, and isn't run again. Jobs are kept in their agent's folder, so they move with its
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
    job, where its schedule is up to and its runs, each with its task, whose conversation is the run;
    runs from before runs were tasks keep their transcripts in `runs/<run>.jsonl`),
    a log of every turn and job run (`logs/<date>.log`:
    the command, where it ran, how long it took, the exit status, any error and the CLI's error output), notes
    it couldn't save to memory yet (`memory-unsaved.json`, `shared-memory-unsaved.json`), the reviews of its work (`evaluations/`
    and `run-reviews.json`, below) and its
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
  - **Run reviews:** once a day, at the review time (04:00 in this Mac's time zone, unless you set
    another in Settings ▸ **Run reviews**), BotChu reviews each bot's work since its last review in
    one pass, in the background: every conversation, its Home and its tasks, with the sub-agent runs
    they delegated that ran as it, for what went well, what didn't, and whether anything should
    change in how the bot works. A turn's or sub-agent's end only extends its conversation's stretch
    of unreviewed work, from the last message reviewed (its cursor) to the end of its last finished
    turn, so nothing is reviewed twice and nothing between two reviews is missed: it builds nothing
    and adds no review, and the turn's receipt, the handoff, queued messages and switching
    conversations never wait for one. A sub-agent that ran as another bot joins that bot's review,
    never one of its own, and the caller's own turns are reviewed about the caller, so a lesson isn't
    saved to every bot that took part. The time and missed days come from the jobs' `JobSchedule`
    and `JobPlanner`, though a review isn't a job and isn't listed in Jobs: the jobs' 20-second check,
    a wake and a clock change make the day's reviews due, and a review time missed while BotChu was
    closed or the Mac asleep is due once, at the first chance afterwards, never twice for one day,
    whatever a change of the Mac's time zone or daylight saving does. Each bot has at most one review
    waiting: one that can't run before the next review time (its account busy, or out of allowance)
    takes the next day too, since its cursors haven't moved, and work left unreviewed for 7 days
    (from its end, or from the last **Retry** of its review) is skipped and counted as not reviewed
    in time. **Review now** in Activity reviews a bot's unreviewed work (in Home), or a task's alone,
    moving only that task's cursor, without waiting for the review time, under the same rules. Only
    work with signal is reviewed, as its transcripts show without a model call: a failed turn or
    sub-agent run (a handoff that couldn't be saved fails its run), a run the owner stopped, an owner
    message after a task's brief (in Home each message is a new request, not steering), 3 or more
    failed tool calls, 60 or more tool calls, or 45 minutes or more at work in one conversation's
    stretch. A day without signal asks no model: its cursors move, and it counts as without signal.
    Work still running when a review starts waits for the next one. A review runs on the bot's own
    account, model and effort, as its Home uses them, since one review covers runs that may have used
    several accounts: one at a time across all bots, once that account has been idle for a minute
    (no turn, sub-agent or scheduled job on it), as a new session with no tools at all, which the CLI
    itself enforces: Claude Code without its built-in tools (`--tools ""`), with every tool denied,
    no MCP servers, skills or commands, and nothing approved (`dontAsk`); Codex in its read-only
    sandbox approving nothing, without your Codex configuration (its MCP servers and plugins) or
    rules, with its shell, code mode, sub-agents, apps, browser and web search turned off; Muse in
    its empty preset, with its shell, writes and web tools off. Nothing bypasses permissions, and no
    review session is saved. A review that still reports a tool call is stopped at once and fails
    (**tool use**), keeping nothing. Antigravity has no such mode, and Pi's (`--no-tools`) hasn't been
    checked with a real run, so a bot on either isn't reviewed, spending nothing, and its work doesn't
    wait for a review that can't come. A review runs in an empty temporary folder (removed
    afterwards), without the delegation helper, at utility priority: at most 12 model calls a day per
    account, retries included, each review stopped after 5 minutes (its CLI interrupted, then
    terminated, then killed), with one automatic retry; an account out of allowance waits an hour. A
    review is neither a turn nor a sub-agent, so it is never reviewed itself, and BotChu's turn log
    records it as a "run review", without lines that look like secrets. It sees one snapshot of the
    day, of up to 48,000 characters, read from the saved transcripts and sub-agent runs off the main
    thread as it starts, grouped by conversation, those with signal first and newest first in each
    group. Each conversation has a header line (Home or the task, its repository and computer, open or
    closed, and its signal), and each turn and sub-agent run one (how it ended, its tool calls and
    failed ones, and its time: a finished turn isn't proof the work succeeded; a stopped run is
    neither a failure nor finished work, and isn't continued). Header lines are never left out, long
    passages are shortened first, and a conversation without signal gives its header lines alone.
    Under them come the brief, the owner's messages and corrections, the bot's replies and handoffs,
    and each tool call with its exit code (and the end of a failed one's output), each labelled across
    the day so the review cites them as evidence. Lines that look like secrets are left out before
    anything is shortened; text from the work is indented and BotChu's own tags in it are
    neutralized, so it can't pose as a label or end the snapshot, and only the labels BotChu wrote
    count as evidence. With it come the bot's instructions and memory as they are now, the shared
    memory and `TEAM.md`, all as evidence rather than instructions. The review is asked for lessons
    that hold across the day's work, a mistake repeated in several conversations being one pattern,
    and to correct or remove an existing note rather than add a near-duplicate. The result is **No
    durable change**, **Memory updated**, **Change proposed**, or a failure, with sign-in, allowance,
    the review itself, tool use and saving told apart. BotChu applies at most three changes a review,
    so three a bot a day, each citing evidence, verified, general and one line of plain text, and only
    to the bot's own `MEMORY.md` (which sessions read as data, not instructions), through the same
    writer as **Saving memory** (above): notes, and corrections and removals of a note that is there
    exactly, once (never one that merely contains it). Every change to `INSTRUCTIONS.md` is a proposal
    for you, as are the shared memory, `TEAM.md`, a bot that delegated a run, the repository's own
    documents (which change through its pull requests; a review never edits a repository), an
    unverified hypothesis, a change without evidence, a correction of a note that has changed since,
    and any line that could loosen a safeguard, widen what the bot may do, or name a web address or a
    command to run. A change of more than one line, or with Markdown or HTML structure (a heading,
    list item, quote, table row, code fence or tag) or control characters, is left out before
    anything is written, as are one-off details; secrets, transcripts and command output are left
    out, as in memory, and a secret is never quoted; and a note memory lost while the review ran (a
    correction or `Forget:`) isn't saved again. Each review is saved at every step in
    `.botchu/evaluations/<id>.json` in that bot's folder, and the work waiting for its next one, each
    conversation's stretch with its cursor, in `.botchu/run-reviews.json`, without lines that look
    like secrets, so a relaunch neither repeats one nor applies one twice (quitting stops a running
    review, which runs again after the next launch); the newest 50 a bot are kept, and any that called
    the model in the last 24 hours, which the daily limit still counts. Reviews of single runs still
    waiting from before daily reviews fold into their bot's next daily review at launch, without a
    model call: each conversation's stretch starts before its oldest one. Finished ones stay as they
    are. A change that couldn't be saved stays with its review, whose **Retry** saves it, rather than
    waiting with the conversations' notes, and conversations' notes still waiting for the file are
    saved first, on their own. **Activity ▸ Run reviews** in the status sidebar starts with one line
    saying what the reviews are doing, such as "Next review at 04:00 · 3 conversations with unreviewed
    work", "Waiting · Claude Personal is busy", "Waiting · daily limit, next at 14:05", "Reviewing on
    Claude Personal…" or "Up to date", with **Review now** while there is unreviewed work and no
    review of it waits. Below it come rows only for reviews with news (**Memory updated**, **Change
    proposed** or **Failed**), each naming its day and the conversations its changes cite, and
    opening to its summary, what worked and didn't, the evidence it cited, every line it added and
    removed (read from the file just before and just after the save, so a review that wrote anything
    never shows as no change, and no copy of the file is kept), its proposals (with Copy) and what it
    left out, with **Revert**, which undoes each of its changes only where the file still holds
    exactly what it left, in the same section, and lists any you have changed since as not reverted,
    keeping your edit; and **Retry**. One line counts the week's others: "This week: 5 days with no
    change · 2 without signal · 0 not reviewed in time". Home's covers all the bot's work, and says
    so; a task's lists the reviews that covered it. Home gets a note for a change made or proposed,
    and for a failure once per kind until a review succeeds; reviews that change nothing, or find no
    signal, stay quiet. Saved notes reach the bot's next new session, never a running one; what a
    conversation asks to remember (`<remember>`, above) isn't a review, and is still saved at once.
    Settings ▸ **Run reviews** turns them off and sets the review time; they are on by default, since
    the CLIs enforce the tool-free sessions and only memory notes change by themselves, and they spend
    the bot's allowance. Only the installed app runs reviews, never tests or review copies.
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
    in a rounded bar with a raised selected segment: **Activity** (Home's closed tasks, run reviews of all the bot's work and conversation stats; a task's, the reviews that covered it), **Sub-agents** (delegated work),
    **Model & Usage** (account, agent, model, reasoning and allowance), **Session** (the CLI session
    and workspace controls), and **Memory** (instructions, personality, memory, the team
    playbook and skills). Hover for tab names, or
    focus the bar and use Left/Right arrows. The selected area is remembered across conversations
    and launches; its data always belongs to the shown Home or task. The character, tabs and bottom
    actions stay visible while the selected area's content scrolls. Home's Activity lists only its
    **Closed tasks** (collapsed at first, with their count), each to open again with a click: the
    open ones are the tabs beside the chat. Home keeps Edit and New Session;
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
    its own login, in a temporary folder, outside bot conversations. **Model & Usage** shows the
    reading Providers and the background checks keep (every 15 minutes, hourly for Muse), so opening
    it, or another conversation while it shows, gives the last numbers at once, with when they were
    read, marked stale (older than that) or failed as on Providers, and a check made anywhere
    updates them in place. Each window's reset is the time left and when ("Resets in 1d 10h,
    Monday at 5:00 PM"), and under the windows a hairline, then the account's usage credits, its
    free resets of the limits and when they expire, when its CLI reports them (Codex). The area checks the account itself only when it has no reading or one
    that old, after turns while it is open, or with Refresh (at most once every 30 seconds).
    Muse needs one brief `Reply with OK.` request to learn its allowance: it uses isolated,
    temporary host state, checks hourly automatically, and at most once every five minutes after
    a turn or with Refresh. This spends a small amount of its allowance. Muse reports the
    reading from its answer on, often only when that turn winds down after it, so the check keeps
    asking until then (within 90 seconds). OpenRouter shows the
    saved key's spending allowance and any reported shared budgets, with resets at midnight UTC;
    an uncapped key says so, without claiming unlimited account credits. Saving a different key
    clears its previous readout. Failed checks retain the last successful reading marked stale;
    an expired window hides its old percentage until a new reading arrives. CLI output and
    credentials are not written to disk by BotChu; of a reading, only its usage fields are
    (`usage.json`).
  - **Connectors (#183, #212):** under Usage, **Connectors** shows the connectors the conversation's
    CLI profile already has, as its provider reports them, for the conversation's profile, command
    (a host's own included), folder and host; BotChu never installs, signs in or configures one.
    On this Mac a Claude Code or Codex profile is checked in the conversation's folder when the
    section shows and the last check is over an hour old, or with Refresh (at most once a minute),
    each within 20 seconds: `claude mcp list` (which health-checks the servers it may connect to,
    claude.ai connectors and plugins' among them) or a `codex app-server` that asks for every
    page of `mcpServerStatus/list` and a refreshed `app/installed`. Neither starts a model turn or
    calls a connector's tool. The card is **Enabled for this profile**: a check of the profile,
    not of the conversation's session. On a host, Claude Code's report from its turn's start
    (`system/init`) is **Connected at last report**, an earlier session's in the same profile,
    command, folder and host **Last session report**, and otherwise **Not reported yet**; Codex
    there is **Not checked on <host>**, and Antigravity, Muse and Pi **Discovery unavailable for
    <CLI>**. Unknown is a sentence, never an empty list; **None** only when a report came back
    empty. Each entry is a **Connection** (a service), a **Tool** (Computer Use) or **System**:
    the provider's own, matched exactly (Codex's link, node_repl and `cua_repl`, its computer-use
    runtime, servers, its `codex_apps` bridge and its own apps, `connector_openai_…`, such as
    Hotline and Pets); anything else stays a connection. The card
    lists first what needs you, **Needs sign-in**, **Failed** or **Pending approval**, each with its
    action; then connected services as chips (twelve, then **+N more**); **Off**, **Not confirmed**
    (not started, starting, or an app with no callable tool) and **Configured · not checked** (a
    server that lists nothing outside a turn: neither working nor broken) as rows with a symbol
    each; then **Tools**. System entries are left to Providers. **Manage** opens Providers on the
    conversation's profile and its exact folder and host.
    In Providers, the selected profile's **Connectors** names the **Folder** it is checked in: the
    one a conversation's Manage chose, else the first Home or open task on this Mac set to the
    profile, else the home folder; its menu lists those (and a host's, by name). Never another
    folder's, profile's, command's or host's check. Below are **Connections**, **Tools** and a
    folded **System** (remembered when opened), each entry with its state and, where it needs one,
    the action its provider supports: **Sign In…** runs the CLI's own `mcp login <name>` (the name
    as configured, such as `claude.ai Slack`) in Terminal, as the profile's command in that folder,
    each word quoted; **Open in Terminal** opens the profile's CLI there (its `/mcp` approves or
    turns on servers); **Manage** opens the provider's settings in the browser
    (claude.ai ▸ Customize ▸ Connectors, or ChatGPT's settings), with whichever account is signed
    in there; **Retry** checks again. **Manage on claude.ai** (or **Open ChatGPT Settings**) and
    **Open in Terminal** are below. A host's CLI is never run from here. After any of these, every
    folder's list for that profile on this Mac is marked stale (sign-ins are the profile's), and the
    folder it was for is checked again when BotChu is in front again; the others when next shown.
    Checks are saved between launches (`connectors.json` beside the bot index, under opaque keys:
    names, states, tool counts and BotChu's own error sentences, never commands, paths, endpoints or
    the CLI's errors), so a relaunch shows the last list without checking. A list over an hour old,
    one whose check failed (kept, with the error) or one invalidated by management is **Stale**
    while it is checked again. One check per scope runs at a time, even one overtaken by
    management: its answer is dropped, the list before it stays meanwhile, and a check asked for
    while it runs (the return, a Refresh, showing the folder) follows it once. Refresh during a
    current check starts none. A changed command or removed profile drops its checks, any queued
    check and a return still awaited, so nothing runs for it.
    Session reports stay in memory, per conversation.
  - **Settings:** a page of the main window, beside the sidebar, opened by the sidebar's gear,
    ⌘, or BotChu ▸ Settings…, like a gallery: the conversation shown keeps its tab, its draft and its
    turns. Its nine pages (General, Accounts, GitHub, Hosts, Run reviews, Pets, OpenRouter, Telegram,
    Remote queue) are in a rail that marks a page needing you (a missing command, an unsaved key, a
    service on), which becomes a menu in the page's title when the page is under 720 points wide.
    It opens on the page last shown, and links elsewhere (Change Command…, GitHub Settings,
    Connection Settings…) open their page. Preferences save as you change them; the OpenRouter key
    and Telegram token save only with Save, and a key typed and not saved stays while you change
    pages, until you leave Settings. **GitHub ▸ Test Connection** checks that `gh` is available and can authenticate to
    github.com, then shows its version and signed-in username. Connection failures give install/login
    guidance without displaying credentials. Settings also contains the bots folder, the repositories folder, the hosts and where you chose to work
    on repositories, each account's command, the Codex account that draws pets' stills, the
    OpenRouter model that animates them (with its cost per pet), the OpenRouter API key (Keychain)
    and default OpenRouter model, whether each bot's work gets a daily run review and at what time, and the Telegram gateway (below).
  - **Quick tasks:** Settings ▸ General ▸ **Quick tasks** picks the profile and model of small
    background asks: for now, each new task's summary, the label of three or four words on its
    tab's second line. It is **Off** until you pick a profile (Claude Code, Codex or Muse, which
    BotChu can run without tools); picking one starts on its family's smallest model (Haiku, GPT-6
    Luna, Muse Spark), which you can change. Each task started afterwards is summarized once, in the
    background (its turn doesn't wait), from its issue's or pull request's title once looked up, else
    its brief, in a fresh session with every tool turned off by the CLI itself, in an empty folder,
    as a run review is, on that profile's allowance and never another's, and logged in its bot's
    turn log as a "task summary". A reply that isn't a label of three or four words, a failure, or
    none within 90 seconds leaves the task named as before. The summary is saved in its
    `task.json`; nothing is asked at launch, while drawing tabs, or for tasks from before.
  - **Remote queue bots:** choose **Remote queue** in New Bot to message an agent such as Danny
    on its own computer. BotChu serves an authenticated HTTP queue, while the remote runtime
    polls for messages and posts complete replies or errors into Home. Documents go both ways: attach
    them with +, a drop or a paste, and the remote runtime's files show under its reply, opening in
    their apps. It can have a pet like any bot's, moving in its status sidebar too. Other bots message it with `botchu-message send`, and
    its answer comes back into the asking conversation as a message from it, starting a turn; it only
    answers, never starts a conversation itself. The queue survives relaunch,
    retains replies without truncation, and deduplicates retry acknowledgements. This bot has no
    local workspace, CLI, account/model controls, tasks, jobs or sub-agents. Settings ▸ **Remote queue**
    controls its address/port, generated Keychain token and connection status; the sidebar shows
    whether a poll arrived in the last two minutes and how many messages wait, or **Tailscale off**
    when the queue is served through Tailscale and Tailscale is disconnected on this Mac (BotChu
    never reconnects it). See
    [Remote queue setup and protocol](docs/remote-queue.md).
  - **Telegram:** an opt-in gateway, in Settings ▸ **Telegram**, lets you message bots from
    Telegram through a Telegram bot of your own (made with BotFather) while BotChu runs on this
    Mac. There is no server or webhook: BotChu asks Telegram for new messages itself (long
    polling). The bot token is kept in the Keychain and never goes into a log, a conversation or a
    prompt. Only the private chats listed there reach BotChu, each reaching the bot chosen for it,
    in its Home (not its tasks). Anything else (another person, a group, a bot) is ignored before
    BotChu reads it or says anything, and Settings lists the chats it refused since launch, with
    **Allow** for your own. A message goes into the Home through its queue, as one typed in BotChu
    does, so it resumes the Home's CLI session and waits behind a turn under way (the chat is told).
    While a turn works, Telegram shows "typing…". When it ends, a concise digest of its final answer
    goes back as readable plain text, keeping the result, caveats and decisions; progress chatter
    and raw tool/log output stay in BotChu. `/details` retrieves the complete assistant reply one
    page at a time, without another turn. Failed, stopped and incomplete turns say so and give a
    next action, without exposing raw errors. It takes text only: photos, files
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
    offset into it (`TranscriptViewport.swift`), when the chat keeps its reader at the newest content
    (`ChatPin.swift`), the identity, instructions,
    team playbook, memory, skill catalog and recap that open a session (`BotContext.swift`), the editable Markdown
    files of a bot and of every bot (`BotDocument.swift`), account allowance parsing and native queries,
    with each window's model group and length, and what Providers makes of a reading: its windows by
    group, each reset as the time left and when, the credits and resets, what a row's second line
    says, and how its columns and meters share the table's width (`ProviderUsage.swift`, `ProviderUsageClient.swift`) with a throttled cache,
    saved between launches (`UsageCache.swift`), per-conversation pending-message delivery, keeping a follow-up the CLI
    took until a saved transcript holds it (`MessageQueue.swift`, saved in that order by
    `Store.swift`), how tall the message box is for its draft and how far its text may scroll
    (`ComposerLayout.swift`), what
    the status sidebar shows about a bot, from a summary of its thread kept as the thread grows, and
    its `MEMORY.md` (`BotStatus.swift`), what a conversation's tab and its bot's row say: its state,
    the tab's lines, the row's dots and subtitle, and when the column folds into the rail
    (`ConversationTabs.swift`), a new task's summary on the Quick tasks profile: what it is made
    from, its prompt and which replies are kept (`TaskSummaries.swift`), replies' parsed Markdown, cached by their text within a
    budget of bytes (`MarkdownCache.swift`), and parsed off the main thread as they are written, one
    revision at a time for each reply (`MarkdownPreparation.swift`), a reply's text as it is selected
    and copied: its texts in reading order, what goes between them, words and paragraphs
    (`ReplyText.swift`), and where their lines and glyphs are drawn, for the place under a point and
    what a selection covers (`TextLines.swift`), pets: the activity a tool call means
    and the clips that show it (`Pet.swift`), making a pet: its poses and clips, the Codex prompt
    for the stills, the OpenRouter request and job, the cost estimate, the manifest and install
    (`PetVideo.swift`), scheduled jobs: their schedules in their own time zones, runs, history and
    storage, what is due, a run's context and how it went (`Jobs.swift`), and the scheduler that
    reserves a time before its run starts, makes runs wait, records how they end and recovers after
    a quit (`JobEngine.swift`), the task a job's run starts as, what it says of its job and time,
    and which runs' tasks close or go (`JobTasks.swift`), tasks: the task, its title
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
    coalesced refreshes, and deleting an issue with `gh` (`ProjectSync.swift`), a repository's open issues at a glance as a task's
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
    again, and holds what is written back. A delivery to the Inbox (`botchu-inbox send`) goes through
    it too: `Inbox.swift` reads and checks the request, keeps deliveries and their copies in a bot's
    folder, what the owner did with them (`InboxState`), the list's groups (`InboxList`) and a reply's
    prompt (`InboxReply`); the app's `InboxModel` takes them in and sends the replies, one at a time.
    `DeliveryBanner.swift` makes a delivery's banner (its text, buttons and category, the newest 20
    categories kept registered) and reads a click back into a reply or "show it"; the app's
    `InboxNotifications.swift` (`InboxNotifier`) posts banners, answers clicks and keeps the Dock
    badge through a `BannerSystem`: the notification center in BotChu.app only, a stand-in in tests.
    What replies ask to remember (`MemoryNotes`, in `BotContext.swift`) is saved to memory files
    by `MemoryWriter.swift`: one save at a time, read back to check it held, with notes that wait
    and are tried again. Run reviews are in `ReviewStretch.swift` and `RunEvaluation.swift`: each
    conversation's stretch of unreviewed work and its cursor (`ReviewStretch`), the signal gate over
    a stretch's messages and sub-agent runs (`ReviewSignals`), the daily review time and missed days
    through `JobSchedule` and `JobPlanner` (`ReviewTime`), the day's snapshot read off the main actor
    (`ReviewDay`), the prompt, reading its reply, which changes are applied and which are proposals,
    the saved record, the evaluator (`RunEvaluator`: work handed over, one waiting review a bot, the
    idle gate, the 7-day skip, limits, retries, relaunch and the upgrade from reviews of single runs,
    `waitReason` and Activity's summary line), applying through the writer
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
    of scheduled jobs, `JobRuntime.swift`, and handing finished turns and runs to the daily run reviews, `Evaluations.swift`),
    `Sidebar/` (workspace destinations and a row per bot, and the sections' menus and naming alert, which Agents shares), `Library/` (Projects with its repository sidebar, Agents grouped by section, Providers, Skills, and Jobs with its history), `Chat/` (a bot's conversations as tabs beside its chat, the column, its rail and their status dots, `ConversationTabs.swift`, messages, the activity cards and their density, the shown part of the transcript and the rows of it laid out, with the scroll view's watcher that keeps the reader's row in place, tells their own scrolling from the chat's and keeps a pinned chat at its end, `ChatScrollProbe.swift`, rich replies' web views and the pool that keeps them, selecting a reply's text across its blocks, `ReplySelection.swift`, and the composer, whose image-taking writing area the report and New Task sheets share, with `@` and `#` completion in the chat's alone, `MentionCompletion.swift`), `Inspector/` (the
    status sidebar, a bot's and a task's, with a bot's jobs and its run reviews, and a task's repository's open issues), `Editor/` (the bot, Markdown, New Task, job and report sheets), `Settings/` (the
    in-window Settings page with its rail and pages, with the hosts, Telegram and run reviews), and
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
    file, the four-request limit, and a deleted issue leaving it at once, also while a sync that read
    it is under way, or staying when gh refuses, with why); and hosts: their `ssh` command lines, where a repository is worked on, clones,
    worktrees, reviews and turns on a host through a stand-in `ssh` that runs here, and notes kept
    from a remote task; memory: #88's Home sequence (a routing preference saved in the turn that
    agrees, and recalled by a fresh session), what is left out, bot or shared scope, repeats,
    corrections and forgets, concurrent saves, and saves that fail, wait (also across a relaunch)
    and are tried again; reports: their titles, app state, the size of their window's screenshot, and filing (with attached images) through a stand-in `gh`;
    output parsed off the main thread and delivered in batches, a CLI's end (#145: one still
    running after it said its turn ended is ended with its turn standing, one that takes input only
    once its input is closed, one that carries on is left alone, and Stop kills one that ignores
    SIGINT and SIGTERM, with a process it started), thread summaries, the Markdown cache
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
    kept as rows above it change, are forgotten or move; when the chat keeps its reader at its end
    (only their own scrolling up leaves it, not a bounce; back within 40 points, or sending, opening
    or Jump to Latest from anywhere, pins it again); the sidebar's sections of bots, and searching them; follow-ups the CLI
    took, kept through a transcript that can't be saved and a relaunch, in Home and in tasks;
    conversations' files with a line that isn't JSON, an unknown role, or no readable text, kept
    before the next save, also in a queue going through a relaunch; saving off the main thread: each
    file's writes in order and different files' side by side, newer states taking the place of waiting
    ones, repeats skipped, quitting's wait, a deleted bot's folder never made again, a sub-agent's end
    never written behind another's, and the conversation's guarantees above with writes and the CLI's
    messages interleaved and each write failing in turn; a turn handed to run reviews as a stretch
    of work, building nothing; a section change or a new
    bot while `index.json` can't be saved, then the retry and a reload; how tall the message box
    grows and how far its text scrolls; each account's allowance, with Muse's check through a
    stand-in `muse serve`: a reading that comes long after the answer, or announced while a read is
    answered empty, and none at all; connector discovery: Claude Code's `mcp list` and init and
    Codex's app-server, from captured samples, every page, an older Codex, late checks from
    another conversation, stale and empty lists; connectors' categories, actions and Terminal
    handoffs (quoted, run in a shell), saved checks by opaque key across a relaunch, invalidation
    after management and late answers it overtakes, a handoff and return during a suspended check
    (never two at once, one fresh check after it), nothing run for a removed profile or changed
    command, and Providers' folder, Manage's scope and the folded System (#212); Model & Usage showing the reading the background keeps,
    checking only one missing or as old as its interval, and Refresh's limits; Providers' model
    groups, time left and reset times, credits and free resets with their expiry, a row's status by
    exception, and the widths of its columns and meters; skills: their frontmatter, finding and making them, which a
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
    empty and failed results; a job's run as a task: in the agent's workspace on the run's account,
    model and effort, named after its job and time, what its tab and context say, the earlier runs'
    tasks a new run closes unless the owner took one over, and those that go with the runs the
    history lets go; a task's glance at its repository's open issues: GitHub's count
    whatever the preview and the read list hold, pull requests left out, loading, not read,
    unavailable, zero and kept after a failed read, and another repository's answer never showing
    under the one switched to; and run reviews, with stand-in reviewers (no test
    runs a real review): a stretch and its cursor, so that nothing is reviewed twice or missed; the
    signal gate (failures, stops, steering, failed tool calls, tool calls, time, Home's messages not
    steering); the review time once a day, missed days, time zone and daylight-saving changes; a
    review folded into the next day's, the 7-day skip and Retry restarting it, the idle gate, Review
    now of a task moving only its cursor, a sub-agent run reviewed about the bot it ran as, a day
    without signal asking no model, the upgrade from waiting reviews of single runs, the summary
    line and the counts; 35 runs a day across conversations staying at one waiting review a bot and
    one model call a day; the bounded snapshot of a day, grouped by conversation with every header
    line, and labels and tags in the work's text that can't pass for its own, handing work over
    without waiting, one review despite repeated ends and relaunches, a review cut short by quitting, no-change outcomes, which
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
    Markdown editor sizing and Save/Cancel, collapsing status sections, a bot's tabs beside its
    chat (a click, the close button on hover, **+**, « and », the arrow keys, ⌘1 to ⌘9, the rail at
    the narrowest window and by the owner's choice, light and dark) and its row in the bot list,
    the sidebar's sections of bots (their menus, the alert that names them, collapsing and revealing, and changes that can't
    be saved, shown until Try Again or quitting saves them), Agents grouped under them and editing
    them with the same menus and alert, inspector tab navigation and
    restored selection, conversation-scoped allowance reads that show the background's reading
    instead of checking again, automatic task branch creation, the
    main window's layout at its narrowest, galleries that preserve conversation state, the project
    sidebar's tabs, details and fan-out tasks, deleting an issue from the Issues table's and the
    sidebar's menus and its detail (confirmed first, through a stand-in `gh`, and refused), custom profile persistence, the Providers table's
    columns and its 56- and 74-point rows in every state, from wide to its narrowest, sorting by
    Weekly, the selected profile's sidebar, a problem's popover, and removing an added profile from
    its row's menu after confirming, provider logos in both
    appearances and in account menus, the report
    sheet, with a stand-in screenshot (taken of its window before the sheet opens, removed, not
    taken again on a retry, new for the next report, and a report without one when it can't be
    taken) and a real one of a test window through ScreenCaptureKit, filing with a stand-in, images pasted with Edit ▸ Paste into the composer, the report
    and New Task (through a stand-in for the general pasteboard, so no test touches the clipboard)
    and what pastes as text instead, New Task starting a task from a project and a brief with an
    image, the activity chat at every density, light and dark and at its
    narrowest, a chat that follows new content only for a reader at the bottom; a message sent from the
    end or from far up that lands in view and stays there through the queue, the turn's preparation
    and its reply; a chat at its end that stays there as a reply streams, calls group live, a command
    and a sub-agent's card arrive and the message box and window resize; a reader who scrolled up
    with the wheel keeping what they see as a turn goes on and the window resizes, until they scroll
    back down or click Jump to Latest, and back at the end after switching away and back; a long
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
    queue alone, and deleted with its agent, a job's run as a new task in its agent's Tasks column
    with the job's menu, its conversation the run's, opened from Home's receipt, taking the place of
    the run before, kept open once the owner writes in it (resuming the run's session) and gone with
    a run the history lets go, a scheduled run's deliveries to the Inbox as its task's (its own, one
    its helper stopped waiting for, its finding as BotChu's report, none when quiet, a report the
    Inbox couldn't take tried again on a tick, the owner's reply back in the task, its mailbox
    closed), a sub-agent's handoff and a task's receipt that
    don't wait for run reviews, which review each bot's own work on its own account, Activity's run
    reviews (the summary line, news rows and counts line, in light and dark, and Review now) and
    the review time in Settings, a task's Activity listing its repository's open issues:
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
    (or `projectSidebarShowsTabsDetailsAndFanOutTasks`, `issuesAreDeletedFromTheirMenuAndDetailAfterConfirming`, `providersTableShowsWindowsInColumns`,
    `activityChatRendersGroupsCardsAndLiveWork`, `agentsGroupsAgentsUnderTheSidebarsSectionsAndEditsThem`,
    `jobsBelongToTheirAgentAndReachHomeOnlyAsReceipts`, `aJobsRunIsANewTaskInItsAgentsTasks`, `taskActivityShowsItsRepositorysOpenIssues`, or
    `conversationColumnFollowsTheWindowAndTheOwnersChoice`)
    to render isolated gallery/table (sidebar, chat, tasks' column and rail, or Agents' sections, wide and narrow) screenshots
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
  --disable-reminders --no-session-log`, on the reviewed bot's own account. None runs on Antigravity or Pi.

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
- While editing, run the suites the change touches: `swift test --package-path macOS --filter <Suite>`.
  Rendering suites still need the shared window-test gate.
- Before a push, `scripts/test.sh --fast` checks shell syntax and renderer checksums, builds debug
  tests, and runs every Core test. It does not need window focus or the gate.
- Each step prints elapsed time and the load average before and after. xUnit reports and logs stay
  in `macOS/.build/test-results/`; a run prints its 20 slowest tests and a failed run prints a command
  selecting only the failed tests with `--skip-build`. If an unrelated test fails, rerun only that
  test a few times; if it passes, name it and the load average in the PR instead of rerunning the
  full suite. A changed test still needs a demonstrated fix.
- `scripts/test.sh` runs everything: shell syntax for every script, `macOS/test.sh` (the unit and
  rendering tests) and `macOS/build.sh` into a temporary folder. There is no CI: the tests need a Mac
  with full Xcode. Debug/release test builds and the app build finish before any gate request. Core
  and release tests run outside the gate; only the prebuilt window tests and isolated native-click
  test acquire it. Run the script directly: do not wrap a full run in another gate request.
  The script installs the versioned `scripts/coord/` gate to `/tmp/botchu-coord/` when absent or changed,
  preserving its lock and run folders. Other repositories retain the same `start`, `wait`, `status`
  interface. BotChu's windowless wrapper is recognized by ancestry; unwrapped window tests and
  other repositories' tests still block the gate.
- Debug tests use `macOS/.build/`, release tests with testability use `macOS/.build/release-tests/`,
  and the app uses `macOS/.build/app/`. Each keeps its own build manifest: on Xcode's build system,
  even a debug test build can invalidate optimized Core when it shares the app's scratch directory.
  `RunEvaluationTests` runs only in release in the full tier; the fast tier keeps running it in debug.
- A full pass on a tree that stayed clean and unchanged records `<tree> <commit> <UTC time>` in
  the shared Git directory's `test-passes`. Worktrees and merge commits with that same tree share
  the result; a dirty tree or an edit during testing cannot receive a receipt.
- `macOS/test.sh` requires every test bundle to finish and rejects explicit failure summaries,
  even if SwiftPM returns success. The native-click test of the tasks' column runs in its own process because
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
  Task or Settings instead (`BOTCHU_TASK_REPO=<owner/name>` picks New Task's repository;
  `BOTCHU_SETTINGS=<page>` picks Settings' page: `general`, `accounts`, `github`, `hosts`,
  `run-reviews`, `pets`, `openrouter`, `telegram` or `remote-queue`).
  `BOTCHU_OPEN=projects`, `agents`, `providers`, `skills` or `jobs` opens that workspace screen;
  with `projects`, `BOTCHU_PROJECT=<owner/name>` shows that repository's sidebar, and
  `BOTCHU_PROJECT_TAB=issues` (or `pulls`, `overview`) with `BOTCHU_PROJECT_ITEM=<number>` opens a
  tab and an issue or pull request there, read with your `gh` login.
  `BOTCHU_OPEN=memory` or `soul` opens the selected bot's Markdown editor.
  `BOTCHU_INBOX=sample` gives the Inbox sample deliveries from both demo bots, one of each purpose (a report with a
  question and a recommended answer crediting the other bot, a page from a task for review, merged pull requests, an FYI, and an older done one kept before purposes), with the
  first one's card in the first bot's Home; `replied` has it answered from the Inbox (Done), with the
  bot's answer in that Home; `done` has every one Done. `BOTCHU_OPEN=inbox` opens the Inbox, on the delivery `BOTCHU_INBOX_ITEM` names
  (`00000000-0000-4000-9000-00000000000<n>`); the window's snapshot draws web views in too.
  `BOTCHU_JOBS=sample` gives the demo bots sample jobs, with a history of every kind of run, the
  latest a task beside the first bot's chat, and a receipt in the first bot's Home, and runs no job (Run Now records a failed run), so nothing starts a CLI; `BOTCHU_OPEN=job-editor`
  or `job-history` opens a new job's editor or the first job's history, `job-model` or `job-effort` a
  new job's model or effort picker, and `job-edit` the editor of the job `BOTCHU_JOB` names (else the
  first): `Check the deploy` has its own account, model and effort, and `Friday release notes` one on
  a CLI profile that is gone.
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
  `BOTCHU_CONNECTORS=sample` (or `stale`, `unavailable`) gives profile checks in Connectors
  sample results (every state, an action of each kind, Computer Use and System entries), a check
  that fails after the first, or one that always fails, without starting a CLI.
  `BOTCHU_USAGE=sample` (or `stale`, `expired`, `unavailable`) reviews allowance states without
  querying any account (`sample` is Providers as its mock's main state: Claude's Fable week,
  Codex profiles' credits and free resets, and the Pi profile a key with a spending limit);
  `mixed` is its problems: a stale reading whose 5-hour window has reset since, then a failed
  check; a week used up, with no credits and a free reset expiring in two days; a failed check; a
  daily window; a profile still checking; a key without a limit; and an added profile
  (`BOTCHU_PROFILE`) whose command isn't found. `BOTCHU_PROVIDER=<account id>` selects that
  profile, showing it on the right. Usage fixtures
  are ignored outside throwaway data runs. `BOTCHU_PROFILE="<name>|<family>|<command>"` (several
  separated by `;`, `family` one of `claude`, `codex`, `antigravity`, `muse`, `pi`) adds CLI
  profiles to the run, such as one with a long name or a command that isn't installed.
  `BOTCHU_ACCOUNT`, `BOTCHU_MODEL` and `BOTCHU_EFFORT` set the first demo bot's generation choices;
  `BOTCHU_DEFAULT_MODEL` supplies an isolated OpenRouter default. `BOTCHU_OPEN=model` or `effort`
  opens the composer's picker, and `inspector-model` or `inspector-effort` opens the sidebar's.
  `BOTCHU_INSPECTOR=activity`, `subagents`, `model`, `session` or `memory` selects a status sidebar tab;
  with `BOTCHU_DEMO=activity`, `BOTCHU_SUBAGENT=<title>` opens the details of the demo's sub-agent
  whose title starts with it;
  `inspector-model` and `inspector-effort` also select Model & Usage before opening the picker.
  `BOTCHU_WINDOW=compact` checks the minimum window width, where a bot's tasks show as the rail,
  `wide` (1,700 points) the column, and `BOTCHU_WINDOW=1908x960` a window of that size, as a
  report gives it. `BOTCHU_DEMO=tasks` gives the first bot six more open
  tasks in memory, so its tabs show every state at once (working, starting, making the worktree,
  news with a pull request, idle, beside the seeded finished and failed ones), with no real turn;
  `BOTCHU_TAB=3` then shows the one working on #113. `BOTCHU_DRAFT=<text>` puts that draft in
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
  turn to run reviews costs the main thread (and reading it off the main thread, as its review
  starts), and writes the table to the file. Run with the same
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
- Task summaries (Quick tasks) without tools: `swift run --package-path macOS botchu-smoke --summary
  [account id …]` names a sample task on each account the way a new task's summary is asked for, on
  its family's smallest model (or `BOTCHU_SMOKE_MODEL`), and passes when the reply is a label of
  three or four words. It spends a little of each account's allowance; run it after changing how
  summaries are asked for.
- Telegram end to end: the gateway's tests use stand-ins for Telegram, so a real exchange is
  checked by hand, with your own Telegram bot: see
  [Checking it end to end](docs/telegram.md#checking-it-end-to-end).
- Smoke test after deploy: `macOS/install.sh` fails unless the installed app starts (launched hidden,
  found by its executable's path in `ps`, so a review copy running meanwhile doesn't count, and
  quit again unless it was already open).

## Deploy
- **Live checkout:** `Alexs-MacBook-Pro-92440` runs the app from `~/Desktop/WORKSPACE/BotChu`, which stays on `main` and is never edited; the app is installed to `~/Applications/BotChu.app`.
- **Secrets:** None in the repository or `.env`. The OpenRouter key and the Telegram bot token live in the Keychain, entered in Settings.
- **Deploy:** `scripts/deploy.sh`, run in `~/Desktop/WORKSPACE/BotChu`, fast-forwards it to `origin/main`, reuses a full-suite pass recorded for that exact tree (or runs `scripts/test.sh` when none exists), installs the app with `macOS/install.sh` (which restarts BotChu if it was open and smoke-tests that it starts), and appends `<UTC time> <commit> ok|failed` to `.git/deploys`. `scripts/deploy.sh --tests` forces the full suite even when a pass is recorded; `--skip-tests` still explicitly skips it. The build and the install's smoke test always run. Success: it exits 0, the last line of `.git/deploys` is that commit with `ok`, and `BotChuCommit` in `~/Applications/BotChu.app/Contents/Info.plist` is that commit. Nothing else deploys. Restarting BotChu stops every turn under way, its bots' tasks and sub-agents included, so deploy only when the owner asks and no turns are running. It refuses if `~/Desktop/WORKSPACE/BotChu` has local edits or commits; fix those through a pull request.
- **Recovery:** After a failed deploy, fix it (or revert the change) through a pull request and deploy again; `scripts/deploy.sh` retries, and reinstalls what is checked out when nothing new merged.
- **Scheduled jobs:** none.
- **Development:** On this Mac, in task worktrees of `~/Desktop/WORKSPACE/BotChu` (`.claude/worktrees/<type>-<slug>`, from `origin/main`). Changes reach the live app only by merging a pull request to `main` and deploying it.
