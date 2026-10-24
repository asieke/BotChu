import Foundation
import Testing
@testable import BotChuCore

/// The Projects catalog and its sync, against a stand-in gh that answers as GitHub does: ETags and
/// 304s on the REST list, the account and the probes, PROJECT.md, and the open work query.
@Suite struct ProjectCatalogTests {
    @Test func savedCatalogShowsBeforeAnyRequestCompletes() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        let saved = await fixture.sync.state
        #expect(saved.repositories?.count == 4)

        // Relaunched, with GitHub holding every request: the saved catalog shows at once.
        await github.hold()
        let relaunched = fixture.relaunch()
        let state = await relaunched.load()
        #expect(state.login == "asieke")
        #expect(state.repositories == saved.repositories)
        #expect(state.records == saved.records)
        #expect(state.openItems == saved.openItems)
        #expect(state.syncedAt == saved.syncedAt)
        let syncing = Task { await relaunched.sync(.changes) }
        var updates = relaunched.updates.makeAsyncIterator()
        let shown = await updates.next()
        #expect(shown?.repositories == saved.repositories)
        try await github.waitUntilHeld(1)
        #expect(await github.answered == 0)
        await github.release()
        await syncing.value
        #expect(await relaunched.state.error == nil)

        // Offline: the sync fails, and the saved catalog stays as it was.
        await github.set(offline: true)
        await relaunched.sync(.full)
        let offline = await relaunched.state
        #expect(offline.error?.contains("Couldn't reach GitHub") == true)
        #expect(offline.repositories == saved.repositories)
        #expect(offline.openItems == saved.openItems)
        #expect(offline.syncedAt != nil)
    }

    @Test func checksForChangesReadOnlyWhatChanged() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        var calls = await github.takeCalls()
        #expect(calls.filter { $0.hasPrefix("record:") }.count == 4)
        #expect(calls.contains("work:asieke/BotChu,asieke/Orbit"))
        // Busy repositories are probed before their work is first read, so the ETag predates it.
        #expect(calls.filter { $0.hasPrefix("probe:") }.sorted() == ["probe:asieke/BotChu", "probe:asieke/Orbit"])
        let first = await fixture.sync.state
        #expect(first.repositories?.first { $0.id == "asieke/BotChu" }?.openPullRequests == 1)
        #expect(first.repositories?.first { $0.id == "asieke/Orbit" }?.openIssues == 2)
        #expect(first.openItems?.count == 3)
        #expect(first.records["asieke/Notes"]?.exists == false)

        // Nothing changed: the account, the list and the probes come back 304, and nothing is read.
        await fixture.sync.sync(.changes)
        #expect(await github.notModified == 4)
        calls = await github.takeCalls()
        #expect(calls.sorted() == ["list:1", "probe:asieke/BotChu", "probe:asieke/Orbit", "user"])

        // A push reads that repository's PROJECT.md again; a new issue its open work; a comment
        // (which moves nothing in the list) is caught by its probe.
        await github.update("asieke/Notes") { $0.pushed += 60; $0.project = "---\nname: Notes\ntype: docs\nstatus: paused\n---\n" }
        await github.update("asieke/BotChu") { $0.issues.append(12) }
        await github.update("asieke/Orbit") { $0.activity += 1 }
        await fixture.sync.sync(.changes)
        calls = await github.takeCalls()
        #expect(calls.filter { $0.hasPrefix("record:") } == ["record:asieke/Notes"])
        #expect(calls.filter { $0.hasPrefix("work:") } == ["work:asieke/BotChu,asieke/Orbit"])
        let changed = await fixture.sync.state
        #expect(try changed.records["asieke/Notes"]?.metadata(repoName: "Notes").status == .paused)
        #expect(changed.repositories?.first { $0.id == "asieke/BotChu" }?.openIssues == 1)
        #expect(changed.openItems?.contains { $0.id == "asieke/BotChu#12" } == true)

        // A pull request whose checks are running is read again on every sync, until they finish.
        await github.update("asieke/BotChu") { $0.pendingChecks = true; $0.activity += 1 }
        await fixture.sync.sync(.changes)
        _ = await github.takeCalls()
        await fixture.sync.sync(.changes)
        #expect(await github.takeCalls().filter { $0.hasPrefix("work:") } == ["work:asieke/BotChu"])
        await github.update("asieke/BotChu") { $0.pendingChecks = false }
        await fixture.sync.sync(.changes)
        _ = await github.takeCalls()
        await fixture.sync.sync(.changes)
        #expect(await github.takeCalls().filter { $0.hasPrefix("work:") }.isEmpty)

        // Closing everything empties a repository's open work without asking for it.
        await github.update("asieke/Orbit") { $0.issues = [] }
        await fixture.sync.sync(.changes)
        #expect(await github.takeCalls().filter { $0.hasPrefix("work:") }.isEmpty)
        let emptied = await fixture.sync.state
        #expect(emptied.openItems?.contains { $0.repo == "asieke/Orbit" } == false)
        #expect(emptied.repositories?.first { $0.id == "asieke/Orbit" }?.openIssues == 0)

        // Current: no request at all, until it is two minutes old.
        let synced = try #require(emptied.syncedAt)
        await fixture.sync.syncIfStale(now: synced.addingTimeInterval(60))
        #expect(await github.takeCalls().isEmpty)
        await fixture.sync.syncIfStale(now: synced.addingTimeInterval(ProjectSync.staleAfter + 1))
        #expect(await github.takeCalls().contains("user"))
        #expect(ProjectSync.dueScope(now: synced, fullSyncedAt: synced.addingTimeInterval(-60)) == .changes)
        #expect(ProjectSync.dueScope(now: synced, fullSyncedAt: synced.addingTimeInterval(-ProjectSync.fullInterval)) == .full)
        #expect(ProjectSync.dueScope(now: synced, fullSyncedAt: nil) == .full)
    }

    @Test func failuresKeepTheLastUsableData() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample)
        await github.set(failRecords: ["asieke/Orbit"], unreadableWork: ["asieke/Orbit"])
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        var state = await fixture.sync.state
        #expect(state.error == nil)
        #expect(state.repositories?.count == 4)
        #expect(state.records.count == 3)
        #expect(state.recordErrors["asieke/Orbit"] != nil)
        #expect(state.unreadableWork == ["asieke/Orbit"])
        #expect(state.openItems?.map(\.repo) == ["asieke/BotChu"])

        // A check for changes doesn't retry what failed under the same list entry; a full sync does.
        await github.set(failRecords: [], unreadableWork: [])
        _ = await github.takeCalls()
        await fixture.sync.sync(.changes)
        #expect(await github.takeCalls().filter { $0.hasPrefix("record:") || $0.hasPrefix("work:") }.isEmpty)
        await fixture.sync.sync(.full)
        state = await fixture.sync.state
        #expect(state.recordErrors.isEmpty)
        #expect(state.unreadableWork.isEmpty)
        #expect(state.openItems?.count == 3)
        let record = state.records["asieke/Orbit"]

        // A read that fails keeps what was read before.
        await github.set(failRecords: ["asieke/Orbit"], workDown: true)
        await github.update("asieke/Orbit") { $0.pushed += 60; $0.issues.append(9) }
        await fixture.sync.sync(.changes)
        state = await fixture.sync.state
        #expect(state.error == nil)
        #expect(state.records["asieke/Orbit"] == record)
        #expect(state.recordErrors["asieke/Orbit"] != nil)
        #expect(state.unreadableWork == ["asieke/Orbit"])
        #expect(state.openItems?.filter { $0.repo == "asieke/Orbit" }.count == 2)

        // A list that can't be read keeps every repository; gh signed out says so.
        await github.set(listStatus: 502)
        await fixture.sync.sync(.full)
        state = await fixture.sync.state
        #expect(state.error?.contains("502") == true)
        #expect(state.repositories?.count == 4)
        await github.set(listStatus: nil, userStatus: 401)
        await fixture.sync.sync(.full)
        #expect(await fixture.sync.state.error?.contains("gh auth login") == true)
        #expect(await fixture.sync.state.repositories?.count == 4)
    }

    /// What a task's Activity counts (#113): issues without pull requests, a confirmed zero, and
    /// the count read before, with why, when a read fails.
    @Test func issueStatusCountsIssuesAloneAndKeepsWhatWasRead() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        #expect(await fixture.sync.load().issueStatus == nil)
        await fixture.sync.sync(.full)
        var state = await fixture.sync.state
        #expect(state.issueStatus?.count == 4)
        // BotChu has one open pull request and no issue.
        #expect(state.issueStatus?["asieke/botchu"] == OpenIssueStatus(count: 0))
        #expect(state.issueStatus?["asieke/orbit"] == OpenIssueStatus(count: 2))
        #expect(state.issueStatus?["asieke/notes"] == OpenIssueStatus(count: 0))

        await github.set(workDown: true)
        await github.update("asieke/Orbit") { $0.issues.append(9) }
        await fixture.sync.sync(.changes)
        state = await fixture.sync.state
        #expect(state.issueStatus?["asieke/orbit"]?.count == 2)
        #expect(state.issueStatus?["asieke/orbit"]?.problem != nil)
        let stale = IssuePreview(repo: "asieke/Orbit", statuses: state.issueStatus, items: state.openItems, syncing: false, error: state.error)
        #expect(stale.note == "Not updated")
        #expect(stale.issues.map(\.number) == [4, 3])

        await github.set(workDown: false)
        await fixture.sync.sync(.full)
        #expect(await fixture.sync.state.issueStatus?["asieke/orbit"] == OpenIssueStatus(count: 3))
    }

    @Test func repositoriesGoOnlyOnceGitHubConfirmsIt() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample + [.init(name: "asieke/Old"), .init(name: "asieke/Shared")])
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        #expect(await fixture.sync.state.repositories?.count == 6)

        // Old is deleted; Shared is a public repository the account can't reach any more, which
        // GitHub still shows; Notes is archived.
        await github.remove("asieke/Old", stillShown: false)
        await github.remove("asieke/Shared", stillShown: true)
        await github.update("asieke/Notes") { $0.archived = true }
        await fixture.sync.sync(.changes)
        var names = await fixture.sync.state.repositories?.map(\.id) ?? []
        #expect(!names.contains("asieke/Old"))
        #expect(names.contains("asieke/Shared"))
        #expect(!names.contains("asieke/Notes"))
        #expect(await github.takeCalls().filter { $0.hasPrefix("exists:") }.sorted() == ["exists:asieke/Old", "exists:asieke/Shared"])

        // A list GitHub answers 304 for says nothing about what is missing; the next complete
        // list without Shared drops it without asking.
        await fixture.sync.sync(.changes)
        #expect(await fixture.sync.state.repositories?.contains { $0.id == "asieke/Shared" } == true)
        await fixture.sync.sync(.full)
        names = await fixture.sync.state.repositories?.map(\.id) ?? []
        #expect(!names.contains("asieke/Shared"))
        #expect(await github.takeCalls().filter { $0.hasPrefix("exists:") }.isEmpty)
        let saved = try #require(ProjectSync.read(fixture.file))
        #expect(saved.records["asieke/Old"] == nil)
        #expect(saved.records["asieke/Shared"] == nil)
    }

    @Test func refreshesAskedForDuringASyncRunOnceAfterIt() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        _ = await github.takeCalls()
        await github.hold()
        let tick = Task { await fixture.sync.sync(.changes) }
        try await github.waitUntilHeld(1)
        let refreshes = (0..<3).map { _ in Task { await fixture.sync.sync(.full) } }
        let anotherTick = Task { await fixture.sync.sync(.changes) }
        try await waitFor { await fixture.sync.requests == ProjectSync.Requests(active: 2, queued: 3) }
        #expect(await fixture.sync.state.syncing == .changes)
        await github.release()
        await tick.value
        await anotherTick.value
        for refresh in refreshes { await refresh.value }
        let calls = await github.takeCalls()
        #expect(calls.filter { $0 == "user" }.count == 2)
        #expect(await fixture.sync.state.syncing == nil)
        #expect(await fixture.sync.requests == ProjectSync.Requests(active: 0, queued: 0))
    }

    @Test func anotherAccountStartsItsOwnCatalog() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        #expect(await fixture.sync.state.login == "asieke")
        await github.signIn("octocat", repos: [.init(name: "octocat/Hello-World", issues: [1], project: "---\nname: Hello\ntype: docs\nstatus: active\n---\n")])
        await fixture.sync.sync(.changes)
        let state = await fixture.sync.state
        #expect(state.login == "octocat")
        #expect(state.repositories?.map(\.id) == ["octocat/Hello-World"])
        #expect(Set(state.records.keys) == ["octocat/Hello-World"])
        #expect(state.openItems?.allSatisfy { $0.repo == "octocat/Hello-World" } == true)
        let saved = try #require(ProjectSync.read(fixture.file))
        #expect(saved.login == "octocat")
        #expect(saved.listed.map(\.nameWithOwner) == ["octocat/Hello-World"])
        // Logins match whatever their case: the catalog stays, and nothing is read again.
        _ = await github.takeCalls()
        await github.signIn("OctoCat", repos: [.init(name: "octocat/Hello-World", issues: [1])])
        await fixture.sync.sync(.changes)
        #expect(await fixture.sync.state.repositories?.count == 1)
        #expect(await github.takeCalls().filter { $0.hasPrefix("record:") || $0.hasPrefix("work:") }.isEmpty)
    }

    @Test func missingOrUnreadableCacheStartsEmpty() async throws {
        let github = StandInGitHub(repos: StandInGitHub.sample)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        var state = await fixture.sync.load()
        #expect(state.login == nil)
        #expect(state.repositories == nil)
        #expect(state.openItems == nil)
        for broken in [Data("not json".utf8), Data(#"{"version":99,"login":"asieke"}"#.utf8), Data()] {
            try broken.write(to: fixture.file)
            state = await fixture.relaunch().load()
            #expect(state.login == nil)
            #expect(state.repositories == nil)
        }
        let recovered = fixture.relaunch()
        await recovered.sync(.full)
        #expect(await recovered.state.repositories?.count == 4)
        #expect(ProjectSync.read(fixture.file)?.login == "asieke")
        #expect(await fixture.relaunch().load().repositories?.count == 4)
    }

    @Test func listsEveryPageAndAsksAgainOnlyWithETags() async throws {
        let repos = (0..<150).map { StandInGitHub.Repo(name: String(format: "asieke/repo-%03d", $0)) }
        let github = StandInGitHub(repos: repos)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        #expect(await fixture.sync.state.repositories?.count == 150)
        #expect(await github.takeCalls().filter { $0.hasPrefix("list:") } == ["list:1", "list:2"])
        await fixture.sync.sync(.changes)
        #expect(await github.notModified == 3)
        #expect(await github.takeCalls().filter { $0.hasPrefix("list:") }.sorted() == ["list:1", "list:2"])
    }

    // Run in Release too (test.sh): Swift 6.4 miscompiles tuple returns from task-group children.
    @Test func projectLoadingCollectsEveryResultWithinBatchLimit() async throws {
        let repos = (0..<24).map { StandInGitHub.Repo(name: "fixture/project-\($0)", project: "# Project \($0)\n") }
        let github = StandInGitHub(repos: repos)
        await github.set(failRecords: Set((0..<24).filter { $0.isMultiple(of: 3) }.map { "fixture/project-\($0)" }), recordDelay: .milliseconds(20))
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        await fixture.sync.sync(.full)
        let state = await fixture.sync.state
        #expect(state.records.count == 16)
        #expect(state.recordErrors.count == 8)
        for index in 0..<24 {
            let id = "fixture/project-\(index)"
            if index.isMultiple(of: 3) { #expect(state.recordErrors[id] != nil) }
            else { #expect(state.records[id]?.text == "# Project \(index)\n") }
        }
        let records = await github.records
        #expect(records.active == 0)
        #expect(records.completed == 24)
        #expect(records.peak <= ProjectSync.recordsAtOnce)
    }

    @Test func projectLoadingGoesOnWhenItsCallerLeaves() async throws {
        let repos = (0..<24).map { StandInGitHub.Repo(name: "fixture/project-\($0)", project: "# Project \($0)\n") }
        let github = StandInGitHub(repos: repos)
        await github.holdRecords(4)
        let fixture = try Fixture(github)
        defer { fixture.remove() }
        let caller = Task { await fixture.sync.sync(.full) }
        try await github.waitUntilHeld(4)
        #expect(await github.records.active == 4)
        caller.cancel()
        await github.release()
        await caller.value
        let records = await github.records
        #expect(records.active == 0)
        #expect(records.completed == 24)
        #expect(records.peak <= ProjectSync.recordsAtOnce)
        #expect(await fixture.sync.state.records.count == 24)
        // Opening Projects again doesn't read them again.
        await fixture.sync.sync(.changes)
        #expect(await github.records.completed == 24)
    }

    @Test func readsGitHubAnswers() throws {
        let answer = "HTTP/2.0 200 OK\nEtag: W/\"abc\"\r\nLink: <https://api.github.com/user/repos?page=2>; rel=\"next\", <https://api.github.com/user/repos?page=3>; rel=\"last\"\r\n\r\n[]"
        let response = try #require(GitHubResponse.parse("login shell noise\n" + answer))
        #expect(response.status == 200)
        #expect(response.etag == "W/\"abc\"")
        #expect(response.hasNextPage)
        #expect(response.body == "[]")
        #expect(GitHubResponse.parse("HTTP/2.0 304 Not Modified\nEtag: \"abc\"\r\n\r\n")?.status == 304)
        #expect(GitHubResponse.parse("HTTP/2.0 304 Not Modified\nEtag: \"abc\"\r\n\r\n")?.hasNextPage == false)
        #expect(GitHubResponse.parse("error connecting to api.github.com") == nil)

        // As GitHub's REST list gives them (trimmed).
        let page = #"""
            [{"full_name":"asieke/BotChu","description":"Bots\non agent CLIs","pushed_at":"2026-10-24T12:02:56Z","updated_at":"2026-10-23T17:51:51Z","private":false,"fork":false,"archived":false,"language":"Swift","open_issues_count":16,"owner":{"type":"User","avatar_url":"https://avatars.githubusercontent.com/u/4070885?v=4"}},
             {"full_name":"Humanist-Venture-Studio/internal-brain","description":null,"pushed_at":null,"updated_at":"2026-10-20T00:00:00Z","private":true,"fork":true,"archived":true,"language":null,"open_issues_count":0,"owner":{"type":"Organization","avatar_url":"http://example.com/a.png"}},
             {"description":"no name"}]
            """#
        let listed = try #require(ProjectSnapshot.Listed.parse(page: page))
        #expect(listed.map(\.nameWithOwner) == ["asieke/BotChu", "Humanist-Venture-Studio/internal-brain"])
        #expect(listed[0].description == "Bots on agent CLIs")
        #expect(listed[0].openCount == 16)
        #expect(listed[0].language == "Swift")
        #expect(listed[0].ownerAvatar?.absoluteString == "https://avatars.githubusercontent.com/u/4070885?v=4&s=64")
        #expect(listed[0].pushedAt == ISO8601DateFormatter().date(from: "2026-10-24T12:02:56Z"))
        #expect(listed[1].isArchived && listed[1].isFork && listed[1].isPrivate && listed[1].ownerIsOrganization)
        #expect(listed[1].ownerAvatar == nil)
        #expect(listed[1].language == nil)
        #expect(ProjectSnapshot.Listed.parse(page: #"{"message":"Bad credentials"}"#) == nil)
        var snapshot = ProjectSnapshot(login: "asieke")
        snapshot.takeList([ProjectSnapshot.Page(etag: "x", repos: listed)], complete: true)
        #expect(snapshot.repositories.map(\.id) == ["asieke/BotChu"])

        // The open work query asks for GitHub's counts too.
        #expect(GitHubLookup.openWorkQuery(["asieke/BotChu"]).contains("first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount nodes"))
        let work = try #require(GitHubLookup.parseOpenWork(#"{"data":{"r0":{"nameWithOwner":"ASIEKE/botchu","pullRequests":{"totalCount":31,"nodes":[]},"issues":{"totalCount":2,"nodes":[]}}}}"#, asked: ["asieke/BotChu"]))
        #expect(work.counts["asieke/BotChu"] == GitHubLookup.OpenCounts(issues: 2, pullRequests: 31))
    }

    @Test func catalogEntriesNeedNoNetwork() {
        let metadata = ProjectMetadata(name: "Bot Chu", kind: .local, status: .active, deploy: "local:far-mac:~/apps/BotChu")
        let text = (try? ProjectRecord(text: "", sha: nil).updating(metadata)) ?? ""
        let host = SSHHost(nickname: "Far Mac", destination: "alex@far", machine: "far-mac", reposFolder: "~/apps")
        let rows = ProjectRow.rows(repos: [GitHubLookup.Repo(nameWithOwner: "asieke/BotChu"), GitHubLookup.Repo(nameWithOwner: "asieke/Bare")],
                                   records: ["asieke/BotChu": ProjectRecord(text: text, sha: "1"), "asieke/Bare": ProjectRecord(text: "", sha: nil)],
                                   chosen: [:], thisMac: "this-mac", hosts: [host], reposRoot: "/tmp/repos", taskRepos: [])
        let entries = rows.map(\.catalogEntry)
        #expect(entries[0].name == "Bot Chu")
        #expect(entries[0].repo == "asieke/BotChu")
        #expect(entries[0].url.absoluteString == "https://github.com/asieke/BotChu")
        #expect(entries[0].status == .active)
        #expect(entries[0].workplace == "Far Mac")
        #expect(entries[0].location == RepoLocation(hostID: host.id, path: "~/apps/BotChu"))
        #expect(entries[1].name == "Bare")
        #expect(entries[1].status == nil)
        #expect(entries[1].location.path == "/tmp/repos/Bare")
    }
}

/// Waits (up to two seconds) until `condition` holds.
private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting")
}

private struct Fixture {
    let root: URL
    let file: URL
    let github: StandInGitHub
    let sync: ProjectSync

    init(_ github: StandInGitHub) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("projects.json")
        self.github = github
        sync = Self.make(file, github)
    }

    /// Another ProjectSync on the same file, as after a relaunch.
    func relaunch() -> ProjectSync { Self.make(file, github) }

    private static func make(_ file: URL, _ github: StandInGitHub) -> ProjectSync {
        ProjectSync(file: file, client: ProjectSync.Client(github: ProjectGitHub { arguments, _ in await github.answer(arguments) }), saveDelay: .zero)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// GitHub as gh shows it, for one account's repositories.
private actor StandInGitHub {
    struct Repo: Sendable {
        var name: String
        var pushed = 0
        var updated = 0
        var archived = false
        var issues: [Int] = []
        var pulls: [Int] = []
        var pendingChecks = false
        var project: String?
        /// Edits, comments and reviews: they move only the probe's ETag.
        var activity = 0
        var openCount: Int { issues.count + pulls.count }
    }

    static let sample: [Repo] = [
        Repo(name: "asieke/BotChu", pushed: 300, pulls: [7], project: "---\nname: BotChu\ntype: local\nstatus: active\n---\n"),
        Repo(name: "asieke/Orbit", pushed: 200, issues: [3, 4], project: "---\nname: Orbit\ntype: hosted\nstatus: active\n---\n"),
        Repo(name: "asieke/Notes", pushed: 100),
        Repo(name: "asieke/TinyKit", pushed: 50, project: "---\nname: TinyKit\ntype: library\nstatus: maintenance\n---\n"),
    ]

    private var login = "asieke"
    private var repos: [Repo]
    /// Repositories the list lacks that `repos/<name>` still shows.
    private var shown: Set<String> = []
    private var offline = false
    private var failRecords: Set<String> = []
    private var unreadableWork: Set<String> = []
    private var workDown = false
    private var listStatus: Int?
    private var userStatus: Int?
    private var recordDelay: Duration = .zero
    private var calls: [String] = []
    private(set) var notModified = 0
    private(set) var answered = 0
    private var holding = false
    private var recordsToHold = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var recordActive = 0, recordPeak = 0, recordCompleted = 0
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    init(repos: [Repo]) { self.repos = repos }

    var records: (active: Int, peak: Int, completed: Int) { (recordActive, recordPeak, recordCompleted) }

    func set(offline: Bool) { self.offline = offline }
    func set(failRecords: Set<String>? = nil, unreadableWork: Set<String>? = nil, workDown: Bool? = nil, recordDelay: Duration? = nil) {
        if let failRecords { self.failRecords = failRecords }
        if let unreadableWork { self.unreadableWork = unreadableWork }
        if let workDown { self.workDown = workDown }
        if let recordDelay { self.recordDelay = recordDelay }
    }
    func set(listStatus: Int?, userStatus: Int? = nil) { self.listStatus = listStatus; self.userStatus = userStatus }
    func update(_ name: String, _ change: (inout Repo) -> Void) {
        guard let index = repos.firstIndex(where: { $0.name == name }) else { return }
        change(&repos[index])
        repos[index].updated += 1
    }
    func remove(_ name: String, stillShown: Bool) {
        repos.removeAll { $0.name == name }
        if stillShown { shown.insert(name) }
    }
    func signIn(_ login: String, repos: [Repo]) { self.login = login; self.repos = repos }
    func takeCalls() -> [String] { defer { calls = []; notModified = 0 }; return calls }

    func hold() { holding = true; answered = 0 }
    func holdRecords(_ count: Int) { recordsToHold = count }
    func release() {
        holding = false
        recordsToHold = 0
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
    func waitUntilHeld(_ count: Int) async throws {
        for _ in 0..<400 where held.count < count { try await Task.sleep(for: .milliseconds(5)) }
        #expect(held.count >= count)
    }

    func answer(_ arguments: [String]) async -> Shell.Result {
        let isRecord = arguments.contains { $0.hasSuffix("/contents/PROJECT.md") }
        if isRecord {
            recordActive += 1
            recordPeak = max(recordPeak, recordActive)
        }
        if holding || isRecord && recordsToHold > 0 {
            if isRecord, recordsToHold > 0 { recordsToHold -= 1 }
            await withCheckedContinuation { held.append($0) }
        }
        if isRecord, recordDelay > .zero { try? await Task.sleep(for: recordDelay) }
        defer {
            answered += 1
            if isRecord { recordActive -= 1; recordCompleted += 1 }
        }
        if offline { return Shell.Result(status: 1, output: "", errors: "error connecting to api.github.com") }
        if arguments.starts(with: ["gh", "api", "graphql"]) { return work(arguments.last ?? "") }
        let path = arguments.last { !$0.hasPrefix("-") && $0 != "gh" && $0 != "api" && $0 != "github.com" && $0 != "GET" } ?? ""
        if isRecord { return record(String(path.dropFirst("repos/".count).dropLast("/contents/PROJECT.md".count))) }
        guard arguments.contains("-i") else {
            // ProjectGitHub asks whether a repository without PROJECT.md is there.
            return Shell.Result(status: 0, output: "{}", errors: "")
        }
        let etag = arguments.first { $0.hasPrefix("If-None-Match: ") }.map { String($0.dropFirst("If-None-Match: ".count)) }
        if path == "user" {
            calls.append("user")
            if let userStatus { return http(userStatus, etag: nil, body: "{}") }
            return conditional(etag, current: "W/\"user-\(login)\"", body: #"{"login":"\#(login)"}"#)
        }
        if path.hasPrefix("user/repos?") {
            let page = Int(path.components(separatedBy: "&page=")[1].prefix { $0.isNumber }) ?? 1
            calls.append("list:\(page)")
            if let listStatus { return http(listStatus, etag: nil, body: "{}") }
            let slice = repos.sorted { $0.name.lowercased() < $1.name.lowercased() }.dropFirst((page - 1) * 100).prefix(100)
            let body = "[" + slice.map(listed).joined(separator: ",") + "]"
            let more = repos.count > page * 100 ? "<https://api.github.com/user/repos?page=\(page + 1)>; rel=\"next\"" : nil
            return conditional(etag, current: "W/\"\(checksum(body))\"", body: body, link: more)
        }
        let name = path.dropFirst("repos/".count).components(separatedBy: "/").prefix(2).joined(separator: "/").components(separatedBy: "?")[0]
        if path.contains("/issues?") {
            calls.append("probe:\(name)")
            guard let repo = repos.first(where: { $0.name == name }) else { return http(404, etag: nil) }
            return conditional(etag, current: "\"issues-\(checksum("\(repo.issues)\(repo.pulls)\(repo.activity)\(repo.pendingChecks)"))\"", body: "[]")
        }
        calls.append("exists:\(name)")
        return repos.contains { $0.name == name } || shown.contains(name) ? http(200, etag: nil, body: #"{"full_name":"\#(name)"}"#) : http(404, etag: nil)
    }

    private func conditional(_ asked: String?, current: String, body: String, link: String? = nil) -> Shell.Result {
        let strong = { (tag: String) in tag.hasPrefix("W/") ? String(tag.dropFirst(2)) : tag }
        if let asked, strong(asked) == strong(current) {
            notModified += 1
            return http(304, etag: strong(current))
        }
        return http(200, etag: current, link: link, body: body)
    }

    private func http(_ status: Int, etag: String?, link: String? = nil, body: String = "") -> Shell.Result {
        var head = "HTTP/2.0 \(status) \(status == 200 ? "OK" : status == 304 ? "Not Modified" : "Error")\n"
        if let etag { head += "Etag: \(etag)\r\n" }
        if let link { head += "Link: \(link)\r\n" }
        head += "Content-Type: application/json\r\n\r\n"
        return Shell.Result(status: status == 200 ? 0 : 1, output: head + body, errors: status == 200 ? "" : "gh: HTTP \(status)")
    }

    private func date(_ offset: Int) -> String { ISO8601DateFormatter().string(from: base.addingTimeInterval(TimeInterval(offset))) }

    private func listed(_ repo: Repo) -> String {
        #"{"full_name":"\#(repo.name)","description":"","pushed_at":"\#(date(repo.pushed))","updated_at":"\#(date(repo.updated))","private":false,"fork":false,"archived":\#(repo.archived),"language":"Swift","open_issues_count":\#(repo.openCount),"owner":{"type":"User","avatar_url":"https://avatars.githubusercontent.com/u/1?v=4"}}"#
    }

    private func record(_ name: String) -> Shell.Result {
        calls.append("record:\(name)")
        guard !failRecords.contains(name), let repo = repos.first(where: { $0.name == name }) else { return Shell.Result(status: 1, output: "", errors: "HTTP 502") }
        guard let text = repo.project else { return Shell.Result(status: 1, output: #"{"message":"Not Found","status":"404"}"#, errors: "gh: Not Found (HTTP 404)") }
        return Shell.Result(status: 0, output: #"{"type":"file","encoding":"base64","sha":"\#(checksum(text))","content":"\#(Data(text.utf8).base64EncodedString())"}"#, errors: "")
    }

    private func work(_ query: String) -> Shell.Result {
        let pattern = try! NSRegularExpression(pattern: #"(r\d+): repository\(owner: "([^"]+)", name: "([^"]+)"\)"#)
        let asked = pattern.matches(in: query, range: NSRange(query.startIndex..., in: query)).map { match in
            (alias: String(query[Range(match.range(at: 1), in: query)!]),
             name: "\(query[Range(match.range(at: 2), in: query)!])/\(query[Range(match.range(at: 3), in: query)!])")
        }
        calls.append("work:" + asked.map(\.name).joined(separator: ","))
        if workDown { return Shell.Result(status: 1, output: "", errors: "HTTP 502") }
        let fields = asked.map { alias, name -> String in
            guard !unreadableWork.contains(name), let repo = repos.first(where: { $0.name == name }) else { return "\"\(alias)\":null" }
            let node = { (number: Int, pull: Bool) -> String in
                let checks = pull ? #","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"\#(repo.pendingChecks ? "PENDING" : "SUCCESS")"}}}]}"# : ""
                return #"{"number":\#(number),"title":"Item \#(number)","url":"https://github.com/\#(name)/\#(pull ? "pull" : "issues")/\#(number)","createdAt":"\#(self.date(number))","updatedAt":"\#(self.date(number + repo.activity))","author":{"login":"octocat"}\#(checks)}"#
            }
            return #""\#(alias)":{"nameWithOwner":"\#(name)","pullRequests":{"totalCount":\#(repo.pulls.count),"nodes":[\#(repo.pulls.map { node($0, true) }.joined(separator: ","))]},"issues":{"totalCount":\#(repo.issues.count),"nodes":[\#(repo.issues.map { node($0, false) }.joined(separator: ","))]}}"#
        }
        let failed = asked.contains { unreadableWork.contains($0.name) }
        return Shell.Result(status: failed ? 1 : 0, output: #"{"data":{"# + fields.joined(separator: ",") + "}}", errors: "")
    }

    private func checksum(_ text: String) -> String {
        String(text.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 16)
    }
}

/// How long Projects takes to show and sync your real catalog, with your gh login (read-only):
/// `BOTCHU_PROJECTS_BENCHMARK=<file> swift test --package-path macOS --filter projectsBenchmark`.
/// Skipped without it; it asserts nothing about time.
@Suite struct ProjectsBenchmark {
    @Test func projectsBenchmark() async throws {
        guard let output = ProcessInfo.processInfo.environment["BOTCHU_PROJECTS_BENCHMARK"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-projects-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects.json")
        func seconds(_ since: ContinuousClock.Instant) -> String {
            let elapsed = (ContinuousClock.now - since).components
            return String(format: "%.2f s", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        var lines = ["| Run | First sync: list shown | First sync: all read | Relaunch: saved catalog shown | Check for changes | Full sync | Catalog |", "| --- | --- | --- | --- | --- | --- | --- |"]
        for run in 1...3 {
            try? FileManager.default.removeItem(at: file)
            let cold = ProjectSync(file: file, client: ProjectSync.Client(github: ProjectGitHub()), saveDelay: .zero)
            let start = ContinuousClock.now
            let watcher = Task { () -> String in
                for await state in cold.updates where state.repositories != nil { return seconds(start) }
                return "-"
            }
            await cold.sync(.full)
            let all = seconds(start)
            watcher.cancel()
            let listed = await watcher.value
            let relaunched = ProjectSync(file: file, client: ProjectSync.Client(github: ProjectGitHub()), saveDelay: .zero)
            let loadStart = ContinuousClock.now
            let saved = await relaunched.load()
            let shown = seconds(loadStart)
            var clock = ContinuousClock.now
            await relaunched.sync(.changes)
            let tick = seconds(clock)
            clock = ContinuousClock.now
            await relaunched.sync(.full)
            let full = seconds(clock)
            let state = await relaunched.state
            #expect(state.error == nil)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            lines.append("| \(run) | \(listed) | \(all) | \(shown) | \(tick) | \(full) | \(saved.repositories?.count ?? 0) repositories, \(saved.records.count) PROJECT.md, \(saved.openItems?.count ?? 0) open items, \(size / 1024) KB |")
        }
        try lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
