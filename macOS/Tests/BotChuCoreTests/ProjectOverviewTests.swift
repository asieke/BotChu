import Foundation
import Testing
@testable import BotChuCore

@Suite struct ProjectOverviewTests {
    @Test func readsRepositoriesWithTheirOpenWork() {
        // As `gh api graphql --paginate … --jq '… | @tsv'` prints them (repositoriesFields).
        let tsv = """
            asieke/BotChu\t\tfalse\t2026-10-23T01:41:28Z\tfalse\thttps://avatars.githubusercontent.com/u/4070885?s=64&v=4\tUser\tfalse\tSwift\t2\t3
            Humanist-Venture-Studio/internal-brain\tInternal knowledge\\tand ways\tfalse\t2026-10-22T23:28:21Z\ttrue\thttps://avatars.githubusercontent.com/u/293191397?s=64&v=4\tOrganization\ttrue\t\t1\t0
            asieke/old\t\ttrue\t2026-10-01T00:00:00Z\tfalse\t\tUser\tfalse\t\t0\t0
            """
        let repos = GitHubLookup.parseRepositories(tsv)
        #expect(repos.map(\.nameWithOwner) == ["asieke/BotChu", "Humanist-Venture-Studio/internal-brain"])
        #expect(repos[0].openIssues == 2)
        #expect(repos[0].openPullRequests == 3)
        #expect(repos[0].language == "Swift")
        #expect(repos[0].ownerAvatar?.host == "avatars.githubusercontent.com")
        #expect(!repos[0].ownerIsOrganization)
        #expect(repos[1].ownerIsOrganization)
        #expect(repos[1].isFork)
        #expect(repos[1].isPrivate)
        #expect(repos[1].language == nil)
        #expect(repos[1].description == "Internal knowledge and ways")
        #expect(repos[1].owner == "Humanist-Venture-Studio")
    }

    @Test func readsOpenPullRequestsAndIssuesDespiteAMissingRepository() throws {
        // A real answer to openWorkQuery (trimmed to two of each), with a repository GitHub can't
        // resolve: gh exits 1 then, but still prints the data for the rest.
        let output = #"""
            {"data":{"r0":{"nameWithOwner":"asieke/BotChu","pullRequests":{"nodes":[{"number":41,"title":"Fix the chat not autoscrolling as replies stream in","url":"https://github.com/asieke/BotChu/pull/41","isDraft":false,"createdAt":"2026-10-23T01:37:10Z","updatedAt":"2026-10-23T01:37:10Z","author":{"login":"asieke","avatarUrl":"https://avatars.githubusercontent.com/u/4070885?s=64&v=4"},"reviewDecision":null,"headRefName":"fix/chat-autoscroll","isCrossRepository":false,"comments":{"totalCount":0},"additions":4,"deletions":1,"labels":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}},{"number":38,"title":"Grow the message composer and support image attachments","url":"https://github.com/asieke/BotChu/pull/38","isDraft":true,"createdAt":"2026-10-22T22:42:43Z","updatedAt":"2026-10-22T22:44:25Z","author":{"login":"asieke","avatarUrl":"https://avatars.githubusercontent.com/u/4070885?s=64&v=4"},"reviewDecision":"CHANGES_REQUESTED","headRefName":"feat/37-composer-images","isCrossRepository":true,"comments":{"totalCount":2},"additions":709,"deletions":45,"labels":{"nodes":[{"name":"enhancement","color":"a2eeef"}]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}]},"issues":{"nodes":[{"number":42,"title":"Bot instructions as INSTRUCTIONS.md + shared TEAM.md playbook","url":"https://github.com/asieke/BotChu/issues/42","createdAt":"2026-10-23T01:41:20Z","updatedAt":"2026-10-23T01:41:20Z","author":{"login":"asieke","avatarUrl":"https://avatars.githubusercontent.com/u/4070885?s=64&v=4"},"comments":{"totalCount":0},"labels":{"nodes":[]}},{"number":37,"title":"Grow the composer and support image attachments","url":"https://github.com/asieke/BotChu/issues/37","createdAt":"2026-10-22T22:31:52Z","updatedAt":"2026-10-22T22:31:52Z","author":null,"comments":{"totalCount":3},"labels":{"nodes":[]}}]}},"r1":null},"errors":[{"type":"NOT_FOUND","path":["r1"],"locations":[{"line":1,"column":688}],"message":"Could not resolve to a Repository with the name 'asieke/nope-not-here-xyz'."}]}
            """#
        let items = try #require(GitHubLookup.parseOpenWork(output))
        let pulls = items.filter(\.isPullRequest), issues = items.filter { !$0.isPullRequest }
        #expect(pulls.map(\.number) == [41, 38])
        #expect(issues.map(\.number) == [42, 37])
        #expect(pulls[0].checks == .success)
        #expect(pulls[0].branch == "fix/chat-autoscroll")
        #expect(pulls[0].id == "asieke/BotChu#41")
        #expect(pulls[1].checks == .failure)
        #expect(pulls[1].isDraft)
        #expect(pulls[1].fromFork)
        #expect(pulls[1].reviewDecision == "CHANGES_REQUESTED")
        #expect(pulls[1].labels == [GitHubLookup.OpenItem.Label(name: "enhancement", color: "a2eeef")])
        #expect(pulls[1].changeSize == 754)
        #expect(issues[0].checks == .none)
        #expect(issues[1].author == "ghost")
        #expect(issues[1].comments == 3)
        #expect(issues[0].work == BotTask.Work(number: 42, title: issues[0].title, url: issues[0].url, isPullRequest: false))
        #expect(GitHubLookup.parseOpenWork("gh: Bad credentials") == nil)
        #expect(GitHubLookup.parseOpenWork(#"{"errors":[{"message":"Bad credentials"}]}"#) == nil)
    }

    @Test func asksOnlyAboutSafeRepositoryNames() {
        #expect(GitHubLookup.isSafeName("Humanist-Venture-Studio/agora-v2"))
        #expect(GitHubLookup.isSafeName("a.b/c_d"))
        #expect(!GitHubLookup.isSafeName("asieke/BotChu\") { x }"))
        #expect(!GitHubLookup.isSafeName("asieke"))
        #expect(!GitHubLookup.isSafeName("a/b/c"))
        let query = GitHubLookup.openWorkQuery(["asieke/BotChu", "octo/cat"])
        #expect(query.contains(#"r0: repository(owner: "asieke", name: "BotChu")"#))
        #expect(query.contains(#"r1: repository(owner: "octo", name: "cat")"#))
        #expect(query.contains("pullRequests(states: OPEN, first: 30"))
    }

    @Test func readsDeployTargetsForDisplay() {
        let targets = DeployTarget.parse("local:Alexs-MacBook-Pro-92440:~/Desktop/WORKSPACE/BotChu, vercel:rowchuk, ftp:weird")
        #expect(targets.map(\.kind) == [.local, .vercel, .unrecognized])
        #expect(targets[0].name == "Alexs-MacBook-Pro-92440")
        #expect(targets[0].path == "~/Desktop/WORKSPACE/BotChu")
        #expect(targets[1].name == "rowchuk")
        #expect(DeployTarget.parse("none").map(\.kind) == [.none])
        #expect(DeployTarget.parse("registry:swift").first?.name == "swift")
    }

    @Test func buildsRowsWithRecordsPlacesAndTasks() throws {
        let host = SSHHost(nickname: "Omarchy", destination: "asieke@omarchy", machine: "omarchy")
        let repos = [
            GitHubLookup.Repo(nameWithOwner: "asieke/BotChu", description: "Bots", openIssues: 2, openPullRequests: 3),
            GitHubLookup.Repo(nameWithOwner: "asieke/talent"),
            GitHubLookup.Repo(nameWithOwner: "asieke/new"),
            GitHubLookup.Repo(nameWithOwner: "asieke/broken"),
            GitHubLookup.Repo(nameWithOwner: "asieke/loading"),
        ]
        let local = ProjectMetadata(name: "BotChu", kind: .local, deploy: "local:my-mac:~/apps/BotChu", merge: "agent")
        let hosted = ProjectMetadata(name: "Talent", kind: .hosted, status: .paused, deploy: "local:omarchy:~/apps/talent, vercel:talent")
        let records = [
            "asieke/BotChu": ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(local), sha: "a"),
            "asieke/talent": ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(hosted), sha: "b"),
            "asieke/new": ProjectRecord(text: "", sha: nil),
            "asieke/broken": ProjectRecord(text: "---\ntype: spaceship\n---\n", sha: "c"),
        ]
        let rows = ProjectRow.rows(repos: repos, records: records, chosen: [:], thisMac: "my-mac", hosts: [host], reposRoot: "/repos",
                                   taskRepos: ["asieke/BotChu", "ASIEKE/botchu", "asieke/talent"])
        #expect(rows.map(\.workplace) == ["This Mac", "Omarchy", "This Mac", "This Mac", "This Mac"])
        #expect(rows[0].location.path == NSHomeDirectory() + "/apps/BotChu")
        #expect(rows[1].location == RepoLocation(hostID: host.id, path: "~/apps/talent"))
        #expect(rows[2].location.path == "/repos/new")
        #expect(rows.map(\.openTasks) == [2, 1, 0, 0, 0])
        #expect(rows[0].metadata == local)
        #expect(rows[0].mergeKey == 2)
        #expect(rows[1].deploy.map(\.kind) == [.local, .vercel])
        #expect(rows[1].statusKey > rows[0].statusKey)
        #expect(rows[2].record == .missing)
        #expect(rows[3].record == .invalid)
        #expect(rows[4].record == .loading)
        #expect(rows[4].typeKey == 0)
        #expect(rows[0].openPullRequests == 3)
        #expect(rows[0].matches("bots local"))
        #expect(rows[1].matches("omarchy"))
        #expect(!rows[1].matches("bots"))
    }
}
