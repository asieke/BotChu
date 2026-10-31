import Foundation

/// One worktree of a checkout, as `git worktree list --porcelain` lists it.
public struct WorktreeEntry: Equatable, Hashable, Sendable {
    public var path: String
    /// Without `refs/heads/`; nil for a detached or bare one.
    public var branch: String?
    /// The commit it is on; nil for a bare repository.
    public var head: String?
    /// The checkout the others were made from, which git lists first.
    public var isMain: Bool
    public var isDetached: Bool
    /// Its folder is gone, so `git worktree prune` would forget it.
    public var isPrunable: Bool
    public var isLocked: Bool

    public init(path: String, branch: String? = nil, head: String? = nil, isMain: Bool = false, isDetached: Bool = false,
                isPrunable: Bool = false, isLocked: Bool = false) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isMain = isMain
        self.isDetached = isDetached
        self.isPrunable = isPrunable
        self.isLocked = isLocked
    }
}

/// A checkout's worktrees (#401), for the Sub-agents tab's list (#399, decision 7).
public enum WorktreeList {
    /// What `git worktree list --porcelain` printed, main checkout first, as git lists it.
    public static func parse(porcelain: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        func close() {
            if var entry = current {
                entry.isMain = entries.isEmpty
                entries.append(entry)
            }
            current = nil
        }
        for line in porcelain.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let (key, value) = line.firstIndex(of: " ").map { (line[..<$0], String(line[line.index(after: $0)...])) } ?? (line[...], "")
            switch key {
            case "worktree":
                close()
                current = WorktreeEntry(path: value)
            case "HEAD":
                current?.head = value
            case "branch":
                current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "detached":
                current?.isDetached = true
            case "prunable":
                current?.isPrunable = true
            case "locked":
                current?.isLocked = true
            case "":
                close()
            default:
                continue
            }
        }
        close()
        return entries
    }

    /// A POSIX `sh` script that lists `checkout`'s worktrees, here or on a host (`Machine.script`).
    public static func script(checkout: String) -> String {
        "git -C \(Machine.remotePath(checkout)) worktree list --porcelain"
    }

    /// Whether `git status --porcelain` printed nothing: no change, staged or not, and no untracked
    /// file, so `git worktree remove` takes it without `--force`.
    public static func isClean(statusPorcelain: String) -> Bool {
        statusPorcelain.allSatisfy(\.isWhitespace)
    }
}
