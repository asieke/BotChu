import AppKit
import SwiftUI
import BotChuCore

/// The Sub-agents tab's Worktrees (#405, #431): the worktrees of the conversation's checkout that
/// no running run works in (finished runs' leftovers, folders gone), each with its branch, a dot
/// when it has changes, its pull request and Remove. A running run's worktree shows on its row;
/// with none left over, the section isn't shown.
struct WorktreesSection: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let monitor: WorktreeMonitor

    var body: some View {
        let running = model.delegation.all.filter { $0.phase.isActive && $0.worktree != nil }
        let rows = WorktreeCleanupPolicy.unowned(monitor.rows, among: running)
        if !rows.isEmpty || monitor.failure != nil {
            InspectorSection("Worktrees", trailing: rows.isEmpty ? nil : "\(rows.count)", preferenceKey: "worktrees") {
                if rows.isEmpty, let failure = monitor.failure {
                    Text(failure.split(whereSeparator: \.isNewline).last.map(String.init) ?? failure)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    InspectorCard {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            WorktreeRowView(row: row, pullRequest: row.entry.branch.flatMap { monitor.pullRequests[$0] },
                                            removing: monitor.removing.contains(row.entry.path), last: index == rows.count - 1) {
                                Task { await monitor.remove(row, model: model, in: target) }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("worktrees-section")
        }
    }
}

/// Reads a checkout's worktrees when the Sub-agents tab appears, when one of the conversation's runs
/// changes phase, and every 30 seconds while one runs, whether or not Worktrees shows.
struct WorktreeRefresh: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let monitor: WorktreeMonitor

    var body: some View {
        let runs = model.delegation.records[target] ?? []
        Color.clear
            .task(id: runs.map { "\($0.id)\($0.phase)" }) {
                await monitor.refresh(model: model, in: target)
                while !Task.isCancelled, (model.delegation.records[target] ?? []).contains(where: { $0.phase.isActive }) {
                    try? await Task.sleep(for: WorktreeMonitor.whileRunning)
                    guard !Task.isCancelled else { return }
                    await monitor.refresh(model: model, in: target)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct WorktreeRowView: View {
    let row: WorktreeRow
    let pullRequest: BranchPullRequest?
    let removing: Bool
    let last: Bool
    let remove: () -> Void
    @State private var hovered = false

    private var name: String { row.entry.branch ?? (row.entry.path as NSString).lastPathComponent }

    var body: some View {
        HStack(spacing: 8) {
            if row.isDirty == true {
                Circle().fill(Palette.warning).frame(width: 7, height: 7)
                    .accessibilityLabel("Changed")
            }
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.entry.isPrunable ? Palette.secondaryText : Palette.text)
            Spacer(minLength: 6)
            if let pullRequest { PullRequestPill(number: pullRequest.number, state: pullRequest.state) }
            if hovered || removing || pullRequest?.state == .merged || pullRequest?.state == .closed {
                Button("Remove", action: remove)
                    .buttonStyle(InspectorButtonStyle())
                    .controlSize(.small)
                    .disabled(removing)
                    .accessibilityIdentifier("worktree-remove-\(name)")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .help(row.entry.path)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.entry.path)]) }
                .disabled(row.entry.isPrunable)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.entry.path, forType: .string)
            }
            Divider()
            Button("Remove", action: remove).disabled(removing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("worktree-\(name)")
    }
}

struct PullRequestPill: View {
    let number: Int
    /// Nil for one only linked to.
    let state: PullRequestState?

    var body: some View {
        DotPill(text: "PR #\(number)", tint: Self.tint(state))
    }

    static func tint(_ state: PullRequestState?) -> Color {
        switch state {
        case .merged: GitHubColors.open
        case .closed: Palette.secondaryText
        case .open, nil: Palette.violet
        }
    }
}

/// A small status capsule with a dot: a run card's state, a pull request.
struct DotPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
        .fixedSize()
    }
}
