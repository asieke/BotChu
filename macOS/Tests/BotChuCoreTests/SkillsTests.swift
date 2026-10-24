import Foundation
import Testing
@testable import BotChuCore

/// Skills: `skills/<slug>/SKILL.md`, shared in the bots folder or a bot's own, given to sessions as
/// a catalog (#76).
@Suite struct SkillsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, skill slug: String, in skills: URL, files: [String] = []) throws {
        let directory = skills.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent(Skills.fileName), atomically: true, encoding: .utf8)
        for file in files {
            let url = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "echo hi".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func skill(_ slug: String, _ text: String, scope: Skill.Scope = .shared) -> Skill {
        Skill(slug: slug, text: text, scope: scope, url: URL(fileURLWithPath: "/b/skills/\(slug)/SKILL.md"))
    }

    // MARK: Frontmatter

    @Test func readsTheScalarsSkillsUse() {
        let text = """
            ---
            name: tea-runbook # a comment
            description: "Brew tea for \\"guests\\" under $50, \\\\ and\\nmore"
            single: 'It''s fine'
            folded: >-
              Browse the web
              and report back.

              Second paragraph.
            literal: |
              line one
                indented
            plain: spans
              two lines
            nested:
              version: 1
            Upper: kept
            ---
            # Title
            """
        let (fields, body) = Skills.frontmatter(of: text)
        #expect(fields["name"] == "tea-runbook")
        #expect(fields["description"] == "Brew tea for \"guests\" under $50, \\ and\nmore")
        #expect(fields["single"] == "It's fine")
        #expect(fields["folded"] == "Browse the web and report back.\nSecond paragraph.")
        #expect(fields["literal"] == "line one\n  indented")
        #expect(fields["plain"] == "spans two lines")
        #expect(fields["nested"] == "version: 1")
        #expect(fields["upper"] == "kept")
        #expect(body == "# Title")
    }

    @Test func aFileWithoutFrontmatterIsAllBody() {
        for text in ["# Just steps\n\n1. Do it", "---\nname: never closed\n", ""] {
            let (fields, body) = Skills.frontmatter(of: text)
            #expect(fields.isEmpty)
            #expect(body == text)
        }
        let windows = Skills.frontmatter(of: "---\r\nname: crlf\r\n---\r\nBody")
        #expect(windows.fields["name"] == "crlf")
        #expect(windows.body == "Body")
    }

    @Test func nameAndDescriptionFallBackToTheFolderAndFirstLine() {
        let bare = skill("deploy-steps", "# Deploying\n\n```sh\nmake\n```\nRun the deploy script, then check the logs.\n")
        #expect(bare.name == "deploy-steps")
        #expect(bare.description == "Run the deploy script, then check the logs.")
        let named = skill("folder", "---\nname: \"  Real   name \"\ndescription: |\n  Two\n  lines\n---\n")
        #expect(named.name == "Real name")
        #expect(named.description == "Two lines")
        let long = skill("long", "---\ndescription: \(String(repeating: "a", count: 2_000))\n---\n")
        #expect(long.summary.count == Skills.maxDescription + 4)
        #expect(long.summary.hasSuffix(" […]"))
    }

    @Test func theShippedExampleParses() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("docs/skills/aside-web-browsing/SKILL.md")
        let example = Skill(slug: "aside-web-browsing", text: try String(contentsOf: url, encoding: .utf8), scope: .shared, url: url)
        #expect(example.name == "aside-web-browsing")
        #expect(example.description.hasPrefix("Browse the web, research live sites"))
        #expect(example.description.hasSuffix("or authenticated web context."))
        #expect(!example.description.contains("\n"))
    }

    // MARK: Finding them

    @Test func discoversSkillFoldersByName() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("---\nname: zebra\ndescription: Last\n---\n", skill: "zebra", in: root, files: ["scripts/run.sh", "references/api.md"])
        try write("---\nname: alpha\ndescription: First\n---\n", skill: "alpha", in: root)
        try write("hidden", skill: ".hidden", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)
        try "loose".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        // A skill kept elsewhere and linked in counts too.
        let elsewhere = try folder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try write("---\nname: linked\ndescription: Linked in\n---\n", skill: "linked", in: elsewhere, files: ["scripts/a.sh"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("linked"))

        let skills = Skills.discover(in: root, scope: .shared)
        #expect(skills.map(\.name) == ["alpha", "linked", "zebra"])
        #expect(skills.map(\.resourceCount) == [0, 1, 2])
        #expect(skills.allSatisfy { $0.scope == .shared })
        #expect(skills[2].url == root.appendingPathComponent("zebra/SKILL.md"))
        #expect(Skills.discover(in: root.appendingPathComponent("missing"), scope: .bot).isEmpty)
    }

    @Test func aBotGetsItsOwnSkillsAndTheSharedOnesItKeepsOn() {
        var bot = Bot(name: "Scout", workspace: "/b/scout")
        let shared = [skill("browse", "---\ndescription: Shared browse\n---\n"), skill("deploy", "---\ndescription: Deploy\n---\n"),
                      skill("tea", "---\ndescription: Tea\n---\n")]
        let own = [skill("browse", "---\ndescription: My browse\n---\n", scope: .bot), skill("notes", "---\ndescription: Notes\n---\n", scope: .bot)]
        #expect(Skills.active(for: bot, shared: shared, own: own).map(\.description) == ["My browse", "Deploy", "Notes", "Tea"])

        bot.setSharedSkill("tea", enabled: false)
        bot.setSharedSkill("notes", enabled: false)
        #expect(bot.disabledSkills == ["notes", "tea"])
        #expect(!bot.usesSharedSkill("tea"))
        // Only shared skills turn off: a bot's own stay on.
        #expect(Skills.active(for: bot, shared: shared, own: own).map(\.description) == ["My browse", "Deploy", "Notes"])
        bot.setSharedSkill("tea", enabled: true)
        bot.setSharedSkill("notes", enabled: true)
        #expect(bot.disabledSkills == nil)
    }

    @Test func turnedOffSkillsAreSavedWithTheBot() throws {
        var bot = Bot(name: "Scout", workspace: "/b/scout")
        bot.setSharedSkill("tea", enabled: false)
        let decoded = try JSONDecoder().decode(Bot.self, from: try JSONEncoder().encode(bot))
        #expect(decoded.disabledSkills == ["tea"])
        // A bot.json from before skills keeps every shared skill on.
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Bot(name: "Old", workspace: "/b/old"))) as! [String: Any]
        json.removeValue(forKey: "disabledSkills")
        let old = try JSONDecoder().decode(Bot.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(old.disabledSkills == nil)
        #expect(old.usesSharedSkill("tea"))
    }

    // MARK: Making one

    @Test func newSkillsStartFromATemplateThatReadsBack() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try Skills.create(name: "Aside Web Browsing", description: "Browse with \"aside\" for under $50\nand more", in: root)
        #expect(url == root.appendingPathComponent("aside-web-browsing/SKILL.md"))
        let made = try #require(Skills.discover(in: root, scope: .bot).first)
        #expect(made.name == "aside-web-browsing")
        #expect(made.description == "Browse with \"aside\" for under $50 and more")
        #expect(made.text.contains("# Aside Web Browsing"))
        #expect(throws: Skills.Problem.exists("aside-web-browsing")) {
            try Skills.create(name: "aside web browsing", description: "", in: root)
        }
        #expect(Skills.slug("!!!") == "skill")
        #expect(Skills.slug("Bot helper") == "bot-helper")
        #expect(Skills.slug("bot") == "bot")
    }

    // MARK: Sessions

    private let bot = Bot(name: "Scout", workspace: "/b/scout")
    private var skills: [Skill] {
        [skill("browse", "---\nname: browse\ndescription: Browse the web with aside.\n---\n# Browse\n\nSECRET-STEP: quote dollars."),
         skill("notes", "---\nname: notes\ndescription: Keep notes.\n---\nNOTES-BODY", scope: .bot)]
    }

    @Test func localSessionsGetOnlyTheCatalog() {
        let task = BotTask(for: bot, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Do it")
        let run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Check", brief: "Check.", workingDirectory: "/tmp/repo")
        let contexts = [
            BotContext.agentsFile(bot: bot, sharedMemoryPath: "/b/MEMORY.md", skills: skills),
            BotContext.sessionPreamble(bot: bot, memory: "", sharedMemory: "", history: [], skills: skills),
            BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [], skills: skills),
            BotContext.subagentPreamble(bot: bot, run: run, callerDescription: "Lead", memory: "", sharedMemory: "", skills: skills),
        ]
        for context in contexts {
            #expect(context.contains("- `browse` (`/b/skills/browse/SKILL.md`) — Browse the web with aside."))
            #expect(context.contains("- `notes` (`/b/skills/notes/SKILL.md`) — Keep notes."))
            #expect(!context.contains("SECRET-STEP"))
            #expect(!context.contains("NOTES-BODY"))
        }
        for preamble in contexts.dropFirst() { #expect(preamble.contains("<skills>")) }
        #expect(contexts[0].contains("## Skills"))
        #expect(contexts[0].contains("`/b/skills`"))
        #expect(contexts[0].contains("write or change one in the shared folder only when your owner asks"))
    }

    @Test func sessionsOnAHostGetTheSkillsInFull() {
        let task = BotTask(for: bot, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Do it")
        let run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Check", brief: "Check.", workingDirectory: "/tmp/repo",
                              hostID: UUID())
        for context in [
            BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [], machine: "Far Mac", skills: skills),
            BotContext.subagentPreamble(bot: bot, run: run, callerDescription: "Lead", memory: "", sharedMemory: "", skills: skills),
        ] {
            #expect(context.contains("<skill name=\"browse\">\n---\nname: browse"))
            #expect(context.contains("SECRET-STEP: quote dollars.\n</skill>"))
            #expect(context.contains("NOTES-BODY"))
            #expect(!context.contains("/b/skills/browse/SKILL.md"))
        }
    }

    @Test func skillsTooLongForAHostAreListedByName() {
        let task = BotTask(for: bot, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Do it")
        let huge = skill("huge", "---\ndescription: Very long.\n---\n" + String(repeating: "x", count: BotContext.maxSkillCharacters))
        let context = BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [], machine: "Far Mac",
                                              skills: [huge] + skills)
        #expect(context.contains("- `huge` — Very long. (too long to send here)"))
        #expect(!context.contains("xxxxxxxxxx"))
        #expect(context.contains("NOTES-BODY"))
        #expect(context.contains("except the ones listed after them"))
    }

    @Test func noSkillsLeavesThePreamblesAsTheyWere() {
        let task = BotTask(for: bot, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Do it")
        #expect(!BotContext.sessionPreamble(bot: bot, memory: "", sharedMemory: "", history: []).contains("<skills>"))
        #expect(!BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [], machine: "Far Mac").contains("<skills>"))
        #expect(BotContext.agentsFile(bot: bot, sharedMemoryPath: "/b/MEMORY.md").contains("## Skills"))
    }

    @Test func memoryRulesSendRunbooksToSkills() {
        let task = BotTask(for: bot, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Do it")
        let run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "Check", brief: "Check.", workingDirectory: "/tmp/repo")
        let files = [BotContext.agentsFile(bot: bot, sharedMemoryPath: "/b/MEMORY.md"),
                     BotContext.sessionPreamble(bot: bot, memory: "", sharedMemory: "", history: []),
                     BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [])]
        let tags = [BotContext.taskPreamble(bot: bot, task: task, memory: "", sharedMemory: "", history: [], machine: "Far Mac"),
                    BotContext.subagentPreamble(bot: bot, run: run, callerDescription: "Lead", memory: "", sharedMemory: "")]
        for context in files + tags {
            #expect(context.contains("**Memory vs. skills:** Memory holds one-line facts and preferences."))
        }
        for context in files { #expect(context.contains("`skills/<name>/SKILL.md` in your own workspace, never in a repository you work on")) }
        for context in tags { #expect(context.contains("draft that file in your reply for your owner to add in BotChu ▸ Skills")) }
        #expect(BotContext.memoryOverview.contains("go in skills"))
    }

    // MARK: Workspace

    @Test func theWorkspaceListsActiveSkillsInAgentsAndGemini() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var bot = Bot(name: "Scout", workspace: root.appendingPathComponent("scout").path)
        let shared = root.appendingPathComponent("MEMORY.md").path
        try write("---\nname: browse\ndescription: Browse the web.\n---\nBROWSE-BODY", skill: "browse", in: root.appendingPathComponent("skills"))
        try write("---\nname: tea\ndescription: Brew tea.\n---\n", skill: "tea", in: root.appendingPathComponent("skills"))
        try write("---\nname: mine\ndescription: Only Scout's.\n---\n", skill: "mine", in: Skills.folder(of: bot))
        bot.setSharedSkill("tea", enabled: false)
        try Workspace.prepare(bot: bot, sharedMemoryPath: shared)
        for file in ["AGENTS.md", "GEMINI.md"] {
            let text = Workspace.read((bot.workspace as NSString).appendingPathComponent(file))
            #expect(text.contains("- `browse` (`\(root.appendingPathComponent("skills/browse/SKILL.md").path)`) — Browse the web."))
            #expect(text.contains("- `mine` (`\(Skills.folder(of: bot).appendingPathComponent("mine/SKILL.md").path)`) — Only Scout's."))
            #expect(!text.contains("`tea`"))
            #expect(!text.contains("BROWSE-BODY"))
        }
    }

    @Test func aBotsOwnSkillsMoveWithItsWorkspace() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = Bot(name: "Scout", workspace: root.appendingPathComponent("bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        try write("---\nname: mine\n---\n", skill: "mine", in: Skills.folder(of: bot), files: ["scripts/run.sh"])
        let destination = root.appendingPathComponent("moved")
        try home.move(toWorkspace: destination.path)
        let moved = Skills.discover(in: destination.appendingPathComponent("skills"), scope: .bot)
        #expect(moved.map(\.name) == ["mine"])
        #expect(moved.first?.resourceCount == 1)
        #expect(!FileManager.default.fileExists(atPath: Skills.folder(of: bot).path))
    }
}
