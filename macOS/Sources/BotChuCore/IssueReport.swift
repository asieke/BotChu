import Foundation

/// A bug report or feature request filed from inside BotChu: an issue in BotChu's own repository,
/// made with `gh issue create` as gh is signed in, with a snapshot of the app (`IssueSnapshot`).
/// The repository is public, and so is everything filed there.
public enum IssueReport {
    /// Where reports go.
    public static let repository = "asieke/BotChu"
    public static let issuesURL = URL(string: "https://github.com/\(repository)/issues")!
    /// A title longer than this is cut at a word.
    public static let titleLimit = 72
    /// GitHub refuses a longer description.
    public static let bodyLimit = 65_536
    static let fallbackTitle = "Report from BotChu"

    /// A short title from the report: its first line without Markdown's leading marks, or that
    /// line's first sentence when the line is long, cut at a word (with "…") when still too long.
    public static func title(from report: String) -> String {
        var title = report.split(whereSeparator: \.isNewline).lazy.map { plain(String($0)) }.first { !$0.isEmpty } ?? ""
        if title.count > titleLimit, let sentence = firstSentence(of: title) { title = sentence }
        if title.count > titleLimit { title = cut(title, to: titleLimit) }
        title = trimmingTrailing(title)
        return title.isEmpty ? fallbackTitle : title
    }

    /// The issue's description: the report as written, then the app's state.
    public static func body(report: String, snapshot: IssueSnapshot) -> String {
        report.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n### App state\n\n"
            + snapshot.lines.map { "- " + $0 }.joined(separator: "\n")
            + "\n\n_Filed from BotChu. The app state holds categories and counts only: no conversations, instructions, memory, paths or names._\n"
    }

    /// `gh issue create` in BotChu's repository, with the body on standard input. The title is
    /// one `--title=…` word, so a title that starts with `-` is never read as an option.
    public static func arguments(title: String) -> [String] {
        ["gh", "issue", "create", "--repo", repository, "--title=" + title, "--body-file", "-"]
    }

    /// The new issue's address in what `gh issue create` printed, rebuilt from its number.
    public static func issueURL(in output: String) -> URL? {
        let pattern = #"https?://github\.com/"# + NSRegularExpression.escapedPattern(for: repository) + #"/issues/([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let range = Range(match.range(at: 1), in: output), let number = Int(output[range]) else { return nil }
        return URL(string: "https://github.com/\(repository)/issues/\(number)")
    }

    /// The issue's number, from its address.
    public static func number(of url: URL) -> Int? { Int(url.lastPathComponent) }

    /// What a run of `gh issue create` came to: the issue, or why there is none in gh's own words
    /// (the last lines it printed), or how to get gh when it couldn't be run.
    static func outcome(of result: Shell.Result) -> IssueFiler.Outcome {
        if result.ok { return .filed(issueURL(in: result.output)) }
        if result.status == 127 {
            return .failed("BotChu couldn't run gh, the GitHub CLI. Install it and sign in with gh auth login in Terminal, then try again.")
        }
        let printed = result.errors.contains(where: { !$0.isWhitespace }) ? result.errors : result.output
        let lines = printed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .failed("gh couldn't create the issue (exit status \(result.status)).") }
        return .failed("gh couldn't create the issue:\n" + masked(lines.suffix(6).joined(separator: "\n")))
    }

    /// The text with anything shaped like a GitHub token hidden, before it is shown.
    static func masked(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b(gh[opusr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})"#, with: "[token hidden]",
                                  options: .regularExpression)
    }

    /// A line as plain words: whitespace collapsed, without a heading's, quote's, list item's or
    /// task box's leading marks, or bold's asterisks.
    static func plain(_ line: String) -> String {
        var text = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let marks = [#"^#{1,6} "#, #"^> ?"#, #"^[-*+] "#, #"^[0-9]{1,3}[.)] "#, #"^\[[ xX]\] "#]
        var stripped = true
        while stripped {
            stripped = false
            for mark in marks {
                if let range = text.range(of: mark, options: .regularExpression) {
                    text.removeSubrange(range)
                    stripped = true
                }
            }
        }
        return text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The line up to the end of its first sentence that has at least `minimum` characters (shorter
    /// ones, like "Bug!", run on into the next), or nil when no sentence ends.
    static func firstSentence(of line: String, minimum: Int = 20) -> String? {
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            if ".!?".contains(line[index]), next == line.endIndex || line[next] == " " {
                let sentence = String(line[...index])
                if sentence.count >= minimum { return sentence }
            }
            index = next
        }
        return nil
    }

    /// The text cut to `limit` characters with "…", at a word unless that loses over half of it.
    static func cut(_ text: String, to limit: Int) -> String {
        let head = String(text.prefix(limit - 1))
        var end = head.endIndex
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= limit / 2 { end = space }
        return trimmingTrailing(String(head[..<end])) + "…"
    }

    /// Without trailing spaces and the punctuation a title doesn't end with (a question or
    /// exclamation mark stays).
    static func trimmingTrailing(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace || ".,;:-–—".contains(last) { text.removeLast() }
        return text
    }
}

/// Files reports with `gh issue create`, run through the login shell like every gh command BotChu
/// runs (`Shell`), never prompting, with the body on standard input.
public struct IssueFiler: Sendable {
    /// What filing came to.
    public enum Outcome: Equatable, Sendable {
        /// The new issue's address; nil when gh made it without printing one.
        case filed(URL?)
        /// Why it wasn't filed, for the owner to read. The report stays, to try again.
        case failed(String)
    }

    /// Files a title and body.
    public typealias File = @Sendable (_ title: String, _ body: String) async -> Outcome

    private let file: File

    /// Files with `gh` as the login shell finds it, or with the program at a path in its place: a
    /// stand-in, in tests and throwaway runs (`macOS/ui-review.sh`), so they never file a real issue.
    public init(gh: String = "gh") {
        file = { title, body in
            let arguments = [gh] + IssueReport.arguments(title: title).dropFirst()
            return IssueReport.outcome(of: await Shell.run(arguments, in: NSHomeDirectory(), input: Data(body.utf8)))
        }
    }

    public init(_ file: @escaping File) {
        self.file = file
    }

    /// Files the report, titled from its first line, with the snapshot.
    public func file(_ report: String, snapshot: IssueSnapshot) async -> Outcome {
        let report = report.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !report.isEmpty else { return .failed("Write the report first.") }
        let body = IssueReport.body(report: report, snapshot: snapshot)
        guard body.count <= IssueReport.bodyLimit else {
            return .failed("This report is too long for a GitHub issue, which holds \(IssueReport.bodyLimit.formatted()) characters with the app state. Shorten it, then try again.")
        }
        return await file(IssueReport.title(from: report), body)
    }
}

/// What BotChu was doing when a report was filed, as the public issue lists it: the version and
/// system, the screen, and for a conversation what kind it is, the CLI family it runs on and how its
/// turn is going. Everything is a category or a count, taken from typed values. Messages,
/// instructions, memory, soul, prompts, tool calls, error text, paths, session ids, model ids
/// typed by hand, and the names of bots, tasks, accounts, hosts and repositories are never read
/// into it.
public struct IssueSnapshot: Equatable, Sendable {
    /// "Label: value", in the order the issue lists them.
    public let lines: [String]

    /// What the window shows.
    public enum Screen: Equatable, Sendable {
        case projects, agents, providers
        /// A bot's Home or one of its tasks, with the status sidebar's area as its tab names it, or
        /// nil while the status sidebar is hidden.
        case conversation(statusArea: String?)
        /// No bot to show.
        case noBot
    }

    /// The main window: its size in points, and whether it looks dark.
    public struct Window: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var dark: Bool

        public init(width: Double, height: Double, dark: Bool) {
            self.width = width
            self.height = height
            self.dark = dark
        }
    }

    /// - Parameters:
    ///   - info: the app's Info.plist, for its version (`version(info:)`).
    ///   - conversation: the conversation shown, if any.
    ///   - bots: how many bots there are; `runningTurns`, how many turns run across them.
    public init(info: [String: Any]?, system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                screen: Screen, conversation: Conversation? = nil, window: Window? = nil, bots: Int, runningTurns: Int) {
        var lines = ["Version: " + Self.version(info: info), "System: " + Self.system(system)]
        switch screen {
        case .projects: lines.append("Screen: Projects")
        case .agents: lines.append("Screen: Agents")
        case .providers: lines.append("Screen: Providers")
        case .conversation(let area): lines.append("Screen: conversation, " + (area.map { "status sidebar on \($0)" } ?? "status sidebar hidden"))
        case .noBot: lines.append("Screen: no bot selected")
        }
        lines += conversation?.lines ?? []
        if let window {
            lines.append("Window: \(Int(window.width.rounded())) × \(Int(window.height.rounded())) points, \(window.dark ? "dark" : "light") appearance")
        }
        lines.append("Bots: \(bots), " + (runningTurns > 0 ? "\(Self.count(runningTurns, "turn")) running" : "no turns running"))
        self.lines = lines
    }

    /// The conversation shown, reduced to what kind it is, what it runs on and how it's going.
    public struct Conversation: Equatable, Sendable {
        let lines: [String]

        /// - Parameters:
        ///   - settings: the bot (for its Home) or the task. Only its account's CLI family, whether
        ///     that account is built in or an added profile, a starter model's id, the reasoning
        ///     effort and whether its session continues are kept.
        ///   - task: the task, for a task's conversation: only whether it works here or on a host,
        ///     on what kind of work, who started it and whether its worktree was made are kept.
        ///   - status: how its turn is going; its error, if any, is kept as a kind (`errorKind`).
        ///   - openTasks: for a Home, its bot's open tasks.
        ///   - queued: messages waiting to send, and whether they wait for the owner.
        ///   - subagents: delegated runs under way.
        public init(settings: some RunSettings, task: BotTask?, status: BotStatus?, openTasks: Int = 0,
                    queued: Int = 0, queuePaused: Bool = false, subagents: Int = 0, now: Date = Date()) {
            var what: String
            if let task {
                what = "task " + (task.isRemote ? "on an SSH host" : "on this Mac") + ", "
                switch (task.work, task.review) {
                case (.some, .review?): what += "reviewing a pull request here only"
                case (.some, .comment?): what += "reviewing a pull request and posting the review"
                case (let work?, nil): what += work.isPullRequest ? "continuing a pull request" : "working on an issue"
                case (nil, _): what += "new work from a brief"
                }
                if task.origin == .home { what += ", started by its bot" }
                if task.folder == nil { what += ", no worktree yet" }
            } else {
                what = "Home" + (openTasks > 0 ? " with \(IssueSnapshot.count(openTasks, "open task"))" : "")
            }
            var counts: [String] = []
            if let status {
                counts.append("\(IssueSnapshot.count(status.messageCount, "message")), \(IssueSnapshot.count(status.toolCallCount, "tool call"))")
            }
            if queued > 0 { counts.append("\(IssueSnapshot.count(queued, "message")) waiting to send" + (queuePaused ? " (paused)" : "")) }
            if subagents > 0 { counts.append("\(IssueSnapshot.count(subagents, "sub-agent")) running") }

            let kind = settings.account.kind
            let family = kind.displayName + (kind == .pi ? " (OpenRouter)" : "")
                + (Accounts.all.contains { $0.id == settings.accountID } ? ", a built-in account" : ", an added profile")
            let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelText = model.isEmpty ? "the account's default"
                : GenerationOptions.models(for: kind).contains { $0.id == model } ? model : "a custom ID (left out)"

            lines = ["Conversation: " + ([what] + counts).joined(separator: "; "),
                     "Provider: \(family); model: \(modelText); effort: \(settings.reasoningEffort?.rawValue ?? "auto")",
                     "State: " + (status.map { Self.state($0, now: now) } ?? "unknown")]
        }

        static func state(_ status: BotStatus, now: Date) -> String {
            var state: String
            switch status.phase {
            case .idle: state = "idle"
            case .preparing: state = "preparing its turn"
            case .starting: state = "turn started, no output yet"
            case .working: state = "working (\(status.activity.rawValue))"
            case .failed: state = "last turn failed: " + IssueSnapshot.errorKind(status.lastError ?? "")
            }
            if status.phase.isActive, let start = status.runStartedAt {
                state += " for " + BotStatus.formatElapsed(from: start, to: now)
            }
            switch status.session {
            case .continuing: state += "; its next message continues its CLI session"
            case .startsNew(let accountChanged): state += "; its next message starts a new CLI session" + (accountChanged ? " (account changed)" : "")
            }
            return state
        }
    }

    /// BotChu's version from its Info.plist as `macOS/build.sh` writes it: the version, the build
    /// (its commit count) and the commit (`-dirty` when built with uncommitted changes). Anything
    /// else in those keys is left out; a build without a version, such as `swift run`, is a
    /// development build.
    static func version(info: [String: Any]?) -> String {
        func value(_ key: String, matching pattern: String) -> String? {
            guard let text = info?[key] as? String, text.range(of: pattern, options: .regularExpression) != nil else { return nil }
            return text
        }
        let commit = value("BotChuCommit", matching: #"^[0-9a-f]{7,40}(-dirty)?$"#).map { "commit \($0)" }
        guard let version = value("CFBundleShortVersionString", matching: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#) else {
            return "development build" + (commit.map { " (\($0))" } ?? "")
        }
        let details = [value("CFBundleVersion", matching: #"^[0-9]{1,9}$"#).map { "build \($0)" }, commit].compactMap { $0 }
        return details.isEmpty ? version : "\(version) (\(details.joined(separator: ", ")))"
    }

    static func system(_ version: OperatingSystemVersion) -> String {
        var text = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        #if arch(arm64)
        return text + ", Apple silicon"
        #else
        return text + ", Intel"
        #endif
    }

    /// A conversation's last error as a kind of failure, never its text, which can carry a CLI's
    /// output, paths and names. The kinds BotChu reports itself are known by how it words them;
    /// anything else came from the CLI.
    static func errorKind(_ text: String) -> String {
        let kinds: [(prefix: String, kind: String)] = [
            ("Couldn't make this task's worktree", "couldn't make the task's worktree"),
            ("Couldn't send images", "couldn't send the attached images"),
            ("Couldn't prepare delegation", "couldn't prepare sub-agents"),
            ("Couldn't prepare ", "couldn't prepare the bot's folder"),
            ("Couldn't start ", "couldn't start the CLI"),
            ("Couldn't reach ", "couldn't reach the host over SSH"),
            ("Couldn't save", "couldn't save"),
            ("Couldn't move ", "couldn't move the bot's folder"),
            ("Add your OpenRouter API key", "no OpenRouter key in Settings"),
            ("This task works on ", "its host isn't in Settings any more"),
        ]
        if let known = kinds.first(where: { text.hasPrefix($0.prefix) }) { return known.kind }
        if let range = text.range(of: #" exited with status -?[0-9]+"#, options: .regularExpression),
           let status = text[range].split(separator: " ").last {
            return "the CLI exited with status \(status)" + (text.contains("without replying") ? " without replying" : "")
        }
        return "an error from the CLI (its text is left out)"
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)" + (n == 1 ? "" : "s")
    }
}
