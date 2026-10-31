# BotChu

How to run, test and deploy BotChu is in README.md; what it is, in PROJECT.md.

## Project rules

- The app is the Swift package in `macOS/`. Keep `Sources/BotChuCore/` Foundation-only and unit-tested; the SwiftUI app in `Sources/BotChu/` stays thin over it.
- After changing how a CLI is run or parsed, run `swift run --package-path macOS botchu-smoke <account id>…` for the accounts it touches: two real turns each (a new session, then a resumed one that must recall a code word). It uses the CLIs' own logins and their allowance; OpenRouter needs `OPENROUTER_API_KEY` in its environment, and Sail `SAIL_API_KEY` plus `BOTCHU_SMOKE_MODEL=<a Sail model that takes Flex>` (its turns can wait in Sail's Flex queue).
- When a CLI's headless output format changes, capture a real sample into the parser tests (`macOS/Tests/BotChuCoreTests/`) before changing its parser.
- Never copy, read aloud or log the CLIs' auth files or the OpenRouter or Sail keys; each profile owns its own login.
- Read an `@AppStorage` value only in the small view that shows it, and pass it down as a `let`: any UserDefaults write, whatever its key (AppKit saves split view widths there), evaluates again every view whose body reads one (#348).

## Test loop

- While editing, run `swift test --package-path macOS --filter <Suite>` for the suites the change touches; `BotChuRenderingTests` only inside the shared gate.
- Each pull request runs `scripts/test.sh --fast` before a push. When it changes views, `AppModel`, streaming or persistence, it also runs the journeys that change reaches, `scripts/test.sh --journeys <names or numbers>` (it queues itself in the shared gate; never wrap it in a gate request), and pastes the latency report it ends with into `## Testing`. A docs-only pull request runs nothing else.
- After the last pull request of a batch merges, run the full `scripts/test.sh` once on `origin/main`: the fast tier, the Release Core subset (Swift 6.4's task-group optimizer bug), the kept window tests and every journey. Fix a regression in a follow-up pull request and run it again until it passes; the batch summary gives each journey's time before and after. Deploy runs the same suite unless that tree already passed.
- A journey fails when its median is over budget or more than 25% (and 3 ms) slower than `macOS/Journeys/baseline.json`. Change the baseline only with `BOTCHU_JOURNEYS_RECORD=1 scripts/test.sh --journeys <names>`, in a pull request that says why.
- New behaviour gets a Core test of its logic or a check in an existing journey, not a window test; `BotChuRenderingTests` keeps only tests of bugs that came back and security checks nothing else observes (docs/testing.md).
- If a test outside the change's scope fails, rerun only the failed test with the printed command a few times. If it passes, name the test and the load average in the PR; do not rerun the whole suite. Changed tests still need a demonstrated fix. A full clean-tree pass is shared across worktrees and reused by deploy; `scripts/deploy.sh --tests` explicitly forces testing.
