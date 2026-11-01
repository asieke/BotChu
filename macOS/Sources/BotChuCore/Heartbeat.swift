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
///
/// A failed turn (#442) whose account hit a usage limit pauses until the limit resets, then hears
/// one heartbeat a minute after (`resumeDate`), with the sub-agent runs that paused on it resumed;
/// any other failed turn is retried once, `retryDelay` after it, as a heartbeat.
public enum Heartbeat {
    /// What a bot replies to a heartbeat when nothing is left to do.
    public static let ack = "HEARTBEAT_OK"
    /// How long after a stalled turn each heartbeat in a row goes out; tests shorten them.
    nonisolated(unsafe) public static var delays: [TimeInterval] = [2 * 60, 10 * 60, 30 * 60]
    public static var maxPulses: Int { delays.count }
    /// How long after a failed turn its one retry goes out; tests shorten it.
    nonisolated(unsafe) public static var retryDelay: TimeInterval = 2 * 60
    /// How long after a usage limit resets the paused work carries on.
    public static let afterReset: TimeInterval = 60

    /// Why a turn looks stalled.
    public enum Stall: Equatable, Sendable {
        /// Its reply says work is still going.
        case promised
        /// BotChu ended its CLI while background tasks it waited for still ran.
        case backgroundEnded
        /// Its turn failed: the one retry (#442).
        case failed
        /// Its turn, or runs it started, paused on a usage limit that has reset now (#442).
        case limitReset
    }

    /// The facts of a turn that has ended.
    public struct Turn: Equatable, Sendable {
        /// Its last reply, if it had one.
        public var reply: String?
        /// The heartbeat number of the message it answered, nil for any other message.
        public var pulse: Int?
        public var stopped: Bool
        public var failed: Bool
        /// When the usage limit its account hit resets, for a turn that failed on one (`UsageLimit`).
        public var limitResetsAt: Date?
        /// Whether BotChu ended its CLI while background tasks still ran (`AgentRun.endedBackgroundTasks`).
        public var endedBackgroundTasks: Bool

        public init(reply: String?, pulse: Int? = nil, stopped: Bool = false, failed: Bool = false, limitResetsAt: Date? = nil,
                    endedBackgroundTasks: Bool = false) {
            self.reply = reply
            self.pulse = pulse
            self.stopped = stopped
            self.failed = failed || limitResetsAt != nil
            self.limitResetsAt = limitResetsAt
            self.endedBackgroundTasks = endedBackgroundTasks
        }
    }

    /// What follows a turn.
    public enum Next: Equatable, Sendable {
        /// Nothing: it didn't stall, or was stopped, acknowledged, or failed again after its retry.
        case none
        /// Heartbeat `number` goes out `after` seconds from now.
        case pulse(number: Int, after: TimeInterval, stall: Stall)
        /// It still stalled after the last heartbeat: BotChu stops checking in.
        case gaveUp
        /// Its account hit a usage limit: the conversation is paused until the limit resets
        /// (`until`), and carries on with a `.limitReset` heartbeat at `resume`.
        case paused(until: Date, resume: Date)
    }

    public static func next(after turn: Turn, now: Date = Date()) -> Next {
        guard !turn.stopped else { return .none }
        if turn.failed {
            if let reset = turn.limitResetsAt { return .paused(until: reset, resume: resumeDate(after: reset, now: now)) }
            // A turn that answered a heartbeat (its retry among them) isn't retried.
            return turn.pulse == nil ? .pulse(number: 1, after: retryDelay, stall: .failed) : .none
        }
        guard !isAck(turn.reply ?? "") else { return .none }
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

    /// When work paused on a limit that resets at `reset` carries on: a minute after, and never
    /// sooner than a minute from now. A reset that just passed (`UsageLimit.grace`) waits five
    /// minutes, so a CLI still refusing for a moment doesn't make it go round every minute.
    public static func resumeDate(after reset: Date, now: Date = Date()) -> Date {
        let due = reset.addingTimeInterval(afterReset)
        return due > now ? due : now.addingTimeInterval(reset < now.addingTimeInterval(-afterReset) ? 5 * 60 : afterReset)
    }

    /// The heartbeat message: what the bot reads. `error` is the failure a retry follows.
    public static func prompt(_ stall: Stall, number: Int, error: String? = nil) -> String {
        if stall == .failed {
            let line = (error ?? "").split(whereSeparator: \.isNewline).first.map { String($0.prefix(300)) } ?? ""
            return """
                \(retryPrefix) your last turn failed\(line.isEmpty ? "" : " (“\(line)”)"), and BotChu retries it once. Check \
                what it already did (processes, files, git, pull requests, tasks) and carry the work on to the end within \
                this turn, without redoing what is done. If nothing is left to do, or it waits for the owner, reply with just \(ack).
                """
        }
        let why = switch stall {
        case .promised:
            "your last turn ended saying work was still going, but nothing is running in this conversation now: no turn, no sub-agents, and nothing you started in the background (that ended with your turn)."
        case .backgroundEnded:
            "BotChu ended your CLI after waiting for its background tasks for too long, so they stopped before they finished."
        case .failed, .limitReset: ""
        }
        return """
            BotChu heartbeat (\(number) of \(maxPulses)): \(why) Check the real state of that work (processes, files, \
            git, pull requests, tasks) and carry it on to the end, running what it needs within this turn. If you are \
            waiting on something outside BotChu (CI, a deploy), say what. If nothing is left to do, or it waits for the \
            owner, reply with just \(ack).
            """
    }

    /// The heartbeat that carries on work paused on a usage limit once it has reset: the turn that
    /// paused (`turnPaused`), and the runs BotChu resumed (`resumed`), whose handoffs it collects.
    public static func limitPrompt(turnPaused: Bool, resumed: [SubagentRun]) -> String {
        var lines = ["\(limitPrefix) the usage limit that paused "
                     + (turnPaused ? "your last turn" : "sub-agent runs you started") + " has reset."]
        if !resumed.isEmpty {
            lines.append("BotChu resumed these runs that paused on it, each in its own workspace and session; collect each "
                         + "handoff with `botchu-subagent wait <id>`:")
            lines += resumed.prefix(20).map {
                "- \($0.id.uuidString.lowercased()) “\(SubagentInterruption.bounded($0.title, 100))” (\(SubagentInterruption.bounded($0.targetBotName, 60)))"
            }
        }
        lines.append("Check the real state of the work (processes, files, git, pull requests, tasks) and carry it on to the end "
                     + "within this turn, without redoing what is done. If nothing is left to do, or it waits for the owner, "
                     + "reply with just \(ack).")
        return lines.joined(separator: "\n")
    }

    static let retryPrefix = "BotChu heartbeat (retry):"
    static let limitPrefix = "BotChu heartbeat (usage limit reset):"

    /// The line the conversation shows for heartbeat `number`, whose message is `text`.
    public static func label(number: Int, text: String = "") -> String {
        if text.hasPrefix(retryPrefix) { return "Heartbeat: retrying the failed turn" }
        if text.hasPrefix(limitPrefix) { return "Heartbeat: carrying on after the usage limit reset" }
        return "Heartbeat \(number) of \(maxPulses): checking on unfinished work"
    }

    /// BotChu's note when a heartbeat is acknowledged, and when it stops checking in.
    public static let acknowledged = "Heartbeat: nothing left to do"
    public static let gaveUp = "BotChu stopped checking in after \(maxPulses) heartbeats. The work may still be unfinished."
}
