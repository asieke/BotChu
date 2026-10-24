import Foundation

/// How much conversation history BotChu has read, decoded, written and copied, per file, for
/// measuring what a launch costs (#109) and for tests that check it reads only what it needs. Each
/// file counts on its own, so a test reads the counts under its own folder (`counts(under:)`) and
/// work elsewhere in the process doesn't change them.
public final class HistoryCounters: @unchecked Sendable {
    public struct Counts: Equatable, Sendable {
        /// JSON Lines files read (transcripts, queues, sub-agents' and jobs' threads), and their bytes.
        public var reads = 0
        public var bytesRead = 0
        /// Messages decoded from them.
        public var decoded = 0
        /// JSON Lines files written whole, and their bytes.
        public var writes = 0
        public var bytesWritten = 0
        /// Files rewritten while being read, with what could be read (`TranscriptRead`).
        public var repairs = 0
        /// Originals kept beside a file that couldn't be read (`<name>.unreadable-<time>`).
        public var copies = 0
        /// Conversations' index files (`thread.index.json`) read and written.
        public var indexReads = 0
        public var indexWrites = 0

        public init() {}

        static func + (lhs: Counts, rhs: Counts) -> Counts {
            var sum = lhs
            sum.reads += rhs.reads
            sum.bytesRead += rhs.bytesRead
            sum.decoded += rhs.decoded
            sum.writes += rhs.writes
            sum.bytesWritten += rhs.bytesWritten
            sum.repairs += rhs.repairs
            sum.copies += rhs.copies
            sum.indexReads += rhs.indexReads
            sum.indexWrites += rhs.indexWrites
            return sum
        }

        /// One line, for a benchmark's report.
        public var summary: String {
            "\(reads) reads (\(bytesRead) B), \(decoded) decoded, \(writes) writes (\(bytesWritten) B), "
                + "\(repairs) repairs, \(copies) copies, index \(indexReads) read / \(indexWrites) written"
        }
    }

    public static let shared = HistoryCounters()

    private let lock = NSLock()
    private var files: [String: Counts] = [:]

    public init() {}

    func record(_ url: URL, _ change: (inout Counts) -> Void) {
        lock.lock()
        change(&files[url.path, default: Counts()])
        lock.unlock()
    }

    /// What was done to the files under `folder` (everywhere, for nil).
    public func counts(under folder: URL? = nil) -> Counts {
        let prefix = folder.map(Self.prefix)
        lock.lock()
        defer { lock.unlock() }
        return files.reduce(Counts()) { sum, entry in prefix.map(entry.key.hasPrefix) ?? true ? sum + entry.value : sum }
    }

    /// The files under `folder` that were read, with the messages decoded from each.
    public func decodedFiles(under folder: URL) -> [String: Int] {
        let prefix = Self.prefix(folder)
        lock.lock()
        defer { lock.unlock() }
        return files.filter { $0.key.hasPrefix(prefix) && $0.value.decoded > 0 }.mapValues(\.decoded)
    }

    /// Forgets what was counted under `folder` (everywhere, for nil).
    public func reset(under folder: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let folder else { files = [:]; return }
        let prefix = Self.prefix(folder)
        files = files.filter { !$0.key.hasPrefix(prefix) }
    }

    private static func prefix(_ folder: URL) -> String {
        folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
    }
}
