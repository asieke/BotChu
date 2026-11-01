# Testing BotChu

The commands are in the README's Test section. This page says which to run when, and where a new
test goes. The suite answers one question: did the things the owner does every day stay fast and
keep working? It trades coverage for speed and signal on purpose (#323).

## When to run what

| When | Run | Takes |
|---|---|---|
| Each pull request | `scripts/test.sh --fast` | about a minute |
| … that changes views, `AppModel`, streaming or persistence | also `scripts/test.sh --journeys <names>` for the journeys below that the change reaches, with the latency report it ends with in `## Testing` | a few seconds to 2.5 minutes |
| After the last pull request of a batch merges | the full `scripts/test.sh` once on `origin/main`; a regression is fixed in a follow-up pull request and the suite runs again until it passes | under 5 minutes on a warm build tree |
| Deploy (`scripts/deploy.sh`) | the full suite, unless that tree already passed it | |

A docs-only pull request runs nothing else.

| What the change touches | Journeys |
|---|---|
| Launch, data loading, migration | `launch` (1), `relaunch` (13) |
| Sidebar, toolbar, status sidebar | `sidebar` (2), `switch-bot` (3) |
| The ⌘K switcher | `switch-bot` (3) |
| Project Areas column, attaching an area, legacy tasks | `switch-area` (4), `attach-area` (9) |
| Composer, typing | `typing` (5), `subagent` (12) |
| Sending, streaming, the turn loop | `send` (6), `typing` (5) |
| Chat history, scrolling, tool-call groups | `scroll` (7), `expand` (8) |
| An area's work rows | `relaunch` (13) |
| Window and column layout | `resize` (10) |
| Inbox, Settings | `inbox` (11) |
| Sub-agents | `subagent` (12) |
| Drafts, anything kept across a relaunch | `relaunch` (13) |

## The full suite

| Part | Budget |
|---|---|
| Builds: debug and Release tests, the release app and the journeys harness (incremental) | ≤ 90 s |
| `BotChuCoreTests`, Debug | ≤ 20 s |
| The Release Core subset (`projectLoading`, `RunEvaluationTests`, Core `SensitiveInputTests`): Swift 6.4's task-group optimizer bug (#93208) and the secure input check that failed only optimized (#314) | ≤ 15 s |
| The kept `BotChuRenderingTests`, and their secure input tests again optimized, one gated run | ≤ 30 s |
| The 13 journeys on the release app, one gated run, then the latency report | ≤ 150 s |

A full pass is recorded for its Git tree (`.git/test-passes`), shared across worktrees and reused by
deploy. Deploy's latency report (`scripts/deploy-report.sh`) uses the journeys the full suite ran on
that commit, and runs them itself only when there are none (after `--skip-tests`, or a pass reused
from another commit of the same tree).

## Journeys and their baseline

The journeys bring their isolated copy of BotChu to the foreground, where the owner performs these
interactions, then restore the previously active app. Leave that copy in front while they run. A
journey checks that the copy still has focus when it finishes: a background copy can be demoted
by macOS even with App Nap disabled, making the long streaming measurements bimodal (#388).

A journey fails when its median is over its budget, or more than 25% (and more than 3 ms) slower
than `macOS/Journeys/baseline.json`; a failed measurement is retried once and the load average is
recorded. When a baseline misses its budget, the step is held to baseline + 10% (the ratchet) and a
perf issue is filed, until a fix and a new baseline bring it back. To rebaseline, run the journeys whose times changed with
`BOTCHU_JOURNEYS_RECORD=1 scripts/test.sh --journeys <names>` on a quiet Mac (1-minute load under
10) and commit the new `baseline.json` in a pull request that says why the times moved. Never
overwrite another journey's numbers.

## Where a new test goes

1. **Core** (`macOS/Tests/BotChuCoreTests/`): the logic. When it lives in the app target, extract
   the pure part (no SwiftUI, AppKit or `AppModel`) into `BotChuCore` and test it there.
2. **A journey**: a flow or a latency the owner sees, as a check in an existing journey. A new
   journey or budget is its own issue.
3. **`BotChuRenderingTests`**: only when neither of the above can catch it, and only for a bug
   that came back after it was fixed (its comment names the issues that show it), or for a security
   or data-safety check at a point nothing else observes (secure input, the remote queue's public
   listener, what a web view may reach, writes during a storage move). The whole target stays
   under 30 s.
