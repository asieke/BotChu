# BotChu

A minimal, open-source, native macOS app for persistent AI bots, in the spirit of Grok Bot and [rakazo](https://github.com/elie222/rakazo). Bots are listed down the left; the selected bot's chat fills the window, and each bot can also work on parallel tasks in your GitHub repositories in their own git worktrees on this Mac or over SSH. Every bot is driven by a coding-agent CLI already installed and signed in on the Mac (Claude Code, Codex, Antigravity, Muse, or Pi), or by BotChu's own headless agent on Sail Research (`botchu-sail`).

## Run locally
- Prerequisites: macOS 14 or later with full Xcode 16 or later (`xcode-select -p` must point into `Xcode.app`), and whichever agent CLIs you want to use, installed and signed in.
- Install: no dependency installation is needed; the renderer assets are included in the repository.
- Configure: nothing in `.env`. The OpenRouter and Sail keys and the Telegram bot token go in BotChu ▸ Settings.
- Run from a checkout without touching the installed copy:
  ```sh
  pkill -x BotChu; macOS/build.sh && open macOS/build/BotChu.app
  ```

## Test
- Suites touched while editing (rendering suites need the shared `/tmp/botchu-coord/gate.sh` gate):
  ```sh
  swift test --package-path macOS --filter <Suite>
  ```
- Fast pre-push check (shell syntax, renderer checksums, debug test build, and all `BotChuCoreTests`, without the gate):
  ```sh
  scripts/test.sh --fast
  ```
- Pull request check (fast tier plus reachable `BotChuRenderingTests` and Release tests via `scripts/test-select.py --explain`; queues its own gate run):
  ```sh
  scripts/test.sh --changed
  ```
- Full test suite (shell syntax, `macOS/test.sh` unit and rendering tests, and `macOS/build.sh` into a temporary folder):
  ```sh
  scripts/test.sh
  ```
- Black-box UI journeys against `macOS/Journeys/baseline.json` (`BOTCHU_JOURNEYS_RECORD=1` records a new baseline), each run's results kept in `~/Library/Caches/botchu-journeys/runs/` (`BOTCHU_JOURNEYS_RUNS`), and the latency report of the newest run against the baseline and the last 3 on `main`:
  ```sh
  scripts/test.sh --journeys [names or numbers]
  scripts/journeys-report.py [--results <file>] [--write <file>]
  ```
- Isolated UI review on throwaway data:
  ```sh
  macOS/ui-review.sh ["message"]
  ```
- Live CLI and provider smoke checks (uses account allowance; not part of `scripts/test.sh`):
  ```sh
  swift run --package-path macOS botchu-smoke [account id …]
  swift run --package-path macOS botchu-smoke --usage|--review|--summary|--issue [account id …]
  ```
- Manual Telegram gateway verification: see [Checking it end to end](docs/telegram.md#checking-it-end-to-end).

## Deploy
- Live checkout: `~/Desktop/WORKSPACE/BotChu` on `Alexs-MacBook-Pro-92440` (stays on `main`), installed to `~/Applications/BotChu.app`.
- Fast-forward `~/Desktop/WORKSPACE/BotChu` to `origin/main`, reuse a recorded full-suite pass for that tree (or run `scripts/test.sh`), send the commit's latency report to the Inbox with `scripts/deploy-report.sh` (running the journeys when it has no results), and install and smoke-test with `macOS/install.sh`:
  ```sh
  scripts/deploy.sh
  ```
- Force or skip the full test suite during deploy:
  ```sh
  scripts/deploy.sh --tests
  scripts/deploy.sh --skip-tests
  ```

## Operate
- Refresh the offline token market pricing snapshot (`macOS/Sources/BotChuCore/ModelPrices.generated.swift`):
  ```sh
  scripts/update-model-prices.py --date YYYY-MM-DD
  ```
