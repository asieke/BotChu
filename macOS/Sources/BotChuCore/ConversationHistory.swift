import Foundation

// A conversation's history is read when it is needed, not at launch (#109). What the sidebar, the
// status sidebar and Home's task reports need of a conversation that isn't in memory is its
// digest (`ThreadDigest`), kept beside its transcript in `thread.index.json` with what the digest
// was made from, so a transcript changed since (by BotChu or anything else) is never described by
// a stale one. A launch reads each open conversation's queue files and its index, not its
// transcript, unless it has messages waiting, which recovery needs it for.

/// What a status, a sidebar row and a task report read of a conversation without its messages:
/// its summary and the start of its last reply.
public struct ThreadDigest: Codable, Equatable, Sendable {
    public var summary: ThreadSummary
    /// Every message in the thread, BotChu's own lines included.
    public var count: Int
    /// The last reply, trimmed, up to `replyKept` characters, and whether it goes on.
    public var lastReply: String?
    public var lastReplyCut: Bool
    public var shellCount: Int

    /// More than a report shows (`BotContext.maxReportReply`).
    public static let replyKept = 1_000

    public init(_ messages: [ChatMessage]) {
        self.init(summary: ThreadSummary(messages), count: messages.count,
                  lastReply: messages.last(where: { $0.role == .assistant })?.text, shellCount: ToolCounts(messages: messages).shell)
    }

    /// From a summary kept as the thread changed, and its last reply.
    public init(summary: ThreadSummary, count: Int, lastReply: String?, shellCount: Int = 0) {
        self.summary = summary
        self.count = count
        self.shellCount = shellCount
        let reply = lastReply?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lastReply = reply.map { String($0.prefix(Self.replyKept)) }
        lastReplyCut = (reply?.count ?? 0) > Self.replyKept
    }

    private enum CodingKeys: String, CodingKey { case summary, count, lastReply, lastReplyCut, shellCount }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        summary = try values.decode(ThreadSummary.self, forKey: .summary)
        count = try values.decode(Int.self, forKey: .count)
        lastReply = try values.decodeIfPresent(String.self, forKey: .lastReply)
        lastReplyCut = try values.decode(Bool.self, forKey: .lastReplyCut)
        shellCount = try values.decodeIfPresent(Int.self, forKey: .shellCount) ?? 0
    }
}

/// What identifies a file's contents without reading it: its size, its modification time, its
/// inode's change time (which a tool that keeps a file's dates can't set back) and its inode (an
/// atomic save makes a new one). Any of them differing means the file changed.
public struct FileStamp: Codable, Equatable, Sendable {
    public var size: Int64
    public var modified: Int64
    public var changed: Int64
    public var inode: UInt64

    public init(size: Int64, modified: Int64, changed: Int64, inode: UInt64) {
        self.size = size
        self.modified = modified
        self.changed = changed
        self.inode = inode
    }

    public static func of(_ url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        func nanoseconds(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
        return FileStamp(size: Int64(info.st_size), modified: nanoseconds(info.st_mtimespec), changed: nanoseconds(info.st_ctimespec),
                         inode: UInt64(info.st_ino))
    }
}

/// A fast 64-bit hash of bytes, for telling a file's contents apart; not for security.
public enum ContentHash {
    public static func of(_ data: Data) -> String {
        data.withUnsafeBytes { hex(of: $0) }
    }

    /// The hash of the last `TranscriptIndex.tailLength` bytes.
    public static func tail(of data: Data) -> String {
        of(data.suffix(TranscriptIndex.tailLength))
    }

    static func hex(of bytes: UnsafeRawBufferPointer) -> String {
        var hash: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ UInt64(bytes.count)
        var offset = 0
        while offset + 8 <= bytes.count {
            hash = mix(hash ^ bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            offset += 8
        }
        var last: UInt64 = 0
        for (shift, byte) in bytes[offset...].enumerated() { last |= UInt64(byte) << (8 * UInt64(shift)) }
        hash = mix(hash ^ last ^ 0xA5)
        return String(hash, radix: 16)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var x = value &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        x = x &* 0xC4CE_B9FE_1A85_EC53
        return x ^ (x >> 29)
    }
}

/// `thread.index.json`: a transcript's digest, with the transcript it was made from (its stamp, a
/// hash of all of it and of its end). Missing, of another version, unreadable, or not matching the
/// transcript, it is made again from the transcript; it is never taken over the transcript.
public struct TranscriptIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let tailLength = 4_096
    public static let fileName = "thread.index.json"

    public var version: Int
    public var stamp: FileStamp
    public var hash: String
    public var tail: String
    public var digest: ThreadDigest
    public var pages: [PagedTranscript.Page]?

    public init(stamp: FileStamp, data: Data, digest: ThreadDigest) {
        version = Self.currentVersion
        self.stamp = stamp
        hash = ContentHash.of(data)
        tail = ContentHash.tail(of: data)
        self.digest = digest
    }
}

/// A conversation's transcript as read for showing it: its messages (with a note on anything that
/// couldn't be read), its digest, and its size on disk.
public struct HistoryLoad: Sendable {
    public var messages: [ChatMessage]
    public var digest: ThreadDigest
    public var bytes: Int
    /// The index didn't describe the transcript read (missing, stale, or changed outside BotChu),
    /// and was made again.
    public var reindexed: Bool
    public var start: Int
    public var prefix: ThreadDigest

    public init(messages: [ChatMessage], digest: ThreadDigest, bytes: Int, reindexed: Bool, start: Int = 0, prefix: ThreadDigest = ThreadDigest([])) {
        self.messages = messages
        self.digest = digest
        self.bytes = bytes
        self.reindexed = reindexed
        self.start = start
        self.prefix = prefix
    }
}

/// What recovering a conversation's queue after a launch found (`BotHome.recover`).
public struct HistoryRecovery: Sendable {
    public var queue: MessageQueue
    public var failures: [SaveFailure]
    /// The transcript, when recovery needed it (messages waiting, or the conversation is shown), as
    /// recovery left it; nil when it stayed on disk, unread.
    public var history: HistoryLoad?
    /// The digest, from the index when the transcript wasn't read; nil when the index has to be
    /// made again (`BotHome.rebuildDigest`).
    public var digest: ThreadDigest?

    public init(queue: MessageQueue, failures: [SaveFailure], history: HistoryLoad?, digest: ThreadDigest?) {
        self.queue = queue
        self.failures = failures
        self.history = history
        self.digest = digest
    }
}

extension BotHome {
    public func transcriptURL(task id: UUID? = nil) -> URL { id.map(taskThreadURL) ?? threadURL }
    public func indexURL(task id: UUID? = nil) -> URL { (id.map(taskURL) ?? url).appendingPathComponent(TranscriptIndex.fileName) }

    /// Saves the index of a transcript just written as `data` from `messages`. It is a cache: when it
    /// can't be saved, the transcript is read the next time.
    func writeIndex(for data: Data, messages: [ChatMessage], task id: UUID?) {
        let transcript = transcriptURL(task: id)
        guard let stamp = FileStamp.of(transcript) else { return }
        // A background digest does not migrate payload. Leave it unpaged so the first real load
        // or write preserves the legacy original and normalizes legal blank lines before indexing.
        try? PagedTranscript.writeIndex(TranscriptIndex(stamp: stamp, data: data, digest: ThreadDigest(messages)), at: transcript)
    }

    private func readIndex(task id: UUID?) -> TranscriptIndex? {
        let file = indexURL(task: id)
        guard let data = try? Data(contentsOf: file) else { return nil }
        HistoryCounters.shared.record(file) { $0.indexReads += 1 }
        guard let index = try? JSONDecoder().decode(TranscriptIndex.self, from: data), index.version == TranscriptIndex.currentVersion else { return nil }
        return index
    }

    /// The conversation's digest without reading its transcript: from its index, when the
    /// transcript is the one it was made from (its stamp, and its last bytes, read again). A
    /// missing transcript is an empty conversation. Nil when the index must be made again.
    public func readDigest(task id: UUID? = nil) -> ThreadDigest? {
        let transcript = transcriptURL(task: id)
        guard let stamp = FileStamp.of(transcript) else {
            return FileManager.default.fileExists(atPath: transcript.path) ? nil : ThreadDigest([])
        }
        guard let index = PagedTranscript.validIndex(transcript), index.stamp == stamp else { return nil }
        return index.digest
    }

    private static func tailHash(of url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = min(Int64(TranscriptIndex.tailLength), size)
        guard (try? handle.seek(toOffset: UInt64(size - length))) != nil, let data = try? handle.read(upToCount: Int(length)) else { return nil }
        return ContentHash.of(data)
    }

    /// Reads the conversation's transcript to show it, keeping what can't be read as
    /// `TranscriptRead` does, and makes its index again when it doesn't describe what was read: a
    /// transcript changed outside BotChu, also with the same size and dates, has another hash.
    public func loadHistory(task id: UUID? = nil, before: Int? = nil, limit: Int = PagedTranscript.residentLimit) -> HistoryLoad {
        do { return try PagedTranscript.load(transcriptURL(task: id), before: before, limit: limit) }
        catch {
            let whole = loadWholeHistory(task: id)
            let end = max(0, min(before ?? whole.messages.count, whole.messages.count))
            let start = max(0, end - max(1, limit))
            return HistoryLoad(messages: Array(whole.messages[start..<end]), digest: whole.digest,
                               bytes: whole.bytes, reindexed: whole.reindexed, start: start,
                               prefix: ThreadDigest(Array(whole.messages.prefix(start))))
        }
    }

    public func loadWholeHistory(task id: UUID? = nil) -> HistoryLoad {

        let transcript = transcriptURL(task: id)
        let before = FileStamp.of(transcript)
        var content = Data()
        let read = TranscriptRead.read(transcript) { content = $0 }
        var messages = read.messages
        if let note = read.note(for: .conversation) {
            messages.append(note)
            // Once the original is kept, the note is saved with what could be read (and the index with it).
            if read.kept != nil {
                HistoryCounters.shared.record(transcript) { $0.repairs += 1 }
                let bytes = (try? writeTranscript(messages, task: id)) ?? content.count
                return HistoryLoad(messages: messages, digest: ThreadDigest(messages), bytes: bytes, reindexed: true)
            }
        }
        let digest = ThreadDigest(messages)
        guard let before else { return HistoryLoad(messages: messages, digest: digest, bytes: 0, reindexed: false) }
        let index = readIndex(task: id)
        let current = index.map { $0.stamp == before && ($0.pages != nil || $0.hash == ContentHash.of(content)) } ?? false
        // Only a transcript that didn't change while it was read gets an index made from it.
        if !current, FileStamp.of(transcript) == before {
            writeIndex(for: content, messages: messages, task: id)
        }
        return HistoryLoad(messages: messages, digest: digest, bytes: content.count, reindexed: !current)
    }

    /// Makes the conversation's index again from its transcript, read without changing anything
    /// (a damaged one is kept and noted when it is opened), and returns its digest.
    public func rebuildDigest(task id: UUID? = nil) -> ThreadDigest {
        let transcript = transcriptURL(task: id)
        let before = FileStamp.of(transcript)
        var content = Data()
        let read = TranscriptRead.read(transcript, keeping: false) { content = $0 }
        let digest = ThreadDigest(read.messages)
        if before != nil, !read.isDamaged, FileStamp.of(transcript) == before {
            writeIndex(for: content, messages: read.messages, task: id)
        }
        return digest
    }

    /// Whether anything waits in the conversation's queue files for recovery (`recover`): a launch
    /// looks, without reading them, and recovers only the conversations that have some.
    public func hasQueueFiles(task id: UUID? = nil) -> Bool {
        let folder = id.map(taskURL) ?? url
        return [queueURL(task: id), folder.appendingPathComponent(Self.takenFile)].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A conversation's queue after a launch, or when a closed task opens again, as `recoverQueue`
    /// recovers it. The transcript is read only when recovery needs it (messages waiting or taken,
    /// or a queue file that couldn't be read) or `load` asks for it; `transcript` is the one in
    /// memory, when it is.
    public func recover(task id: UUID? = nil, transcript given: [ChatMessage]? = nil, load: Bool = false, start: Int = 0, prefix: ThreadDigest = ThreadDigest([])) -> HistoryRecovery {
        let queued = readQueuedMessages(task: id), taken = readTakenMessages(task: id)
        let notes = [taken.note(for: .taken), queued.note(for: .queue)].compactMap { $0 }
        let waiting = !queued.messages.isEmpty || !taken.messages.isEmpty || !notes.isEmpty
        guard waiting || load || given != nil else {
            return HistoryRecovery(queue: MessageQueue(), failures: [], history: nil, digest: readDigest(task: id))
        }
        var history = given.map { HistoryLoad(messages: $0, digest: ThreadDigest($0), bytes: 0, reindexed: false, start: start, prefix: prefix) } ?? loadHistory(task: id)
        let ids = Set((queued.messages + taken.messages).map(\.id)).subtracting(history.messages.map(\.id))
        let earlier = history.start > 0 ? (try? PagedTranscript.matching(ids, in: transcriptURL(task: id))) ?? [] : []
        var queue = MessageQueue(saved: queued.messages, taken: taken.messages, delivered: history.messages + earlier, paused: loadQueuePaused(task: id))
        var failures: [SaveFailure] = []
        if !queue.taken.isEmpty || !notes.isEmpty {
            let base = history.messages
            history.messages = queue.restoringTaken(into: history.messages) + notes
            failures = checkpoint(PagedTranscript.Snapshot(history.messages, start: history.start, base: base), queue: &queue, task: id).failures
        }
        var summary = history.prefix.summary
        summary.extend(with: history.messages, from: 0)
        let reply = history.messages.last(where: { $0.role == .assistant })?.text
        history.digest = ThreadDigest(summary: summary, count: history.start + history.messages.count,
                                      lastReply: reply ?? history.prefix.lastReply,
                                      shellCount: history.prefix.shellCount + ToolCounts(messages: history.messages).shell)
        if reply == nil { history.digest.lastReplyCut = history.prefix.lastReplyCut }
        return HistoryRecovery(queue: queue, failures: failures, history: history, digest: history.digest)
    }
}

/// Where one conversation's history is: on disk only, being read, or in memory; and whether its
/// queue was recovered after the launch (a closed task's isn't, until it opens). One read or
/// recovery runs at a time (`ticket`); its result is taken only while it is the latest, so a read
/// that ends after the conversation was dropped from memory, read again or recovered again is
/// ignored. What the app asks of the conversation meanwhile waits for it (`isBusy`).
public struct HistoryState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case unloaded, loading, loaded }
    public enum Recovery: Equatable, Sendable {
        /// Not asked for: a closed task's queue isn't recovered (nor sent) until it opens again.
        case none
        case recovering
        case recovered
    }

    public private(set) var phase: Phase
    public private(set) var recovery: Recovery
    /// Counts reads, recoveries and evictions; a result is taken only for the latest.
    public private(set) var ticket = 0

    /// After a launch that found nothing in its queue files: not in memory, and nothing to recover.
    public static let clean = HistoryState(phase: .unloaded, recovery: .recovered)

    public init(phase: Phase = .unloaded, recovery: Recovery = .none) {
        self.phase = phase
        self.recovery = recovery
    }

    /// A conversation made now, with nothing on disk yet: in memory and recovered.
    public static let created = HistoryState(phase: .loaded, recovery: .recovered)

    public var isLoaded: Bool { phase == .loaded }
    /// A read or a recovery is under way: changes to the conversation wait for it.
    public var isBusy: Bool { phase == .loading || recovery == .recovering }

    /// Starts a read (`load`, when the history isn't in memory) and a recovery of the queue
    /// (`recover`); nil when something is under way already or there is nothing to start.
    public mutating func begin(load: Bool, recover: Bool) -> Int? {
        guard !isBusy else { return nil }
        let reads = load && phase == .unloaded
        guard reads || recover else { return nil }
        ticket += 1
        if reads { phase = .loading }
        if recover { recovery = .recovering }
        return ticket
    }

    /// The work for `ticket` ended: whether the history is in memory now and the queue recovered.
    /// False when it is no longer the latest, and its result must be dropped.
    public mutating func finish(_ ticket: Int, loaded: Bool, recovered: Bool) -> Bool {
        guard ticket == self.ticket, isBusy else { return false }
        if loaded { phase = .loaded } else if phase == .loading { phase = .unloaded }
        if recovery == .recovering { recovery = recovered ? .recovered : .none }
        return true
    }

    /// The work for `ticket` was for a folder that has moved since: back to where it was, to start again.
    public mutating func abandon(_ ticket: Int) {
        guard ticket == self.ticket else { return }
        self.ticket += 1
        if phase == .loading { phase = .unloaded }
        if recovery == .recovering { recovery = .none }
    }

    /// A read or recovery done here and now (quitting), in the place of any under way, which isn't taken.
    public mutating func took(loaded: Bool, recovered: Bool) {
        ticket += 1
        phase = loaded ? .loaded : phase == .loading ? .unloaded : phase
        if recovered { recovery = .recovered } else if recovery == .recovering { recovery = .none }
    }

    /// The history leaves memory; a read under way isn't taken. False when it can't (being read or recovered).
    public mutating func evict() -> Bool {
        guard phase == .loaded, !isBusy else { return false }
        phase = .unloaded
        ticket += 1
        return true
    }

    /// The conversation's history is given whole, in memory only (a demo): no read or recovery
    /// under way is taken.
    public mutating func adopt() {
        ticket += 1
        phase = .loaded
        recovery = .recovered
    }
}

/// Which histories to drop from memory so the inactive ones (not pinned: not shown, running,
/// unsaved or being read) take at most `limit` bytes: the least recently used first.
public struct HistoryBudget<Key: Hashable & Sendable>: Sendable {
    public let limit: Int
    /// Least recently used first.
    public private(set) var order: [Key] = []
    private var sizes: [Key: Int] = [:]

    public init(limit: Int) {
        self.limit = limit
    }

    /// `key` is in memory, taking `bytes`, and was used now.
    public mutating func use(_ key: Key, bytes: Int) {
        if sizes[key] != nil { order.removeAll { $0 == key } }
        order.append(key)
        sizes[key] = bytes
    }

    public mutating func remove(_ key: Key) {
        guard sizes.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    public func bytes(of key: Key) -> Int { sizes[key] ?? 0 }
    public var total: Int { sizes.values.reduce(0, +) }

    /// The histories to drop, least recently used first, until the ones not pinned fit.
    public func overflow(pinned: (Key) -> Bool) -> [Key] {
        let inactive = order.filter { !pinned($0) }
        var bytes = inactive.reduce(0) { $0 + (sizes[$1] ?? 0) }
        var drop: [Key] = []
        for key in inactive where bytes > limit {
            drop.append(key)
            bytes -= sizes[key] ?? 0
        }
        return drop
    }

    /// About how much memory `messages` take: their text, a tool's input, output and arguments,
    /// and each message's own fields.
    public static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { sum, message in
            sum + 200 + message.text.utf8.count + (message.toolInput?.utf8.count ?? 0) + (message.toolOutput?.utf8.count ?? 0)
                + (message.toolArguments?.utf8.count ?? 0)
        }
    }
}
