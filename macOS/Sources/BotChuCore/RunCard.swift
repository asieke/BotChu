import Foundation

/// Where a sub-agent run stands, as its one-line card in the chat shows it (#405; #399, decision 6):
/// Queued → Running → Needs you → PR #n → Merged, Done or Failed.
public enum RunPill: Equatable, Hashable, Sendable {
    case queued, running, needsYou, pullRequest(Int), merged, done, failed

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .needsYou: "Needs you"
        case .pullRequest(let number): "PR #\(number)"
        case .merged: "Merged"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    /// `needsInput`: the run, or one it started, asked the owner something still unanswered.
    public static func of(_ run: SubagentRun, needsInput: Bool) -> RunPill {
        switch run.phase {
        case .failed, .stopped: return .failed
        case _ where needsInput: return .needsYou
        case .queued, .preparing: return .queued
        case .running: return .running
        case .completed:
            if run.pullRequestState == .merged { return .merged }
            if let number = run.pullRequest, run.pullRequestState != .closed { return .pullRequest(number) }
            return .done
        }
    }
}

/// The parts of a sub-agent run's card line besides its pill.
public enum RunCard {
    /// What follows the pill: the branch, or the pull request once it merged.
    public static func detail(_ run: SubagentRun, pill: RunPill) -> String {
        if pill == .merged, let number = run.pullRequest { return "PR #\(number)" }
        return run.branch ?? ""
    }

    /// The bot's name as the card shortens it: its first word (`10x Engineer Bot` → `10x`).
    public static func shortName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
    }

    /// How long it has run, or ran: `45s`, `2m`, `1h 5m`.
    public static func elapsed(_ run: SubagentRun, now: Date = Date()) -> String {
        let start = run.startedAt ?? run.createdAt
        let seconds = max(0, Int((run.finishedAt ?? (run.phase.isActive ? now : run.createdAt)).timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
    }

    /// The runs in `run`'s tree: itself and every run it started, at any depth, among `runs`.
    public static func tree(of run: SubagentRun, among runs: [SubagentRun]) -> Set<UUID> {
        var ids: Set<UUID> = [run.id]
        var grew = true
        while grew {
            grew = false
            for other in runs where !ids.contains(other.id) {
                if let parent = other.parentSubagentID, ids.contains(parent) {
                    ids.insert(other.id)
                    grew = true
                }
            }
        }
        return ids
    }

    /// Whether the run, or one it started, sent a delivery that waits on the owner: `waiting` are the
    /// runs whose unresolved Needs input deliveries its conversation has (`Delivery.runID`).
    public static func needsInput(_ run: SubagentRun, among runs: [SubagentRun], waiting: Set<UUID>) -> Bool {
        guard !waiting.isEmpty else { return false }
        return !tree(of: run, among: runs).isDisjoint(with: waiting)
    }
}
