import Foundation
import BotChuCore

// Swift 6.4 can miscompile String-first tuple returns from task-group do/catch branches
// in optimized builds, losing results or completing children into a destroyed group.
// Keep a named result and one return: https://github.com/swiftlang/swift/issues/93208
private struct ProjectLoadResult: Sendable {
    let repo: String
    let result: Result<ProjectRecord, Error>
}

extension AppModel {
    func loadProjects(force: Bool = false) async {
        guard !projectsLoading else { return }
        await loadRepositories(force: force)
        await loadProjectRecords(force: force)
    }

    /// Reads the repositories again, then their PROJECT.md records and open work side by side.
    func refreshProjects() async {
        guard !projectsLoading else { return }
        await loadRepositories(force: true)
        let work = Task { await loadOpenWork(force: true) }
        await loadProjectRecords(force: true)
        await work.value
    }

    /// Reads the PROJECT.md of each repository not read yet (of every one, when `force`).
    func loadProjectRecords(force: Bool = false) async {
        guard !projectsLoading else { return }
        projectsLoading = true
        defer { projectsLoading = false }
        guard let repositories else { return }
        let pending = repositories.filter { force || projectRecords[$0.id] == nil && projectErrors[$0.id] == nil }
        // A small bounded batch prevents a large catalog from launching hundreds of gh processes.
        for start in stride(from: 0, to: pending.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = Array(pending[start..<min(start + 4, pending.count)])
            await withTaskGroup(of: ProjectLoadResult.self) { group in
                let client = projectGitHub
                for repo in batch {
                    group.addTask {
                        let result: Result<ProjectRecord, Error>
                        do { result = .success(try await client.record(repo: repo.id)) }
                        catch { result = .failure(error) }
                        return ProjectLoadResult(repo: repo.id, result: result)
                    }
                }
                for await loaded in group {
                    let repo = loaded.repo
                    switch loaded.result {
                    case .success(let record):
                        projectRecords[repo] = record
                        projectErrors[repo] = nil
                        deployTargetCache[repo] = Locations.deployTargets(projectFile: record.text)
                    case .failure(let error): projectErrors[repo] = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Reads the open pull requests and issues of the repositories GitHub counts any in, unless they
    /// were read in the last ten minutes.
    func loadOpenWork(force: Bool = false) async {
        guard !openItemsLoading else { return }
        if !force, openItems != nil, let read = openItemsReadAt, Date().timeIntervalSince(read) < 600 { return }
        guard let repositories else { return }
        openItemsLoading = true
        defer { openItemsLoading = false }
        let busy = repositories.filter { $0.openIssues + $0.openPullRequests > 0 }.map(\.id)
        switch busy.isEmpty ? .success(GitHubLookup.OpenWork(items: [])) : await openWorkLookup(busy) {
        case .success(let work):
            openItems = work.items
            openItemsError = work.unreadable.isEmpty ? nil
                : "Couldn't read the open pull requests and issues of \(work.unreadable.map(TaskNaming.repoName).joined(separator: ", ")). Refresh to try again."
            openItemsReadAt = Date()
        case .failure(let failure):
            openItemsError = "\(failure.step). Is gh installed and signed in?"
        }
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

extension AppModel {
    /// A project that names only machines not configured here must not silently become a local task.
    func projectPlacementProblem(_ repo: String) -> String? {
        if let chosen = settings.repoLocations[repo], chosen.hostID == nil || settings.host(chosen.hostID) != nil { return nil }
        let targets = deployTargetCache[repo] ?? []
        guard !targets.isEmpty else { return nil }
        let known = [settings.thisMacName] + settings.hosts.map(\.machine)
        guard !targets.contains(where: { target in known.contains { $0.caseInsensitiveCompare(target.machine) == .orderedSame } }) else { return nil }
        return "This project deploys on \(targets.map(\.machine).joined(separator: ", ")), which isn’t connected in Settings ▸ Hosts. Connect it there, or work on it on This Mac."
    }
}
