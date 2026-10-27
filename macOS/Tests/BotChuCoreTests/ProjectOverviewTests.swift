import Foundation
import Testing
@testable import BotChuCore

@Suite struct ProjectOverviewTests {
    @Test func readsOpenPullRequestsAndIssuesDespiteAMissingRepository() throws {
        // A real answer to openWorkQuery (trimmed to two of each), with a repository GitHub can't
        // resolve: gh exits 1 then, but still prints the data for the rest.
        let output = #"""
            {"data":{"r0":{"nameWithOwner":"asieke/BotChu","pullRequests":{"nodes":[{"number":41,"title":"Fix the chat not autoscrolling as replies stream in","url":"https://github.com/asieke/BotChu/pull/41","isDraft":false,"createdAt":"2026-10-23T01:37:10Z","updatedAt":"2026-10-23T01:37:10Z","author":{"login":"asieke","avatarUrl":"https://avatars.githubusercontent.com/u/4070885?s=64&v=4"},"reviewDecision":null,"headRefName":"fix/chat-autoscroll","isCrossRepository":false,"comments":{"totalCount":0},"additions":4,"deletions":1,"labels":{"nodes":[]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}},{"number":38,"title":"Grow the message composer and support image attachments","url":"https://github.com/asieke/BotChu/pull/38","isDraft":true,"createdAt":"2026-10-22T22:42:43Z","updatedAt":"2026-10-22T22:44:25Z","author":{"login":"asieke","avatarUrl":"https://avatars.githubusercontent.com/u/4070885?s=64&v=4"},"reviewDecision":"CHANGES_REQUESTED","headRefName":"feat/37-composer-images","isCrossRepository":true,"comments":{"totalCount":2},"additions":709,"deletions":45,"labels":{"nodes":[{"name":"enhancement","color":"a2eeef"}]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}]},"issues":{"nodes":[{"number":42,"title":"Bot instructions as INSTRUCTIONS.md + shared TEAM.md playbook","url":"https://github.com/asieke/BotChu/issues/42","createdAt":"2026-10-23T01:41:20Z","updatedAt":"2026-10-23T01:41:20Z","author":{"login":"asieke","avatarUrl":"https://avatars.githubusercontent.com/u/4070885?s=64&v=4"},"comments":{"totalCount":0},"labels":{"nodes":[]}},{"number":37,"title":"Grow the composer and support image attachments","url":"https://github.com/asieke/BotChu/issues/37","createdAt":"2026-10-22T22:31:52Z","updatedAt":"2026-10-22T22:31:52Z","author":null,"comments":{"totalCount":3},"labels":{"nodes":[]}}]}},"r1":null},"errors":[{"type":"NOT_FOUND","path":["r1"],"locations":[{"line":1,"column":688}],"message":"Could not resolve to a Repository with the name 'asieke/nope-not-here-xyz'."}]}
            """#
        let read = try #require(GitHubLookup.parseOpenWork(output, asked: ["asieke/BotChu", "asieke/nope-not-here-xyz"]))
        #expect(read.unreadable == ["asieke/nope-not-here-xyz"])
        let items = read.items
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
        #expect(GitHubLookup.parseOpenWork("gh: Bad credentials", asked: ["asieke/BotChu"]) == nil)
        #expect(GitHubLookup.parseOpenWork(#"{"errors":[{"message":"Bad credentials"}]}"#, asked: ["asieke/BotChu"]) == nil)
        // Every repository unresolved: data, but no answers at all.
        #expect(GitHubLookup.parseOpenWork(#"{"data":{"r0":null},"errors":[{"type":"NOT_FOUND"}]}"#, asked: ["a/b"])?.unreadable == ["a/b"])
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

    @Test func filtersProjectsByStatus() {
        func row(_ name: String, _ record: ProjectRow.Record) -> ProjectRow {
            ProjectRow(repo: GitHubLookup.Repo(nameWithOwner: "octocat/\(name)"), record: record, deploy: [], workplace: "This Mac",
                       location: RepoLocation(path: "/tmp/\(name)"), openTasks: 0)
        }
        let rows = [
            row("Live", .present(ProjectMetadata(name: "Live"))),
            row("Resting", .present(ProjectMetadata(name: "Resting", status: .paused))),
            row("Old", .present(ProjectMetadata(name: "Old", status: .deprecated))),
            row("Bare", .missing), row("Unread", .loading), row("Broken", .invalid), row("Offline", .failed("No network.")),
        ]
        func shown(_ filter: ProjectStatusFilter) -> [String] { rows.filter(filter.includes).map(\.repo.name) }
        #expect(shown(.active) == ["Live"])
        #expect(shown(.paused) == ["Resting"])
        #expect(shown(.deprecated) == ["Old"])
        #expect(shown(.maintenance).isEmpty)
        // No PROJECT.md: unclassified. Not read yet, unreadable or failed: no status known, so only All.
        #expect(shown(.unclassified) == ["Bare"])
        #expect(shown(.all).count == rows.count)
        #expect(ProjectStatusFilter(rawValue: "active") == .active)
        #expect(ProjectStatusFilter.all.label == "All statuses")
        #expect(ProjectStatusFilter.maintenance.label == "Maintenance")
    }

    /// Issues and Pull Requests cover the repositories Repositories shows, by status and type (#186):
    /// their items, the repository picker, the counts and the note about what wasn't read.
    @Test func scopesOpenWorkByStatusAndType() {
        func row(_ name: String, _ record: ProjectRow.Record, issues: Int = 0, pulls: Int = 0) -> ProjectRow {
            ProjectRow(repo: GitHubLookup.Repo(nameWithOwner: "octocat/\(name)", openIssues: issues, openPullRequests: pulls), record: record,
                       deploy: [], workplace: "This Mac", location: RepoLocation(path: "/tmp/\(name)"), openTasks: 0)
        }
        let rows = [
            row("App", .present(ProjectMetadata(name: "App", kind: .local)), issues: 40, pulls: 1),
            row("Notes", .present(ProjectMetadata(name: "Notes", kind: .docs)), issues: 1),
            row("Resting", .present(ProjectMetadata(name: "Resting", kind: .library, status: .paused)), issues: 1),
            row("Bare", .missing, issues: 1), row("Unread", .loading, issues: 1), row("Broken", .invalid, issues: 1),
        ]
        func item(_ repo: String, _ number: Int, _ title: String, pull: Bool = false, labels: [String] = []) -> GitHubLookup.OpenItem {
            GitHubLookup.OpenItem(repo: "octocat/\(repo)", number: number, title: title, url: URL(string: "https://github.com/octocat/\(repo)/issues/\(number)")!,
                                  isPullRequest: pull, author: "hubot", createdAt: .distantPast, updatedAt: .distantPast,
                                  labels: labels.map { .init(name: $0, color: "888888") })
        }
        // App has 40 open issues and two were read.
        let items = [item("App", 1, "Crash on launch", labels: ["bug"]), item("App", 2, "Dark mode"), item("App", 3, "Ship it", pull: true),
                     item("Notes", 4, "Typo"), item("Resting", 5, "Old idea"), item("Bare", 6, "Add PROJECT.md"),
                     item("Unread", 7, "Unknown"), item("Broken", 8, "Fix metadata")]
        func work(_ status: ProjectStatusFilter, _ kind: ProjectKindFilter, pulls: Bool = false, repo: String? = nil, query: String = "") -> ProjectWork {
            ProjectWork(rows: rows, items: items, scope: ProjectScope(status: status, kind: kind), pulls: pulls, repo: repo, query: query)
        }
        func shown(_ work: ProjectWork) -> [Int] { work.items.map(\.number) }

        // The same repositories as the Repositories view, for every status and type.
        for status in ProjectStatusFilter.allCases {
            for kind in ProjectKindFilter.allCases {
                let scope = ProjectScope(status: status, kind: kind)
                let eligible = Set(rows.filter { status.includes($0) && kind.includes($0) }.map(\.id))
                let issues = work(status, kind)
                #expect(Set(issues.items.map(\.repo)) == eligible.intersection(items.filter { !$0.isPullRequest }.map(\.repo)))
                #expect(Set(issues.repos).isSubset(of: eligible))
                #expect(issues.truncated.allSatisfy { eligible.contains($0.id) })
                #expect(scope.openCount(in: rows, pulls: false) == rows.filter { eligible.contains($0.id) }.reduce(0) { $0 + $1.openIssues })
            }
        }
        #expect(shown(work(.active, .all)) == [1, 2, 4])
        #expect(shown(work(.active, .code)) == [1, 2])
        #expect(shown(work(.active, .docs)) == [4])
        #expect(shown(work(.paused, .all)) == [5])
        #expect(shown(work(.maintenance, .all)).isEmpty)
        #expect(shown(work(.deprecated, .all)).isEmpty)
        // No PROJECT.md is unclassified, and has no type; not read yet or unreadable shows only under All.
        #expect(shown(work(.unclassified, .all)) == [6])
        #expect(shown(work(.unclassified, .code)).isEmpty)
        #expect(shown(work(.all, .all)) == [1, 2, 4, 5, 6, 7, 8])
        #expect(shown(work(.all, .code)) == [1, 2, 5])
        #expect(shown(work(.active, .all, pulls: true)) == [3])
        #expect(work(.active, .all).outOfScope == 4)
        #expect(work(.all, .all).outOfScope == 0)

        // Counts are GitHub's totals across the repositories in scope, not just what was read.
        #expect(ProjectScope(status: .active, kind: .all).openCount(in: rows, pulls: false) == 41)
        #expect(ProjectScope(status: .active, kind: .code).openCount(in: rows, pulls: true) == 1)
        #expect(ProjectScope.everything.openCount(in: rows, pulls: false) == 45)
        // The note about what wasn't read names only repositories in scope (and the chosen one).
        #expect(work(.active, .all).truncated.map(\.name) == ["App"])
        #expect(work(.paused, .all).truncated.isEmpty)
        #expect(work(.all, .all, repo: "octocat/Notes").truncated.isEmpty)

        // The picker lists the repositories in scope with work; choosing one narrows the scope further.
        #expect(work(.active, .all).repos == ["octocat/App", "octocat/Notes"])
        #expect(work(.active, .all, pulls: true).repos == ["octocat/App"])
        let chosen = work(.active, .all, repo: "octocat/Notes")
        #expect(chosen.repo == "octocat/Notes" && shown(chosen) == [4])
        // A chosen repository without work of this kind stays listed, and explains an empty list.
        #expect(work(.active, .all, pulls: true, repo: "octocat/Notes").repos == ["octocat/App", "octocat/Notes"])
        // A choice the scope no longer covers counts as none: it neither shows its work nor empties the list.
        let stale = work(.active, .code, repo: "octocat/Notes")
        #expect(stale.repo == nil && shown(stale) == [1, 2] && !stale.repos.contains("octocat/Notes"))
        #expect(work(.paused, .all, repo: "octocat/App").repo == nil)
        #expect(work(.active, .all, repo: "OCTOCAT/app").repo == "octocat/App")

        // The search finds an item by title, number or label without the repository's text matching.
        #expect(shown(work(.active, .all, query: "crash")) == [1])
        #expect(shown(work(.active, .all, query: "#4")) == [4])
        #expect(shown(work(.active, .all, query: "bug launch")) == [1])
        #expect(shown(work(.active, .all, query: "old idea")).isEmpty)
        #expect(shown(work(.all, .all, query: "old idea")) == [5])

        #expect(ProjectKindFilter(rawValue: "docs") == .docs)
        #expect(ProjectKindFilter.docs.label == "Non-code")
        #expect(ProjectScope(status: .active, kind: .code).projects == "active code projects")
        #expect(ProjectScope(status: .all, kind: .docs).projects == "non-code projects")
        #expect(ProjectScope(status: .unclassified, kind: .all).projects == "unclassified projects")
        #expect(!ProjectScope.everything.isNarrowed && ProjectScope(status: .active, kind: .all).isNarrowed)
    }

    @Test func readsAnIssueWithItsConversation() throws {
        // `gh issue view 14755 --repo cli/cli --json <issueDetailFields>`, its texts trimmed.
        let output = #"""
            {"author": {"id": "MDQ6VXNlcjgwMzMyMjAw", "is_bot": false, "login": "samaluk", "name": "Sebastián Maluk"}, "body": "### Describe the feature or problem you’d like to solve\n\nI’d like to configure default options once and have standard `gh` commands inherit them.", "comments": [{"id": "IC_kwDODKw3uc8AAAABdjeZjA", "author": {"login": "cli-triage"}, "authorAssociation": "NONE", "body": "Thanks for the detailed write-up! This reads as a clear enhancement request.", "createdAt": "2026-10-19T21:59:46Z", "includesCreatedEdit": false, "isMinimized": false, "minimizedReason": "", "reactionGroups": [], "url": "https://github.com/cli/cli/issues/14755#issuecomment-6278322572", "viewerDidAuthor": false}, {"id": "IC_kwDODKw3uc8AAAABdjlyHg", "author": {"login": "github-actions"}, "authorAssociation": "CONTRIBUTOR", "body": "Thank you for your issue! We have categorized it as an enhancement.", "createdAt": "2026-10-19T22:07:47Z", "includesCreatedEdit": false, "isMinimized": false, "minimizedReason": "", "reactionGroups": [], "url": "https://github.com/cli/cli/issues/14755#issuecomment-6278443550", "viewerDidAuthor": false}], "createdAt": "2026-10-19T21:56:16Z", "labels": [{"id": "MDU6TGFiZWwxNjk4MDc2MTcz", "name": "enhancement", "description": "a request to improve CLI", "color": "0dd8ac"}, {"id": "LA_kwDODKw3uc8AAAABZDqY9g", "name": "gh-pr", "description": "relating to the gh pr command", "color": "DD04FD"}], "number": 14755, "state": "OPEN", "title": "Support persistent command defaults without requiring custom aliases", "updatedAt": "2026-10-19T22:07:47Z", "url": "https://github.com/cli/cli/issues/14755"}
            """#
        let detail = try #require(GitHubLookup.parseDetail(output, repo: "cli/cli", pullRequest: false))
        #expect(detail.id == "cli/cli#14755")
        #expect(detail.title == "Support persistent command defaults without requiring custom aliases")
        #expect(detail.author == "samaluk")
        #expect(detail.state == "OPEN")
        #expect(detail.body.hasPrefix("### Describe the feature"))
        #expect(detail.labels == [GitHubLookup.OpenItem.Label(name: "enhancement", color: "0dd8ac"), GitHubLookup.OpenItem.Label(name: "gh-pr", color: "DD04FD")])
        #expect(detail.conversation.map(\.author) == ["cli-triage", "github-actions"])
        #expect(detail.conversation.allSatisfy { $0.review == nil })
        #expect(detail.conversation[0].date < detail.conversation[1].date)
        #expect(detail.checks.isEmpty && detail.checksSummary == nil && detail.checksState == .none)
        #expect(detail.work == BotTask.Work(number: 14755, title: detail.title, url: detail.url, isPullRequest: false))
        #expect(GitHubLookup.issueDetailFields == "number,title,body,url,state,author,createdAt,updatedAt,labels,comments")
        #expect(GitHubLookup.parseDetail("GraphQL: Could not resolve to an issue or pull request with the number of 9.", repo: "cli/cli", pullRequest: false) == nil)
    }

    @Test func readsAPullRequestWithChecksFilesAndReviews() throws {
        // `gh pr view 14766 --repo cli/cli --json <pullRequestDetailFields>`, its texts trimmed. Added to
        // its checks: BotChu #58's commit status, and a job still running and a failed one in the same
        // form; to its reviews, a comment-only review with no body, which says nothing on its own.
        let output = #"""
            {"additions": 3, "author": {"is_bot": true, "login": "app/dependabot"}, "baseRefName": "trunk", "body": "Bumps [github.com/gabriel-vasile/mimetype](https://github.com/gabriel-vasile/mimetype) from 1.4.15 to 1.4.16.\n<details>\n<summary>Release notes</summary>", "changedFiles": 2, "comments": [{"id": "IC_kwDODKw3uc8AAAABdx0UlA", "author": {"login": "cli-triage"}, "authorAssociation": "NONE", "body": "**Recommendation: Merge, Confidence: High**", "createdAt": "2026-10-20T14:34:35Z", "includesCreatedEdit": false, "isMinimized": false, "minimizedReason": "", "reactionGroups": [], "url": "https://github.com/cli/cli/pull/14766#issuecomment-6293361812", "viewerDidAuthor": false}], "createdAt": "2026-10-20T14:03:03Z", "deletions": 3, "files": [{"path": "go.mod", "additions": 1, "deletions": 1, "changeType": "MODIFIED"}, {"path": "go.sum", "additions": 2, "deletions": 2, "changeType": "MODIFIED"}], "headRefName": "dependabot/go_modules/github.com/gabriel-vasile/mimetype-1.4.16", "isCrossRepository": false, "isDraft": false, "labels": [{"id": "LA_kwDODKw3uc8AAAABYP6ixA", "name": "dependencies", "description": "Pull requests that update a dependency file", "color": "0366d6"}], "number": 14766, "reviewDecision": "APPROVED", "reviews": [{"id": "PRR_kwDODKw3uc8AAAABTQPibw", "author": {"login": "williammartin"}, "authorAssociation": "MEMBER", "body": "", "submittedAt": "2026-10-20T15:07:53Z", "includesCreatedEdit": false, "reactionGroups": [], "state": "APPROVED", "commit": {"oid": "7d01a387524920742414a38eca9f8544193a5cbc"}}, {"id": "PRR_kwDODKw3uc8AAAABTQPicA", "author": {"login": "babakks"}, "authorAssociation": "MEMBER", "body": "", "submittedAt": "2026-10-20T15:09:00Z", "includesCreatedEdit": false, "reactionGroups": [], "state": "COMMENTED", "commit": {"oid": "7d01a387524920742414a38eca9f8544193a5cbc"}}], "state": "MERGED", "statusCheckRollup": [{"__typename": "CheckRun", "completedAt": "2026-10-20T14:03:11Z", "conclusion": "SKIPPED", "detailsUrl": "https://github.com/cli/cli/actions/runs/39435775443/job/118672277117", "name": "label-external", "startedAt": "2026-10-20T14:03:12Z", "status": "COMPLETED", "workflowName": "PR Triaging"}, {"__typename": "CheckRun", "completedAt": "2026-10-20T14:03:12Z", "conclusion": "SKIPPED", "detailsUrl": "https://github.com/cli/cli/actions/runs/39435776426/job/118672347998", "name": "label-external", "startedAt": "2026-10-20T14:03:20Z", "status": "COMPLETED", "workflowName": "PR Triaging"}, {"__typename": "CheckRun", "completedAt": "2026-10-20T14:05:46Z", "conclusion": "SUCCESS", "detailsUrl": "https://github.com/cli/cli/actions/runs/39435771269/job/118672256520", "name": "CodeQL-Build (go, manual, ./.github/codeql/codeql-config.yml)", "startedAt": "2026-10-20T14:03:14Z", "status": "COMPLETED", "workflowName": "Code Scanning"}, {"__typename": "CheckRun", "completedAt": "0001-01-01T00:00:00Z", "conclusion": "", "detailsUrl": "https://github.com/cli/cli/actions/runs/39435771270/job/118672256521", "name": "build (macos-latest)", "startedAt": "2026-10-20T14:03:14Z", "status": "IN_PROGRESS", "workflowName": "Tests"}, {"__typename": "CheckRun", "completedAt": "2026-10-20T14:04:40Z", "conclusion": "FAILURE", "detailsUrl": "https://github.com/cli/cli/actions/runs/39435771271/job/118672256522", "name": "lint", "startedAt": "2026-10-20T14:03:14Z", "status": "COMPLETED", "workflowName": "Lint"}, {"__typename": "StatusContext", "context": "check", "startedAt": "2026-10-23T11:26:09Z", "state": "SUCCESS", "targetUrl": ""}], "title": "chore(deps): bump github.com/gabriel-vasile/mimetype from 1.4.15 to 1.4.16", "updatedAt": "2026-10-21T07:45:14Z", "url": "https://github.com/cli/cli/pull/14766"}
            """#
        let detail = try #require(GitHubLookup.parseDetail(output, repo: "cli/cli", pullRequest: true))
        #expect(detail.isPullRequest)
        #expect(detail.author == "dependabot[bot]")
        #expect(detail.state == "MERGED")
        #expect(detail.head == "dependabot/go_modules/github.com/gabriel-vasile/mimetype-1.4.16")
        #expect(detail.base == "trunk")
        #expect(!detail.fromFork && !detail.isDraft)
        #expect(detail.additions == 3 && detail.deletions == 3 && detail.changedFiles == 2)
        #expect(detail.reviewDecision == "APPROVED")
        #expect(detail.files == [.init(path: "go.mod", additions: 1, deletions: 1), .init(path: "go.sum", additions: 2, deletions: 2)])
        // What needs attention first: the failure, the job still running, then by name.
        #expect(detail.checks.map(\.state) == [.failure, .pending, .success, .success, .skipped, .skipped])
        #expect(detail.checks.map(\.name).prefix(4) == ["lint", "build (macos-latest)", "check", "CodeQL-Build (go, manual, ./.github/codeql/codeql-config.yml)"])
        #expect(detail.checks[0].workflow == "Lint")
        #expect(detail.checks[0].url?.absoluteString == "https://github.com/cli/cli/actions/runs/39435771271/job/118672256522")
        #expect(detail.checks[2].workflow == nil && detail.checks[2].url == nil)
        #expect(detail.checksSummary == "1 failing, 1 running, 2 passed, 2 skipped")
        #expect(detail.checksState == .failure)
        // The approval says something without a body; the empty comment-only review doesn't.
        #expect(detail.conversation.map(\.author) == ["cli-triage", "williammartin"])
        #expect(detail.conversation.map(\.review) == [nil, "APPROVED"])
        #expect(GitHubLookup.pullRequestDetailFields.hasPrefix(GitHubLookup.issueDetailFields + ",isDraft,headRefName"))
    }

    @Test func showsGitHubTextAsTheSidebarDoes() {
        let body = "## What\r\n<!-- Describe the change -->\r\nFixes the thing.\r\n<!--\r\nA template's\r\nhints\r\n-->\r\n"
        #expect(GitHubLookup.WorkDetail.shown(body) == "## What\n\nFixes the thing.")
        #expect(GitHubLookup.avatar(login: "williammartin")?.absoluteString == "https://avatars.githubusercontent.com/williammartin?s=64")
        #expect(GitHubLookup.avatar(login: "dependabot[bot]") == nil)
        #expect(GitHubLookup.login(nil) == "ghost")
        #expect(GitHubLookup.login(["login": "app/dependabot"]) == "dependabot[bot]")
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
            GitHubLookup.Repo(nameWithOwner: "asieke/waiting"),
        ]
        let local = ProjectMetadata(name: "BotChu", kind: .local, deploy: "local:my-mac:~/apps/BotChu", merge: "agent")
        let hosted = ProjectMetadata(name: "Talent", kind: .hosted, status: .paused, deploy: "local:omarchy:~/apps/talent, vercel:talent")
        let records = [
            "asieke/BotChu": ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(local), sha: "a"),
            "asieke/talent": ProjectRecord(text: try ProjectRecord(text: "", sha: nil).updating(hosted), sha: "b"),
            "asieke/new": ProjectRecord(text: "", sha: nil),
            "asieke/broken": ProjectRecord(text: "---\ntype: spaceship\n---\n", sha: "c"),
        ]
        // Tasks work on this Mac, wherever PROJECT.md deploys, unless the owner chose a host.
        let chosen = RepoLocation(hostID: host.id, path: "~/work/new")
        let rows = ProjectRow.rows(repos: repos, records: records, errors: ["asieke/loading": "Could not read PROJECT.md."], chosen: ["asieke/new": chosen],
                                   hosts: [host], reposRoot: "/repos", taskRepos: ["asieke/BotChu", "ASIEKE/botchu", "asieke/talent"])
        #expect(rows.map(\.workplace) == ["This Mac", "This Mac", "Omarchy", "This Mac", "This Mac", "This Mac"])
        #expect(rows[0].location == RepoLocation(path: "/repos/BotChu"))
        #expect(rows[1].location == RepoLocation(path: "/repos/talent"))
        #expect(rows[2].location == chosen)
        #expect(rows.map(\.openTasks) == [2, 1, 0, 0, 0, 0])
        #expect(rows[5].record == .loading)
        #expect(rows[0].metadata == local)
        #expect(rows[0].mergeKey == 2)
        #expect(rows[1].deploy.map(\.kind) == [.local, .vercel])
        #expect(rows[1].statusKey > rows[0].statusKey)
        #expect(rows[2].record == .missing)
        #expect(rows[3].record == .invalid)
        #expect(rows[4].record == .failed("Could not read PROJECT.md."))
        #expect(rows[4].typeKey == 0)
        #expect(rows[0].openPullRequests == 3)
        #expect(rows[0].matches("bots local"))
        #expect(rows[1].matches("omarchy"))
        #expect(!rows[1].matches("bots"))
    }
}
