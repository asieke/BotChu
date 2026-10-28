# Cross-bot delegation

A conversation hands work to another bot in one of two ways, each with its own command. An `@bot`
mention only names the bot; what is asked for decides which:

| The owner asks for | What BotChu makes | Where it shows | Lifetime |
| --- | --- | --- | --- |
| "New task @bot", "hand this off to @bot as a new task" | a **Task**, with `botchu-task create` | under the bot in the left sidebar | the bot's own; goes on after the asking turn ends or stops |
| "New subagent @bot", "delegate this to @bot as a sub-agent" | a **sub-agent run**, with `botchu-subagent call` or `spawn` | the asking conversation's Sub-agents inspector | a child of the asking turn; its handoff comes back, and Stop cascades |

A remote queue bot, which runs on its own computer, is neither: a turn messages it with
`botchu-message send`, and its answer comes back into the asking conversation as a new message
([Remote queue: messages from other bots](remote-queue.md#messages-from-other-bots)). The roster
marks remote bots (`"remote": true`); `botchu-subagent list` leaves them out.

BotChu supplies both commands to every Home, task and delegated turn. They work through shell
tools on all five CLI families. Python 3 is required on the execution machine.

## Tasks

```sh
botchu-task create --agent '10x Engineer Bot' --repo asieke/BotChu --title 'Speed audit' \
  --brief 'Fix #106–#110: spawn one sub-agent run per issue, then merge them one at a time.'
botchu-task create --agent 'QA Bot' --repo asieke/BotChu --review 121 --comment
botchu-task status <request id>
botchu-task list --mine [--json]
```

`create` takes `--brief`, `--issue`, `--pr` (to continue a pull request) or `--review` (with
`--comment` to post it), and `--title`, `--branch` and `--machine`, the fields of a dispatch file
(README, **Home coordinates**). The Task is made as the named bot's own: in its repository's usual
place, with the usual issue, pull request and worktree checks, on the bot's account, model and
effort, recording which conversation asked (`requestedBy` in its `task.json`). Its first message
tells the bot who handed it over. The asking conversation gets a receipt that opens the Task, and
the command prints the bot and Task IDs and one status: `pending`, `created` (its first turn still
starting when `--wait`, 120 seconds by default, ran out), `started`, `start failed` (the Task is
there, with why) or `failed` (nothing was made: run the same command again once the reason is
fixed). It exits nonzero for the last two. A pull request to continue is read from GitHub before
anything is made, and when another open task already works on its head branch (a task that
opened it there, say), the request fails with that task as `Working Task:`, its bot and ID, to
message instead; no Task or tab is made. A dispatch file asking the same gets the same answer in
Home. Running the same command again from the same
conversation, in the same turn, a later one or after a relaunch, returns the same Task: BotChu
recognizes it by the conversation, the bot and what it asks for. A request seen again in the same
turn gets the same answer. The Task doesn't count against sub-agent limits and never waits for
the asking turn; it counts as one of the turn's sixty-four delegations.

`list --mine` (#262) prints the asking bot's open Tasks as its Tasks column in BotChu shows them,
in its order, with the column's count: each row's title, summary and state (`Idle`, `Thinking…`,
`Running a tool…`, `Finished · PR #12`, `Needs input`), the running turn's elapsed time or the time
since its last activity, its issue or pull request, branch, host and Task ID; `--json` prints the
same fields. BotChu answers from its live run state, so a Task closed in the sidebar isn't listed
and nothing is read from `task.json`, process tables or transcripts. "Mine" is the bot whose turn
asks: its Home, one of its Tasks, or a sub-agent run, whose own bot it is rather than its caller's.
Without `--mine`, `list` lists the bots that can own Tasks, as before.

A batch goes to one bot as one Task, whose own turn runs a sub-agent run per item: the asking
turn can end while they work, and stopping the Task stops its runs.

A dispatch file with `"agent"` does the same from a bot's folder on this Mac, with a receipt in
its Home. BotChu looks at every bot's dispatch folder while any turn runs, so a request written
into another bot's folder no longer waits for that bot's Home.

## Sub-agent runs

```sh
botchu-subagent list
botchu-subagent call --agent 'QA Bot' --title 'Check the change' --brief 'Review the changed files and report findings.'
first=$(botchu-subagent spawn --agent 'QA Bot' --brief 'Run the tests.')
second=$(botchu-subagent spawn --agent 'Docs Bot' --workspace bot_home --brief 'Draft release notes from this summary: …')
botchu-subagent wait "$first" "$second"
```

Names and slugs are case insensitive. Ambiguous names require a bot UUID from `list`.
`call` and `wait` return the child's handoff on stdout and exit nonzero for failure or Stop.
Progress goes to stderr. A caller must collect its children before its turn ends; an ended
parent stops remaining descendants. A child is a fresh session using its target bot's account,
model, effort, instructions (`INSTRUCTIONS.md`), soul and memory, with the shared `TEAM.md`
playbook when it has one. It never resumes or appends to that bot's Home.
Explicit `<remember>` notes in a successful handoff (and `<remember scope="shared">` ones) are
saved to the target bot's memory on this Mac, as from every conversation (README, **Saving
memory**): the run's transcript says how it went, and the bot's Home hears it at its next turn. A
save that fails waits to be tried again and doesn't fail the handoff. Once the run's record is
saved and its handoff queued, a finished, failed or stopped attempt that used tools (or failed) is
handed to a background run review about the target bot (README, **Run reviews**); the handoff
never waits for it, and runs closed while BotChu relaunches aren't reviewed.

The default `shared` workspace is the caller's directory and machine, including for nested
delegation on SSH hosts. `bot_home` uses the called bot's folder on this Mac. The prompt tells
delegates to respect repository instructions, avoid overlapping edits, and follow the called
bot's identity even when the shared folder contains another bot's generated instructions.
Delegation doesn't create a git branch or worktree: top-level tasks still provide that isolation.

## Ownership and lifetime

The app registers a fresh invocation UUID before each CLI turn and injects the helper path,
mailbox and caller context. Requests must match that registered invocation, root conversation,
parent and depth. The app derives the workspace and host from its registration, never from the
request's working-directory field. It rejects stale, malformed, oversized or ambiguous requests
with a terminal failure. Maximum depth is three, with twelve active children across the app and
sixty-four admissions per root turn. Capacity rejection returns immediately; waiting parents
never occupy a child queue that could deadlock their descendants.

Each request is atomically published, persisted before acknowledgment, and deduplicated by UUID
within its invocation. Each child's transcript and final record are saved before returning its
handoff. While a child streams, its transcript is checkpointed off the main thread at most once a
second, and checkpoints still waiting are written when BotChu quits. Result writes are atomic and retry transient delivery failures. An unrecoverable delivery
closes the mailbox so the helper fails; startup republishes persisted results. Stop interrupts
running processes, terminates them 3 seconds later and kills them, with what they started, 5
seconds after that, and waits for their exit before completing the child. A child whose CLI is
still running 30 seconds after it said its turn ended is terminated, then killed 5 seconds later,
and completes with its handoff and a note saying so (#145: Antigravity printed a handoff, then
never exited and ignored Stop's signals, so the run stayed running until BotChu restarted); one
whose background tasks still run gets up to 2 hours for them (#255). A
parent handoff waits for its descendants to finish stopping. Active records found on restart
become stopped.

BotChu refreshes the heartbeat every two seconds; the helper checks it and fails after thirty
seconds without one. Its
overall wait limit is two hours. It does not reconnect a crashed CLI session or automatically
repeat work after an app restart.

## Files and SSH

Records and transcripts stay with the owning conversation:

```text
<owner workspace>/.botchu/subagents/<run id>/{run.json,thread.jsonl}
<owner workspace>/.botchu/tasks/<task id>/subagents/<run id>/{run.json,thread.jsonl}
```

The standalone helper is installed in `~/.botchu/bin`, as `botchu-subagent`, `botchu-task`,
`botchu-inbox` and `botchu-message` (one script that acts by the name it is run as). A message
(`"kind": "message"`) stages its files as a delivery does. Each turn also receives private copies in
its mailbox's `bin` directory, prepended to PATH after login-shell initialization. Local mailboxes
are under `~/.botchu/ipc/subagents/<invocation id>`. A remote mailbox is under
`~/.botchu/ipc/subagents/<app namespace>/<invocation id>` on the host. Each contains `roster.json`,
`heartbeat.json`, `requests/<id>.json`, `status/<id>.status.json` (rewritten only when the child's
phase or activity changes) and `results/<id>.result.json`. A Task request is a request with `"kind":
"task"`; its result is rewritten as it goes from pending to created to started, and
`botchu-subagent wait` refuses it, as `botchu-task status` refuses a sub-agent run's. A delivery
(`botchu-inbox send`) is a request with `"kind": "inbox"`; the helper first copies its files into
`inbox/<request id>/` in the mailbox, BotChu reads them from there (over SSH from a host, each at
most 20 MB) into the sending bot's `.botchu/inbox/<delivery id>/`, removes them, and writes a result
that says whether it was delivered or updated, or why not.
A Tasks list (`botchu-task list --mine`) is a request with `"kind": "taskList"`; its result holds
the rows and the text the helper prints, and the helper removes it once read.
The app namespace survives relaunch. Isolated tests and development runs use their own data root.

SSH mailbox polling uses an independent connection through the existing ControlMaster, so a
provider that buffers a shell tool's output cannot block delivery. Mailboxes are polled off the
main thread, and on a host a poll refreshes the heartbeat in the same round trip. Remote filesystem operations
have bounded requests, timeouts and cancellation; results go through stdin to avoid argument-size
limits. Only the exact delegation environment keys cross SSH. The OpenRouter key and the local
provider environment stay on this Mac; remote children use the host's own account commands and
credentials. No CLI parser or provider-specific output marker is required.

The inspector's Clear action removes a completed run and its completed descendants from history;
it does not erase already-returned handoff files or undo delegated changes.

## Verification

`scripts/test.sh` runs core and rendering tests and builds the app. Delegation tests exercise
helper round trips, validation, scoped persistence, nested fan-out, stop (also of a child that
ignores SIGINT and SIGTERM), a child that never exits after its handoff, restart, transport failure
and local/SSH environment handling. The standard `botchu-smoke` two-turn checks verify real CLI
execution and resumption separately, using each account's own login and allowance.
