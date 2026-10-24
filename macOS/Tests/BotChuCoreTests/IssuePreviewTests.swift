import Foundation
import Testing
@testable import BotChuCore

/// A task's glance at its repository's open issues (#113), from the saved Projects catalog.
@Suite struct IssuePreviewTests {
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    private static func item(_ repo: String, _ number: Int, pull: Bool = false, updated: Int? = nil, title: String? = nil) -> GitHubLookup.OpenItem {
        GitHubLookup.OpenItem(repo: repo, number: number, title: title ?? "Item \(number)",
                              url: URL(string: "https://github.com/\(repo)/\(pull ? "pull" : "issues")/\(number)")!, isPullRequest: pull,
                              author: "octocat", createdAt: base, updatedAt: base.addingTimeInterval(TimeInterval(updated ?? number)))
    }

    @Test func theCountIsGitHubsWhateverThePreviewOrTheReadListHolds() {
        // GitHub counts 42 open issues; the sync read its 30 most recently updated, and pull requests.
        let issues = (1...30).map { Self.item("asieke/BotChu", $0) }
        let pulls = (100...104).map { Self.item("asieke/BotChu", $0, pull: true, updated: 1_000 + $0) }
        let other = [Self.item("asieke/Orbit", 9, updated: 5_000)]
        let preview = IssuePreview(repo: "asieke/BotChu", statuses: ["asieke/botchu": OpenIssueStatus(count: 42)],
                                   items: (other + pulls + issues).shuffled(), syncing: false, error: nil)
        #expect(preview.count == .known(42))
        #expect(preview.heading == "Issues · 42")
        #expect(preview.accessibilityHeading == "Issues, 42 open")
        #expect(preview.issues.map(\.number) == [30, 29, 28, 27, 26])
        #expect(preview.issues.allSatisfy { !$0.isPullRequest && $0.repo == "asieke/BotChu" })
        #expect(preview.hasMore)
        #expect(!preview.unread)
        #expect(preview.note == nil)

        // Fewer than the preview lists: nothing more to show, and the count still comes from GitHub.
        let few = IssuePreview(repo: "asieke/BotChu", statuses: ["asieke/botchu": OpenIssueStatus(count: 2)],
                               items: Array(issues.prefix(2)) + pulls, syncing: false, error: nil)
        #expect(few.issues.map(\.number) == [2, 1])
        #expect(few.total == 2)
        #expect(!few.hasMore)
    }

    @Test func eachRepositoryShowsOnlyItsOwnAndCaseDoesntMatter() {
        let statuses = ["asieke/botchu": OpenIssueStatus(count: 3), "asieke/orbit": OpenIssueStatus(count: 1)]
        let items = [Self.item("asieke/BotChu", 1), Self.item("asieke/BotChu", 2), Self.item("asieke/BotChu", 3),
                     Self.item("asieke/Orbit", 7, updated: 99)]
        let botchu = IssuePreview(repo: "ASIEKE/botchu", statuses: statuses, items: items, syncing: false, error: nil)
        let orbit = IssuePreview(repo: "asieke/Orbit", statuses: statuses, items: items, syncing: false, error: nil)
        #expect(botchu.heading == "Issues · 3")
        #expect(botchu.issues.map(\.number) == [3, 2, 1])
        #expect(orbit.heading == "Issues · 1")
        #expect(orbit.issues.map(\.id) == ["asieke/Orbit#7"])
    }

    @Test func zeroIsOnlyEverAConfirmedZero() {
        let zero = IssuePreview(repo: "asieke/Notes", statuses: ["asieke/notes": OpenIssueStatus(count: 0)], items: [], syncing: false, error: nil)
        #expect(zero.count == .known(0))
        #expect(zero.heading == "Issues · 0")
        #expect(zero.note == nil)
        #expect(!zero.unread)

        // Nothing read for the account yet: loading while (or before) a sync reads it, unknown once one failed.
        let first = IssuePreview(repo: "asieke/Notes", statuses: nil, items: nil, syncing: true, error: nil)
        #expect(first.count == .loading)
        #expect(first.heading == "Issues")
        #expect(first.note == "Reading…")
        #expect(IssuePreview(repo: "asieke/Notes", statuses: nil, items: nil, syncing: false, error: nil).count == .loading)
        let offline = IssuePreview(repo: "asieke/Notes", statuses: nil, items: nil, syncing: false, error: "Couldn't reach GitHub.")
        #expect(offline.count == .unknown)
        #expect(offline.problem == "Couldn't reach GitHub.")
        #expect(offline.note == "Couldn't read")

        // Listed, its open work not read yet.
        let listed = ["asieke/orbit": OpenIssueStatus(count: nil)]
        #expect(IssuePreview(repo: "asieke/Orbit", statuses: listed, items: [], syncing: true, error: nil).count == .loading)
        let unread = IssuePreview(repo: "asieke/Orbit", statuses: listed, items: [], syncing: false, error: nil)
        #expect(unread.count == .unknown)
        #expect(unread.note == "Not read")
        #expect(unread.heading == "Issues")
        let failed = IssuePreview(repo: "asieke/Orbit", statuses: ["asieke/orbit": OpenIssueStatus(count: nil, problem: "GitHub couldn't answer.")],
                                  items: [], syncing: false, error: nil)
        #expect(failed.count == .unknown)
        #expect(failed.note == "Couldn't read")
        #expect(failed.accessibilityHeading == "Issues, couldn't read")

        // Not one of the account's repositories (an issue read for it before doesn't count).
        let elsewhere = IssuePreview(repo: "octocat/hello-world", statuses: listed, items: [Self.item("octocat/hello-world", 1)],
                                     syncing: false, error: nil)
        #expect(elsewhere.count == .unavailable)
        #expect(elsewhere.issues.isEmpty)
        #expect(elsewhere.note == "Unavailable")

        // GitHub counts some, but none were read: not an empty backlog.
        let none = IssuePreview(repo: "asieke/Orbit", statuses: ["asieke/orbit": OpenIssueStatus(count: 4)], items: [], syncing: false, error: nil)
        #expect(none.unread)
        #expect(none.heading == "Issues · 4")
    }

    @Test func aFailedRefreshKeepsWhatWasReadAndSaysSo() {
        let items = [Self.item("asieke/Orbit", 3), Self.item("asieke/Orbit", 4)]
        let stale = IssuePreview(repo: "asieke/Orbit", statuses: ["asieke/orbit": OpenIssueStatus(count: 2, problem: "GitHub couldn't answer.")],
                                 items: items, syncing: false, error: nil)
        #expect(stale.count == .known(2))
        #expect(stale.issues.map(\.number) == [4, 3])
        #expect(stale.problem == "GitHub couldn't answer.")
        #expect(stale.note == "Not updated")
        let offline = IssuePreview(repo: "asieke/Orbit", statuses: ["asieke/orbit": OpenIssueStatus(count: 2)], items: items,
                                   syncing: false, error: "Couldn't reach GitHub.")
        #expect(offline.count == .known(2))
        #expect(offline.problem == "Couldn't reach GitHub.")
        #expect(offline.note == "Not updated")
        let syncing = IssuePreview(repo: "asieke/Orbit", statuses: ["asieke/orbit": OpenIssueStatus(count: 2)], items: items,
                                   syncing: true, error: nil)
        #expect(syncing.note == "Syncing…")
        #expect(syncing.issues.count == 2)
    }

    @Test func switchingRepositoriesNeverShowsAnotherRepositorysAnswer() {
        var snapshot = ProjectSnapshot(login: "asieke")
        let botchu = ProjectSnapshot.Listed(nameWithOwner: "asieke/BotChu", openCount: 3)
        let orbit = ProjectSnapshot.Listed(nameWithOwner: "asieke/Orbit", openCount: 2)
        snapshot.takeList([ProjectSnapshot.Page(etag: "1", repos: [botchu, orbit])], complete: true)
        let fingerprints = ["asieke/BotChu": botchu.fingerprint, "asieke/Orbit": orbit.fingerprint]
        func preview(_ repo: String) -> IssuePreview {
            IssuePreview(repo: repo, statuses: snapshot.issueStatus, items: snapshot.openItems, syncing: false, error: nil)
        }
        snapshot.takeWork(["asieke/Orbit"], .success(GitHubLookup.OpenWork(
            items: [Self.item("asieke/Orbit", 3), Self.item("asieke/Orbit", 4)],
            counts: ["asieke/Orbit": GitHubLookup.OpenCounts(issues: 2, pullRequests: 0)])), under: fingerprints, etags: [:])
        // The owner moves from a task on Orbit to one on BotChu before BotChu's answer arrives.
        #expect(preview("asieke/Orbit").heading == "Issues · 2")
        let waiting = preview("asieke/BotChu")
        #expect(waiting.count == .unknown)
        #expect(waiting.issues.isEmpty)
        // A late answer for Orbit changes nothing under BotChu; BotChu's own answer fills it in.
        snapshot.takeWork(["asieke/Orbit"], .success(GitHubLookup.OpenWork(
            items: [Self.item("asieke/Orbit", 3), Self.item("asieke/Orbit", 4), Self.item("asieke/Orbit", 5)],
            counts: ["asieke/Orbit": GitHubLookup.OpenCounts(issues: 3, pullRequests: 0)])), under: fingerprints, etags: [:])
        #expect(preview("asieke/BotChu") == waiting)
        snapshot.takeWork(["asieke/BotChu"], .success(GitHubLookup.OpenWork(
            items: [Self.item("asieke/BotChu", 8), Self.item("asieke/BotChu", 9, pull: true)],
            counts: ["asieke/BotChu": GitHubLookup.OpenCounts(issues: 1, pullRequests: 2)])), under: fingerprints, etags: [:])
        let shown = preview("asieke/BotChu")
        #expect(shown.heading == "Issues · 1")
        #expect(shown.issues.map(\.number) == [8])
        #expect(preview("asieke/Orbit").heading == "Issues · 3")
    }

    @Test func theCatalogCountsIssuesWithoutPullRequests() {
        var snapshot = ProjectSnapshot(login: "asieke")
        let busy = ProjectSnapshot.Listed(nameWithOwner: "asieke/BotChu", openCount: 5)
        let quiet = ProjectSnapshot.Listed(nameWithOwner: "asieke/Notes", openCount: 0)
        let archived = ProjectSnapshot.Listed(nameWithOwner: "asieke/Old", isArchived: true, openCount: 1)
        snapshot.takeList([ProjectSnapshot.Page(etag: "1", repos: [busy, quiet, archived])], complete: true)
        let fingerprints = ["asieke/BotChu": busy.fingerprint, "asieke/Notes": quiet.fingerprint]
        #expect(snapshot.issueStatus == ["asieke/botchu": OpenIssueStatus(count: nil), "asieke/notes": OpenIssueStatus(count: 0)])

        snapshot.takeWork(["asieke/BotChu"], .success(GitHubLookup.OpenWork(
            items: [Self.item("asieke/BotChu", 1), Self.item("asieke/BotChu", 2, pull: true)],
            counts: ["asieke/BotChu": GitHubLookup.OpenCounts(issues: 3, pullRequests: 2)])), under: fingerprints, etags: [:])
        #expect(snapshot.issueStatus["asieke/botchu"] == OpenIssueStatus(count: 3))

        // A read that fails keeps the count read before, with why; a repository with nothing open
        // is a confirmed zero whatever failed before.
        snapshot.takeWork(["asieke/BotChu", "asieke/Notes"], .failure(TaskWorktree.Failure(step: "Couldn't read open work", output: "")),
                          under: fingerprints, etags: [:])
        #expect(snapshot.issueStatus["asieke/botchu"] == OpenIssueStatus(count: 3, problem: "Couldn't read open work"))
        #expect(snapshot.issueStatus["asieke/notes"] == OpenIssueStatus(count: 0))
    }
}
