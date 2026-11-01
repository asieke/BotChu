import Foundation

/// How far a run got when it ended without a handoff (#368): what ended it, its tool calls, its
/// last action and the workspace it left. Saved with the run, so its row says Interrupted with
/// these facts, and its caller hears them instead of a bare "Stopped". The run's phase stays
/// `.stopped` (or `.failed`), which every reader and helper already knows.
public struct SubagentInterruption: Codable, Equatable, Sendable {
    public enum Cause: String, Codable, Sendable {
        /// The owner's Stop, on the run or on its conversation.
        case owner
        /// BotChu quit or restarted while it ran.
        case restart
        /// The turn that called it ended before it handed off.
        case parentEnded
        /// The run that called it was stopped.
        case parentStopped
        /// Its CLI ended by itself without a handoff.
        case failed
    }

    public var cause: Cause
    public var at: Date
    public var toolCalls: Int
    /// Its last tool call, as `action` says it.
    public var lastAction: String?
    /// Nil outside a git checkout, or when it couldn't be read in time.
    public var workspace: SubagentWorkspaceState?
    /// For a run that failed because its account hit a usage limit, when the limit resets (#442):
    /// the run is paused until then, and BotChu resumes it a minute after. Nil otherwise.
    public var resetsAt: Date?

    public init(cause: Cause, at: Date = Date(), toolCalls: Int = 0, lastAction: String? = nil,
                workspace: SubagentWorkspaceState? = nil, resetsAt: Date? = nil) {
        self.cause = cause
        self.at = at
        self.toolCalls = toolCalls
        self.lastAction = lastAction
        self.workspace = workspace
        self.resetsAt = resetsAt
    }

    /// Reads what it can: a cause a later BotChu added reads as `failed`, so the run still decodes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cause = (try? container.decode(String.self, forKey: .cause)).flatMap(Cause.init(rawValue:)) ?? .failed
        at = (try? container.decode(Date.self, forKey: .at)) ?? Date(timeIntervalSince1970: 0)
        toolCalls = (try? container.decode(Int.self, forKey: .toolCalls)) ?? 0
        lastAction = try? container.decodeIfPresent(String.self, forKey: .lastAction)
        workspace = try? container.decodeIfPresent(SubagentWorkspaceState.self, forKey: .workspace)
        resetsAt = try? container.decodeIfPresent(Date.self, forKey: .resetsAt)
    }

    /// The interruption of a run that ended now, from its transcript (`messages`, the part in memory)
    /// and all the tool calls it made (`toolCalls`, counted with those of earlier pages; by default
    /// those in `messages`).
    public static func of(_ messages: [ChatMessage], toolCalls: Int? = nil, cause: Cause, root: String? = nil,
                          workspace: SubagentWorkspaceState? = nil, at: Date = Date()) -> SubagentInterruption {
        let tools = messages.filter { $0.role == .tool }
        let last = tools.last.map { action($0, root: root) }
        return SubagentInterruption(cause: cause, at: at, toolCalls: max(toolCalls ?? 0, tools.count), lastAction: last, workspace: workspace)
    }

    /// What the run's transcript ends with and its caller hears, in place of "Stopped" or a CLI's
    /// raw diagnostic: what ended it, how far it got, its last action and its workspace. `failure`
    /// is why a failed run's CLI ended.
    public func outcome(for run: SubagentRun, failure: String? = nil) -> String {
        // A failure says what went wrong first, as it did.
        guard cause == .failed else { return facts(for: run) }
        var text = Self.failureText(failure) + "\n\n" + facts(for: run)
        if let resetsAt {
            text += " Paused until " + UsageLimit.timeText(resetsAt, now: at) + ", when its account's usage limit resets: BotChu "
                + "resumes it then and sends a heartbeat to the conversation that started it, so don't resume or delegate it again."
        }
        return text
    }

    /// What ended it (but a failure's own words), how far it got, its last action and its workspace.
    public func facts(for run: SubagentRun) -> String {
        let calls = toolCalls == 0 ? "before any tool call" : "after \(toolCalls) tool \(toolCalls == 1 ? "call" : "calls")"
        // A restart is seen at the next launch, so how long it ran isn't known.
        let took = cause == .restart ? "" : run.startedAt.map { Self.duration(at.timeIntervalSince($0)) }.map { " in \($0)" } ?? ""
        var parts: [String]
        switch cause {
        case .owner: parts = ["The owner stopped it \(calls)\(took)."]
        case .restart: parts = ["BotChu quit or restarted while it ran, \(calls)\(took)."]
        case .parentEnded: parts = ["The turn that called it ended before its handoff, \(calls)\(took)."]
        case .parentStopped: parts = ["The run that called it was stopped, \(calls)\(took)."]
        case .failed: parts = ["It ended \(calls)\(took)."]
        }
        if let lastAction { parts.append("Last action: \(lastAction).") }
        parts.append(Self.workspaceText(run.workingDirectory, workspace))
        return parts.joined(separator: " ")
    }

    /// A tool call in one bounded line: a command as it ran (`bun run test`), anything else as its
    /// row in the transcript says it (README.md, in docs).
    public static func action(_ message: ChatMessage, root: String? = nil) -> String {
        let activity = ToolActivity.describe(message, root: root)
        if activity.isShell, let command = activity.command, !command.isEmpty { return "`" + bounded(command, 150) + "`" }
        return bounded([activity.title, activity.subtitle].filter { !$0.isEmpty }.joined(separator: " "), 160)
    }

    /// A CLI's failure as a caller can act on it: Claude Code's `[ede_diagnostic]` lines, which only
    /// say it ended during a tool call, say that.
    public static func failureText(_ failure: String?) -> String {
        let text = (failure ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Its CLI ended without a handoff." }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let diagnostic = lines.filter { $0.hasPrefix("[ede_diagnostic]") }
        let rest = lines.filter { !$0.hasPrefix("[ede_diagnostic]") && !$0.isEmpty }
        guard !diagnostic.isEmpty else { return text.count <= 4_000 ? text : String(text.prefix(3_999)) + "…" }
        let during = diagnostic.contains { $0.contains("stop_reason=tool_use") }
            ? "Its CLI ended its turn in the middle of a tool call, without a reply." : "Its CLI ended its turn without a reply."
        return rest.isEmpty ? during : bounded(rest.joined(separator: " "), 400) + " " + during
    }

    static func workspaceText(_ directory: String, _ state: SubagentWorkspaceState?) -> String {
        let place = "Workspace: \(bounded(directory, 300))"
        guard let state else { return place + "." }
        var located = place
        if let branch = state.branch, !branch.isEmpty { located += " on `\(bounded(branch, 120))`" }
        if let head = state.head, !head.isEmpty { located += " at `\(bounded(head, 120))`" }
        guard state.uncommittedCount > 0 else { return located + ", nothing uncommitted." }
        let listed = state.uncommitted.prefix(SubagentWorkspaceState.listed).map { "`\($0)`" }.joined(separator: ", ")
        let more = state.uncommittedCount > state.uncommitted.prefix(SubagentWorkspaceState.listed).count
            ? " and \(state.uncommittedCount - min(state.uncommitted.count, SubagentWorkspaceState.listed)) more" : ""
        return located + ", \(state.uncommittedCount) uncommitted: \(listed)\(more)."
    }

    /// One line of at most `limit` characters, without backticks, which would end the code spans
    /// the outcome puts it in.
    static func bounded(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "`", with: "'")
            .trimmingCharacters(in: .whitespaces)
        return line.count <= limit ? line : String(line.prefix(limit - 1)) + "…"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m" + (total % 60 == 0 ? "" : " \(total % 60)s") }
        return "\(total / 3_600)h" + (total % 3_600 / 60 == 0 ? "" : " \(total % 3_600 / 60)m")
    }
}

/// A git checkout as a run left it: its branch, its last commit and what isn't committed.
public struct SubagentWorkspaceState: Codable, Equatable, Sendable {
    public var branch: String?
    /// The last commit: its short hash and subject.
    public var head: String?
    /// The first uncommitted paths, bounded.
    public var uncommitted: [String]
    public var uncommittedCount: Int

    static let listed = 20

    public init(branch: String? = nil, head: String? = nil, uncommitted: [String] = [], uncommittedCount: Int? = nil) {
        self.branch = branch
        self.head = head
        self.uncommitted = Array(uncommitted.prefix(Self.listed))
        self.uncommittedCount = uncommittedCount ?? uncommitted.count
    }

    /// Reads it with the system's git, never writing the index or running a file monitor, within
    /// `timeout`; nil when the folder isn't a checkout, or it couldn't be read in time. Over SSH,
    /// the host's git on its login shell's PATH.
    public static func read(_ directory: String, on machine: Machine = .thisMac, timeout: TimeInterval = 5) async -> SubagentWorkspaceState? {
        let result: Shell.Result
        if machine.isRemote {
            result = await machine.script(script, in: directory, timeout: timeout)
        } else {
            let folder = (directory as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: folder) else { return nil }
            result = await ChildProcess.run("/bin/sh", ["-c", script, "botchu"], in: folder,
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LC_ALL": "C"], timeout: timeout)
        }
        guard result.ok, !result.timedOut else { return nil }
        return parse(result.output)
    }

    /// `git status --porcelain` and two tagged lines, as `script` prints them.
    public static func parse(_ output: String) -> SubagentWorkspaceState? {
        var state = SubagentWorkspaceState()
        var paths: [String] = []
        var count = 0
        var tagged = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("branch\t") {
                state.branch = SubagentInterruption.bounded(String(line.dropFirst(7)), 120)
                tagged = true
            } else if line.hasPrefix("head\t") {
                state.head = SubagentInterruption.bounded(String(line.dropFirst(5)), 120)
            } else if line.count > 3 {
                count += 1
                if paths.count < listed {
                    let path = String(line.dropFirst(3))
                    // A rename is listed as where it went.
                    paths.append(SubagentInterruption.bounded(path.components(separatedBy: " -> ").last ?? path, 200))
                }
            }
        }
        guard tagged else { return nil }
        if state.branch?.isEmpty == true { state.branch = nil }
        if state.head?.isEmpty == true { state.head = nil }
        state.uncommitted = paths
        state.uncommittedCount = count
        return state
    }

    static let script = """
        export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0
        git -c core.fsmonitor=false rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 3
        printf 'branch\\t%s\\n' "$(git -c core.fsmonitor=false branch --show-current 2>/dev/null)"
        printf 'head\\t%s\\n' "$(git -c core.fsmonitor=false log -1 --format='%h %s' 2>/dev/null)"
        git -c core.fsmonitor=false -c core.quotePath=false status --porcelain=v1 -uall 2>/dev/null | head -n 1000
        """
}
