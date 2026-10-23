import Foundation

/// Saves sub-agents' transcripts and records (`BotHome.saveSubagentThread`, `saveSubagent`) on a
/// queue of its own. While a run streams, its latest state is written off the caller's thread at
/// most once per `interval` (`checkpoint`), each write replacing the transcript atomically, rather
/// than on every batch of output. A run's start and end are saved at once (`save`), after any
/// checkpoint under way, so a handoff never goes back to its caller before its record is durable
/// and an older checkpoint never replaces a newer state. `flush` writes every checkpoint still
/// waiting, for quitting.
public final class SubagentArchive: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var record: SubagentRun
        public var messages: [ChatMessage]
        /// The owning bot's folder.
        public var home: BotHome

        public init(record: SubagentRun, messages: [ChatMessage], home: BotHome) {
            self.record = record
            self.messages = messages
            self.home = home
        }
    }

    public typealias Writer = @Sendable (Snapshot) throws -> Void

    /// The longest a checkpoint waits; changes in between are written together.
    public let interval: TimeInterval
    private let write: Writer
    private let queue = DispatchQueue(label: "BotChu.SubagentArchive", qos: .utility)
    private let lock = NSLock()
    private var pending: [UUID: (snapshot: Snapshot, failed: @MainActor (Error) -> Void)] = [:]
    private var scheduled: Set<UUID> = []

    public init(interval: TimeInterval = 1, write: @escaping Writer = { try SubagentArchive.writeToDisk($0) }) {
        self.interval = interval
        self.write = write
    }

    public static func writeToDisk(_ snapshot: Snapshot) throws {
        try snapshot.home.saveSubagentThread(snapshot.messages, id: snapshot.record.id, taskID: snapshot.record.rootTaskID)
        try snapshot.home.saveSubagent(snapshot.record)
    }

    /// Keeps the run's latest state and writes it within `interval`, off the caller's thread. A
    /// write that fails is reported to `failed`, on the main queue.
    public func checkpoint(_ snapshot: Snapshot, failed: @escaping @MainActor (Error) -> Void) {
        let id = snapshot.record.id
        lock.lock()
        pending[id] = (snapshot, failed)
        let schedule = scheduled.insert(id).inserted
        lock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + interval) { [self] in
            lock.lock()
            let entry = pending.removeValue(forKey: id)
            scheduled.remove(id)
            lock.unlock()
            guard let entry else { return }
            do {
                try write(entry.snapshot)
            } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { entry.failed(error) } }
            }
        }
    }

    /// Writes the run's state now, after any write of it under way, and returns once it is
    /// written. A checkpoint still waiting is dropped: this state is newer.
    public func save(_ snapshot: Snapshot) throws {
        lock.lock()
        pending[snapshot.record.id] = nil
        lock.unlock()
        try queue.sync { try write(snapshot) }
    }

    /// Writes every checkpoint still waiting, and waits for writes under way. For quitting, so
    /// nothing a sub-agent streamed is lost; a write that fails then isn't reported.
    public func flush() {
        lock.lock()
        let waiting = pending.values.map(\.snapshot)
        pending = [:]
        lock.unlock()
        queue.sync {
            for snapshot in waiting { try? write(snapshot) }
        }
    }
}
