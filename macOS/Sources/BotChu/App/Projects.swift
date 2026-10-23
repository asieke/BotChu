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
