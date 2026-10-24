import Foundation
import BotChuCore

extension AppModel {
    /// Shows the Projects catalog saved on disk as soon as it is read (off the main thread), and
    /// every change a sync makes to it from then on.
    func showSavedProjects() {
        let sync = projectSync, updates = projectSync.updates
        Task { [weak self] in
            for await state in updates { self?.showProjects(state) }
        }
        Task { await sync.load() }
    }

    /// Takes what the catalog holds now. Until something was saved or read for an account, what is
    /// shown stays as it is.
    func showProjects(_ state: ProjectSync.State) {
        if projectsLoading != (state.syncing != nil) { projectsLoading = state.syncing != nil }
        if repositoriesError != state.error { repositoriesError = state.error }
        guard state.login != nil else { return }
        if projectsLogin != state.login { projectsLogin = state.login }
        if repositoriesReadAt != state.syncedAt { repositoriesReadAt = state.syncedAt }
        if repositories != state.repositories { repositories = state.repositories }
        if projectRecords != state.records { projectRecords = state.records }
        if projectErrors != state.recordErrors { projectErrors = state.recordErrors }
        if openItems != state.openItems { openItems = state.openItems }
        let error = state.unreadableWork.isEmpty ? nil
            : "Couldn't read the open pull requests and issues of \(state.unreadableWork.map(TaskNaming.repoName).joined(separator: ", ")). Refresh to try again."
        if openItemsError != error { openItemsError = error }
    }

    /// Syncs the Projects catalog with GitHub unless it is current (synced in the last two minutes):
    /// a check for changes, or a full sync every half hour; `force` syncs in full now.
    func loadProjects(force: Bool = false) async {
        if force { return await refreshProjects() }
        if repositories != nil, let read = repositoriesReadAt, Date().timeIntervalSince(read) < ProjectSync.staleAfter { return }
        await projectSync.syncIfStale()
    }

    /// A full sync now, or right after the one under way, however often it is asked for.
    func refreshProjects() async {
        await projectSync.sync(.full)
    }

    /// The projects as saved, for readers that mustn't wait on GitHub (such as `#project` completion).
    var projectCatalog: [ProjectCatalogEntry] {
        ProjectRow.rows(repos: repositories ?? [], records: projectRecords, errors: projectErrors, chosen: settings.repoLocations,
                        hosts: settings.hosts, reposRoot: settings.expandedReposRoot, taskRepos: [])
            .map(\.catalogEntry)
    }

    /// The open tasks, of every bot, as (bot, task) pairs.
    var openTasks: [(bot: Bot, task: BotTask)] {
        bots.flatMap { bot in (tasks[bot.id] ?? []).filter { !$0.isArchived }.map { (bot, $0) } }
    }

    /// The open tasks on this issue or pull request, or (for a pull request) the tasks that opened it,
    /// among `open` (every open task when nil).
    func tasks(on item: GitHubLookup.OpenItem, among open: [(bot: Bot, task: BotTask)]? = nil) -> [(bot: Bot, task: BotTask)] {
        tasks(onNumber: item.number, pullRequest: item.isPullRequest, in: item.repo, among: open)
    }

    func tasks(onNumber number: Int, pullRequest: Bool, in repo: String, among open: [(bot: Bot, task: BotTask)]? = nil) -> [(bot: Bot, task: BotTask)] {
        (open ?? openTasks).filter { pair in
            pair.task.repo.caseInsensitiveCompare(repo) == .orderedSame
                && (pair.task.work.map { $0.number == number && $0.isPullRequest == pullRequest } == true
                    || pullRequest && pair.task.pullRequest == number)
        }
    }

    // MARK: The Projects sidebar

    /// Shows `repo` in the Projects sidebar: on `tab` with `item` opened there, or, without a tab, on
    /// the tab it shows already (keeping what is opened there, for the same repository). Nil hides it.
    func selectProject(_ repo: String?, tab: ProjectSelection.Tab? = nil, item: Int? = nil) {
        guard let repo else { projectSelection = nil; return }
        if let tab {
            projectSelection = ProjectSelection(repo: repo, tab: tab, item: item)
        } else if projectSelection?.repo != repo {
            projectSelection = ProjectSelection(repo: repo, tab: projectSelection?.tab ?? .overview)
        }
    }

    /// The repository's open issues, or pull requests, as read for Projects: most recently updated first.
    func openWork(of repo: String, pulls: Bool) -> [GitHubLookup.OpenItem] {
        (openItems ?? []).filter { $0.isPullRequest == pulls && $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
    }

    /// The issues Fix All gives out: those no open task works on.
    func issuesToFix(in repo: String) -> [GitHubLookup.OpenItem] {
        let open = openTasks
        return openWork(of: repo, pulls: false).filter { tasks(on: $0, among: open).isEmpty }
    }

    /// The pull requests Review All gives out: those no open task is reviewing already.
    func pullRequestsToReview(in repo: String) -> [GitHubLookup.OpenItem] {
        let open = openTasks
        return openWork(of: repo, pulls: true).filter { item in !tasks(on: item, among: open).contains { $0.task.review != nil } }
    }

    /// Opens New Task for one task in which the bot fixes each issue `issuesToFix` lists with a
    /// parallel sub-agent of its own.
    func fixAllIssues(in repo: String, with botID: UUID) {
        let issues = issuesToFix(in: repo)
        guard let bot = bot(botID), !issues.isEmpty else { return }
        newTask(for: botID, repo: repo, brief: FanOutBrief.fixIssues(issues.map(\.work), repo: repo, agent: subagentName(of: bot)))
    }

    /// Opens New Task for one task in which the bot reviews each pull request `pullRequestsToReview`
    /// lists with a parallel sub-agent of its own, posting the reviews on GitHub when `comment`.
    func reviewAllPullRequests(in repo: String, with botID: UUID, comment: Bool) {
        let pulls = pullRequestsToReview(in: repo)
        guard let bot = bot(botID), !pulls.isEmpty else { return }
        newTask(for: botID, repo: repo,
                brief: FanOutBrief.reviewPullRequests(pulls.map(\.work), repo: repo, agent: subagentName(of: bot), comment: comment))
    }

    /// How `botchu-subagent` finds the bot: by its name, or by its id when the name finds another too.
    func subagentName(of bot: Bot) -> String {
        (try? SubagentResolver.resolve(bot.name, bots: bots))?.id == bot.id ? bot.name : bot.id.uuidString
    }

    func checkGitHub() async {
        guard !githubChecking else { return }
        githubChecking = true
        defer { githubChecking = false }
        githubConnection = await projectGitHub.connection()
    }
}
