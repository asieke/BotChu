import Foundation

/// `botchu-subagent resume <id>` (#368): relaunch an interrupted run of this conversation's with its
/// brief, session and workspace. Like every request, its caller fields only name the turn whose
/// mailbox it is in; BotChu checks them against what it registered for that turn.
public struct SubagentResumeRequest: Equatable, Sendable {
    public static let kind = "resume"

    public var id: UUID
    public var runID: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    public var depth: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), runID: UUID, invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil,
                parentSubagentID: UUID? = nil, depth: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.runID = runID
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID
        self.parentSubagentID = parentSubagentID
        self.depth = depth
        self.createdAt = createdAt
    }

    public static func isRequest(_ data: Data) -> Bool { SubagentRequestFields.kind(of: data) == kind }

    public static func parse(_ data: Data) throws -> SubagentResumeRequest {
        let fields = try SubagentRequestFields(data, kind: kind)
        guard let runID = fields.uuid("runID") else { throw InboxRequest.Problem("it doesn't name a sub-agent run") }
        return SubagentResumeRequest(id: fields.id, runID: runID, invocationID: fields.invocationID, callerBotID: fields.callerBotID,
                                     callerTaskID: fields.uuid("callerTaskID"), parentSubagentID: fields.uuid("parentSubagentID"),
                                     depth: fields.depth, createdAt: fields.createdAt)
    }

    /// `now` is nil for a request from a host, whose clock isn't this Mac's.
    public func validate(_ caller: SubagentCallerContext, now: Date? = Date()) throws {
        try SubagentRequestFields.validate(invocationID: invocationID, botID: callerBotID, taskID: callerTaskID, parent: parentSubagentID,
                                           depth: depth, createdAt: createdAt, against: caller, now: now)
    }
}

/// `botchu-subagent wait <id>` from a later turn (#368): the runs it names that this turn's mailbox
/// knows nothing of, so BotChu sends their handoffs here, now or once they end.
public struct SubagentAttachRequest: Equatable, Sendable {
    public static let kind = "attach"
    public static let maxRuns = 64

    public var id: UUID
    public var runIDs: [UUID]
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    public var depth: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), runIDs: [UUID], invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil,
                parentSubagentID: UUID? = nil, depth: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.runIDs = runIDs
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID
        self.parentSubagentID = parentSubagentID
        self.depth = depth
        self.createdAt = createdAt
    }

    public static func isRequest(_ data: Data) -> Bool { SubagentRequestFields.kind(of: data) == kind }

    public static func parse(_ data: Data) throws -> SubagentAttachRequest {
        let fields = try SubagentRequestFields(data, kind: kind)
        guard let raw = fields.object["runIDs"] as? [Any], (1...maxRuns).contains(raw.count) else {
            throw InboxRequest.Problem("it must name 1–\(maxRuns) sub-agent runs")
        }
        let ids = raw.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
        guard ids.count == raw.count else { throw InboxRequest.Problem("a sub-agent run's ID isn't a UUID") }
        return SubagentAttachRequest(id: fields.id, runIDs: ids, invocationID: fields.invocationID, callerBotID: fields.callerBotID,
                                     callerTaskID: fields.uuid("callerTaskID"), parentSubagentID: fields.uuid("parentSubagentID"),
                                     depth: fields.depth, createdAt: fields.createdAt)
    }

    public func validate(_ caller: SubagentCallerContext, now: Date? = Date()) throws {
        try SubagentRequestFields.validate(invocationID: invocationID, botID: callerBotID, taskID: callerTaskID, parent: parentSubagentID,
                                           depth: depth, createdAt: createdAt, against: caller, now: now)
    }
}

/// BotChu's answer to a resume request, in the caller's mailbox under the request's ID.
public struct SubagentResumeAnswer: Codable, Equatable, Sendable {
    public var kind = SubagentResumeRequest.kind
    public var id: UUID
    public var runID: UUID
    public var accepted: Bool
    /// It was relaunched (false when accepted for any other reason).
    public var resumed: Bool?
    public var errorMessage: String?

    public init(id: UUID, runID: UUID, resumed: Bool) {
        self.id = id
        self.runID = runID
        accepted = true
        self.resumed = resumed
    }

    public init(id: UUID, runID: UUID, refused: String) {
        self.id = id
        self.runID = runID
        accepted = false
        errorMessage = refused
    }
}

/// What resume and attach requests share: who asks, checked as `SubagentCallerContext.validate` does.
struct SubagentRequestFields {
    var object: [String: Any]
    var id: UUID
    var invocationID: UUID
    var callerBotID: UUID
    var depth: Int
    var createdAt: Date

    static func kind(of data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String
    }

    init(_ data: Data, kind: String) throws {
        guard data.count <= 64_000, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["kind"] as? String == kind else { throw InboxRequest.Problem("it isn't a \(kind) request") }
        self.object = object
        func uuid(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
        guard let id = uuid("id"), let invocationID = uuid("invocationID"), let callerBotID = uuid("callerBotID") else {
            throw InboxRequest.Problem("it doesn't say which turn asks")
        }
        guard let stamp = object["createdAt"] as? String, let createdAt = ISO8601DateFormatter().date(from: stamp) else {
            throw InboxRequest.Problem("it doesn't say when it was made")
        }
        self.id = id
        self.invocationID = invocationID
        self.callerBotID = callerBotID
        depth = object["depth"] as? Int ?? 0
        self.createdAt = createdAt
    }

    func uuid(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }

    static func validate(invocationID: UUID, botID: UUID, taskID: UUID?, parent: UUID?, depth: Int, createdAt: Date,
                         against caller: SubagentCallerContext, now: Date?) throws {
        guard invocationID == caller.invocationID, botID == caller.botID, taskID == caller.taskID,
              parent == caller.parentSubagentID, depth == caller.depth else {
            throw InboxRequest.Problem("the asking turn no longer matches this request; ask again from the active turn")
        }
        if let now, !(createdAt.timeIntervalSince(now) < 60 && now.timeIntervalSince(createdAt) < 300) {
            throw InboxRequest.Problem("this request is stale; ask again from the active turn")
        }
    }
}

public enum SubagentResume {
    /// Why the turn `caller` may not resume or collect `run`, or nil when it may: a run of one of its
    /// bot's conversations, which it started (its next turn, or a resumed run's new CLI asking for
    /// its own children), or any of them from that bot's Home turn. Never another bot's, a sibling's,
    /// or Home's from a task.
    public static func problem(collecting run: SubagentRun, by caller: SubagentCallerContext) -> String? {
        let refused = "No sub-agent run \(run.id.uuidString.lowercased()) that this turn can resume or collect."
        guard run.rootBotID == caller.botID else { return refused }
        if run.rootTaskID == caller.taskID, run.parentSubagentID == caller.parentSubagentID { return nil }
        if caller.taskID == nil, caller.parentSubagentID == nil { return nil }
        return refused
    }

    /// Why `run` can't be relaunched, saying what to run instead, or nil when it can: one that
    /// stopped, or failed after it started.
    public static func problem(resuming run: SubagentRun) -> String? {
        let id = run.id.uuidString.lowercased()
        if run.isResumable { return nil }
        if run.phase.isActive { return "\(id) is under way: collect its handoff with botchu-subagent wait \(id)." }
        if run.phase == .completed { return "\(id) completed: botchu-subagent wait \(id) prints its handoff." }
        return "\(id) failed before it started: delegate it again."
    }

    /// Whether a resumed launch that ended starts again in a new session, with its brief: one that
    /// continued its session and failed before any tool call, as a session killed mid-tool (a call
    /// without its result) can't always be continued. Once: the new launch continues no session.
    public static func startsANewSession(continuedSession: Bool, failed: Bool, toolCallsSinceLaunch: Int) -> Bool {
        continuedSession && failed && toolCallsSinceLaunch == 0
    }

    /// The message a resumed run starts with: what interrupted it and how far it got, its workspace
    /// as it is now, the runs it started that were interrupted with it, and what to do. With its
    /// session (`session`), only this; without, after its brief. Every name in it is bounded data.
    public static func delta(for run: SubagentRun, workspace: SubagentWorkspaceState?, interruptedChildren: [SubagentRun],
                             session: Bool) -> String {
        var now = run.interruption ?? SubagentInterruption(cause: run.phase == .failed ? .failed : .owner, at: run.finishedAt ?? Date())
        now.workspace = workspace
        var lines = ["BotChu interrupted this sub-agent run, and now resumes it in a fresh launch"
                     + (session ? ", continuing your session." : "; your session couldn't be continued, so your brief is above."),
                     "How it ended: " + now.facts(for: run)]
        // A failure's own words come first in its outcome; the first paragraph says what went wrong.
        if run.phase == .failed, let error = run.errorMessage?.components(separatedBy: "\n\n").first, !error.isEmpty {
            lines.append("Its error: " + SubagentInterruption.bounded(error, 600))
        }
        if !interruptedChildren.isEmpty {
            lines.append("Sub-agent runs you started that were interrupted with it, which you can resume with "
                         + "`botchu-subagent resume <id>` (or collect with `botchu-subagent wait <id>` once they end):")
            lines += interruptedChildren.prefix(20).map {
                "- \($0.id.uuidString.lowercased()) “\(SubagentInterruption.bounded($0.title, 100))” (\(SubagentInterruption.bounded($0.targetBotName, 60)))"
            }
        }
        lines.append("Check what is already done in the workspace before redoing anything, carry on with the brief from where it "
                     + "stopped, and end with your Handoff Report.")
        return "<botchu_resume>\n" + lines.joined(separator: "\n") + "\n</botchu_resume>"
    }
}

extension SubagentRun {
    /// A run that can be relaunched with its brief, session and workspace (#368): one that stopped,
    /// or that failed after it started.
    public var isResumable: Bool { phase == .stopped || phase == .failed && interruption != nil }

    /// When the usage limit a failed run paused on resets (#442); nil for any other run.
    public var pausedUntil: Date? { phase == .failed ? interruption?.resetsAt : nil }
}

/// Whether a CLI of a run, or anything it started, still runs (#368): a process whose environment
/// has `BOTCHU_CALLER_SUBAGENT_ID` set to the run's ID, which BotChu gives each run's CLI and its
/// children inherit. Matched on the run's UUID, never a PID, so a reused PID can't match.
public enum SubagentLiveness {
    public struct Problem: Error, Equatable { public var message: String }

    /// The processes on `machine` marked with one of `ids`, or why that couldn't be checked: a
    /// check that fails or times out refuses, never passes.
    public static func processes(marked ids: [UUID], on machine: Machine = .thisMac, timeout: TimeInterval = 20) async -> Result<[Int32], Problem> {
        let arguments = ids.map { $0.uuidString.uppercased() } + ids.map { $0.uuidString.lowercased() }
        let result: Shell.Result
        if machine.isRemote {
            result = await machine.script(script, arguments: arguments, in: "~", timeout: timeout)
        } else {
            result = await ChildProcess.run("/bin/sh", ["-c", script, "botchu"] + arguments, in: "/",
                                            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: timeout)
        }
        guard result.ok, !result.timedOut, let found = parse(result.output) else {
            return .failure(Problem(message: "Couldn't check that no CLI of it still runs on \(machine.destination ?? "this Mac")"
                + (result.timedOut ? " in time." : ".")))
        }
        return .success(found)
    }

    /// The PIDs the script printed, or nil when it didn't get to the end.
    public static func parse(_ output: String) -> [Int32]? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.last == "scanned" else { return nil }
        return Array(Set(lines.dropLast().compactMap { Int32($0) })).sorted()
    }

    /// Linux keeps each process's environment in `/proc/<pid>/environ`; elsewhere `ps -E` shows it
    /// after the command. macOS shows it for the CLIs (node, Claude Code, Python, swift-build), not
    /// for its own platform binaries (zsh, sleep): a run's CLI is found, a shell it left isn't. The
    /// marker is split in the script's text, and no process it starts gets a whole one in its
    /// arguments, so it never finds itself.
    static let script = #"""
        if [ -r /proc/self/environ ]; then
          list=$(mktemp) || exit 4
          for id in "$@"; do printf 'BOTCHU_CALLER_SUBAGENT_''ID=%s\n' "$id"; done > "$list"
          for f in /proc/[0-9]*/environ; do
            pid=${f#/proc/}; pid=${pid%/environ}
            [ "$pid" = "$$" ] && continue
            tr '\000' '\n' < "$f" 2>/dev/null | grep -qxF -f "$list" && echo "$pid"
          done
          rm -f "$list"
          echo scanned
          exit 0
        fi
        out=$(ps -Eww -ax -o pid=,command=) || exit 4
        printf '%s\n' "$out" | grep -F 'BOTCHU_CALLER_SUBAGENT_' | while read -r pid rest; do
          [ "$pid" = "$$" ] && continue
          for id in "$@"; do
            case " $rest " in *" BOTCHU_CALLER_SUBAGENT_""ID=$id "*) echo "$pid"; break ;; esac
          done
        done
        echo scanned
        """#
}
