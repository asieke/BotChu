import Foundation

/// The lines a turn adds to its bot's log (`.botchu/logs/<date>.log`): what ran, then how it ended,
/// with the CLI's error output. The prompt itself is in the thread, so the log gives only its length,
/// and no environment variable (the OpenRouter key among them) is ever written.
public enum TurnLog {
    /// `what` names the run: a chat `turn`, or another job such as `pet drawing`. `directory` is
    /// where it runs, when that isn't the bot's own folder (a task's worktree).
    public static func started(at date: Date, account: Account, command: String, arguments: [String],
                               prompt: String, resuming sessionID: String?, what: String = "turn", directory: String? = nil) -> String {
        let shown = arguments.map { argument in
            argument == prompt || argument == " " + prompt ? "<prompt: \(prompt.count) characters>" : quoted(argument)
        }
        let session = sessionID.map { "resumes \($0)" } ?? "new session"
        return "── \(timestamp(date)) · \(what) started · \(account.name) · \(session)\n"
            + (directory.map { "   in \($0)\n" } ?? "")
            + "   \(command) \(shown.joined(separator: " "))\n"
    }

    public static func ended(at date: Date, startedAt: Date, status: Int32, stopped: Bool, toolCalls: Int,
                             error: String?, stderr: String, what: String = "turn") -> String {
        let seconds = String(format: "%.1f", date.timeIntervalSince(startedAt))
        let outcome = stopped ? "stopped" : error == nil ? "finished" : "failed"
        var text = "── \(timestamp(date)) · \(what) \(outcome) in \(seconds) s · exit \(status) · "
            + "\(toolCalls) tool call\(toolCalls == 1 ? "" : "s")\n"
        if let error { text += indented("error", error) }
        let stderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { text += indented("stderr", stderr) }
        return text + "\n"
    }

    static func indented(_ label: String, _ text: String) -> String {
        "   \(label):\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "   | \($0)" }.joined(separator: "\n") + "\n"
    }

    static func quoted(_ argument: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@,+%~"))
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(plain.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
