import Foundation

/// What Projects shows, kept on disk so it opens at once, after GitChu's store: the repositories
/// GitHub lists for the signed-in account, their PROJECT.md, and their open pull requests and
/// issues with GitHub's counts. Each part remembers the list entry it was read under, so a sync
/// (`ProjectSync`) reads again only what changed, and a sync that fails keeps what it has.
public struct ProjectSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// The fields of a repository in GitHub's REST list that move when anything Projects shows of
    /// it could have: a push (PROJECT.md, a pull request's commits), a change to its settings, and
    /// an issue or pull request opened or closed (`open_issues_count` counts both; a new issue moves
    /// it but not `updated_at`).
    public struct Fingerprint: Codable, Hashable, Sendable {
        public var pushedAt: Date?
        public var updatedAt: Date?
        public var openCount: Int
    }

    /// A repository as `GET /user/repos` lists it.
    public struct Listed: Codable, Hashable, Sendable {
        public var nameWithOwner: String
        public var description: String
        public var pushedAt: Date?
        public var updatedAt: Date?
        public var isPrivate: Bool
        public var isFork: Bool
        public var isArchived: Bool
        public var language: String?
        /// Open issues and pull requests together.
        public var openCount: Int
        public var ownerAvatar: URL?
        public var ownerIsOrganization: Bool

        public init(nameWithOwner: String, description: String = "", pushedAt: Date? = nil, updatedAt: Date? = nil, isPrivate: Bool = false,
                    isFork: Bool = false, isArchived: Bool = false, language: String? = nil, openCount: Int = 0, ownerAvatar: URL? = nil,
                    ownerIsOrganization: Bool = false) {
            self.nameWithOwner = nameWithOwner; self.description = description; self.pushedAt = pushedAt; self.updatedAt = updatedAt
            self.isPrivate = isPrivate; self.isFork = isFork; self.isArchived = isArchived; self.language = language
            self.openCount = openCount; self.ownerAvatar = ownerAvatar; self.ownerIsOrganization = ownerIsOrganization
        }

        /// GitHub matches names whatever their case.
        public var key: String { nameWithOwner.lowercased() }
        public var fingerprint: Fingerprint { Fingerprint(pushedAt: pushedAt, updatedAt: updatedAt, openCount: openCount) }
    }

    /// One page of the list, with its ETag; its repositories stand in for it when GitHub answers 304.
    public struct Page: Codable, Equatable, Sendable {
        public var etag: String
        public var repos: [Listed]
        public init(etag: String, repos: [Listed]) { self.etag = etag; self.repos = repos }
    }

    /// PROJECT.md as read after the push the list showed then.
    public struct Record: Codable, Equatable, Sendable {
        public var record: ProjectRecord
        public var pushedAt: Date?
    }

    /// A repository's open pull requests and issues as read, GitHub's counts, and the list entry
    /// they were read under.
    public struct Work: Codable, Equatable, Sendable {
        public var items: [GitHubLookup.OpenItem]
        public var counts: GitHubLookup.OpenCounts
        public var fingerprint: Fingerprint?
    }

    /// Why a part couldn't be read, under the list entry tried: a check for changes doesn't try it
    /// again until that entry moves; a full sync does.
    public struct Problem: Codable, Equatable, Sendable {
        public var message: String
        public var tried: Fingerprint?
    }

    public var version: Int
    /// The GitHub account it was read as.
    public var login: String
    /// `GET /user`'s ETag: a sync learns for free that the same account is signed in.
    public var userETag: String?
    /// The end of the last sync that read the account and the whole list.
    public var syncedAt: Date?
    /// The start of the last such full sync, which reads the list without ETags.
    public var fullSyncedAt: Date?
    public var pages: [Page]
    /// Repositories a list no longer has that are kept until a full sync settles them: a check for
    /// changes never removes one, and a full sync asks GitHub first (`ProjectSync`).
    public var unlisted: [Listed]
    /// Of those, the ones a complete list lacked though GitHub still showed them (a public
    /// repository the account can't reach any more): the next complete list without them drops them.
    public var stillShown: Set<String>
    public var records: [String: Record]
    public var recordProblems: [String: Problem]
    public var work: [String: Work]
    public var workProblems: [String: Problem]
    /// Each probe's ETag, taken before the open work it flagged was read (or tried).
    public var probeETags: [String: String]

    public init(login: String) {
        version = Self.currentVersion; self.login = login; pages = []; unlisted = []; stillShown = []
        records = [:]; recordProblems = [:]; work = [:]; workProblems = [:]; probeETags = [:]
    }

    // MARK: What Projects shows

    /// Every repository listed, without archived ones.
    public var listed: [Listed] {
        var seen = Set<String>()
        return (pages.flatMap(\.repos) + unlisted).filter { !$0.isArchived && seen.insert($0.key).inserted }
    }

    /// The repositories, most recently pushed first, with GitHub's open counts as last read.
    public var repositories: [GitHubLookup.Repo] {
        listed.map { listed in
            let counts = listed.openCount == 0 ? nil : work[listed.nameWithOwner]?.counts
            return GitHubLookup.Repo(nameWithOwner: listed.nameWithOwner, description: listed.description, pushedAt: listed.pushedAt,
                                     isPrivate: listed.isPrivate, isFork: listed.isFork, ownerAvatar: listed.ownerAvatar,
                                     ownerIsOrganization: listed.ownerIsOrganization, language: listed.language,
                                     openIssues: counts?.issues ?? 0, openPullRequests: counts?.pullRequests ?? 0)
        }
        .sorted { a, b in
            let (x, y) = (a.pushedAt ?? .distantPast, b.pushedAt ?? .distantPast)
            return x != y ? x > y : a.nameWithOwner.lowercased() < b.nameWithOwner.lowercased()
        }
    }

    public var projectRecords: [String: ProjectRecord] { records.mapValues(\.record) }
    public var recordErrors: [String: String] { recordProblems.mapValues(\.message) }
    /// The open pull requests and issues, most recently updated first.
    public var openItems: [GitHubLookup.OpenItem] { work.values.flatMap(\.items).sorted { $0.updatedAt > $1.updatedAt } }
    public var unreadableWork: [String] { workProblems.keys.sorted() }

    // MARK: Taking what a sync read

    /// Takes the list as read now. A repository it lacks is kept among `unlisted`, unless the list
    /// is complete (every page read afresh) and it is `gone`: GitHub says so, or it was still shown
    /// when the last complete list lacked it too. Returns the repositories dropped.
    @discardableResult
    public mutating func takeList(_ pages: [Page], complete: Bool, gone: Set<String> = []) -> [String] {
        let before = listedAll
        self.pages = pages
        let now = Set(pages.flatMap(\.repos).map(\.key))
        let missing = before.filter { !now.contains($0.key) }
        var dropped: [String] = []
        unlisted = []
        var shown = Set<String>()
        for repo in missing {
            if complete, gone.contains(repo.key) || stillShown.contains(repo.key) {
                dropped.append(repo.nameWithOwner)
            } else {
                unlisted.append(repo)
                if complete || stillShown.contains(repo.key) { shown.insert(repo.key) }
            }
        }
        stillShown = shown
        for name in dropped {
            records[name] = nil; recordProblems[name] = nil; work[name] = nil; workProblems[name] = nil; probeETags[name] = nil
        }
        return dropped
    }

    /// Of the repositories listed before, those a complete list `pages` lacks, which GitHub is asked
    /// about first unless the last complete list lacked them too.
    public func missing(from pages: [Page]) -> [Listed] {
        let now = Set(pages.flatMap(\.repos).map(\.key))
        return listedAll.filter { !now.contains($0.key) && !stillShown.contains($0.key) }
    }

    /// Every repository listed, archived ones too.
    private var listedAll: [Listed] {
        var seen = Set<String>()
        return (pages.flatMap(\.repos) + unlisted).filter { seen.insert($0.key).inserted }
    }

    public mutating func takeRecord(_ repo: String, _ result: Result<ProjectRecord, ProjectRecord.Problem>, under listed: Fingerprint?) {
        switch result {
        case .success(let record):
            records[repo] = Record(record: record, pushedAt: listed?.pushedAt)
            recordProblems[repo] = nil
        case .failure(let problem):
            recordProblems[repo] = Problem(message: problem.message, tried: listed)
        }
    }

    /// Takes what `openWork` read for the repositories `asked`, each under its list entry, with the
    /// probe ETags taken before; one it couldn't read keeps what it had.
    public mutating func takeWork(_ asked: [String], _ result: Result<GitHubLookup.OpenWork, TaskWorktree.Failure>,
                                  under listed: [String: Fingerprint], etags: [String: String]) {
        for repo in asked { if let etag = etags[repo] { probeETags[repo] = etag } }
        switch result {
        case .success(let read):
            let unreadable = Set(read.unreadable.map { $0.lowercased() })
            for repo in asked {
                guard !unreadable.contains(repo.lowercased()) else {
                    workProblems[repo] = Problem(message: "GitHub couldn't answer for its open pull requests and issues.", tried: listed[repo])
                    continue
                }
                let items = read.items.filter { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
                let counts = read.counts[repo] ?? GitHubLookup.OpenCounts(issues: items.filter { !$0.isPullRequest }.count,
                                                                         pullRequests: items.filter(\.isPullRequest).count)
                work[repo] = Work(items: items, counts: counts, fingerprint: listed[repo])
                workProblems[repo] = nil
            }
        case .failure(let failure):
            for repo in asked { workProblems[repo] = Problem(message: failure.step, tried: listed[repo]) }
        }
    }

    /// Repositories with nothing open any more lose what they had.
    public mutating func emptyWork(_ repos: [String], under listed: [String: Fingerprint]) {
        for repo in repos {
            work[repo] = Work(items: [], counts: GitHubLookup.OpenCounts(issues: 0, pullRequests: 0), fingerprint: listed[repo])
            workProblems[repo] = nil
            probeETags[repo] = nil
        }
    }

    /// Forgets issue `number` of `repo`, deleted on GitHub: it leaves the open issues read, and
    /// GitHub's count of them, which counted it, drops by one. One that wasn't read (closed, or
    /// beyond those read) changes nothing; GitHub's list entry moves, so the next sync reads the
    /// repository again. Returns whether it was there.
    @discardableResult
    public mutating func removeIssue(_ number: Int, of repo: String) -> Bool {
        guard let key = work.keys.first(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }), var read = work[key],
              let index = read.items.firstIndex(where: { !$0.isPullRequest && $0.number == number }) else { return false }
        read.items.remove(at: index)
        read.counts.issues = max(0, read.counts.issues - 1)
        work[key] = read
        return true
    }
}

/// What a sync reads once it has the list: PROJECT.md of each repository pushed to since it was
/// read (or never read), and the open pull requests and issues of each whose list entry moved,
/// that a probe flagged, or that has a pull request whose checks are running (a finished check
/// moves neither). A check for changes doesn't retry what failed under the same entry; a full
/// sync does.
public struct ProjectSyncPlan: Equatable, Sendable {
    public var records: [String] = []
    public var work: [String] = []
    /// Repositories with nothing open any more, whose open work goes.
    public var emptied: [String] = []

    public init(snapshot: ProjectSnapshot, full: Bool, flagged: Set<String>) {
        for listed in snapshot.listed {
            let repo = listed.nameWithOwner, fingerprint = listed.fingerprint
            if snapshot.records[repo].map({ $0.pushedAt != listed.pushedAt }) ?? true,
               full || snapshot.recordProblems[repo].map({ $0.tried?.pushedAt != listed.pushedAt }) ?? true {
                records.append(repo)
            }
            let stored = snapshot.work[repo]
            guard listed.openCount > 0 else {
                if let stored, !stored.items.isEmpty || stored.counts.issues + stored.counts.pullRequests > 0 { emptied.append(repo) }
                continue
            }
            let due = stored == nil || stored?.fingerprint != fingerprint || flagged.contains(repo)
                || stored?.items.contains { $0.isPullRequest && $0.checks == .pending } == true
            let retry = full || flagged.contains(repo) || snapshot.workProblems[repo].map { $0.tried != fingerprint } ?? true
            if due, retry { work.append(repo) }
        }
    }
}

/// What `gh api -i` printed: the HTTP status, the headers (by lower-case name) and the body; nil
/// when it printed no HTTP response, as when gh can't reach GitHub.
public struct GitHubResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: String

    public init(status: Int, headers: [String: String] = [:], body: String = "") { self.status = status; self.headers = headers; self.body = body }

    public static func parse(_ output: String) -> GitHubResponse? {
        // gh ends the status line with \n and each header with \r\n, which Swift counts as one newline.
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        while let first = lines.first, !first.hasPrefix("HTTP/") { lines = lines.dropFirst() }
        guard let statusLine = lines.popFirst(), let status = statusLine.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return nil }
        var headers: [String: String] = [:]
        while let header = lines.popFirst() {
            if header.isEmpty { break }
            guard let colon = header.firstIndex(of: ":") else { continue }
            headers[header[..<colon].lowercased()] = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return GitHubResponse(status: status, headers: headers, body: lines.joined(separator: "\n"))
    }

    public var etag: String? { headers["etag"].flatMap { $0.isEmpty ? nil : $0 } }
    /// The `Link` header names a next page.
    public var hasNextPage: Bool {
        (headers["link"] ?? "").split(separator: ",").contains { $0.contains("rel=\"next\"") }
    }
}

extension ProjectSnapshot.Listed {
    /// The repositories in a page of `GET /user/repos`; nil when it isn't one.
    static func parse(page body: String) -> [ProjectSnapshot.Listed]? {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [[String: Any]] else { return nil }
        let dates = ISO8601DateFormatter()
        return array.compactMap { object in
            guard let name = object["full_name"] as? String, name.contains("/") else { return nil }
            let owner = object["owner"] as? [String: Any]
            // The 64-point size the rows show, as GraphQL's avatarUrl(size: 64) gave it.
            var avatar = (owner?["avatar_url"] as? String).flatMap(URLComponents.init(string:))
            if let items = avatar?.queryItems ?? (avatar != nil ? [] : nil) {
                avatar?.queryItems = items.filter { $0.name != "s" } + [URLQueryItem(name: "s", value: "64")]
            }
            let language = object["language"] as? String
            return ProjectSnapshot.Listed(
                nameWithOwner: name, description: (object["description"] as? String ?? "").replacingOccurrences(of: "\n", with: " "),
                pushedAt: (object["pushed_at"] as? String).flatMap(dates.date(from:)), updatedAt: (object["updated_at"] as? String).flatMap(dates.date(from:)),
                isPrivate: object["private"] as? Bool ?? false, isFork: object["fork"] as? Bool ?? false, isArchived: object["archived"] as? Bool ?? false,
                language: language?.isEmpty == false ? language : nil, openCount: object["open_issues_count"] as? Int ?? 0,
                ownerAvatar: avatar?.scheme == "https" ? avatar?.url : nil, ownerIsOrganization: owner?["type"] as? String == "Organization")
        }
    }
}

/// A project as offline readers see it, such as `#project` completion: from the saved catalog,
/// without asking GitHub.
public struct ProjectCatalogEntry: Identifiable, Hashable, Sendable {
    /// PROJECT.md's name, else the repository's.
    public var name: String
    /// `owner/name`.
    public var repo: String
    public var url: URL
    /// PROJECT.md's status; nil for a repository without one, or not read yet.
    public var status: ProjectMetadata.Status?
    /// Where its tasks work, and "This Mac" or the host's nickname.
    public var location: RepoLocation
    public var workplace: String
    public var id: String { repo }
}

extension ProjectRow {
    public var catalogEntry: ProjectCatalogEntry {
        ProjectCatalogEntry(name: metadata?.name ?? repo.name, repo: repo.nameWithOwner,
                            url: URL(string: "https://github.com/\(repo.nameWithOwner)") ?? URL(string: "https://github.com")!,
                            status: metadata?.status, location: location, workplace: workplace)
    }
}
