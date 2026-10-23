import Foundation

/// An issue or pull request as its page on GitHub shows it, for the Projects sidebar: read with
/// `gh issue view` or `gh pr view`, as the owner signed gh in.
extension GitHubLookup {
    public struct WorkDetail: Equatable, Sendable {
        /// One check on a pull request's latest commit: a GitHub Actions job or a commit status.
        public struct Check: Equatable, Sendable {
            /// In the order the sidebar lists them: what needs attention first.
            public enum State: Int, Comparable, Sendable {
                case failure, pending, success, skipped
                public static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
            }

            public var name: String
            /// The workflow of a GitHub Actions job.
            public var workflow: String?
            public var state: State
            public var url: URL?

            public init(name: String, workflow: String? = nil, state: State, url: URL? = nil) {
                self.name = name; self.workflow = workflow; self.state = state; self.url = url
            }
        }

        /// A file the pull request changes.
        public struct File: Equatable, Sendable {
            public var path: String
            public var additions: Int
            public var deletions: Int

            public init(path: String, additions: Int, deletions: Int) {
                self.path = path; self.additions = additions; self.deletions = deletions
            }
        }

        /// A comment, or a review with its verdict.
        public struct Comment: Equatable, Sendable {
            public var author: String
            public var body: String
            public var date: Date
            /// A review's verdict (`APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`); nil for a comment.
            public var review: String?

            public init(author: String, body: String, date: Date, review: String? = nil) {
                self.author = author; self.body = body; self.date = date; self.review = review
            }
        }

        public var repo: String
        public var number: Int
        public var title: String
        /// The description as written, in Markdown; may be empty.
        public var body: String
        public var url: URL
        public var isPullRequest: Bool
        /// `OPEN`, `CLOSED` or `MERGED`.
        public var state: String
        public var author: String
        public var createdAt: Date
        public var updatedAt: Date
        public var labels: [OpenItem.Label]
        /// Comments and reviews, oldest first.
        public var conversation: [Comment]
        // A pull request's.
        public var isDraft: Bool
        public var head: String?
        public var base: String?
        public var fromFork: Bool
        public var additions: Int
        public var deletions: Int
        public var changedFiles: Int
        /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or nil.
        public var reviewDecision: String?
        /// What needs attention first, then by name.
        public var checks: [Check]
        public var files: [File]

        public init(repo: String, number: Int, title: String, body: String = "", url: URL, isPullRequest: Bool, state: String = "OPEN",
                    author: String, createdAt: Date, updatedAt: Date, labels: [OpenItem.Label] = [], conversation: [Comment] = [],
                    isDraft: Bool = false, head: String? = nil, base: String? = nil, fromFork: Bool = false, additions: Int = 0,
                    deletions: Int = 0, changedFiles: Int = 0, reviewDecision: String? = nil, checks: [Check] = [], files: [File] = []) {
            self.repo = repo; self.number = number; self.title = title; self.body = body; self.url = url
            self.isPullRequest = isPullRequest; self.state = state; self.author = author; self.createdAt = createdAt
            self.updatedAt = updatedAt; self.labels = labels; self.conversation = conversation; self.isDraft = isDraft
            self.head = head; self.base = base; self.fromFork = fromFork; self.additions = additions; self.deletions = deletions
            self.changedFiles = changedFiles; self.reviewDecision = reviewDecision; self.checks = checks; self.files = files
        }

        public var id: String { "\(repo)#\(number)" }
        public var work: BotTask.Work { BotTask.Work(number: number, title: title, url: url, isPullRequest: isPullRequest) }

        /// The description to show: without the HTML comments templates leave in it.
        public var shownBody: String { Self.shown(body) }

        /// The checks together, as the Projects tables show them.
        public var checksState: OpenItem.Checks {
            if checks.contains(where: { $0.state == .failure }) { return .failure }
            if checks.contains(where: { $0.state == .pending }) { return .pending }
            return checks.contains { $0.state == .success } ? .success : .none
        }

        /// "1 failing, 2 running, 12 passed, 3 skipped", or nil without checks.
        public var checksSummary: String? {
            guard !checks.isEmpty else { return nil }
            let words: [(Check.State, String)] = [(.failure, "failing"), (.pending, "running"), (.success, "passed"), (.skipped, "skipped")]
            return words.compactMap { state, word in
                let count = checks.filter { $0.state == state }.count
                return count == 0 ? nil : "\(count) \(word)"
            }.joined(separator: ", ")
        }

        /// Markdown from GitHub as the sidebar shows it: with Unix line ends, and no HTML comments.
        public static func shown(_ markdown: String) -> String {
            markdown.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static let issueDetailFields = "number,title,body,url,state,author,createdAt,updatedAt,labels,comments"
    static let pullRequestDetailFields = issueDetailFields
        + ",isDraft,headRefName,baseRefName,isCrossRepository,additions,deletions,changedFiles,files,reviews,reviewDecision,statusCheckRollup"

    /// Issue or pull request `number` of `repo` (`owner/name`), with its conversation.
    public static func detail(number: Int, pullRequest: Bool, repo: String) async -> Result<WorkDetail, TaskWorktree.Failure> {
        let args = ["gh", pullRequest ? "pr" : "issue", "view", String(number), "--repo", repo, "--json",
                    pullRequest ? pullRequestDetailFields : issueDetailFields]
        let run = await Shell.run(args, in: NSHomeDirectory())
        guard run.ok, let detail = parseDetail(run.output, repo: repo, pullRequest: pullRequest) else {
            let what = pullRequest ? "pull request" : "issue"
            return .failure(TaskWorktree.Failure(step: "Couldn't read \(what) #\(number) of \(repo) with gh", output: run.report("gh \(args[1]) view")))
        }
        return .success(detail)
    }

    /// What `gh issue view --json` (`issueDetailFields`) or `gh pr view --json` (`pullRequestDetailFields`)
    /// printed; nil when it isn't an issue or pull request.
    static func parseDetail(_ output: String, repo: String, pullRequest: Bool) -> WorkDetail? {
        guard let object = json(output) as? [String: Any], let number = object["number"] as? Int,
              let url = (object["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https" else { return nil }
        let dates = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? { (value as? String).flatMap(dates.date(from:)) }
        let labels = (object["labels"] as? [[String: Any]] ?? []).compactMap { label -> OpenItem.Label? in
            guard let name = label["name"] as? String else { return nil }
            return OpenItem.Label(name: name, color: label["color"] as? String ?? "888888")
        }
        var conversation = (object["comments"] as? [[String: Any]] ?? []).compactMap { comment -> WorkDetail.Comment? in
            guard let when = date(comment["createdAt"]) else { return nil }
            return WorkDetail.Comment(author: login(comment["author"]), body: comment["body"] as? String ?? "", date: when)
        }
        // A review says something when it has a body or a verdict; a pending one is the viewer's own draft.
        conversation += (object["reviews"] as? [[String: Any]] ?? []).compactMap { review -> WorkDetail.Comment? in
            let state = review["state"] as? String ?? ""
            let body = review["body"] as? String ?? ""
            guard let when = date(review["submittedAt"]), state != "PENDING",
                  !(state == "COMMENTED" && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return nil }
            return WorkDetail.Comment(author: login(review["author"]), body: body, date: when, review: state)
        }
        conversation.sort { $0.date < $1.date }
        let created = date(object["createdAt"]) ?? .distantPast
        let decision = (object["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let files = (object["files"] as? [[String: Any]] ?? []).compactMap { file -> WorkDetail.File? in
            guard let path = file["path"] as? String else { return nil }
            return WorkDetail.File(path: path, additions: file["additions"] as? Int ?? 0, deletions: file["deletions"] as? Int ?? 0)
        }
        let checks = (object["statusCheckRollup"] as? [[String: Any]] ?? []).compactMap(check)
            .sorted { $0.state != $1.state ? $0.state < $1.state : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return WorkDetail(
            repo: repo, number: number, title: object["title"] as? String ?? "", body: object["body"] as? String ?? "", url: url,
            isPullRequest: pullRequest, state: object["state"] as? String ?? "OPEN", author: login(object["author"]),
            createdAt: created, updatedAt: date(object["updatedAt"]) ?? created, labels: labels, conversation: conversation,
            isDraft: object["isDraft"] as? Bool ?? false, head: object["headRefName"] as? String, base: object["baseRefName"] as? String,
            fromFork: object["isCrossRepository"] as? Bool ?? false, additions: object["additions"] as? Int ?? 0,
            deletions: object["deletions"] as? Int ?? 0, changedFiles: object["changedFiles"] as? Int ?? files.count,
            reviewDecision: decision, checks: checks, files: files)
    }

    /// A check run (a GitHub Actions job) or a commit status of `statusCheckRollup`.
    private static func check(_ entry: [String: Any]) -> WorkDetail.Check? {
        let link = { (key: String) in (entry[key] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil } }
        if let context = entry["context"] as? String {
            let state: WorkDetail.Check.State = switch entry["state"] as? String {
            case "SUCCESS": .success
            case "FAILURE", "ERROR": .failure
            default: .pending
            }
            return WorkDetail.Check(name: context, state: state, url: link("targetUrl"))
        }
        guard let name = entry["name"] as? String else { return nil }
        let state: WorkDetail.Check.State
        if entry["status"] as? String != "COMPLETED" {
            state = .pending
        } else {
            switch entry["conclusion"] as? String {
            case "SUCCESS": state = .success
            case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": state = .failure
            default: state = .skipped
            }
        }
        let workflow = (entry["workflowName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WorkDetail.Check(name: name, workflow: workflow, state: state, url: link("detailsUrl"))
    }

    /// An author as github.com names it: `app/dependabot` is `dependabot[bot]`, and a deleted
    /// account is `ghost`.
    static func login(_ author: Any?) -> String {
        guard let login = (author as? [String: Any])?["login"] as? String, !login.isEmpty else { return "ghost" }
        return login.hasPrefix("app/") ? String(login.dropFirst(4)) + "[bot]" : login
    }

    /// A GitHub user's avatar, by login; nil for an app's, which has no such address.
    public static func avatar(login: String) -> URL? {
        guard !login.isEmpty, login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(login)?s=64")
    }
}
