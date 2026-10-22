import Foundation

/// A bot's own files, in `.botchu/` inside its workspace, so the folder is the whole bot: its
/// settings (`bot.json`), its conversation (`thread.jsonl`, one message per line), a log of each
/// turn (`logs/<date>.log`) and its animated pet (`pet/`). A `.gitignore` keeps them out of a workspace that is a git repository.
public struct BotHome: Sendable {
    public static let folderName = ".botchu"

    public let url: URL

    public init(workspace: String) {
        url = URL(fileURLWithPath: workspace, isDirectory: true).appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public var botURL: URL { url.appendingPathComponent("bot.json") }
    public var threadURL: URL { url.appendingPathComponent("thread.jsonl") }
    public var logsURL: URL { url.appendingPathComponent("logs", isDirectory: true) }
    /// The bot's animated pet, when it has one (see `PetPackage`).
    public var petURL: URL { url.appendingPathComponent("pet", isDirectory: true) }

    public func loadPet() -> PetPackage? { PetPackage.load(from: petURL) }

    public var exists: Bool { FileManager.default.fileExists(atPath: botURL.path) }

    public func loadBot() -> Bot? {
        guard let data = try? Data(contentsOf: botURL) else { return nil }
        return try? Store.decoder.decode(Bot.self, from: data)
    }

    public func save(_ bot: Bot) throws {
        try prepare()
        try Store.encoder.encode(bot).write(to: botURL, options: .atomic)
    }

    public func loadThread() -> [ChatMessage] {
        guard let text = try? String(contentsOf: threadURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Store.decoder.decode(ChatMessage.self, from: Data($0.utf8)) }
    }

    /// Rewrites the whole thread, atomically (a temporary file, then a rename), so a crash never
    /// leaves it half written.
    public func saveThread(_ messages: [ChatMessage]) throws {
        try prepare()
        let lines = try messages.map { String(decoding: try Store.lineEncoder.encode($0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8).write(to: threadURL, options: .atomic)
    }

    /// Appends to the day's log, `logs/yyyy-MM-dd.log` in local time.
    public func appendLog(_ text: String, at date: Date = Date()) throws {
        try prepare()
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let file = logsURL.appendingPathComponent("\(Self.day.string(from: date)).log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Moves the folder elsewhere when a bot's workspace changes.
    public func move(toWorkspace workspace: String) throws {
        let destination = BotHome(workspace: workspace)
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: destination.url.path) else { return }
        try FileManager.default.createDirectory(at: destination.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination.url)
    }

    /// Puts the folder in the Trash, when its bot is deleted; the rest of the workspace stays.
    public func trash() {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let ignore = url.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try "# BotChu's files for this bot; never committed.\n*\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
    }

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Where BotChu finds its bots: `index.json`, the bots' ids and workspaces in sidebar order, under
/// `~/Library/Application Support/BotChu`. Everything else about a bot is in its `BotHome`.
public struct Store: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: UUID
        public var workspace: String

        public init(id: UUID, workspace: String) {
            self.id = id
            self.workspace = workspace
        }
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var applicationSupport: Store {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Store(root: base.appendingPathComponent("BotChu", isDirectory: true))
    }

    var indexURL: URL { root.appendingPathComponent("index.json") }
    /// Before bots had their own folders: every bot in `bots.json`, every thread in `threads/`.
    var legacyBotsURL: URL { root.appendingPathComponent("bots.json") }
    var legacyThreadsURL: URL { root.appendingPathComponent("threads", isDirectory: true) }
    /// Where the migration keeps those files.
    var backupURL: URL { root.appendingPathComponent("backup-before-bot-folders", isDirectory: true) }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func loadIndex() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? Self.decoder.decode([Entry].self, from: data)) ?? []
    }

    public func saveIndex(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: indexURL, options: .atomic)
    }

    /// The bots in the index whose folders hold them, in order, and the entries whose folders don't
    /// (moved, deleted, or on a drive that isn't connected), kept so they come back with their folder.
    public func loadBots() -> (bots: [Bot], missing: [Entry]) {
        var bots: [Bot] = []
        var missing: [Entry] = []
        for entry in loadIndex() {
            let folderExists = FileManager.default.fileExists(atPath: entry.workspace)
            if var bot = BotHome(workspace: entry.workspace).loadBot() ?? (folderExists ? backedUpBot(entry.id) : nil) {
                bot.workspace = entry.workspace
                bots.append(bot)
            } else {
                missing.append(entry)
            }
        }
        return (bots, missing)
    }

    public func loadThread(for bot: Bot) -> [ChatMessage] {
        let home = BotHome(workspace: bot.workspace)
        if FileManager.default.fileExists(atPath: home.threadURL.path) { return home.loadThread() }
        return backedUpThread(bot.id)
    }

    /// Moves bots from `bots.json` and `threads/` into their own folders, once. The old files are
    /// kept in `backup-before-bot-folders/`; a bot whose folder couldn't be written is read from
    /// there until its folder can be.
    @discardableResult
    public func migrateIfNeeded() -> Bool {
        let files = FileManager.default
        guard !files.fileExists(atPath: indexURL.path), let data = try? Data(contentsOf: legacyBotsURL),
              let bots = try? Self.decoder.decode([Bot].self, from: data) else { return false }
        for bot in bots {
            let home = BotHome(workspace: bot.workspace)
            guard !home.exists else { continue }
            try? home.save(bot)
            let legacyThread = legacyThreadsURL.appendingPathComponent("\(bot.id.uuidString).json")
            if let thread = try? Self.decoder.decode([ChatMessage].self, from: Data(contentsOf: legacyThread)) {
                try? home.saveThread(thread)
            }
        }
        guard (try? saveIndex(bots.map { Entry(id: $0.id, workspace: $0.workspace) })) != nil else { return false }
        try? files.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try? files.moveItem(at: legacyBotsURL, to: backupURL.appendingPathComponent("bots.json"))
        try? files.moveItem(at: legacyThreadsURL, to: backupURL.appendingPathComponent("threads", isDirectory: true))
        return true
    }

    private func backedUpBot(_ id: UUID) -> Bot? {
        guard let data = try? Data(contentsOf: backupURL.appendingPathComponent("bots.json")),
              let bots = try? Self.decoder.decode([Bot].self, from: data) else { return nil }
        return bots.first { $0.id == id }
    }

    private func backedUpThread(_ id: UUID) -> [ChatMessage] {
        let url = backupURL.appendingPathComponent("threads").appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([ChatMessage].self, from: data)) ?? []
    }
}
