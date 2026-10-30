import Foundation

/// What is typed in a conversation's message box and not sent yet: its text, and the agents and
/// projects chosen in it from `@` and `#` completion (`Mentions.swift`). Its images and documents
/// stay in memory.
public struct ComposerDraft: Codable, Hashable, Sendable {
    public var text: String
    public var references: [MessageReference]?

    public init(text: String, references: [MessageReference] = []) {
        self.text = text
        self.references = references.isEmpty ? nil : references
    }
}

/// The drafts kept between launches (#357), one file per conversation: `drafts/<bot>/home.json`
/// for a bot's Home and `drafts/<bot>/<task>.json` for a task, in BotChu's own folder (`Store.root`).
///
/// Not beside the queue files: a draft is text the owner hasn't given the bot (a key pasted and
/// thought better of), and the bot's folder is where its CLI works with permission prompts
/// bypassed, may sync with the Desktop, and goes to the Trash with the bot. Here the folders are
/// the owner's alone (0700), each file too (0600, never written readable to anyone else, even
/// while it is being written), and `drafts/` is left out of backups: a draft isn't written where
/// that can't be made so. Programs run as the owner can still read them; nothing here hides
/// them from those.
///
/// A draft is written off the caller's thread, on its file's lane (`StorageQueue`), at most once
/// every `delay` while it changes, its latest state each time; quitting's `StorageQueue.wait`
/// writes what waits. An empty draft removes its file at once, ahead of any write still waiting.
public struct DraftStore: Sendable {
    public struct Key: Hashable, Sendable {
        public var bot: UUID
        /// Nil for the bot's Home.
        public var task: UUID?

        public init(bot: UUID, task: UUID? = nil) {
            self.bot = bot
            self.task = task
        }
    }

    public static let folderName = "drafts"
    static let homeFile = "home.json"
    static let slot = "draft"

    public let url: URL
    /// How long a change waits for the next ones before its draft is written.
    public let delay: TimeInterval
    /// Runs on the lane as each draft is written, before its file is: tests hold a write there.
    var writing: (@Sendable (Key) -> Void)?

    public init(root: URL, delay: TimeInterval = 0.5) {
        url = root.appendingPathComponent(Self.folderName, isDirectory: true)
        self.delay = delay
    }

    public func folder(bot: UUID) -> URL { url.appendingPathComponent(bot.uuidString.lowercased(), isDirectory: true) }

    public func fileURL(_ key: Key) -> URL {
        folder(bot: key.bot).appendingPathComponent(key.task.map { $0.uuidString.lowercased() + ".json" } ?? Self.homeFile)
    }

    /// Keeps the conversation's draft, or removes it when it is empty (sent, or cleared). A state
    /// already on disk isn't written again.
    public func save(_ draft: ComposerDraft?, for key: Key, storage: StorageQueue) {
        let draft = draft ?? ComposerDraft(text: "")
        storage.replace(fileURL(key).path, slot: Self.slot, value: draft, version: AnyHashable(draft),
                        delay: draft.text.isEmpty ? 0 : delay, write: { try self.write($0, for: key) })
    }

    /// A bot is being deleted: what waits to be written of its drafts is dropped, what is being
    /// written finishes, and its drafts go (not to the Trash), again once a write that outlasted
    /// `timeout` has finished, so it can't leave them behind.
    public func removeBot(_ bot: UUID, storage: StorageQueue, timeout: TimeInterval) {
        let folder = folder(bot: bot)
        let unfinished = storage.retire(folder.path, timeout: timeout)
        try? FileManager.default.removeItem(at: folder)
        if !unfinished.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                storage.wait(under: folder.path, timeout: 60)
                try? FileManager.default.removeItem(at: folder)
            }
        }
        storage.reopen(folder.path)
    }

    /// The drafts to put back at launch: those of the bots and tasks there are (`tasks`). What no
    /// conversation will ask for again is removed: the folders of bots that are gone, the drafts of
    /// tasks `isGone` says are (not of one whose record couldn't be read this time), files that
    /// can't be read as a draft, and what a write left half done. A bot whose folder is missing
    /// (`missing`, a drive not connected) keeps its drafts for its return. Run at launch before
    /// anything is saved, once `StorageQueue.wait` has written what waited.
    public func restore(tasks: [UUID: Set<UUID>], missing: Set<UUID> = [],
                        isGone: (Key) -> Bool = { _ in true }) -> [Key: ComposerDraft] {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return [:] }
        try? Self.ownerOnly(url, excludedFromBackup: true)
        var drafts: [Key: ComposerDraft] = [:]
        for folder in (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
            guard let bot = UUID(uuidString: folder.lastPathComponent), tasks[bot] != nil || missing.contains(bot) else {
                try? files.removeItem(at: folder)
                continue
            }
            for file in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let name = file.lastPathComponent
                // A missing bot's tasks aren't known: only what a write left half done goes.
                guard let known = tasks[bot] else {
                    if name.hasSuffix(Self.tempSuffix) { try? files.removeItem(at: file) }
                    continue
                }
                let task = name.hasSuffix(".json") ? UUID(uuidString: String(name.dropLast(".json".count))) : nil
                guard name == Self.homeFile || task != nil else {
                    try? files.removeItem(at: file)
                    continue
                }
                let key = Key(bot: bot, task: task)
                if let task, !known.contains(task) {
                    if isGone(key) { try? files.removeItem(at: file) }
                    continue
                }
                guard let draft = Self.read(file) else {
                    try? files.removeItem(at: file)
                    continue
                }
                drafts[key] = draft
            }
        }
        return drafts
    }

    // MARK: Files

    static let tempSuffix = ".tmp"

    /// Writes the draft whole, or removes its file when it is empty, and returns the bytes written.
    @discardableResult
    func write(_ draft: ComposerDraft, for key: Key) throws -> Int {
        let file = fileURL(key)
        writing?(key)
        guard !draft.text.isEmpty else {
            guard unlink(file.path) == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return 0
        }
        try Self.ownerOnly(url, excludedFromBackup: true)
        try Self.ownerOnly(file.deletingLastPathComponent())
        let data = try Store.encoder.encode(draft)
        try Self.writeOwnerOnly(data, to: file)
        return data.count
    }

    static func read(_ file: URL) -> ComposerDraft? {
        guard let data = try? Data(contentsOf: file), let draft = try? Store.decoder.decode(ComposerDraft.self, from: data),
              !draft.text.isEmpty else { return nil }
        return draft
    }

    /// Makes the folder only its owner can open, or makes it so; `excludedFromBackup` keeps it
    /// out of Time Machine, and throws when that can't be made so.
    static func ownerOnly(_ folder: URL, excludedFromBackup: Bool = false) throws {
        let files = FileManager.default
        var isFolder: ObjCBool = false
        if files.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue {
            let mode = (try files.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue
            if mode != 0o700 { try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        } else {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard excludedFromBackup, !isExcludedFromBackup(folder) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = folder
        try marked.setResourceValues(values)
        guard isExcludedFromBackup(folder) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: folder]) }
    }

    private static func isExcludedFromBackup(_ folder: URL) -> Bool {
        var folder = folder
        folder.removeAllCachedResourceValues()
        return (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    /// Writes `data` in place of `file` at once: into a new file beside it that only its owner can
    /// read from the moment it is made (`Data.write(.atomic)` makes a new file readable to all),
    /// then moved over it.
    static func writeOwnerOnly(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)\(tempSuffix)")
        let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(temp.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(temp.path)
            throw error
        }
    }
}
