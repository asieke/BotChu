import Foundation
import Testing
@testable import BotChuCore

@Suite struct PetActivityTests {
    @Test func claudeToolsByName() {
        #expect(BotActivity.classify(toolName: "Read", input: "README.md") == .researching)
        #expect(BotActivity.classify(toolName: "Grep", input: "foo") == .researching)
        #expect(BotActivity.classify(toolName: "Glob", input: "**/*.swift") == .researching)
        #expect(BotActivity.classify(toolName: "WebSearch", input: "swift") == .browsing)
        #expect(BotActivity.classify(toolName: "WebFetch", input: "https://x") == .browsing)
        #expect(BotActivity.classify(toolName: "Edit", input: "a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "Write", input: "a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "MultiEdit", input: "a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "TodoWrite", input: "") == .thinking)
        #expect(BotActivity.classify(toolName: "Task", input: "explore") == .working)
        #expect(BotActivity.classify(toolName: "mcp__linear__get_issue", input: "") == .working)
    }

    @Test func otherCLIsToolNames() {
        // Codex (StreamParsers names its items), Antigravity, Muse and Pi.
        #expect(BotActivity.classify(toolName: "Edit files", input: "update a.swift") == .coding)
        #expect(BotActivity.classify(toolName: "Web search", input: "weather") == .browsing)
        #expect(BotActivity.classify(toolName: "Shell", input: "swift test") == .testing)
        #expect(BotActivity.classify(toolName: "run_command", input: "ls -la") == .researching)
        #expect(BotActivity.classify(toolName: "invoke_subagent", input: "") == .working)
        #expect(BotActivity.classify(toolName: "view_file", input: "a") == .researching)
        #expect(BotActivity.classify(toolName: "replace_file_content", input: "a") == .coding)
        #expect(BotActivity.classify(toolName: "bash", input: "git commit -m x") == .coding)
        #expect(BotActivity.classify(toolName: "read", input: "a") == .researching)
        #expect(BotActivity.classify(toolName: "github.search_issues", input: "") == .researching)
    }

    @Test func shellCommands() {
        #expect(BotActivity.classify(command: "ls -la") == .researching)
        #expect(BotActivity.classify(command: "cat tests/fixture.json") == .researching)
        #expect(BotActivity.classify(command: "grep -rn foo . | head -20") == .researching)
        #expect(BotActivity.classify(command: "git status && git diff") == .researching)
        #expect(BotActivity.classify(command: "sed -n 1,40p a.swift") == .researching)
        #expect(BotActivity.classify(command: "sed -i '' s/a/b/ a.swift") == .coding)
        #expect(BotActivity.classify(command: "cat > notes.md <<'EOF'") == .coding)
        #expect(BotActivity.classify(command: "git add -A && git commit -m wip") == .coding)
        #expect(BotActivity.classify(command: "cd macOS && swift test") == .testing)
        #expect(BotActivity.classify(command: "scripts/check.sh") == .testing)
        #expect(BotActivity.classify(command: "npm run build") == .testing)
        #expect(BotActivity.classify(command: "pytest -q tests/") == .testing)
        #expect(BotActivity.classify(command: "ls && make") == .testing)
        #expect(BotActivity.classify(command: "curl -s https://example.com") == .browsing)
        #expect(BotActivity.classify(command: "python3 tool.py") == .working)
        #expect(BotActivity.classify(command: "echo latest version") == .researching)
        #expect(BotActivity.classify(command: "") == .working)
    }

    @Test func eventsMoveTheActivity() {
        #expect(BotActivity.next(after: .textDelta("hi")) == .thinking)
        #expect(BotActivity.next(after: .toolStarted(id: "1", name: "Read", input: "a")) == .researching)
        #expect(BotActivity.next(after: .toolFinished(id: "1", name: "Read", output: "", isError: false)) == .thinking)
        #expect(BotActivity.next(after: .session("s")) == nil)
        #expect(BotActivity.next(after: .finished) == nil)
    }

    @Test func animationsFallBackToAtlasRows() {
        let atlas = Set(PetAtlas.rows.map(\.name))
        #expect(BotActivity.coding.animation(among: atlas) == "running")
        #expect(BotActivity.researching.animation(among: atlas) == "review")
        #expect(BotActivity.browsing.animation(among: atlas) == "review")
        #expect(BotActivity.thinking.animation(among: atlas) == "waiting")
        #expect(BotActivity.done.animation(among: atlas) == "jumping")
        #expect(BotActivity.greeting.animation(among: atlas) == "waving")
        let withExtras = atlas.union(["coding", "researching"])
        #expect(BotActivity.coding.animation(among: withExtras) == "coding")
        #expect(BotActivity.browsing.animation(among: withExtras) == "researching")
        #expect(BotActivity.idle.animation(among: []) == nil)
        #expect(BotActivity.allCases.allSatisfy { $0.animations.last == "idle" })
    }

    @Test func extrasUseRealAtlasRowsAndCoverActivities() {
        for spec in PetActivitySpec.all {
            let row = PetAtlas.row(named: spec.alias)
            #expect(row != nil, "\(spec.id) aliases \(spec.alias)")
            #expect(row?.frames == spec.frames, "\(spec.id) needs \(row?.frames ?? 0) frames to be sliced as \(spec.alias)")
            #expect(BotActivity.allCases.contains { $0.animations.first == spec.id }, "\(spec.id) is no activity's first choice")
        }
    }

    @Test func statusShowsTheActivity() {
        let bot = Bot(name: "B", workspace: "/tmp/b")
        #expect(BotStatus.make(bot: bot, messages: [], run: nil).activity == .idle)
        #expect(BotStatus.make(bot: bot, messages: [], run: RunState(activity: .coding)).activity == .coding)
        #expect(BotStatus.make(bot: bot, messages: [], run: nil, reaction: .done).activity == .done)
        let failed = [ChatMessage(role: .error, text: "boom")]
        #expect(BotStatus.make(bot: bot, messages: failed, run: nil).activity == .failed)
        #expect(BotStatus.make(bot: bot, messages: failed, run: RunState()).activity == .thinking)
    }
}

@Suite struct PetAtlasTests {
    @Test func rowsMatchTheCodexContract() {
        #expect(PetAtlas.rows.map(\.name) == ["idle", "running-right", "running-left", "waving", "jumping",
                                               "failed", "waiting", "running", "review"])
        #expect(PetAtlas.rows.map(\.frames) == [6, 8, 8, 4, 5, 8, 6, 6, 6])
        #expect(PetAtlas.rows.enumerated().allSatisfy { $0.offset == $0.element.index })
        #expect(PetAtlas.isValidSize(width: 1536, height: 1872))
        #expect(PetAtlas.isValidSize(width: 1536, height: 2288))
        #expect(!PetAtlas.isValidSize(width: 1536, height: 2000))
    }

    @Test func durationsFitAnyFrameCount() {
        let idle = PetAtlas.rows[0]
        #expect(idle.durations(frameCount: 6) == [280, 110, 110, 140, 140, 320])
        #expect(idle.durations(frameCount: 7) == [280, 110, 110, 140, 140, 140, 320])
        #expect(idle.durations(frameCount: 4) == [280, 110, 110, 320])
        #expect(idle.durations(frameCount: 1) == [320])
        #expect(idle.durations(frameCount: 0) == [])
    }
}

@Suite struct PetPackageTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-pet-\(UUID().uuidString)")

    func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func loadsACodexPetWithItsExtras() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // pet.json as the hatch-pet skill writes it.
        try write(#"{"id":"mochi","displayName":"Mochi","description":"A plush companion.","spriteVersionNumber":2,"spritesheetPath":"spritesheet.webp"}"#,
                  "pet/pet.json")
        try write("webp", "pet/spritesheet.webp")
        try write(#"{"version":1,"activities":[{"id":"coding","frames":3,"durations":[110,110,200]},{"id":"testing","frames":2,"durations":[100,200]}]}"#,
                  "pet/activities.json")
        for n in 0..<3 { try write("png", "pet/activities/coding/0\(n).png") }
        try write("png", "pet/activities/testing/00.png")  // one frame missing: not used
        let pet = try #require(PetPackage.load(from: root.appendingPathComponent("pet")))
        #expect(pet.manifest.displayName == "Mochi")
        #expect(pet.manifest.spriteVersionNumber == 2)
        #expect(pet.sheetURL.lastPathComponent == "spritesheet.webp")
        #expect(pet.extras.map(\.id) == ["coding"])
        #expect(pet.extras[0].durations == [110, 110, 200])
        #expect(pet.extras[0].frameURLs.map(\.lastPathComponent) == ["00.png", "01.png", "02.png"])
    }

    @Test func noPetWithoutItsSpritesheet() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"id":"x","displayName":"X","spritesheetPath":"spritesheet.webp"}"#, "pet/pet.json")
        #expect(PetPackage.load(from: root.appendingPathComponent("pet")) == nil)
        try write(#"{"id":"x","displayName":"X","spritesheetPath":"../../secret.webp"}"#, "pet/pet.json")
        try write("x", "secret.webp")
        #expect(PetPackage.load(from: root.appendingPathComponent("pet")) == nil)
    }

    @Test func importsACodexPetFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"id":"puck","displayName":"Puck","spritesheetPath":"spritesheet.webp"}"#, "codex/puck/pet.json")
        try write("webp", "codex/puck/spritesheet.webp")
        let home = BotHome(workspace: root.appendingPathComponent("bot").path)
        try PetPackage.importCodexPet(from: root.appendingPathComponent("codex/puck"), into: home.petURL)
        #expect(home.loadPet()?.manifest.id == "puck")
        #expect(throws: PetError.self) {
            try PetPackage.importCodexPet(from: root.appendingPathComponent("codex"), into: home.petURL)
        }
        // A failed import leaves the pet that was there.
        #expect(home.loadPet()?.manifest.id == "puck")
    }

    @Test func botsWithoutAppearanceStillDecode() throws {
        let json = #"{"id":"8C1F6A2E-5B7D-4E8A-9C3B-2A1D0F4E6B71","name":"Scout","emoji":"🔭","title":"","instructions":"","accountID":"claude-dev","model":"","workspace":"/tmp/s","createdAt":"2026-10-22T03:00:00Z"}"#
        let bot = try Store.decoder.decode(Bot.self, from: Data(json.utf8))
        #expect(bot.appearance == nil)
        var drawn = bot
        drawn.appearance = "A small brass robot"
        let again = try Store.decoder.decode(Bot.self, from: Store.encoder.encode(drawn))
        #expect(again.appearance == "A small brass robot")
    }
}
