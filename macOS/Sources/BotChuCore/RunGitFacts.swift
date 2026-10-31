import Foundation

/// Where a pull request stands, as a run's transcript last showed it.
public enum PullRequestState: String, Codable, Sendable, CaseIterable {
    case open, merged, closed
}

/// The worktree, branch and pull request a sub-agent run works on, read from the shell commands in
/// its own transcript (#401): `git worktree add`, `gh issue develop --name`, `gh pr create`,
/// `gh pr merge` and `gh pr close`, and else the newest pull request URL it printed.
///
/// Commands are read with `ShellCommand`, so a command quoted in a heredoc or a message is never
/// taken for one that ran. A call that failed (or never finished) counts only for what its output
/// confirms happened.
public struct RunGitFacts: Equatable, Sendable {
    /// Absolute when the transcript says where it is; `~` is left as is without a `home`.
    public var worktree: String?
    public var branch: String?
    public var pullRequest: Int?
    /// Nil for a pull request it only linked to.
    public var pullRequestState: PullRequestState?

    public init(worktree: String? = nil, branch: String? = nil, pullRequest: Int? = nil,
                pullRequestState: PullRequestState? = nil) {
        self.worktree = worktree
        self.branch = branch
        self.pullRequest = pullRequest
        self.pullRequestState = pullRequestState
    }

    public var isEmpty: Bool { self == RunGitFacts() }

    /// `checkout` is the folder the run's commands start in (its `workingDirectory`); `home`, when
    /// given, replaces a leading `~` in the worktree's path. `known` is what was found before in
    /// the messages that came earlier, such as a resumed run's: a `gh pr merge` without a number
    /// merges the pull request it already knows.
    public static func parse(_ messages: [ChatMessage], checkout: String, home: String? = nil,
                             known: RunGitFacts = RunGitFacts()) -> RunGitFacts {
        var facts = known
        var released = false
        for message in messages where message.role == .tool && ToolActivity.isShell(toolName: message.toolName ?? "") {
            facts.read(message, checkout: checkout, home: home, released: &released)
        }
        if facts.pullRequest == nil {
            facts.pullRequest = TaskNaming.pullRequest(in: messages.filter { $0.role == .tool || $0.role == .assistant }, repo: nil)
        }
        return facts
    }

    // MARK: Reading one call

    /// `released`: the run removed the worktree recorded, so the next one it makes is its own.
    private mutating func read(_ message: ChatMessage, checkout: String, home: String?, released: inout Bool) {
        let input = message.toolInput ?? ""
        let args = ToolArguments.parse(message.toolArguments) ?? (input.hasPrefix("{") ? ToolArguments.parse(input) : nil) ?? [:]
        // `toolArguments` shortens long strings, so the one-line input is the whole command when it isn't JSON.
        let line = input.hasPrefix("{") || input.isEmpty
            ? ToolActivity.string(args, ["command", "CommandLine", "cmd", "commandLine", "script"]) ?? input : input
        guard line.holds(any: ["worktree", "gh pr", "gh issue"]) else { return }
        let start = ToolActivity.string(args, ["Cwd", "cwd", "workdir", "directory", "working_directory"]).map { Self.join(checkout, $0) } ?? checkout
        let output = message.toolOutput ?? ""
        let succeeded = (message.toolState ?? .done) == .done && (message.toolExitCode ?? 0) == 0
        let prepared = Self.preparedBranches(in: output)
        var adds = 0
        for simple in ShellCommand(ToolActivity.unwrapped(line)).commands {
            var words = Array(simple.words.drop { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil })
            if words.first == "command" || words.first == "env" { words.removeFirst() }
            guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let directory = Self.join(start, simple.directory ?? ".")
            if program == "git" {
                if let removed = Self.worktreeRemove(Array(words.dropFirst()), in: directory) {
                    if succeeded, let worktree, Self.expand(removed, home: home) == worktree { released = true }
                    continue
                }
                guard var add = Self.worktreeAdd(Array(words.dropFirst()), in: directory) else { continue }
                // git says which branch it checked out; a failed call counts only for the worktrees it made.
                if adds < prepared.count { add.branch = prepared[adds] } else if !succeeded { continue }
                adds += 1
                // A name the shell would work out (`-b "$branch"`) isn't one.
                if let branch = add.branch, !TaskNaming.isValidBranch(branch) { add.branch = nil }
                record(worktree: add.path.map { Self.expand($0, home: home) }, branch: add.branch, released: &released)
            } else if program == "gh" {
                readGitHub(Array(words.dropFirst()), output: output, succeeded: succeeded)
            }
        }
    }

    /// The run's first worktree on a branch is its own until it removes it: one it adds after that
    /// is a fixture, a test merge or a review. A detached one counts only while it has no other.
    private mutating func record(worktree path: String?, branch: String?, released: inout Bool) {
        guard let path else {
            if worktree == nil, branch != nil { self.branch = branch }
            return
        }
        guard worktree == nil || (branch != nil && (released || self.branch == nil)) else { return }
        worktree = path
        self.branch = branch
        released = false
    }

    private mutating func readGitHub(_ words: [String], output: String, succeeded: Bool) {
        guard words.count >= 2 else { return }
        let rest = Array(words.dropFirst(2))
        switch (words[0], words[1]) {
        case ("issue", "develop"):
            guard let name = Self.value(of: ["--name", "-n"], in: rest), TaskNaming.isValidBranch(name) else { return }
            // A failed call made the branch when GitHub printed its URL.
            guard succeeded || output.contains("/tree/" + name) else { return }
            if worktree == nil { branch = name }
        case ("pr", "create"):
            guard let number = TaskNaming.pullRequests(in: output, repo: nil).last else { return }
            pullRequest = number
            pullRequestState = .open
        case ("pr", "merge"), ("pr", "close"):
            let merging = words[1] == "merge"
            guard succeeded, !(merging && (rest.contains("--auto") || rest.contains("--disable-auto"))) else { return }
            let withValues: Set<String> = ["-R", "--repo", "-b", "--body", "-F", "--body-file", "-t", "--subject", "-A",
                                           "--author-email", "--match-head-commit", "-c", "--comment"]
            let named = Self.positionals(rest, withValues: withValues).first.flatMap(Self.pullRequestNumber)
            let printed = Self.firstMatch("(?i)merged pull request [^\\s#]+#([0-9]+)", in: output).flatMap { Int($0) }
            guard let number = named ?? (merging ? printed : nil) ?? pullRequest else { return }
            pullRequest = number
            pullRequestState = merging ? .merged : .closed
        default:
            return
        }
    }

    // MARK: git worktree add

    struct WorktreeAdd: Equatable {
        /// Nil when the shell would work it out (`$(mktemp -d)/x`).
        var path: String?
        var branch: String?
    }

    /// The worktree `git [-C dir] worktree add …` makes (its arguments after `git`), seen from `directory`.
    static func worktreeAdd(_ words: [String], in directory: String) -> WorktreeAdd? {
        guard let (rest, directory) = worktreeArguments("add", words, in: directory) else { return nil }
        let detached = rest.contains("--detach") || rest.contains("-d")
        let created = value(of: ["-b", "-B"], in: rest)
        let positional = positionals(rest, withValues: ["-b", "-B", "--reason"])
        guard let given = positional.first else { return nil }
        let path = given.contains("$") || given.contains("`") || given.contains("*") ? nil : join(directory, given)
        var branch: String?
        if detached {
            branch = nil
        } else if let created {
            branch = created
        } else if positional.count > 1 {
            branch = branchName(positional[1])
        } else {
            // Without a commit, git makes a branch named after the folder.
            branch = path.map { ($0 as NSString).lastPathComponent }
        }
        return WorktreeAdd(path: path, branch: branch)
    }

    /// The worktree `git [-C dir] worktree remove …` removes, seen from `directory`.
    static func worktreeRemove(_ words: [String], in directory: String) -> String? {
        guard let (rest, directory) = worktreeArguments("remove", words, in: directory),
              let given = positionals(rest, withValues: []).first, !given.contains("$") else { return nil }
        return join(directory, given)
    }

    /// The arguments of `git [global options] worktree <subcommand> …`, and the folder `-C` moves to.
    private static func worktreeArguments(_ subcommand: String, _ words: [String], in directory: String) -> ([String], String)? {
        var directory = directory
        var index = 0
        while index < words.count, words[index].hasPrefix("-") {
            switch words[index] {
            case "-C":
                guard index + 1 < words.count else { return nil }
                directory = join(directory, words[index + 1])
                index += 2
            case "-c", "--git-dir", "--work-tree", "--namespace":
                index += 2
            default:
                index += 1
            }
        }
        guard index + 1 < words.count, words[index] == "worktree", words[index + 1] == subcommand else { return nil }
        return (Array(words[(index + 2)...]), directory)
    }

    /// The branch a commit-ish names, or nil for a commit, a remote branch or `HEAD`, which git
    /// checks out detached.
    static func branchName(_ commit: String) -> String? {
        if commit.hasPrefix("refs/heads/") { return String(commit.dropFirst("refs/heads/".count)) }
        let detached = commit.hasPrefix("refs/") || commit.hasPrefix("origin/") || commit.hasPrefix("upstream/")
            || commit.hasSuffix("HEAD") || commit.contains("~") || commit.contains("^") || commit.contains("@") || commit.contains("$")
            || commit.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil
        return detached ? nil : commit
    }

    /// `Preparing worktree (new branch 'x')` lines, in order: the branch, or nil for a detached one.
    static func preparedBranches(in output: String) -> [String?] {
        guard output.holds(any: ["Preparing worktree"]) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { line -> String?? in
            guard let range = line.range(of: "Preparing worktree (") else { return nil }
            let detail = line[range.upperBound...]
            if detail.hasPrefix("detached HEAD") { return .some(nil) }
            return .some(firstMatch("'([^']+)'", in: String(detail)))
        }
    }

    // MARK: Words

    /// The value after the first of `flags`, also in `--flag=value` form.
    static func value(of flags: Set<String>, in words: [String]) -> String? {
        for (index, word) in words.enumerated() {
            if flags.contains(word), index + 1 < words.count { return words[index + 1] }
            if let equals = word.firstIndex(of: "="), flags.contains(String(word[..<equals])) { return String(word[word.index(after: equals)...]) }
        }
        return nil
    }

    /// The words that aren't options or the values of `withValues` options.
    static func positionals(_ words: [String], withValues: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        var options = true
        while index < words.count {
            let word = words[index]
            if options, word == "--" {
                options = false
            } else if options, word.hasPrefix("-"), word.count > 1 {
                if withValues.contains(word) { index += 1 }
            } else {
                result.append(word)
            }
            index += 1
        }
        return result
    }

    static func pullRequestNumber(_ word: String) -> Int? {
        Int(word.hasPrefix("#") ? String(word.dropFirst()) : word) ?? TaskNaming.pullRequests(in: word, repo: nil).first
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Paths

    /// `path` from `directory`, without `.` and `..` parts or a trailing slash.
    static func join(_ directory: String, _ path: String) -> String {
        normalized(ShellPaths.join(directory, path))
    }

    static func normalized(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != "..", last != "~" { parts.removeLast(); continue }
            parts.append(part)
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined.isEmpty ? "." : joined
    }

    static func expand(_ path: String, home: String?) -> String {
        guard let home, path == "~" || path.hasPrefix("~/") else { return path }
        return normalized(home + path.dropFirst())
    }
}

extension String {
    /// Whether it holds any of the parts, compared byte by byte: quick on long tool output, where
    /// `contains` is slow.
    func holds(any parts: [String]) -> Bool {
        var text = self
        return text.withUTF8 { haystack in
            parts.contains { part in
                part.utf8.withContiguousStorageIfAvailable { needle in
                    memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
                } ?? false
            }
        }
    }
}

extension SubagentRun {
    public var gitFacts: RunGitFacts {
        RunGitFacts(worktree: worktree, branch: branch, pullRequest: pullRequest, pullRequestState: pullRequestState)
    }

    /// Takes in what its own transcript shows now, on top of what it recorded before: a resumed
    /// run's messages can start partway, after the calls that made its worktree.
    public mutating func recordGitFacts(from messages: [ChatMessage], home: String? = nil) {
        let found = RunGitFacts.parse(messages, checkout: workingDirectory, home: home, known: gitFacts)
        worktree = found.worktree
        branch = found.branch
        pullRequest = found.pullRequest
        pullRequestState = found.pullRequestState
    }
}
