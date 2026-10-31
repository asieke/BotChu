import Foundation

/// One immutable context/catalog per bot and input revision. File work is ordered on the bot's
/// storage lane, including owned workspace files; callers only capture settings and await it.
/// Every request checks shallow file identities, so atomic saves and linked skill replacements
/// invalidate a snapshot without a watcher or a recursive walk of skill resources.
public final class SessionPreparation: @unchecked Sendable {
    public struct Input: Equatable, Sendable {
        public var bot: Bot
        public var sharedMemoryPath: String
        public var repositoriesPath: String?
        public var machines: [String]
        public var availableBots: [BotRosterEntry]
        /// The bot's Project Areas its `AGENTS.md` lists.
        public var areas: [AreaListing]

        public init(bot: Bot, sharedMemoryPath: String, repositoriesPath: String? = nil,
                    machines: [String] = [], availableBots: [BotRosterEntry] = [], areas: [AreaListing] = []) {
            // Session IDs, model reports, pets, etc. do not change the bot's context.
            var identity = Bot(name: bot.name, emoji: bot.emoji, title: bot.title,
                               instructions: bot.instructions, accountID: "", workspace: bot.workspace, createdAt: .distantPast)
            identity.id = bot.id
            identity.role = bot.role
            identity.disabledSkills = bot.disabledSkills
            self.bot = identity
            self.sharedMemoryPath = sharedMemoryPath
            self.repositoriesPath = repositoriesPath
            self.machines = machines
            self.availableBots = availableBots
            self.areas = areas
        }
    }

    public struct Snapshot: Sendable {
        public let revision: UUID
        public let memory: String
        public let sharedMemory: String
        public let soul: String
        public let instructions: String
        public let team: String
        public let skills: [Skill]
        public let migratedInstructions: Bool
    }

    public struct Statistics: Sendable {
        public var requested = 0
        public var prepared = 0
        public var reused = 0
    }

    private struct Stamp: Equatable {
        var path: String
        var file: FileStamp?
    }

    private struct Cached {
        var input: Input
        var files: [Stamp]
        var owned: [Stamp]
        var snapshot: Snapshot
    }

    private let storage: StorageQueue
    private let lock = NSLock()
    private var latest: [UUID: Input] = [:]
    private var retired: Set<UUID> = []
    private var cache: [UUID: Cached] = [:]
    private var counts = Statistics()

    public init(storage: StorageQueue = .shared) { self.storage = storage }

    public var statistics: Statistics { lock.withLock { counts } }

    /// Called before retiring/deleting a bot's storage. Even requests not enqueued yet cannot
    /// recreate its workspace when the storage lane is reopened after the deletion.
    public func retire(_ botID: UUID) {
        lock.withLock {
            retired.insert(botID)
            latest[botID] = nil
            cache[botID] = nil
        }
    }

    /// Register in the same order the UI captures settings, before the first suspension. The
    /// storage work may be scheduled later, but an older request can never supersede a newer one.
    @MainActor public func prepare(_ input: Input) async throws -> Snapshot {
        try Task.checkCancellation()
        try lock.withLock {
            guard !retired.contains(input.bot.id) else { throw StorageQueue.Failure.retired }
            latest[input.bot.id] = input
            counts.requested += 1
        }
        let result = try await storage.perform(input.bot.workspace + "/" + BotContext.memoryFile, label: "session-preparation") {
            try self.read(input)
        }
        try Task.checkCancellation()
        try checkCurrent(input)
        return result
    }

    private func checkCurrent(_ input: Input) throws {
        try lock.withLock {
            guard !retired.contains(input.bot.id) else { throw StorageQueue.Failure.retired }
            guard latest[input.bot.id] == input else { throw StorageQueue.Failure.superseded }
        }
    }

    private func read(_ input: Input) throws -> Snapshot {
        try checkCurrent(input)
        let bot = input.bot
        let files = try stamps(input)
        let owned = try ownedStamps(bot)
        if let cached = lock.withLock({ cache[bot.id] }), cached.input == input,
           cached.files == files, cached.owned == owned {
            lock.withLock { counts.reused += 1 }
            return cached.snapshot
        }

        var migrated = bot
        let didMigrate = try Workspace.migrateInstructions(of: &migrated)
        try Workspace.seed(bot: migrated, sharedMemoryPath: input.sharedMemoryPath)
        // An external editor can save while a snapshot is read. Retry the whole revision rather
        // than mixing old instructions with new skills, or publishing the pre-save revision.
        for _ in 0..<4 {
            try checkCurrent(input)
            let before = try stamps(input)
            let sharedSkills = Skills.sharedFolder(besideSharedMemory: input.sharedMemoryPath)
            let snapshot = Snapshot(revision: UUID(),
                memory: try text(bot.workspace + "/" + BotContext.memoryFile),
                sharedMemory: try text(input.sharedMemoryPath),
                soul: try text(bot.workspace + "/" + BotContext.soulFile),
                instructions: try text(bot.workspace + "/" + BotContext.instructionsFile),
                team: try text(BotContext.teamPath(besideSharedMemory: input.sharedMemoryPath)),
                skills: Skills.active(for: migrated, sharedFolder: sharedSkills), migratedInstructions: didMigrate)
            guard before == (try stamps(input)) else { continue }
            try checkCurrent(input)
            // This entire read/write runs on one serial lane. A newer request may invalidate
            // it here, but cannot write newer owned content until this work has left the lane.
            try Workspace.prepareOwned(bot: migrated, sharedMemoryPath: input.sharedMemoryPath,
                instructions: snapshot.instructions, team: snapshot.team, repositoriesPath: input.repositoriesPath,
                machines: input.machines, availableBots: input.availableBots, skills: snapshot.skills, areas: input.areas)
            try BotHome(workspace: bot.workspace).prepareDispatch()
            guard before == (try stamps(input)) else { continue }
            let owned = try ownedStamps(bot)
            try checkCurrent(input)
            try lock.withLock {
                guard latest[bot.id] == input, !retired.contains(bot.id) else { throw StorageQueue.Failure.superseded }
                cache[bot.id] = Cached(input: input, files: before, owned: owned, snapshot: snapshot)
                counts.prepared += 1
            }
            return snapshot
        }
        throw Failure.changingFiles
    }

    private func text(_ path: String) throws -> String {
        do { return try String(contentsOfFile: path, encoding: .utf8) }
        catch CocoaError.fileReadNoSuchFile { return "" }
    }

    private func stamp(_ path: String) throws -> Stamp {
        let url = URL(fileURLWithPath: path)
        // stat follows links and includes nanosecond ctime as well as inode/mtime/size.
        return Stamp(path: path, file: FileStamp.of(url))
    }

    private func stamps(_ input: Input) throws -> [Stamp] {
        let bot = input.bot
        var paths = [BotContext.memoryFile, BotContext.soulFile, BotContext.instructionsFile].map { bot.workspace + "/" + $0 }
        paths += [input.sharedMemoryPath, BotContext.teamPath(besideSharedMemory: input.sharedMemoryPath)]
        for folder in [Skills.sharedFolder(besideSharedMemory: input.sharedMemoryPath), Skills.folder(of: bot)] {
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: folder.path) }
            catch CocoaError.fileReadNoSuchFile { names = [] }
            paths += names.filter { !$0.hasPrefix(".") }.sorted().map { folder.appendingPathComponent($0).appendingPathComponent(Skills.fileName).path }
        }
        return try paths.map(stamp)
    }

    private func ownedStamps(_ bot: Bot) throws -> [Stamp] {
        var files = try ["AGENTS.md", "GEMINI.md", "CLAUDE.md"].map { try stamp(bot.workspace + "/" + $0) }
        let dispatch = bot.workspace + "/.botchu/dispatch"
        // Dispatch requests change the directory's dates, not the context or its existence.
        let identity = FileStamp.of(URL(fileURLWithPath: dispatch)).map {
            FileStamp(size: 0, modified: 0, changed: 0, inode: $0.inode)
        }
        files.append(Stamp(path: dispatch, file: identity))
        return files
    }

    private enum Failure: LocalizedError {
        case changingFiles
        var errorDescription: String? { "The bot's context files kept changing during preparation. Try sending again." }
    }
}
