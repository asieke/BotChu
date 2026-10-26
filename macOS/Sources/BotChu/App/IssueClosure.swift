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

    /// Closes the issue once confirmed. It leaves Projects, and the sidebar page showing it, at once
    /// (`ProjectSync` hides it until GitHub answers); when GitHub refuses it comes back, and
    /// `issueClosure` says why and offers to try again, unless another account signed in meanwhile.
    func closeIssue(_ request: IssueClosure) async {
        guard updatingIssues.insert(request.id).inserted else { return }
        defer { updatingIssues.remove(request.id) }
        let login = projectsLogin
        leaveIssueDetail(request.number, of: request.repo)
        guard case .failure(let failure) = await projectSync.closeIssue(request.number, of: request.repo),
              projectsLogin == login else { return }
        var failed = request
        failed.failure = failure.message
        // A late failure waits for the question asked meanwhile about another issue.
        if issueClosure == nil || issueClosure?.id == request.id { issueClosure = failed } else { closureFailures.append(failed) }
    }

    /// Puts the question or failure away, and shows the next failure that waited for it.
    func dismissIssueClosure() {
        issueClosure = closureFailures.isEmpty ? nil : closureFailures.removeFirst()
    }
}
