# Cross-bot delegation

BotChu supplies a `botchu-subagent` command to every Home, task and delegated turn. It works
through shell tools on all five CLI families. Python 3 is required on the execution machine.

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
save that fails waits to be tried again and doesn't fail the handoff.

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
running processes and waits for their exit before completing the child. A parent handoff waits
for its descendants to finish stopping. Active records found on restart become stopped.

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

The standalone helper is installed in `~/.botchu/bin`. Each turn also receives a private copy in
its mailbox's `bin` directory, prepended to PATH after login-shell initialization. Local mailboxes
are under `~/.botchu/ipc/subagents/<invocation id>`. A remote mailbox is under
`~/.botchu/ipc/subagents/<app namespace>/<invocation id>` on the host. Each contains `roster.json`,
`heartbeat.json`, `requests/<id>.json`, `status/<id>.status.json` (rewritten only when the child's
phase or activity changes) and `results/<id>.result.json`.
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

`scripts/check.sh` runs core and rendering tests and builds the app. Delegation tests exercise
helper round trips, validation, scoped persistence, nested fan-out, stop, restart, transport failure
and local/SSH environment handling. The standard `botchu-smoke` two-turn checks verify real CLI
execution and resumption separately, using each account's own login and allowance.
