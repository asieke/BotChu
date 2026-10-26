# BotChu

How to run, test and deploy BotChu is in README.md; what it is, in PROJECT.md.

## Project rules

- The app is the Swift package in `macOS/`. Keep `Sources/BotChuCore/` Foundation-only and unit-tested; the SwiftUI app in `Sources/BotChu/` stays thin over it.
- After changing how a CLI is run or parsed, run `swift run --package-path macOS botchu-smoke <account id>…` for the accounts it touches: two real turns each (a new session, then a resumed one that must recall a code word). It uses the CLIs' own logins and their allowance; OpenRouter needs `OPENROUTER_API_KEY` in its environment.
- When a CLI's headless output format changes, capture a real sample into the parser tests (`macOS/Tests/BotChuCoreTests/`) before changing its parser.
- Never copy, read aloud or log the CLIs' auth files or the OpenRouter key; each profile owns its own login.

## Test loop

- While editing, run `swift test --package-path macOS --filter <Suite>` for the suites the change touches. Rendering suites need the shared window-test gate.
- Run `scripts/test.sh --fast` before a push: shell syntax, renderer checksums, a debug build with tests, and all Core tests, without the gate.
- Run `scripts/test.sh` once per final PR head for all tests and an app build.
