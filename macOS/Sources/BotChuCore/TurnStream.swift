import Foundation

/// One CLI turn as its stream comes in: the events its parser makes of the CLI's output, applied
/// to the conversation and the run's state in the order the CLI said them, and what BotChu writes
/// when the CLI exits. A chat turn, a sub-agent's run and a job's run each drive one, keeping only
/// what differs between them: where the sessions, the model and the transcript are kept.
public struct TurnStream {
    /// How the stream says the turn ended, so far.
    public private(set) var outcome = TurnOutcome()
    private var assembler = ThreadAssembler()
    private let account: Account
    private let adapter: any RuntimeAdapter
    private let invocation: Invocation
    private let usage: UsageLedger.Capture?

    /// `usage` records the turn's tokens, model and session, and the follow-ups it took.
    public init(account: Account, invocation: Invocation, usage: UsageLedger.Capture? = nil) {
        self.account = account
        adapter = RuntimeAdapters.adapter(for: account.kind)
        self.invocation = invocation
        self.usage = usage
    }

    public func parser() -> any StreamParser { adapter.parser() }

    /// What one batch of events said, for the driver to keep where it keeps such things.
    public struct Batch: Equatable {
        /// The sessions the CLI said it runs in, as BotChu resumes them, in order.
        public var sessions: [String] = []
        public var reportedModel: String?
        public var connectors: [Connector]?
        /// How long until each activity waiting to show can take over (`RunState.settle`).
        public var settles: [TimeInterval] = []
        /// The follow-ups the CLI took, added to the thread where it took them.
        public var followUps: [ChatMessage] = []
        /// The turn ended with nothing written to the CLI left untaken: its input closes, which
        /// lets it exit.
        public var closesInput = false

        /// Calls `settle` on the main queue once each of those waits is over.
        public func settle(_ settle: @escaping () -> Void) {
            for wait in settles { DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: settle) }
        }
    }

    /// Applies a batch the CLI's run delivered, writing the thread with `write` (the
    /// conversation's own, which holds its transcript), and moves `state` along. Nil for a batch
    /// without events, the CLI's first output when that held none: it has started, and that's all.
    /// `ledger` is the input of a CLI that takes follow-ups mid-turn, whose next one `followUp`
    /// gives once the CLI takes it. After Stop (`stopped`) a CLI's failure is left out.
    @MainActor public mutating func apply(_ events: [AgentEvent], state: inout RunState?, stopped: Bool = false,
                                          ledger: inout InputLedger?, followUp: @escaping () -> ChatMessage?,
                                          in write: ((inout [ChatMessage]) -> Void) -> Void) -> Batch? {
        if state?.hasOutput == false { state?.hasOutput = true }
        guard !events.isEmpty else { return nil }
        var batch = Batch()
        write { messages in
            for event in events {
                // After Stop, a CLI's last word is about the interruption (Antigravity repeats its
                // whole reply as a failure); the "Stopped" note says it.
                if stopped, case .failed = event { continue }
                outcome.record(event)
                usage?.record(event)
                switch event {
                case .session(let reported):
                    batch.sessions.append(adapter.resumeID(invocation: invocation, reported: reported))
                case .model(let id):
                    batch.reportedModel = id
                case .connectors(let list):
                    batch.connectors = list
                case .inputTaken:
                    guard ledger != nil else { continue }
                    if ledger?.taken() == true {
                        // A follow-up reached the CLI: it joins the transcript here.
                        if let message = followUp() {
                            usage?.include(messageID: message.id)
                            assembler.apply(event, to: &messages)
                            messages.append(message)
                            batch.followUps.append(message)
                        }
                    } else {
                        // The prompt's echo: this CLI takes follow-ups from now on.
                        state?.takesInput = true
                    }
                    continue
                case .finished, .failed:
                    // Its input closes once the CLI has taken everything written to it.
                    if ledger?.turnEnded() == true {
                        batch.closesInput = true
                        state?.takesInput = false
                    }
                default: break
                }
                if let activity = BotActivity.next(after: event), let wait = state?.move(to: activity) {
                    batch.settles.append(wait)
                }
                assembler.apply(event, to: &messages)
            }
        }
        return batch
    }

    /// `apply` for a CLI that takes no input mid-turn.
    @MainActor public mutating func apply(_ events: [AgentEvent], state: inout RunState?,
                                          in write: ((inout [ChatMessage]) -> Void) -> Void) -> Batch? {
        var none: InputLedger?
        return apply(events, state: &state, ledger: &none, followUp: { nil }, in: write)
    }

    /// The CLI exited: the reply it was writing is complete, and tools still running were interrupted.
    public mutating func close(_ messages: inout [ChatMessage]) {
        assembler.apply(.textEnd, to: &messages)
        ThreadAssembler.closeRunningTools(&messages)
    }

    /// What a turn ends with once its CLI has exited: the "Stopped" note (`byOwner` when the owner
    /// stopped it), why BotChu ended a CLI that stayed on after its turn (`lingered`), or, when the
    /// stream never said the turn finished or failed, what went wrong: the host it ran on over SSH
    /// (`host`) didn't answer, or what the CLI printed as it exited. Nil when nothing needs saying.
    public func endNote(status: Int32, stderr: String, stopped: Bool, byOwner: Bool, lingered: Bool,
                        host: String? = nil) -> ChatMessage? {
        if stopped { return .stopNote(byOwner: byOwner) }
        if lingered { return lingerNote }
        guard !outcome.ended else { return nil }
        let detail = Self.lastLines(stderr)
        if let host, status == 255 {
            // ssh's own failure: the host didn't answer, or refused the connection.
            return ChatMessage(role: .error, text: "Couldn't reach \(host) over SSH" + (detail.isEmpty ? "." : ":\n\(detail)"))
        }
        return ChatMessage(role: .error, text: detail.isEmpty
            ? "\(account.name) exited with status \(status) without replying."
            : "\(account.name) exited with status \(status):\n\(detail)")
    }

    /// A CLI still running a while after it said its turn ended was ended (#145); its turn stands.
    public var lingerNote: ChatMessage {
        ChatMessage(role: .note, text: "\(account.name) didn't exit after its reply, so BotChu ended it.")
    }

    /// The last few meaningful lines of a CLI's stderr, for an error message.
    public static func lastLines(_ text: String, count: Int = 8) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(count).joined(separator: "\n")
    }
}
