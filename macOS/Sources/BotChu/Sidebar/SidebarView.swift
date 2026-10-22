import SwiftUI
import BotChuCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Bot?
    @State private var expansion = SidebarExpansion()

    var body: some View {
        List(selection: Binding<SidebarDestination?>(
            get: { model.sidebarSelection },
            set: { value in
                guard let value else { return }
                expansion.reveal(value)
                model.selectSidebar(value)
            })) {
            Section("Workspace") {
                ForEach(LibraryDestination.allCases, id: \.self) { destination in
                    Label(destination.title, systemImage: destination.symbol).tag(SidebarDestination.library(destination))
                }
            }
            Section("Conversations") {
                ForEach(model.bots) { bot in
                    let expanded = expansion.botIDs.contains(bot.id)
                    BotRow(bot: bot, status: model.status(of: bot), selected: model.visibleBotID == bot.id,
                           unread: model.unreadCount(of: bot.id), runningTasks: model.runningTaskCount(for: bot.id),
                           openTasks: model.openTasks(of: bot.id).count, isExpanded: expanded,
                           onToggleExpand: { expansion.toggle(bot.id) })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            expansion.reveal(.botHome(bot.id))
                            model.show(.home(bot.id))
                        }
                        .tag(SidebarDestination.botHome(bot.id))
                        .accessibilityIdentifier("sidebar-home-\(bot.id)")
                        .contextMenu {
                            Button("Edit…") { model.edit(bot.id) }
                            Button("New Task…") { model.newTask(for: bot.id) }
                            Button("New Session") { model.newSession(.home(bot.id)) }
                                .disabled(model.isRunning(.home(bot.id)))
                            Button("Show Workspace in Finder") { model.revealWorkspace(bot.id) }
                            Divider()
                            Button("Delete…", role: .destructive) { pendingDelete = bot }
                        }
                    if expanded {
                        ForEach(model.openTasks(of: bot.id)) { task in
                            SidebarTaskRow(botID: bot.id, task: task)
                                .modifier(SidebarTreeBranch())
                                .tag(SidebarDestination.botTask(botID: bot.id, taskID: task.id))
                        }
                        SidebarNewTaskRow(botID: bot.id)
                            .modifier(SidebarTreeBranch(isLast: true))
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.sidebarStructure, initial: true) { _, structure in expansion.update(structure) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { model.newBot() } label: {
                    Label("New Bot", systemImage: "plus")
                }
                .help("New Bot (⌘N)")
                Spacer()
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Settings (⌘,)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "bot")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { bot in
            Button("Delete", role: .destructive) { model.delete(bot.id) }
        } message: { bot in
            Text("Its conversation and tasks are deleted. Its workspace folder, \(bot.workspace), and its tasks' worktrees are kept.")
        }
    }
}

/// The guide runs through adjoining rows, ending beside New task.
struct SidebarTreeBranch: ViewModifier {
    var isLast = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, 27)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.12))
                    .frame(width: 1.5)
                    .padding(.leading, 14)
                    .padding(.top, -5)
                    .padding(.bottom, isLast ? 12 : -5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

struct BotRow: View {
    let bot: Bot
    let status: BotStatus
    let selected: Bool
    /// Conversations (Home or tasks) that finished a turn since they were last shown.
    var unread = 0
    var runningTasks = 0
    var openTasks = 0
    var isExpanded = false
    var onToggleExpand: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            // Only the selected bot and busy ones move, so a long list stays calm.
            BotAvatar(bot: bot, size: 30, activity: status.activity, animates: selected || status.activity != .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(runningTasks > 0 ? AnyShapeStyle(Color.accentColor)
                                     : status.phase == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if status.phase.isActive {
                SidebarActivitySpinner(color: .secondary).frame(width: 14, height: 14)
            }
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.accentColor))
                    .help(unread == 1 ? "1 conversation has news" : "\(unread) conversations have news")
            }
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Collapse tasks" : "Expand tasks")
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") tasks for \(bot.name)")
            .accessibilityIdentifier("sidebar-disclosure-\(bot.id)")
        }
        .padding(.vertical, 3)
    }

    var subtitle: String {
        if runningTasks > 0 { return "\(runningTasks) task\(runningTasks == 1 ? "" : "s") running" }
        if status.phase.isActive || status.phase == .failed { return status.label }
        if openTasks > 0 { return "\(openTasks) open task\(openTasks == 1 ? "" : "s")" }
        return bot.account.name
    }
}

struct SidebarTaskRow: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let task: BotTask
    @State private var hovering = false

    private var target: ChatTarget { .task(task.id, of: botID) }
    private var selected: Bool { model.sidebarSelection == .botTask(botID: botID, taskID: task.id) }

    var body: some View {
        let status = model.status(of: target)
        Group {
            if status?.phase.isActive == true {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    row(status: status, now: context.date)
                }
            } else {
                row(status: status, now: .now)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { model.show(target) }
        .help(help(status: status))
        .contextMenu { menu }
        .accessibilityIdentifier("sidebar-task-\(task.id)")
    }

    private func row(status: BotStatus?, now: Date) -> some View {
        HStack(spacing: 7) {
            light(status: status)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Text(Self.subtitle(task: task, status: status, now: now))
                    .font(.system(size: 11))
                    .truncationMode(.middle)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.closeTask(target) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering || selected ? 1 : 0)
            .disabled(model.isRunning(target))
            .help(model.isRunning(target) ? "Stop the turn to close the task" : "Close the task; reopen it from Home’s status")
            .accessibilityLabel("Close \(task.title)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(selected ? 0.12 : hovering ? 0.05 : 0))
        }
    }

    @ViewBuilder private func light(status: BotStatus?) -> some View {
        if status?.phase.isActive == true {
            SidebarActivitySpinner(color: selected ? .purple : .secondary)
        } else if status?.phase == .failed {
            Circle().fill(Color.red).frame(width: 7, height: 7)
        } else if model.unread.contains(target) {
            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
        } else {
            Image(systemName: "circle.dashed").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    static func subtitle(task: BotTask, status: BotStatus?, now: Date) -> String {
        var parts = [task.work.map { "#\($0.number)" } ?? "Task"]
        if let status {
            parts.append(status.phase.isActive && status.phase != .preparing ? status.activity.doing : status.label)
            if status.phase.isActive, let start = status.runStartedAt {
                parts.append(BotStatus.formatElapsed(from: start, to: now))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func help(status: BotStatus?) -> String {
        var lines = [task.repo + (task.isRemote ? " on \(model.machineName(task.hostID, fallback: task.hostName))" : "")]
        if let status, status.phase != .idle { lines.append(status.lastError ?? status.label) }
        if model.unread.contains(target) { lines.append("Finished a turn since you last looked") }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var menu: some View {
        if let work = task.work {
            Link("Open \(work.isPullRequest ? "Pull Request" : "Issue") #\(work.number)", destination: work.url)
        }
        if let number = task.pullRequest, let url = task.pullRequestURL, task.work?.isPullRequest != true {
            Link("Open Pull Request #\(number)", destination: url)
        }
        if !task.branch.isEmpty {
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.branch, forType: .string)
            }
        }
        if !task.isRemote {
            Button("Show Task Folder in Finder") { model.revealWorktree(target) }
                .disabled(task.folder == nil)
        }
        Button("Open Task in Terminal") { model.openWorktreeInTerminal(target) }
            .disabled(task.folder == nil)
        Divider()
        Button("New Session") { model.newSession(target) }
            .disabled(model.isRunning(target))
        Button("Close Task") { model.closeTask(target) }
            .disabled(model.isRunning(target))
    }
}

struct SidebarNewTaskRow: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        Button { model.newTask(for: botID) } label: {
            Label("New task", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("New Task (⌘T)")
        .accessibilityIdentifier("sidebar-new-task-\(botID)")
    }
}

/// AppKit's indeterminate ProgressView ignores tint; draw the small task spinner in its status color.
private struct SidebarActivitySpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            Circle()
                .trim(from: 0.1, to: 0.82)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) * 300))
                .padding(1)
        }
        .accessibilityLabel("Working")
    }
}
