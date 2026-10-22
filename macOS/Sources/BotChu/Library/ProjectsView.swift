import SwiftUI
import BotChuCore

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("projectsLayout") private var layout = "gallery"
    @State private var query = ""
    @State private var category = "all"
    @State private var selected: GitHubLookup.Repo?
    @State private var pendingTask: (UUID, String)?

    private var matches: [GitHubLookup.Repo] {
        (model.repositories ?? []).filter { repo in
            let metadata = metadata(repo)
            let text = [repo.nameWithOwner, repo.description, metadata?.name ?? "", metadata?.kind.label ?? "", metadata?.status.rawValue ?? ""].joined(separator: " ")
            return (category == "all" || category == "docs" && metadata?.kind == .docs || category == "code" && metadata != nil && metadata?.kind != .docs)
                && query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }

    private func metadata(_ repo: GitHubLookup.Repo) -> ProjectMetadata? {
        guard let record = model.projectRecords[repo.id], record.exists else { return nil }
        return try? record.metadata(repoName: repo.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Projects", subtitle: "Your repositories, with a place and a purpose.", count: model.repositories?.count) {
                if model.projectsLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.loadProjects(force: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.projectsLoading)
            }
            HStack {
                LibrarySearch(text: $query, prompt: "Search projects")
                Picker("Project kind", selection: $category) {
                    Text("All projects").tag("all")
                    Text("Code").tag("code")
                    Text("Non-code").tag("docs")
                }.labelsHidden().frame(width: 130)
                LibraryLayoutPicker(layout: $layout)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            if let error = model.repositoriesError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("GitHub Settings") { openSettings() }
                }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if model.repositories == nil && model.projectsLoading {
                LibraryEmpty(title: "Loading projects", subtitle: "Reading repositories with your GitHub CLI login.", symbol: "arrow.triangle.2.circlepath")
            } else if matches.isEmpty {
                LibraryEmpty(title: model.repositories?.isEmpty == false ? "No matching projects" : "No projects yet",
                             subtitle: model.repositories?.isEmpty == false ? "Try another search or project kind." : "Connect gh in Settings, then refresh to see your repositories.", symbol: "folder")
            } else if layout == "table" {
                Table(matches) {
                    TableColumn("Project") { repo in
                        Button { selected = repo } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(metadata(repo)?.name ?? repo.name).fontWeight(.medium)
                                Text(repo.nameWithOwner).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }.width(min: 200, ideal: 260)
                    TableColumn("Type") { repo in Text(metadata(repo)?.kind.label ?? "Unclassified").foregroundStyle(.secondary) }
                    TableColumn("Status") { repo in Text(metadata(repo)?.status.rawValue.capitalized ?? "—").foregroundStyle(.secondary) }.width(100)
                    TableColumn("Deployment") { repo in Text(metadata(repo)?.deploy ?? "—").lineLimit(1).help(metadata(repo)?.deploy ?? "No PROJECT.md") }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                        ForEach(matches) { repo in
                            Button { selected = repo } label: { projectCard(repo) }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Projects")
        .task { await model.loadProjects() }
        .sheet(item: $selected, onDismiss: {
            if let (botID, repo) = pendingTask { pendingTask = nil; model.newTask(for: botID, repo: repo) }
        }) { repo in
            ProjectDetail(repo: repo) { botID in pendingTask = (botID, repo.nameWithOwner); selected = nil }.environment(model)
        }
    }

    private func projectCard(_ repo: GitHubLookup.Repo) -> some View {
        let metadata = metadata(repo)
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
            HStack {
                Text(metadata?.kind.label ?? "No project record").font(.caption)
                Spacer()
                if model.projectErrors[repo.id] != nil { Image(systemName: "exclamationmark.triangle").help("Metadata could not be refreshed") }
                Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).libraryCard()
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("\(metadata?.name ?? repo.name), \(metadata?.kind.label ?? "unclassified"). Open project")
    }
}

private struct ProjectEditRequest: Identifiable {
    let id = UUID()
    let record: ProjectRecord
    let metadata: ProjectMetadata
}

struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: GitHubLookup.Repo
    var startTask: (UUID) -> Void
    @State private var editor: ProjectEditRequest?
    @State private var location: RepoLocation?
    private var record: ProjectRecord? { model.projectRecords[repo.id] }
    private var metadata: ProjectMetadata? { record.flatMap { try? $0.metadata(repoName: repo.name) } }
    private var parseError: String? {
        do { _ = try record?.metadata(repoName: repo.name); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                LibraryIcon(symbol: metadata?.kind.symbol ?? "folder", color: .indigo)
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata?.name ?? repo.name).font(.title2.bold())
                    Text(repo.nameWithOwner).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !repo.description.isEmpty { Text(repo.description).foregroundStyle(.secondary) }
            if let error = model.projectErrors[repo.id] ?? parseError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Retry") { Task { await model.loadProjects(force: true) } }.disabled(model.projectsLoading)
            }
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 12) {
                GridRow { Text("Type").foregroundStyle(.secondary); Text(record?.exists == true ? metadata?.kind.label ?? "Unknown" : "Unclassified") }
                GridRow { Text("Status").foregroundStyle(.secondary); Text(record?.exists == true ? metadata?.status.rawValue.capitalized ?? "Unknown" : "—") }
                GridRow { Text("Visibility").foregroundStyle(.secondary); Text(repo.isPrivate ? "Private" : "Public") }
                GridRow { Text("Deployment").foregroundStyle(.secondary); Text(metadata?.deploy ?? "—").textSelection(.enabled) }
                if let location {
                    GridRow { Text("Work happens on").foregroundStyle(.secondary); Text(model.machineName(location.hostID)) }
                    GridRow { Text("Checkout").foregroundStyle(.secondary); Text(location.path).textSelection(.enabled) }
                }
            }.font(.callout)
            if let warning = model.projectPlacementProblem(repo.id) {
                Label(warning, systemImage: "network.badge.shield.half.filled").font(.callout).foregroundStyle(.orange)
            }
            if let record, !record.exists {
                Text("No PROJECT.md yet. Add a project record to describe its type and deployment.").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Link("Open on GitHub", destination: URL(string: "https://github.com/\(repo.id)")!)
                Spacer()
                Button(record?.exists == true ? "Edit Metadata…" : "Add Metadata…") {
                    if let record, let metadata { editor = ProjectEditRequest(record: record, metadata: metadata) }
                }
                    .disabled(record == nil || parseError != nil || model.projectErrors[repo.id] != nil)
                Menu("Start Task with…") {
                    ForEach(model.bots) { bot in
                        Button(bot.name) { startTask(bot.id) }
                    }
                }.disabled(model.bots.isEmpty)
            }
            if model.bots.isEmpty { Text("Create an agent to work on this project.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(24).frame(width: 600).background(Color(nsColor: .windowBackgroundColor))
        .task(id: record?.sha) { location = await model.location(of: repo.nameWithOwner) }
        .sheet(item: $editor) { request in
            ProjectMetadataEditor(repo: repo, original: request.record, metadata: request.metadata).environment(model)
        }
    }
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
