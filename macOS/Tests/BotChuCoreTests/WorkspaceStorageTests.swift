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

    /// What the Projects table's Checkout column draws (#321): the counts and changes as fields, and
    /// the same sentence as before for its tooltip.
    @Test func checkoutStatusKeepsCountsChangesAndKindApart() async throws {
        let behind = CheckoutStatus.parse("# branch.oid 1a2b\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -9\n", path: "/repo", fetchedAt: nil)
        #expect(behind == CheckoutStatus(kind: .local, behind: 9, detail: "/repo"))
        #expect(behind.label == "Checkout · clean · Behind 9")
        #expect(behind.marks == [.behind(9)])
        #expect(behind.marks.map(\.symbol) == ["arrow.down"] && behind.marks.map(\.count) == [9])
        let ahead = CheckoutStatus.parse("# branch.head main\n# branch.ab +2 -0\n1 .M N... 100644 100644 100644 a b Sources/App.swift\n", path: "/repo", fetchedAt: nil)
        #expect(ahead == CheckoutStatus(kind: .local, dirty: true, ahead: 2, detail: "/repo"))
        #expect(ahead.label == "Checkout · local changes · Ahead 2")
        #expect(ahead.marks == [.changes, .ahead(2)])
        #expect(ahead.marks.map(\.symbol) == ["pencil", "arrow.up"] && ahead.marks.map(\.count) == [nil, 2])
        // No upstream: no counts; clean and current shows nothing.
        let current = CheckoutStatus.parse("# branch.head feature\n", path: "/repo", fetchedAt: nil)
        #expect(current == CheckoutStatus(kind: .local, detail: "/repo") && current.marks.isEmpty)

        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = await CheckoutStatus.read(RepoLocation(path: root.path + "/absent"), host: "This Mac")
        #expect(missing == CheckoutStatus(kind: .missing, detail: root.path + "/absent"))
        #expect(missing.label == "No checkout")
        #expect(missing.marks == [.none] && missing.marks[0].symbol == nil)
        // A host's checkout isn't probed from this Mac, even at a path that exists here.
        let remote = await CheckoutStatus.read(RepoLocation(hostID: UUID(), path: root.path), host: "omarchy")
        #expect(remote == CheckoutStatus(kind: .remote, detail: "omarchy: \(root.path)"))
        #expect(remote.label == "Elsewhere")
        #expect(remote.marks == [.elsewhere] && remote.marks[0].symbol == "network")
        try FileManager.default.createDirectory(atPath: root.path + "/broken/.git", withIntermediateDirectories: true)
        let broken = await CheckoutStatus.read(RepoLocation(path: root.path + "/broken"), host: "This Mac")
        #expect(broken.kind == .unavailable && broken.label == "Checkout · unavailable" && broken.marks == [.unavailable])

        // The column sorts none, hosts, unreadable, then by changes, ahead and behind.
        let order = [missing, remote, broken, current, behind, CheckoutStatus(kind: .local, ahead: 1, detail: "/repo"),
                     CheckoutStatus(kind: .local, ahead: 1, behind: 3, detail: "/repo"), CheckoutStatus(kind: .local, dirty: true, detail: "/repo"), ahead]
        #expect(order.map(\.sortKey) == order.map(\.sortKey).sorted() && Set(order.map(\.sortKey)).count == order.count)
    }

    /// A table's checkouts are read together, off the main actor, into one answer (#321): each
    /// local one by git itself, with its upstream's counts and when it was last fetched.
    @Test func checkoutsAreReadTogetherWithCountsFromGit() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String], in directory: String) async throws {
            let result = await Shell.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false"] + args, in: directory)
            #expect(result.ok, "git fixture failed: \(result.errors)")
            try #require(result.ok)
        }
        let origin = root.appendingPathComponent("origin").path
        try await git(["init", "-b", "main", origin], in: root.path)
        for n in 1...3 { try await git(["commit", "--allow-empty", "-m", "Commit \(n)"], in: origin) }
        let behind = root.appendingPathComponent("behind").path, dirty = root.appendingPathComponent("dirty").path
        try await git(["clone", "-q", origin, behind], in: root.path)
        try await git(["reset", "-q", "--hard", "HEAD~2"], in: behind)
        try await git(["clone", "-q", origin, dirty], in: root.path)
        try await git(["commit", "--allow-empty", "-m", "Local"], in: dirty)
        try "draft".write(toFile: dirty + "/notes.txt", atomically: true, encoding: .utf8)
        try await git(["fetch", "-q"], in: behind)
        var places: [RepoLocation: String] = [RepoLocation(path: behind): "This Mac", RepoLocation(path: dirty): "This Mac",
                                              RepoLocation(hostID: UUID(), path: "~/src/remote"): "omarchy"]
        for n in 0..<27 { places[RepoLocation(path: root.path + "/missing-\(n)")] = "This Mac" }
        let statuses = await CheckoutStatus.read(places)
        #expect(statuses.count == 30)
        let read = try #require(statuses[RepoLocation(path: behind)])
        #expect(read.kind == .local && !read.dirty && read.ahead == 0 && read.behind == 2)
        #expect(read.fetchedAt != nil)
        let changed = try #require(statuses[RepoLocation(path: dirty)])
        #expect(changed.kind == .local && changed.dirty && changed.ahead == 1 && changed.behind == 0)
        #expect(statuses.values.filter { $0.kind == .missing }.count == 27)
        #expect(statuses.values.filter { $0.kind == .remote }.count == 1)
        // A worktree's .git is a file, and git keeps each worktree's FETCH_HEAD apart.
        let tree = behind + "/.claude/worktrees/task"
        try await git(["worktree", "add", "-q", "-b", "task", tree], in: behind)
        let worktree = await CheckoutStatus.read(RepoLocation(path: tree), host: "This Mac")
        #expect(worktree.kind == .local && worktree.fetchedAt == nil)
        try await git(["fetch", "-q", "origin"], in: tree)
        #expect(await CheckoutStatus.read(RepoLocation(path: tree), host: "This Mac").fetchedAt != nil)
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
