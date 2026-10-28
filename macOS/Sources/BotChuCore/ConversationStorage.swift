import Foundation

/// Saves one conversation's files off the main thread (#107), in order on its lane of a
/// `StorageQueue`: its transcript, the messages the CLI took (`taken.jsonl`) and its pending
/// messages, with the guarantees `BotHome.checkpoint` gives when it saves them at once.
///
/// A message leaving the pending ones is never in neither file. A message the CLI took, or one a
/// turn starts with, stays in the saved queue until a saved transcript holds it, and only the
/// messages the written transcript holds leave the queue, from the queue as it is once that write
/// is done, so a message taken meanwhile stays (`MessageQueue.saved`). Transcript suffixes commit
/// durably before queue files are replaced. A newer state takes the place of one not written yet,
/// so a late save never overwrites a newer
/// one; a state already written isn't written again.
@MainActor
public struct ConversationStorage {
    /// How the conversation's queue is read and changed, on the main actor, once a write is done,
    /// and where its files are by then (`files`: its bot may have moved; nil once it's gone).
    public struct Queue: Sendable {
        public var get: @MainActor @Sendable () -> MessageQueue?
        public var set: @MainActor @Sendable (MessageQueue) -> Void
        public var files: @MainActor @Sendable () -> ConversationStorage?

        public init(get: @escaping @MainActor @Sendable () -> MessageQueue?, set: @escaping @MainActor @Sendable (MessageQueue) -> Void,
                    files: @escaping @MainActor @Sendable () -> ConversationStorage?) {
            self.get = get
            self.set = set
            self.files = files
        }
    }

    public let storage: StorageQueue
    public let home: BotHome
    public let task: UUID?

    public init(storage: StorageQueue, home: BotHome, task: UUID?) {
        self.storage = storage
        self.home = home
        self.task = task
    }

    public var lane: String { home.conversationLane(task: task) }
    var transcriptURL: URL { task.map(home.taskThreadURL) ?? home.threadURL }

    /// Writes `transcript` (one with the `version` written last isn't written again). Once it is
    /// written, the queue loses the taken and starting messages it holds, and is saved when that
    /// changed it. When it can't be written while the queue holds taken messages, the pending
    /// messages pause (so the CLI takes no more that couldn't be saved either) and the queue is
    /// saved with the taken ones, which are never sent again. Failures go to `failed`, the queue's
    /// when its write is done; `done` says whether a transcript holding this one was written, as
    /// soon as it was, without waiting for the queue.
    public func saveTranscript(_ transcript: [ChatMessage], version: AnyHashable? = nil, queue: Queue,
                               failed: @escaping @MainActor @Sendable ([SaveFailure]) -> Void,
                               done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        saveTranscript(PagedTranscript.Snapshot(transcript), version: version, queue: queue, failed: failed, done: done)
    }

    public func saveTranscript(_ snapshot: PagedTranscript.Snapshot, version: AnyHashable? = nil, queue: Queue,
                               failed: @escaping @MainActor @Sendable ([SaveFailure]) -> Void,
                               done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let home = home, task = task, file = transcriptURL
        storage.replace(lane, slot: "thread", value: snapshot, version: version,
                        write: { try home.writeTranscript($0, task: task) }) { result in
            guard var current = queue.get() else {
                done?(result.isSuccess)
                return
            }
            let before = current
            var failures: [SaveFailure] = []
            switch result {
            case .success(let written):
                current.saved(written.messages)
            case .failure(let error):
                if !current.taken.isEmpty, (error as? StorageQueue.Failure) != .retired {
                    if !current.messages.isEmpty { current.pause() }
                    failures.append(SaveFailure(.conversation(paused: current.isPaused), file: file, error: error))
                }
            }
            if current != before { queue.set(current) }
            if !failures.isEmpty { failed(failures) }
            // The taken messages go into `taken.jsonl` when the transcript lacks them, and leave it
            // once it has them: where the conversation's files are now.
            if current != before || (!before.taken.isEmpty && !result.isSuccess), let files = queue.files() {
                files.saveQueue(current) { failure in
                    if let failure { failed([failure]) }
                }
            }
            done?(result.isSuccess)
        }
    }

    /// Writes the queue: the messages the CLI took first, then the pending ones and whether they
    /// are paused. `done` gets why it couldn't, or nil once a queue holding this one was written.
    public func saveQueue(_ queue: MessageQueue, done: (@MainActor @Sendable (SaveFailure?) -> Void)? = nil) {
        let home = home, task = task
        storage.replace(lane, slot: "queue", value: queue, write: { try home.saveQueue($0, task: task) }) { result in
            switch result {
            case .success: done?(nil)
            case .failure(let error): done?(SaveFailure(.pendingMessages, file: home.queueURL(task: task), error: error))
            }
        }
    }

    /// Reads the conversation's transcript on its lane, after the writes asked for before, so a
    /// repair the read makes (`TranscriptRead`) is in order with them. For a conversation read after
    /// launch; it waits only while the lane is busy.
    public func load() -> [ChatMessage] {
        let home = home, task = task
        return storage.sync(lane, label: "read") { task.map { home.loadThread(task: $0) } ?? home.loadThread() }
    }

    /// Reads the conversation's queue after its transcript on its lane (`BotHome.recoverQueue`),
    /// putting the messages the CLI took that `transcript` lacks back into it.
    public func recover(_ transcript: inout [ChatMessage]) -> (queue: MessageQueue, failures: [SaveFailure]) {
        let home = home, task = task
        var messages = transcript
        let recovered = storage.sync(lane, label: "recover") { home.recoverQueue(transcript: &messages, task: task) }
        transcript = messages
        return recovered
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
