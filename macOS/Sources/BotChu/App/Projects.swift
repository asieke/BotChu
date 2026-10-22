import Foundation
import BotChuCore

extension AppModel {
    func loadProjects(force: Bool = false) async {
        guard !projectsLoading else { return }
        projectsLoading = true
        defer { projectsLoading = false }
        await loadRepositories(force: force)
        guard let repositories else { return }
        let pending = repositories.filter { force || projectRecords[$0.id] == nil && projectErrors[$0.id] == nil }
        // A small bounded batch prevents a large catalog from launching hundreds of gh processes.
        for start in stride(from: 0, to: pending.count, by: 4) {
            guard !Task.isCancelled else { return }
            let batch = Array(pending[start..<min(start + 4, pending.count)])
            await withTaskGroup(of: (String, Result<ProjectRecord, Error>).self) { group in
                let client = projectGitHub
                for repo in batch {
                    group.addTask {
                        do { return (repo.id, .success(try await client.record(repo: repo.id))) }
                        catch { return (repo.id, .failure(error)) }
                    }
                }
                for await (repo, result) in group {
                    switch result {
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
        return "This project deploys on \(targets.map(\.machine).joined(separator: ", ")), which isn’t connected in Settings ▸ Hosts. Connect it there, or choose a workspace override."
    }
}
