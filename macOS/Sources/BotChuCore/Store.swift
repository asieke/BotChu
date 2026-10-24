import Foundation

/// A bot's own files, in `.botchu/` inside its workspace, so the folder is the whole bot: its
/// settings (`bot.json`), its conversation (`thread.jsonl`, one message per line), its tasks
/// (`tasks/<id>/`, each with `task.json` and its own `thread.jsonl`), the tasks it asks for
/// (`dispatch/`), a log of each turn (`logs/<date>.log`) and its animated pet (`pet/`). A
/// `.gitignore` keeps them out of a workspace that is a git repository.
public struct BotHome: Sendable {
    public static let folderName = ".botchu"

    public let url: URL

    public init(workspace: String) {
        url = URL(fileURLWithPath: workspace, isDirectory: true).appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public var botURL: URL { url.appendingPathComponent("bot.json") }
    public var threadURL: URL { url.appendingPathComponent("thread.jsonl") }
    public var logsURL: URL { url.appendingPathComponent("logs", isDirectory: true) }
    /// The bot's animated pet, when it has one (see `PetVideo`).
    public var petURL: URL { url.appendingPathComponent("pet", isDirectory: true) }
    public var tasksURL: URL { url.appendingPathComponent("tasks", isDirectory: true) }
    /// Where the bot puts requests for tasks from its Home conversation (`TaskRequest`), which
    /// BotChu takes and removes.
    public var dispatchURL: URL { url.appendingPathComponent("dispatch", isDirectory: true) }

    public func taskURL(_ id: UUID) -> URL { tasksURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    public func taskThreadURL(_ id: UUID) -> URL { taskURL(id).appendingPathComponent("thread.jsonl") }
    /// A conversation's pending messages: Home's, or a task's.
    public func queueURL(task id: UUID? = nil) -> URL { (id.map(taskURL) ?? url).appendingPathComponent("queued.jsonl") }


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
        Self.readThread(threadURL)
    }

    /// Rewrites the whole thread, atomically (a temporary file, then a rename), so a crash never
    /// leaves it half written.
    public func saveThread(_ messages: [ChatMessage]) throws {
        try prepare()
        try Self.writeThread(messages, to: threadURL)
    }

    /// The bot's tasks, open and closed, oldest first. A task whose `task.json` can't be read is left out.
    public func loadTasks() -> [BotTask] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: tasksURL, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("task.json"))).flatMap { try? Store.decoder.decode(BotTask.self, from: $0) }
        }
        .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func save(_ task: BotTask) throws {
        try prepare()
        try FileManager.default.createDirectory(at: taskURL(task.id), withIntermediateDirectories: true)
        try Store.encoder.encode(task).write(to: taskURL(task.id).appendingPathComponent("task.json"), options: .atomic)
    }

    public func loadThread(task id: UUID) -> [ChatMessage] {
        Self.readThread(taskThreadURL(id))
    }

    public func saveThread(_ messages: [ChatMessage], task id: UUID) throws {
        try prepare()
        try FileManager.default.createDirectory(at: taskURL(id), withIntermediateDirectories: true)
        try Self.writeThread(messages, to: taskThreadURL(id))
    }

    /// Unsent follow-ups live beside their conversation, including while a task is closed.
    public func loadQueuedMessages(task id: UUID? = nil) -> [ChatMessage] {
        Self.readThread((id.map(taskURL) ?? url).appendingPathComponent("queued.jsonl"))
    }

    /// Whether the owner's Stop or a failed turn paused the queue, which then waits for the owner
    /// after a relaunch too. Otherwise recovered messages are sent on their own.
    public func loadQueuePaused(task id: UUID? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (id.map(taskURL) ?? url).appendingPathComponent(Self.queuePausedFile).path)
    }

    public func saveQueuedMessages(_ messages: [ChatMessage], paused: Bool = false, task id: UUID? = nil) throws {
        try prepare()
        let folder = id.map(taskURL) ?? url
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeThread(messages, to: folder.appendingPathComponent("queued.jsonl"))
        let marker = folder.appendingPathComponent(Self.queuePausedFile)
        if paused && !messages.isEmpty {
            try Data().write(to: marker, options: .atomic)
        } else if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    static let queuePausedFile = "queued.paused"
    static let takenFile = "taken.jsonl"

    /// A conversation's queue as it was saved, reconciled with its saved transcript.
    public func loadQueue(delivered: [ChatMessage], task id: UUID? = nil) -> MessageQueue {
        MessageQueue(saved: loadQueuedMessages(task: id), taken: Self.readThread((id.map(taskURL) ?? url).appendingPathComponent(Self.takenFile)),
                     delivered: delivered, paused: loadQueuePaused(task: id))
    }

    /// Saves a conversation's queue: the messages the CLI took (`taken.jsonl`) first, so a message
    /// leaving the pending ones is never in neither file, then the pending messages.
    public func saveQueue(_ queue: MessageQueue, task id: UUID? = nil) throws {
        try prepare()
        let folder = id.map(taskURL) ?? url
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let taken = folder.appendingPathComponent(Self.takenFile)
        if !queue.taken.isEmpty {
            try Self.writeThread(queue.taken, to: taken)
        } else if FileManager.default.fileExists(atPath: taken.path) {
            try FileManager.default.removeItem(at: taken)
        }
        try saveQueuedMessages(queue.messages, paused: queue.isPaused, task: id)
    }

    /// Saves a conversation's transcript, and its queue while it holds messages the CLI took. A
    /// taken message leaves the saved queue only once a saved transcript holds it. When the
    /// transcript can't be saved, the message stays in the saved queue as taken (never sent
    /// again), the pending messages pause, so the CLI takes no more that couldn't be saved either,
    /// and the failure is returned for the conversation to show. `saved` says whether the
    /// transcript was saved.
    public func checkpoint(_ transcript: [ChatMessage], queue: inout MessageQueue, task id: UUID? = nil) -> (saved: Bool, failures: [SaveFailure]) {
        let holdsTaken = !queue.taken.isEmpty
        var failures: [SaveFailure] = []
        var saved = true
        do {
            if let id { try saveThread(transcript, task: id) } else { try saveThread(transcript) }
            queue.saved(transcript)
        } catch {
            saved = false
            if holdsTaken {
                if !queue.messages.isEmpty { queue.pause() }
                failures.append(SaveFailure(.conversation(paused: queue.isPaused), file: id.map(taskThreadURL) ?? threadURL, error: error))
            }
        }
        guard holdsTaken else { return (saved, failures) }
        do {
            try saveQueue(queue, task: id)
        } catch {
            failures.append(SaveFailure(.pendingMessages, file: queueURL(task: id), error: error))
        }
        return (saved, failures)
    }

    /// A conversation's queue after a launch. Messages the CLI took that the saved transcript lacks
    /// go back into it (`MessageQueue.restoringTaken`) rather than out again, and are saved there.
    public func recoverQueue(transcript: inout [ChatMessage], task id: UUID? = nil) -> (queue: MessageQueue, failures: [SaveFailure]) {
        var queue = loadQueue(delivered: transcript, task: id)
        guard !queue.taken.isEmpty else { return (queue, []) }
        transcript = queue.restoringTaken(into: transcript)
        let failures = checkpoint(transcript, queue: &queue, task: id).failures
        return (queue, failures)
    }

    public func subagentsURL(taskID: UUID? = nil) -> URL {
        (taskID.map(taskURL) ?? url).appendingPathComponent("subagents", isDirectory: true)
    }

    public func subagentURL(id: UUID, taskID: UUID? = nil) -> URL {
        subagentsURL(taskID: taskID).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Every descendant lives beside its root conversation, with parentSubagentID defining the tree.
    public func loadSubagents(taskID: UUID? = nil) -> [SubagentRun] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: subagentsURL(taskID: taskID), includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("run.json")))
                .flatMap { try? SubagentIPC.decode(SubagentRun.self, from: $0) }
        }
        .filter { $0.rootTaskID == taskID }
        .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func saveSubagent(_ run: SubagentRun) throws {
        try prepare()
        let folder = subagentURL(id: run.id, taskID: run.rootTaskID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SubagentIPC.encode(run).write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    }

    public func loadSubagentThread(id: UUID, taskID: UUID? = nil) -> [ChatMessage] {
        Self.readThread(subagentURL(id: id, taskID: taskID).appendingPathComponent("thread.jsonl"))
    }

    /// Streaming uses complete snapshots so the open assistant message can be replaced atomically.
    public func saveSubagentThread(_ messages: [ChatMessage], id: UUID, taskID: UUID? = nil) throws {
        try prepare()
        let folder = subagentURL(id: id, taskID: taskID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeThread(messages, to: folder.appendingPathComponent("thread.jsonl"))
    }

    public func appendSubagentMessages(_ messages: [ChatMessage], id: UUID, taskID: UUID? = nil) throws {
        try saveSubagentThread(loadSubagentThread(id: id, taskID: taskID) + messages, id: id, taskID: taskID)
    }

    /// Clearing a finished inspector entry never touches the owning conversation or its workspace.
    public func removeSubagent(id: UUID, taskID: UUID? = nil) throws {
        let folder = subagentURL(id: id, taskID: taskID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// The task requests waiting in `dispatch/`, oldest first: each file's name and contents. Each
    /// is removed as it is read, so a request is taken once. A file changed in the last `settle`
    /// seconds may still be being written, so it waits for the next look.
    public func takeDispatches(now: Date = Date(), settle: TimeInterval = 1) -> [(name: String, data: Data)] {
        dispatchFiles(now: now, settle: settle).compactMap { file in
            guard let data = try? Data(contentsOf: file), (try? FileManager.default.removeItem(at: file)) != nil else { return nil }
            return (file.lastPathComponent, data)
        }
    }

    /// Whether a request is waiting, without taking it.
    public func hasDispatches(now: Date = Date(), settle: TimeInterval = 1) -> Bool {
        !dispatchFiles(now: now, settle: settle).isEmpty
    }

    /// The requests waiting, oldest first, without taking them: each is taken with `take(dispatch:)`
    /// once its task is ready to record.
    public func peekDispatches(now: Date = Date(), settle: TimeInterval = 1) -> [(file: URL, data: Data)] {
        dispatchFiles(now: now, settle: settle).compactMap { file in (try? Data(contentsOf: file)).map { (file, $0) } }
    }

    /// Removes a request, so it is taken once; false when it was taken already.
    public func take(dispatch file: URL) -> Bool {
        (try? FileManager.default.removeItem(at: file)) != nil
    }

    private func dispatchFiles(now: Date, settle: TimeInterval) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dispatchURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return files.filter { $0.pathExtension.lowercased() == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .filter { now.timeIntervalSince(modified($0)) >= settle }
            .sorted { (modified($0), $0.lastPathComponent) < (modified($1), $1.lastPathComponent) }
    }

    /// Creates `dispatch/`, so a bot finds where its requests go.
    public func prepareDispatch() throws {
        try prepare()
        try FileManager.default.createDirectory(at: dispatchURL, withIntermediateDirectories: true)
    }

    static func readThread(_ url: URL) -> [ChatMessage] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Store.decoder.decode(ChatMessage.self, from: Data($0.utf8)) }
    }

    static func writeThread(_ messages: [ChatMessage], to url: URL) throws {
        let lines = try messages.map { String(decoding: try Store.lineEncoder.encode($0), as: UTF8.self) }
        try Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8).write(to: url, options: .atomic)
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

    /// Moves the bot and its editable Markdown together, rejecting collisions before moving anything.
    public func move(toWorkspace workspace: String) throws {
        let destination = BotHome(workspace: workspace)
        let files = FileManager.default
        let sourceFolder = url.deletingLastPathComponent()
        let targetFolder = destination.url.deletingLastPathComponent()
        guard sourceFolder.standardizedFileURL != targetFolder.standardizedFileURL else { return }
        let sources = ([url] + BotDocument.allCases.map { sourceFolder.appendingPathComponent($0.rawValue) })
            .filter { files.fileExists(atPath: $0.path) }
        for source in sources {
            let target = targetFolder.appendingPathComponent(source.lastPathComponent)
            guard !files.fileExists(atPath: target.path) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path])
            }
        }
        try files.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        var moved: [(source: URL, target: URL)] = []
        do {
            for source in sources {
                let target = targetFolder.appendingPathComponent(source.lastPathComponent)
                try files.moveItem(at: source, to: target)
                moved.append((source, target))
            }
        } catch {
            for entry in moved.reversed() { try? files.moveItem(at: entry.target, to: entry.source) }
            throw error
        }
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

/// A file BotChu couldn't save, said so the owner can act on it: what it holds, where it is, why
/// saving failed, and what BotChu keeps meanwhile.
public struct SaveFailure: Error, Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        /// A conversation's transcript, while messages the CLI took wait in its saved queue for
        /// it; `paused` when its pending messages were paused for it.
        case conversation(paused: Bool)
        /// A conversation's pending messages.
        case pendingMessages
    }

    public var item: Item
    public var file: URL
    /// Why saving failed, without a closing period.
    public var reason: String

    public init(_ item: Item, file: URL, error: Error) {
        self.item = item
        self.file = file
        var reason = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while reason.hasSuffix(".") { reason.removeLast() }
        self.reason = reason
    }

    /// What the conversation shows, in the same words while the same failure repeats.
    public var message: String {
        let place = "(\((file.path as NSString).abbreviatingWithTildeInPath))"
        let fix = "Check that its folder is writable and its disk has space."
        switch item {
        case .conversation(let paused):
            return "Couldn't save this conversation \(place): \(reason). Messages the bot already took are kept with the "
                + "pending messages until it saves, and aren't sent again." + (paused ? " Pending messages wait for Send next." : "")
                + " " + fix
        case .pendingMessages:
            return "Couldn't save pending messages \(place): \(reason). \(fix)"
        }
    }
}

/// Where BotChu finds its bots: `index.json`, the bots' ids, workspaces and sidebar sections in
/// sidebar order, under `~/Library/Application Support/BotChu`. Everything else about a bot is in
/// its `BotHome`.
public struct Store: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: UUID
        public var workspace: String
        /// The sidebar section the bot is in (`BotSections`); nil for none, and in indexes from
        /// before sections.
        public var section: String?

        public init(id: UUID, workspace: String, section: String? = nil) {
            self.id = id
            self.workspace = workspace
            self.section = section
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

    /// The bots in the index whose folders hold them, in order, with the sections they are in, and
    /// the entries whose folders don't (moved, deleted, or on a drive that isn't connected), kept so
    /// they come back with their folder, in their section.
    public func loadBots() -> (bots: [Bot], missing: [Entry], sections: [UUID: String]) {
        var bots: [Bot] = []
        var missing: [Entry] = []
        var sections: [UUID: String] = [:]
        for entry in loadIndex() {
            let folderExists = FileManager.default.fileExists(atPath: entry.workspace)
            if var bot = BotHome(workspace: entry.workspace).loadBot() ?? (folderExists ? backedUpBot(entry.id) : nil) {
                bot.workspace = entry.workspace
                bots.append(bot)
                sections[bot.id] = entry.section
            } else {
                missing.append(entry)
            }
        }
        return (bots, missing, sections)
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
