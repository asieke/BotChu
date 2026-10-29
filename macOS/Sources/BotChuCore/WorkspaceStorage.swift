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
    public var label: String
    public var detail: String
    public var fetchedAt: Date?

    public static func read(_ location: RepoLocation, host: String) async -> Self {
        guard location.hostID == nil else { return Self(label: "Elsewhere", detail: "\(host): \(location.path)") }
        let path = location.path
        guard FileManager.default.fileExists(atPath: path + "/.git") else {
            return Self(label: "No checkout", detail: path)
        }
        let status = await Shell.run(["git", "--no-optional-locks", "status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: path)
        guard status.ok else { return Self(label: "Checkout · unavailable", detail: path) }
        let fetch = await Shell.run(["git", "rev-parse", "--path-format=absolute", "--git-path", "FETCH_HEAD"], in: path)
        let fetched = fetch.ok ? fetch.lastLine.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        } : nil
        return parse(status.output, path: path, fetchedAt: fetched)
    }

    public static func parse(_ output: String, path: String, fetchedAt: Date?) -> Self {
        let lines = output.split(separator: "\n")
        let dirty = lines.contains { !$0.hasPrefix("# ") }
        var parts = [dirty ? "Checkout · local changes" : "Checkout · clean"]
        if let counts = lines.first(where: { $0.hasPrefix("# branch.ab ") })?.split(separator: " "), counts.count == 4 {
            if let ahead = Int(counts[2]), ahead > 0 { parts.append("Ahead \(ahead)") }
            if let behind = Int(counts[3]), behind < 0 { parts.append("Behind \(-behind)") }
        }
        return Self(label: parts.joined(separator: " · "), detail: path, fetchedAt: fetchedAt)
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
                let moved = await Shell.run(["git", "worktree", "move", "--", source, destination], in: source)
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
