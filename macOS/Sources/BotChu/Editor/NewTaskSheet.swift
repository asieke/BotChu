import SwiftUI
import BotChuCore

/// Starts a task for a bot: one of the owner's GitHub repositories, and what to do, in words and
/// images. It works where the repository lives (`AppModel.location(of:)`), on the bot's account,
/// and branches are managed when it starts. Opened for an issue or pull request (from Projects), it
/// works on that, and the words add to it.
struct NewTaskSheet: View {
    /// What a task on a pull request does with it.
    enum Purpose: Hashable {
        case work, review, comment

        var review: BotTask.Review? {
            switch self {
            case .work: nil
            case .review: .review
            case .comment: .comment
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let botID: UUID
    let initialRepo: String?
    /// The repository a task started in last time, chosen again first.
    @AppStorage("newTaskRepo") private var lastRepo = ""
    @State private var query = ""
    @State private var repo: String?
    /// Where the repository is worked on, once read.
    @State private var location: RepoLocation?
    /// Why it isn't worked on where it deploys: that computer isn't in Settings ▸ Hosts.
    @State private var placementProblem: String?
    /// The owner chose to work on this Mac all the same, which is remembered for the repository.
    @State private var worksHere = false
    /// The issue or pull request the task works on, if any.
    @State private var work: BotTask.Work?
    @State private var purpose: Purpose
    @State private var brief = ""
    @State private var editing = true
    @State private var images = DraftImages()

    /// - Parameters:
    ///   - initialWork: an issue or pull request of `initialRepo` to work on, and `initialPurpose`,
    ///     what to do with a pull request.
    init(botID: UUID, initialRepo: String? = nil, initialWork: BotTask.Work? = nil, initialPurpose: Purpose = .work) {
        self.botID = botID
        self.initialRepo = initialRepo
        _work = State(initialValue: initialRepo == nil ? nil : initialWork)
        _purpose = State(initialValue: initialWork?.isPullRequest == true ? initialPurpose : .work)
    }

    private var botName: String { model.bot(botID)?.name ?? "the bot" }

    var body: some View {
        VStack(spacing: 0) {
            Text("New Task for \(model.bot(botID)?.name ?? "Bot")")
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    TextField("Search", text: $query, prompt: Text("Search your projects"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    repositoryList
                } header: {
                    Text("Project")
                } footer: {
                    placeFooter
                }
                Section {
                    if let work { workRow(work) }
                    DraftEditor(text: $brief, focused: $editing, images: images,
                                placeholder: work == nil ? "What should \(botName) do?" : "Anything to add? (optional)",
                                maxHeight: 200, identifier: "task-brief")
                } header: {
                    Text("Task")
                } footer: {
                    taskFooter
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Task") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
                    .help(problem ?? "Prepare the task and send its first message (⌘↩)")
            }
            .padding(16)
        }
        .frame(width: 560, height: 720)
        .task {
            await model.loadRepositories()
            let wanted = initialRepo ?? (DevHooks.dataDir == nil ? lastRepo : DevHooks.env["BOTCHU_TASK_REPO"] ?? "")
            if repo == nil, let last = model.repositories?.first(where: { $0.nameWithOwner == wanted }) { choose(last.nameWithOwner) }
        }
    }

    // MARK: Repository

    private var matches: [GitHubLookup.Repo] {
        let all = model.repositories ?? []
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        return all.filter { repo in words.allSatisfy { repo.nameWithOwner.lowercased().contains($0) || repo.description.lowercased().contains($0) } }
    }

    private var repositoryList: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.repositories == nil, model.repositoriesError == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading your repositories…").foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
                ForEach(matches) { found in
                    Button { choose(found.nameWithOwner) } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(found.nameWithOwner)
                                    .fontWeight(found.nameWithOwner == repo ? .semibold : .regular)
                                if !found.description.isEmpty {
                                    Text(found.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            if found.isPrivate {
                                Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).help("Private")
                            }
                            if let pushed = found.pushedAt {
                                Text(pushed, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6).fill(found.nameWithOwner == repo ? Color.accentColor.opacity(0.15) : .clear))
                    }
                    .buttonStyle(.plain)
                    .id(found.nameWithOwner)
                }
                if model.repositories != nil, matches.isEmpty {
                    Text("No repository matches “\(query)”.").foregroundStyle(.secondary).padding(10)
                }
            }
        }
        .frame(height: 176)
        // The repository chosen for the sheet (the last one used) is in view.
        .task(id: repo) { if let repo { proxy.scrollTo(repo, anchor: .center) } }
        }
    }

    private func choose(_ nameWithOwner: String) {
        guard nameWithOwner != repo else { return }
        repo = nameWithOwner
        // The issue or pull request the sheet was opened for is its repository's.
        if nameWithOwner != initialRepo {
            work = nil
            purpose = .work
        }
        location = nil
        placementProblem = nil
        worksHere = false
        Task {
            let found = await model.location(of: nameWithOwner)
            guard repo == nameWithOwner else { return }
            location = found
            placementProblem = model.projectPlacementProblem(nameWithOwner)
        }
    }

    @ViewBuilder private var placeFooter: some View {
        Group {
            if let error = model.repositoriesError, model.repositories == nil {
                Text(error).foregroundStyle(.red)
            } else if let placementProblem, !worksHere {
                VStack(alignment: .leading, spacing: 6) {
                    Text(placementProblem).foregroundStyle(.orange)
                    Button("Work on This Mac") { worksHere = true }
                        .help("Work on it in \(location.map(displayed) ?? "the repositories folder") on this Mac, from now on")
                }
            } else if let location {
                Text("Works on \(model.machineName(location.hostID))\(location.hostID == nil ? "" : " over SSH"), in \(displayed(location)). BotChu clones it there if it isn't yet.")
                    .textSelection(.enabled)
            } else if repo != nil {
                Text("Finding where it’s worked on…")
            } else {
                Text("Your GitHub repositories, and your organizations', as gh lists them.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// A folder as the sheet shows it: with `~` for this Mac's home.
    private func displayed(_ location: RepoLocation) -> String {
        location.hostID == nil ? (location.path as NSString).abbreviatingWithTildeInPath : location.path
    }

    // MARK: Work

    /// The issue or pull request, as what the task does with it.
    private func workRow(_ work: BotTask.Work) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: work.isPullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                .foregroundStyle(.secondary)
            Text(verbatim: workSummary(work))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                self.work = nil
                purpose = .work
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Start something new instead")
            .accessibilityLabel("Remove \(work.reference)")
        }
    }

    private func workSummary(_ work: BotTask.Work) -> String {
        switch purpose {
        case .review: "Review \(work.reference)"
        case .comment: "Review and comment on \(work.reference)"
        case .work: (work.isPullRequest ? "Continue " : "Work on ") + work.reference
        }
    }

    @ViewBuilder private var taskFooter: some View {
        Group {
            if let conflict {
                Text(conflict).foregroundStyle(.red)
            } else if purpose == .comment {
                Text("\(botName) reviews the changes and posts one review on GitHub.")
            } else if purpose == .review {
                Text("\(botName) reviews the changes and gives its review here; it posts nothing.")
            } else {
                Text("The task's first message, after \(botName)'s instructions and memory. It has a workspace and conversation of its own, on \(model.bot(botID)?.account.name ?? "the bot's account").")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Starting

    /// Why the task can't start yet, or nil when it can.
    private var problem: String? {
        guard let repo else { return "Choose a project" }
        if let placementProblem, !worksHere { return placementProblem }
        guard let location else { return "Finding where \(repo) is worked on…" }
        if work == nil, brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what \(botName) should do" }
        if location.hostID != nil, let folder = SSHHost.folderProblem(location.path) { return folder }
        return conflict
    }

    /// Prevent two tasks working on the same issue or pull request. Fresh tasks get unique
    /// branches automatically during preparation, even when their briefs happen to match.
    private var conflict: String? {
        guard let repo, let other = model.taskAlreadyWorking(on: repo, hostID: location?.hostID, work: work,
                                                             review: purpose.review, branch: "") else { return nil }
        return "“\(other.title)” already works on this. Send it a message there."
    }

    private func start() {
        guard problem == nil, let bot = model.bot(botID), let repo, var location else { return }
        if location.hostID == nil { location.path = (location.path as NSString).expandingTildeInPath }
        let attachments: [ImageAttachment]
        do {
            let home = BotHome(workspace: bot.workspace)
            attachments = try images.images.map { try home.saveImage($0.png, name: $0.name) }
        } catch {
            images.problem = "Couldn't keep the images in \(bot.name)'s folder: \(error.localizedDescription)"
            return
        }
        if worksHere { model.settings.repoLocations[repo] = location }
        let task = BotTask(for: bot, repo: repo, checkout: location.path, work: work,
                           brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                           host: model.settings.host(location.hostID), review: purpose.review)
        lastRepo = repo
        model.startTask(task, for: botID, show: true, images: attachments)
        dismiss()
    }
}
