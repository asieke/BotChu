import Foundation

/// What a bot is doing, which picks its pet's animation.
public enum BotActivity: String, CaseIterable, Codable, Sendable {
    case idle, greeting, thinking, researching, browsing, coding, testing, working, done, failed

    /// The clips that show this activity, best first: its own (named after it), then a close one,
    /// then `idle`. A pet whose clip for an activity wasn't made shows the next.
    public var animations: [String] {
        let closest: [BotActivity] = switch self {
        case .browsing: [.researching]
        case .testing: [.coding]
        default: []
        }
        var names = [rawValue] + closest.map(\.rawValue)
        if self != .idle { names.append(BotActivity.idle.rawValue) }
        return names
    }

    /// Played once, then the pet goes back to idle.
    public var isOneShot: Bool { self == .greeting || self == .done }

    /// The first of this activity's animations that the pet has.
    public func animation(among available: Set<String>) -> String? {
        animations.first { available.contains($0) }
    }

    /// The activity a turn's event moves to, or nil when it leaves the activity as it is.
    public static func next(after event: AgentEvent) -> BotActivity? {
        switch event {
        case .textDelta, .text, .toolFinished: .thinking
        case let .toolStarted(_, name, input, _): classify(toolName: name, input: input)
        // A CLI waiting on its background tasks after its turn shows what they do (#255).
        case .backgroundTasks(let tasks): tasks.isEmpty ? nil : mostTelling(Set(tasks))
        case .session, .model, .textEnd, .failed, .finished, .inputTaken, .connectors: nil
        }
    }

    /// What a tool call is for, from its name and input. The CLIs name their tools differently
    /// (Claude `Read`/`Edit`/`Bash`, Codex `Shell`/`Edit files`/`Web search`, Antigravity
    /// `run_command`, Muse and Pi `bash`), so this goes by words in the name, and for shell
    /// commands by the command itself.
    public static func classify(toolName: String, input: String) -> BotActivity {
        let name = toolName.lowercased()
        if shellTools.contains(name) { return classify(command: input) }
        if name == "todowrite" || name == "todoread" || name.contains("plan") { return .thinking }
        if ["task", "agent", "invoke_subagent"].contains(name) { return .working }
        if ["web", "url", "browser", "fetch"].contains(where: name.contains) { return .browsing }
        if ["edit", "write", "patch", "replace", "create"].contains(where: name.contains) { return .coding }
        if ["read", "grep", "glob", "search", "list", "view", "find"].contains(where: name.contains) || name == "ls" {
            return .researching
        }
        return .working
    }

    static let shellTools: Set<String> = ["bash", "shell", "run_command", "run_shell_command", "exec_command", "command", "terminal"]

    /// What a shell command does. A command line with several commands takes the most telling one.
    public static func classify(command: String) -> BotActivity {
        let separators = CharacterSet(charactersIn: "&|;\n")
        let parts = command.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("cd ") && $0 != "cd" }
        return mostTelling(Set(parts.map(classifyOne)))
    }

    /// The most telling of several things being done at once.
    static func mostTelling(_ found: Set<BotActivity>) -> BotActivity {
        [BotActivity.testing, .coding, .browsing, .working, .researching].first(where: found.contains) ?? .working
    }

    static let readCommands: Set<String> = [
        "ls", "cat", "head", "tail", "find", "grep", "rg", "fd", "wc", "tree", "less", "more", "man", "file",
        "stat", "pwd", "which", "awk", "jq", "du", "nl", "sort", "uniq", "diff", "echo", "printf",
    ]

    static let testPattern = try! NSRegularExpression(pattern: [
        #"\b(tests?|pytest|jest|vitest|xcodebuild|tsc|eslint|swiftlint|lint|check\.sh|test\.sh)\b"#,
        #"\bswift (build|test)\b"#,
        #"\b(npm|pnpm|yarn|bun) (test|run (build|test|lint|check))\b"#,
        #"\bcargo (build|test|check|clippy)\b"#,
        #"\bgo (test|build|vet)\b"#,
        #"\bmake\b"#,
        #"\bgradle"#,
        #"\bmvn\b"#,
    ].joined(separator: "|"))

    private static func classifyOne(_ part: String) -> BotActivity {
        let lower = part.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return .working }
        let second = words.count > 1 ? words[1] : ""
        switch first {
        case "curl", "wget": return .browsing
        case "sed": return words.contains(where: { $0.hasPrefix("-i") }) ? .coding : .researching
        case "git":
            if ["log", "status", "diff", "show", "blame", "grep", "ls-files", "branch", "remote"].contains(second) { return .researching }
            if ["add", "commit", "apply", "mv", "rm", "restore"].contains(second) { return .coding }
        case "apply_patch", "patch", "tee", "touch", "mkdir", "cp", "mv": return .coding
        default:
            if readCommands.contains(first) {
                return lower.contains(" > ") || lower.contains(" >> ") || lower.contains("<<") ? .coding : .researching
            }
        }
        let range = NSRange(lower.startIndex..., in: lower)
        if testPattern.firstMatch(in: lower, range: range) != nil { return .testing }
        return .working
    }
}

public struct PetError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
