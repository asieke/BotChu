import Foundation
import Testing
@testable import BotChuCore

@Suite struct BotDocumentTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-documents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func seedsSoulOnceAndPreservesEditedOrEmptyFiles() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var bot = Bot(name: "Scout", title: "Research helper", workspace: root.appendingPathComponent("scout").path)
        let shared = root.appendingPathComponent("MEMORY.md").path
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        let soul = BotDocument.soul.url(for: bot)
        #expect(try String(contentsOf: soul, encoding: .utf8) == BotContext.seedSoul(bot: bot))
        #expect(BotContext.seedSoul(bot: bot).contains("Research helper"))
        #expect(Workspace.read(root.appendingPathComponent("scout/AGENTS.md").path).contains("`SOUL.md`"))
        for text in ["# Voice\n\nDry humor.\n", ""] {
            try text.write(to: soul, atomically: true, encoding: .utf8)
            bot.name = "Renamed"
            try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
            #expect(try String(contentsOf: soul, encoding: .utf8) == text)
        }
    }

    @Test(arguments: BotDocument.allCases) func editsRoundTripExactMarkdownAndCanBeCleared(document: BotDocument) throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Scout", workspace: root.appendingPathComponent("bot").path)
        var draft = try BotDocumentDraft(bot: bot, document: document)
        #expect(draft.text == document.seed(for: bot))
        draft.text = "# Title\n\n- One\n  - Two ✨\n\n```swift\nlet x = 1\n```\n"
        try draft.save()
        let reloaded = try BotDocumentDraft(bot: bot, document: document)
        #expect(reloaded.text == draft.text)
        draft.text = ""
        try draft.save()
        #expect(try String(contentsOf: document.url(for: bot), encoding: .utf8).isEmpty)
    }

    @Test func refusesToOverwriteNotesChangedWhileEditing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Scout", workspace: root.path)
        let url = BotDocument.memory.url(for: bot)
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        var draft = try BotDocumentDraft(bot: bot, document: .memory)
        draft.text = "My edits"
        try "Agent's newer notes".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try draft.save() }
        #expect(draft.text == "My edits")
        #expect(try String(contentsOf: url, encoding: .utf8) == "Agent's newer notes")
    }

    @Test func unreadableMarkdownIsAnErrorRatherThanAnEmptyDraft() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Scout", workspace: root.path)
        try Data([0xFF, 0xFE, 0xFF]).write(to: BotDocument.soul.url(for: bot))
        #expect(throws: (any Error).self) { try BotDocumentDraft(bot: bot, document: .soul) }
    }

    @Test func homeAndLocalAndRemoteTasksReceivePersonalitySeparatelyFromMemory() {
        let bot = Bot(name: "Scout", instructions: "Research carefully.", workspace: "/tmp/scout")
        let task = BotTask(for: bot, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Research")
        let soul = "# Personality\n\nUse dry humor."
        let contexts = [
            BotContext.sessionPreamble(bot: bot, memory: "Remember tea.", sharedMemory: "", history: [], soul: soul),
            BotContext.taskPreamble(bot: bot, task: task, memory: "Remember tea.", sharedMemory: "", history: [], soul: soul),
            BotContext.taskPreamble(bot: bot, task: task, memory: "Remember tea.", sharedMemory: "", history: [], machine: "Far Mac", soul: soul),
        ]
        for context in contexts {
            #expect(context.contains("<personality>\n\(soul)\n</personality>"))
            #expect(context.contains("<instructions>\nResearch carefully.\n</instructions>"))
            let memory = context.components(separatedBy: "<durable_memory>").last ?? ""
            #expect(!memory.contains("Use dry humor."))
            #expect(memory.contains("Remember tea."))
        }
        #expect(!contexts[2].contains("Read /tmp/scout/SOUL.md"))
    }

    @Test func workspaceMoveKeepsDocumentsAndRejectsCollisions() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Scout", workspace: root.appendingPathComponent("bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        for document in BotDocument.allCases {
            try document.rawValue.write(to: document.url(for: bot), atomically: true, encoding: .utf8)
        }
        let destination = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let collision = destination.appendingPathComponent("SOUL.md")
        try "Someone else's soul".write(to: collision, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try home.move(toWorkspace: destination.path) }
        #expect(home.exists)
        #expect(try String(contentsOf: collision, encoding: .utf8) == "Someone else's soul")
        try FileManager.default.removeItem(at: collision)
        try home.move(toWorkspace: destination.path)
        #expect(!home.exists)
        #expect(BotHome(workspace: destination.path).exists)
        for document in BotDocument.allCases {
            #expect(try String(contentsOf: destination.appendingPathComponent(document.rawValue), encoding: .utf8) == document.rawValue)
            #expect(!FileManager.default.fileExists(atPath: document.url(for: bot).path))
        }
    }
}
