import Foundation
import Testing
@testable import BotChuCore

/// A bot's INSTRUCTIONS.md and the shared TEAM.md (#42).
@Suite struct InstructionsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-instructions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let none = "None yet. Ask your owner what they need."

    private func run(_ bot: Bot) -> SubagentRun {
        SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Check", brief: "Check the change.",
                    workingDirectory: bot.workspace)
    }

    /// Home, local and remote task, and sub-agent contexts, with the given file texts.
    private func contexts(_ bot: Bot, instructions: String, team: String) -> [String] {
        let task = BotTask(for: bot, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Do it")
        return [
            BotContext.sessionPreamble(bot: bot, memory: "", sharedMemory: "", history: [], instructions: instructions, team: team),
            BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [], instructions: instructions, team: team),
            BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [], machine: "Far Mac",
                                    instructions: instructions, team: team),
            BotContext.subagentPreamble(bot: bot, run: run(bot), callerDescription: "Lead", memory: "", sharedMemory: "",
                                        instructions: instructions, team: team),
        ]
    }

    @Test func workspaceReadsInstructionsFromTheFileIntoAgentsAndGemini() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Scout", workspace: root.appendingPathComponent("scout").path)
        let shared = root.appendingPathComponent("MEMORY.md").path
        try FileManager.default.createDirectory(atPath: bot.workspace, withIntermediateDirectories: true)
        try "# Role\n\nTake specs from Product Fox; hand PRs to QA Duck.\n"
            .write(to: BotDocument.instructions.url(for: bot), atomically: true, encoding: .utf8)
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        for name in ["AGENTS.md", "GEMINI.md"] {
            let text = Workspace.read((bot.workspace as NSString).appendingPathComponent(name))
            #expect(text.contains("# Role\n\nTake specs from Product Fox; hand PRs to QA Duck."))
            #expect(text.contains("`INSTRUCTIONS.md` in this folder"))
            #expect(text.contains("don't change it unless they ask you to"))
            #expect(!text.contains(none))
        }

        // Edits to the file reach AGENTS.md at the next prepare (before each turn).
        try "Review pull requests only.".write(to: BotDocument.instructions.url(for: bot), atomically: true, encoding: .utf8)
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        let agents = Workspace.read((bot.workspace as NSString).appendingPathComponent("AGENTS.md"))
        #expect(agents.contains("Review pull requests only."))
        #expect(!agents.contains("Product Fox"))
    }

    @Test func everyContextCarriesTheFileOverTheLegacyField() {
        let bot = Bot(name: "Scout", instructions: "Old field text", workspace: "/tmp/scout")
        for context in contexts(bot, instructions: "# Role\nShip it.\n", team: "") {
            #expect(context.contains("<instructions>\n# Role\nShip it.\n</instructions>"))
            #expect(!context.contains("Old field text"))
        }
        #expect(BotContext.agentsFile(bot: bot, sharedMemoryPath: "/b/MEMORY.md", instructions: "# Role\nShip it.").contains("Ship it."))
        // Until the field moves into the file, it still counts.
        for context in contexts(bot, instructions: "  \n", team: "") {
            #expect(context.contains("<instructions>\nOld field text\n</instructions>"))
        }
    }

    @Test func emptyOrMissingInstructionsFallBackToAskingTheOwner() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Scout", workspace: root.appendingPathComponent("scout").path)
        try Workspace.prepare(bot: bot, sharedMemoryPath: root.appendingPathComponent("MEMORY.md").path)
        #expect(!FileManager.default.fileExists(atPath: BotDocument.instructions.url(for: bot).path))
        #expect(Workspace.read((bot.workspace as NSString).appendingPathComponent("AGENTS.md")).contains(none))
        #expect(BotContext.agentsFile(bot: bot, sharedMemoryPath: "/b/MEMORY.md", instructions: " \n\n ").contains(none))
        for context in contexts(bot, instructions: "\n", team: "") {
            #expect(!context.contains("<instructions>"))
        }
        #expect(try BotDocumentDraft(bot: bot, document: .instructions).text.isEmpty)
    }

    @Test func legacyFieldMovesIntoTheFileOnce() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var bot = Bot(name: "Scout", instructions: "  Work with Product Fox.\n", workspace: root.appendingPathComponent("scout").path)
        let file = BotDocument.instructions.url(for: bot)
        // Before it moves, the editor starts from the field.
        #expect(try BotDocumentDraft(bot: bot, document: .instructions).text == bot.instructions)

        #expect(try Workspace.migrateInstructions(of: &bot))
        #expect(bot.instructions.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Work with Product Fox.\n")

        // Once moved, the file is the source: emptying or deleting it doesn't bring the field back.
        #expect(try Workspace.migrateInstructions(of: &bot) == false)
        try "".write(to: file, atomically: true, encoding: .utf8)
        #expect(try Workspace.migrateInstructions(of: &bot) == false)
        #expect(Workspace.read(file.path).isEmpty)
        try FileManager.default.removeItem(at: file)
        #expect(try Workspace.migrateInstructions(of: &bot) == false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func existingFileWinsOverTheFieldWithoutLosingEither() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var bot = Bot(name: "Scout", instructions: "From bot.json", workspace: root.path)
        let file = BotDocument.instructions.url(for: bot)
        try "From the file".write(to: file, atomically: true, encoding: .utf8)
        #expect(try Workspace.migrateInstructions(of: &bot) == false)
        #expect(bot.instructions == "From bot.json")
        #expect(Workspace.read(file.path) == "From the file")
        #expect(BotContext.instructions(of: bot, file: Workspace.read(file.path)) == "From the file")

        // A file that already says the same thing just clears the field.
        try "From bot.json\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try Workspace.migrateInstructions(of: &bot))
        #expect(bot.instructions.isEmpty)
        #expect(Workspace.read(file.path) == "From bot.json\n")
    }

    @Test func olderBotJSONStillDecodesItsInstructions() throws {
        let json = #"{"id":"8C1F6A2E-5B7D-4E8A-9C3B-2A1D0F4E6B71","name":"Scout","emoji":"🔭","title":"","instructions":"Be brief.","accountID":"claude-dev","model":"","workspace":"/tmp/s","createdAt":"2026-10-22T03:00:00Z"}"#
        let bot = try Store.decoder.decode(Bot.self, from: Data(json.utf8))
        #expect(bot.instructions == "Be brief.")
    }

    @Test func teamPlaybookIsInHomeAgentsFileWhenPresentAndOmittedWhenAbsent() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bots = root.appendingPathComponent("BOTS")
        let shared = bots.appendingPathComponent("MEMORY.md").path
        let team = bots.appendingPathComponent("TEAM.md")
        let bot = Bot(name: "Scout", workspace: bots.appendingPathComponent("scout").path)
        let agents = (bot.workspace as NSString).appendingPathComponent("AGENTS.md")
        #expect(BotContext.teamPath(besideSharedMemory: shared) == team.path)
        #expect(SharedDocument.team.url(botsRoot: bots.path) == team)

        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        #expect(!FileManager.default.fileExists(atPath: team.path))
        #expect(!Workspace.read(agents).contains("TEAM.md"))
        #expect(!Workspace.read(agents).contains("Team playbook"))

        try "   \n".write(to: team, atomically: true, encoding: .utf8)
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        #expect(!Workspace.read(agents).contains("Team playbook"))

        try "## Stages\n1. Product Fox writes the spec.\n2. QA Duck tests the PR.\n".write(to: team, atomically: true, encoding: .utf8)
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        let text = Workspace.read(agents)
        #expect(text.contains("## Team playbook\n`\(team.path)` is the playbook"))
        #expect(text.contains("## Stages\n1. Product Fox writes the spec.\n2. QA Duck tests the PR."))
        #expect(text.contains("don't change it unless they ask you to"))
        #expect(Workspace.read(team.path).hasPrefix("## Stages"), "BotChu never writes TEAM.md")
    }

    @Test func teamPlaybookIsInTaskAndSubagentContextsAsInstructionsWhenPresent() {
        let bot = Bot(name: "Scout", workspace: "/tmp/scout")
        let playbook = "## Handoffs\nHand every PR to QA Duck."
        for context in contexts(bot, instructions: "", team: "\n\(playbook)\n\n") {
            #expect(context.contains("<team_playbook>\n\(playbook)\n</team_playbook>"))
            #expect(context.contains("these are instructions"))
            let memory = context.components(separatedBy: "<durable_memory>").dropFirst().joined()
            #expect(!memory.contains("Hand every PR"), "The playbook is not memory")
        }
        for team in ["", " \n\t"] {
            for context in contexts(bot, instructions: "", team: team) {
                #expect(!context.contains("team_playbook"))
                #expect(!context.contains("TEAM.md"))
            }
        }
    }

    @Test func draftsTrackChangesAgainstWhatTheyOpenedWith() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = SharedDocument.team.url(botsRoot: root.path)
        var draft = try BotDocumentDraft(url: url, seed: SharedDocument.team.seed)
        #expect(draft.text.isEmpty)
        #expect(!draft.hasChanges)
        draft.text = "# Team"
        #expect(draft.hasChanges)
        try draft.save()
        #expect(!draft.hasChanges)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Team")
        #expect(SharedDocument.memory.seed == BotContext.seedSharedMemory)
    }
}
