---
name: BotChu
type: local
status: active
visibility: public
owner: asieke
merge: agent
deploy: local:Alexs-MacBook-Pro-92440:~/Desktop/WORKSPACE/BotChu
---

# BotChu

## Purpose
A minimal, open-source, native macOS take on "bot" apps such as Grok Bot and its open-source clone [rakazo](https://github.com/elie222/rakazo): a list of persistent bots down the left, each with its own name, instructions, memory and workspace folder, and a chat with the selected bot on the right. A bot can also work on several of the owner's GitHub repositories at once: tasks nested beneath it in the sidebar, each in its own git worktree on this Mac or on another computer over SSH, which it can start and keep track of itself, including reviews of pull requests. Instead of a hosted model runtime, every bot is driven by a coding-agent CLI already installed and signed in on the Mac (Claude Code, Codex, Antigravity, Muse, or Pi through OpenRouter), and any bot can be switched to any of those accounts.

## Audience
Alex, on one Mac, who has several signed-in agent accounts (three Claude, three Codex, one Google, one Muse, plus OpenRouter) and wants long-lived bots on top of them without a server. Open source, so anyone with those CLIs can build it.

## Goals and success
- Create a bot, pick its account, and chat with it in a native chat view that streams its replies and shows its tool calls; the conversation and the CLI session survive relaunches.
- Every account listed above can run a bot end to end on this Mac; additional profiles of those CLI families can be added in Providers.
- Projects, Agents and Providers give the workspace a visual overview: one project per GitHub repository, metadata edits proposed as lightweight PROJECT.md pull requests, and tasks pairing an agent with a project whose metadata supplies its working location.
- Each bot can have an animated pet, made from a free-text description (stills drawn by Codex, looping clips made on OpenRouter), that acts out what the bot is doing.
- A bot such as a "10x engineer" keeps its identity and memory while it works on several repositories in parallel: each task in its own worktree and CLI session, started by the owner or by the bot from its Home conversation, which hears back how each task went.
- A bot's Home can be messaged from Telegram, through an opt-in gateway in the app that needs no server, with its replies coming back there and the exchange kept in the Home conversation.
- An agent can own scheduled jobs, such as a morning triage on weekdays, each run in a fresh session of its own, with its history in Jobs and only findings and failures in its Home.
- Any Home or task conversation can delegate to another configured bot, inspect its nested activity in the right sidebar, and receive its handoff without mixing the bots’ Home sessions.
- First milestone: the macOS MVP — bot list and creation, chat, a minimal Settings window — built, tested and installed into `~/Applications` from `main`.

## Context
- Constraints: A native SwiftUI macOS app built with SwiftPM, without an Xcode project. Third-party dependencies are allowed when they materially improve the app: pin versions, retain their licenses and test their integration. Chat rendering assets ship with the app and work offline; chat content is never sent to a rendering service. Runs bots on the host Mac in a folder per bot; a task can run on another computer over SSH (Settings ▸ Hosts), keeping the bot's folder, and so its memory, on the Mac; containers and cloud come later. No secrets in the repository: the CLIs keep their own logins, and the OpenRouter key and the Telegram bot token are entered in Settings and kept in the Keychain. Bots run their CLIs with permission prompts bypassed, because the MVP has no approval UI.
- Supporting documents: [rakazo](https://github.com/elie222/rakazo) (bot, memory and thread model this follows), [GitChu](https://github.com/asieke/GitChu) (how the account CLIs and profiles are set up on this Mac)
- Open decisions: whether a bot's Home can run elsewhere than this Mac; containers and cloud; whether scheduled jobs need a background runtime that runs them while BotChu is quit (with its own start, stop and login behavior), and cloud scheduling; approval UI for tool calls. Decided: scheduled jobs (#87) run in BotChu while it is open and the Mac is awake, each run a fresh session of its agent's, apart from Home; tasks on other machines run over SSH hosts set up in BotChu itself (#16); nothing is handed over from GitChu, and BotChu depends on no other app. The repositories tasks work on are the ones `gh` lists for the signed-in GitHub account.
