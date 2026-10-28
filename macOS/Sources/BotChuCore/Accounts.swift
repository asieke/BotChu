import Foundation

/// The agent CLI behind an account. Each one has its own headless flags, session handling and
/// JSON stream (see `StreamParsers.swift`). Sail's is BotChu's own helper (`SailCommand`).
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, antigravity, muse, pi, sail

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .muse: "Muse"
        case .pi: "Pi"
        case .sail: "Sail"
        }
    }

    /// The families an added CLI profile can be: Sail is BotChu's own helper, with one key in
    /// Settings, so it has its one account only.
    public static var profileFamilies: [AgentKind] { allCases.filter { $0 != .sail } }
}

/// A signed-in CLI profile a bot can run on. The command is run through the login shell, so it may
/// start with `~` or be a bare name on the login PATH.
public struct Account: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: AgentKind
    public let defaultCommand: String
    /// The SF Symbol earlier versions showed beside the account. The app now shows its CLI family's
    /// logo (`ProviderLogo`, by `kind`); this is still saved so profiles stay readable by them.
    public let symbol: String

    public init(id: String, name: String, kind: AgentKind, defaultCommand: String, symbol: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultCommand = defaultCommand
        self.symbol = symbol
    }
}

public enum Accounts {
    /// Every account BotChu offers, in the order the pickers show them. The Claude and Codex
    /// profiles are the `~/.local/bin` wrappers that give each login its own config directory.
    public static let all: [Account] = [
        Account(id: "claude-personal", name: "Claude Personal", kind: .claude, defaultCommand: "~/.local/bin/claude-personal", symbol: "sparkle"),
        Account(id: "claude-dev", name: "Claude Dev", kind: .claude, defaultCommand: "~/.local/bin/claude-dev", symbol: "sparkle"),
        Account(id: "claude-work", name: "Claude Work", kind: .claude, defaultCommand: "~/.local/bin/claude-work", symbol: "sparkle"),
        Account(id: "codex-personal", name: "Codex Personal", kind: .codex, defaultCommand: "~/.local/bin/codex-personal", symbol: "chevron.left.forwardslash.chevron.right"),
        Account(id: "codex-dev", name: "Codex Dev", kind: .codex, defaultCommand: "~/.local/bin/codex-dev", symbol: "chevron.left.forwardslash.chevron.right"),
        Account(id: "codex-work", name: "Codex Work", kind: .codex, defaultCommand: "~/.local/bin/codex-work", symbol: "chevron.left.forwardslash.chevron.right"),
        Account(id: "google", name: "Google (Antigravity)", kind: .antigravity, defaultCommand: "agy", symbol: "g.circle"),
        Account(id: "muse", name: "Muse", kind: .muse, defaultCommand: "~/.local/bin/muse", symbol: "m.circle"),
        Account(id: "openrouter", name: "OpenRouter", kind: .pi, defaultCommand: "~/.local/bin/pi", symbol: "arrow.triangle.branch"),
        // BotChu's own helper, built beside the app; Settings runs the copy there (`Sail.helperCommand`).
        Account(id: "sail", name: "Sail Research", kind: .sail, defaultCommand: Sail.helperName, symbol: "sailboat"),
    ]

    public static let defaultID = "claude-personal"

    public static func account(id: String) -> Account {
        all.first { $0.id == id } ?? all[0]
    }
}

/// One headless CLI run: the arguments after the account's command, extra environment, and the
/// session id when it is known before the run (otherwise the stream reports it).
public struct Invocation: Equatable, Sendable {
    public var arguments: [String]
    public var environment: [String: String]
    public var sessionID: String?
    public var standardInput: Data?

    /// For a CLI that takes input mid-turn, the lines written to its stdin when it starts (the
    /// prompt); its stdin then stays open for follow-ups until BotChu closes it. Nil runs the CLI
    /// with stdin closed and the prompt among its arguments.
    public var input: [String]?

    public init(arguments: [String], environment: [String: String] = [:], sessionID: String? = nil, input: [String]? = nil, standardInput: Data? = nil) {
        self.arguments = arguments
        self.environment = environment
        self.sessionID = sessionID
        self.input = input
        self.standardInput = standardInput
    }
}

public enum CommandBuilder {
    /// Whether the CLI takes a follow-up while a turn runs, once its current step ends (after the
    /// running tool call returns): Claude Code, with `--input-format stream-json`. The others hear follow-ups as the next turn, once the
    /// running one ends (see README.md, Queued messages).
    public static func takesInputMidTurn(_ kind: AgentKind) -> Bool { kind == .claude }

    /// One user message for the stdin of a CLI that takes input mid-turn, or nil for the others.
    public static func inputLine(kind: AgentKind, text: String) -> String? {
        guard takesInputMidTurn(kind) else { return nil }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The arguments for one turn. `sessionID` is the session to resume, or nil to start one;
    /// `newID` makes the ids of sessions BotChu names itself (Claude, Muse, Pi, Sail) testable.
    /// `liveInput` gives a CLI that takes input mid-turn its prompt on stdin, which stays open.
    /// `openRouterKey` and `sailKey` reach only Pi and Sail, through their environment.
    public static func invocation(
        kind: AgentKind,
        prompt: String,
        model: String?,
        sessionID: String?,
        reasoningEffort: ReasoningEffort? = nil,
        openRouterKey: String? = nil,
        sailKey: String? = nil,
        liveInput: Bool = false,
        newID: () -> String = { UUID().uuidString.lowercased() }
    ) -> Invocation {
        let input = liveInput ? inputLine(kind: kind, text: prompt).map { [$0] } : nil
        let prompt = argument(prompt)
        let (model, effort) = generation(kind: kind, model: model, reasoningEffort: reasoningEffort)
        var args: [String] = []
        var env: [String: String] = [:]
        var session = sessionID

        switch kind {
        case .claude:
            args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--dangerously-skip-permissions"]
            // Each message Claude Code takes from stdin is echoed back, so BotChu knows when it did.
            if input != nil { args += ["--input-format", "stream-json", "--replay-user-messages"] }
            if let sessionID {
                args += ["--resume", sessionID]
            } else {
                let id = newID()
                session = id
                args += ["--session-id", id]
            }
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
            if input == nil { args.append(prompt) }
        case .codex:
            args = ["exec"]
            if let sessionID { args += ["resume", sessionID] }
            args += ["--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"]
            if let model { args += ["-m", model] }
            if let effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            args.append(prompt)
        case .antigravity:
            args = ["-p", prompt, "--output-format", "stream-json", "--dangerously-skip-permissions"]
            if let sessionID { args += ["--conversation", sessionID] }
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
        case .muse:
            let id = sessionID ?? newID()
            session = id
            args = ["exec", "--json", "--session-id", id]
            if let model { args += ["--model", model] }
            if let effort { args += ["--reasoning-effort", effort] }
            args.append(prompt)
        case .pi:
            let id = sessionID ?? newID()
            session = id
            args = ["-p", "--mode", "json", "--session-id", id, "--provider", "openrouter",
                    "--model", model ?? defaultOpenRouterModel]
            if let effort { args += ["--thinking", effort] }
            args.append(prompt)
            if let openRouterKey, !openRouterKey.isEmpty { env["OPENROUTER_API_KEY"] = openRouterKey }
        case .sail:
            // `--resume` asks for the session saved before; a new one is made only on the first turn.
            let id = sessionID ?? newID()
            session = id
            args = ["--session-id", id]
            if sessionID != nil { args.append("--resume") }
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
            args.append(prompt)
            if let sailKey, !sailKey.isEmpty { env[Sail.keyVariable] = sailKey }
        }
        return Invocation(arguments: args, environment: env, sessionID: session, input: input)
    }

    /// A prompt as an argument: one that starts with "-" would be read as an option.
    private static func argument(_ prompt: String) -> String {
        prompt.hasPrefix("-") ? " " + prompt : prompt
    }

    /// The model as the CLI names it, and an effort the CLI and that model take, when chosen.
    private static func generation(kind: AgentKind, model: String?, reasoningEffort: ReasoningEffort?) -> (model: String?, effort: String?) {
        let model = model.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : GenerationOptions.modelArgument(trimmed, kind: kind, effort: reasoningEffort)
        }
        let effort = reasoningEffort.flatMap {
            GenerationOptions.efforts(for: kind, model: model ?? "").contains($0) ? $0.rawValue : nil
        }
        return (model, effort)
    }

    /// Whether the CLI can run a session with no tools, enforced by the CLI itself rather than asked
    /// of the model, as run reviews need (`toolFreeInvocation`). Antigravity has no such mode. Pi has
    /// `--no-tools`, but no real run has checked it yet, so reviews skip it as well.
    public static func runsToolFree(_ kind: AgentKind) -> Bool {
        switch kind {
        case .claude, .codex, .muse: true
        case .antigravity, .pi, .sail: false
        }
    }

    /// The Codex features a tool-free session turns off: running commands (the shell, unified exec
    /// and code mode, which reaches the patch tool), sub-agents, apps and plugins, the browser and
    /// computer use, images, goals, sleeping, tool suggestions, skills and hooks.
    static let codexToolFeatures = ["shell_tool", "unified_exec", "code_mode", "code_mode_host", "multi_agent", "multi_agent_v2",
                                    "apps", "plugins", "browser_use", "computer_use", "image_generation", "view_image", "goals",
                                    "sleep_tool", "tool_suggest", "skill_search", "hooks"]

    /// One headless turn in a new session that has no tools, for a run review; nil for a CLI without
    /// such a mode (`runsToolFree`). Nothing bypasses permissions, and no session is saved. Claude
    /// Code has no built-in tools (`--tools ""`), every tool denied, no MCP servers, skills or
    /// commands, and asks nobody (`dontAsk`). Codex runs in its read-only sandbox approving nothing,
    /// without the user's configuration (its MCP servers and plugins) or rules, with web search and
    /// `codexToolFeatures` off. Muse runs its empty preset, with the shell, writes, web tools,
    /// questions and reminder agents off.
    public static func toolFreeInvocation(kind: AgentKind, prompt: String, model: String?, reasoningEffort: ReasoningEffort? = nil,
                                          newID: () -> String = { UUID().uuidString.lowercased() }) -> Invocation? {
        let prompt = argument(prompt)
        let (model, effort) = generation(kind: kind, model: model, reasoningEffort: reasoningEffort)
        var args: [String]
        var session: String?
        switch kind {
        case .claude:
            // `--tools` and `--disallowedTools` take several values: an option must follow each.
            let id = newID()
            session = id
            args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--disallowedTools", "*", "--strict-mcp-config", "--disable-slash-commands",
                    "--permission-mode", "dontAsk", "--no-session-persistence", "--session-id", id]
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
        case .codex:
            args = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "approval_policy=\"never\"",
                    "-c", "web_search=\"disabled\"", "--ephemeral", "--ignore-user-config", "--ignore-rules"]
            args += codexToolFeatures.flatMap { ["--disable", $0] }
            if let model { args += ["-m", model] }
            if let effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        case .muse:
            // Without a session id, which Muse refuses without a saved session log.
            args = ["exec", "--json", "--preset", "empty", "--disable-shell", "--disable-write",
                    "--disable-web-tools", "--disable-request-user-input", "--disable-reminders", "--no-session-log"]
            if let model { args += ["--model", model] }
            if let effort { args += ["--reasoning-effort", effort] }
        case .antigravity, .pi, .sail:
            return nil
        }
        args.append(prompt)
        return Invocation(arguments: args, sessionID: session)
    }

    /// Whether an error a tool-free session reports is only its CLI saying that a tool is off, as
    /// asked, while the turn goes on: Codex reports its code mode turned off as an error item.
    public static func isToolFreeNotice(_ message: String, kind: AgentKind) -> Bool {
        kind == .codex && message.localizedCaseInsensitiveContains("code-mode host is disabled")
    }

    /// The id that resumes a run's session, once its stream reports one: Muse, Pi and Sail resume
    /// by the id BotChu gave them, the others by the id they report.
    public static func resumeID(kind: AgentKind, invocation: Invocation, reported: String) -> String {
        switch kind {
        case .muse, .pi, .sail: invocation.sessionID ?? reported
        case .claude, .codex, .antigravity: reported
        }
    }

    public static let defaultOpenRouterModel = "anthropic/claude-sonnet-4.5"

    /// The shell script `zsh -l -c` runs: the account's command, then the arguments as `"$@"`.
    public static func shellScript(command: String) -> String {
        "exec \(command) \"$@\""
    }
}
