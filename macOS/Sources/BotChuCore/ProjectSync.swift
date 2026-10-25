import Foundation

/// Keeps Projects' catalog (`ProjectSnapshot`) on disk and in step with GitHub, after GitChu's sync
/// engine. It shows what was saved at once, then asks GitHub what changed with requests that cost
/// nothing when nothing did: who is signed in and GitHub's REST list of repositories, both with the
/// ETags from last time, and a probe of each repository with anything open (its most recently
/// updated issue or pull request, with its ETag). Only what they flag is read again: PROJECT.md
/// after a push, open work after a change, four and two requests at a time. Every answer is kept
/// as it arrives, so a sync that fails halfway keeps what did arrive, and the store is written to
/// disk off the main thread, a second after the last change.
public actor ProjectSync {
    public enum Scope: Int, Comparable, Sendable {
        /// A check for changes: the account and the list with their ETags, and the probes.
        case changes
        /// That, with the list read afresh, so a repository that is gone goes, and every part that
        /// failed is tried again: at launch, with Refresh, and every half hour.
        case full

        public static func < (a: Scope, b: Scope) -> Bool { a.rawValue < b.rawValue }
    }

    /// What it runs: gh, as the owner signed it in (the account, the list and the probes), and
    /// the readers of PROJECT.md and of open work. Stand-ins in tests.
    public struct Client: Sendable {
        public var gh: @Sendable ([String]) async -> Shell.Result
        public var record: @Sendable (String) async throws -> ProjectRecord
        public var openWork: @Sendable ([String]) async -> Result<GitHubLookup.OpenWork, TaskWorktree.Failure>

        public init(gh: @escaping @Sendable ([String]) async -> Shell.Result,
                    record: @escaping @Sendable (String) async throws -> ProjectRecord,
                    openWork: @escaping @Sendable ([String]) async -> Result<GitHubLookup.OpenWork, TaskWorktree.Failure>) {
            self.gh = gh; self.record = record; self.openWork = openWork
        }

        /// Everything through one gh runner.
        public init(github: ProjectGitHub) {
            self.init(gh: { await github.gh($0) }, record: { try await github.record(repo: $0) },
                      openWork: { await GitHubLookup.openWork(repos: $0, run: { await github.gh($0) }) })
        }
    }

    /// What Projects shows now.
    public struct State: Equatable, Sendable {
        /// The account the catalog belongs to.
        public var login: String?
        public var syncedAt: Date?
        /// Nil until a list was saved or read.
        public var repositories: [GitHubLookup.Repo]?
        public var records: [String: ProjectRecord] = [:]
        public var recordErrors: [String: String] = [:]
        public var openItems: [GitHubLookup.OpenItem]?
        public var unreadableWork: [String] = []
        /// Each listed repository's open issue count, by lower-cased `owner/name`; nil until a list
        /// was saved or read.
        public var issueStatus: [String: OpenIssueStatus]?
        public var syncing: Scope?
        /// Why the last sync failed; nil once one succeeds.
        public var error: String?
    }

    /// A catalog synced or tried this recently is current: opening Projects doesn't sync it.
    public static let staleAfter: TimeInterval = 120
    /// How often a sync is a full one.
    public static let fullInterval: TimeInterval = 1800
    static let pageSize = 100
    static let recordsAtOnce = 4
    static let probesAtOnce = 6
    static let workBatch = 10
    static let workAtOnce = 2

    /// Every change to the state, newest only, for the window to show.
    public nonisolated let updates: AsyncStream<State>
    private let continuation: AsyncStream<State>.Continuation
    private let file: URL
    private let client: Client
    private let saveDelay: Duration
    private var snapshot: ProjectSnapshot?
    private var loaded = false
    private var error: String?
    private var lastAttempt: Date?
    private var saveTask: Task<Void, Never>?
    /// The sync under way and those waiting for it; the widest scope asked for meanwhile, which
    /// runs once it ends, and those waiting for that.
    private var active: Scope?
    private var activeWaiters: [CheckedContinuation<Void, Never>] = []
    private var queued: Scope?
    private var queuedWaiters: [CheckedContinuation<Void, Never>] = []

    public init(file: URL, client: Client, saveDelay: Duration = .seconds(1)) {
        self.file = file
        self.client = client
        self.saveDelay = saveDelay
        (updates, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit { continuation.finish() }

    /// The saved catalog, read from disk once; a missing, unreadable or older file starts empty.
    @discardableResult
    public func load() -> State {
        if !loaded {
            loaded = true
            snapshot = Self.read(file)
            publish()
        }
        return state
    }

    public var state: State {
        guard let snapshot else { return State(syncing: active, error: error) }
        // Nothing read yet for this account: nil, not an empty list.
        let listed = snapshot.syncedAt != nil || !snapshot.pages.isEmpty
        let worked = snapshot.syncedAt != nil || !snapshot.work.isEmpty || !snapshot.workProblems.isEmpty
        return State(login: snapshot.login, syncedAt: snapshot.syncedAt, repositories: listed ? snapshot.repositories : nil,
                     records: snapshot.projectRecords, recordErrors: snapshot.recordErrors, openItems: worked ? snapshot.openItems : nil,
                     unreadableWork: snapshot.unreadableWork, issueStatus: listed ? snapshot.issueStatus : nil, syncing: active, error: error)
    }

    /// The scope a sync due now has: full when the last full one is older than `fullInterval`.
    public static func dueScope(now: Date, fullSyncedAt: Date?) -> Scope {
        fullSyncedAt.map { now.timeIntervalSince($0) < fullInterval } == true ? .changes : .full
    }

    /// Syncs unless the catalog is current (synced or tried in the last `staleAfter`); joins a sync
    /// under way.
    public func syncIfStale(now: Date = Date()) async {
        load()
        if let active { await sync(active); return }
        if let last = [snapshot?.syncedAt, lastAttempt].compactMap({ $0 }).max(), now.timeIntervalSince(last) < Self.staleAfter { return }
        await sync(Self.dueScope(now: now, fullSyncedAt: snapshot?.fullSyncedAt))
    }

    /// Syncs, unless a sync under way already covers `scope`: then it waits for that one. A wider
    /// scope asked for meanwhile runs once that ends, however many ask for it. Returns once the
    /// sync covering the request ends; a caller that is cancelled still waits, and the sync goes on.
    public func sync(_ scope: Scope) async {
        load()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            if let active, active >= scope {
                activeWaiters.append(waiter)
            } else if active != nil {
                queued = max(queued ?? scope, scope)
                queuedWaiters.append(waiter)
            } else {
                activeWaiters.append(waiter)
                start(scope)
            }
        }
    }

    /// How many wait for the sync under way, and for the one after it.
    struct Requests: Equatable { var active: Int; var queued: Int }
    var requests: Requests { Requests(active: activeWaiters.count, queued: queuedWaiters.count) }

    private func start(_ scope: Scope) {
        active = scope
        Task { await self.run(scope) }
    }

    private func run(_ scope: Scope) async {
        let started = Date()
        lastAttempt = started
        publish()
        do {
            try await syncOnce(scope, started: started)
            error = nil
        } catch let failure as Failure {
            error = failure.message
        } catch {
            self.error = error.localizedDescription
        }
        saveNow()
        let waiters = activeWaiters
        activeWaiters = queuedWaiters
        queuedWaiters = []
        active = nil
        if let next = queued {
            queued = nil
            start(next)
        }
        publish()
        for waiter in waiters { waiter.resume() }
    }

    struct Failure: Error, Equatable { let message: String }

    private func syncOnce(_ scope: Scope, started: Date) async throws {
        let client = client
        let remembered = snapshot?.pages ?? []
        let probes = (snapshot?.listed ?? []).filter { $0.openCount > 0 }.map {
            ProbeRequest(repo: $0.nameWithOwner, etag: snapshot?.probeETags[$0.nameWithOwner])
        }
        // A list asked for with ETags says nothing about another account's repositories.
        let conditional = scope != .full && !remembered.isEmpty
        // Who is signed in, the list and the probes at once; what they say is taken only once the
        // account is known to be the one the catalog belongs to.
        async let userRead = Self.user(client, etag: snapshot?.userETag)
        async let listRead = Self.list(client, remembered: scope == .full ? [] : remembered)
        async let probeRead = Self.probe(client, probes)
        var list: ListRead
        var flagged: [String: String]
        var probed = Set(probes.map(\.repo))
        switch try await userRead {
        case .same:
            list = try await listRead
            flagged = await probeRead
        case .signedIn(let login, let etag):
            if let snapshot, snapshot.login.caseInsensitiveCompare(login) == .orderedSame {
                self.snapshot?.userETag = etag
                list = try await listRead
                flagged = await probeRead
            } else {
                // Another account (or the first sync): nothing saved is its own. Start afresh, and
                // read the list again if it was asked for with the other account's ETags.
                let read = try? await listRead
                _ = await probeRead
                snapshot = ProjectSnapshot(login: login)
                snapshot?.userETag = etag
                saveNow()
                publish()
                if let read, !conditional { list = read } else { list = try await Self.list(client, remembered: []) }
                flagged = [:]
                probed = []
            }
        }
        guard var snapshot else { return }
        if list.complete {
            let gone = await Self.gone(client, snapshot.missing(from: list.pages).map(\.nameWithOwner))
            snapshot.takeList(list.pages, complete: true, gone: Set(gone.map { $0.lowercased() }))
        } else {
            snapshot.takeList(list.pages, complete: false)
        }
        let plan = ProjectSyncPlan(snapshot: snapshot, full: scope == .full, flagged: Set(flagged.keys))
        let fingerprints = Dictionary(snapshot.listed.map { ($0.nameWithOwner, $0.fingerprint) }) { first, _ in first }
        snapshot.emptyWork(plan.emptied, under: fingerprints)
        self.snapshot = snapshot
        changed()
        // Repositories to read that weren't probed yet are probed first, so the ETag kept with
        // what is read predates it, and the next probe sees any change since.
        let late = await Self.probe(client, plan.work.filter { !probed.contains($0) }.map { ProbeRequest(repo: $0, etag: nil) })
        let etags = flagged.merging(late) { _, new in new }
        async let records: Void = readRecords(plan.records, under: fingerprints)
        async let work: Void = readWork(plan.work, under: fingerprints, etags: etags)
        _ = await (records, work)
        self.snapshot?.syncedAt = Date()
        if scope == .full { self.snapshot?.fullSyncedAt = started }
    }

    private func readRecords(_ repos: [String], under fingerprints: [String: ProjectSnapshot.Fingerprint]) async {
        let client = client
        await Self.bounded(repos, atOnce: Self.recordsAtOnce, read: { repo in
            let result: Result<ProjectRecord, ProjectRecord.Problem>
            do { result = .success(try await client.record(repo)) }
            catch { result = .failure(error as? ProjectRecord.Problem ?? ProjectRecord.Problem(error.localizedDescription)) }
            return RecordAnswer(repo: repo, result: result)
        }, take: { answer in
            self.snapshot?.takeRecord(answer.repo, answer.result, under: fingerprints[answer.repo])
            self.changed()
        })
    }

    private func readWork(_ repos: [String], under fingerprints: [String: ProjectSnapshot.Fingerprint], etags: [String: String]) async {
        let client = client
        let batches = stride(from: 0, to: repos.count, by: Self.workBatch).map { Array(repos[$0..<min($0 + Self.workBatch, repos.count)]) }
        await Self.bounded(batches, atOnce: Self.workAtOnce, read: { batch in
            WorkAnswer(asked: batch, result: await client.openWork(batch))
        }, take: { answer in
            self.snapshot?.takeWork(answer.asked, answer.result, under: fingerprints, etags: etags)
            self.changed()
        })
    }

    // MARK: Reading from GitHub

    // Swift 6.4 can miscompile tuple results of task-group children in optimized builds; each child
    // returns a named struct: https://github.com/swiftlang/swift/issues/93208
    private struct RecordAnswer: Sendable { let repo: String; let result: Result<ProjectRecord, ProjectRecord.Problem> }
    private struct WorkAnswer: Sendable { let asked: [String]; let result: Result<GitHubLookup.OpenWork, TaskWorktree.Failure> }
    private struct ProbeRequest: Sendable { let repo: String; let etag: String? }
    private struct ProbeAnswer: Sendable { let repo: String; let etag: String? }
    private struct GoneAnswer: Sendable { let repo: String; let gone: Bool }
    private struct PageAnswer: Sendable { let index: Int; let page: PageRead }
    private enum PageRead: Sendable { case changed(ProjectSnapshot.Page, hasNext: Bool), unchanged }
    private struct ListRead: Sendable { var pages: [ProjectSnapshot.Page]; var complete: Bool }
    private enum UserRead: Sendable { case same, signedIn(String, etag: String?) }

    /// Reads `items`, at most `atOnce` at a time, taking each answer as it arrives, on the caller's actor.
    private static func bounded<Item: Sendable, Answer: Sendable>(_ items: [Item], atOnce: Int, isolation: isolated (any Actor)? = #isolation,
                                                                 read: @escaping @Sendable (Item) async -> Answer,
                                                                 take: (Answer) async -> Void) async {
        await withTaskGroup(of: Answer.self) { group in
            var next = items.startIndex
            while next < items.endIndex, next - items.startIndex < atOnce {
                let item = items[next]
                group.addTask { await read(item) }
                next += 1
            }
            while let answer = await group.next() {
                await take(answer)
                if next < items.endIndex {
                    let item = items[next]
                    group.addTask { await read(item) }
                    next += 1
                }
            }
        }
    }

    /// A GET through gh with `-i`, conditional on `etag`: 200 and 304 are answers, anything else fails.
    private static func get(_ client: Client, _ path: String, etag: String?, what: String) async throws -> GitHubResponse {
        var arguments = ["gh", "api", "--hostname", "github.com", "-i", "--method", "GET"]
        if let etag, !etag.isEmpty { arguments += ["-H", "If-None-Match: \(etag)"] }
        let run = await client.gh(arguments + [path])
        guard let response = GitHubResponse.parse(run.output) else {
            let missing = run.status == 127 || run.errors.contains("command not found")
            throw Failure(message: missing ? "Couldn't run gh to read \(what). Install the GitHub CLI and sign in with gh auth login."
                                           : "Couldn't reach GitHub to read \(what). Check the connection; Projects shows what was saved.")
        }
        guard response.status == 200 || response.status == 304 else {
            throw Failure(message: response.status == 401 ? "gh isn't signed in to GitHub. Run gh auth login in Terminal, then Refresh."
                                                          : "GitHub answered \(response.status) when reading \(what). Projects shows what was saved.")
        }
        return response
    }

    private static func user(_ client: Client, etag: String?) async throws -> UserRead {
        let response = try await get(client, "user", etag: etag, what: "your GitHub account")
        if response.status == 304 { return .same }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(response.body.utf8))) as? [String: Any],
              let login = object["login"] as? String, !login.isEmpty else {
            throw Failure(message: "Couldn't tell which GitHub account gh is signed in to.")
        }
        return .signedIn(login, etag: response.etag)
    }

    /// The list against the pages remembered: those are asked for at once with their ETags (none
    /// remembered: one page, afresh), then the pages after the last while there may be more. The
    /// list is complete when every page came back afresh.
    private static func list(_ client: Client, remembered: [ProjectSnapshot.Page]) async throws -> ListRead {
        let count = max(1, remembered.count)
        let answers = try await withThrowingTaskGroup(of: PageAnswer.self) { group in
            for index in 0..<count {
                let etag = index < remembered.count ? remembered[index].etag : nil
                group.addTask { PageAnswer(index: index, page: try await page(client, index + 1, etag: etag)) }
            }
            var answers: [Int: PageRead] = [:]
            for try await answer in group { answers[answer.index] = answer.page }
            return answers
        }
        var read = ListRead(pages: [], complete: true)
        var more = false
        for index in 0..<count {
            switch answers[index] ?? .unchanged {
            case .changed(let page, let hasNext):
                read.pages.append(page)
                more = hasNext
            case .unchanged where index < remembered.count:
                read.complete = false
                read.pages.append(remembered[index])
                // A new repository sorting after every other lands on a page of its own.
                more = remembered[index].repos.count >= pageSize
            case .unchanged:
                read.complete = false
            }
        }
        while more {
            guard case .changed(let next, let hasNext) = try await page(client, read.pages.count + 1, etag: nil) else { break }
            read.pages.append(next)
            more = hasNext
        }
        return read
    }

    private static func page(_ client: Client, _ number: Int, etag: String?) async throws -> PageRead {
        // By name, so a changed repository changes only its own page's ETag.
        let path = "user/repos?per_page=\(pageSize)&page=\(number)&sort=full_name&direction=asc&affiliation=owner,organization_member"
        let response = try await get(client, path, etag: etag, what: "your GitHub repositories")
        if response.status == 304 { return .unchanged }
        guard let repos = ProjectSnapshot.Listed.parse(page: response.body) else {
            throw Failure(message: "Couldn't read your GitHub repositories from gh's answer.")
        }
        return .changed(ProjectSnapshot.Page(etag: response.etag ?? "", repos: repos), hasNext: response.hasNextPage)
    }

    /// The new ETag of each repository whose issues and pull requests changed since its ETag was
    /// taken: one conditional request each for the most recently updated one, which moves when any
    /// is opened, closed, edited, labelled, commented on, reviewed or pushed to. A probe that fails
    /// flags nothing; the next sync probes again.
    private static func probe(_ client: Client, _ requests: [ProbeRequest]) async -> [String: String] {
        var flagged: [String: String] = [:]
        await bounded(requests, atOnce: probesAtOnce, read: { request in
            let path = "repos/\(request.repo)/issues?state=all&sort=updated&direction=desc&per_page=1"
            let response = try? await get(client, path, etag: request.etag, what: "\(request.repo)")
            return ProbeAnswer(repo: request.repo, etag: response?.status == 200 ? response?.etag ?? "" : nil)
        }, take: { answer in
            if let etag = answer.etag { flagged[answer.repo] = etag }
        })
        return flagged
    }

    /// Of the repositories a complete list lacks, those GitHub says are gone: not found or no longer
    /// readable, or renamed (the list has the new name). Any other answer keeps one for now.
    private static func gone(_ client: Client, _ repos: [String]) async -> [String] {
        var gone: [String] = []
        await bounded(repos, atOnce: probesAtOnce, read: { repo in
            let run = await client.gh(["gh", "api", "--hostname", "github.com", "-i", "--method", "GET", "repos/\(repo)"])
            guard let response = GitHubResponse.parse(run.output) else { return GoneAnswer(repo: repo, gone: false) }
            if [403, 404, 410, 451].contains(response.status) { return GoneAnswer(repo: repo, gone: true) }
            let name = ((try? JSONSerialization.jsonObject(with: Data(response.body.utf8))) as? [String: Any])?["full_name"] as? String
            return GoneAnswer(repo: repo, gone: response.status == 200 && name.map { $0.caseInsensitiveCompare(repo) != .orderedSame } == true)
        }, take: { answer in
            if answer.gone { gone.append(answer.repo) }
        })
        return gone
    }

    // MARK: Keeping it

    private func publish() { continuation.yield(state) }

    /// Something was taken: shows it, and saves a second after the last change.
    private func changed() {
        publish()
        guard saveTask == nil else { return }
        let delay = saveDelay
        saveTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    /// Writes the catalog now, atomically; one that can't be written stays in memory for next time.
    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let snapshot else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch {}
    }

    static func read(_ file: URL) -> ProjectSnapshot? {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(ProjectSnapshot.self, from: data),
              snapshot.version == ProjectSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
