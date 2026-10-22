import Foundation
import BotChuCore

/// Where tasks work: the owner's GitHub repositories (the list tasks start from), the computer and
/// folder each is worked on, and the hosts reached over SSH.
extension AppModel {
    /// Reads the owner's GitHub repositories again, unless they were read in the last ten minutes.
    func loadRepositories(force: Bool = false) async {
        if !force, repositories != nil, let read = repositoriesReadAt, Date().timeIntervalSince(read) < 600 { return }
        if let task = repositoriesTask { await task.value; return }
        repositoriesLoading = true
        let task = Task { @MainActor in
            defer { repositoriesLoading = false; repositoriesTask = nil }
            switch await GitHubLookup.repositories() {
            case .success(let found):
                repositories = found
                repositoriesError = nil
                repositoriesReadAt = Date()
            case .failure(let failure):
                repositoriesError = "\(failure.step). Is gh installed and signed in?"
            }
        }
        repositoriesTask = task
        await task.value
    }

    /// Where a repository is worked on: where the owner chose, else where its PROJECT.md deploys it
    /// (on this Mac or on a host of that machine name), else in the repositories folder here.
    func location(of repo: String) async -> RepoLocation {
        Locations.resolve(repo: repo, chosen: settings.repoLocations[repo], deployTargets: await deployTargets(of: repo),
                          thisMac: settings.thisMacName, hosts: settings.hosts, reposRoot: settings.expandedReposRoot)
    }

    /// Where the repository is worked on by default, without the owner's choice.
    func defaultLocation(of repo: String) async -> RepoLocation {
        Locations.resolve(repo: repo, chosen: nil, deployTargets: await deployTargets(of: repo),
                          thisMac: settings.thisMacName, hosts: settings.hosts, reposRoot: settings.expandedReposRoot)
    }

    /// The folder a repository has on a computer: where its PROJECT.md deploys it there, else in that
    /// computer's repositories folder.
    func folder(of repo: String, on hostID: UUID?) async -> String {
        let targets = await deployTargets(of: repo)
        let machine = settings.host(hostID)?.machine ?? settings.thisMacName
        if let target = targets.first(where: { !machine.isEmpty && $0.machine.caseInsensitiveCompare(machine) == .orderedSame }) {
            return hostID == nil ? (target.path as NSString).expandingTildeInPath : target.path
        }
        let root = settings.host(hostID)?.reposFolder ?? settings.expandedReposRoot
        return (root as NSString).appendingPathComponent(TaskNaming.repoName(repo))
    }

    /// PROJECT.md's `local:` deploy targets for a repository on GitHub, read once.
    private func deployTargets(of repo: String) async -> [(machine: String, path: String)] {
        if let known = deployTargetCache[repo] { return known }
        guard repo.contains("/") else { return [] }
        let targets = await GitHubLookup.projectFile(repo: repo).map(Locations.deployTargets(projectFile:)) ?? []
        deployTargetCache[repo] = targets
        return targets
    }

    /// Where a task's commands run: this Mac, or its host, which must still be in Settings.
    func machine(of task: BotTask) -> Result<Machine, TaskWorktree.Failure> {
        guard let id = task.hostID else { return .success(.thisMac) }
        guard let host = settings.host(id) else {
            return .failure(TaskWorktree.Failure(step: "This task works on \(task.hostName ?? "a host") over SSH, which isn't in Settings ▸ Hosts any more",
                                                 output: "Add it again there (with the same nickname), or start a new task."))
        }
        return .success(Machine(destination: host.destination))
    }

    /// "This Mac", or the host's nickname.
    func machineName(_ hostID: UUID?, fallback: String? = nil) -> String {
        guard let hostID else { return "This Mac" }
        return settings.host(hostID)?.nickname ?? fallback ?? "a host"
    }

    /// A task's computer as its preamble names it: "Omarchy (asieke@omarchy)"; nil on this Mac.
    func machineDescription(of task: BotTask) -> String? {
        guard task.isRemote else { return nil }
        guard let host = settings.host(task.hostID) else { return task.hostName }
        return "\(host.nickname) (\(host.destination))"
    }

    /// The host a request names, by nickname, machine name or SSH destination; This Mac is nil.
    func host(named name: String) -> Result<SSHHost?, TaskRequest.Problem> {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if ["this mac", "mac", "local", "here", settings.thisMacName.lowercased()].contains(wanted.lowercased()) { return .success(nil) }
        if let host = settings.hosts.first(where: { [$0.nickname, $0.machine, $0.destination].contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } }) {
            return .success(host)
        }
        let known = (["This Mac"] + settings.hosts.map(\.nickname)).joined(separator: ", ")
        return .failure(TaskRequest.Problem(message: "there is no computer called “\(wanted)” (there are: \(known))"))
    }

    /// The repository a request names: one of the owner's GitHub repositories, by `owner/name` or
    /// its name alone; else a checkout on this Mac, by its folder or name.
    func repository(named reference: String, checkouts: [RepoCheckout]) -> Result<(repo: String, checkout: RepoCheckout?), TaskRequest.Problem> {
        let wanted = (Repositories.nameWithOwner(remote: reference) ?? reference).trimmingCharacters(in: .whitespaces)
        if !wanted.hasPrefix("/"), !wanted.hasPrefix("~"), let repositories {
            if let exact = repositories.first(where: { $0.nameWithOwner.caseInsensitiveCompare(wanted) == .orderedSame }) {
                return .success((exact.nameWithOwner, nil))
            }
            let named = repositories.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            if named.count == 1 { return .success((named[0].nameWithOwner, nil)) }
            if named.count > 1 {
                return .failure(TaskRequest.Problem(message: "several repositories are called \(wanted): name one as owner/name (\(named.map(\.nameWithOwner).joined(separator: ", ")))"))
            }
        }
        if let checkout = Repositories.find(wanted, in: checkouts) { return .success((checkout.repo, checkout)) }
        return .failure(TaskRequest.Problem(message: repositories == nil
            ? "\(wanted) isn't checked out here, and your GitHub repositories couldn't be read (\(repositoriesError ?? "gh failed"))"
            : "\(wanted) isn't one of your GitHub repositories"))
    }
}
