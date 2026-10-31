import AppKit
import SwiftUI
import BotChuCore

/// The repository selected in Projects, on the right: its overview, and its open issues and pull
/// requests, each of which opens in place to read and to start work on. Every start goes through
/// New Task, with the bot, the repository and the work (or a brief) chosen, so its account and
/// workspace can be checked first.
struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model
    let selection: ProjectSelection

    var body: some View {
        VStack(spacing: 0) {
            if let repo = model.repositories?.first(where: { $0.id.caseInsensitiveCompare(selection.repo) == .orderedSame }) {
                ProjectSidebarHeader(repo: repo)
                Picker("Show", selection: Binding(get: { selection.tab }, set: { model.selectProject(selection.repo, tab: $0) })) {
                    Text("Overview").tag(ProjectSelection.Tab.overview)
                    Text(titled("Issues", repo.openIssues)).tag(ProjectSelection.Tab.issues)
                    Text(titled("PRs", repo.openPullRequests)).tag(ProjectSelection.Tab.pulls)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                Rectangle().fill(Palette.hairline).frame(height: 1)
                Group {
                    switch selection.tab {
                    case .overview:
                        ScrollView { ProjectOverviewTab(repo: repo).padding(16) }
                    case .issues, .pulls:
                        if let number = selection.item {
                            WorkDetailView(repo: repo, number: number, pulls: selection.tab == .pulls)
                                .id("\(repo.id)#\(number)")
                        } else {
                            ProjectWorkList(repo: repo, pulls: selection.tab == .pulls)
                        }
                    }
                }
                // What a tab read or opened belongs to its repository.
                .id(repo.id)
            } else if model.repositories == nil {
                ProgressView("Reading your repositories…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Not One of Your Repositories", systemImage: "folder",
                                       description: Text("gh doesn’t list \(selection.repo) for your account now."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.text)
        .background(Palette.sidebar)
    }

    /// "Issues 3", or "Issues" when there are none.
    private func titled(_ title: String, _ count: Int) -> String {
        count > 0 ? "\(title) \(count)" : title
    }
}

extension GitHubLookup.Repo {
    /// The repository's page on GitHub.
    var webURL: URL { URL(string: "https://github.com/\(nameWithOwner)")! }
}

/// The project's name (from PROJECT.md) and repository, with Open on GitHub and Close.
private struct ProjectSidebarHeader: View {
    @Environment(AppModel.self) private var model
    let repo: GitHubLookup.Repo

    var body: some View {
        let metadata = model.projectRecords[repo.id].flatMap { try? $0.metadata(repoName: repo.name) }
        HStack(spacing: 10) {
            Image(systemName: metadata?.kind.symbol ?? "folder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.indigo)
                .frame(width: 34, height: 34)
                .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(metadata?.name ?? repo.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if repo.isPrivate { Image(systemName: "lock.fill").font(.system(size: 8.5)).help("Private repository") }
                    Text(repo.nameWithOwner).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 4)
            Button { NSWorkspace.shared.open(repo.webURL) } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help("Open on GitHub")
            .accessibilityLabel("Open on GitHub")
            Button { model.selectProject(nil) } label: {
                Image(systemName: "xmark")
            }
            .help("Close")
            .accessibilityLabel("Close project sidebar")
        }
        .buttonStyle(.borderless)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 14))
    }
}

/// The project at a glance: its open work, PROJECT.md's metadata, where its tasks work, the tasks
/// on it, and Start Task and Edit Metadata.
struct ProjectOverviewTab: View {
    @Environment(AppModel.self) private var model
    let repo: GitHubLookup.Repo
    /// Start Task with; an area's Repo tab (#405) has none, being the place work starts already.
    var startsWork = true
    /// Shows the open issues or pull requests; Projects' sidebar when nil.
    var show: ((ProjectSelection.Tab) -> Void)?
    @State private var editor: ProjectEditRequest?
    private var location: RepoLocation { model.location(of: repo.nameWithOwner) }
    private var record: ProjectRecord? { model.projectRecords[repo.id] }
    private var metadata: ProjectMetadata? { record.flatMap { try? $0.metadata(repoName: repo.name) } }
    private var parseError: String? {
        do { _ = try record?.metadata(repoName: repo.name); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !repo.description.isEmpty {
                Text(repo.description)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.projectErrors[repo.id] ?? parseError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await model.refreshProjects() } }
                }
                .font(.callout)
            }
            InspectorSection("Open", preferenceKey: "project.open") {
                HStack(spacing: 8) {
                    openTile(repo.openIssues, "issue", tab: .issues)
                    openTile(repo.openPullRequests, "pull request", tab: .pulls)
                }
            }
            InspectorSection("Project", preferenceKey: "project.metadata") {
                InspectorCard {
                    InspectorRow("Type", value: record == nil ? "—" : record?.exists == true ? metadata?.kind.label ?? "Unknown" : "Unclassified")
                    InspectorRow("Status", value: record?.exists == true ? metadata?.status.rawValue.capitalized ?? "Unknown" : "—")
                    InspectorRow("Visibility", value: repo.isPrivate ? "Private" : "Public")
                    InspectorRow("Merges", value: metadata.map { $0.merge == "agent" ? "Agent" : "Owner" } ?? "—")
                    InspectorRow("Deploys", last: true) {
                        Text(metadata?.deploy ?? "—").truncationMode(.middle).textSelection(.enabled).help(metadata?.deploy ?? "")
                    }
                }
            }
            InspectorSection("Workspace", preferenceKey: "project.workspace") {
                InspectorCard {
                    InspectorRow("Works on", value: model.machineName(location.hostID))
                    InspectorRow("Checkout", last: true) {
                        let path = location.hostID == nil ? (location.path as NSString).abbreviatingWithTildeInPath : location.path
                        Text(path).truncationMode(.head).textSelection(.enabled).help(path)
                    }
                }
            }
            let tasks = model.openTasks.filter { $0.task.repo.caseInsensitiveCompare(repo.id) == .orderedSame }
            if !tasks.isEmpty {
                InspectorSection("Tasks", trailing: "\(tasks.count) open", preferenceKey: "project.tasks") {
                    InspectorCard {
                        ForEach(Array(tasks.enumerated()), id: \.element.task.id) { index, pair in
                            ProjectTaskRow(bot: pair.bot, task: pair.task, last: index == tasks.count - 1)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                // With no agent to start a task, the action makes one (#232).
                if !startsWork {
                    EmptyView()
                } else if !model.taskOwners.isEmpty {
                    BotMenu(title: "Start Task with", systemImage: "plus") { model.startInArea(repo: repo.id, with: $0) }
                        .buttonStyle(InspectorButtonStyle(prominent: true, fill: true))
                        .help("Open this repository's area")
                } else {
                    Button { model.newBot() } label: { Label("New Agent…", systemImage: "plus") }
                        .buttonStyle(InspectorButtonStyle(prominent: true, fill: true))
                }
                HStack(spacing: 8) {
                    Button(record?.exists == true ? "Edit Metadata…" : "Add Metadata…") {
                        if let record, let metadata { editor = ProjectEditRequest(record: record, metadata: metadata) }
                    }
                    .disabled(record == nil || parseError != nil || model.projectErrors[repo.id] != nil)
                    Button("Open on GitHub") { NSWorkspace.shared.open(repo.webURL) }
                }
                .buttonStyle(InspectorButtonStyle(fill: true))
            }
        }
        .sheet(item: $editor) { request in
            ProjectMetadataEditor(repo: repo, original: request.record, metadata: request.metadata).environment(model)
        }
    }

    /// How many issues or pull requests are open; shows them.
    private func openTile(_ count: Int, _ noun: String, tab: ProjectSelection.Tab) -> some View {
        Button { if let show { show(tab) } else { model.selectProject(repo.id, tab: tab) } } label: {
            StatTile(value: "\(count)", label: "open \(noun)\(count == 1 ? "" : "s")")
        }
        .buttonStyle(.plain)
        .help("Show the open \(noun)s")
    }
}

/// A repository's open issues or pull requests, as read for Projects (most recently updated first),
/// with Fix All or Review All. Each opens in place.
struct ProjectWorkList: View {
    @Environment(AppModel.self) private var model
    let repo: GitHubLookup.Repo
    let pulls: Bool

    var body: some View {
        let items = model.openWork(of: repo.id, pulls: pulls)
        let total = max(pulls ? repo.openPullRequests : repo.openIssues, items.count)
        let open = model.openTasks
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(total) open \(noun(total))").font(.system(size: 13, weight: .semibold))
                    if !items.isEmpty, items.count < total {
                        Text("The \(items.count) most recently updated").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                    }
                }
                Spacer(minLength: 4)
                if pulls { reviewAll } else { fixAll }
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            if items.isEmpty {
                Group {
                    if total > 0, model.openItems == nil, model.projectsLoading {
                        ProgressView("Reading open \(noun(2))…").controlSize(.small)
                    } else if total > 0 {
                        ContentUnavailableView {
                            Label("Not Read", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(model.openItemsError ?? "GitHub counts \(total) open, but none were read. Refresh to try again.")
                        } actions: {
                            Button("Refresh") { Task { await model.refreshProjects() } }
                        }
                    } else {
                        ContentUnavailableView("No Open \(pulls ? "Pull Requests" : "Issues")", systemImage: "checkmark.circle")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    InspectorCard {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ProjectWorkRow(item: item, tasks: model.tasks(on: item, among: open), last: index == items.count - 1)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16))
                }
            }
        }
    }

    private func noun(_ count: Int) -> String {
        (pulls ? "pull request" : "issue") + (count == 1 ? "" : "s")
    }

    /// One task fixing every issue no task works on yet, each with a parallel sub-agent.
    private var fixAll: some View {
        let ready = model.issuesToFix(in: repo.id).count
        return BotMenu(title: "Fix All", systemImage: "wand.and.stars") { model.fixAllIssues(in: repo.id, with: $0) }
            .buttonStyle(InspectorButtonStyle(prominent: true))
            .fixedSize()
            .disabled(ready == 0)
            .help(ready == 0 ? "Every issue read here has a task already"
                  : "Start one task that fixes \(ready == 1 ? "this issue" : "these \(ready) issues"), each with a parallel sub-agent and pull request of its own")
    }

    /// One task reviewing every pull request no task is reviewing yet, each with a parallel sub-agent.
    private var reviewAll: some View {
        let ready = model.pullRequestsToReview(in: repo.id).count
        return ReviewMenu(title: "Review All") { botID, comment in
            model.reviewAllPullRequests(in: repo.id, with: botID, comment: comment)
        }
        .buttonStyle(InspectorButtonStyle(prominent: true))
        .fixedSize()
        .disabled(ready == 0)
        .help(ready == 0 ? "Every pull request read here is being reviewed already"
              : "Start one task that reviews \(ready == 1 ? "this pull request" : "these \(ready) pull requests"), each with a parallel sub-agent of its own")
    }
}

/// An open issue or pull request in the sidebar's list: what it is, who opened it, when it last
/// changed, its checks and labels, and the bots on it. Its menu is the Projects tables'.
struct ProjectWorkRow: View {
    @Environment(AppModel.self) private var model
    let item: GitHubLookup.OpenItem
    let tasks: [(bot: Bot, task: BotTask)]
    let last: Bool
    /// Opens it; in Projects' sidebar when nil.
    var open: (() -> Void)?
    /// The conversation an area's Repo tab (#405) belongs to: the menu inserts it in its message.
    var conversation: ChatTarget?

    var body: some View {
        Button {
            if let open { open() } else { model.selectProject(item.repo, tab: item.isPullRequest ? .pulls : .issues, item: item.number) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                WorkIcon(isPullRequest: item.isPullRequest, isDraft: item.isDraft)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text("#\(item.number)").monospacedDigit()
                        Text("·")
                        Text(item.author).lineLimit(1)
                        Text("·")
                        Text(RelativeDate.text(item.updatedAt)).lineLimit(1).fixedSize()
                        if item.isPullRequest, item.checks != .none { ChecksIcon(checks: item.checks) }
                        if item.comments > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "bubble.left")
                                Text("\(item.comments)").monospacedDigit()
                            }
                            .help("\(item.comments) comment\(item.comments == 1 ? "" : "s")")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    if item.isDraft || item.fromFork || !item.labels.isEmpty {
                        FlowLayout(spacing: 4, lineSpacing: 4) {
                            if item.isDraft { Tag("Draft") }
                            if item.fromFork { Tag("Fork", systemImage: "tuningfork") }
                            ForEach(item.labels, id: \.name) { LabelChip(label: $0) }
                        }
                    }
                }
                Spacer(minLength: 4)
                if !tasks.isEmpty {
                    Text(tasks.prefix(3).map(\.bot.emoji).joined())
                        .help(tasks.map { "\($0.bot.name): \($0.task.title)" }.joined(separator: "\n"))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .contextMenu {
            if let conversation { AreaWorkMenu(item: item, conversation: conversation) } else { WorkMenu(item: item, tasks: tasks) }
        }
        .accessibilityLabel("\(item.isPullRequest ? "Pull request" : "Issue") \(item.number): \(item.title)")
        .accessibilityHint("Shows it")
    }
}

/// One issue or pull request, read in full: its description and conversation, and for a pull
/// request its branches, checks and changed files; with Fix, or Review and Continue, for any bot,
/// and Delete for an issue.
struct WorkDetailView: View {
    @Environment(AppModel.self) private var model
    let repo: GitHubLookup.Repo
    let number: Int
    let pulls: Bool
    /// Back to the list; Projects' sidebar's when nil.
    var back: (() -> Void)?
    /// Fix, Review and Continue; an area's Repo tab (#405) has none.
    var startsWork = true
    @State private var detail: GitHubLookup.WorkDetail?
    @State private var failure: String?
    @State private var loading = false
    @State private var allChecks = false
    @State private var allFiles = false

    private var key: String { "\(repo.id)#\(number)" }
    /// What Projects read about it already, shown until (and unless) the rest is read.
    private var item: GitHubLookup.OpenItem? { model.openWork(of: repo.id, pulls: pulls).first { $0.number == number } }
    private var work: BotTask.Work { detail?.work ?? item?.work ?? BotTask.Work(number: number, isPullRequest: pulls, repo: repo.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { if let back { back() } else { model.selectProject(repo.id, tab: pulls ? .pulls : .issues) } } label: {
                    Label(pulls ? "Pull Requests" : "Issues", systemImage: "chevron.left")
                }
                .help("Back to the list")
                Spacer()
                let updating = model.updatingIssues.contains(key)
                if loading || updating { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
                    .help("Read it again")
                    .accessibilityLabel("Read it again")
                Button { NSWorkspace.shared.open(work.url) } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Open on GitHub")
                    .accessibilityLabel("Open on GitHub")
                if !pulls {
                    Menu {
                        IssueClosureActions(repo: repo.id, number: number, title: detail?.title ?? item?.title ?? "Issue #\(number)")
                    } label: { Image(systemName: "archivebox") }
                    .menuIndicator(.hidden)
                    .disabled(updating)
                    .help("Archive or mark obsolete; keep it on GitHub")
                    .accessibilityLabel("Archive issue")
                    Button { model.askToDeleteIssue(number, of: repo.id, title: detail?.title ?? item?.title ?? "Issue #\(number)") } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(updating)
                    .help("Delete Issue…")
                    .accessibilityLabel("Delete issue")
                }
            }
            .buttonStyle(.borderless)
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 14))
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    if startsWork { actions }
                    if let failure {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try Again") { Task { await load() } }.disabled(loading)
                        }
                        .font(.callout)
                    }
                    if pulls { pullStatus }
                    description
                    if let detail, pulls {
                        checks(detail)
                        files(detail)
                    }
                    if let detail, !detail.conversation.isEmpty {
                        InspectorSection("Conversation", trailing: "\(detail.conversation.count)", preferenceKey: "project.conversation") {
                            VStack(spacing: 8) {
                                ForEach(Array(detail.conversation.enumerated()), id: \.offset) { _, comment in CommentCard(comment: comment) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .task {
            detail = model.workDetails[key]
            await load()
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let result = await model.workDetailLookup(repo.id, number, pulls)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let read):
            model.workDetails[key] = read
            detail = read
            failure = nil
        case .failure(let error):
            failure = "\(error.step). Is gh installed and signed in?"
        }
    }

    // MARK: Parts

    @ViewBuilder private var heading: some View {
        let title = detail?.title ?? item?.title ?? ""
        let labels = detail?.labels ?? item?.labels ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WorkIcon(isPullRequest: pulls, isDraft: detail?.isDraft ?? item?.isDraft ?? false, state: detail?.state ?? "OPEN")
                Text(title.isEmpty ? "\(pulls ? "Pull request" : "Issue") #\(number)" : title)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                stateTag
                if let opened = detail?.createdAt ?? item?.createdAt {
                    Text("#\(number) · opened \(RelativeDate.text(opened)) by \(detail?.author ?? item?.author ?? "ghost")")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                        .help(opened.formatted(date: .long, time: .shortened))
                }
            }
            if pulls, let head = detail?.head ?? item?.branch {
                HStack(spacing: 4) {
                    Text(head).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    Text(detail?.base ?? "default branch").lineLimit(1)
                    if detail?.fromFork ?? item?.fromFork ?? false { Tag("Fork", systemImage: "tuningfork") }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.pathText)
                .help("Merges \(head) into \(detail?.base ?? "the default branch")")
            }
            if !labels.isEmpty {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(labels, id: \.name) { LabelChip(label: $0) }
                }
            }
        }
    }

    @ViewBuilder private var stateTag: some View {
        switch (pulls, detail?.state ?? "OPEN") {
        case (true, "MERGED"): Tag("Merged", tint: GitHubColors.done, systemImage: "arrow.triangle.merge")
        case (true, "CLOSED"): Tag("Closed", tint: GitHubColors.danger, systemImage: "xmark")
        case (false, "CLOSED"): Tag("Closed", tint: GitHubColors.done, systemImage: "checkmark")
        case (true, _) where detail?.isDraft ?? item?.isDraft ?? false: Tag("Draft", systemImage: "pencil")
        default: Tag("Open", tint: GitHubColors.open, systemImage: pulls ? "arrow.triangle.pull" : "smallcircle.filled.circle")
        }
    }

    /// Start work on it with a bot, or show the tasks already on it.
    @ViewBuilder private var actions: some View {
        let tasks = model.tasks(onNumber: number, pullRequest: pulls, in: repo.id)
        let fromFork = detail?.fromFork ?? item?.fromFork ?? false
        VStack(alignment: .leading, spacing: 8) {
            if pulls {
                HStack(spacing: 8) {
                    ReviewMenu(title: "Review") { botID, comment in
                        model.startInArea(repo: repo.id, work: work, review: comment ? .comment : .review, with: botID)
                    }
                    .buttonStyle(InspectorButtonStyle(prominent: true, fill: true))
                    .help("Review it with an agent, here or also on GitHub")
                    BotMenu(title: "Continue", systemImage: "arrow.triangle.branch") { model.startInArea(repo: repo.id, work: work, with: $0) }
                        .buttonStyle(InspectorButtonStyle(fill: true))
                        .disabled(fromFork)
                        .help(fromFork ? "This pull request comes from a fork: review it instead" : "Work on its branch with an agent")
                }
            } else {
                BotMenu(title: "Fix with", systemImage: "wand.and.stars") { model.startInArea(repo: repo.id, work: work, with: $0) }
                    .buttonStyle(InspectorButtonStyle(prominent: true, fill: true))
                    .help("Ask an agent to fix it in this repository's area")
            }
            if !tasks.isEmpty {
                InspectorCard {
                    ForEach(Array(tasks.enumerated()), id: \.element.task.id) { index, pair in
                        ProjectTaskRow(bot: pair.bot, task: pair.task, last: index == tasks.count - 1)
                    }
                }
            }
        }
    }

    /// Its checks, review and size, as Projects read them, until the rest is read.
    @ViewBuilder private var pullStatus: some View {
        let additions = detail?.additions ?? item?.additions ?? 0
        let deletions = detail?.deletions ?? item?.deletions ?? 0
        InspectorCard {
            InspectorRow("Checks") {
                HStack(spacing: 5) {
                    ChecksIcon(checks: detail?.checksState ?? item?.checks ?? .none)
                    Text(detail?.checksSummary ?? (item?.checks ?? .none).label)
                }
            }
            InspectorRow("Review") { ReviewBadge(decision: detail?.reviewDecision ?? item?.reviewDecision) }
            InspectorRow("Changes", last: true) {
                HStack(spacing: 5) {
                    Text("+\(additions)").foregroundStyle(GitHubColors.open)
                    Text("−\(deletions)").foregroundStyle(GitHubColors.danger)
                    if let detail { Text("· \(detail.changedFiles) file\(detail.changedFiles == 1 ? "" : "s")").foregroundStyle(Palette.secondaryText) }
                }
                .monospacedDigit()
            }
        }
    }

    private var description: some View {
        InspectorSection("Description", preferenceKey: "project.description") {
            InspectorCard(padded: true) {
                if let detail {
                    let body = detail.shownBody
                    if body.isEmpty {
                        Text("No description provided.").italic().foregroundStyle(Palette.secondaryText)
                    } else {
                        MarkdownText(text: body)
                    }
                } else if failure == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading it with gh…").foregroundStyle(Palette.secondaryText)
                    }
                } else {
                    Text("Not read.").foregroundStyle(Palette.secondaryText)
                }
            }
            .font(.system(size: 13))
        }
    }

    @ViewBuilder private func checks(_ detail: GitHubLookup.WorkDetail) -> some View {
        if !detail.checks.isEmpty {
            let shown = allChecks ? detail.checks : Array(detail.checks.prefix(8))
            InspectorSection("Checks", trailing: detail.checksSummary, preferenceKey: "project.checks") {
                InspectorCard {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, check in
                        CheckRow(check: check, last: index == shown.count - 1 && shown.count == detail.checks.count)
                    }
                    if shown.count < detail.checks.count {
                        Button("Show all \(detail.checks.count)") { allChecks = true }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12))
                            .padding(EdgeInsets(top: 7, leading: 12, bottom: 8, trailing: 12))
                    }
                }
            }
        }
    }

    @ViewBuilder private func files(_ detail: GitHubLookup.WorkDetail) -> some View {
        if !detail.files.isEmpty {
            let shown = allFiles ? detail.files : Array(detail.files.prefix(10))
            InspectorSection("Files", trailing: "\(detail.changedFiles) changed", preferenceKey: "project.files") {
                InspectorCard {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, file in
                        FileRow(file: file, last: index == shown.count - 1 && shown.count == detail.files.count)
                    }
                    if shown.count < detail.files.count {
                        Button("Show all \(detail.files.count)") { allFiles = true }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12))
                            .padding(EdgeInsets(top: 7, leading: 12, bottom: 8, trailing: 12))
                    }
                }
            }
        }
    }
}

/// An issue's or pull request's glyph, colored by its state as on GitHub.
struct WorkIcon: View {
    var isPullRequest: Bool
    var isDraft = false
    /// `OPEN`, `CLOSED` or `MERGED`.
    var state = "OPEN"

    var body: some View {
        let (symbol, color): (String, Color) = switch (isPullRequest, state) {
        case (true, "MERGED"): ("arrow.triangle.merge", GitHubColors.done)
        case (true, "CLOSED"): ("arrow.triangle.pull", GitHubColors.danger)
        case (false, "CLOSED"): ("checkmark.circle", GitHubColors.done)
        case (true, _): ("arrow.triangle.pull", isDraft ? GitHubColors.neutral : GitHubColors.open)
        default: ("smallcircle.filled.circle", GitHubColors.open)
        }
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// An open task on the repository: its bot, its title and how it is doing. Opens its conversation.
private struct ProjectTaskRow: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let task: BotTask
    let last: Bool

    var body: some View {
        let target = ChatTarget.task(task.id, of: bot.id)
        let status = model.status(of: target)
        Button { model.show(target) } label: {
            HStack(spacing: 10) {
                Text(bot.emoji).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(status.map { $0.phase == .idle ? bot.name : "\(bot.name) · \($0.label)" } ?? bot.name)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .help("Show \(bot.name)’s task")
    }
}

/// A pull request's check: a GitHub Actions job or a commit status. Opens its page.
private struct CheckRow: View {
    let check: GitHubLookup.WorkDetail.Check
    let last: Bool

    var body: some View {
        Button { if let url = check.url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol.0)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(symbol.1)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(check.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if let workflow = check.workflow {
                        Text(workflow).font(.system(size: 10)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if check.url != nil {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(check.url == nil)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
        .help(check.url == nil ? check.name : "Open \(check.name) on GitHub")
    }

    private var symbol: (String, Color) {
        switch check.state {
        case .failure: ("xmark.circle.fill", GitHubColors.danger)
        case .pending: ("circle.dotted.circle", GitHubColors.attention)
        case .success: ("checkmark.circle.fill", GitHubColors.open)
        case .skipped: ("minus.circle", GitHubColors.neutral)
        }
    }
}

/// A file a pull request changes, with the lines it adds and removes.
private struct FileRow: View {
    let file: GitHubLookup.WorkDetail.File
    let last: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.path)
            Spacer(minLength: 4)
            Text("+\(file.additions)").foregroundStyle(GitHubColors.open)
            Text("−\(file.deletions)").foregroundStyle(GitHubColors.danger)
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
    }
}

/// A comment, or a review with its verdict, in an issue's or pull request's conversation.
private struct CommentCard: View {
    let comment: GitHubLookup.WorkDetail.Comment

    var body: some View {
        InspectorCard(padded: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Avatar(url: GitHubLookup.avatar(login: comment.author), size: 18)
                    Text(comment.author).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let review = comment.review { ReviewStateTag(state: review) }
                    Spacer(minLength: 4)
                    Text(RelativeDate.text(comment.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize()
                        .help(comment.date.formatted(date: .long, time: .shortened))
                }
                let body = GitHubLookup.WorkDetail.shown(comment.body)
                if !body.isEmpty { MarkdownText(text: body).font(.system(size: 13)) }
            }
        }
    }
}

/// A review's verdict, as GitHub words it.
private struct ReviewStateTag: View {
    let state: String

    var body: some View {
        switch state {
        case "APPROVED": Tag("Approved", tint: GitHubColors.open, systemImage: "checkmark")
        case "CHANGES_REQUESTED": Tag("Changes requested", tint: GitHubColors.danger, systemImage: "exclamationmark")
        case "DISMISSED": Tag("Dismissed")
        default: Tag("Reviewed", systemImage: "eye")
        }
    }
}

/// A menu of the agents that can own a task (`taskOwners`), by emoji and name, that does something
/// with the one chosen.
struct BotMenu: View {
    @Environment(AppModel.self) private var model
    let title: String
    var systemImage: String?
    let action: (UUID) -> Void

    var body: some View {
        Menu {
            ForEach(model.taskOwners) { bot in Button("\(bot.emoji) \(bot.name)") { action(bot.id) } }
        } label: {
            MenuLabel(title: title, systemImage: systemImage)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .disabled(model.taskOwners.isEmpty)
    }
}

/// A menu of the agents that can own a task, twice: to review in the conversation only, or also to
/// post the review on GitHub (`true`).
struct ReviewMenu: View {
    @Environment(AppModel.self) private var model
    let title: String
    let action: (UUID, Bool) -> Void

    var body: some View {
        Menu {
            Section("Review with") {
                ForEach(model.taskOwners) { bot in Button("\(bot.emoji) \(bot.name)") { action(bot.id, false) } }
            }
            Section("Review and comment with") {
                ForEach(model.taskOwners) { bot in Button("\(bot.emoji) \(bot.name)") { action(bot.id, true) } }
            }
        } label: {
            MenuLabel(title: title, systemImage: "eye")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .disabled(model.taskOwners.isEmpty)
    }
}

/// A menu button's title, with a chevron that says it opens a menu.
private struct MenuLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.7)
        }
    }
}
