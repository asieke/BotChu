import SwiftUI
import BotChuCore

/// Starts a task for a bot: one of the owner's GitHub repositories, the computer and folder it is
/// worked on (where it lives, by default), an open issue or pull request there (or something new),
/// what to do and the account it runs on. Branches are managed when the task starts.
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
    var initialRepo: String? = nil
    /// An open issue or pull request of `initialRepo` to choose once it is read, and what to do with it.
    var initialWork: BotTask.Work? = nil
    var initialPurpose = Purpose.work
    /// The repository a task started in last time, chosen again first.
    @AppStorage("newTaskRepo") private var lastRepo = ""
    @State private var showsLocation = false
    @State private var overridesPlacement = false
    @State private var placementProblem: String?
    @State private var query = ""
    @State private var repo: String?
    @State private var hostID: UUID?
    @State private var folder = ""
    /// Where the repository is worked on when the owner hasn't chosen.
    @State private var usual: RepoLocation?
    @State private var openWork: [GitHubLookup.Found] = []
    @State private var loading = false
    @State private var lookupError: String?
    /// The issue or pull request chosen (`issue-48`, `pr-12`), or "" for something new.
    @State private var workKey = ""
    @State private var purpose = Purpose.work
    @State private var brief = ""
    @State private var accountID = ""

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
                    Group {
                        if let error = model.repositoriesError, model.repositories == nil {
                            Text(error).foregroundStyle(.red)
                        } else {
                            Text("Your GitHub repositories, and your organizations', as gh lists them.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if repo != nil {
                    Section {
                        LabeledContent("Works on", value: model.machineName(hostID))
                        Text(folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let placementProblem, !overridesPlacement {
                            Text(placementProblem).font(.caption).foregroundStyle(.orange)
                            Button("Use selected workspace instead") { overridesPlacement = true; showsLocation = true }
                        }
                        DisclosureGroup("Workspace options", isExpanded: $showsLocation) {
                        Picker("Computer", selection: Binding(get: { hostID }, set: { nextHost in
                            hostID = nextHost
                            guard let selectedRepo = repo else { return }
                            Task {
                                let path = await model.folder(of: selectedRepo, on: nextHost)
                                guard repo == selectedRepo, hostID == nextHost else { return }
                                folder = displayed(path, on: nextHost)
                            }
                        })) {
                            Label("This Mac", systemImage: "laptopcomputer").tag(UUID?.none)
                            ForEach(model.settings.hosts) { host in
                                Label(host.nickname, systemImage: "network").tag(UUID?.some(host.id))
                            }
                        }
                        LabeledContent("Folder") {
                            TextField("Folder", text: $folder)
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                        }
                        }
                    } header: {
                        Text("Project workspace")
                    } footer: {
                        locationFooter
                    }
                    Section {
                        Picker("Work on", selection: $workKey) {
                            Text("Something new").tag("")
                            let issues = openWork.filter { !$0.work.isPullRequest }
                            let pulls = openWork.filter(\.work.isPullRequest)
                            if !issues.isEmpty {
                                Section("Issues") {
                                    ForEach(issues, id: \.work.number) { found in
                                        Text("#\(found.work.number) \(found.work.title)").tag("issue-\(found.work.number)")
                                    }
                                }
                            }
                            if !pulls.isEmpty {
                                Section("Pull requests") {
                                    ForEach(pulls, id: \.work.number) { found in
                                        Text("#\(found.work.number) \(found.work.title)\(found.fromFork ? " (from a fork)" : "")")
                                            .tag("pr-\(found.work.number)")
                                    }
                                }
                            }
                        }
                        .disabled(loading)
                        if chosen?.work.isPullRequest == true {
                            Picker("Do", selection: $purpose) {
                                Text("Continue it").tag(Purpose.work)
                                Text("Review it").tag(Purpose.review)
                                Text("Review and comment").tag(Purpose.comment)
                            }
                            .pickerStyle(.segmented)
                        }
                    } footer: {
                        workFooter
                    }
                    Section {
                        TextEditor(text: $brief)
                            .font(.body)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .overlay(alignment: .topLeading) {
                                if brief.isEmpty {
                                    Text(chosen == nil ? "What should \(model.bot(botID)?.name ?? "the bot") do?" : "Anything to add? (optional)")
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    } header: {
                        Text(chosen == nil ? "Task" : "Notes")
                    } footer: {
                        Text("The task's first message. It starts with \(model.bot(botID)?.name ?? "the bot")'s instructions and memory, in a session of its own.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Picker("Account", selection: $accountID) {
                            ForEach(model.settings.accounts) { account in
                                Label(account.name, systemImage: account.symbol).tag(account.id)
                            }
                        }
                    } header: {
                        Text("Runs on")
                    } footer: {
                        taskFooter
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Task") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
                    .help(problem ?? "Prepare the task and send its first message")
            }
            .padding(16)
        }
        .frame(width: 560, height: 720)
        .task {
            accountID = model.bot(botID)?.accountID ?? Accounts.defaultID
            await model.loadRepositories()
            let wanted = initialRepo ?? (DevHooks.dataDir == nil ? lastRepo : DevHooks.env["BOTCHU_TASK_REPO"] ?? "")
            if repo == nil, let last = model.repositories?.first(where: { $0.nameWithOwner == wanted }) { choose(last.nameWithOwner) }
        }
        .onChange(of: workKey) {
            if chosen?.work.isPullRequest != true { purpose = .work }
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
        overridesPlacement = false
        placementProblem = nil
        openWork = []
        workKey = ""
        purpose = .work
        lookupError = nil
        loading = true
        Task {
            let location = await model.location(of: nameWithOwner)
            usual = await model.defaultLocation(of: nameWithOwner)
            guard repo == nameWithOwner else { return }
            placementProblem = model.projectPlacementProblem(nameWithOwner)
            hostID = location.hostID
            folder = displayed(location.path, on: location.hostID)
            let result = await GitHubLookup.openWork(repo: nameWithOwner)
            guard repo == nameWithOwner else { return }
            switch result {
            case .success(var found):
                // The issue or pull request this sheet was opened for may be beyond the list's first
                // hundred: read it on its own, so it is still the one chosen.
                if nameWithOwner == initialRepo, let wanted = initialWork,
                   !found.contains(where: { $0.work.number == wanted.number && $0.work.isPullRequest == wanted.isPullRequest }) {
                    switch await GitHubLookup.work(number: wanted.number, pullRequest: wanted.isPullRequest, repo: nameWithOwner) {
                    case .success(let item) where item.state == "OPEN": found.append(item)
                    case .success: lookupError = "\(wanted.isPullRequest ? "Pull request" : "Issue") #\(wanted.number) isn't open any more."
                    case .failure(let failure): lookupError = "\(failure.step). Is gh installed and signed in?"
                    }
                    guard repo == nameWithOwner else { return }
                }
                openWork = found
                if nameWithOwner == initialRepo, let wanted = initialWork,
                   found.contains(where: { $0.work.number == wanted.number && $0.work.isPullRequest == wanted.isPullRequest }) {
                    workKey = (wanted.isPullRequest ? "pr-" : "issue-") + "\(wanted.number)"
                    purpose = wanted.isPullRequest ? initialPurpose : .work
                }
            case .failure(let failure): lookupError = "\(failure.step). Is gh installed and signed in?"
            }
            loading = false
        }
    }

    /// A folder as the field shows it: with `~` for this Mac's home.
    private func displayed(_ path: String, on hostID: UUID?) -> String {
        hostID == nil ? (path as NSString).abbreviatingWithTildeInPath : path
    }

    @ViewBuilder private var locationFooter: some View {
        Group {
            if let folderProblem {
                Text(folderProblem).foregroundStyle(.red)
            } else if hostID != nil {
                Text("BotChu connects over SSH, clones the repository there if it isn't yet, and runs the task there. The task keeps \(model.bot(botID)?.name ?? "the bot")'s context from this Mac.")
            } else {
                Text("BotChu clones the repository here if it isn't yet.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Work

    /// The issue or pull request chosen.
    private var chosen: GitHubLookup.Found? {
        openWork.first { ($0.work.isPullRequest ? "pr-" : "issue-") + "\($0.work.number)" == workKey }
    }

    @ViewBuilder private var workFooter: some View {
        Group {
            if loading {
                Text("Reading open issues and pull requests…")
            } else if let lookupError {
                Text(lookupError).foregroundStyle(.red)
            } else if purpose == .comment {
                Text("The bot reviews the changes and posts one review on GitHub.")
            } else if purpose == .review {
                Text("The bot reviews the changes and gives its review here; it posts nothing.")
            } else {
                Text("Or describe something new below.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var taskFooter: some View {
        Group {
            if let conflict {
                Text(conflict).foregroundStyle(.red)
            } else {
                Text("Each task has its own workspace and conversation.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Starting

    /// Why the task can't start yet, or nil when it can.
    private var problem: String? {
        guard repo != nil else { return "Choose a project" }
        if let placementProblem, !overridesPlacement { return placementProblem }
        if loading { return "Reading the project workspace and open work…" }
        if chosen == nil, brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Say what to do, or choose an issue or pull request"
        }
        if chosen?.fromFork == true, purpose == .work { return "This pull request comes from a fork. Choose Review it or Review and comment." }
        return folderProblem ?? conflict
    }

    private var folderProblem: String? {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        if hostID == nil, !folder.hasPrefix("/"), !folder.hasPrefix("~") { return "The folder on this Mac starts with / or ~/." }
        return hostID == nil ? nil : SSHHost.folderProblem(folder)
    }

    /// Prevent two tasks working on the same issue or pull request. Fresh tasks get unique
    /// branches automatically during preparation, even when their briefs happen to match.
    private var conflict: String? {
        guard let repo, let other = model.taskAlreadyWorking(on: repo, hostID: hostID, work: chosen?.work,
                                                             review: purpose.review, branch: "") else { return nil }
        return "“\(other.title)” already works on this. Send it a message there."
    }

    private func start() {
        guard problem == nil, let bot = model.bot(botID), let repo else { return }
        var path = folder.trimmingCharacters(in: .whitespaces)
        if hostID == nil { path = (path as NSString).expandingTildeInPath }
        let location = RepoLocation(hostID: hostID, path: path)
        // A computer or folder other than the usual one is remembered for this repository.
        model.settings.repoLocations[repo] = !overridesPlacement && location == usual ? nil : location
        var task = BotTask(for: bot, repo: repo, checkout: location.path, work: chosen?.work,
                           brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                           host: model.settings.host(hostID), review: purpose.review)
        if accountID != bot.accountID { task.selectAccount(model.settings.account(accountID)) }
        lastRepo = repo
        model.startTask(task, for: botID, show: true)
        dismiss()
    }
}
