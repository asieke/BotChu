import Foundation

/// What the Projects tables show: a row per repository, and the open pull requests and issues
/// across them, read with `gh` as the owner signed it in.
extension GitHubLookup {
    /// An open pull request or issue in one of the owner's repositories.
    public struct OpenItem: Identifiable, Hashable, Codable, Sendable {
        /// The combined state of a pull request's latest commit's checks.
        public enum Checks: Int, Comparable, Codable, Sendable {
            case none, pending, failure, success
            public static func < (a: Checks, b: Checks) -> Bool { a.rawValue < b.rawValue }
            public var label: String {
                switch self {
                case .none: "No checks"
                case .pending: "Checks running"
                case .failure: "Checks failed"
                case .success: "Checks passed"
                }
            }
        }
        public struct Label: Hashable, Codable, Sendable {
            public var name: String
            /// Six hex digits, without `#`.
            public var color: String
            public init(name: String, color: String) { self.name = name; self.color = color }
        }

        public var repo: String
        public var number: Int
        public var title: String
        public var url: URL
        public var isPullRequest: Bool
        public var isDraft: Bool
        public var author: String
        public var authorAvatar: URL?
        public var createdAt: Date
        public var updatedAt: Date
        public var comments: Int
        public var labels: [Label]
        /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or nil.
        public var reviewDecision: String?
        public var checks: Checks
        public var branch: String?
        public var fromFork: Bool
        public var additions: Int
        public var deletions: Int

        public init(repo: String, number: Int, title: String, url: URL, isPullRequest: Bool, isDraft: Bool = false, author: String,
                    authorAvatar: URL? = nil, createdAt: Date, updatedAt: Date, comments: Int = 0, labels: [Label] = [],
                    reviewDecision: String? = nil, checks: Checks = .none, branch: String? = nil, fromFork: Bool = false,
                    additions: Int = 0, deletions: Int = 0) {
            self.repo = repo; self.number = number; self.title = title; self.url = url; self.isPullRequest = isPullRequest
            self.isDraft = isDraft; self.author = author; self.authorAvatar = authorAvatar; self.createdAt = createdAt
            self.updatedAt = updatedAt; self.comments = comments; self.labels = labels; self.reviewDecision = reviewDecision
            self.checks = checks; self.branch = branch; self.fromFork = fromFork; self.additions = additions; self.deletions = deletions
        }

        public var id: String { "\(repo)#\(number)" }
        public var repoName: String { TaskNaming.repoName(repo) }
        public var work: BotTask.Work { BotTask.Work(number: number, title: title, url: url, isPullRequest: isPullRequest) }
        // Sort keys for the tables.
        public var titleKey: String { title.lowercased() }
        public var repoKey: String { "\(repoName.lowercased())#\(String(format: "%08d", number))" }
        public var authorKey: String { author.lowercased() }
        public var reviewRank: Int {
            switch reviewDecision {
            case "CHANGES_REQUESTED": 1
            case "REVIEW_REQUIRED": 2
            case "APPROVED": 3
            default: 0
            }
        }
        public var changeSize: Int { additions + deletions }
    }

    /// How many repositories one query asks about, and how many of each kind it reads from each.
    static let openWorkBatch = 10
    static let openWorkPerRepo = 30

    /// How many open issues and pull requests GitHub counts in a repository.
    public struct OpenCounts: Hashable, Codable, Sendable {
        public var issues: Int
        public var pullRequests: Int
        public init(issues: Int, pullRequests: Int) { self.issues = issues; self.pullRequests = pullRequests }
    }

    /// What `openWork` read: the items, how many GitHub counts open in each repository that
    /// answered (by `owner/name` as asked), and the repositories GitHub couldn't answer for.
    public struct OpenWork: Equatable, Sendable {
        public var items: [OpenItem]
        public var unreadable: [String]
        public var counts: [String: OpenCounts]
        public init(items: [OpenItem], unreadable: [String] = [], counts: [String: OpenCounts] = [:]) {
            self.items = items; self.unreadable = unreadable; self.counts = counts
        }
    }

    /// The open pull requests and issues of these repositories (`owner/name`), most recently
    /// updated first. A repository GitHub can't resolve is listed as unreadable rather than failing
    /// the rest; it fails when it could read none of them. `run` runs gh (a stand-in in tests).
    public static func openWork(repos: [String], run gh: @escaping @Sendable ([String]) async -> Shell.Result = {
        await Shell.run($0, in: NSHomeDirectory())
    }) async -> Result<OpenWork, TaskWorktree.Failure> {
        var all = OpenWork(items: [], unreadable: repos.filter { !isSafeName($0) })
        var lastRun: Shell.Result?
        let valid = repos.filter(isSafeName)
        for start in stride(from: 0, to: valid.count, by: openWorkBatch) {
            let batch = Array(valid[start..<min(start + openWorkBatch, valid.count)])
            let run = await gh(["gh", "api", "graphql", "-f", "query=\(openWorkQuery(batch))"])
            lastRun = run
            // gh exits non-zero when any repository fails, but still prints the others.
            guard let read = parseOpenWork(run.output, asked: batch) else {
                return .failure(TaskWorktree.Failure(step: "Couldn't read open pull requests and issues with gh", output: run.report("gh api graphql (open work)")))
            }
            all.items += read.items
            all.unreadable += read.unreadable
            all.counts.merge(read.counts) { _, new in new }
        }
        if !repos.isEmpty, all.unreadable.count == repos.count {
            return .failure(TaskWorktree.Failure(step: "Couldn't read open pull requests and issues of any repository with gh",
                                                 output: lastRun?.report("gh api graphql (open work)") ?? "No repository name was valid."))
        }
        all.items.sort { $0.updatedAt > $1.updatedAt }
        return .success(all)
    }

    /// Owner and repository names GitHub allows, so they can be written into a query as they are.
    static func isSafeName(_ nameWithOwner: String) -> Bool {
        let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
    }

    static func openWorkQuery(_ repos: [String]) -> String {
        let each = openWorkPerRepo
        let fields = repos.enumerated().map { index, repo in
            let parts = repo.split(separator: "/")
            return """
                r\(index): repository(owner: "\(parts[0])", name: "\(parts[1])") { nameWithOwner \
                pullRequests(states: OPEN, first: \(each), orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount nodes { \
                number title url isDraft createdAt updatedAt author { login avatarUrl(size: 64) } reviewDecision headRefName \
                isCrossRepository comments { totalCount } additions deletions labels(first: 5) { nodes { name color } } \
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } \
                issues(states: OPEN, first: \(each), orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount nodes { \
                number title url createdAt updatedAt author { login avatarUrl(size: 64) } comments { totalCount } \
                labels(first: 5) { nodes { name color } } } } }
                """
        }
        return "query {\n" + fields.joined(separator: "\n") + "\n}"
    }

    /// The items in a GraphQL answer to `openWorkQuery` for the repositories `asked`, and those of
    /// them it has no answer for; nil when it holds no data at all.
    static func parseOpenWork(_ output: String, asked: [String]) -> OpenWork? {
        guard let root = json(output) as? [String: Any], let data = root["data"] as? [String: Any] else { return nil }
        let dates = ISO8601DateFormatter()
        var items: [OpenItem] = []
        var counts: [String: OpenCounts] = [:]
        var answered = Set<String>()
        for case let repository as [String: Any] in data.values {
            guard let repo = repository["nameWithOwner"] as? String else { continue }
            answered.insert(repo.lowercased())
            let total = { (key: String) in (repository[key] as? [String: Any])?["totalCount"] as? Int }
            if let issues = total("issues"), let pulls = total("pullRequests"),
               let name = asked.first(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) {
                counts[name] = OpenCounts(issues: issues, pullRequests: pulls)
            }
            for pullRequest in [true, false] {
                let nodes = (repository[pullRequest ? "pullRequests" : "issues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
                for node in nodes {
                    guard let number = node["number"] as? Int, let address = node["url"] as? String,
                          let url = URL(string: address), url.scheme == "https" else { continue }
                    let author = node["author"] as? [String: Any]
                    let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { label -> OpenItem.Label? in
                        guard let name = label["name"] as? String else { return nil }
                        return OpenItem.Label(name: name, color: label["color"] as? String ?? "888888")
                    }
                    let commits = (node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]
                    let rollup = ((commits?.last?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any])?["state"] as? String
                    let checks: OpenItem.Checks = switch rollup {
                    case "SUCCESS": .success
                    case "FAILURE", "ERROR": .failure
                    case "PENDING", "EXPECTED": .pending
                    default: .none
                    }
                    let created = (node["createdAt"] as? String).flatMap(dates.date(from:)) ?? .distantPast
                    items.append(OpenItem(
                        repo: repo, number: number, title: node["title"] as? String ?? "", url: url, isPullRequest: pullRequest,
                        isDraft: node["isDraft"] as? Bool ?? false, author: author?["login"] as? String ?? "ghost",
                        authorAvatar: (author?["avatarUrl"] as? String).flatMap(URL.init(string:)), createdAt: created,
                        updatedAt: (node["updatedAt"] as? String).flatMap(dates.date(from:)) ?? created,
                        comments: (node["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0, labels: labels,
                        reviewDecision: node["reviewDecision"] as? String, checks: checks, branch: node["headRefName"] as? String,
                        fromFork: node["isCrossRepository"] as? Bool ?? false,
                        additions: node["additions"] as? Int ?? 0, deletions: node["deletions"] as? Int ?? 0))
                }
            }
        }
        return OpenWork(items: items, unreadable: asked.filter { !answered.contains($0.lowercased()) }, counts: counts)
    }
}

/// One target of PROJECT.md's `deploy` field, as the Projects table shows it.
public struct DeployTarget: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case local, vercel, registry, none, unrecognized }
    public var kind: Kind
    /// The machine of a local target, the Vercel project or registry name, or the target as written.
    public var name: String
    public var path: String?

    /// The targets of a `deploy` value: `none`, or targets separated by commas.
    public static func parse(_ deploy: String) -> [DeployTarget] {
        deploy.split(separator: ",").compactMap { value in
            let value = value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            if value == "none" { return DeployTarget(kind: .none, name: "None") }
            let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, parts[0] == "local" { return DeployTarget(kind: .local, name: parts[1], path: parts[2]) }
            if parts.count == 2, parts[0] == "vercel" { return DeployTarget(kind: .vercel, name: parts[1]) }
            if parts.count == 2, parts[0] == "registry" { return DeployTarget(kind: .registry, name: parts[1]) }
            return DeployTarget(kind: .unrecognized, name: value)
        }
    }
}

/// A repository's row in the Projects table: GitHub's facts, PROJECT.md's metadata, where its tasks
/// work and how many are open, with a sort key for every column.
public struct ProjectRow: Identifiable, Equatable, Sendable {
    /// Not read yet; read, with no PROJECT.md; unreadable as metadata; present; or not read, with why.
    public enum Record: Equatable, Sendable { case loading, missing, invalid, present(ProjectMetadata), failed(String) }

    public var repo: GitHubLookup.Repo
    public var record: Record
    public var deploy: [DeployTarget]
    /// "This Mac", or the host's nickname, where its tasks work.
    public var workplace: String
    public var location: RepoLocation
    public var openTasks: Int

    public var id: String { repo.id }
    public var metadata: ProjectMetadata? { if case .present(let metadata) = record { metadata } else { nil } }
    public var nameKey: String { repo.name.lowercased() }
    public var ownerKey: String { repo.owner.lowercased() }
    public var openIssues: Int { repo.openIssues }
    public var openPullRequests: Int { repo.openPullRequests }
    public var pushedKey: Date { repo.pushedAt ?? .distantPast }
    public var typeKey: Int { metadata.map { ProjectMetadata.Kind.allCases.firstIndex(of: $0.kind)! + 1 } ?? 0 }
    public var statusKey: Int { metadata.map { ProjectMetadata.Status.allCases.firstIndex(of: $0.status)! + 1 } ?? 0 }
    public var mergeKey: Int { metadata.map { $0.merge == "agent" ? 2 : 1 } ?? 0 }
    public var deployKey: String { deploy.map(\.name).joined(separator: ",").lowercased() }
    public var workplaceKey: String { workplace.lowercased() }

    public init(repo: GitHubLookup.Repo, record: Record, deploy: [DeployTarget], workplace: String, location: RepoLocation, openTasks: Int) {
        self.repo = repo; self.record = record; self.deploy = deploy; self.workplace = workplace; self.location = location; self.openTasks = openTasks
    }

    /// The rows for these repositories, from their PROJECT.md records (or why one couldn't be read), the
    /// owner's chosen locations and hosts, and the open tasks' repositories.
    public static func rows(repos: [GitHubLookup.Repo], records: [String: ProjectRecord], errors: [String: String] = [:],
                            chosen: [String: RepoLocation], hosts: [SSHHost], reposRoot: String,
                            taskRepos: [String]) -> [ProjectRow] {
        var tasks: [String: Int] = [:]
        for repo in taskRepos { tasks[repo.lowercased(), default: 0] += 1 }
        return repos.map { repo in
            let file = records[repo.id]
            let record: Record
            switch file {
            case nil: record = errors[repo.id].map(Record.failed) ?? .loading
            case let file? where !file.exists: record = .missing
            case let file?: record = (try? file.metadata(repoName: repo.name)).map(Record.present) ?? .invalid
            }
            let location = Locations.resolve(repo: repo.id, chosen: chosen[repo.id], hosts: hosts, reposRoot: reposRoot)
            let workplace = location.hostID.flatMap { id in hosts.first { $0.id == id }?.nickname } ?? "This Mac"
            var deploy: [DeployTarget] = []
            if case .present(let metadata) = record { deploy = DeployTarget.parse(metadata.deploy) }
            return ProjectRow(repo: repo, record: record, deploy: deploy, workplace: workplace, location: location,
                              openTasks: tasks[repo.id.lowercased()] ?? 0)
        }
    }

    /// Whether every word of the search is in the row's name, description or metadata.
    public func matches(_ query: String) -> Bool {
        let text = [repo.nameWithOwner, repo.description, repo.language ?? "", metadata?.name ?? "", metadata?.kind.label ?? "",
                    metadata?.status.rawValue ?? "", metadata?.deploy ?? "", workplace].joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}

/// Which projects the Projects list shows, by the status in their PROJECT.md: active ones by default.
public enum ProjectStatusFilter: String, CaseIterable, Sendable {
    case active, all, paused, maintenance, deprecated, unclassified

    public var label: String {
        switch self {
        case .active: "Active"
        case .all: "All statuses"
        case .unclassified: "Unclassified"
        case .paused, .maintenance, .deprecated: rawValue.capitalized
        }
    }

    /// Whether the row shows. One whose PROJECT.md isn't read yet, or can't be, shows only under All
    /// statuses: nobody knows its status until then. Unclassified ones have no PROJECT.md.
    public func includes(_ row: ProjectRow) -> Bool {
        switch self {
        case .all: true
        case .unclassified: row.record == .missing
        case .active, .paused, .maintenance, .deprecated: row.metadata?.status.rawValue == rawValue
        }
    }
}

/// Which projects the Projects list shows by the type in their PROJECT.md: code (a library or an
/// app), non-code (docs), or all of them.
public enum ProjectKindFilter: String, CaseIterable, Sendable {
    case all, code, docs

    public var label: String {
        switch self {
        case .all: "All projects"
        case .code: "Code"
        case .docs: "Non-code"
        }
    }

    /// Whether the row shows. One without metadata (none, not read yet, or unreadable) has no type,
    /// so it shows only under All projects.
    public func includes(_ row: ProjectRow) -> Bool {
        guard self != .all, let kind = row.metadata?.kind else { return self == .all }
        return (kind == .docs) == (self == .docs)
    }
}

/// The repositories all three of Projects' views cover: those of the chosen status and type. A search
/// or a chosen repository narrows a view further.
public struct ProjectScope: Equatable, Sendable {
    public var status: ProjectStatusFilter
    public var kind: ProjectKindFilter
    public init(status: ProjectStatusFilter, kind: ProjectKindFilter) { self.status = status; self.kind = kind }

    public static let everything = ProjectScope(status: .all, kind: .all)

    public func includes(_ row: ProjectRow) -> Bool { status.includes(row) && kind.includes(row) }
    public var isNarrowed: Bool { self != .everything }

    /// The projects it covers in words, as in "No open issues in active code projects".
    public var projects: String {
        let words = [status == .all ? nil : status.label.lowercased(),
                     kind == .all ? nil : kind == .code ? "code" : "non-code"].compactMap { $0 }
        return (words + ["projects"]).joined(separator: " ")
    }

    /// GitHub's count of open pull requests or issues across the repositories it covers.
    public func openCount(in rows: [ProjectRow], pulls: Bool) -> Int {
        rows.filter(includes).reduce(0) { $0 + (pulls ? $1.openPullRequests : $1.openIssues) }
    }
}

/// The open pull requests or issues one of Projects' tables shows: those read for the repositories in
/// scope, of the chosen repository when it is in scope (a choice the scope no longer covers counts as
/// none, so it can't show work the scope leaves out), matching the search.
public struct ProjectWork: Equatable, Sendable {
    public var pulls: Bool
    /// The chosen repository, when the scope covers it.
    public var repo: String?
    public var items: [GitHubLookup.OpenItem]
    /// The repositories in scope with any of this kind read, and the chosen one, by name.
    public var repos: [String]
    /// The repositories shown that have more open than were read.
    public var truncated: [GitHubLookup.Repo]
    /// How many read are left out by the scope alone, before the repository and search.
    public var outOfScope: Int

    public init(rows: [ProjectRow], items: [GitHubLookup.OpenItem], scope: ProjectScope, pulls: Bool, repo chosen: String?, query: String) {
        let eligible = rows.filter(scope.includes)
        let ids = Set(eligible.map { $0.id.lowercased() })
        let kind = items.filter { $0.isPullRequest == pulls }
        let inScope = kind.filter { ids.contains($0.repo.lowercased()) }
        let repo = chosen.flatMap { chosen in eligible.first { $0.id.caseInsensitiveCompare(chosen) == .orderedSame }?.id }
        self.pulls = pulls
        self.repo = repo
        self.outOfScope = kind.count - inScope.count
        self.items = inScope.filter { item in (repo.map { item.repo.caseInsensitiveCompare($0) == .orderedSame } ?? true) && item.matches(query) }
        var seen = Set<String>()
        let names = (inScope.map(\.repo) + [repo].compactMap { $0 }).filter { seen.insert($0.lowercased()).inserted }
        self.repos = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let read = Dictionary(grouping: inScope, by: { $0.repo.lowercased() }).mapValues(\.count)
        self.truncated = eligible.map(\.repo).filter { row in
            (repo == nil || row.id == repo) && (pulls ? row.openPullRequests : row.openIssues) > (read[row.id.lowercased()] ?? 0)
        }
    }
}

extension GitHubLookup.OpenItem {
    /// Whether every word of the search is in its title, number, repository, author, branch or labels.
    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            [title, repo, "#\(number)", author, branch ?? ""].contains { $0.localizedCaseInsensitiveContains(word) }
                || labels.contains { $0.name.localizedCaseInsensitiveContains(word) }
        }
    }
}
