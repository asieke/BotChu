import Foundation

/// What the saved Projects catalog knows of a repository's open issues: GitHub's count, without
/// pull requests, and why its open work couldn't be read the last time it was tried.
public struct OpenIssueStatus: Equatable, Sendable {
    /// Nil until its open work is read; 0 for a repository GitHub lists with nothing open.
    public var count: Int?
    /// What was read before stays when this is set.
    public var problem: String?

    public init(count: Int?, problem: String? = nil) { self.count = count; self.problem = problem }
}

extension ProjectSnapshot {
    /// Each listed repository's, by lower-cased `owner/name`.
    public var issueStatus: [String: OpenIssueStatus] {
        Dictionary(listed.map { listed in
            let name = listed.nameWithOwner
            let status = listed.openCount == 0 ? OpenIssueStatus(count: 0)
                : OpenIssueStatus(count: work[name]?.counts.issues, problem: workProblems[name]?.message)
            return (listed.key, status)
        }) { first, _ in first }
    }
}

/// A repository's open issues at a glance, as a task's Activity shows them: GitHub's count, the few
/// most recently updated, and how current they are. It is made from the catalog as it is now, for
/// the repository asked about, so nothing read for another repository can show under it.
public struct IssuePreview: Equatable, Sendable {
    /// How many issues it lists at most.
    public static let limit = 5

    public enum Count: Equatable, Sendable {
        /// Not read yet, while a sync is (or is about to be) reading it.
        case loading
        /// GitHub doesn't list it among the account's repositories: not one of them, archived,
        /// renamed or out of reach.
        case unavailable
        /// Not read, and no sync is reading it: `problem` says why, when it's known.
        case unknown
        /// GitHub counts this many open issues, however many were read.
        case known(Int)
    }

    public var repo: String
    public var count: Count
    /// The most recently updated open issues read, at most `limit`, newest first.
    public var issues: [GitHubLookup.OpenItem]
    /// Why the last sync couldn't read it; what was read before stays.
    public var problem: String?
    public var syncing: Bool

    /// - Parameters:
    ///   - statuses: `ProjectSnapshot.issueStatus`; nil until the account's repositories are read.
    ///   - items: the open pull requests and issues read, of every repository.
    ///   - error: why the last sync failed as a whole.
    public init(repo: String, statuses: [String: OpenIssueStatus]?, items: [GitHubLookup.OpenItem]?, syncing: Bool, error: String?) {
        self.repo = repo
        self.syncing = syncing
        let read = (items ?? []).filter { !$0.isPullRequest && $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let statuses else {
            count = syncing || error == nil ? .loading : .unknown
            issues = []
            problem = error
            return
        }
        guard let status = statuses[repo.lowercased()] else {
            count = .unavailable
            issues = []
            problem = error
            return
        }
        count = status.count.map { .known(max($0, read.count)) } ?? (syncing ? .loading : .unknown)
        issues = Array(read.prefix(Self.limit))
        problem = status.problem ?? error
    }

    /// GitHub's count, when it is known.
    public var total: Int? { if case .known(let total) = count { total } else { nil } }
    /// GitHub counts more open issues than it lists.
    public var hasMore: Bool { total.map { $0 > issues.count } ?? false }
    /// GitHub counts open issues but none were read, which isn't an empty backlog.
    public var unread: Bool { total.map { $0 > 0 && issues.isEmpty } ?? false }
    /// "Issues · 7", which stays in view while the section is collapsed; "Issues" without a count.
    public var heading: String { total.map { "Issues · \($0)" } ?? "Issues" }
    public var accessibilityHeading: String {
        total.map { "Issues, \($0) open" } ?? "Issues, \(note?.lowercased() ?? "count unknown")"
    }
    /// Beside the heading: why there is no count, or that the one shown may be out of date.
    public var note: String? {
        switch count {
        case .loading: "Reading…"
        case .unavailable: "Unavailable"
        case .unknown: problem == nil ? "Not read" : "Couldn't read"
        case .known: problem != nil ? "Not updated" : syncing ? "Syncing…" : nil
        }
    }
}
