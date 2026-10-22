---
name: BotChu
type: local
status: active
visibility: public
owner: asieke
merge: agent
deploy: local:Alexs-MacBook-Pro-92440:~/Desktop/WORKSPACE/BotChu
refresh: none
sources: []
standard: 2026-10-20
---

# BotChu

## Purpose
A minimal, open-source, native macOS take on "bot" apps such as Grok Bot and its open-source clone [rakazo](https://github.com/elie222/rakazo): a list of persistent bots down the left, each with its own name, instructions, memory and workspace folder, and a chat with the selected bot on the right. Instead of a hosted model runtime, every bot is driven by a coding-agent CLI already installed and signed in on the Mac (Claude Code, Codex, Antigravity, Muse, or Pi through OpenRouter), and any bot can be switched to any of those accounts.

## Audience
Alex, on one Mac, who has several signed-in agent accounts (three Claude, three Codex, one Google, one Muse, plus OpenRouter) and wants long-lived bots on top of them without a server. Open source, so anyone with those CLIs can build it.

## Goals and success
- Create a bot, pick its account, and chat with it in a native chat view that streams its replies and shows its tool calls; the conversation and the CLI session survive relaunches.
- Every account listed above can run a bot end to end on this Mac.
- Each bot can have an animated pet, drawn by Codex from a free-text description, that acts out what the bot is doing.
- First milestone: the macOS MVP — bot list and creation, chat, a minimal Settings window — built, tested and installed into `~/Applications` from `main`.

## Context
- Constraints: A native SwiftUI macOS app built with SwiftPM, without an Xcode project. Third-party dependencies are allowed when they materially improve the app: pin versions, retain their licenses and test their integration. Chat rendering assets ship with the app and work offline; chat content is never sent to a rendering service. Runs agents on the host Mac in a folder per bot; running them elsewhere (SSH hosts, containers, cloud) comes later. No secrets in the repository: the CLIs keep their own logins, and the OpenRouter key is entered in Settings and kept in the Keychain. Bots run their CLIs with permission prompts bypassed, because the MVP has no approval UI.
- Supporting documents: [rakazo](https://github.com/elie222/rakazo) (bot, memory and thread model this follows), [GitChu](https://github.com/asieke/GitChu) (how the account CLIs and profiles are set up on this Mac)
- Open decisions: where bots run besides this Mac; scheduled routines; approval UI for tool calls.
