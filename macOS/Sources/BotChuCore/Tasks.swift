import Foundation

/// Work a bot does in one repository, beside its other tasks and its own conversation (its Home):
/// a conversation and CLI session of its own, run in a worktree of the repository's checkout on
/// this Mac, so parallel tasks never share files. Kept in `.botchu/tasks/<id>/` in the bot's folder;
/// the repository gets nothing of BotChu's.
public struct BotTask: Identifiable, Codable, Hashable, Sendable, RunSettings {
    /// The issue or pull request a task works on.
    public struct Work: Codable, Hashable, Sendable {
        public var number: Int
        /// Empty until BotChu has looked it up on GitHub.
        public var title: String
        public var url: URL
        public var isPullRequest: Bool

        public init(number: Int, title: String = "", url: URL, isPullRequest: Bool) {
            self.number = number
            self.title = title
            self.url = url
            self.isPullRequest = isPullRequest
        }

        /// Its page on GitHub, before BotChu has looked it up.
        public init(number: Int, isPullRequest: Bool, repo: String) {
            let kind = isPullRequest ? "pull" : "issues"
            self.init(number: number, url: URL(string: "https://github.com/\(repo)/\(kind)/\(number)")!, isPullRequest: isPullRequest)
        }

        /// "issue #48 “Add a filter bar”", as a sentence names it.
        public var reference: String {
            "\(isPullRequest ? "pull request" : "issue") #\(number)" + (title.isEmpty ? "" : " “\(title)”")
        }
    }

    /// Who started the task: the owner (New Task), or the bot itself, from its Home conversation.
    public enum Origin: String, Codable, Sendable {
        case owner, home
    }

    /// A review of the task's pull request, in a worktree detached at its head: in the
    /// conversation only (`review`), or also posted on GitHub as one review (`comment`, the
    /// workspace standard's "Review and comment on this PR").
    public enum Review: String, Codable, Sendable {
        case review, comment
    }

    public var id: UUID
    /// The tab's title, such as "GitChu #48".
    public var title: String
    /// `owner/name` on GitHub, or the checkout's folder name when its origin isn't on GitHub.
    public var repo: String
    /// The repository's main checkout, which stays on its default branch, on the task's machine.
    public var checkout: String
    /// The host the task works on, over SSH; nil for this Mac. A task stays on its machine.
    public var hostID: UUID?
    /// The host's nickname when the task started, shown if it leaves Settings.
    public var hostName: String?
    /// Empty until BotChu names it, from the issue's title or the brief.
    public var branch: String
    /// The task's worktree, where its CLI runs; nil until BotChu has made it.
    public var folder: String?
    public var work: Work?
    /// What to do, in the words of whoever started the task. May be empty when an issue or pull
    /// request says it all.
    public var brief: String
    public var origin: Origin
    public var accountID: String
    public var model: String
    public var reasoningEffort: ReasoningEffort?
    public var sessionID: String?
    public var sessionAccountID: String?
    public var createdAt: Date
    /// When its tab was closed. Its record and conversation stay, and it can be opened again.
    public var archivedAt: Date?
    /// The pull request the task opened (or works on), once its conversation has linked to it.
    public var pullRequest: Int?
    /// Set for a review of the task's pull request, which works in a detached worktree.
    public var review: Review?
    /// The commit a review's worktree is detached at.
    public var head: String?

    public init(
        id: UUID = UUID(), title: String? = nil, repo: String, checkout: String, branch: String = "", folder: String? = nil,
        work: Work? = nil, brief: String = "", origin: Origin = .owner, accountID: String = Accounts.defaultID,
        model: String = "", reasoningEffort: ReasoningEffort? = nil, sessionID: String? = nil, sessionAccountID: String? = nil,
        createdAt: Date = Date(), archivedAt: Date? = nil, pullRequest: Int? = nil, hostID: UUID? = nil, hostName: String? = nil,
        review: Review? = nil
    ) {
        self.id = id
        self.title = title ?? TaskNaming.title(repo: repo, work: work, brief: brief, review: review != nil)
        self.repo = repo
        self.checkout = checkout
        self.hostID = hostID
        self.hostName = hostName
        self.review = review
        self.branch = branch
        self.folder = folder
        self.work = work
        self.brief = brief
        self.origin = origin
        self.accountID = accountID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.sessionID = sessionID
        self.sessionAccountID = sessionAccountID
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.pullRequest = pullRequest ?? (work?.isPullRequest == true ? work?.number : nil)
    }

    /// A new task for `bot`, on the bot's account, model and effort, in the repository's checkout on
    /// this Mac or a host.
    public init(for bot: Bot, repo: String, checkout: String, work: Work?, brief: String, branch: String = "",
                title: String? = nil, origin: Origin = .owner, host: SSHHost? = nil, review: Review? = nil) {
        self.init(title: title, repo: repo, checkout: checkout, branch: branch, work: work, brief: brief, origin: origin,
                  accountID: bot.accountID, model: bot.model, reasoningEffort: bot.reasoningEffort,
                  hostID: host?.id, hostName: host?.nickname, review: review)
    }

    public var isRemote: Bool { hostID != nil }

    public var isArchived: Bool { archivedAt != nil }

    /// The repository's name without its owner.
    public var repoName: String { TaskNaming.repoName(repo) }

    /// The task's pull request on GitHub, when its repository is on GitHub.
    public var pullRequestURL: URL? {
        guard let pullRequest, repo.contains("/") else { return nil }
        return URL(string: "https://github.com/\(repo)/pull/\(pullRequest)")
    }

    /// The first message of the task's conversation, when the person (or bot) starting it wrote no
    /// brief: the issue or pull request.
    public var opening: String {
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !brief.isEmpty { return brief }
        guard let work else { return "Start." }
        switch review {
        case .review: return "Review \(work.reference)."
        case .comment: return "Review and comment on \(work.reference)."
        case nil: return work.isPullRequest ? "Continue \(work.reference)." : "Work on \(work.reference)."
        }
    }
}

/// How tasks and their branches are named.
public enum TaskNaming {
    public static func repoName(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    /// "GitChu #48" for an issue or a pull request ("GitChu #12 review" for a review), else the
    /// repository and the brief's first words: "GitChu · Speed up the sync".
    public static func title(repo: String, work: BotTask.Work?, brief: String, review: Bool = false) -> String {
        let name = repoName(repo)
        if let work { return "\(name) #\(work.number)" + (review ? " review" : "") }
        let words = shortened(brief, limit: 28)
        return words.isEmpty ? name : "\(name) · \(words)"
    }

    /// The text's first line, cut at a word to at most `limit` characters, with "…" when cut.
    public static func shortened(_ text: String, limit: Int) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        guard line.count > limit else { return line }
        var out = ""
        for word in line.split(separator: " ") {
            guard out.count + word.count + (out.isEmpty ? 0 : 1) <= limit - 1 else { break }
            out += (out.isEmpty ? "" : " ") + word
        }
        return (out.isEmpty ? String(line.prefix(limit - 1)) : out) + "…"
    }

    /// `feat/<number>-<slug>` for an issue, `feat/<slug>` for a brief: up to four plain words, in
    /// ASCII letters and digits (accents dropped), at most 50 characters, as the workspace standard's
    /// `scripts/worktree.sh` insists. A brief's slug never starts with a number, which the script
    /// would take for an issue's. `fallback` names a branch whose text has no usable words.
    public static func branch(issue: Int?, text: String, fallback: String) -> String {
        let stop: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "it", "its", "is",
                                 "as", "at", "by", "from", "into", "please", "this", "that"]
        let words = text.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }
            .drop { issue == nil && $0.allSatisfy(\.isNumber) }
            .prefix(4)
        let base = issue.map { "feat/\($0)" } ?? "feat"
        var branch = base
        for word in words where branch.count + 1 + word.count <= 50 {
            branch += branch == "feat" ? "/\(word)" : "-\(word)"
        }
        if branch == base { branch += issue == nil ? "/\(fallback)" : "-issue" }
        return branch
    }

    /// The branch with `-<n>` added, for a name that is taken, its slug shortened to stay within 50
    /// characters.
    public static func numbered(_ branch: String, _ n: Int) -> String {
        let suffix = "-\(n)"
        var base = branch
        while base.count + suffix.count > 50, base.last != "/" { base.removeLast() }
        while base.hasSuffix("-") { base.removeLast() }
        return base + suffix
    }

    /// Whether the workspace standard's `scripts/worktree.sh` takes the branch:
    /// `<feat|fix|chore|docs>/<slug>` in lowercase letters, digits and hyphens, at most 50 characters.
    public static func isStandardBranch(_ branch: String) -> Bool {
        branch.count <= 50 && branch.range(of: "^(feat|fix|chore|docs)/[a-z0-9-]+$", options: .regularExpression) != nil
    }

    /// Whether git takes the name for a branch, roughly (`git check-ref-format` has the last word).
    public static func isValidBranch(_ branch: String) -> Bool {
        !branch.isEmpty && branch.count <= 200 && !branch.hasPrefix("-") && !branch.hasPrefix("/") && !branch.hasSuffix("/")
            && !branch.hasSuffix(".") && !branch.hasSuffix(".lock") && !branch.contains("..") && !branch.contains("//")
            && !branch.contains("@{") && branch.range(of: "^[A-Za-z0-9._/+-]+$", options: .regularExpression) != nil
    }

    /// The newest pull request of the task's repository its conversation links to, as agents print
    /// its URL when they open one; else the one the task has (the one it works on, or found before).
    public static func pullRequest(in messages: [ChatMessage], task: BotTask) -> Int? {
        let pattern = "https://github\\.com/" + NSRegularExpression.escapedPattern(for: task.repo) + "/pull/([0-9]+)"
        if task.repo.contains("/"), let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            for message in messages.reversed() {
                let text = [message.text, message.toolOutput ?? ""].joined(separator: "\n")
                let range = NSRange(text.startIndex..., in: text)
                if let match = regex.matches(in: text, range: range).last,
                   let number = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }) {
                    return number
                }
            }
        }
        return task.pullRequest
    }
}

/// The notes BotChu leaves in a bot's Home thread about its tasks. Each names its task, so the next
/// Home turn can report on it (`BotContext.taskUpdates`).
public enum TaskReceipt {
    public static func started(_ task: BotTask) -> String {
        "Started \(task.title)" + (task.title.localizedCaseInsensitiveContains(task.repoName) ? "" : " in \(task.repo)")
            + (task.branch.isEmpty ? "" : " on \(task.branch)")
    }

    public static func finished(_ task: BotTask, pullRequest: Int?) -> String {
        "\(task.title) finished its turn" + (pullRequest.map { " · PR #\($0)" } ?? "")
    }

    public static func failed(_ task: BotTask, error: String) -> String {
        let line = error.split(separator: "\n").first.map(String.init) ?? error
        return "\(task.title) stopped with an error: \(TaskNaming.shortened(line, limit: 120))"
    }

    public static func couldNotStart(_ request: String, reason: String) -> String {
        "Couldn't start the task in \(request): \(reason)"
    }
}

/// A task a bot asks for from its Home conversation, by writing a JSON file into
/// `.botchu/dispatch/` in its folder: `{"repo": "asieke/GitChu", "issue": 48, "task": "…"}`.
public struct TaskRequest: Equatable, Sendable {
    /// `owner/name`, a repository's name alone, or its checkout's folder.
    public var repo: String
    public var issue: Int?
    public var pullRequest: Int?
    /// What to do, in the bot's words.
    public var task: String
    public var branch: String?
    public var title: String?
    /// The computer to work on, by its nickname in Settings ▸ Hosts (or "This Mac"); where the
    /// repository lives when not given.
    public var machine: String?
    /// For a pull request: review it instead of continuing it, posting the review on GitHub too
    /// when `.comment`.
    public var review: BotTask.Review?

    public init(repo: String, issue: Int? = nil, pullRequest: Int? = nil, task: String = "", branch: String? = nil, title: String? = nil,
                machine: String? = nil, review: BotTask.Review? = nil) {
        self.repo = repo
        self.issue = issue
        self.pullRequest = pullRequest
        self.task = task
        self.branch = branch
        self.title = title
        self.machine = machine
        self.review = review
    }

    public struct Problem: Error, Equatable, Sendable {
        public var message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// Reads a request file, forgivingly: numbers may be written as `48`, `"48"` or `"#48"`; `pr` and
    /// `pull_request` name a pull request, `brief` and `description` the task, `host` the machine.
    /// `"review": 12` asks for a review of pull request 12, and `"comment": true` posts it.
    public static func parse(_ data: Data) throws -> TaskRequest {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Problem(message: "it isn't a JSON object")
        }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = object[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        func number(_ keys: String...) throws -> Int? {
            for key in keys {
                guard let value = object[key], !(value is NSNull) else { continue }
                if let int = value as? Int, int > 0 { return int }
                if let text = value as? String, let int = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "# "))), int > 0 {
                    return int
                }
                throw Problem(message: "“\(key)” must be a number")
            }
            return nil
        }
        guard let repo = string("repo", "repository") else { throw Problem(message: "it names no “repo”") }
        let reviewed = try number("review")
        let pullRequest = try number("pullRequest", "pull_request", "pr")
        if reviewed != nil, pullRequest != nil, reviewed != pullRequest {
            throw Problem(message: "“review” and “pullRequest” name different pull requests")
        }
        let comment = (object["comment"] as? Bool) ?? false
        let request = TaskRequest(repo: repo, issue: try number("issue"), pullRequest: reviewed ?? pullRequest,
                                  task: string("task", "brief", "description", "prompt") ?? "",
                                  branch: string("branch"), title: string("title"), machine: string("machine", "host"),
                                  review: reviewed == nil ? nil : comment ? .comment : .review)
        if request.issue != nil, request.pullRequest != nil {
            throw Problem(message: "give an issue or a pull request, not both")
        }
        if request.issue == nil, request.pullRequest == nil, request.task.isEmpty {
            throw Problem(message: "it needs a “task”, an “issue” or a “pullRequest”")
        }
        if let branch = request.branch, !TaskNaming.isValidBranch(branch) {
            throw Problem(message: "“\(branch)” isn't a branch name git takes")
        }
        return request
    }
}
