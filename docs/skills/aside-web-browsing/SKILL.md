---
name: aside-web-browsing
description: >-
  Browse the web, research live sites (like Amazon, Reddit, documentation), and interact with authenticated web apps (Gmail, Slack, Notion, Google apps) using the `aside` AI browser CLI. Use whenever a task needs interactive browsing, live page inspection, or authenticated web context.
---

# Web Browsing via Aside (`aside-web-browsing`)

## Purpose
Use the `aside` CLI to delegate multi-step browser tasks to the Aside AI browser agent (`aside exec`) or inspect/control pages directly (`aside repl`). Aside runs with the owner's browser sessions, cookies, and site skills.

## Operating Rules (Critical)
1. **Quote or escape `$` in prompts:** Always wrap prompts in single quotes (`'...'`) or escape dollar signs (`\$50`) when invoking `aside` from `zsh`. Double quotes cause the shell to expand `$50` into `$5` + `0` (stripping the number).
2. **Never run `aside session resume <id>` without a prompt:** Omitting the prompt argument (`aside session resume <id>`) drops into an interactive `>` REPL that never exits on its own, hanging the turn. Always pass a follow-up prompt inline:
   ```sh
   aside session resume <id> 'Continue and summarize your findings'
   ```
3. **Do not wait silently on backgrounded runs:** When an `aside` command runs in the background, schedule a 60-second wakeup timer (`schedule` with `DurationSeconds: 60`, `TimerCondition: "any"`) to inspect the task log, surface progress to the owner, and catch completed or disconnected sessions immediately.

## Workflow
1. **Delegate browsing tasks (`aside exec`):**
   Prefer `aside exec` for research and multi-step web tasks:
   ```sh
   aside exec 'Search Amazon.com for the best closet dehumidifiers under $50 and return live prices, ratings, and ASINs.'
   ```
2. **Check user context (`aside memory`):**
   Before asking the owner for personal context that Aside may already know:
   ```sh
   aside memory search '<query>' --json
   ```
3. **Steer or resume a running/disconnected session:**
   - Steer an active run: `aside session steer <id> 'Focus on cordless options'`
   - Queue next instruction: `aside session queue <id> 'Export to Markdown table'`
   - Resume a finished/interrupted session (always include the prompt!): `aside session resume <id> 'Summarize the subagent results and finish'`
4. **Direct DOM/Screenshot inspection (`aside repl`):**
   Only use `aside repl` when you need direct Playwright-style JS access to tabs, DOM selectors, or screenshots. Run `aside guide repl` first if you haven't read its API in the current session.
