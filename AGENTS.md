# BotChu

How to run, test and deploy BotChu is in README.md; what it is, in PROJECT.md.

## Project rules

- The app is the Swift package in `macOS/`. Keep `Sources/BotChuCore/` Foundation-only and unit-tested; the SwiftUI app in `Sources/BotChu/` stays thin over it.
- After changing how a CLI is run or parsed, run `swift run --package-path macOS botchu-smoke <account id>…` for the accounts it touches: two real turns each (a new session, then a resumed one that must recall a code word). It uses the CLIs' own logins and their allowance; OpenRouter needs `OPENROUTER_API_KEY` in its environment, and Sail `SAIL_API_KEY` plus `BOTCHU_SMOKE_MODEL=<a Sail model that takes Flex>` (its turns can wait in Sail's Flex queue).
- When a CLI's headless output format changes, capture a real sample into the parser tests (`macOS/Tests/BotChuCoreTests/`) before changing its parser.
- Never copy, read aloud or log the CLIs' auth files or the OpenRouter or Sail keys; each profile owns its own login.

## Test loop

- While editing, run `swift test --package-path macOS --filter <Suite>` for the suites the change touches. Rendering suites need the shared window-test gate.
- Run `scripts/test.sh --fast` before a push: shell syntax, renderer checksums, a debug build with tests, and all Core tests, without the gate.
- Run `scripts/test.sh` directly once per final PR head for all tests and an app build. It installs the shared gate and queues only prebuilt window tests; never wrap this full script in a gate request.
- If a test outside the change's scope fails, rerun only the failed test with the printed command a few times. If it passes, name the test and the load average in the PR; do not rerun the whole suite. Changed tests still need a demonstrated fix. A full clean-tree pass is shared across worktrees and reused by deploy; `scripts/deploy.sh --tests` explicitly forces testing.
