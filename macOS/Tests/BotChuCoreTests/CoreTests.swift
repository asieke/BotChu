import Foundation
import Testing
@testable import BotChuCore

@Suite struct CommandBuilderTests {
    let id = { "fixed-id" }

    @Test func claudeStartsThenResumes() {
        let first = CommandBuilder.invocation(kind: .claude, prompt: "hi", model: nil, sessionID: nil, newID: id)
        #expect(first.arguments == ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                                    "--dangerously-skip-permissions", "--session-id", "fixed-id", "hi"])
        #expect(first.sessionID == "fixed-id")
        let next = CommandBuilder.invocation(kind: .claude, prompt: "again", model: "opus", sessionID: "s1", newID: id)
        #expect(next.arguments.suffix(5) == ["--resume", "s1", "--model", "opus", "again"])
    }

    @Test func codexResumesItsThread() {
        let first = CommandBuilder.invocation(kind: .codex, prompt: "hi", model: " ", sessionID: nil)
        #expect(first.arguments == ["exec", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "hi"])
        #expect(first.sessionID == nil)
        let next = CommandBuilder.invocation(kind: .codex, prompt: "again", model: "gpt-5.5", sessionID: "t1")
        #expect(next.arguments == ["exec", "resume", "t1", "--json", "--skip-git-repo-check",
                                   "--dangerously-bypass-approvals-and-sandbox", "-m", "gpt-5.5", "again"])
    }

    @Test func antigravityContinuesItsConversation() {
        let next = CommandBuilder.invocation(kind: .antigravity, prompt: "hi", model: nil, sessionID: "c1")
        #expect(next.arguments == ["-p", "hi", "--output-format", "stream-json", "--dangerously-skip-permissions", "--conversation", "c1"])
    }

    @Test func museAndPiKeepTheirOwnIDs() {
        let muse = CommandBuilder.invocation(kind: .muse, prompt: "hi", model: nil, sessionID: nil, newID: id)
        #expect(muse.arguments == ["exec", "--json", "--session-id", "fixed-id", "hi"])
        let pi = CommandBuilder.invocation(kind: .pi, prompt: "hi", model: nil, sessionID: "p1", openRouterKey: "sk-or-x")
        #expect(pi.arguments == ["-p", "--mode", "json", "--session-id", "p1", "--provider", "openrouter",
                                 "--model", CommandBuilder.defaultOpenRouterModel, "hi"])
        #expect(pi.environment == ["OPENROUTER_API_KEY": "sk-or-x"])
    }

    @Test func dashPromptIsNotAnOption() {
        let inv = CommandBuilder.invocation(kind: .codex, prompt: "-v please", model: nil, sessionID: nil)
        #expect(inv.arguments.last == " -v please")
    }

    @Test func everyAccountHasAUniqueID() {
        #expect(Set(Accounts.all.map(\.id)).count == Accounts.all.count)
        #expect(Accounts.all.filter { $0.kind == .claude }.count == 3)
        #expect(Accounts.all.filter { $0.kind == .codex }.count == 3)
        #expect(Accounts.account(id: "gone").id == Accounts.all[0].id)
    }
}

@Suite struct BotTests {
    @Test func slugs() {
        #expect(Bot.slug("Research Bot") == "research-bot")
        #expect(Bot.slug("  Café ☕️ Helper!! ") == "cafe-helper")
        #expect(Bot.slug("🤖") == "bot")
    }

    @Test func sessionResumesOnlyOnItsAccount() {
        var bot = Bot(name: "A", accountID: "claude-dev", workspace: "/tmp/a", sessionID: "s", sessionAccountID: "claude-dev")
        #expect(bot.resumableSessionID == "s")
        bot.accountID = "codex-dev"
        #expect(bot.resumableSessionID == nil)
    }
}

@Suite struct BotContextTests {
    let bot = Bot(name: "Scout", emoji: "🔭", title: "Finds things", instructions: "Be brief.", workspace: "/tmp/scout")

    @Test func preambleCarriesIdentityMemoryAndRecap() {
        let history = [
            ChatMessage(role: .note, text: "New session"),
            ChatMessage(role: .user, text: "Remember I like tea"),
            ChatMessage(role: .tool, toolName: "Bash"),
            ChatMessage(role: .assistant, text: "Noted."),
        ]
        let preamble = BotContext.sessionPreamble(bot: bot, memory: "# Scout\n- likes tea", sharedMemory: "", history: history)
        #expect(preamble.hasPrefix("<botchu_context>"))
        #expect(preamble.contains("You are Scout — Finds things"))
        #expect(preamble.contains("<instructions>\nBe brief.\n</instructions>"))
        #expect(preamble.contains("<bot>\n# Scout\n- likes tea\n</bot>"))
        #expect(!preamble.contains("<shared>"))
        #expect(preamble.contains("Owner: Remember I like tea\n\nYou: Noted."))
        #expect(!preamble.contains("New session"))
    }

    @Test func freshBotHasNoRecap() {
        let preamble = BotContext.sessionPreamble(bot: bot, memory: "", sharedMemory: "", history: [])
        #expect(!preamble.contains("recent_conversation"))
        #expect(!preamble.contains("durable_memory"))
    }

    @Test func recapKeepsTheNewestWithinItsLimit() {
        let long = (0..<40).map { ChatMessage(role: .user, text: "message \($0) " + String(repeating: "x", count: 900)) }
        let recap = BotContext.recap(long)
        #expect(recap.count <= BotContext.maxRecapCharacters + 100)
        #expect(recap.contains("message 39"))
        #expect(!recap.contains("message 0 "))
    }

    @Test func promptPutsPreambleFirst() {
        #expect(BotContext.prompt(for: "hi", preamble: nil) == "hi")
        #expect(BotContext.prompt(for: "hi", preamble: "<c/>") == "<c/>\n\nhi")
    }
}

@Suite struct WorkspaceTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func preparesFilesAndKeepsMemory() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var bot = Bot(name: "Scout", instructions: "One", workspace: root.appendingPathComponent("scout").path)
        let shared = root.appendingPathComponent("MEMORY.md").path
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        let dir = URL(fileURLWithPath: bot.workspace)
        #expect(Workspace.read(dir.appendingPathComponent("AGENTS.md").path).contains("One"))
        #expect(Workspace.read(dir.appendingPathComponent("CLAUDE.md").path).contains("@AGENTS.md"))
        #expect(Workspace.read(shared).hasPrefix("# Shared memory"))

        try "# Scout\n- learned".write(to: dir.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        bot.instructions = "Two"
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        #expect(Workspace.read(dir.appendingPathComponent("AGENTS.md").path).contains("Two"))
        #expect(Workspace.read(dir.appendingPathComponent("MEMORY.md").path) == "# Scout\n- learned")
    }

    @Test func neverOverwritesSomeoneElsesInstructions() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = root.appendingPathComponent("AGENTS.md")
        try "# A project's own rules".write(to: agents, atomically: true, encoding: .utf8)
        let bot = Bot(name: "Dev", workspace: root.path)
        try Workspace.prepare(bot: bot, sharedMemoryPath: root.appendingPathComponent("shared/MEMORY.md").path)
        #expect(Workspace.read(agents.path) == "# A project's own rules")
        #expect(Workspace.read(root.appendingPathComponent("GEMINI.md").path).hasPrefix(BotContext.marker))
    }
}

@Suite struct StoreTests {
    @Test func roundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        #expect(store.loadBots().isEmpty)
        // The files keep whole seconds (ISO 8601).
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let bot = Bot(name: "Scout", workspace: "/tmp/scout", sessionID: "s", sessionAccountID: "muse", createdAt: date)
        try store.saveBots([bot])
        #expect(store.loadBots() == [bot])
        let messages = [ChatMessage(role: .user, text: "hi", date: date),
                        ChatMessage(role: .tool, date: date, toolID: "t", toolName: "Bash", toolState: .done)]
        try store.saveThread(messages, for: bot.id)
        #expect(store.loadThread(bot.id) == messages)
        store.deleteThread(bot.id)
        #expect(store.loadThread(bot.id).isEmpty)
    }
}

@Suite struct AgentRunTests {
    @Test func childEnvironmentDropsAgentSessionVariables() {
        let env = AgentRun.childEnvironment([
            "HOME": "/Users/a", "PATH": "/usr/bin", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "x",
            "CLAUDE_CONFIG_DIR": "/Users/a/.claude-dev", "CODEX_HOME": "/c", "AI_AGENT": "claude-code",
            "ANTHROPIC_API_KEY": "k", "BOTCHU_SEND": "hi", "MCP_SERVER_CONNECTION_BATCH_SIZE": "4", "LANG": "en_US.UTF-8",
        ])
        #expect(env == ["HOME": "/Users/a", "PATH": "/usr/bin", "LANG": "en_US.UTF-8"])
    }
}

@Suite struct BotStatusTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    func bot(session: String? = nil, on account: String? = nil) -> Bot {
        Bot(name: "Scout", accountID: "claude-dev", workspace: "/tmp/scout", sessionID: session, sessionAccountID: account)
    }

    @Test func idleBotCountsItsThread() {
        let messages = [
            ChatMessage(role: .note, text: "Scout was created on Claude Dev", date: date),
            ChatMessage(role: .assistant, text: "Hi", date: date),
            ChatMessage(role: .user, text: "ls", date: date.addingTimeInterval(5)),
            ChatMessage(role: .tool, date: date.addingTimeInterval(6), toolName: "Bash"),
            ChatMessage(role: .assistant, text: "Done", date: date.addingTimeInterval(7)),
            ChatMessage(role: .note, text: "New session", date: date.addingTimeInterval(60)),
        ]
        let status = BotStatus.make(bot: bot(session: "s1", on: "claude-dev"), messages: messages, run: nil)
        #expect(status.phase == .idle)
        #expect(status.session == .continuing(id: "s1"))
        #expect(status.messageCount == 3)
        #expect(status.toolCallCount == 1)
        #expect(status.lastActivity == date.addingTimeInterval(7))
        #expect(status.lastError == nil)
    }

    @Test func runPhases() {
        let started = RunState(startedAt: date, hasOutput: false)
        #expect(BotStatus.make(bot: bot(), messages: [], run: started).phase == .starting)
        var running = started
        running.hasOutput = true
        let status = BotStatus.make(bot: bot(), messages: [], run: running)
        #expect(status.phase == .working)
        #expect(status.runStartedAt == date)
    }

    @Test func failedTurnIgnoresLaterNotes() {
        let messages = [ChatMessage(role: .error, text: "usage limit"), ChatMessage(role: .note, text: "Stopped")]
        let status = BotStatus.make(bot: bot(), messages: messages, run: nil)
        #expect(status.phase == .failed)
        #expect(status.lastError == "usage limit")
    }

    @Test func sessionAfterAnAccountSwitchStartsNew() {
        #expect(BotStatus.make(bot: bot(session: "s1", on: "codex-dev"), messages: [], run: nil).session == .startsNew(accountChanged: true))
        #expect(BotStatus.make(bot: bot(), messages: [], run: nil).session == .startsNew(accountChanged: false))
    }
}

@Suite struct MemorySnapshotTests {
    let bot = Bot(name: "Scout", workspace: "/tmp/scout")

    @Test func seededFileIsEmpty() {
        let memory = MemorySnapshot.parse(BotContext.seedMemory(bot: bot), bot: bot, modified: nil)
        #expect(memory.body.isEmpty)
        #expect(memory.entryCount == 0)
    }

    @Test func countsListedFacts() {
        let text = BotContext.seedMemory(bot: bot) + "\n- likes tea\n- 30 minutes max\n\nNotes without a bullet\n"
        let memory = MemorySnapshot.parse(text, bot: bot, modified: nil)
        #expect(memory.body == "- likes tea\n- 30 minutes max\n\nNotes without a bullet")
        #expect(memory.entryCount == 2)
    }

    @Test func editedHeadingIsDropped() {
        let memory = MemorySnapshot.parse("# Scout's notes\n\n* one", bot: bot, modified: nil)
        #expect(memory.body == "* one")
        #expect(memory.entryCount == 1)
    }

    @Test func missingFile() throws {
        let gone = Bot(name: "Gone", workspace: "/nonexistent/botchu-\(UUID().uuidString)")
        #expect(MemorySnapshot.read(bot: gone) == .missing)
    }
}
