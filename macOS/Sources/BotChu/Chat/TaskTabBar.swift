import SwiftUI
import BotChuCore

/// A bot's conversations as tabs above its chat: its Home, then each open task, then New Task.
/// Shown once the bot has a task.
struct TaskTabBar: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        let shown = model.tab(of: botID)
        HStack(spacing: 4) {
            // Whole titles when they fit, then shorter ones, then a row that scrolls.
            ViewThatFits(in: .horizontal) {
                tabs(shown: shown, titleWidth: 190)
                tabs(shown: shown, titleWidth: 110)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        tabs(shown: shown, titleWidth: 110)
                    }
                    .onChange(of: shown) {
                        // After layout: a tab that was just added has no place to scroll to yet.
                        guard let id = shown.taskID else { return }
                        DispatchQueue.main.async { withAnimation { proxy.scrollTo(id) } }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.newTask(for: botID) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Task (⌘T)")
            .accessibilityLabel("New Task")
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabs(shown: ChatTarget, titleWidth: CGFloat) -> some View {
        HStack(spacing: 2) {
            ConversationTab(target: .home(botID), selected: shown.taskID == nil, titleWidth: titleWidth)
            ForEach(model.openTasks(of: botID)) { task in
                ConversationTab(target: .task(task.id, of: botID), selected: shown.taskID == task.id, titleWidth: titleWidth)
                    .id(task.id)
            }
        }
        .padding(.horizontal, 10)
    }
}

/// One tab: a light for how the conversation is doing, its title, and for a task, a close button.
struct ConversationTab: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let selected: Bool
    /// The widest its title gets before it is shortened in the middle.
    var titleWidth: CGFloat = 190
    @State private var hovering = false

    var body: some View {
        let task = model.task(target)
        let status = model.status(of: target)
        HStack(spacing: 6) {
            light(task: task, status: status)
                .frame(width: 14, height: 14)
            Text(task?.title ?? "Home")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: titleWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if task != nil {
                Button { model.closeTask(target) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering || selected ? 1 : 0)
                .disabled(model.isRunning(target))
                .help(model.isRunning(target) ? "Stop the turn to close the task" : "Close the task; it can be opened again from Home's status")
                .accessibilityLabel("Close \(task?.title ?? "task")")
            }
        }
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.leading, 9)
        .padding(.trailing, task == nil ? 11 : 5)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(selected ? 0.085 : hovering ? 0.045 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { model.show(target) }
        .onHover { hovering = $0 }
        .help(help(task: task, status: status))
        .contextMenu { menu(task: task) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Working, failed, news, a pull request, or just which kind of tab it is.
    @ViewBuilder private func light(task: BotTask?, status: BotStatus?) -> some View {
        if status?.phase.isActive == true {
            ProgressView().controlSize(.mini)
        } else if status?.phase == .failed {
            Circle().fill(Color.red).frame(width: 7, height: 7)
        } else if model.unread.contains(target) {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
        } else if task?.pullRequest != nil {
            Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
        } else {
            Image(systemName: task == nil ? (selected ? "house.fill" : "house") : "arrow.triangle.branch")
                .font(.system(size: 11))
        }
    }

    private func help(task: BotTask?, status: BotStatus?) -> String {
        var lines: [String] = []
        if let task {
            lines.append(task.repo + (task.isRemote ? " on \(model.machineName(task.hostID, fallback: task.hostName))" : "")
                         + (task.branch.isEmpty ? "" : " · \(task.branch)"))
            if let pullRequest = task.pullRequest { lines.append("Pull request #\(pullRequest)") }
        } else {
            lines.append("Home: your conversation with the bot")
        }
        if let status, status.phase != .idle { lines.append(status.phase == .failed ? (status.lastError ?? status.label) : status.label) }
        if model.unread.contains(target) { lines.append("Finished a turn since you last looked") }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private func menu(task: BotTask?) -> some View {
        if let task {
            if let url = task.pullRequestURL {
                Link("Open Pull Request #\(task.pullRequest ?? 0)", destination: url)
            }
            if let work = task.work, !work.isPullRequest {
                Link("Open Issue #\(work.number)", destination: work.url)
            }
            if !task.isRemote {
                Button("Show Worktree in Finder") { model.revealWorktree(target) }
                    .disabled(task.folder == nil)
            }
            Button("Open Worktree in Terminal") { model.openWorktreeInTerminal(target) }
                .disabled(task.folder == nil)
            Divider()
        }
        Button("New Session") { model.newSession(target) }
            .disabled(model.isRunning(target))
        if task != nil {
            Button("Close Task") { model.closeTask(target) }
                .disabled(model.isRunning(target))
        }
    }
}
