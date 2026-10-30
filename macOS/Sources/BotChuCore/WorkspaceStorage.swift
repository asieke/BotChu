import Foundation

/// Storage selection never creates a missing mount point or silently picks another disk.
public enum StorageAvailability: Equatable, Sendable {
    case unconfigured, available, unavailable

    public static func read(_ path: String, volumes: [URL]? = nil) -> Self {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unconfigured }
        let path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return .unavailable }
        if path.hasPrefix("/Volumes/") {
            let mounted = volumes ?? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []
            guard mounted.contains(where: { $0.path != "/" && StorageMove.contains(path, under: $0.path) }) else { return .unavailable }
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isWritableFile(atPath: path) else { return .unavailable }
        return .available
    }

    public var label: String {
        switch self {
        case .unconfigured: "Not configured"
        case .available: "Available"
        case .unavailable: "Unavailable — reconnect the drive or choose an existing folder"
        }
    }
}

extension Store {
    /// Finish association updates after an interrupted explicit move. A journal written before
    /// moving anything is harmless; ambiguous copies remain untouched and require owner review.
    public func recoverStorageMove() throws -> StorageMove? {
        let journal = root.appendingPathComponent("storage-move.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return nil }
        let move = try JSONDecoder().decode(StorageMove.self, from: Data(contentsOf: journal))
        let sourceExists = FileManager.default.fileExists(atPath: move.source)
        let destinationExists = FileManager.default.fileExists(atPath: move.destination)
        if sourceExists && !destinationExists {
            try FileManager.default.removeItem(at: journal)
            return nil
        }
        guard !sourceExists, destinationExists else {
            throw StorageMove.Problem("An interrupted storage move needs review. Keep both folders and storage-move.json; no new turns will start.")
        }
        if move.kind == .repository {
            // Rare startup recovery: repair registrations before any task can use this checkout.
            // No shell, hooks, fetch or file contents are involved.
            func git(_ arguments: [String], output: URL?) throws {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", move.destination] + arguments
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                var handle: FileHandle?
                if let output {
                    FileManager.default.createFile(atPath: output.path, contents: nil)
                    handle = try FileHandle(forWritingTo: output)
                }
                defer { try? handle?.close() }
                process.standardOutput = handle ?? FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw StorageMove.Problem("Git worktree repair needs review before new turns can start.") }
            }
            let listing = root.appendingPathComponent("storage-move-worktrees.txt")
            defer { try? FileManager.default.removeItem(at: listing) }
            try git(["worktree", "list", "--porcelain", "-z"], output: listing)
            let paths = try String(contentsOf: listing, encoding: .utf8).split(separator: "\0").compactMap {
                $0.hasPrefix("worktree ") ? move.replacing(String($0.dropFirst(9))) : nil
            }
            try git(["worktree", "repair"] + paths, output: nil)
        }
        var entries = loadIndex()
        for i in entries.indices {
            entries[i].workspace = move.replacing(entries[i].workspace)
            let home = BotHome(workspace: entries[i].workspace)
            guard var bot = home.loadBot(), !bot.isRemoteQueue else { continue }
            bot.workspace = move.replacing(bot.workspace)
            try home.save(bot)
            for var task in home.loadTasks() where task.hostID == nil {
                task.checkout = move.replacing(task.checkout)
                task.folder = task.folder.map(move.replacing)
                try home.save(task)
            }
        }
        try saveIndex(entries)
        // The app removes the journal only after updating its saved repository locations too.
        return move
    }
}

/// A local, read-only view of the checkout. Counts describe the last fetched upstream, never an
/// assertion that anything has been uploaded. Remote locations aren't probed on this Mac.
public struct CheckoutStatus: Equatable, Sendable {
    /// On this Mac; on a host, which isn't probed from here; not cloned yet; or one git couldn't read.
    public enum Kind: Equatable, Sendable { case local, remote, missing, unavailable }

    public var kind: Kind
    /// Changed, staged or untracked files.
    public var dirty = false
    /// Commits ahead of and behind the fetched upstream.
    public var ahead = 0
    public var behind = 0
    public var detail: String
    public var fetchedAt: Date?

    public init(kind: Kind, dirty: Bool = false, ahead: Int = 0, behind: Int = 0, detail: String, fetchedAt: Date? = nil) {
        self.kind = kind; self.dirty = dirty; self.ahead = ahead; self.behind = behind; self.detail = detail; self.fetchedAt = fetchedAt
    }

    /// The whole state in words, such as "Checkout · clean · Behind 9".
    public var label: String {
        switch kind {
        case .remote: return "Elsewhere"
        case .missing: return "No checkout"
        case .unavailable: return "Checkout · unavailable"
        case .local:
            var parts = [dirty ? "Checkout · local changes" : "Checkout · clean"]
            if ahead > 0 { parts.append("Ahead \(ahead)") }
            if behind > 0 { parts.append("Behind \(behind)") }
            return parts.joined(separator: " · ")
        }
    }

    /// What the Projects table's Checkout column shows of it, in order (#321).
    public enum Mark: Equatable, Sendable {
        case changes, ahead(Int), behind(Int), none, elsewhere, unavailable

        /// Its SF Symbol, beside the count if it has one; none is a dash.
        public var symbol: String? {
            switch self {
            case .changes: "pencil"
            case .ahead: "arrow.up"
            case .behind: "arrow.down"
            case .none: nil
            case .elsewhere: "network"
            case .unavailable: "exclamationmark.triangle.fill"
            }
        }

        public var count: Int? {
            switch self {
            case .ahead(let count), .behind(let count): count
            case .changes, .none, .elsewhere, .unavailable: nil
            }
        }
    }

    /// Local changes, then the commits ahead and behind; nothing for a clean, current checkout.
    public var marks: [Mark] {
        switch kind {
        case .remote: return [.elsewhere]
        case .missing: return [.none]
        case .unavailable: return [.unavailable]
        case .local: return (dirty ? [.changes] : []) + (ahead > 0 ? [.ahead(ahead)] : []) + (behind > 0 ? [.behind(behind)] : [])
        }
    }

    /// Each location's checkout (with the name of the computer it is on), at most `atOnce` at a time
    /// and off the caller's actor, so a whole table takes them in one update (#321).
    public static func read(_ places: [RepoLocation: String], atOnce: Int = 4) async -> [RepoLocation: Self] {
        // Swift 6.4 can miscompile tuple results of task-group children in optimized builds; each child
        // returns a named struct: https://github.com/swiftlang/swift/issues/93208
        struct Reading: Sendable { let location: RepoLocation; let status: CheckoutStatus }
        let places = Array(places)
        return await withTaskGroup(of: Reading.self) { group in
            var next = 0, statuses: [RepoLocation: Self] = [:]
            func start() {
                let (location, host) = places[next]
                group.addTask { Reading(location: location, status: await read(location, host: host)) }
                next += 1
            }
            while next < places.count, next < atOnce { start() }
            while let reading = await group.next() {
                statuses[reading.location] = reading.status
                if next < places.count { start() }
            }
            return statuses
        }
    }

    public static func read(_ location: RepoLocation, host: String) async -> Self {
        guard location.hostID == nil else { return Self(kind: .remote, detail: "\(host): \(location.path)") }
        let path = location.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &directory) else {
            return Self(kind: .missing, detail: path)
        }
        // git itself, not through the login shell: one process per checkout, every 30 seconds.
        let status = await Shell.execute("/usr/bin/git", ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: path, input: nil, timeout: Shell.timeout)
        guard status.ok else { return Self(kind: .unavailable, detail: path) }
        var fetchHead = path + "/.git/FETCH_HEAD"
        if !directory.boolValue {
            // A worktree's .git is a file, and git keeps its FETCH_HEAD apart.
            let fetch = await Shell.execute("/usr/bin/git", ["rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], in: path, input: nil, timeout: Shell.timeout)
            fetchHead = fetch.ok ? fetch.lastLine ?? "" : ""
        }
        let fetched = (try? FileManager.default.attributesOfItem(atPath: fetchHead)[.modificationDate]) as? Date
        return parse(status.output, path: path, fetchedAt: fetched)
    }

    public static func parse(_ output: String, path: String, fetchedAt: Date?) -> Self {
        let lines = output.split(separator: "\n")
        var status = Self(kind: .local, dirty: lines.contains { !$0.hasPrefix("# ") }, detail: path, fetchedAt: fetchedAt)
        if let counts = lines.first(where: { $0.hasPrefix("# branch.ab ") })?.split(separator: " "), counts.count == 4 {
            status.ahead = max(0, Int(counts[2]) ?? 0)
            status.behind = max(0, -(Int(counts[3]) ?? 0))
        }
        return status
    }
}

/// Explicit owner-approved relocation, separate from changing defaults and from Janitor cleanup.
public struct StorageMove: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case bot, repository }
    public var id: String { source }
    public var source: String
    public var destination: String
    public var kind: Kind
    public init(source: String, destination: String, kind: Kind) {
        self.source = source; self.destination = destination; self.kind = kind
    }
    public static func contains(_ path: String, under root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
    public func replacing(_ path: String) -> String {
        Self.contains(path, under: source) ? destination + path.dropFirst(source.count) : path
    }
    public func validate() throws {
        guard source.hasPrefix("/"), destination.hasPrefix("/"), source != "/",
              !Self.contains(destination, under: source), !Self.contains(source, under: destination),
              FileManager.default.fileExists(atPath: source),
              (try? FileManager.default.attributesOfItem(atPath: destination)) == nil,
              StorageAvailability.read((destination as NSString).deletingLastPathComponent) == .available else {
            throw Problem("Move unavailable: source missing, destination already exists, or destination drive is unavailable.")
        }
    }

    public func perform() async throws {
        try validate()
        let files = FileManager.default
        var worktrees: [String] = []
        if kind == .repository {
            let listing = await Shell.run(["git", "worktree", "list", "--porcelain", "-z"], in: source)
            guard listing.ok else { throw Problem("Couldn't inspect the repository's worktrees. Nothing moved.") }
            worktrees = listing.output.split(separator: "\0").compactMap {
                $0.hasPrefix("worktree ") ? String($0.dropFirst(9)) : nil
            }
            let type = try files.attributesOfItem(atPath: source + "/.git")[.type] as? FileAttributeType
            if type == .typeRegular {
                let moved = await Shell.run(["git", "worktree", "move", "--", source, destination], in: source, timeout: Shell.longTimeout)
                guard moved.ok else { throw Problem("Git refused to move this worktree. Nothing was overwritten.") }
                return
            }
        }
        try await Task.detached { try FileManager.default.moveItem(atPath: source, toPath: destination) }.value
        if kind == .repository {
            let paths = worktrees.filter { $0 != source }.map(replacing)
            let repaired = await Shell.run(["git", "worktree", "repair"] + paths, in: destination)
            if !repaired.ok {
                do {
                    try files.moveItem(atPath: destination, toPath: source)
                    _ = await Shell.run(["git", "worktree", "repair"] + worktrees.filter { $0 != source }, in: source)
                } catch { throw Problem("Git repair failed; the folder is at \(destination). Keep the move journal for recovery.") }
                throw Problem("Git repair failed. The repository was returned to its original location.")
            }
        }
    }
    public struct Problem: Error, LocalizedError, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
