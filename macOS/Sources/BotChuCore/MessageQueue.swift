import Foundation

/// Follow-ups for one conversation. Only delivered messages belong in its transcript; queued
/// messages keep their IDs when delivered so recovery cannot send them twice.
///
/// A follow-up reaches the bot in one of two ways: as the next turn, once the running one ends,
/// or, for a CLI that takes input mid-turn (`CommandBuilder.takesInputMidTurn`), written to the
/// running CLI, which takes it at its next tool call. A message written to the CLI stays queued
/// (`inFlight`) until the CLI says it took it; if the run ends first, it waits for the next turn.
/// A message the CLI took is kept (`taken`) until a saved transcript holds it.
public struct MessageQueue: Equatable, Sendable {
    public private(set) var messages: [ChatMessage]
    public private(set) var isPaused: Bool
    /// Messages written to the running CLI and not yet taken by it, oldest first. They can't be
    /// edited or removed any more. Not saved: after a relaunch they are queued like any other.
    public private(set) var inFlight: [UUID] = []
    /// Messages the CLI took that no saved transcript holds yet, oldest first. They are saved with
    /// the queue until one does (`BotHome.checkpoint`), so a transcript that can't be saved never
    /// loses them, and they are never sent again: after a relaunch they go back into the
    /// transcript (`restoringTaken`).
    public private(set) var taken: [ChatMessage] = []

    /// Recovered messages are sent again automatically, unless the owner's Stop or a failed turn
    /// had paused the queue (`paused`, saved beside it). A crash between saving the transcript and
    /// saving the queue may leave an already-delivered message in both files. A message the CLI
    /// took (`taken`) is never sent again, even when the saved queue still has it.
    public init(saved: [ChatMessage] = [], taken: [ChatMessage] = [], delivered: [ChatMessage] = [], paused: Bool = false) {
        var held = Set(delivered.map(\.id))
        self.taken = taken.filter { held.insert($0.id).inserted }
        messages = saved.filter { $0.role == .user && !held.contains($0.id) }
        isPaused = paused && !messages.isEmpty
    }

    /// The oldest message not yet written to the CLI, unless the queue is paused.
    public var next: ChatMessage? { isPaused ? nil : messages.first { !inFlight.contains($0.id) } }

    public func isInFlight(_ id: UUID) -> Bool { inFlight.contains(id) }

    public mutating func enqueue(_ message: ChatMessage) {
        guard message.role == .user, (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty),
              !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        isPaused = false
    }

    /// Removes a message that hasn't been written to the CLI; one in flight can't be taken back.
    public mutating func remove(_ id: UUID) {
        guard !inFlight.contains(id) else { return }
        messages.removeAll { $0.id == id }
    }

    public mutating func resume() { isPaused = false }

    /// Stop and a failed turn keep unsent text but withdraw automatic delivery.
    public mutating func pause() {
        isPaused = true
    }

    /// The message was written to the running CLI's input.
    public mutating func markInFlight(_ id: UUID) {
        guard messages.contains(where: { $0.id == id }), !inFlight.contains(id) else { return }
        inFlight.append(id)
    }

    /// The CLI took the oldest message written to it: it leaves the queue for the transcript, and
    /// is kept as taken until a saved transcript holds it.
    public mutating func acknowledge() -> ChatMessage? {
        guard !inFlight.isEmpty else { return nil }
        let id = inFlight.removeFirst()
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        let message = messages.remove(at: index)
        taken.append(message)
        return message
    }

    /// A transcript was saved: the taken messages it holds leave the queue for good.
    public mutating func saved(_ transcript: [ChatMessage]) {
        guard !taken.isEmpty else { return }
        let held = Set(transcript.map(\.id))
        taken.removeAll { held.contains($0.id) }
    }

    /// After a relaunch, the saved transcript with the taken messages it lacks put back where they
    /// belong: after everything in it, since it was last saved before the CLI took them. A note
    /// after them says that what followed them is missing.
    public func restoringTaken(into transcript: [ChatMessage]) -> [ChatMessage] {
        let held = Set(transcript.map(\.id))
        let missing = taken.filter { !held.contains($0.id) }
        guard !missing.isEmpty else { return transcript }
        let note = (missing.count == 1 ? "The bot took this message" : "The bot took these \(missing.count) messages")
            + " before BotChu could save the conversation, so what came after is missing here."
        return transcript + missing + [ChatMessage(role: .note, text: note)]
    }

    /// Called only after the old process and both output pipes have finished. Messages the CLI
    /// never took wait for the next turn. Stop and failures require the owner to resume the queue;
    /// anything else, including a turn that ended with a nonzero exit after the stream said it
    /// finished, leaves it to send on its own.
    public mutating func finishTurn(stopped: Bool, failed: Bool) {
        inFlight = []
        if failed || stopped { pause() }
    }
}

/// How a turn's stream said it ended. The last word wins: CLIs report errors they recover from,
/// such as Codex's reconnects or a failed sub-agent inside Antigravity, before finishing the turn.
public struct TurnOutcome: Equatable, Sendable {
    /// Whether the stream said the turn finished or failed.
    public private(set) var ended = false
    /// The failure the stream ended with, if it ended with one.
    public private(set) var failure: String?

    public init() {}

    public mutating func record(_ event: AgentEvent) {
        switch event {
        case .finished:
            ended = true
            failure = nil
        case .failed(let reason):
            ended = true
            failure = reason
        case .inputTaken:
            // The CLI took another message, which it answers as more of this run.
            ended = false
            failure = nil
        default: break
        }
    }

    /// Why the turn failed, or nil when it didn't. A stream that never ended leaves BotChu's own
    /// error (`exitError`: the CLI's exit status and stderr) in the transcript instead; a nonzero
    /// exit after the stream said the turn finished is not a failure.
    public func failure(stopped: Bool, exitError: String?) -> String? {
        if stopped { return nil }
        return ended ? failure : exitError
    }
}

/// What a CLI that takes input mid-turn has been given on stdin during one run, and has taken
/// back (Claude Code echoes each message it takes with `--replay-user-messages`). The first
/// message is the turn's prompt; follow-ups are written only once the CLI has echoed it, which
/// shows this CLI echoes, so a message written to it is never taken without BotChu knowing.
public struct InputLedger: Equatable, Sendable {
    public private(set) var promptTaken = false
    /// Follow-ups written and not yet taken.
    public private(set) var waiting = 0
    /// Whether the CLI's input was closed, which ends it once it has nothing left to do.
    public private(set) var closed = false

    public init() {}

    /// Whether a follow-up can be written now.
    public var acceptsFollowUps: Bool { promptTaken && !closed }

    public mutating func wrote() { waiting += 1 }

    /// The CLI took the next message written to it. True when that was a follow-up rather than
    /// the prompt.
    public mutating func taken() -> Bool {
        guard promptTaken else {
            promptTaken = true
            return false
        }
        guard waiting > 0 else { return false }
        waiting -= 1
        return true
    }

    /// After the CLI says a turn ended: whether to close its input now, which lets it exit. Not
    /// while a follow-up written to it is still untaken, since the CLI takes that as its next turn.
    public mutating func turnEnded() -> Bool {
        guard waiting == 0 else { return false }
        closed = true
        return true
    }

    /// Stop, or the run ended: nothing more is written.
    public mutating func close() { closed = true }
}
