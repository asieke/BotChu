import Foundation
import Observation
import BotChuCore

/// A checkout's worktrees for the Sub-agents tab's Worktrees list (#405; #399, decision 7): what
/// `git worktree list` shows with each one's changes, the pull request on each branch (read again
/// after a minute), and removing one. One per checkout, kept while the app runs, so going back to
/// an area shows what was read and the pull requests aren't asked for again within the minute.
@MainActor @Observable
final class WorktreeMonitor {
    private static var monitors: [String: WorktreeMonitor] = [:]

    static func of(_ checkout: String) -> WorktreeMonitor {
        if let known = monitors[checkout] { return known }
        let made = WorktreeMonitor(checkout: checkout)
        monitors[checkout] = made
        return made
    }

    /// How long a branch's pull request is taken as read.
    static let pullRequestsFor: TimeInterval = 60
    /// How often the list is read while a run of the conversation is under way.
    static let whileRunning: Duration = .seconds(30)

    let checkout: String
    private(set) var rows: [WorktreeRow] = []
    private(set) var pullRequests: [String: BranchPullRequest] = [:]
    /// Worktrees being removed, by path.
    private(set) var removing: Set<String> = []
    /// Why the list couldn't be read, last time.
    private(set) var failure: String?
    private(set) var isRead = false
    @ObservationIgnored private var readAt: [String: Date] = [:]
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// Worktrees BotChu failed to remove by itself: not tried again by itself.
    @ObservationIgnored private var failedCleanups: Set<String> = []

    private init(checkout: String) {
        self.checkout = checkout
    }

    /// Reads the list and the pull requests not read within the minute, then removes each worktree
    /// the cleanup policy allows. A read asked for during one waits for it rather than starting another.
    func refresh(model: AppModel, in target: ChatTarget) async {
        if let reading { return await reading.value }
        let task = Task { await read(model: model, target: target) }
        reading = task
        await task.value
        reading = nil
    }

    private func read(model: AppModel, target: ChatTarget) async {
        let listed = await Machine.thisMac.script(WorktreeStatus.script(checkout: checkout), in: checkout)
        guard listed.ok else {
            let message = listed.report("git worktree list")
            if failure != message { failure = message }
            isRead = true
            return
        }
        if failure != nil { failure = nil }
        let read = WorktreeStatus.parse(listed.output)
        if rows != read { rows = read }
        isRead = true

        let branches = Set(read.filter { !$0.entry.isMain }.compactMap(\.entry.branch))
        let now = Date()
        let stale = branches.filter { readAt[$0].map { now.timeIntervalSince($0) >= Self.pullRequestsFor } ?? true }.sorted()
        var found = pullRequests.filter { branches.contains($0.key) }
        if !stale.isEmpty {
            let asked = await Machine.thisMac.script(WorktreeStatus.pullRequestsScript, arguments: stale, in: checkout)
            if asked.ok {
                let answered = WorktreeStatus.parsePullRequests(asked.output)
                for branch in stale {
                    found[branch] = answered[branch]
                    readAt[branch] = now
                }
            }
        }
        readAt = readAt.filter { branches.contains($0.key) }
        if pullRequests != found { pullRequests = found }

        let busy = model.busyWorktrees()
        for row in read where !failedCleanups.contains(row.entry.path) {
            let owned = busy.contains { WorktreeCleanupPolicy.samePath($0, row.entry.path) }
            guard WorktreeCleanupPolicy.removes(row, pullRequest: row.entry.branch.flatMap { found[$0] }, isOwned: owned) else { continue }
            await remove(row, model: model, in: target, cleaningUp: true)
        }
    }

    /// `git worktree remove`, never forced: a worktree with changes stays, and the conversation gets
    /// a note with what git said. Cleaning up, its local branch goes too, and git forgets worktrees
    /// whose folders are gone.
    func remove(_ row: WorktreeRow, model: AppModel, in target: ChatTarget, cleaningUp: Bool = false) async {
        let path = row.entry.path
        guard WorktreeCleanupPolicy.canRemove(row.entry), removing.insert(path).inserted else { return }
        defer { removing.remove(path) }
        let result = await TaskWorktree.remove(path, checkout: checkout)
        guard result.ok else {
            if cleaningUp { failedCleanups.insert(path) }
            let said = [result.errors, result.output].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                ?? "git exited with \(result.status)"
            model.note("Couldn't remove the worktree \(row.entry.branch ?? (path as NSString).lastPathComponent): \(said)", in: target)
            return
        }
        if cleaningUp, let branch = row.entry.branch {
            _ = await Machine.thisMac.run(["git", "branch", "-D", branch], in: checkout)
            _ = await Machine.thisMac.run(["git", "worktree", "prune"], in: checkout)
        }
        rows.removeAll { $0.id == row.id }
    }
}

extension AppModel {
    /// The worktrees something works in now: a running sub-agent run's (its `worktree`), or an open
    /// task's folder on this Mac. The cleanup leaves them alone.
    func busyWorktrees() -> [String] {
        delegation.all.filter { $0.phase.isActive }.compactMap(\.worktree)
            + openTasks.compactMap { $0.task.isRemote ? nil : $0.task.folder }
    }

    /// The checkout whose worktrees a conversation's Sub-agents tab lists: a repository area's, or a
    /// task's on this Mac; nil for Home, folder areas and job runs.
    func worktreeCheckout(of target: ChatTarget) -> String? {
        guard let task = task(target), !task.isRemote, !task.repo.isEmpty, task.area?.kind != .folder, task.jobRun == nil,
              !task.checkout.isEmpty else { return nil }
        return (task.checkout as NSString).expandingTildeInPath
    }

    /// Puts `text` at the end of what the conversation's message box holds.
    func insertInMessage(_ text: String, in target: ChatTarget) {
        let draft = drafts[target] ?? ""
        drafts[target] = draft.isEmpty || draft.last?.isWhitespace == true ? draft + text : draft + " " + text
    }
}
