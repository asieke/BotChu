import SwiftUI
import BotChuCore

/// Starts a task for a bot: a repository checked out in the repositories folder, an open issue or
/// pull request there (or something new), what to do, the branch, and the account it runs on.
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let botID: UUID
    /// The checkout a task started in last time, chosen again first.
    @AppStorage("newTaskRepo") private var lastRepo = ""
    @State private var checkouts: [RepoCheckout]?
    @State private var repoPath = ""
    @State private var openWork: [GitHubLookup.Found] = []
    @State private var loading = false
    @State private var lookupError: String?
    /// The issue or pull request chosen (`issue-48`, `pr-12`), or "" for something new.
    @State private var workKey = ""
    @State private var brief = ""
    @State private var branch = ""
    /// The branch last filled in from the choice; once the field differs, the person chose it.
    @State private var autoBranch = ""
    @State private var accountID = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("New Task for \(model.bot(botID)?.name ?? "Bot")")
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    Picker("Repository", selection: $repoPath) {
                        if checkout == nil { Text(checkouts == nil ? "Looking…" : "Choose…").tag("") }
                        ForEach(checkouts ?? []) { checkout in
                            Text(checkout.repo).tag(checkout.path)
                        }
                    }
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
                    .disabled(checkout == nil || loading)
                } footer: {
                    repositoryFooter
                }
                Section {
                    TextEditor(text: $brief)
                        .font(.body)
                        .frame(minHeight: 110)
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
                    LabeledContent("Branch") {
                        TextField("Branch", text: $branch, prompt: Text(chosen == nil ? "Named from the task" : "Named from the issue"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .disabled(chosen?.work.isPullRequest == true)
                    }
                    Picker("Account", selection: $accountID) {
                        ForEach(Accounts.all) { account in
                            Label(account.name, systemImage: account.symbol).tag(account.id)
                        }
                    }
                } header: {
                    Text("Runs on")
                } footer: {
                    branchFooter
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
                    .help(problem ?? "Make the task's worktree and send its first message")
            }
            .padding(16)
        }
        .frame(width: 520, height: 640)
        .task {
            accountID = model.bot(botID)?.accountID ?? Accounts.defaultID
            let root = model.settings.expandedReposRoot
            // Off the main thread: the first look into ~/Desktop or ~/Documents waits on macOS's question.
            let found = await Task.detached { Repositories.scan(root: root) }.value
            checkouts = found
            repoPath = found.first(where: { $0.path == lastRepo })?.path ?? ""
        }
        .onChange(of: repoPath) { loadOpenWork() }
        .onChange(of: workKey) { refreshBranch() }
        .onChange(of: brief) { if chosen == nil { refreshBranch() } }
    }

    private var checkout: RepoCheckout? { checkouts?.first { $0.path == repoPath } }

    /// The issue or pull request chosen.
    private var chosen: GitHubLookup.Found? {
        openWork.first { ($0.work.isPullRequest ? "pr-" : "issue-") + "\($0.work.number)" == workKey }
    }

    /// Why the task can't start yet, or nil when it can.
    private var problem: String? {
        guard checkout != nil else { return "Choose a repository" }
        if chosen == nil, brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Say what to do, or choose an issue or pull request"
        }
        if chosen?.fromFork == true { return "A pull request from a fork has no branch on origin to work on" }
        return branchProblem
    }

    private var branchProblem: String? {
        let branch = branch.trimmingCharacters(in: .whitespaces)
        return !branch.isEmpty && !TaskNaming.isValidBranch(branch) ? "That isn't a branch name git takes." : nil
    }

    @ViewBuilder private var repositoryFooter: some View {
        Group {
            if checkouts?.isEmpty == true {
                Text("No git checkouts in \((model.settings.expandedReposRoot as NSString).abbreviatingWithTildeInPath). Choose the repositories folder in Settings.")
            } else if loading {
                Text("Reading open issues and pull requests…")
            } else if let lookupError {
                Text(lookupError).foregroundStyle(.red)
            } else if let checkout, checkout.nameWithOwner == nil {
                Text("Its origin isn't on GitHub, so there are no issues to choose from.")
            } else {
                Text("Repositories checked out in \((model.settings.expandedReposRoot as NSString).abbreviatingWithTildeInPath), as in Settings.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var branchFooter: some View {
        let branch = branch.trimmingCharacters(in: .whitespaces)
        Group {
            if let branchProblem {
                Text(branchProblem).foregroundStyle(.red)
            } else if checkout?.hasWorktreeScript == true, !branch.isEmpty, !TaskNaming.isStandardBranch(branch),
                      chosen?.work.isPullRequest != true {
                Text("The repository's scripts/worktree.sh takes only <feat|fix|chore|docs>/<slug> branches, so BotChu makes this one with git instead.")
            } else if checkout?.hasWorktreeScript == true {
                Text("The repository's scripts/worktree.sh makes the task's worktree in .claude/worktrees/, so the main checkout stays on its branch.")
            } else {
                Text("BotChu makes the task's worktree in .claude/worktrees/ of the checkout, so the main checkout stays on its branch.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func loadOpenWork() {
        openWork = []
        workKey = ""
        lookupError = nil
        guard let checkout, let repo = checkout.nameWithOwner else { return }
        loading = true
        Task {
            let result = await GitHubLookup.openWork(repo: repo, in: checkout.path)
            guard repoPath == checkout.path else { return }
            loading = false
            switch result {
            case .success(let found): openWork = found
            case .failure(let failure): lookupError = "\(failure.step). Is gh installed and signed in?"
            }
        }
    }

    /// Fills in the branch from the choice, unless the person typed their own.
    private func refreshBranch() {
        let next: String
        if let chosen {
            next = chosen.work.isPullRequest ? chosen.branch ?? "" : TaskNaming.branch(issue: chosen.work.number, text: chosen.work.title, fallback: "issue")
        } else {
            let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
            next = text.isEmpty ? "" : TaskNaming.branch(issue: nil, text: text, fallback: "task")
        }
        if branch == autoBranch || chosen?.work.isPullRequest == true { branch = next }
        autoBranch = next
    }

    private func start() {
        guard problem == nil, let bot = model.bot(botID), let checkout else { return }
        var task = BotTask(for: bot, repo: checkout.repo, checkout: checkout.path, work: chosen?.work,
                           brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
                           branch: branch.trimmingCharacters(in: .whitespaces))
        if accountID != bot.accountID { task.selectAccount(accountID) }
        lastRepo = checkout.path
        model.startTask(task, for: botID, show: true)
        dismiss()
    }
}
