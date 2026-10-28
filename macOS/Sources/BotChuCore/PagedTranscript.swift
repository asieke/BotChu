import Foundation

/// Completed pages are immutable byte ranges in the ordinary JSONL file. Keeping the ranges in
/// that file gives external readers the complete conversation without exporting it at every save.
/// Only the changing suffix is committed. Callers serialize reads and writes on their StorageQueue lane.
public enum PagedTranscript {
    public static let pageSize = 128
    public static let residentLimit = 256
    public static let browsingLimit = 512

    /// An unresolved message can outlive the resident suffix. Keep that message alone, not all
    /// completed payload following it. Its eventual update retains its original ordinal and ID.
    public struct Pending: Sendable {
        public var position: Int
        public var base: ChatMessage
        public var message: ChatMessage
        public init(position: Int, message: ChatMessage) {
            self.position = position; self.base = message; self.message = message
        }
    }

    public struct Page: Codable, Equatable, Sendable {
        public var start: Int
        public var count: Int
        public var offset: Int
        public var bytes: Int
        public var hash: String
        /// Summary of everything before this page, so trimming payload does not trim status.
        public var prefix: ThreadDigest
    }

    /// A suffix of the conversation, with its original payload for three-way reconciliation if an
    /// external editor changes the file while the app has it open. A nil base explicitly replaces
    /// the entire transcript (the original public save API).
    public struct Snapshot: Sendable {
        public var messages: [ChatMessage]
        public var start: Int
        public var base: [ChatMessage]?
        public var pending: [Pending]
        public init(_ messages: [ChatMessage], start: Int = 0, base: [ChatMessage]? = nil, pending: [Pending] = []) {
            self.messages = messages
            self.start = start
            self.base = base
            self.pending = pending
        }
    }

    struct Commit: Codable {
        var offset: Int
        var inode: UInt64
        var prefix: String
        var old: Data
        var new: Data
    }

    public enum Failure: Error { case changedDuringRead, invalidRange, unreadableOriginal }

    static func indexURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("index.json") }
    static func commitURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("commit.json") }

    static func readIndex(_ url: URL) -> TranscriptIndex? {
        guard let data = try? Data(contentsOf: indexURL(url)) else { return nil }
        HistoryCounters.shared.record(url) { $0.indexReads += 1; $0.indexBytesRead += data.count }
        guard let index = try? JSONDecoder().decode(TranscriptIndex.self, from: data),
              index.version == TranscriptIndex.currentVersion else { return nil }
        return index
    }

    static func validIndex(_ url: URL) -> TranscriptIndex? {
        guard !FileManager.default.fileExists(atPath: commitURL(url).path),
              let index = readIndex(url), index.stamp == FileStamp.of(url),
              let tail = try? bytes(url, offset: max(0, Int(index.stamp.size) - TranscriptIndex.tailLength),
                                    count: min(Int(index.stamp.size), TranscriptIndex.tailLength), counted: false),
              ContentHash.of(tail) == index.tail else { return nil }
        if let pages = index.pages {
            var start = 0, offset = 0
            for page in pages {
                guard page.start == start, page.prefix.count == start, page.offset == offset, page.count > 0, page.count <= pageSize,
                      page.bytes > 0, page.bytes <= Int(index.stamp.size) - offset else { return nil }
                start += page.count; offset += page.bytes
            }
            guard start == index.digest.count, offset == Int(index.stamp.size) else { return nil }
        }
        return index
    }

    static func bytes(_ url: URL, offset: Int, count: Int, counted: Bool = true) throws -> Data {
        guard offset >= 0, count >= 0 else { throw Failure.invalidRange }
        if count == 0 { return Data() }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw Failure.changedDuringRead }
        if counted { HistoryCounters.shared.record(url) { $0.reads += 1; $0.bytesRead += data.count } }
        return data
    }

    static func decode(_ data: Data, at url: URL) throws -> [ChatMessage] {
        let messages = try data.split(separator: 0x0A).map { try Store.decoder.decode(ChatMessage.self, from: Data($0)) }
        HistoryCounters.shared.record(url) { $0.decoded += messages.count }
        return messages
    }

    static func encode(_ messages: [ChatMessage], at url: URL) throws -> Data {
        let data = try BotHome.encodeThread(messages)
        HistoryCounters.shared.record(url) { $0.encoded += messages.count }
        return data
    }

    static func writeIndex(_ index: TranscriptIndex, at url: URL) throws {
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL(url), options: .atomic)
        HistoryCounters.shared.record(url) { $0.indexWrites += 1; $0.indexBytesWritten += data.count }
    }

    /// Indexes existing bytes without rewriting them. Legacy originals are kept once, before the
    /// first in-place commit, even if the index was removed or an upgrade was interrupted.
    static func buildIndex(_ url: URL, data: Data, messages: [ChatMessage], persist: Bool = true) throws -> TranscriptIndex {
        guard let stamp = FileStamp.of(url) else { throw Failure.changedDuringRead }
        var index = TranscriptIndex(stamp: stamp, data: data, digest: ThreadDigest(messages))
        var pages: [Page] = []
        var summary = ThreadSummary(), reply: String?
        var shells = 0
        var offset = 0, start = 0
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        while start < messages.count {
            let count = min(pageSize, messages.count - start)
            let length = lines[start..<(start + count)].reduce(0) { $0 + $1.count + 1 }
            pages.append(Page(start: start, count: count, offset: offset, bytes: min(length, data.count - offset),
                              hash: ContentHash.of(data[offset..<min(offset + length, data.count)]),
                              prefix: ThreadDigest(summary: summary, count: start, lastReply: reply, shellCount: shells)))
            let group = Array(messages[start..<(start + count)])
            summary.extend(with: group, from: 0)
            shells += ToolCounts(messages: group).shell
            if let last = group.last(where: { $0.role == .assistant }) { reply = last.text }
            start += count; offset += length
        }
        index.pages = pages
        if persist { try writeIndex(index, at: url) }
        return index
    }

    /// Exceptional full scan: first migration, an external edit, missing index, or damage. The
    /// normal indexed path below never reaches it. Original damage keeps TranscriptRead's backup/note.
    static func prepare(_ url: URL) throws -> (TranscriptIndex, Bool) {
        try recoverCommit(url)
        if let index = validIndex(url), index.pages != nil { return (index, false) }
        let before = FileStamp.of(url)
        var data = Data()
        let read = TranscriptRead.read(url) { data = $0 }
        var messages = read.messages
        if let note = read.note(for: .conversation) {
            guard read.kept != nil else { throw Failure.unreadableOriginal }
            messages.append(note)
            data = try encode(messages, at: url)
            try BotHome.write(data, to: url)
            HistoryCounters.shared.record(url) { $0.repairs += 1 }
        } else if before == nil {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .atomic)
        } else {
            guard FileStamp.of(url) == before else { throw Failure.changedDuringRead }
            // Blank lines and a missing final newline are legal legacy JSONL. Normalize once,
            // preserving the exact original before the first rewrite.
            let rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            let lines = rawLines.last?.isEmpty == true ? rawLines.dropLast() : rawLines[...]
            if lines.count != messages.count || (!data.isEmpty && data.last != 0x0A) || lines.contains(where: { $0.allSatisfy { [9, 13, 32].contains($0) } }) {
                try keepOriginal(url)
                data = try encode(messages, at: url)
                try BotHome.write(data, to: url)
            }
        }
        if before != nil, !read.isDamaged, readIndex(url)?.pages == nil { try keepOriginal(url) }
        return (try buildIndex(url, data: data, messages: messages, persist: before != nil), true)
    }

    static func keepOriginal(_ url: URL) throws {
        let kept = url.deletingPathExtension().appendingPathExtension("original.jsonl")
        guard FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: kept.path) else { return }
        try FileManager.default.copyItem(at: url, to: kept)
        HistoryCounters.shared.record(url) { $0.copies += 1 }
    }

    public static func load(_ url: URL, before: Int? = nil, limit: Int = residentLimit) throws -> HistoryLoad {
        let (index, rebuilt) = try prepare(url)
        let end = max(0, min(before ?? index.digest.count, index.digest.count))
        let start = max(0, end - max(1, limit))
        let slice = try read(url, index: index, range: start..<end)
        return HistoryLoad(messages: slice.messages, digest: index.digest, bytes: slice.bytes, reindexed: rebuilt,
                           start: start, prefix: slice.prefix)
    }

    struct Slice { var messages: [ChatMessage]; var bytes: Int; var prefix: ThreadDigest }

    static func read(_ url: URL, index: TranscriptIndex, range: Range<Int>) throws -> Slice {
        guard range.lowerBound >= 0, range.upperBound <= index.digest.count else { throw Failure.invalidRange }
        guard !range.isEmpty, let first = index.pages?.last(where: { $0.start <= range.lowerBound }),
              let last = index.pages?.last(where: { $0.start < range.upperBound }) else {
            return Slice(messages: [], bytes: 0, prefix: index.digest)
        }
        let data = try bytes(url, offset: first.offset, count: last.offset + last.bytes - first.offset)
        let messages = try decode(data, at: url)
        guard FileStamp.of(url) == index.stamp else { throw Failure.changedDuringRead }
        let leading = Array(messages.prefix(range.lowerBound - first.start))
        var summary = first.prefix.summary
        summary.extend(with: leading, from: 0)
        var prefix = ThreadDigest(summary: summary, count: range.lowerBound,
                                  lastReply: leading.last(where: { $0.role == .assistant })?.text ?? first.prefix.lastReply,
                                  shellCount: first.prefix.shellCount + ToolCounts(messages: leading).shell)
        if !leading.contains(where: { $0.role == .assistant }) { prefix.lastReplyCut = first.prefix.lastReplyCut }
        return Slice(messages: Array(messages.dropFirst(leading.count).prefix(range.count)), bytes: data.count, prefix: prefix)
    }

    /// Saves only the changed suffix. Unchanged completed messages are compared but never encoded
    /// or written. Runtime snapshots contain at most the resident tail plus unresolved tools.
    @discardableResult
    public static func save(_ snapshot: Snapshot, to url: URL) throws -> Int {
        // Fail before creating a redo record when an existing path cannot be written. In
        // particular a locked file must leave taken-message recovery in charge, and a directory
        // at this path must not be moved aside by the read/repair path during a failed save.
        if FileManager.default.fileExists(atPath: url.path) {
            let writable = try FileHandle(forWritingTo: url)
            try writable.close()
        }
        let (prepared, rebuilt) = try prepare(url)
        let updates = snapshot.pending.filter { $0.message != $0.base }
        let index: TranscriptIndex
        if updates.isEmpty { index = prepared }
        else {
            try amend(updates, at: url)
            index = try prepare(url).0
        }
        if snapshot.base != nil, rebuilt, index.digest.count > 0 {
            let disk = try read(url, index: index, range: 0..<index.digest.count).messages
            try keepConflicts(disk, base: snapshot.base ?? [], incoming: snapshot.messages, at: url)
            let merged = reconcile(disk, base: snapshot.base ?? [], incoming: snapshot.messages)
            return try save(Snapshot(merged), to: url)
        }
        guard snapshot.start >= 0, snapshot.start <= index.digest.count else { throw Failure.invalidRange }
        let old = try read(url, index: index, range: snapshot.start..<index.digest.count).messages
        // A prior save can shift this suffix after an external insertion; locate its stable ID.
        if let base = snapshot.base, let first = base.first, let held = old.first, held.id != first.id {
            let disk = try read(url, index: index, range: 0..<index.digest.count).messages
            try keepConflicts(disk, base: base, incoming: snapshot.messages, at: url)
            return try save(Snapshot(reconcile(disk, base: base, incoming: snapshot.messages)), to: url)
        }
        if let base = snapshot.base, !old.elementsEqual(base, by: equivalent) {
            try keepConflicts(old, base: base, incoming: snapshot.messages, at: url)
            return try save(Snapshot(reconcile(old, base: base, incoming: snapshot.messages), start: snapshot.start), to: url)
        }
        var same = 0
        while same < min(old.count, snapshot.messages.count), equivalent(old[same], snapshot.messages[same]) { same += 1 }
        if same == old.count, same == snapshot.messages.count { return 0 }
        let changed = snapshot.start + same
        let pages = index.pages ?? []
        let page = pages.last(where: { $0.start <= changed })
        let boundary = page?.start ?? 0
        let prefixBytes = try bytes(url, offset: page?.offset ?? 0, count: page?.bytes ?? 0)
        let prefixLength = prefixBytes.split(separator: 0x0A).prefix(changed - boundary).reduce(0) { $0 + $1.count + 1 }
        let offset = (page?.offset ?? 0) + prefixLength
        let replacement = try encode(Array(snapshot.messages.dropFirst(same)), at: url)
        let previous = try bytes(url, offset: offset, count: Int(index.stamp.size) - offset)
        let prefix = try bytes(url, offset: max(0, offset - TranscriptIndex.tailLength), count: min(offset, TranscriptIndex.tailLength))
        let commit = Commit(offset: offset, inode: index.stamp.inode, prefix: ContentHash.of(prefix), old: previous, new: replacement)
        // A durable redo record precedes the first mutation; recovery is idempotent at every step.
        guard FileStamp.of(url) == index.stamp else { throw Failure.changedDuringRead }
        let journalData = try JSONEncoder().encode(commit)
        try durable(journalData, to: commitURL(url))
        HistoryCounters.shared.record(url) { $0.journalBytesWritten += journalData.count }
        if FileStamp.of(url) != index.stamp {
            try recoverCommit(url)
            _ = try prepare(url)
            return replacement.count
        }
        try apply(commit, to: url)

        // Rebuild only the affected page and following tail, retaining completed page metadata.
        let retained = pages.filter { $0.start + $0.count <= boundary }
        let prefixMessages = try decode(Data(prefixBytes.prefix(prefixLength)), at: url)
        let tailMessages = prefixMessages + snapshot.messages.dropFirst(same)
        let tailData = Data(prefixBytes.prefix(prefixLength)) + replacement
        var next = index
        var summary = page?.prefix.summary ?? ThreadSummary()
        var reply = page?.prefix.lastReply
        var replyCut = page?.prefix.lastReplyCut ?? false
        var shells = page?.prefix.shellCount ?? 0
        var nextPages = retained
        var position = 0, byte = page?.offset ?? 0
        let lines = tailData.split(separator: 0x0A)
        while position < tailMessages.count {
            let count = min(pageSize, tailMessages.count - position)
            let length = lines[position..<(position + count)].reduce(0) { $0 + $1.count + 1 }
            let local = byte - (page?.offset ?? 0)
            var prefix = ThreadDigest(summary: summary, count: boundary + position, lastReply: reply, shellCount: shells)
            prefix.lastReplyCut = replyCut
            nextPages.append(Page(start: boundary + position, count: count, offset: byte, bytes: length,
                                  hash: ContentHash.of(tailData[local..<(local + length)]),
                                  prefix: prefix))
            let group = Array(tailMessages[position..<(position + count)])
            summary.extend(with: group, from: 0)
            shells += ToolCounts(messages: group).shell
            if let last = group.last(where: { $0.role == .assistant }) {
                reply = last.text
                replyCut = last.text.trimmingCharacters(in: .whitespacesAndNewlines).count > ThreadDigest.replyKept
            }
            position += count; byte += length
        }
        next.pages = nextPages
        next.digest = ThreadDigest(summary: summary, count: snapshot.start + snapshot.messages.count, lastReply: reply, shellCount: shells)
        next.digest.lastReplyCut = replyCut
        next.stamp = FileStamp.of(url)!
        next.tail = ContentHash.of(try bytes(url, offset: max(0, byte - TranscriptIndex.tailLength), count: min(byte, TranscriptIndex.tailLength), counted: false))
        // The page hashes replace the legacy whole-file hash; no completed payload is re-read.
        next.hash = ContentHash.of(Data(nextPages.map(\.hash).joined(separator: ",").utf8))
        try writeIndex(next, at: url)
        try FileManager.default.removeItem(at: commitURL(url))
        return replacement.count
    }

    static func durable(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    /// Rare out-of-order completion of a tool older than the resident tail. Only its page is
    /// decoded and its changed message encoded. An atomic compatibility-file replacement streams
    /// unchanged byte ranges through a small buffer; ordinary checkpoints never take this path.
    /// Before rename the old file is complete; after rename the new file is complete. A stale
    /// index after interruption is rebuilt from that authoritative file.
    static func amend(_ pending: [Pending], at url: URL) throws {
        guard !pending.isEmpty, let index = validIndex(url), let pages = index.pages else { return }
        var changes: [Int: Data] = [:]
        var shellChanges: [(position: Int, delta: Int)] = []
        var keptConflict = false
        func locate(_ update: Pending) throws -> (page: Int, local: Int, lines: [Data], message: ChatMessage) {
            let expected = pages.firstIndex { $0.start <= update.position && update.position < $0.start + $0.count }
            let candidates = expected.map { [$0] } ?? []
            for pageIndex in candidates + pages.indices.filter({ $0 != expected }) {
                let page = pages[pageIndex]
                let data = try changes[pageIndex] ?? bytes(url, offset: page.offset, count: page.bytes)
                let lines = data.split(separator: 0x0A).map { Data($0) }
                let local = pageIndex == expected ? update.position - page.start : nil
                let positions = (local.map { [$0] } ?? []) + lines.indices.filter { $0 != local }
                for position in positions {
                    let message = try Store.decoder.decode(ChatMessage.self, from: lines[position])
                    HistoryCounters.shared.record(url) { $0.decoded += 1 }
                    if message.id == update.message.id { return (pageIndex, position, lines, message) }
                }
            }
            throw Failure.changedDuringRead
        }
        for update in pending {
            // An external insertion can shift the ordinal. The usual path decodes one message;
            // a mismatch searches one page at a time by stable ID, without retaining old payload.
            let found = try locate(update), pageIndex = found.page
            let page = pages[pageIndex]
            var lines = found.lines
            let original = found.message
            guard original.role == .tool, update.message.role == .tool else { throw Failure.changedDuringRead }
            let message = mergeTool(original, base: update.base, incoming: update.message)
            if equivalent(original, message) { continue }
            if !keptConflict {
                keptConflict = try keepConflicts([original], base: [update.base], incoming: [update.message], at: url)
            }
            shellChanges.append((page.start + found.local, ToolCounts(messages: [message]).shell - ToolCounts(messages: [original]).shell))
            lines[found.local] = try Store.lineEncoder.encode(message)
            HistoryCounters.shared.record(url) { $0.encoded += 1 }
            var replacement = Data()
            for line in lines { replacement.append(line); replacement.append(0x0A) }
            changes[pageIndex] = replacement
        }
        guard !changes.isEmpty else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".thread-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let input = try FileHandle(forReadingFrom: url), output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var next = index, offset = 0, changedBytes = 0, copiedBytes = 0
        for (position, page) in pages.enumerated() {
            next.pages![position].offset = offset
            next.pages![position].prefix.shellCount += shellChanges.filter { $0.position < page.start }.reduce(0) { $0 + $1.delta }
            if let data = changes[position] {
                try output.write(contentsOf: data)
                next.pages![position].bytes = data.count
                next.pages![position].hash = ContentHash.of(data)
                offset += data.count; changedBytes += data.count
            } else {
                try input.seek(toOffset: UInt64(page.offset))
                var left = page.bytes
                while left > 0 {
                    let data = try input.read(upToCount: min(left, 65_536)) ?? Data()
                    guard !data.isEmpty else { throw Failure.changedDuringRead }
                    try output.write(contentsOf: data)
                    left -= data.count; copiedBytes += data.count
                }
                offset += page.bytes
            }
        }
        try output.synchronize()
        guard FileStamp.of(url) == index.stamp else { throw Failure.changedDuringRead }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        next.digest.shellCount += shellChanges.reduce(0) { $0 + $1.delta }
        next.stamp = FileStamp.of(url)!
        next.tail = ContentHash.of(try bytes(url, offset: max(0, offset - TranscriptIndex.tailLength), count: min(offset, TranscriptIndex.tailLength), counted: false))
        next.hash = ContentHash.of(Data(next.pages!.map(\.hash).joined(separator: ",").utf8))
        try writeIndex(next, at: url)
        HistoryCounters.shared.record(url) { $0.writes += 1; $0.bytesWritten += changedBytes; $0.bytesCopied += copiedBytes }
    }

    static func mergeTool(_ disk: ChatMessage, base: ChatMessage, incoming: ChatMessage) -> ChatMessage {
        var result = disk
        func take<Value: Equatable>(_ key: WritableKeyPath<ChatMessage, Value>) {
            if incoming[keyPath: key] != base[keyPath: key] { result[keyPath: key] = incoming[keyPath: key] }
        }
        take(\.text); take(\.toolName); take(\.toolInput); take(\.toolOutput); take(\.toolState)
        take(\.toolArguments); take(\.toolExitCode); take(\.toolDuration)
        return result
    }

    static func apply(_ commit: Commit, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(commit.offset))
        try file.write(contentsOf: commit.new)
        try file.truncate(atOffset: UInt64(commit.offset + commit.new.count))
        try file.synchronize()
        guard FileStamp.of(url)?.inode == commit.inode else { throw Failure.changedDuringRead }
        HistoryCounters.shared.record(url) { $0.writes += 1; $0.bytesWritten += commit.new.count }
    }

    /// Replay a committed tail before any reader observes the transcript. In an external-edit
    /// conflict, keep the exact file, then reconcile IDs instead of replaying over the editor's work.
    static func recoverCommit(_ url: URL) throws {
        let journal = commitURL(url)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let commit = try JSONDecoder().decode(Commit.self, from: Data(contentsOf: journal))
        let stamp = FileStamp.of(url)
        let size = Int(stamp?.size ?? 0)
        let prefix = size >= commit.offset ? try bytes(url, offset: max(0, commit.offset - TranscriptIndex.tailLength),
                                                     count: min(commit.offset, TranscriptIndex.tailLength)) : Data()
        let tail = size >= commit.offset ? try bytes(url, offset: commit.offset, count: size - commit.offset) : Data()
        // FileHandle can leave a partial replacement followed by the old suffix if interrupted.
        let common = zip(tail, commit.new).prefix(while: { $0 == $1 }).count
        let interrupted = common == tail.count || (tail.count == commit.old.count && tail.dropFirst(common) == commit.old.dropFirst(common))
        if stamp?.inode == commit.inode, ContentHash.of(prefix) == commit.prefix,
           tail == commit.old || tail == commit.new || interrupted {
            try apply(commit, to: url)
        } else {
            let kept = url.deletingPathExtension().appendingPathExtension("conflict-\(UUID().uuidString).jsonl")
            if stamp != nil { try FileManager.default.copyItem(at: url, to: kept) }
            let current = TranscriptRead.read(url).messages
            let base = try decode(commit.old, at: url), incoming = try decode(commit.new, at: url)
            try BotHome.write(try encode(reconcile(current, base: base, incoming: incoming, preserveMissing: true), at: url), to: url)
        }
        // The file is durable before the redo record goes away. An absent/stale index is rebuilt.
        try? FileManager.default.removeItem(at: indexURL(url))
        try FileManager.default.removeItem(at: journal)
    }

    public static func matching(_ ids: Set<UUID>, in url: URL) throws -> [ChatMessage] {
        guard !ids.isEmpty else { return [] }
        let (index, _) = try prepare(url)
        var remaining = ids, found: [ChatMessage] = []
        for page in (index.pages ?? []).reversed() {
            let messages = try read(url, index: index, range: page.start..<(page.start + page.count)).messages
            for message in messages where remaining.remove(message.id) != nil { found.append(message) }
            if remaining.isEmpty { break }
        }
        return found
    }

    /// The exact recap and outstanding receipt input, requested off the UI thread at turn start.
    /// Tool payload is never retained. Stop once the recap budget and the last answered user are
    /// covered, even when a conversation has thousands of earlier tool calls.
    public static func context(_ url: URL, through lastID: UUID? = nil) throws -> [ChatMessage] {
        let (index, _) = try prepare(url)
        var result: [ChatMessage] = [], characters = 0, recapDone = false, answered = false, receiptsDone = false, recordedTool = false
        var reached = lastID == nil
        for page in (index.pages ?? []).reversed() {
            let messages = try read(url, index: index, range: page.start..<(page.start + page.count)).messages
            for message in messages.reversed() {
                if message.id == lastID { reached = true }
                guard reached else { continue }
                if !receiptsDone {
                    if message.role == .assistant || message.role == .tool { answered = true }
                    if message.role == .user, answered { receiptsDone = true }
                }
                if message.role == .assistant || message.role == .user {
                    if !recapDone {
                        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let size = min(text.count, BotContext.maxRecapMessageCharacters) + (text.count > BotContext.maxRecapMessageCharacters ? 4 : 0)
                                + (message.role == .user ? 7 : 5)
                            characters += size
                            if characters > BotContext.maxRecapCharacters { recapDone = true }
                        }
                    }
                    if !recapDone || !receiptsDone { result.append(message) }
                } else if !receiptsDone {
                    if message.role == .receipt { result.append(message) }
                    else if message.role == .tool, !recordedTool {
                        recordedTool = true
                        // Only its presence answers the preceding user, not the tool's payload.
                        result.append(ChatMessage(id: message.id, role: .tool, date: message.date))
                    }
                }
                if recapDone && receiptsDone { return result.reversed() }
            }
        }
        return result.reversed()
    }

    /// JSONL dates have whole-second precision. Comparing in-memory fractions against their saved
    /// representation must not turn every unchanged message into an edit.
    static func equivalent(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        guard lhs.date.timeIntervalSince1970.rounded(.down) == rhs.date.timeIntervalSince1970.rounded(.down) else { return false }
        var rhs = rhs
        rhs.date = lhs.date
        return lhs == rhs
    }

    /// Both writers changed the same ID. The app's current stream can continue, while the exact
    /// external version remains recoverable beside it. Ordinary unchanged-base saves never copy.
    @discardableResult
    static func keepConflicts(_ disk: [ChatMessage], base: [ChatMessage], incoming: [ChatMessage], at url: URL) throws -> Bool {
        let originals = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let saved = Dictionary(disk.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard incoming.contains(where: { edit in
            guard let original = originals[edit.id], let message = saved[edit.id] else { return false }
            return !equivalent(edit, original) && !equivalent(message, original) && !equivalent(edit, message)
        }) else { return false }
        let kept = url.deletingPathExtension().appendingPathExtension("conflict-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: url, to: kept)
        HistoryCounters.shared.record(url) { $0.copies += 1 }
        return true
    }

    static func reconcile(_ disk: [ChatMessage], base: [ChatMessage], incoming: [ChatMessage], preserveMissing: Bool = false) -> [ChatMessage] {
        let originals = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let edits = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let existing = Set(disk.map(\.id))
        var merged = disk.compactMap { message -> ChatMessage? in
            guard let original = originals[message.id] else { return message }
            guard let edit = edits[message.id] else { return equivalent(message, original) ? nil : message }
            return equivalent(edit, original) ? message : edit
        }
        for (position, message) in incoming.enumerated() where !existing.contains(message.id)
            && (preserveMissing || (originals[message.id].map { !equivalent($0, message) } ?? true)) {
            let following = Set(incoming.dropFirst(position + 1).map(\.id))
            if let next = merged.firstIndex(where: { following.contains($0.id) }) { merged.insert(message, at: next) }
            else { merged.append(message) }
        }
        return merged
    }
}
