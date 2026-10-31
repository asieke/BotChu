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
    /// A prepared native sheet stays idle until it is attached to its parent window.
    let presentation: TaskSheetPresentation?
    /// The repository a task started in last time, chosen again first.
    @AppStorage("newTaskRepo") private var lastRepo = ""
    @State private var query = ""
    @State private var repo: String?
    /// Where the repository is worked on.
    private var location: RepoLocation? { repo.map(model.location(of:)) }
    /// The issue or pull request the task works on, if any.
    @State private var work: BotTask.Work?
    @State private var purpose: Purpose
    /// A pull request to continue, as GitHub has it, with the head branch its task works on.
    @State private var head: PullHead?
    @State private var brief = ""
    /// The agents and projects chosen in the brief from `@` and `#` completion.
    @State private var references: [MessageReference] = []
    @State private var listOpen = false
    @State private var editing = true
    @State private var images = DraftImages()

    /// - Parameters:
    ///   - initialWork: an issue or pull request of `initialRepo` to work on, and `initialPurpose`,
    ///     what to do with a pull request.
    ///   - initialBrief: what to tell the bot, written already: a task over many issues or pull requests.
    init(botID: UUID, initialRepo: String? = nil, initialWork: BotTask.Work? = nil, initialPurpose: Purpose = .work,
         initialBrief: String = "", cachedRepo: String? = nil, presentation: TaskSheetPresentation? = nil) {
        self.botID = botID
        self.initialRepo = initialRepo
        self.presentation = presentation
        _repo = State(initialValue: cachedRepo)
        _work = State(initialValue: initialRepo == nil ? nil : initialWork)
        _purpose = State(initialValue: initialWork?.isPullRequest == true ? initialPurpose : .work)
        _brief = State(initialValue: initialBrief)
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
                    if let location { locationRow(location) }
                } header: {
                    Text("Project")
                } footer: {
                    if let error = model.repositoriesError, model.repositories == nil {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    if let work {
                        workRow(work)
                        if work.isPullRequest { modePicker }
                    }
                    DraftEditor(text: $brief, focused: $editing, images: images,
                                placeholder: work == nil ? "What should \(botName) do?" : "Anything to add? (optional)",
                                maxHeight: 200, identifier: "task-brief",
                                mentions: model.mentionSources(for: botID, favoring: repo), references: $references, listOpen: $listOpen)
                } header: {
                    Text("Task")
                } footer: {
                    if let conflict {
                        Text(conflict).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(listOpen ? nil : .cancelAction)
                Button("Start Task") { start() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil)
                    .help(problem ?? "Prepare the task and send its first message (⌘↩)")
            }
            .padding(16)
        }
        .mentionPopups()
        .frame(width: 560, height: 720)
        .onAppear { if presentation == nil { FrameTimings.mark(FrameMarks.newTask) } }
        // A pull request's branch another task owns turns the task away before it is made (#215).
        .task(id: headKey) {
            guard let headKey, let repo, let work else { return }
            if let found = await model.pullRequestHead(work, repo: repo) {
                guard !Task.isCancelled else { return }
                head = PullHead(key: headKey, work: found.work, branch: found.branch)
            } else {
                guard !Task.isCancelled else { return }
                head = PullHead(key: headKey, work: work, branch: "")
            }
        }
        .task(id: presentation?.shown ?? true) {
            guard presentation?.shown != false else { return }
            await model.loadRepositories()
            guard !Task.isCancelled, presentation?.shown != false else { return }
            let wanted = initialRepo ?? (DevHooks.dataDir == nil ? presentation?.rememberedRepo ?? lastRepo : DevHooks.env["BOTCHU_TASK_REPO"] ?? "")
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
    }

    /// Where the chosen repository is worked on (#232): the computer, then its folder there.
    private func locationRow(_ location: RepoLocation) -> some View {
        LabeledContent("Location") {
            Text(verbatim: "\(model.machineName(location.hostID)) · \(displayed(location))")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(location.hostID == nil ? displayed(location) : "Over SSH, in \(location.path)")
        }
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

    /// What the task does with a pull request (#232): continues it, reviews it here, or reviews it
    /// and posts the review on GitHub, chosen here rather than told in a footer.
    private var modePicker: some View {
        Picker("Mode", selection: $purpose) {
            Text("Continue PR").tag(Purpose.work)
            Text("Review in BotChu").tag(Purpose.review)
            Text("Review & Comment on GitHub").tag(Purpose.comment)
        }
        .pickerStyle(.segmented)
    }

    // MARK: Starting

    struct PullHead {
        var key: String
        var work: BotTask.Work
        var branch: String
    }

    /// The pull request the task would continue, while it is one.
    private var headKey: String? {
        guard let repo, let work, work.isPullRequest, purpose == .work else { return nil }
        return "\(repo)#\(work.number)"
    }

    /// The pull request's head as read, once it is for the one chosen.
    private var currentHead: PullHead? { head.flatMap { $0.key == headKey ? $0 : nil } }

    /// Why the task can't start yet, or nil when it can.
    private var problem: String? {
        guard let location else { return "Choose a project" }
        if work == nil, brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what \(botName) should do" }
        if location.hostID != nil, let folder = SSHHost.folderProblem(location.path) { return folder }
        if headKey != nil, currentHead == nil, let work { return "Reading \(work.reference)…" }
        return conflict
    }

    /// Prevent two tasks working on the same issue or pull request. Fresh tasks get unique
    /// branches automatically during preparation, even when their briefs happen to match.
    private var conflict: String? {
        guard let repo, let other = model.taskAlreadyWorking(on: repo, hostID: location?.hostID, work: work,
                                                             review: purpose.review, branch: currentHead?.branch ?? "") else { return nil }
        return "“\(other.title)” already works on this. Send it a message there."
    }

    private func start() {
        guard problem == nil, let bot = model.bot(botID), let repo, var location else { return }
        if location.hostID == nil { location.path = (location.path as NSString).expandingTildeInPath }
        let attachments: [ImageAttachment]
        do {
            let home = BotHome(workspace: bot.persistencePath)
            attachments = try images.images.map { try home.saveImage($0.png, name: $0.name) }
        } catch {
            images.problem = "Couldn't keep the images in \(bot.name)'s folder: \(error.localizedDescription)"
            return
        }
        let (brief, references) = MessageReference.trimming(brief, references: references)
        let task = BotTask(for: bot, repo: repo, checkout: location.path, work: currentHead?.work ?? work,
                           brief: brief, branch: currentHead?.branch ?? "",
                           host: model.settings.host(location.hostID), review: purpose.review)
        if let presentation { presentation.remember(repo) } else { lastRepo = repo }
        model.startTask(task, for: botID, show: true, images: attachments, references: references)
        close()
    }

    private func close() {
        if let presentation { presentation.close(presentation) } else { dismiss() }
    }
}
