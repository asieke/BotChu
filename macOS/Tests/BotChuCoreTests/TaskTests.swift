import Foundation
import Testing
@testable import BotChuCore

private func tempDir(_ name: String = "botchu-tasks") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // The real path, as git prints it (/private/var/… for /var/…).
    return url.resolvingSymlinksInPath()
}

@Suite struct TaskNamingTests {
    let issue = BotTask.Work(number: 48, title: "Add a filter bar", url: URL(string: "https://github.com/asieke/GitChu/issues/48")!, isPullRequest: false)

    @Test func titles() {
        #expect(TaskNaming.title(repo: "asieke/GitChu", work: issue, brief: "anything") == "GitChu #48")
        #expect(TaskNaming.title(repo: "asieke/GitChu", work: nil, brief: "Speed up the sync") == "GitChu · Speed up the sync")
        #expect(TaskNaming.title(repo: "asieke/GitChu", work: nil, brief: "Make the repository table remember its sort order\nmore")
                == "GitChu · Make the repository table…")
        #expect(TaskNaming.title(repo: "local-only", work: nil, brief: "") == "local-only")
    }

    @Test func openingIsTheBriefOrTheWork() {
        let task = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu", work: issue)
        #expect(task.opening == "Work on issue #48 “Add a filter bar”.")
        let pull = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu",
                           work: BotTask.Work(number: 12, isPullRequest: true, repo: "asieke/GitChu"))
        #expect(pull.opening == "Continue pull request #12.")
        #expect(pull.pullRequest == 12)
        #expect(BotTask(repo: "a/b", checkout: "/w/b", work: issue, brief: " Keep it small ").opening == "Keep it small")
    }

    @Test func branchesFollowTheStandard() {
        #expect(TaskNaming.branch(issue: 48, text: "Add a filter bar to the list", fallback: "x") == "feat/48-add-filter-bar-list")
        #expect(TaskNaming.branch(issue: nil, text: "Fix: crash when the token expires", fallback: "x") == "feat/fix-crash-when-token")
        #expect(TaskNaming.branch(issue: nil, text: "Café menü", fallback: "x") == "feat/cafe-menu")
        #expect(TaskNaming.branch(issue: 7, text: "🎉", fallback: "x") == "feat/7-issue")
        #expect(TaskNaming.branch(issue: nil, text: "", fallback: "task-1a2b3c") == "feat/task-1a2b3c")
        // Not feat/2-…, which scripts/worktree.sh would link to issue #2.
        #expect(TaskNaming.branch(issue: nil, text: "2 small fixes in 3 docs", fallback: "x") == "feat/small-fixes-3-docs")
        let long = TaskNaming.branch(issue: 12345, text: "internationalization localization accessibility responsiveness", fallback: "x")
        #expect(long.count <= 50 && TaskNaming.isStandardBranch(long))
    }

    @Test func numberedBranchesStayValid() {
        #expect(TaskNaming.numbered("feat/fix-login", 2) == "feat/fix-login-2")
        let long = "feat/" + String(repeating: "a", count: 45)
        let numbered = TaskNaming.numbered(long, 12)
        #expect(numbered.count == 50 && numbered.hasSuffix("a-12") && TaskNaming.isStandardBranch(numbered))
        #expect(TaskNaming.numbered("feat/fix-" + String(repeating: "b", count: 40), 3).count <= 50)
    }

    @Test func branchChecks() {
        #expect(TaskNaming.isStandardBranch("fix/19-cron"))
        #expect(!TaskNaming.isStandardBranch("claude/fix-thing"))
        #expect(!TaskNaming.isStandardBranch("feat/Upper"))
        #expect(TaskNaming.isValidBranch("claude/fix-thing"))
        #expect(TaskNaming.isValidBranch("release/1.2"))
        for bad in ["", "-x", "a..b", "a b", "a/", "x.lock", "a//b", "a@{1}", "a~1"] {
            #expect(!TaskNaming.isValidBranch(bad), "\(bad)")
        }
    }

    @Test func pullRequestFromTheConversation() {
        var task = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu")
        let messages = [
            ChatMessage(role: .assistant, text: "Like https://github.com/asieke/GitChu/pull/40 did."),
            ChatMessage(role: .tool, toolName: "Bash", toolInput: "gh pr create", toolOutput: "https://github.com/asieke/GitChu/pull/49\n"),
            ChatMessage(role: .assistant, text: "See also https://github.com/asieke/BotChu/pull/3."),
        ]
        #expect(TaskNaming.pullRequest(in: messages, task: task) == 49)
        #expect(TaskNaming.pullRequest(in: [], task: task) == nil)
        task.pullRequest = 12
        #expect(TaskNaming.pullRequest(in: [ChatMessage(role: .assistant, text: "no links")], task: task) == 12)
        // Owner case differs in the URL GitHub prints.
        #expect(TaskNaming.pullRequest(in: [ChatMessage(role: .assistant, text: "https://github.com/Asieke/gitchu/pull/50")], task: task) == 50)
    }

    @Test func receipts() {
        var task = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu", work: issue)
        #expect(TaskReceipt.started(task) == "Started GitChu #48")
        task.branch = "feat/48-add-filter-bar"
        task.title = "Filters"
        #expect(TaskReceipt.started(task) == "Started Filters in asieke/GitChu")
        task.title = "GitChu #48"
        task.pullRequest = 49
        #expect(TaskReceipt.finished(task) == "GitChu #48 finished its turn")
        #expect(TaskReceipt.failed(task, error: "usage limit\nmore") == "GitChu #48 stopped with an error: usage limit")
    }
}

@Suite struct TaskRequestTests {
    func parse(_ json: String) throws -> TaskRequest { try TaskRequest.parse(Data(json.utf8)) }

    func problem(_ json: String) -> String? {
        do {
            _ = try parse(json)
            return nil
        } catch {
            return (error as? TaskRequest.Problem)?.message
        }
    }

    @Test func readsARequest() throws {
        let request = try parse(#"{"repo": "asieke/GitChu", "issue": 48, "task": " Fix it ", "branch": "fix/48-filter", "title": "Filters"}"#)
        #expect(request == TaskRequest(repo: "asieke/GitChu", issue: 48, task: "Fix it", branch: "fix/48-filter", title: "Filters"))
    }

    @Test func forgivesItsSpelling() throws {
        #expect(try parse(##"{"repository": "GitChu", "pr": "#12"}"##) == TaskRequest(repo: "GitChu", pullRequest: 12))
        #expect(try parse(#"{"repo": "x", "pull_request": 3, "brief": "Look"}"#) == TaskRequest(repo: "x", pullRequest: 3, task: "Look"))
        #expect(try parse(#"{"repo": "x", "issue": null, "description": "Do it"}"#) == TaskRequest(repo: "x", task: "Do it"))
    }

    @Test func saysWhatIsWrong() {
        #expect(problem("[1]") == "it isn't a JSON object")
        #expect(problem(#"{"task": "x"}"#) == "it names no “repo”")
        #expect(problem(#"{"repo": "x"}"#) == "it needs a “task”, an “issue” or a “pullRequest”")
        #expect(problem(#"{"repo": "x", "issue": 1, "pr": 2}"#) == "give an issue or a pull request, not both")
        #expect(problem(#"{"repo": "x", "issue": "soon"}"#) == "“issue” must be a number")
        #expect(problem(#"{"repo": "x", "task": "y", "branch": "a b"}"#) == "“a b” isn't a branch name git takes")
    }
}

@Suite struct RepositoriesTests {
    @Test func gitHubNames() {
        #expect(Repositories.nameWithOwner(remote: "https://github.com/asieke/GitChu.git") == "asieke/GitChu")
        #expect(Repositories.nameWithOwner(remote: "https://github.com/asieke/GitChu") == "asieke/GitChu")
        #expect(Repositories.nameWithOwner(remote: "git@github.com:asieke/BotChu.git") == "asieke/BotChu")
        #expect(Repositories.nameWithOwner(remote: "ssh://git@github.com/asieke/x-digest.git") == "asieke/x-digest")
        #expect(Repositories.nameWithOwner(remote: "https://gitlab.com/a/b.git") == nil)
        #expect(Repositories.nameWithOwner(remote: "/tmp/origin.git") == nil)
    }

    @Test func originFromGitConfig() {
        let config = """
            [core]
            \trepositoryformatversion = 0
            [remote "upstream"]
            \turl = https://github.com/other/fork.git
            [remote "origin"]
            \turl = git@github.com:asieke/GitChu.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            [branch "main"]
            \tremote = origin
            """
        #expect(Repositories.originURL(config: config) == "git@github.com:asieke/GitChu.git")
        #expect(Repositories.originURL(config: "[core]\n\tbare = false\n") == nil)
    }

    @Test func scansAndFindsCheckouts() throws {
        let root = tempDir("botchu-repos")
        defer { try? FileManager.default.removeItem(at: root) }
        func repo(_ name: String, origin: String?) throws {
            let git = root.appendingPathComponent(name).appendingPathComponent(".git")
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            let config = origin.map { "[remote \"origin\"]\n\turl = \($0)\n" } ?? "[core]\n"
            try config.write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        try repo("GitChu", origin: "https://github.com/asieke/GitChu.git")
        try repo("notes", origin: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-repo"), withIntermediateDirectories: true)
        // A linked worktree's .git is a file, not a checkout of its own.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("linked"), withIntermediateDirectories: true)
        try "gitdir: /elsewhere".write(to: root.appendingPathComponent("linked/.git"), atomically: true, encoding: .utf8)

        let found = Repositories.scan(root: root.path)
        #expect(found.map(\.repo) == ["asieke/GitChu", "notes"])
        #expect(Repositories.find("asieke/gitchu", in: found)?.name == "GitChu")
        #expect(Repositories.find("https://github.com/asieke/GitChu", in: found)?.name == "GitChu")
        #expect(Repositories.find("GitChu", in: found)?.nameWithOwner == "asieke/GitChu")
        #expect(Repositories.find("notes", in: found)?.nameWithOwner == nil)
        #expect(Repositories.find(root.appendingPathComponent("notes").path, in: found)?.repo == "notes")
        #expect(Repositories.find("someone/else", in: found) == nil)
        // Without a GitHub origin, a checkout goes by its folder's name, also after an owner…
        #expect(Repositories.find("asieke/notes", in: found)?.repo == "notes")
        // …but one on GitHub only by its own owner.
        #expect(Repositories.find("someone/GitChu", in: found) == nil)
        #expect(Repositories.find("", in: found) == nil)
    }
}

@Suite struct GitHubLookupTests {
    // Captured from gh 2.x: `gh issue view 11 --repo asieke/BotChu --json number,title,url,state` and
    // `gh pr view 12 --repo asieke/BotChu --json number,title,url,state,headRefName,isCrossRepository`.
    let issue = #"{"number":11,"state":"OPEN","title":"Research: Connect bots, repositories, and parallel workstreams","url":"https://github.com/asieke/BotChu/issues/11"}"#
    let pull = #"{"headRefName":"feat/8-pet-hatching","isCrossRepository":false,"number":12,"state":"MERGED","title":"Draw bots' pets with Codex from their appearance","url":"https://github.com/asieke/BotChu/pull/12"}"#

    @Test func readsAnIssueAndAPullRequest() {
        let found = GitHubLookup.parseWork(issue, pullRequest: false)
        #expect(found?.work == BotTask.Work(number: 11, title: "Research: Connect bots, repositories, and parallel workstreams",
                                            url: URL(string: "https://github.com/asieke/BotChu/issues/11")!, isPullRequest: false))
        #expect(found?.state == "OPEN")
        #expect(found?.branch == nil)
        let pr = GitHubLookup.parseWork(pull, pullRequest: true)
        #expect(pr?.branch == "feat/8-pet-hatching")
        #expect(pr?.fromFork == false)
        #expect(pr?.state == "MERGED")
    }

    @Test func readsAListFromTheLineThatStartsIt() {
        let list = GitHubLookup.parseList("A warning [with brackets]\n[\(pull),{\"number\":10,\"title\":\"x\"}]\n", pullRequest: true)
        #expect(list.map(\.work.number) == [12])
        #expect(GitHubLookup.parseList("not json", pullRequest: false).isEmpty)
    }
}

@Suite struct ShellTests {
    @Test func outputIsTheCommandsOwn() async {
        // What the login shell's own files print comes before the marker and is left out.
        #expect(Shell.commandOutput("Welcome [back]\n\(Shell.marker)\n[1]\n") == "[1]\n")
        #expect(Shell.commandOutput("no marker") == "no marker")
        let run = await Shell.run(["printf", "a\\nb"], in: FileManager.default.temporaryDirectory.path)
        #expect(run.ok)
        #expect(run.output == "a\nb")
        #expect(run.lastLine == "b")
    }
}

@Suite struct TaskWorktreeTests {
    func git(_ args: String..., in folder: URL) async throws {
        let run = await Shell.run(["git", "-c", "user.name=BotChu", "-c", "user.email=botchu@example.com",
                                   "-c", "init.defaultBranch=main"] + args, in: folder.path)
        try #require(run.ok, "\(run.report("git \(args.joined(separator: " "))"))")
    }

    /// A checkout of a local origin with one commit on main.
    func checkout(in root: URL) async throws -> URL {
        let origin = root.appendingPathComponent("origin.git")
        try await git("init", "--bare", "--quiet", origin.path, in: root)
        let seed = root.appendingPathComponent("seed")
        try await git("clone", "--quiet", origin.path, seed.path, in: root)
        try "hello\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git("add", ".", in: seed)
        try await git("commit", "--quiet", "-m", "First", in: seed)
        try await git("push", "--quiet", "origin", "HEAD:main", in: seed)
        let checkout = root.appendingPathComponent("repo")
        try await git("clone", "--quiet", origin.path, checkout.path, in: root)
        return checkout
    }

    @Test func makesAndReopensAWorktreeWithGit() async throws {
        let root = tempDir("botchu-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try await checkout(in: root)

        let made = await TaskWorktree.prepare(branch: "feat/new-thing", checkout: checkout.path)
        let folder = try made.get()
        // Where git lists it: the real path (/private/var for /var).
        #expect(URL(fileURLWithPath: folder).resolvingSymlinksInPath()
                == checkout.appendingPathComponent(".claude/worktrees/feat-new-thing").resolvingSymlinksInPath())
        #expect(FileManager.default.fileExists(atPath: folder + "/README.md"))
        let head = await Shell.run(["git", "symbolic-ref", "--short", "HEAD"], in: folder)
        #expect(head.lastLine == "feat/new-thing")
        // The main checkout stays clean: .claude/worktrees/ is ignored.
        #expect(await Shell.run(["git", "status", "--porcelain"], in: checkout.path).output.isEmpty)

        // Reopened where git lists it (its real path, /private/var for /var).
        let reopened = try await TaskWorktree.prepare(branch: "feat/new-thing", checkout: checkout.path).get()
        #expect(URL(fileURLWithPath: reopened).resolvingSymlinksInPath() == URL(fileURLWithPath: folder).resolvingSymlinksInPath())
    }

    @Test func remakesAWorktreeDeletedByHand() async throws {
        let root = tempDir("botchu-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try await checkout(in: root)
        let folder = try await TaskWorktree.prepare(branch: "feat/again", checkout: checkout.path).get()
        try FileManager.default.removeItem(atPath: folder)
        let again = try await TaskWorktree.prepare(branch: "feat/again", checkout: checkout.path).get()
        #expect(FileManager.default.fileExists(atPath: again + "/README.md"))
    }

    @Test func newBranchStartsFromOriginEvenOffline() async throws {
        let root = tempDir("botchu-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try await checkout(in: root)
        // A commit only the main checkout has, and an origin that can't be reached.
        try "local\n".write(to: checkout.appendingPathComponent("LOCAL.md"), atomically: true, encoding: .utf8)
        try await git("add", ".", in: checkout)
        try await git("commit", "--quiet", "-m", "Local", in: checkout)
        try await git("remote", "set-url", "origin", root.appendingPathComponent("gone.git").path, in: checkout)
        let folder = try await TaskWorktree.prepare(branch: "feat/offline", checkout: checkout.path).get()
        #expect(FileManager.default.fileExists(atPath: folder + "/README.md"))
        #expect(!FileManager.default.fileExists(atPath: folder + "/LOCAL.md"))
    }

    @Test func usesTheRepositorysOwnScript() async throws {
        let root = tempDir("botchu-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try await checkout(in: root)
        let scripts = checkout.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let made = root.appendingPathComponent("made-by-script").path
        // Like the standard's script: progress on stderr, the folder last on stdout.
        try "#!/bin/sh\necho \"worktree: making $1\" >&2\nmkdir -p '\(made)'\necho '\(made)'\n"
            .write(to: scripts.appendingPathComponent("worktree.sh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scripts.appendingPathComponent("worktree.sh").path)

        #expect(try await TaskWorktree.prepare(branch: "fix/7-crash", checkout: checkout.path).get() == made)
        // A branch the script refuses is made with git instead.
        let other = try await TaskWorktree.prepare(branch: "claude/odd-name", checkout: checkout.path).get()
        #expect(other.hasSuffix(".claude/worktrees/claude-odd-name"))
    }

    @Test func reportsAFolderThatIsNotAWorktree() async throws {
        let root = tempDir("botchu-worktree")
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = try await checkout(in: root)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".claude/worktrees/feat-taken"), withIntermediateDirectories: true)
        let result = await TaskWorktree.prepare(branch: "feat/taken", checkout: checkout.path)
        guard case .failure(let failure) = result else { Issue.record("expected a failure"); return }
        #expect(failure.step.contains("isn't a worktree on feat/taken"))
        let notGit = await TaskWorktree.prepare(branch: "feat/x", checkout: root.path)
        guard case .failure = notGit else { Issue.record("expected a failure outside a checkout"); return }
    }
}

@Suite struct TaskStoreTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func tasksAndTheirThreadsRoundTrip() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        #expect(home.loadTasks().isEmpty)
        let later = BotTask(repo: "asieke/BotChu", checkout: "/w/BotChu", branch: "feat/b", folder: "/w/BotChu/.claude/worktrees/feat-b",
                            brief: "B", origin: .home, accountID: "codex-dev", sessionID: "t1", sessionAccountID: "codex-dev",
                            createdAt: date.addingTimeInterval(60), pullRequest: 14)
        let first = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu",
                            work: BotTask.Work(number: 48, title: "Filter", url: URL(string: "https://github.com/asieke/GitChu/issues/48")!, isPullRequest: false),
                            createdAt: date, archivedAt: date.addingTimeInterval(5))
        try home.save(later)
        try home.save(first)
        #expect(home.loadTasks() == [first, later])
        let thread = [ChatMessage(role: .user, text: "hi", date: date)]
        try home.saveThread(thread, task: later.id)
        #expect(home.loadThread(task: later.id) == thread)
        #expect(home.loadThread(task: first.id).isEmpty)
        // Tasks live in the bot's own folder, ignored by git like the rest of .botchu/.
        #expect(FileManager.default.fileExists(atPath: home.taskURL(later.id).appendingPathComponent("task.json").path))
        #expect(FileManager.default.fileExists(atPath: home.url.appendingPathComponent(".gitignore").path))
    }

    @Test func receiptsAndOldThreadsDecode() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        let receipt = ChatMessage(role: .receipt, text: "GitChu #48 finished its turn", date: date, taskID: UUID())
        try home.saveThread([receipt])
        #expect(home.loadThread() == [receipt])
        // A line written before tasks has no taskID.
        try #"{"date":"2027-01-15T08:00:00Z","id":"00000000-0000-4000-8000-000000000001","role":"note","text":"New session"}"#
            .write(to: home.threadURL, atomically: true, encoding: .utf8)
        #expect(home.loadThread().first?.taskID == nil)
        #expect(home.loadThread().first?.role == .note)
    }

    @Test func dispatchesAreTakenOnceTheyHaveSettled() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        try home.prepareDispatch()
        try #"{"repo": "a/b", "task": "one"}"#.write(to: home.dispatchURL.appendingPathComponent("one.json"), atomically: true, encoding: .utf8)
        try "notes".write(to: home.dispatchURL.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        // Still being written, perhaps.
        #expect(!home.hasDispatches(now: Date(), settle: 30))
        #expect(home.takeDispatches(now: Date(), settle: 30).isEmpty)
        #expect(home.hasDispatches(now: Date().addingTimeInterval(60)))
        let taken = home.takeDispatches(now: Date().addingTimeInterval(60), settle: 1)
        #expect(taken.map(\.name) == ["one.json"])
        #expect(try TaskRequest.parse(taken[0].data).task == "one")
        #expect(home.takeDispatches(now: Date().addingTimeInterval(60)).isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.dispatchURL.appendingPathComponent("README.txt").path))
    }
}

@Suite struct TaskContextTests {
    let bot = Bot(name: "Scout", emoji: "🔭", title: "Finds things", instructions: "Be brief.", workspace: "/Users/a/BOTS/scout")

    func task(origin: BotTask.Origin = .owner, brief: String = "") -> BotTask {
        BotTask(repo: "asieke/GitChu", checkout: "/Users/a/WORKSPACE/GitChu", branch: "feat/48-add-filter-bar",
                folder: "/Users/a/WORKSPACE/GitChu/.claude/worktrees/feat-48-add-filter-bar",
                work: BotTask.Work(number: 48, title: "Add a filter bar", url: URL(string: "https://github.com/asieke/GitChu/issues/48")!, isPullRequest: false),
                brief: brief, origin: origin)
    }

    @Test func taskPreambleCarriesTheBotAndTheHandoff() {
        let task = task()
        let preamble = BotContext.taskPreamble(bot: bot, task: task, memory: "# Scout\n- likes tea", sharedMemory: "", history: [])
        #expect(preamble.hasPrefix("<botchu_context>"))
        #expect(preamble.contains("You are Scout — Finds things, a persistent bot in BotChu, working on a task"))
        #expect(preamble.contains("<instructions>\nBe brief.\n</instructions>"))
        #expect(preamble.contains("<bot>\n# Scout\n- likes tea\n</bot>"))
        #expect(preamble.contains("Your memory is /Users/a/BOTS/scout/MEMORY.md, in your workspace, not in this repository"))
        #expect(preamble.contains("You are in a worktree of asieke/GitChu at /Users/a/WORKSPACE/GitChu/.claude/worktrees/feat-48-add-filter-bar, on branch feat/48-add-filter-bar"))
        #expect(preamble.contains("main checkout at /Users/a/WORKSPACE/GitChu"))
        #expect(preamble.contains("Your task is issue #48 “Add a filter bar” in asieke/GitChu (https://github.com/asieke/GitChu/issues/48; gh issue view 48 --repo asieke/GitChu --comments)."))
        #expect(!preamble.contains("adds to it"))
        #expect(preamble.contains("/Users/a/BOTS/scout/.botchu/tasks/\(task.id.uuidString.lowercased())/thread.jsonl"))
        #expect(!preamble.contains("recent_conversation"))
    }

    @Test func taskPreambleForABriefFromHome() {
        let preamble = BotContext.taskPreamble(bot: bot, task: task(origin: .home, brief: "Keep it small"), memory: "", sharedMemory: "",
                                               history: [ChatMessage(role: .user, text: "Earlier"), ChatMessage(role: .assistant, text: "Done")])
        #expect(preamble.contains("The message below adds to it. You started this task yourself, from your Home conversation"))
        #expect(preamble.contains("Your memory is /Users/a/BOTS/scout/MEMORY.md"))
        #expect(preamble.contains("Owner: Earlier\n\nYou: Done"))
    }

    @Test func homeLearnsToDispatchAndHearsOfItsTasks() {
        let agents = BotContext.agentsFile(bot: bot, sharedMemoryPath: "/Users/a/BOTS/MEMORY.md", repositoriesPath: "/Users/a/WORKSPACE")
        #expect(agents.contains("## Tasks"))
        #expect(agents.contains("`.botchu/dispatch/`"))
        #expect(agents.contains("    {\"repo\": \"octocat/hello-world\", \"issue\": 12"))
        #expect(agents.contains("clones the repository if it isn't checked out there yet (into `/Users/a/WORKSPACE` on this Mac)"))

        let report = BotContext.taskReport(task(), status: BotStatus.make(task: task(), messages: [ChatMessage(role: .assistant, text: "Opened it.")], run: nil),
                                           pullRequest: 49, lastReply: "Opened it.")
        #expect(report.hasPrefix("“GitChu #48” (task "))
        #expect(report.contains("in asieke/GitChu, on issue #48 “Add a filter bar”, branch feat/48-add-filter-bar: its last turn finished; pull request #49. Its last reply: “Opened it.”"))
        let preamble = BotContext.sessionPreamble(bot: bot, memory: "", sharedMemory: "", history: [], tasks: [report])
        #expect(preamble.contains("<open_tasks>\n- “GitChu #48”"))
        #expect(BotContext.taskUpdates([]) == nil)
        let updates = BotContext.taskUpdates([report]) ?? ""
        #expect(updates.hasPrefix("<task_updates>\n"))
        #expect(BotContext.prompt(for: "hi", preamble: "<c/>", updates: updates) == "<c/>\n\n\(updates)\n\nhi")
        #expect(BotContext.prompt(for: "hi", preamble: nil, updates: "<u/>") == "<u/>\n\nhi")
    }

    @Test func reportsSayHowATaskIsDoing() {
        let task = task()
        let preparing = BotStatus.make(task: task, messages: [], run: RunState(preparing: true))
        #expect(BotContext.taskReport(task, status: preparing, pullRequest: nil, lastReply: nil).hasSuffix(": BotChu is making its worktree"))
        let failed = BotStatus.make(task: task, messages: [ChatMessage(role: .error, text: "usage limit")], run: nil)
        #expect(BotContext.taskReport(task, status: failed, pullRequest: nil, lastReply: nil).hasSuffix(": its last turn failed (usage limit)"))
        let long = String(repeating: "x", count: 2_000)
        #expect(BotContext.taskReport(task, status: failed, pullRequest: nil, lastReply: long).hasSuffix("x […]”"))
    }
}

@Suite struct TaskStatusTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let bot = Bot(name: "Scout", accountID: "claude-dev", workspace: "/tmp/scout")

    @Test func preparingIsATurnUnderWay() {
        let status = BotStatus.make(task: BotTask(repo: "a/b", checkout: "/w/b"), messages: [], run: RunState(preparing: true))
        #expect(status.phase == .preparing)
        #expect(status.phase.isActive)
    }

    @Test func aBotWorksWhileItsTasksDo() {
        let home = BotStatus.make(bot: bot, messages: [ChatMessage(role: .error, text: "old failure")], run: nil)
        #expect(home.phase == .failed)
        #expect(home.working(on: []) == home)
        var later = RunState(startedAt: date.addingTimeInterval(30), hasOutput: true)
        _ = later.move(to: .coding, at: date.addingTimeInterval(31))
        let one = home.working(on: [(title: "GitChu #48", run: later)])
        #expect(one.phase == .working)
        #expect(one.workingOn == "GitChu #48")
        #expect(one.activity == .coding)
        #expect(one.lastError == nil)
        let two = home.working(on: [(title: "GitChu #48", run: later), (title: "BotChu #11", run: RunState(startedAt: date))])
        #expect(two.workingOn == "2 tasks")
        #expect(two.runStartedAt == date)
        #expect(two.activity == .coding)
        // Home's own turn comes first.
        let busyHome = BotStatus.make(bot: bot, messages: [], run: RunState(startedAt: date, hasOutput: true))
        #expect(busyHome.working(on: [(title: "x", run: later)]).workingOn == nil)
    }

    @Test func receiptsAreNotHomeActivity() {
        let messages = [ChatMessage(role: .assistant, text: "Hi", date: date),
                        ChatMessage(role: .error, text: "failed", date: date.addingTimeInterval(1)),
                        ChatMessage(role: .receipt, text: "GitChu #48 finished its turn", date: date.addingTimeInterval(9), taskID: UUID())]
        let status = BotStatus.make(bot: bot, messages: messages, run: nil)
        #expect(status.phase == .failed)
        #expect(status.lastActivity == date.addingTimeInterval(1))
    }

    @Test func taskSessionsResumeOnlyOnTheirAccount() {
        var task = BotTask(repo: "a/b", checkout: "/w/b", accountID: "codex-dev", sessionID: "t1", sessionAccountID: "codex-dev")
        #expect(task.resumableSessionID == "t1")
        task.selectAccount("claude-dev")
        #expect(task.resumableSessionID == nil)
        #expect(BotStatus.make(task: task, messages: [], run: nil).session == .startsNew(accountChanged: true))
    }
}

@Suite struct FanOutBriefTests {
    @Test func fanOutBriefsListTheWorkAndKeepSubagentsApart() {
        let issues = [BotTask.Work(number: 12, title: "Add a filter bar", url: URL(string: "https://github.com/octocat/Orbit/issues/12")!, isPullRequest: false),
                      BotTask.Work(number: 9, title: "Crash on launch", url: URL(string: "https://github.com/octocat/Orbit/issues/9")!, isPullRequest: false)]
        let fix = FanOutBrief.fixIssues(issues, repo: "octocat/Orbit", agent: "Alex's Bot")
        #expect(fix.hasPrefix("Fix 2 open issues\n\nFix each issue of octocat/Orbit below with a parallel sub-agent of its own.\n\n"))
        #expect(fix.contains("- #12 Add a filter bar: https://github.com/octocat/Orbit/issues/12\n- #9 Crash on launch: https://github.com/octocat/Orbit/issues/9\n"))
        #expect(fix.contains("botchu-subagent spawn --agent 'Alex'\\''s Bot' --title 'Fix #<number>'"))
        #expect(fix.contains("Run at most \(FanOutBrief.parallel) at once, and collect them with `botchu-subagent wait`"))
        #expect(fix.contains("`gh issue view <number> --repo octocat/Orbit --comments`"))
        #expect(fix.contains("never in this task's folder, so no two share files"))
        #expect(fix.contains("`Closes #<number>`"))
        #expect(fix.contains("Change nothing in this task's own worktree."))
        // The first line names the task and its branch.
        #expect(TaskNaming.title(repo: "octocat/Orbit", work: nil, brief: fix) == "Orbit · Fix 2 open issues")
        #expect(TaskNaming.branch(issue: nil, text: fix, fallback: "fallback") == "feat/fix-2-open-issues")
        #expect(FanOutBrief.fixIssues([issues[0]], repo: "octocat/Orbit", agent: "Scout").hasPrefix("Fix 1 open issue\n"))

        let pull = BotTask.Work(number: 7, title: "Show open pull requests", url: URL(string: "https://github.com/octocat/BotChu/pull/7")!, isPullRequest: true)
        let review = FanOutBrief.reviewPullRequests([pull], repo: "octocat/BotChu", agent: "Scout", comment: false)
        #expect(review.hasPrefix("Review 1 open pull request\n\n"))
        #expect(review.contains("- #7 Show open pull requests: https://github.com/octocat/BotChu/pull/7"))
        #expect(review.contains("botchu-subagent spawn --agent 'Scout' --title 'Review #<number>' --brief"))
        #expect(review.contains(#"git fetch origin pull/<number>/head && git worktree add --detach "$(mktemp -d)/pr-<number>" FETCH_HEAD"#))
        #expect(review.contains("It posts nothing to GitHub."))
        #expect(!review.contains("gh api"))
        #expect(TaskNaming.title(repo: "octocat/BotChu", work: nil, brief: review) == "BotChu · Review 1 open pull request")
        let comment = FanOutBrief.reviewPullRequests([pull, pull], repo: "octocat/BotChu", agent: "Scout", comment: true)
        #expect(comment.hasPrefix("Review and comment on 2 open pull requests\n"))
        #expect(comment.contains("`gh api repos/octocat/BotChu/pulls/<number>/reviews --method POST` with `\"event\": \"COMMENT\"`"))
        #expect(comment.contains("without asking again"))
        #expect(comment.hasSuffix("its most severe findings, linking each posted review."))
        #expect(!comment.contains("It posts nothing"))
    }
}
