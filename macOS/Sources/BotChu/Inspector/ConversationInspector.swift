import AppKit
import SwiftUI
import BotChuCore

/// The inspector's tabs for an area, a task or a job run (#405; #399, decisions 6, 7 and 11).
enum ConversationInspectorTab: String, CaseIterable, Identifiable {
    case repo, subagents, bot

    static let storageKey = "inspector.conversationTab"
    var id: Self { self }

    var title: String {
        switch self {
        case .repo: "Repo"
        case .subagents: "Sub-agents"
        case .bot: "Bot"
        }
    }

    /// Shows a conversation's sub-agents, as a run card's click does: the tab and the inspector.
    @MainActor static func showSubagents(of target: ChatTarget) {
        let defaults = UserDefaults.standard
        if target.taskID == nil {
            defaults.set(InspectorTab.subagents.rawValue, forKey: InspectorTab.storageKey)
        } else {
            defaults.set(ConversationInspectorTab.subagents.rawValue, forKey: storageKey)
        }
        defaults.set(true, forKey: "showsStatus")
    }
}

/// The inspector beside an area's, a task's or a job run's conversation: **Repo** (the repository's
/// overview, issues and pull requests, or the area's folder), **Sub-agents** (the runs it started and
/// the checkout's worktrees) and **Bot** (the bot in this conversation: activity, model, session and
/// memory). Home keeps `BotInspector`.
struct ConversationInspector: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    var body: some View {
        if let task = model.task(target) {
            let tabs: [ConversationInspectorTab] = task.isArea || !task.repo.isEmpty ? ConversationInspectorTab.allCases : [.subagents, .bot]
            ConversationInspectorAreas(target: target, tabs: tabs, running: model.delegation.activeCount(target))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Explicit, so the sidebar's vibrancy doesn't recolor text on the opaque cards.
                .foregroundStyle(Palette.text)
                .background(Palette.sidebar)
        }
    }
}

/// The tab bar and the selected tab. Only this reads which tab is selected (#348).
private struct ConversationInspectorAreas: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ConversationInspectorTab.storageKey) private var selection: ConversationInspectorTab = .repo
    let target: ChatTarget
    let tabs: [ConversationInspectorTab]
    let running: Int

    var body: some View {
        let shown = tabs.contains(selection) ? selection : tabs.first ?? .bot
        VStack(spacing: 0) {
            ConversationTabBar(selection: Binding(get: { shown }, set: { selection = $0 }), tabs: tabs, running: running)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            switch shown {
            case .repo:
                AreaRepoTab(target: target)
            case .subagents:
                InspectorScroller(id: target) {
                    SubagentsInspectorContent(target: target, footer: model.worktreeCheckout(of: target).map {
                        AnyView(WorktreesSection(target: target, checkout: $0).environment(model))
                    })
                }
            case .bot:
                ConversationBotPanel(target: target)
            }
        }
        .onAppear {
            if let tab = DevHooks.conversationTab { selection = tab }
        }
    }
}

private struct ConversationTabBar: View {
    @Binding var selection: ConversationInspectorTab
    let tabs: [ConversationInspectorTab]
    let running: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: ConversationInspectorTab?
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                Button { selection = tab } label: {
                    HStack(spacing: 5) {
                        Text(tab.title)
                        if tab == .subagents, running > 0 {
                            Text(String(running)).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Palette.accent))
                        }
                    }
                    .font(.system(size: 12, weight: selection == tab ? .semibold : .regular))
                    .foregroundStyle(selection == tab ? Palette.text : Palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background {
                        if selection == tab {
                            Capsule().fill(Palette.card)
                                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        } else if hovered == tab {
                            Capsule().fill(Palette.card.opacity(0.45))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tab : nil }
                .accessibilityLabel(tab.title + (tab == .subagents && running > 0 ? ", \(running) running" : ""))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("inspector-area-tab-\(tab.rawValue)")
            }
        }
        .padding(3)
        .background(Capsule().fill(Palette.dynamic(0xE8E6E3, 0x17171B)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector sections")
    }
}

// MARK: Repo

/// A repository's overview, open issues and pull requests, read in place, without starting work
/// (the conversation is where work starts); an issue's menu inserts it in the message. A folder
/// area shows its folder.
private struct AreaRepoTab: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    @State private var tab: ProjectSelection.Tab = .overview
    @State private var opened: Int?

    var body: some View {
        if let task = model.task(target) {
            Group {
                if task.repo.isEmpty || task.area?.kind == .folder {
                    ScrollView {
                        FolderSection(title: "Folder", name: task.area?.name ?? task.title, path: task.checkout, remote: task.isRemote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16))
                    }
                } else if let repo = model.repositories?.first(where: { $0.id.caseInsensitiveCompare(task.repo) == .orderedSame }) {
                    repository(repo, task: task)
                } else if model.repositories == nil, model.repositoriesError == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 24)
                } else {
                    // Not one gh lists (or gh couldn't be read): its checkout.
                    ScrollView {
                        FolderSection(title: "Checkout", name: task.repo, path: task.checkout, remote: task.isRemote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(EdgeInsets(top: 4, leading: 16, bottom: 24, trailing: 16))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: task.repo) {
                guard !task.repo.isEmpty, task.area?.kind != .folder else { return }
                await model.loadProjects()
            }
        }
    }

    @ViewBuilder private func repository(_ repo: GitHubLookup.Repo, task: BotTask) -> some View {
        Picker("Show", selection: Binding(get: { tab }, set: { tab = $0; opened = nil })) {
            Text("Overview").tag(ProjectSelection.Tab.overview)
            Text(repo.openIssues > 0 ? "Issues \(repo.openIssues)" : "Issues").tag(ProjectSelection.Tab.issues)
            Text(repo.openPullRequests > 0 ? "PRs \(repo.openPullRequests)" : "PRs").tag(ProjectSelection.Tab.pulls)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
        Rectangle().fill(Palette.hairline).frame(height: 1)
        Group {
            switch tab {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ProjectOverviewTab(repo: repo, startsWork: false) { tab = $0; opened = nil }
                        FolderButtons(path: task.checkout, remote: task.isRemote)
                    }
                    .padding(16)
                }
            case .issues, .pulls:
                if let opened {
                    WorkDetailView(repo: repo, number: opened, pulls: tab == .pulls, back: { self.opened = nil }, startsWork: false)
                        .id("\(repo.id)#\(opened)")
                } else {
                    workList(repo, pulls: tab == .pulls)
                }
            }
        }
        // What a tab read or opened belongs to its repository.
        .id(repo.id)
    }

    private func workList(_ repo: GitHubLookup.Repo, pulls: Bool) -> some View {
        let items = model.openWork(of: repo.id, pulls: pulls)
        return ScrollView {
            Group {
                if items.isEmpty {
                    Text(pulls ? "No open pull requests" : "No open issues")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    InspectorCard {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ProjectWorkRow(item: item, tasks: [], last: index == items.count - 1, open: { opened = item.number }, conversation: target)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

/// A folder: its name and path, with Show in Finder and Terminal.
private struct FolderSection: View {
    let title: String
    let name: String
    let path: String
    let remote: Bool

    var body: some View {
        InspectorSection(title) {
            InspectorCard(padded: true) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(remote ? path : (path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.pathText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            FolderButtons(path: path, remote: remote)
        }
    }
}

private struct FolderButtons: View {
    let path: String
    let remote: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { FolderActions.reveal(path) } label: { Label("Show in Finder", systemImage: "folder") }
            Button { FolderActions.openInTerminal(path) } label: { Label("Terminal", systemImage: "terminal") }
        }
        .buttonStyle(InspectorButtonStyle(fill: true))
        .disabled(remote || path.isEmpty)
    }
}

@MainActor enum FolderActions {
    static func reveal(_ path: String) {
        let folder = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: folder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    static func openInTerminal(_ path: String) {
        let folder = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: folder),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// An issue or pull request's menu in an area's Repo tab.
struct AreaWorkMenu: View {
    @Environment(AppModel.self) private var model
    let item: GitHubLookup.OpenItem
    let conversation: ChatTarget

    var body: some View {
        Button("Insert in Message") {
            model.insertInMessage("\(item.isPullRequest ? "pull request" : "issue") #\(item.number) (\(item.title))", in: conversation)
        }
        Divider()
        Button("Open on GitHub") { NSWorkspace.shared.open(item.url) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
    }
}

// MARK: Bot

/// The bot in this conversation, as Home's inspector shows it, with this conversation's activity,
/// session and usage; its Session shows a task's branch and folder, and Close Task.
private struct ConversationBotPanel: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    var body: some View {
        if let bot = model.bot(target.botID), let task = model.task(target), let status = model.status(of: target) {
            let machine = model.machineName(task.hostID, fallback: task.hostName)
            InspectorPanel(tabs: [.activity, .model, .session, .memory]) {
                InspectorSection("Status") {
                    AvatarCard(bot: bot, status: status, title: task.area?.name ?? task.jobRun?.jobTitle ?? task.repoName,
                               subtitle: subtitle(for: task, machine: machine), account: task.account, eyebrow: bot.name)
                }
            } content: { tab in
                switch tab {
                case .activity:
                    ContextSection(target: target)
                    if !task.isArea { taskFacts(task, bot: bot, machine: machine) }
                    RunReviewsSection(target: target)
                    InspectorSection("Conversation") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            StatTile(value: "\(status.messageCount)", label: "Messages", tabular: true)
                            StatTile(value: "\(status.toolCallCount)", label: "Tool calls", tabular: true)
                            StatTile(value: status.lastActivity.map(BotInspector.ago) ?? "None yet", label: "Last activity")
                            StatTile(value: task.createdAt.formatted(.dateTime.month(.abbreviated).day()), label: "Started")
                        }
                    }
                case .subagents:
                    EmptyView()
                case .model:
                    InspectorSection("Runs on") {
                        RunsOnCard(settings: task, target: target)
                    }
                    let usageRequest = model.usageRequest(for: task)
                    AccountUsageSection(request: usageRequest, isRunning: model.isRunning(target))
                        .id(usageRequest)
                    ConnectorsSection(target: target)
                case .session:
                    InspectorSection("Session") {
                        SessionCard(session: status.session)
                    }
                    if !task.isArea { workspace(task, machine: machine) }
                case .memory:
                    MemorySection(botID: target.botID)
                }
            } actions: {
                VStack(spacing: 0) {
                    Rectangle().fill(Palette.hairline).frame(height: 1)
                    HStack(spacing: 8) {
                        Spacer()
                        Button("New Session") { model.newSession(target) }
                            .buttonStyle(InspectorButtonStyle(prominent: true))
                            .disabled(model.isRunning(target))
                            .help("Start the next message in a fresh session (⌘K)")
                    }
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .background(Palette.sidebar)
                }
            }
            .readsContext(of: target, in: model)
        }
    }

    private func subtitle(for task: BotTask, machine: String) -> String {
        if let origin = task.jobRun { return JobTasks.when(origin) }
        if task.isArea { return task.area?.kind == .folder ? "Folder" : task.repo }
        var title = task.title == task.repoName ? "" : task.title
        for prefix in ["\(task.repoName) · ", "\(task.repoName) "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
            break
        }
        return [title, task.isRemote ? "on \(machine)" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A task's or job run's: its job or repository, where it works, its issue and review.
    private func taskFacts(_ task: BotTask, bot: Bot, machine: String) -> some View {
        InspectorSection("Task") {
            InspectorCard {
                if let origin = task.jobRun {
                    InspectorRow("Job") {
                        Button(origin.jobTitle) { model.jobs.showHistory(origin.jobID, run: origin.runID) }
                            .buttonStyle(.link)
                            .foregroundStyle(Palette.accent)
                            .disabled(model.jobs.job(origin.jobID) == nil)
                    }
                    InspectorRow("Run", value: JobTasks.when(origin))
                        .help(JobTasks.schedule(origin))
                } else {
                    InspectorRow("Repository", value: task.repo)
                }
                InspectorRow("Machine", last: task.work?.isPullRequest != false && task.review == nil) {
                    Label(machine, systemImage: task.isRemote ? "network" : "laptopcomputer").labelStyle(.titleAndIcon)
                }
                if let work = task.work, !work.isPullRequest {
                    InspectorRow("Issue", last: task.review == nil) {
                        Link(work.title.isEmpty ? "#\(work.number)" : "#\(work.number) \(work.title)", destination: work.url)
                            .foregroundStyle(Palette.accent)
                            .truncationMode(.tail)
                            .help(work.title)
                    }
                }
                if let review = task.review {
                    InspectorRow("Review", value: review == .comment ? "Posted on GitHub" : "In this conversation", last: true)
                }
            }
        }
    }

    /// A task's or job run's branch and folder, opened here or over SSH, and Close Task.
    private func workspace(_ task: BotTask, machine: String) -> some View {
        InspectorSection("Workspace", trailing: task.isRemote ? "on \(machine)" : nil, preferenceKey: "Worktree") {
            InspectorCard {
                if !task.branch.isEmpty {
                    InspectorRow("Branch") {
                        Text(task.branch).font(.system(size: 11.5, design: .monospaced)).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                InspectorRow("Folder", last: true) {
                    let folder = task.folder.map { task.isRemote ? $0 : ($0 as NSString).abbreviatingWithTildeInPath } ?? "—"
                    Text(folder).font(.system(size: 11.5, design: .monospaced)).truncationMode(.head).textSelection(.enabled)
                        .help(task.folder ?? "")
                }
            }
            HStack(spacing: 8) {
                if task.isRemote {
                    Button {
                        if let command = model.sshCommand(for: task) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                    } label: { Label("Copy SSH", systemImage: "doc.on.doc") }
                } else {
                    Button { model.revealWorktree(target) } label: { Label("Show in Finder", systemImage: "folder") }
                }
                Button { model.openWorktreeInTerminal(target) } label: { Label("Terminal", systemImage: "terminal") }
            }
            .buttonStyle(InspectorButtonStyle(fill: true))
            .disabled(task.folder == nil)
            Button("Close Task") { model.closeTask(target) }
                .buttonStyle(InspectorButtonStyle(fill: true))
                .disabled(model.isRunning(target))
                .accessibilityIdentifier("inspector-close-task")
        }
    }
}
