import Foundation

/// BotChu's heartbeat (#261): a conversation whose turn ended while its work was still going, with
/// nothing left running to carry it on, is asked to check on that work. Three tasks once ended their
/// turns saying "the full test suite is running, I'll report back" when their test runs had died
/// with their CLIs, and sat Idle until the owner noticed.
///
/// A turn stalls when its reply says work is still going (`promisesMore`) or BotChu ended its CLI
/// while its background tasks still ran. Then, `delays` after it, a heartbeat message goes to the
/// conversation, at most `maxPulses` in a row; a reply of just `ack` (as OpenClaw's HEARTBEAT_OK)
/// ends them quietly, and any other message starts over.
public enum Heartbeat {
    /// What a bot replies to a heartbeat when nothing is left to do.
    public static let ack = "HEARTBEAT_OK"
    /// How long after a stalled turn each heartbeat in a row goes out; tests shorten them.
    nonisolated(unsafe) public static var delays: [TimeInterval] = [2 * 60, 10 * 60, 30 * 60]
    public static var maxPulses: Int { delays.count }

    /// Why a turn looks stalled.
    public enum Stall: Equatable, Sendable {
        /// Its reply says work is still going.
        case promised
        /// BotChu ended its CLI while background tasks it waited for still ran.
        case backgroundEnded
    }

    /// The facts of a turn that has ended.
    public struct Turn: Equatable, Sendable {
        /// Its last reply, if it had one.
        public var reply: String?
        /// The heartbeat number of the message it answered, nil for any other message.
        public var pulse: Int?
        public var stopped: Bool
        public var failed: Bool
        /// Whether BotChu ended its CLI while background tasks still ran (`AgentRun.endedBackgroundTasks`).
        public var endedBackgroundTasks: Bool

        public init(reply: String?, pulse: Int? = nil, stopped: Bool = false, failed: Bool = false, endedBackgroundTasks: Bool = false) {
            self.reply = reply
            self.pulse = pulse
            self.stopped = stopped
            self.failed = failed
            self.endedBackgroundTasks = endedBackgroundTasks
        }
    }

    /// What follows a turn.
    public enum Next: Equatable, Sendable {
        /// Nothing: it didn't stall, or was stopped, failed or acknowledged.
        case none
        /// Heartbeat `number` goes out `after` seconds from now.
        case pulse(number: Int, after: TimeInterval, stall: Stall)
        /// It still stalled after the last heartbeat: BotChu stops checking in.
        case gaveUp
    }

    public static func next(after turn: Turn) -> Next {
        guard !turn.stopped, !turn.failed, !isAck(turn.reply ?? "") else { return .none }
        let stall: Stall
        if turn.endedBackgroundTasks {
            stall = .backgroundEnded
        } else if let reply = turn.reply, promisesMore(reply) {
            stall = .promised
        } else {
            return .none
        }
        let number = (turn.pulse ?? 0) + 1
        guard number <= maxPulses else { return .gaveUp }
        return .pulse(number: number, after: delays[number - 1], stall: stall)
    }

    /// Whether a reply is a heartbeat's acknowledgement: it starts or ends with `ack` (formatting
    /// aside), with at most a short remark beside it, as OpenClaw takes HEARTBEAT_OK.
    public static func isAck(_ reply: String) -> Bool {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
            .subtracting(CharacterSet(charactersIn: "_")))
        guard text.hasPrefix(ack) || text.hasSuffix(ack) else { return false }
        return text.count - ack.count <= 300
    }

    /// Whether a reply says its work goes on after the turn: that it will report back, or that
    /// something it started is still running. Only its last sentences count, and not those about
    /// what the owner does ("let me know when it's done").
    public static func promisesMore(_ reply: String) -> Bool {
        let text = String(reply.suffix(800)).lowercased().replacingOccurrences(of: "’", with: "'")
        let sentences = text.split(whereSeparator: { ".!?\n".contains($0) }).map { String($0) }
        return sentences.contains { sentence in
            guard !ownerSide.contains(where: sentence.contains) else { return false }
            return promises.contains(where: sentence.contains)
        }
    }

    private static let promises = [
        "report back", "get back to you", "check back", "check on it", "check on them", "follow up when", "follow up once",
        "let you know when", "let you know once", "update you when", "update you once", "ping you when", "ping you once",
        "keep an eye on", "keep watching", "i'll wait for", "i will wait for",
        "still running", "running in the background", "in the background now", "is running now", "are running now",
        "once it finishes", "when it finishes", "once they finish", "when they finish", "once it completes",
        "when it completes", "once they complete", "once it's done", "once they're done", "once that's done",
        "while it runs", "while they run", "waiting for it to", "waiting for them to", "waiting on it",
        "waiting for the test", "waiting for the build", "waiting for ci", "waiting for the gate",
    ]
    /// Sentences about what the owner does, which are no promise of the bot's.
    private static let ownerSide = ["let me know", "if you", "once you", "when you", "do you want", "would you like"]

    /// The heartbeat message: what the bot reads.
    public static func prompt(_ stall: Stall, number: Int) -> String {
        let why = switch stall {
        case .promised:
            "your last turn ended saying work was still going, but nothing is running in this conversation now: no turn, no sub-agents, and nothing you started in the background (that ended with your turn)."
        case .backgroundEnded:
            "BotChu ended your CLI after waiting for its background tasks for too long, so they stopped before they finished."
        }
        return """
            BotChu heartbeat (\(number) of \(maxPulses)): \(why) Check the real state of that work (processes, files, \
            git, pull requests, tasks) and carry it on to the end, running what it needs within this turn. If you are \
            waiting on something outside BotChu (CI, a deploy), say what. If nothing is left to do, or it waits for the \
            owner, reply with just \(ack).
            """
    }

    /// The line the conversation shows for heartbeat `number`.
    public static func label(number: Int) -> String {
        "Heartbeat \(number) of \(maxPulses): checking on unfinished work"
    }

    /// BotChu's note when a heartbeat is acknowledged, and when it stops checking in.
    public static let acknowledged = "Heartbeat: nothing left to do"
    public static let gaveUp = "BotChu stopped checking in after \(maxPulses) heartbeats. The work may still be unfinished."
}
