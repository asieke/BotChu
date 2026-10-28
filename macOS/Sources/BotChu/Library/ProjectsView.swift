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
    @AppStorage("projectsScope") private var scope = Scope.repositories
    /// Gallery or table; a new key, so the table is where everyone starts.
    @AppStorage("projectsLayoutV2") private var layout = "table"
    /// Which statuses the repositories show: active ones, unless chosen otherwise.
    @AppStorage("projectsStatus") private var status = ProjectStatusFilter.active
    @State private var query = ""
    /// Which types the repositories show; with the status, the scope of all three views.
    @AppStorage("projectsKind") private var category = ProjectKindFilter.all
    /// The repository the pull request and issue tables show, or nil for all.
    @State private var repoFilter: String?

    private var projectScope: ProjectScope { ProjectScope(status: status, kind: category) }

    /// Every repository's row, before the scope and search.
    private var allRows: [ProjectRow] {
        ProjectRow.rows(repos: model.repositories ?? [], records: model.projectRecords, errors: model.projectErrors, chosen: model.settings.repoLocations,
                        hosts: model.settings.hosts, reposRoot: model.settings.expandedReposRoot,
                        taskRepos: model.openTasks.map(\.task.repo))
    }

    private var rows: [ProjectRow] {
        let scope = projectScope
        return allRows.filter { scope.includes($0) && $0.matches(query) }
    }

    private func openWork(pulls: Bool, in rows: [ProjectRow]) -> ProjectWork {
        ProjectWork(rows: rows, items: model.openItems ?? [], scope: projectScope, pulls: pulls, repo: repoFilter, query: query)
    }

    private var loading: Bool { model.projectsLoading }

    /// When what is shown was last synced with GitHub, or that a sync is under way.
    private func freshness(now: Date) -> String? {
        if loading { return model.repositories == nil ? nil : "Syncing…" }
        guard let synced = model.repositoriesReadAt else { return nil }
        return "Synced " + (now.timeIntervalSince(synced) < 60 ? "just now" : synced.formatted(.relative(presentation: .named)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Projects",
                           count: model.repositories == nil ? nil : scope == .repositories ? rows.count : allRows.filter(projectScope.includes).count) {
                if loading { ProgressView().controlSize(.small) }
                TimelineView(.everyMinute) { context in
                    if let freshness = freshness(now: context.date) {
                        Text(freshness).font(.callout).foregroundStyle(.secondary)
                            .help(model.projectsLogin.map { "Saved on this Mac for \($0), and synced with GitHub in the background" } ?? "")
                    }
                }
                // Never disabled: asked for during a sync, it runs once that one ends.
                Button { Task { await model.refreshProjects() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { model.startNewIssue() } label: { Label("New Issue", systemImage: "plus") }
                    .disabled(!model.canStartNewIssue)
                    .help("New Issue (I)")
            }
            IssueFilingsStrip()
            // One row when it fits; in a narrow window, the search goes on a row of its own, and in a
            // narrower one the filters too.
            HeaderControls { scopePicker; search.frame(minWidth: 160); HStack { filters } }
                .padding(.horizontal, 24).padding(.bottom, 16)
            if let error = model.repositoriesError ?? (scope == .repositories ? nil : model.openItemsError) {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("GitHub Settings") { model.openSettings(.github) }
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
        // What was saved shows at once; it is synced when over two minutes old, and every two
        // minutes while Projects shows.
        .task {
            while !Task.isCancelled {
                await model.loadProjects()
                do { try await Task.sleep(for: .seconds(ProjectSync.staleAfter)) } catch { break }
            }
        }
        // The selected repository; closing the sidebar deselects it.
        .inspector(isPresented: Binding(get: { model.projectSelection != nil }, set: { if !$0 { model.selectProject(nil) } })) {
            Group {
                if let selection = model.projectSelection { ProjectSidebar(selection: selection) }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        }
        .modifier(IssueDeletionPrompt())
        .modifier(IssueClosurePrompt())
        // I opens New Issue (#245), never while text is typed or over a sheet.
        .background { BareKey("i") { model.startNewIssue() } }
    }

    private var scopePicker: some View {
        let rows = model.repositories == nil ? nil : allRows
        return Picker("Show", selection: $scope) {
            Text("Repositories").tag(Scope.repositories)
            Text(count("Pull Requests", rows.map { projectScope.openCount(in: $0, pulls: true) })).tag(Scope.pulls)
            Text(count("Issues", rows.map { projectScope.openCount(in: $0, pulls: false) })).tag(Scope.issues)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private var search: some View {
        LibrarySearch(text: $query, prompt: scope == .repositories ? "Search projects" : scope == .pulls ? "Search pull requests" : "Search issues")
    }

    /// The status and type, in all three views; then the layout, or the repository.
    @ViewBuilder private var filters: some View {
        Picker("Status", selection: $status) {
            Text(ProjectStatusFilter.active.label).tag(ProjectStatusFilter.active)
            Text(ProjectStatusFilter.all.label).tag(ProjectStatusFilter.all)
            Divider()
            ForEach([ProjectStatusFilter.paused, .maintenance, .deprecated, .unclassified], id: \.self) { Text($0.label).tag($0) }
        }.labelsHidden().fixedSize().help("Show projects by the status in their PROJECT.md")
        Picker("Project kind", selection: $category) {
            ForEach(ProjectKindFilter.allCases, id: \.self) { Text($0.label).tag($0) }
        }.labelsHidden().fixedSize()
        if scope == .repositories {
            LibraryLayoutPicker(layout: $layout)
        } else {
            let work = openWork(pulls: scope == .pulls, in: allRows)
            // A repository the scope no longer covers shows as All repositories, and comes back with it.
            Picker("Repository", selection: Binding(get: { work.repo }, set: { repoFilter = $0 })) {
                Text("All repositories").tag(String?.none)
                Divider()
                ForEach(work.repos, id: \.self) { Text(TaskNaming.repoName($0)).tag(String?.some($0)) }
            }.labelsHidden().frame(maxWidth: 170).fixedSize()
        }
    }

    private func count(_ title: String, _ value: Int?) -> String {
        guard let value, value > 0 else { return title }
        return "\(title) \(value)"
    }

    @ViewBuilder private var repositories: some View {
        let rows = rows
        if model.repositories == nil && model.projectsLoading {
            LibraryEmpty(title: "Loading projects", subtitle: "Reading repositories with your GitHub CLI login.", symbol: "arrow.triangle.2.circlepath")
        } else if rows.isEmpty, status != .all, model.projectsLoading {
            // Statuses come from PROJECT.md, read after the repositories: none is known to match yet.
            LibraryEmpty(title: "Loading projects", subtitle: "Reading each repository’s PROJECT.md for its status.", symbol: "arrow.triangle.2.circlepath")
        } else if rows.isEmpty, status != .all, model.repositories?.isEmpty == false {
            ContentUnavailableView {
                Label(status == .unclassified ? "No unclassified projects" : "No \(status.label.lowercased()) projects", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(query.isEmpty && category == .all ? "No repository’s PROJECT.md gives it this status." : "Try another search, kind or status.")
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
        let allRows = allRows
        let work = openWork(pulls: pulls, in: allRows)
        let kind = pulls ? "pull requests" : "issues"
        if work.items.isEmpty {
            if model.openItems == nil && model.projectsLoading {
                LibraryEmpty(title: "Loading open \(kind)", subtitle: "Reading them with your GitHub CLI login.", symbol: "arrow.triangle.2.circlepath")
            } else if work.outOfScope > 0, model.projectsLoading, allRows.contains(where: { $0.record == .loading }) {
                // Statuses and types come from PROJECT.md, read after the repositories.
                LibraryEmpty(title: "Loading open \(kind)", subtitle: "Reading each repository’s PROJECT.md for its status and type.", symbol: "arrow.triangle.2.circlepath")
            } else if !query.isEmpty || work.repo != nil {
                ContentUnavailableView {
                    Label("No matching \(kind)", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    // The search covers only what was read; say so when that isn't everything.
                    Text("Nothing open matches the search\(work.repo.map { " in \(TaskNaming.repoName($0))" } ?? "")."
                         + (work.shownOfOpen.map { "\n\nSearched the \($0.shown) most recent of \($0.open)." } ?? ""))
                } actions: {
                    Button("Show All") { query = ""; repoFilter = nil }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if work.outOfScope > 0 {
                ContentUnavailableView {
                    Label("No open \(kind) in \(projectScope.projects)", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Show All Projects") { status = .all; category = .all }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LibraryEmpty(title: "Nothing open", subtitle: "No open \(kind) in your \(projectScope.isNarrowed ? projectScope.projects : "repositories").", symbol: "checkmark.circle")
            }
        } else {
            WorkTable(items: work.items, pulls: pulls)
            if let counts = work.shownOfOpen { truncationBar(work, shown: counts.shown, open: counts.open) }
        }
    }

    /// Under the table when GitHub has more open than were read (#232): how many of how many, and
    /// the rest on GitHub, a link for each repository cut short.
    private func truncationBar(_ work: ProjectWork, shown: Int, open: Int) -> some View {
        HStack(spacing: 6) {
            Text("Showing \(shown) most recent of \(open)")
            ForEach(work.truncated) { repo in
                Text("·").foregroundStyle(.tertiary)
                Link(destination: work.githubURL(of: repo)) {
                    Text(work.truncated.count == 1 ? "Open on GitHub ↗" : "\(repo.name) on GitHub ↗")
                }
                .help("Open \(repo.nameWithOwner)’s open \(work.pulls ? "pull requests" : "issues") on GitHub")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
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

/// Projects' scope picker, search and filters: on one row when they fit, else with the search on a
/// row of its own below, or, narrower still, each on its own row. Each control is measured once when
/// it changes, and only placed as the width changes, which it does on every frame of the sidebar's
/// slide (#188); `ViewThatFits` measured every copy of every control again on each of those frames.
struct HeaderControls: Layout {
    struct Cache {
        /// The scope picker's, the search's and the filters' ideal sizes.
        var sizes: [CGSize]
        /// Between the scope picker and the search, and the search and the filters, as an HStack spaces them.
        var gaps: [CGFloat]
        var rowWidth: CGFloat { sizes.reduce(0) { $0 + $1.width } + gaps.reduce(0, +) }
        /// The narrowest the scope picker and the filters fit beside each other.
        var pairWidth: CGFloat { sizes[0].width + 8 + sizes[2].width }
        var pairHeight: CGFloat { max(sizes[0].height, sizes[2].height) }
    }

    private let rowSpacing: CGFloat = 10

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
              gaps: subviews.indices.dropLast().map { subviews[$0].spacing.distance(to: subviews[$0 + 1].spacing, along: .horizontal) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let sizes = cache.sizes
        guard let width = proposal.width, width.isFinite else { return CGSize(width: cache.rowWidth, height: sizes.map(\.height).max()!) }
        if width >= cache.rowWidth { return CGSize(width: width, height: sizes.map(\.height).max()!) }
        if width >= cache.pairWidth { return CGSize(width: width, height: cache.pairHeight + rowSpacing + sizes[1].height) }
        return CGSize(width: max(width, sizes[0].width, sizes[2].width), height: sizes.map(\.height).reduce(0, +) + 2 * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }
        let sizes = cache.sizes
        if bounds.width >= cache.rowWidth {
            let search = bounds.width - sizes[0].width - sizes[2].width - cache.gaps.reduce(0, +)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(sizes[0]))
            subviews[1].place(at: CGPoint(x: bounds.minX + sizes[0].width + cache.gaps[0], y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: search, height: nil))
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(sizes[2]))
        } else if bounds.width >= cache.pairWidth {
            let middle = bounds.minY + cache.pairHeight / 2
            subviews[0].place(at: CGPoint(x: bounds.minX, y: middle), anchor: .leading, proposal: ProposedViewSize(sizes[0]))
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: middle), anchor: .trailing, proposal: ProposedViewSize(sizes[2]))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + cache.pairHeight + rowSpacing), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        } else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(sizes[0]))
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes[0].height + rowSpacing), proposal: ProposedViewSize(sizes[2]))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes[0].height + sizes[2].height + 2 * rowSpacing),
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// A table's column choices (shown, order, widths), saved between launches.
private struct SavedColumns<Row: Identifiable>: DynamicProperty {
    @AppStorage private var data: Data
    /// The table reads them many times a frame while its columns resize, as in the sidebar's slide (#188).
    @State private var decoded = Decoded<Row>()
    init(_ key: String) { _data = AppStorage(wrappedValue: Data(), key) }
    var customization: TableColumnCustomization<Row> {
        get { decoded.value(of: data) }
        nonmutating set { data = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

/// What a table's saved column choices last decoded to.
private final class Decoded<Row: Identifiable> {
    private var last: (data: Data, value: TableColumnCustomization<Row>)?

    func value(of data: Data) -> TableColumnCustomization<Row> {
        if let last, last.data == data { return last.value }
        let value = (try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: data)) ?? TableColumnCustomization()
        last = (data, value)
        return value
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
            TableColumn("Deploy", value: \ProjectRow.deployKey) { (row: ProjectRow) in
                DeployCell(row: row, names: row.deploy.map { $0.kind == .local ? machineLabel($0.name) : $0.name })
            }
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
        if let thisMac = model.settings.thisMacName, machine.caseInsensitiveCompare(thisMac) == .orderedSame { return "This Mac" }
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
            ForEach(model.taskOwners) { bot in Button("\(bot.emoji) \(bot.name)") { model.newTask(for: bot.id, repo: row.id) } }
        }
        .disabled(model.taskOwners.isEmpty)
    }
}

/// Open pull requests or issues across the repositories. Selecting one opens it in the sidebar, and
/// double-click on GitHub; its menu reviews it or starts a task on it with a bot, opens the task
/// already on it, or deletes an issue.
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
            if let item = sorted.first(where: { ids.contains($0.id) }) { WorkMenu(item: item, tasks: model.tasks(on: item, among: open)) }
        } primaryAction: { ids in
            for item in sorted where ids.contains(item.id) { NSWorkspace.shared.open(item.url) }
        }
    }
}

/// An open pull request's or issue's menu, in the tables and the sidebar's lists: it on GitHub, the
/// tasks on it, a review or a task on it with a bot, and Delete Issue….
struct WorkMenu: View {
    @Environment(AppModel.self) private var model
    let item: GitHubLookup.OpenItem
    let tasks: [(bot: Bot, task: BotTask)]

    var body: some View {
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
            // A fork's branch isn't on origin: it can be reviewed, not continued.
            botMenu("Continue with") { model.newTask(for: $0, repo: item.repo, work: item.work) }
                .disabled(item.fromFork)
        } else {
            botMenu("Start Task with") { model.newTask(for: $0, repo: item.repo, work: item.work) }
            Divider()
            IssueClosureActions(repo: item.repo, number: item.number, title: item.title)
            Button("Delete Issue…", role: .destructive) { model.askToDeleteIssue(item.number, of: item.repo, title: item.title) }
                .disabled(model.updatingIssues.contains(item.id))
        }
    }

    private func botMenu(_ title: String, action: @escaping (UUID) -> Void) -> some View {
        Menu(title) {
            ForEach(model.taskOwners) { bot in Button("\(bot.emoji) \(bot.name)") { action(bot.id) } }
        }
        .disabled(model.taskOwners.isEmpty)
    }
}

/// Asks before deleting the issue the owner chose (`AppModel.issueDeletion`), since GitHub deletes
/// it for everyone and for good; then says why one wasn't deleted.
struct IssueDeletionPrompt: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let request = model.issueDeletion
        content
            .confirmationDialog("Delete issue #\(request?.number ?? 0) of \(request?.repo ?? "")?", isPresented: Binding(
                get: { model.issueDeletion != nil && model.issueDeletion?.failure == nil },
                set: { if !$0, model.issueDeletion?.failure == nil { model.issueDeletion = nil } }),
                titleVisibility: .visible, presenting: request) { request in
                Button("Delete Issue", role: .destructive) {
                    Task { await model.deleteIssue(request.number, of: request.repo, title: request.title) }
                }
            } message: { request in
                Text("“\(request.title)” is deleted on GitHub for everyone, with its comments. This can’t be undone. "
                     + "GitHub lets only the repository’s admins delete issues.")
            }
            .alert("Couldn’t Delete Issue #\(request?.number ?? 0)", isPresented: Binding(
                get: { model.issueDeletion?.failure != nil }, set: { if !$0 { model.issueDeletion = nil } }), presenting: request) { _ in
                Button("OK") {}
            } message: { request in
                Text(request.failure ?? "")
            }
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
    /// The deploy field as pickers (#232), read from `metadata.deploy` once Settings is known.
    @State private var deploy: DeployForm?
    @State private var saving = false
    @State private var failure: String?
    @State private var publication: ProjectGitHub.Publication?
    /// The metadata as edited, its deploy from the pickers.
    private var edited: ProjectMetadata {
        var edited = metadata
        if let deploy { edited.deploy = deploy.value }
        return edited
    }
    private var changedText: String? { try? original.updating(edited) }

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
                Section {
                    TextField("Name", text: $metadata.name)
                    Picker("Type", selection: $metadata.kind) { ForEach(ProjectMetadata.Kind.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Picker("Status", selection: $metadata.status) { ForEach(ProjectMetadata.Status.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Who merges PRs", selection: $metadata.merge) { Text("Owner").tag("owner"); Text("Agent").tag("agent") }
                }
                Section {
                    if let form = Binding($deploy) {
                        DeployTargetRows(form: form, hosts: model.settings.hosts)
                    }
                } footer: {
                    if let problem = edited.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                }
            }.formStyle(.grouped).disabled(saving || publication != nil)
            VStack(alignment: .leading, spacing: 10) {
                if let url = publication?.url {
                    Label("Metadata pull request opened", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Link("Review pull request on GitHub", destination: url)
                } else {
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
                            .disabled(saving || edited.problem != nil || changedText == nil || changedText == original.text)
                    }
                }
            }.padding(20)
        }.frame(width: 580, height: 590).background(Color(nsColor: .windowBackgroundColor)).interactiveDismissDisabled(saving)
        // Read again once this Mac's name is known, as long as nothing in it was changed.
        .task(id: model.settings.thisMacName) {
            if deploy.map({ $0.value == metadata.deploy }) ?? true {
                deploy = DeployForm(deploy: metadata.deploy, thisMac: model.settings.thisMacName, hosts: model.settings.hosts.map(\.machine))
            }
        }
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

/// PROJECT.md's deploy targets as pickers (#232): None or the first target's kind, its folder or
/// name, then any others, each removable, and Add Target. A host is chosen from Settings ▸ Hosts by
/// its machine name, which stays a choice when the file names one Settings doesn't have.
private struct DeployTargetRows: View {
    @Binding var form: DeployForm
    let hosts: [SSHHost]

    var body: some View {
        Picker("Deploy", selection: $form.first) {
            Text("None").tag(DeployForm.Kind?.none)
            Divider()
            ForEach(DeployForm.Kind.allCases) { kind in Text(kind.label).tag(DeployForm.Kind?.some(kind)) }
        }
        ForEach(form.targets) { target in
            if target.id != form.targets.first?.id {
                HStack {
                    Picker("Also deploy to", selection: kind(of: target.id)) {
                        ForEach(DeployForm.Kind.allCases) { kind in Text(kind.label).tag(kind) }
                    }
                    Button { form.remove(target.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this target")
                        .accessibilityLabel("Remove \(target.kind.label) target")
                }
            }
            fields(target)
        }
        if !form.targets.isEmpty {
            Button { form.add() } label: { Label("Add Target", systemImage: "plus") }
        }
    }

    @ViewBuilder private func fields(_ target: DeployForm.Target) -> some View {
        switch target.kind {
        case .thisMac:
            TextField("Folder", text: field(target.id, \.path), prompt: Text("~/apps/project"))
                .font(.system(.body, design: .monospaced))
        case .host:
            let machines = hosts.map(\.machine).filter { !$0.isEmpty }
            if machines.isEmpty {
                TextField("Machine", text: field(target.id, \.machine), prompt: Text("omarchy-1"))
                    .font(.system(.body, design: .monospaced))
            } else {
                Picker("Host", selection: field(target.id, \.machine)) {
                    ForEach(hosts.filter { !$0.machine.isEmpty }) { host in Text("\(host.nickname) · \(host.machine)").tag(host.machine) }
                    if !machines.contains(target.machine) { Text(target.machine.isEmpty ? "None" : target.machine).tag(target.machine) }
                }
            }
            TextField("Folder", text: field(target.id, \.path), prompt: Text("~/apps/project"))
                .font(.system(.body, design: .monospaced))
        case .vercel:
            TextField("Vercel project", text: field(target.id, \.name), prompt: Text("project"))
        case .registry:
            TextField("Package", text: field(target.id, \.name), prompt: Text("name"))
        case .custom:
            TextField("Target", text: field(target.id, \.name), prompt: Text("kind:value"))
                .font(.system(.body, design: .monospaced))
        }
    }

    private func kind(of id: DeployForm.Target.ID) -> Binding<DeployForm.Kind> {
        Binding(get: { form.targets.first { $0.id == id }?.kind ?? .custom }, set: { form.change(id, to: $0) })
    }

    private func field(_ id: DeployForm.Target.ID, _ key: WritableKeyPath<DeployForm.Target, String>) -> Binding<String> {
        Binding(get: { form.targets.first { $0.id == id }?[keyPath: key] ?? "" }, set: { value in
            if let i = form.targets.firstIndex(where: { $0.id == id }) { form.targets[i][keyPath: key] = value }
        })
    }
}
