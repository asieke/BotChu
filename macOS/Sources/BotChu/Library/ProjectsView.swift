import AppKit
import SwiftUI
import BotChuCore

/// The owner's repositories in a sortable table (or a gallery), after GitChu's: where each deploys,
/// its open issues and pull requests, PROJECT.md's type and merge policy, where its tasks work and
/// how many are open; and the open pull requests and issues across them, to review or work on. The
/// repository selected shows in a sidebar on the right (`ProjectSidebar`).
struct ProjectsView: View {
    enum Scope: String { case repositories, pulls, issues }

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("projectsScope") private var scope = Scope.repositories
    /// Gallery or table; a new key, so the table is where everyone starts.
    @AppStorage("projectsLayoutV2") private var layout = "table"
    /// Which statuses the repositories show: active ones, unless chosen otherwise.
    @AppStorage("projectsStatus") private var status = ProjectStatusFilter.active
    @State private var query = ""
    @State private var category = "all"
    /// The repository the pull request and issue tables show, or nil for all.
    @State private var repoFilter: String?

    private var rows: [ProjectRow] {
        ProjectRow.rows(repos: model.repositories ?? [], records: model.projectRecords, errors: model.projectErrors, chosen: model.settings.repoLocations,
                        thisMac: model.settings.thisMacName, hosts: model.settings.hosts, reposRoot: model.settings.expandedReposRoot,
                        taskRepos: model.openTasks.map(\.task.repo))
        .filter { row in
            let kind = row.metadata?.kind
            return (category == "all" || category == "docs" && kind == .docs || category == "code" && kind != nil && kind != .docs)
                && status.includes(row) && row.matches(query)
        }
    }

    private func items(pulls: Bool) -> [GitHubLookup.OpenItem] {
        (model.openItems ?? []).filter { item in
            item.isPullRequest == pulls && (repoFilter == nil || item.repo == repoFilter)
                && query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
                    [item.title, item.repo, "#\(item.number)", item.author, item.branch ?? ""].contains { $0.localizedCaseInsensitiveContains(word) }
                        || item.labels.contains { $0.name.localizedCaseInsensitiveContains(word) }
                }
        }
    }

    private var loading: Bool { model.repositoriesLoading || model.projectsLoading || model.openItemsLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Projects", subtitle: "Your repositories, their open pull requests and issues, and where they work.",
                           count: scope == .repositories && model.repositories != nil ? rows.count : model.repositories?.count) {
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await model.refreshProjects() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(loading)
            }
            // One row when it fits; in a narrow window, the search goes on a row of its own.
            ViewThatFits(in: .horizontal) {
                HStack { scopePicker; search.frame(minWidth: 160); filters }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { scopePicker; Spacer(minLength: 8); filters }
                    search
                }
            }.padding(.horizontal, 24).padding(.bottom, 16)
            if let error = model.repositoriesError ?? (scope == .repositories ? nil : model.openItemsError) {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("GitHub Settings") { openSettings() }
                }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            }
            switch scope {
            case .repositories: repositories
            case .pulls, .issues: work(pulls: scope == .pulls)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Projects")
        .task { await model.loadProjects() }
        .task { await model.loadRepositories(); await model.loadOpenWork() }
        // The selected repository; closing the sidebar deselects it.
        .inspector(isPresented: Binding(get: { model.projectSelection != nil }, set: { if !$0 { model.selectProject(nil) } })) {
            Group {
                if let selection = model.projectSelection { ProjectSidebar(selection: selection) }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        }
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            Text("Repositories").tag(Scope.repositories)
            Text(count("Pull Requests", model.repositories?.reduce(0) { $0 + $1.openPullRequests })).tag(Scope.pulls)
            Text(count("Issues", model.repositories?.reduce(0) { $0 + $1.openIssues })).tag(Scope.issues)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private var search: some View {
        LibrarySearch(text: $query, prompt: scope == .repositories ? "Search projects" : scope == .pulls ? "Search pull requests" : "Search issues")
    }

    @ViewBuilder private var filters: some View {
        if scope == .repositories {
            Picker("Status", selection: $status) {
                Text(ProjectStatusFilter.active.label).tag(ProjectStatusFilter.active)
                Text(ProjectStatusFilter.all.label).tag(ProjectStatusFilter.all)
                Divider()
                ForEach([ProjectStatusFilter.paused, .maintenance, .deprecated, .unclassified], id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().fixedSize().help("Show projects by the status in their PROJECT.md")
            Picker("Project kind", selection: $category) {
                Text("All projects").tag("all")
                Text("Code").tag("code")
                Text("Non-code").tag("docs")
            }.labelsHidden().fixedSize()
            LibraryLayoutPicker(layout: $layout)
        } else {
            Picker("Repository", selection: $repoFilter) {
                Text("All repositories").tag(String?.none)
                Divider()
                ForEach(reposWithWork(pulls: scope == .pulls), id: \.self) { Text(TaskNaming.repoName($0)).tag(String?.some($0)) }
            }.labelsHidden().frame(maxWidth: 170).fixedSize()
        }
    }

    private func count(_ title: String, _ value: Int?) -> String {
        guard let value, value > 0 else { return title }
        return "\(title) \(value)"
    }

    private func reposWithWork(pulls: Bool) -> [String] {
        var seen = Set<String>()
        let names = (model.openItems ?? []).filter { $0.isPullRequest == pulls }.map(\.repo).filter { seen.insert($0).inserted }
        return (names + [repoFilter].compactMap { $0 }.filter { !seen.contains($0) }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @ViewBuilder private var repositories: some View {
        let rows = rows
        if model.repositories == nil && (model.repositoriesLoading || model.projectsLoading) {
            LibraryEmpty(title: "Loading projects", subtitle: "Reading repositories with your GitHub CLI login.", symbol: "arrow.triangle.2.circlepath")
        } else if rows.isEmpty, status != .all, model.projectsLoading {
            // Statuses come from PROJECT.md, read after the repositories: none is known to match yet.
            LibraryEmpty(title: "Loading projects", subtitle: "Reading each repository’s PROJECT.md for its status.", symbol: "arrow.triangle.2.circlepath")
        } else if rows.isEmpty, status != .all, model.repositories?.isEmpty == false {
            ContentUnavailableView {
                Label(status == .unclassified ? "No unclassified projects" : "No \(status.label.lowercased()) projects", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(query.isEmpty && category == "all" ? "No repository’s PROJECT.md gives it this status." : "Try another search, kind or status.")
            } actions: {
                Button("Show All Statuses") { status = .all }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            LibraryEmpty(title: model.repositories?.isEmpty == false ? "No matching projects" : "No projects yet",
                         subtitle: model.repositories?.isEmpty == false ? "Try another search or project kind." : "Connect gh in Settings, then refresh to see your repositories.", symbol: "folder")
        } else if layout == "table" {
            ProjectsTable(rows: rows)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                    ForEach(rows) { row in
                        Button { model.selectProject(row.id) } label: { projectCard(row, selected: model.projectSelection?.repo == row.id) }
                            .buttonStyle(.plain)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder private func work(pulls: Bool) -> some View {
        let items = items(pulls: pulls)
        let kind = pulls ? "pull requests" : "issues"
        if items.isEmpty {
            if model.openItems == nil && (model.openItemsLoading || model.repositoriesLoading) {
                LibraryEmpty(title: "Loading open \(kind)", subtitle: "Reading them with your GitHub CLI login.", symbol: "arrow.triangle.2.circlepath")
            } else if !query.isEmpty || repoFilter != nil {
                ContentUnavailableView {
                    Label("No matching \(kind)", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    // The search covers only what was read; say so when that isn't everything.
                    Text("Nothing open matches the search\(repoFilter.map { " in \(TaskNaming.repoName($0))" } ?? "")."
                         + (truncation(pulls: pulls).map { "\n\n" + $0 } ?? ""))
                } actions: {
                    Button("Show All") { query = ""; repoFilter = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryEmpty(title: "Nothing open", subtitle: "No open \(kind) in your repositories.", symbol: "checkmark.circle")
            }
        } else {
            WorkTable(items: items, pulls: pulls)
            if let note = truncation(pulls: pulls) {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 8)
            }
        }
    }

    /// The repositories with more open pull requests or issues than were read, when any are shown.
    private func truncation(pulls: Bool) -> String? {
        let read = Dictionary(grouping: (model.openItems ?? []).filter { $0.isPullRequest == pulls }, by: \.repo).mapValues(\.count)
        let cut = (model.repositories ?? []).filter { repo in
            (repoFilter == nil || repo.id == repoFilter) && (pulls ? repo.openPullRequests : repo.openIssues) > (read[repo.id] ?? 0)
        }
        guard !cut.isEmpty else { return nil }
        return "Showing the most recently updated \(pulls ? "pull requests" : "issues") of \(cut.map(\.name).joined(separator: ", ")). Open \(cut.count == 1 ? "it" : "them") on GitHub for the rest."
    }

    private func projectCard(_ row: ProjectRow, selected: Bool) -> some View {
        let repo = row.repo, metadata = row.metadata
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                LibraryIcon(symbol: metadata?.kind.symbol ?? "folder", color: .indigo)
                Spacer()
                if repo.isPrivate { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Private repository") }
                Text(metadata?.status.rawValue.capitalized ?? "Unclassified").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(metadata?.name ?? repo.name).font(.title3.weight(.semibold)).lineLimit(1)
                Text(repo.nameWithOwner).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(repo.description.isEmpty ? "Add a purpose to this project on GitHub." : repo.description)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(height: 36, alignment: .topLeading)
            }
            Divider()
            HStack(spacing: 10) {
                Text(metadata?.kind.label ?? "No project record").font(.caption)
                Spacer()
                CountView(value: repo.openIssues, systemImage: "smallcircle.filled.circle", tint: GitHubColors.open).font(.caption)
                    .help("\(repo.openIssues) open issues")
                CountView(value: repo.openPullRequests, systemImage: "arrow.triangle.pull", tint: GitHubColors.open).font(.caption)
                    .help("\(repo.openPullRequests) open pull requests")
                if model.projectErrors[repo.id] != nil { Image(systemName: "exclamationmark.triangle").help("Metadata could not be refreshed") }
                Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).libraryCard()
        .overlay { if selected { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("\(metadata?.name ?? repo.name), \(metadata?.kind.label ?? "unclassified"). Show project")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A table's column choices (shown, order, widths), saved between launches.
private struct SavedColumns<Row: Identifiable>: DynamicProperty {
    @AppStorage private var data: Data
    init(_ key: String) { _data = AppStorage(wrappedValue: Data(), key) }
    var customization: TableColumnCustomization<Row> {
        get { (try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data)) ?? TableColumnCustomization() }
        nonmutating set { data = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

/// The repositories, one row each, sortable by any column. Selecting one shows it in the sidebar;
/// its counts open the sidebar's Issues or PRs.
struct ProjectsTable: View {
    @Environment(AppModel.self) private var model
    var rows: [ProjectRow]
    @State private var sortOrder = [KeyPathComparator(\ProjectRow.pushedKey, order: .reverse)]
    private let columns = SavedColumns<ProjectRow>("projectsColumns")

    var body: some View {
        let sorted = rows.sorted(using: sortOrder)
        let tasks = Dictionary(grouping: model.openTasks) { $0.task.repo.lowercased() }
        let selection = Binding<ProjectRow.ID?>(get: { model.projectSelection?.repo }, set: { model.selectProject($0) })
        Table(sorted, selection: selection, sortOrder: $sortOrder, columnCustomization: Binding(get: { columns.customization }, set: { columns.customization = $0 })) {
            TableColumn("Repository", value: \ProjectRow.nameKey) { (row: ProjectRow) in RepoNameCell(row: row) }
                .width(min: 140, ideal: 190)
                .customizationID("name")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Deploy", value: \ProjectRow.deployKey) { (row: ProjectRow) in DeployCell(row: row, machineLabel: machineLabel) }
                .width(min: 60, ideal: 150, max: 300)
                .customizationID("deploy")
            TableColumn("Owner", value: \ProjectRow.ownerKey) { (row: ProjectRow) in OwnerCell(repo: row.repo) }
                .width(min: 80, ideal: 120)
                .customizationID("owner")
            TableColumn("Issues", value: \ProjectRow.openIssues) { (row: ProjectRow) in
                countButton(row, pulls: false)
            }
            .width(min: 46, ideal: 56, max: 90)
            .customizationID("issues")
            TableColumn("PRs", value: \ProjectRow.openPullRequests) { (row: ProjectRow) in
                countButton(row, pulls: true)
            }
            .width(min: 42, ideal: 52, max: 90)
            .customizationID("pulls")
            TableColumn("Pushed", value: \ProjectRow.pushedKey) { (row: ProjectRow) in DateCell(date: row.repo.pushedAt) }
                .width(min: 64, ideal: 78, max: 130)
                .customizationID("pushed")
            TableColumn("Type", value: \ProjectRow.typeKey) { (row: ProjectRow) in TypeCell(row: row) }
                .width(min: 60, ideal: 84, max: 130)
                .customizationID("type")
            TableColumn("Merge", value: \ProjectRow.mergeKey) { (row: ProjectRow) in MergeCell(row: row) }
                .width(min: 46, ideal: 58, max: 90)
                .customizationID("merge")
            TableColumn("Works on", value: \ProjectRow.workplaceKey) { (row: ProjectRow) in WorkplaceCell(row: row) }
                .width(min: 80, ideal: 110, max: 220)
                .customizationID("workplace")
            TableColumn("Tasks", value: \ProjectRow.openTasks) { (row: ProjectRow) in TasksCell(tasks: tasks[row.id.lowercased()] ?? []) }
                .width(min: 42, ideal: 56, max: 110)
                .customizationID("tasks")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ProjectRow.ID.self) { ids in
            if let row = sorted.first(where: { ids.contains($0.id) }) { menu(row) }
        } primaryAction: { ids in
            if let row = sorted.first(where: { ids.contains($0.id) }) { model.selectProject(row.id, tab: .overview) }
        }
    }

    /// An open-work count that shows those pull requests or issues in the sidebar.
    private func countButton(_ row: ProjectRow, pulls: Bool) -> some View {
        let value = pulls ? row.openPullRequests : row.openIssues
        return Button { model.selectProject(row.id, tab: pulls ? .pulls : .issues) } label: {
            CountView(value: value, systemImage: pulls ? "arrow.triangle.pull" : "smallcircle.filled.circle", tint: GitHubColors.open)
        }
        .buttonStyle(.plain)
        .disabled(value == 0)
        .help(value == 0 ? "" : "Show \(row.repo.name)’s open \(pulls ? "pull requests" : "issues")")
    }

    /// A local deploy target's machine as BotChu knows it: This Mac, a host's nickname, or its name.
    private func machineLabel(_ machine: String) -> String {
        if machine.caseInsensitiveCompare(model.settings.thisMacName) == .orderedSame { return "This Mac" }
        return model.settings.hosts.first { $0.machine.caseInsensitiveCompare(machine) == .orderedSame }?.nickname ?? machine
    }

    @ViewBuilder private func menu(_ row: ProjectRow) -> some View {
        Button("Show Overview") { model.selectProject(row.id, tab: .overview) }
        Button("Open on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/\(row.id)")!) }
        Divider()
        Button("Show Pull Requests") { model.selectProject(row.id, tab: .pulls) }.disabled(row.openPullRequests == 0)
        Button("Show Issues") { model.selectProject(row.id, tab: .issues) }.disabled(row.openIssues == 0)
        Divider()
        Menu("Start Task with") {
            ForEach(model.bots) { bot in Button("\(bot.emoji) \(bot.name)") { model.newTask(for: bot.id, repo: row.id) } }
        }
        .disabled(model.bots.isEmpty)
    }
}

/// Open pull requests or issues across the repositories. Selecting one opens it in the sidebar, and
/// double-click on GitHub; its menu reviews it or starts a task on it with a bot, or opens the task
/// already on it.
struct WorkTable: View {
    @Environment(AppModel.self) private var model
    var items: [GitHubLookup.OpenItem]
    var pulls: Bool
    @State private var sortOrder = [KeyPathComparator(\GitHubLookup.OpenItem.updatedAt, order: .reverse)]
    private let pullColumns = SavedColumns<GitHubLookup.OpenItem>("projectsPullColumns")
    private let issueColumns = SavedColumns<GitHubLookup.OpenItem>("projectsIssueColumns")

    var body: some View {
        let sorted = items.sorted(using: sortOrder)
        let repos = Dictionary((model.repositories ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let open = model.openTasks
        let columns = pulls ? pullColumns : issueColumns
        let selection = Binding<GitHubLookup.OpenItem.ID?>(get: {
            model.projectSelection.flatMap { chosen in
                chosen.tab == (pulls ? .pulls : .issues) ? chosen.item.map { "\(chosen.repo)#\($0)" } : nil
            }
        }, set: { id in
            guard let id else { return model.selectProject(nil) }
            if let item = sorted.first(where: { $0.id == id }) { model.selectProject(item.repo, tab: pulls ? .pulls : .issues, item: item.number) }
        })
        Table(sorted, selection: selection, sortOrder: $sortOrder, columnCustomization: Binding(get: { columns.customization }, set: { columns.customization = $0 })) {
            TableColumn("Title", value: \GitHubLookup.OpenItem.titleKey) { (item: GitHubLookup.OpenItem) in WorkTitleCell(item: item) }
                .width(min: 180, ideal: 300)
                .customizationID("title")
                .disabledCustomizationBehavior(.visibility)
            TableColumn("Repository", value: \GitHubLookup.OpenItem.repoKey) { (item: GitHubLookup.OpenItem) in WorkRepoCell(item: item, repo: repos[item.repo]) }
                .width(min: 110, ideal: 160)
                .customizationID("repo")
            TableColumn("Updated", value: \GitHubLookup.OpenItem.updatedAt) { (item: GitHubLookup.OpenItem) in DateCell(date: item.updatedAt) }
                .width(min: 64, ideal: 78, max: 130)
                .customizationID("updated")
            TableColumn("Checks", value: \GitHubLookup.OpenItem.checks) { (item: GitHubLookup.OpenItem) in
                if item.isPullRequest { ChecksIcon(checks: item.checks) }
            }
            .width(min: 46, ideal: 52, max: 70)
            .customizationID("checks")
            .defaultVisibility(pulls ? .automatic : .hidden)
            TableColumn("Review", value: \GitHubLookup.OpenItem.reviewRank) { (item: GitHubLookup.OpenItem) in ReviewBadge(decision: item.reviewDecision) }
                .width(min: 60, ideal: 110)
                .customizationID("review")
                .defaultVisibility(pulls ? .automatic : .hidden)
            TableColumn("Changes", value: \GitHubLookup.OpenItem.changeSize) { (item: GitHubLookup.OpenItem) in
                if item.isPullRequest { ChangesCell(item: item) }
            }
            .width(min: 70, ideal: 90, max: 140)
            .customizationID("changes")
            .defaultVisibility(.hidden)
            TableColumn("Comments", value: \GitHubLookup.OpenItem.comments) { (item: GitHubLookup.OpenItem) in
                CountView(value: item.comments, systemImage: "bubble.left", tint: GitHubColors.neutral)
            }
            .width(min: 50, ideal: 70, max: 100)
            .customizationID("comments")
            .defaultVisibility(pulls ? .hidden : .automatic)
            TableColumn("Author", value: \GitHubLookup.OpenItem.authorKey) { (item: GitHubLookup.OpenItem) in PersonCell(login: item.author, avatar: item.authorAvatar) }
                .width(min: 80, ideal: 120)
                .customizationID("author")
            TableColumn("Task") { (item: GitHubLookup.OpenItem) in TasksCell(tasks: model.tasks(on: item, among: open)) }
                .width(min: 42, ideal: 56, max: 110)
                .customizationID("task")
            TableColumn("Opened", value: \GitHubLookup.OpenItem.createdAt) { (item: GitHubLookup.OpenItem) in DateCell(date: item.createdAt) }
                .width(min: 64, ideal: 86, max: 130)
                .customizationID("opened")
                .defaultVisibility(.hidden)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: GitHubLookup.OpenItem.ID.self) { ids in
            if let item = sorted.first(where: { ids.contains($0.id) }) { menu(item, tasks: model.tasks(on: item, among: open)) }
        } primaryAction: { ids in
            for item in sorted where ids.contains(item.id) { NSWorkspace.shared.open(item.url) }
        }
    }

    @ViewBuilder private func menu(_ item: GitHubLookup.OpenItem, tasks: [(bot: Bot, task: BotTask)]) -> some View {
        Button("Open on GitHub") { NSWorkspace.shared.open(item.url) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        }
        if !tasks.isEmpty {
            Divider()
            ForEach(tasks, id: \.task.id) { pair in
                Button("Open \(pair.bot.name)’s Task") { model.show(.task(pair.task.id, of: pair.bot.id)) }
            }
        }
        Divider()
        if item.isPullRequest {
            botMenu("Review with") { model.newTask(for: $0, repo: item.repo, work: item.work, purpose: .review) }
            botMenu("Review and Comment with") { model.newTask(for: $0, repo: item.repo, work: item.work, purpose: .comment) }
            botMenu("Continue with") { model.newTask(for: $0, repo: item.repo, work: item.work) }
        } else {
            botMenu("Start Task with") { model.newTask(for: $0, repo: item.repo, work: item.work) }
        }
    }

    private func botMenu(_ title: String, action: @escaping (UUID) -> Void) -> some View {
        Menu(title) {
            ForEach(model.bots) { bot in Button("\(bot.emoji) \(bot.name)") { action(bot.id) } }
        }
        .disabled(model.bots.isEmpty)
    }
}

/// PROJECT.md to edit: as read, and its metadata.
struct ProjectEditRequest: Identifiable {
    let id = UUID()
    let record: ProjectRecord
    let metadata: ProjectMetadata
}

struct ProjectMetadataEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: GitHubLookup.Repo
    let original: ProjectRecord
    @State var metadata: ProjectMetadata
    @State private var saving = false
    @State private var failure: String?
    @State private var publication: ProjectGitHub.Publication?
    private var changedText: String? { try? original.updating(metadata) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project metadata").font(.headline)
                    Text(repo.nameWithOwner + " / PROJECT.md").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Form {
                TextField("Name", text: $metadata.name)
                Picker("Type", selection: $metadata.kind) { ForEach(ProjectMetadata.Kind.allCases, id: \.self) { Text($0.label).tag($0) } }
                Picker("Status", selection: $metadata.status) { ForEach(ProjectMetadata.Status.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                TextField("Deploy", text: $metadata.deploy)
                Picker("Who merges PRs", selection: $metadata.merge) { Text("Owner").tag("owner"); Text("Agent").tag("agent") }
                Text("Deployment tells BotChu where this project lives, such as local:my-mac:~/apps/project or vercel:project. Workspace overrides remain available in New Task.")
                    .font(.caption).foregroundStyle(.secondary)
                if let problem = metadata.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            }.formStyle(.grouped).disabled(saving || publication != nil)
            VStack(alignment: .leading, spacing: 10) {
                if let url = publication?.url {
                    Label("Metadata pull request opened", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Link("Review pull request on GitHub", destination: url)
                    Text("The project updates after this PR merges and you refresh Projects.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Creates a PR changing only PROJECT.md. No clone or test run. Your repository’s merge requirements still apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
                    if let branch = publication?.branch {
                        Link("View saved branch", destination: URL(string: "https://github.com/\(repo.id)/tree/\(branch)")!)
                    }
                }
                HStack {
                    Spacer()
                    Button(publication?.url == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                    if publication?.url == nil {
                        Button(saving ? "Opening PR…" : publication == nil ? "Create Metadata PR" : "Retry") { Task { await save() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving || metadata.problem != nil || changedText == nil || changedText == original.text)
                    }
                }
            }.padding(20)
        }.frame(width: 580, height: 590).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)
    }

    private func save() async {
        guard let text = changedText else { return }
        saving = true; failure = nil
        defer { saving = false }
        do {
            let result = try await model.projectGitHub.publish(repo: repo.id, original: original, text: text, retryBranch: publication?.branch)
            publication = result
            failure = result.problem
        } catch { failure = error.localizedDescription }
    }
}
