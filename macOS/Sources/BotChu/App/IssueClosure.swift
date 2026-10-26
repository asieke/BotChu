import Foundation
import BotChuCore

/// Two ways to put an issue away, both using GitHub's reversible "not planned" closure.
struct IssueClosure: Identifiable, Equatable {
    enum Disposition: String, CaseIterable {
        case archive, obsolete

        var action: String { self == .archive ? "Archive Issue" : "Mark Obsolete" }
        var question: String { self == .archive ? "Archive issue" : "Mark obsolete: issue" }
    }

    var repo: String
    var number: Int
    var title: String
    var disposition: Disposition
    var failure: String?
    var id: String { "\(repo)#\(number)" }
}

extension AppModel {
    func askToCloseIssue(_ number: Int, of repo: String, title: String, as disposition: IssueClosure.Disposition) {
        issueClosure = IssueClosure(repo: repo, number: number, title: title, disposition: disposition)
    }

    func closeIssue(_ request: IssueClosure) async {
        guard updatingIssues.insert(request.id).inserted else { return }
        defer { updatingIssues.remove(request.id) }
        switch await projectSync.closeIssue(request.number, of: request.repo) {
        case .success:
            showProjects(await projectSync.state)
            leaveIssueDetail(request.number, of: request.repo)
        case .failure(let failure):
            var failed = request
            failed.failure = failure.message
            issueClosure = failed
        }
    }
}
