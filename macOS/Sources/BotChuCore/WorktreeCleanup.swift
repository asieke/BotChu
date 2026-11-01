import Foundation

/// A worktree of a checkout with whether it has changes, as the Sub-agents tab's Worktrees list
/// shows it (#405; #399, decision 7).
public struct WorktreeRow: Equatable, Hashable, Sendable, Identifiable {
    public var entry: WorktreeEntry
    /// Nil when its status couldn't be read (its folder is gone).
    public var isDirty: Bool?

    public init(entry: WorktreeEntry, isDirty: Bool? = nil) {
        self.entry = entry
        self.isDirty = isDirty
    }

    public var id: String { entry.path }
}

/// The pull request on a branch, as `gh pr list --head <branch> --state all` shows it: the newest.
public struct BranchPullRequest: Equatable, Hashable, Sendable {
    public var number: Int
    public var state: PullRequestState
    /// The commit its branch was at on GitHub (`headRefOid`).
    public var head: String?

    public init(number: Int, state: PullRequestState, head: String? = nil) {
        self.number = number
        self.state = state
        self.head = head
    }
}

/// Reading a checkout's worktrees with their changes, and the pull requests on their branches, each
/// with one shell script, and when a worktree may be removed without asking.
public enum WorktreeStatus {
    static let statusMarker = "--botchu-status"
    static let branchMarker = "--botchu-branch "

    /// A POSIX `sh` script, run in `checkout`: its worktrees (`git worktree list --porcelain`), then,
    /// after a marker, `dirty <path>` or `clean <path>` for each one whose folder is there.
    public static func script(checkout: String) -> String {
        let list = WorktreeList.script(checkout: checkout)
        return """
            list=$(\(list)) || exit $?
            printf '%s\\n' "$list"
            printf '%s\\n' '\(statusMarker)'
            printf '%s\\n' "$list" | sed -n 's/^worktree //p' | while IFS= read -r path; do
              [ -d "$path" ] || continue
              if [ -n "$(git -C "$path" status --porcelain 2>/dev/null | head -n 1)" ]; then echo "dirty $path"; else echo "clean $path"; fi
            done
            """
    }

    /// What `script` printed: each worktree, main first, with whether it has changes.
    public static func parse(_ output: String) -> [WorktreeRow] {
        let parts = output.components(separatedBy: statusMarker)
        let entries = WorktreeList.parse(porcelain: parts[0])
        var dirty: [String: Bool] = [:]
        if parts.count > 1 {
            for line in parts[1].split(whereSeparator: \.isNewline) {
                if line.hasPrefix("dirty ") { dirty[String(line.dropFirst(6))] = true }
                if line.hasPrefix("clean ") { dirty[String(line.dropFirst(6))] = false }
            }
        }
        return entries.map { WorktreeRow(entry: $0, isDirty: dirty[$0.path]) }
    }

    /// A POSIX `sh` script, run in the checkout, given its branches (`$1`…): for each, a marker line
    /// with the branch, then what `gh pr list --head <branch> --state all` prints as JSON.
    public static let pullRequestsScript = #"""
        for branch in "$@"; do
          printf '%s%s\n' '--botchu-branch ' "$branch"
          gh pr list --head "$branch" --state all --limit 1 --json number,state,headRefOid 2>/dev/null || echo '[]'
        done
        """#

    /// What `pullRequestsScript` printed: the newest pull request on each branch that has one.
    public static func parsePullRequests(_ output: String) -> [String: BranchPullRequest] {
        struct Item: Decodable {
            var number: Int
            var state: String
            var headRefOid: String?
        }
        var found: [String: BranchPullRequest] = [:]
        var branch: String?
        var json = ""
        func close() {
            defer { json = "" }
            guard let branch, let data = json.data(using: .utf8),
                  let item = (try? JSONDecoder().decode([Item].self, from: data))?.first,
                  let state = PullRequestState(rawValue: item.state.lowercased()) else { return }
            found[branch] = BranchPullRequest(number: item.number, state: state, head: item.headRefOid)
        }
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix(branchMarker) {
                close()
                branch = String(line.dropFirst(branchMarker.count))
            } else {
                json += line + "\n"
            }
        }
        close()
        return found
    }
}

/// When BotChu removes a worktree by itself (#399, decision 7): never the main checkout, nor a
/// locked, detached or changed one, nor one a running run or an open task works in; only one whose
/// branch's pull request merged at the commit the worktree is on, so nothing made after it is lost.
public enum WorktreeCleanupPolicy {
    public static func removes(_ row: WorktreeRow, pullRequest: BranchPullRequest?, isOwned: Bool) -> Bool {
        let entry = row.entry
        guard canRemove(entry), !entry.isLocked, !entry.isPrunable, entry.branch != nil, !isOwned,
              row.isDirty == false, let pullRequest, pullRequest.state == .merged else { return false }
        // A pull request read without its head (or a worktree without one) can't vouch for it.
        guard let head = entry.head, let merged = pullRequest.head, head == merged else { return false }
        return true
    }

    /// Whether the owner may remove it: every worktree but the main checkout.
    public static func canRemove(_ entry: WorktreeEntry) -> Bool { !entry.isMain }

    /// The same folder, however it is written: `~`, `/private/tmp` and `/tmp`, a trailing slash.
    public static func samePath(_ a: String, _ b: String, home: String = NSHomeDirectory()) -> Bool {
        normalized(a, home: home) == normalized(b, home: home)
    }

    static func normalized(_ path: String, home: String) -> String {
        var path = path
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        path = (path as NSString).standardizingPath
        for prefix in ["/private/tmp", "/private/var"] where path == prefix || path.hasPrefix(prefix + "/") {
            path = String(path.dropFirst("/private".count))
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The run working in `path`, among those still running: the newest.
    public static func owner(of path: String, among runs: [SubagentRun], home: String = NSHomeDirectory()) -> SubagentRun? {
        runs.filter { $0.phase.isActive && $0.worktree.map { samePath($0, path, home: home) } == true }
            .max { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
    }

    /// The worktrees no running run works in, to list on their own: every one but the main checkout.
    public static func unowned(_ rows: [WorktreeRow], among runs: [SubagentRun], home: String = NSHomeDirectory()) -> [WorktreeRow] {
        rows.filter { !$0.entry.isMain && owner(of: $0.entry.path, among: runs, home: home) == nil }
    }
}

/// Where a run works, as its row in the Sub-agents tab says it (#431): its branch (or its worktree's
/// folder), whether that worktree has changes, and the pull request on the branch.
public struct SubagentWorkplace: Equatable, Sendable {
    public var name: String
    public var isDirty: Bool
    public var pullRequest: Int?
    /// Nil for a pull request it only linked to.
    public var pullRequestState: PullRequestState?

    public init(name: String, isDirty: Bool = false, pullRequest: Int? = nil, pullRequestState: PullRequestState? = nil) {
        self.name = name
        self.isDirty = isDirty
        self.pullRequest = pullRequest
        self.pullRequestState = pullRequestState
    }

    /// From what the run's transcript showed, and the checkout's worktrees as last read: its worktree's
    /// row gives the changes (and the branch when the run didn't say), the newest pull request read on
    /// the branch wins over the one the run named. Nil when it shows neither a branch nor a worktree.
    public static func of(_ run: SubagentRun, rows: [WorktreeRow] = [], pullRequests: [String: BranchPullRequest] = [:],
                          home: String = NSHomeDirectory()) -> SubagentWorkplace? {
        let row = run.worktree.flatMap { path in rows.first { WorktreeCleanupPolicy.samePath($0.entry.path, path, home: home) } }
        let branch = run.branch ?? row?.entry.branch
        guard let name = branch ?? run.worktree.map({ ($0 as NSString).lastPathComponent }), !name.isEmpty else { return nil }
        var place = SubagentWorkplace(name: name, isDirty: row?.isDirty == true, pullRequest: run.pullRequest,
                                      pullRequestState: run.pullRequestState)
        if let read = branch.flatMap({ pullRequests[$0] }) {
            place.pullRequest = read.number
            place.pullRequestState = read.state
        }
        return place
    }
}
