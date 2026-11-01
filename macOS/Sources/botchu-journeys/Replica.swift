import AppKit
import BotChuCore

/// The owner's real data as `scripts/replica.sh refresh` keeps it (#422), copied for one run into the
/// run's own folder, which `finish` deletes: every account is already the fake CLI profile and every
/// path points into the replica, here rewritten to point into the copy. The replica itself is only
/// read, and the live folders never: a copy that names a folder in the home folder is refused.
struct Replica {
    static var folder: URL {
        ProcessInfo.processInfo.environment["BOTCHU_REPLICA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BotChu Replica", isDirectory: true)
    }

    let data: URL
    /// Every bot, in the sidebar's order, and the agents among them (not specialists or the remote queue).
    let bots: [Bot]
    let principal: [Bot]
    /// What the journeys left for journey 13 to find: the deliveries journey 11 marked Done.
    final class Left { var done: [UUID] = [] }
    let left = Left()

    /// The bots' tasks as the copy has them now: what the app saved, after its migration.
    func tasks(of bot: Bot) -> [BotTask] { BotHome(workspace: bot.persistencePath).loadTasks() }

    func deliveries() -> [Delivery] { bots.flatMap { InboxFolder(home: BotHome(workspace: $0.persistencePath)).load() } }

    func inbox() -> InboxState { InboxState.load(from: data) }

    /// What the journeys need of a fixture: its folder and the bots they can select.
    var fixture: Fixture { Fixture(data: data, bots: principal, lastItem: [:]) }

    /// Totals only, for the log: never a bot's name or a message.
    var totals: String {
        let tasks = bots.flatMap(tasks(of:))
        let areas = tasks.filter(\.isArea), others = tasks.filter { !$0.isArea && $0.jobRun == nil }
        return "\(bots.count) bots (\(principal.count) agents), \(areas.count) areas (\(areas.filter(\.isArchived).count) hidden), "
            + "\(others.filter { !$0.isArchived }.count) open tasks, \(tasks.filter { $0.jobRun != nil }.count) job runs, "
            + "\(tasks.filter(\.isRemote).count) on hosts, \(deliveries().count) deliveries"
    }

    /// Copies the replica into `data` (APFS clones, so a second or two) and points its paths there.
    static func copy(from replica: URL, into data: URL) throws -> Replica {
        try remove(data)
        try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try AppUnderTest.run("/bin/cp", ["-cR", replica.path, data.path])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var leaks = 0
        let files = FileManager.default.enumerator(at: data, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "json" {
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let original = text
            for (from, to) in [(replica.path, data.path), (escaped(replica.path), escaped(data.path))] {
                text = text.replacingOccurrences(of: from, with: to)
            }
            if text != original { try text.write(to: file, atomically: true, encoding: .utf8) }
            // A path the app could open, not one quoted in a brief or a reply.
            if text.contains(home + "/") || text.contains(escaped(home + "/")),
               let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]), Self.names(home, in: value) {
                leaks += 1
            }
        }
        guard leaks == 0 else { throw HarnessFailure("\(leaks) files of the replica hold a path in the home folder; run scripts/replica.sh refresh") }
        let bots = Store(root: data).loadIndex().compactMap { BotHome(workspace: $0.workspace).loadBot() }
        guard !bots.isEmpty else { throw HarnessFailure("The replica has no bots; run scripts/replica.sh refresh") }
        let copy = Replica(data: data, bots: bots, principal: bots.filter(\.canOwnTasks))
        guard !copy.principal.isEmpty else { throw HarnessFailure("The replica has no agents, only specialists") }
        try copy.markProjectsSynced()
        try copy.reopenDeliveries(Self.reopened)
        return copy
    }

    /// Journey 11 marks up to `repeats` (6) Done, and again when its first try fails.
    static let reopened = 12

    /// When the owner has already marked nearly everything Done, the copy's newest `count` real
    /// deliveries are open again, so journey 11 always has some to mark Done. Only the copy changes.
    func reopenDeliveries(_ count: Int) throws {
        var state = inbox()
        let newest = deliveries().sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        guard newest.filter({ !state[$0.id].done }).count < count else { return }
        for delivery in newest.prefix(count) { state.entries[delivery.id] = InboxState.Entry(read: true) }
        try state.save(to: data)
    }

    /// Whether a JSON value holds a string that is a path in `home`.
    private static func names(_ home: String, in value: Any) -> Bool {
        switch value {
        case let text as String: text == home || text.hasPrefix(home + "/") || text.hasPrefix("~/")
        case let array as [Any]: array.contains { names(home, in: $0) }
        case let object as [String: Any]: object.values.contains { names(home, in: $0) }
        default: false
        }
    }

    /// JSON's escaped form of a path, as some encoders write it.
    private static func escaped(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\/") }

    /// Removes a copy, read-only stub folders and all.
    static func remove(_ folder: URL) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        _ = try AppUnderTest.run("/bin/chmod", ["-R", "u+w", folder.path])
        try FileManager.default.removeItem(at: folder)
    }

    /// Projects' catalog as synced a day from now, listing the areas' repositories, so BotChu
    /// doesn't sync it with GitHub during the run (as `Fixture.markProjectsSynced`).
    func markProjectsSynced() throws {
        let repos = Set(bots.flatMap(tasks(of:)).filter { $0.area?.kind == .repo && !$0.repo.isEmpty }.map(\.repo)).sorted()
        var snapshot = ProjectSnapshot(login: "journeys")
        snapshot.pages = [ProjectSnapshot.Page(etag: "", repos: repos.map { ProjectSnapshot.Listed(nameWithOwner: $0, pushedAt: Date(), updatedAt: Date()) })]
        snapshot.syncedAt = Date().addingTimeInterval(86_400)
        snapshot.fullSyncedAt = Date().addingTimeInterval(86_400)
        try JSONEncoder().encode(snapshot).write(to: data.appendingPathComponent("projects.json"), options: .atomic)
    }

    /// `text` with every bot's name replaced, so a failure says which step, never whose.
    /// An element's title, description and value too (`AXElement.description`): an area's or a
    /// task's title, or a message, would otherwise reach the log.
    func redact(_ text: String) -> String {
        let quoted = text.replacingOccurrences(of: #"(title|desc|value)="[^"]*""#, with: "$1=\"…\"", options: .regularExpression)
        return bots.map(\.name).filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(quoted) { $0.replacingOccurrences(of: $1, with: "a bot") }
    }

    /// Stand-ins the app finds first on its login shell's PATH (`ZDOTDIR`), for every agent CLI,
    /// `gh` and `ssh`: each notes its name and fails, so nothing real starts.
    static let blocked = ["claude", "codex", "agy", "muse", "pi", "gh", "ssh", "botchu-sail"]

    static func writeStandIns(in work: URL) throws -> (zdotdir: URL, log: URL) {
        let bin = work.appendingPathComponent("blocked-bin", isDirectory: true)
        let zdotdir = work.appendingPathComponent("zdotdir", isDirectory: true)
        let log = work.appendingPathComponent("blocked.log")
        for folder in [bin, zdotdir] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        FileManager.default.createFile(atPath: log.path, contents: nil)
        for name in blocked {
            let file = bin.appendingPathComponent(name)
            try "#!/bin/sh\necho \"\(name)\" >> '\(log.path)'\nexit 1\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let path = "path=('\(bin.path)' $path)\n"
        for name in [".zshenv", ".zprofile"] { try path.write(to: zdotdir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return (zdotdir, log)
    }

    /// How many times the app tried each blocked program: names and counts only.
    static func blockedCalls(_ log: URL) -> [String: Int] {
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return Dictionary(lines.map { ($0, 1) }, uniquingKeysWith: +)
    }
}

/// Watches, while the replica journeys run, for an agent CLI, `gh` or `ssh` started under the app
/// under test (#422), from `ps` a few times a second: the stand-ins on PATH stop the app's own
/// lookups, and this catches what reaches a real program another way. Names only.
final class ProcessWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int32: String] = [:]
    private var running = true
    private let app: () -> pid_t?

    init(app: @escaping () -> pid_t?) {
        self.app = app
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                scan()
                usleep(200_000)
            }
        }
    }

    /// The real programs started under the app, by name, with how many times.
    func stop() -> [String: Int] {
        lock.withLock {
            running = false
            return Dictionary(seen.values.map { ($0, 1) }, uniquingKeysWith: +)
        }
    }

    private func scan() {
        guard let root = app(), let output = try? AppUnderTest.run("/bin/ps", ["-axo", "pid=,ppid=,command="]) else { return }
        var parent: [Int32: Int32] = [:], command: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            parent[pid] = ppid
            command[pid] = String(parts[2])
        }
        for (pid, line) in command {
            let words = line.split(separator: " ").prefix(2).map { String($0) }
            guard let name = words.map({ ($0 as NSString).lastPathComponent }).first(where: Replica.blocked.contains),
                  !line.contains("/blocked-bin/") else { continue }
            var ancestor = parent[pid]
            var depth = 0
            while let current = ancestor, current > 1, depth < 32 {
                if current == root {
                    lock.withLock { seen[pid] = name }
                    break
                }
                ancestor = parent[current]
                depth += 1
            }
        }
    }
}
