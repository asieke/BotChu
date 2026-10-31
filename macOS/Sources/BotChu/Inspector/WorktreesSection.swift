import AppKit
import SwiftUI
import BotChuCore

/// The Sub-agents tab's Worktrees (#405; #399, decision 7): every worktree of the conversation's
/// checkout, with its branch, a dot when it has changes, its pull request, the running run that
/// works in it and Remove. Read when it appears, when one of the conversation's runs changes phase,
/// and every 30 seconds while one runs.
struct WorktreesSection: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let checkout: String
    @State private var monitor: WorktreeMonitor

    init(target: ChatTarget, checkout: String) {
        self.target = target
        self.checkout = checkout
        _monitor = State(initialValue: WorktreeMonitor.of(checkout))
    }

    var body: some View {
        let runs = model.delegation.records[target] ?? []
        let running = model.delegation.all.filter { $0.phase.isActive && $0.worktree != nil }
        InspectorSection("Worktrees", trailing: monitor.rows.isEmpty ? nil : "\(monitor.rows.count)", preferenceKey: "worktrees") {
            if monitor.rows.isEmpty {
                Group {
                    if let failure = monitor.failure {
                        Text(failure.split(whereSeparator: \.isNewline).last.map(String.init) ?? failure)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    } else if !monitor.isRead {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.system(size: 12))
            } else {
                InspectorCard {
                    ForEach(Array(monitor.rows.enumerated()), id: \.element.id) { index, row in
                        WorktreeRowView(row: row, pullRequest: row.entry.branch.flatMap { monitor.pullRequests[$0] },
                                        owner: WorktreeCleanupPolicy.owner(of: row.entry.path, among: running),
                                        removing: monitor.removing.contains(row.entry.path), last: index == monitor.rows.count - 1) {
                            Task { await monitor.remove(row, model: model, in: target) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("worktrees-section")
        .task(id: runs.map { "\($0.id)\($0.phase)" }) {
            await monitor.refresh(model: model, in: target)
            while !Task.isCancelled, (model.delegation.records[target] ?? []).contains(where: { $0.phase.isActive }) {
                try? await Task.sleep(for: WorktreeMonitor.whileRunning)
                guard !Task.isCancelled else { return }
                await monitor.refresh(model: model, in: target)
            }
        }
    }
}

private struct WorktreeRowView: View {
    let row: WorktreeRow
    let pullRequest: BranchPullRequest?
    let owner: SubagentRun?
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
            if let owner { RunOwnerAvatar(run: owner) }
            if row.entry.isMain {
                Text("Checkout").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            } else {
                if let pullRequest { PullRequestPill(pullRequest: pullRequest) }
                if hovered || removing || pullRequest?.state == .merged || pullRequest?.state == .closed {
                    Button("Remove", action: remove)
                        .buttonStyle(InspectorButtonStyle())
                        .controlSize(.small)
                        .disabled(removing || owner != nil)
                        .accessibilityIdentifier("worktree-remove-\(name)")
                }
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
            if !row.entry.isMain {
                Divider()
                Button("Remove", action: remove).disabled(removing || owner != nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("worktree-\(name)")
    }
}

/// The running run working in a worktree.
private struct RunOwnerAvatar: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun

    var body: some View {
        BotAvatar(bot: model.bot(run.targetBotID) ?? Bot(id: run.targetBotID, name: run.targetBotName, emoji: run.targetBotEmoji,
                                                          workspace: run.targetBotWorkspace, appearance: run.targetBotAppearance),
                  size: 16)
            .help("\(run.targetBotName): \(run.title)")
            .accessibilityLabel(run.targetBotName)
    }
}

struct PullRequestPill: View {
    let pullRequest: BranchPullRequest

    var body: some View {
        DotPill(text: "PR #\(pullRequest.number)", tint: Self.tint(pullRequest.state))
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
