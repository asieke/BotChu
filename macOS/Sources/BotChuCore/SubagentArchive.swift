import Foundation

/// Saves sub-agents' transcripts and records (`BotHome.saveSubagentThread`, `saveSubagent`) off the
/// caller's thread, each run in its own lane of a `StorageQueue`, so one run's write never waits
/// for another's. While a run streams, its latest state is written at most once per `interval`
/// (`checkpoint`), each write replacing the transcript atomically, rather than on every batch of
/// output. A run's start and end (`save`) drop the checkpoint still waiting and are written at
/// once, after any write of that run under way, so an older checkpoint never replaces a newer
/// state; the caller waits for them without blocking, and a handoff goes back only once its record
/// is durable. `flush` writes every checkpoint still waiting, for quitting.
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

        /// The run's lane: its folder.
        public var lane: String { home.subagentURL(id: record.id, taskID: record.rootTaskID).path }
    }

    public typealias Writer = @Sendable (Snapshot) throws -> Void

    /// The longest a checkpoint waits; changes in between are written together.
    public let interval: TimeInterval
    public let storage: StorageQueue
    private let write: Writer

    public init(interval: TimeInterval = 1, storage: StorageQueue = StorageQueue(qos: .utility),
                write: @escaping Writer = { try SubagentArchive.writeToDisk($0) }) {
        self.interval = interval
        self.storage = storage
        self.write = write
    }

    public static func writeToDisk(_ snapshot: Snapshot) throws {
        try snapshot.home.saveSubagentThread(snapshot.messages, id: snapshot.record.id, taskID: snapshot.record.rootTaskID)
        try snapshot.home.saveSubagent(snapshot.record)
    }

    /// Keeps the run's latest state and writes it within `interval`, off the caller's thread. A
    /// write that fails is reported to `failed`, on the main queue.
    public func checkpoint(_ snapshot: Snapshot, failed: @escaping @MainActor (Error) -> Void) {
        // Called on the main actor only.
        nonisolated(unsafe) let failed = failed
        let write = write
        storage.replace(snapshot.lane, slot: Self.slot, value: snapshot, delay: interval, write: { try write($0); return 0 }) { result in
            guard case .failure(let error) = result, (error as? StorageQueue.Failure) == nil else { return }
            failed(error)
        }
    }

    /// Writes the run's state now, after any write of it under way, without blocking the caller;
    /// `done` gets why it couldn't, or nil once it is written, on the main queue. A checkpoint still
    /// waiting is dropped: this state is newer.
    public func save(_ snapshot: Snapshot, done: @escaping @MainActor @Sendable (Error?) -> Void) {
        storage.cancel(snapshot.lane, slot: Self.slot)
        let write = write
        storage.submit(snapshot.lane, label: "save", work: { try write(snapshot) }) { result in
            if case .failure(let error) = result { done(error) } else { done(nil) }
        }
    }

    /// Writes the run's state now, as `save(_:done:)` does, and returns once it is written.
    public func save(_ snapshot: Snapshot) async throws {
        storage.cancel(snapshot.lane, slot: Self.slot)
        let write = write
        try await storage.perform(snapshot.lane, label: "save") { try write(snapshot) }
    }

    /// Removes a finished run's folder, after any write of it, so nothing written later makes it
    /// again; `done` gets why it couldn't, or nil, on the main queue.
    public func remove(_ id: UUID, taskID: UUID?, home: BotHome, done: @escaping @MainActor @Sendable (Error?) -> Void) {
        let lane = home.subagentURL(id: id, taskID: taskID).path
        storage.cancel(lane, slot: Self.slot)
        storage.submit(lane, label: "remove", work: { try home.removeSubagent(id: id, taskID: taskID) }) { result in
            if case .failure(let error) = result { done(error) } else { done(nil) }
        }
    }

    /// Writes every checkpoint still waiting, and waits up to `timeout` for the writes under way.
    /// For quitting, so nothing a sub-agent streamed is lost; a write that fails then isn't reported.
    @discardableResult
    public func flush(timeout: TimeInterval = 10) -> [String] {
        storage.wait(timeout: timeout)
    }

    static let slot = "run"
}
