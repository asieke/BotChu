import SwiftUI
import BotChuCore

/// A task's repository's open issues in its Activity, from the saved Projects catalog: GitHub's
/// count in the heading, the few most recently updated, each opening in the Projects sidebar, View
/// All Issues and Refresh. Showing it keeps the catalog current, with a check at most every two
/// minutes through the shared sync.
struct TaskIssuesSection: View {
    @Environment(AppModel.self) private var model
    let repo: String

    var body: some View {
        let preview = model.issuePreview(of: repo)
        InspectorSection(preview.heading, trailing: preview.note, preferenceKey: "Issues", spoken: preview.accessibilityHeading) {
            InspectorCard {
                if preview.issues.isEmpty {
                    placeholder(preview)
                } else {
                    ForEach(Array(preview.issues.enumerated()), id: \.element.id) { index, issue in
                        TaskIssueRow(issue: issue, last: index == preview.issues.count - 1) {
                            model.showIssues(of: repo, number: issue.number)
                        }
                    }
                }
            }
            if let problem = preview.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
                    .help(problem)
            }
            HStack(spacing: 8) {
                if let total = preview.total, total > 0 {
                    Button { model.showIssues(of: repo) } label: {
                        Label(preview.hasMore ? "View All \(total) Issues" : "View All Issues", systemImage: "list.bullet")
                    }
                    .buttonStyle(InspectorButtonStyle(fill: true))
                    .help("Show \(TaskNaming.repoName(repo))'s open issues in Projects")
                    refresh(preview, compact: true)
                } else {
                    refresh(preview, compact: false)
                }
            }
        }
        // A long title truncates rather than asking for a wider sidebar.
        .frame(minWidth: 0, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
        // Before any catalog exists, the window's launch sync is reading it.
        .task(id: repo) { if model.projectsLogin != nil { await model.loadProjects() } }
    }

    /// Beside View All, just its icon.
    @ViewBuilder private func refresh(_ preview: IssuePreview, compact: Bool) -> some View {
        let label = Label(preview.problem == nil ? "Refresh" : "Try Again", systemImage: "arrow.clockwise")
        Button { Task { await model.refreshProjects() } } label: {
            if compact { label.labelStyle(.iconOnly) } else { label }
        }
        .buttonStyle(InspectorButtonStyle(fill: !compact))
        .help("Sync Projects with GitHub")
    }

    @ViewBuilder private func placeholder(_ preview: IssuePreview) -> some View {
        Group {
            switch preview.count {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading issues…")
                }
            case .unavailable:
                Text("Not one of your repositories")
                    .help("gh doesn’t list \(repo) for your GitHub account now")
            case .unknown:
                Text(preview.problem == nil ? "Not read yet" : "Couldn’t read issues")
            case .known(let total):
                Text(total == 0 ? "No open issues" : "GitHub counts \(total) open; none were read")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.secondaryText)
        .lineLimit(2)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }
}

/// An open issue: its number and title, opening it in the Projects sidebar.
private struct TaskIssueRow: View {
    let issue: GitHubLookup.OpenItem
    let last: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("#\(issue.number)")
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
                Text(issue.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .help(issue.title)
        .accessibilityLabel("Issue \(issue.number): \(issue.title)")
        .accessibilityHint("Opens it in Projects")
    }
}
