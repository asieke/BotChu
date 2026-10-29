import Foundation
import Testing
@testable import BotChuCore

@Suite struct WorkspaceStorageTests {
    func folder() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("botchu-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func missingArchiveNeverCreatesAFallbackAndRequiresAMount() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(StorageAvailability.read("") == .unconfigured)
        #expect(StorageAvailability.read(root.path) == .available)
        #expect(StorageAvailability.read(root.path + "/absent") == .unavailable)
        #expect(StorageAvailability.read("/Volumes/Missing-\(UUID().uuidString)/Archive", volumes: [URL(fileURLWithPath: "/")]) == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: root.path + "/absent"))
    }

    @Test func checkoutLabelsDistinguishDirtyAndDivergenceWithoutClaimingUpload() {
        let date = Date(timeIntervalSince1970: 100)
        let clean = CheckoutStatus.parse("# branch.head main\n# branch.ab +2 -3\n", path: "/repo", fetchedAt: date)
        #expect(clean.label == "Checkout · clean · Ahead 2 · Behind 3")
        #expect(clean.fetchedAt == date && clean.detail == "/repo")
        #expect(CheckoutStatus.parse("# branch.head main\n? local.txt\n", path: "/repo", fetchedAt: nil).label == "Checkout · local changes")
    }

    @Test(arguments: [false, true]) func movingRepositoryRepairsNestedWorktreesAndRefusesOverwrite(interrupted: Bool) async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("repo").path, destination = root.appendingPathComponent("moved").path
        func git(_ args: [String], in directory: String) async throws {
            let result = await Shell.run(["git"] + args, in: directory)
            #expect(result.ok, "git fixture failed: \(result.errors)")
            try #require(result.ok)
        }
        try await git(["init", source], in: root.path)
        try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"], in: source)
        let tree = source + "/.claude/worktrees/task"
        try await git(["worktree", "add", "-b", "fixture", tree], in: source)
        try "uncommitted data".write(toFile: tree + "/local.txt", atomically: true, encoding: .utf8)
        let move = StorageMove(source: source, destination: destination, kind: .repository)
        if interrupted {
            let store = Store(root: root.appendingPathComponent("index"))
            try store.saveIndex([])
            try JSONEncoder().encode(move).write(to: store.root.appendingPathComponent("storage-move.json"))
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            #expect(try store.recoverStorageMove() == move)
        } else { try await move.perform() }
        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try String(contentsOfFile: destination + "/.claude/worktrees/task/local.txt", encoding: .utf8) == "uncommitted data")
        let status = await Shell.run(["git", "status", "--porcelain"], in: destination + "/.claude/worktrees/task")
        #expect(status.ok && status.output.contains("local.txt"))
        let listing = await Shell.run(["git", "worktree", "list", "--porcelain"], in: destination)
        #expect(listing.ok && listing.output.contains(destination + "/.claude/worktrees/task"))
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        #expect(throws: StorageMove.Problem.self) { try move.validate() }
    }

    @Test func interruptedBotMoveRecoversTaskAssociationsIdempotently() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bot").path, destination = root.appendingPathComponent("new-bot").path
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fixture", accountID: "codex-dev", workspace: source)
        let home = BotHome(workspace: source)
        try home.save(bot)
        var task = BotTask(repo: "fixture/repo", checkout: source, brief: "Saved task")
        task.folder = source + "/nested"
        try home.save(task)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: source)])
        let move = StorageMove(source: source, destination: destination, kind: .bot)
        try JSONEncoder().encode(move).write(to: store.root.appendingPathComponent("storage-move.json"))
        try await move.perform()
        #expect(try store.recoverStorageMove() == move)
        #expect(try store.recoverStorageMove() == move)
        #expect(store.loadIndex().first?.workspace == destination)
        let moved = BotHome(workspace: destination)
        #expect(moved.loadBot()?.workspace == destination)
        #expect(moved.loadTasks().first?.folder == destination + "/nested")
        #expect(move.replacing(source + "-other") == source + "-other")
    }

    @Test func janitorStartsReportOnlyAndSetupPreservesEdits() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Janitor.install(in: root.path)
        let policy = root.appendingPathComponent(Janitor.policyPath)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: policy)) as? [String: Any])
        #expect(json["mode"] as? String == "report-only")
        let categories = try #require(json["categories"] as? [String: [String: Any]])
        #expect(categories.count == 4)
        #expect(categories.values.allSatisfy { $0["enabled"] as? Bool == false && $0["approval"] is NSNull && $0["minimumAgeDays"] is NSNull })
        try "Owner's edited policy".write(to: policy, atomically: true, encoding: .utf8)
        try Janitor.install(in: root.path)
        #expect(try String(contentsOf: policy, encoding: .utf8) == "Owner's edited policy")
    }
}
