import Foundation

/// The agent CLI behind an account. Each one has its own headless flags, session handling and
/// JSON stream (see `StreamParsers.swift`).
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, antigravity, muse, pi

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .muse: "Muse"
        case .pi: "Pi"
        }
    }
}

/// A signed-in CLI profile a bot can run on. The command is run through the login shell, so it may
/// start with `~` or be a bare name on the login PATH.
public struct Account: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: AgentKind
    public let defaultCommand: String
    /// The SF Symbol shown beside the account.
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

    public init(arguments: [String], environment: [String: String] = [:], sessionID: String? = nil, standardInput: Data? = nil) {
        self.arguments = arguments
        self.environment = environment
        self.sessionID = sessionID
        self.standardInput = standardInput
    }
}

public enum CommandBuilder {
    /// The arguments for one turn. `sessionID` is the session to resume, or nil to start one;
    /// `newID` makes the ids of sessions BotChu names itself (Claude, Muse, Pi) testable.
    public static func invocation(
        kind: AgentKind,
        prompt: String,
        model: String?,
        sessionID: String?,
        reasoningEffort: ReasoningEffort? = nil,
        openRouterKey: String? = nil,
        newID: () -> String = { UUID().uuidString.lowercased() }
    ) -> Invocation {
        // A prompt that starts with "-" would be read as an option.
        let prompt = prompt.hasPrefix("-") ? " " + prompt : prompt
        let model = model.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : GenerationOptions.modelArgument(trimmed, kind: kind, effort: reasoningEffort)
        }
        let effort = reasoningEffort.flatMap {
            GenerationOptions.efforts(for: kind, model: model ?? "").contains($0) ? $0.rawValue : nil
        }
        var args: [String] = []
        var env: [String: String] = [:]
        var session = sessionID

        switch kind {
        case .claude:
            args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--dangerously-skip-permissions"]
            if let sessionID {
                args += ["--resume", sessionID]
            } else {
                let id = newID()
                session = id
                args += ["--session-id", id]
            }
            if let model { args += ["--model", model] }
            if let effort { args += ["--effort", effort] }
            args.append(prompt)
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
        }
        return Invocation(arguments: args, environment: env, sessionID: session)
    }

    /// The id that resumes a run's session, once its stream reports one: Muse and Pi resume by the
    /// id BotChu gave them, the others by the id they report.
    public static func resumeID(kind: AgentKind, invocation: Invocation, reported: String) -> String {
        switch kind {
        case .muse, .pi: invocation.sessionID ?? reported
        case .claude, .codex, .antigravity: reported
        }
    }

    public static let defaultOpenRouterModel = "anthropic/claude-sonnet-4.5"

    /// The shell script `zsh -l -c` runs: the account's command, then the arguments as `"$@"`.
    public static func shellScript(command: String) -> String {
        "exec \(command) \"$@\""
    }
}
