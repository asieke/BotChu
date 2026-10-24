import Foundation
import Testing
@testable import BotChuCore

/// A stand-in for `ssh` that skips its options and the host, then runs the command here, as the
/// host's shell would: remote tasks are tested without a host.
enum FakeSSH {
    static let path: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-fake-ssh-\(ProcessInfo.processInfo.processIdentifier)")
        try? """
            #!/bin/sh
            while [ $# -gt 0 ]; do
              case $1 in -o|-p|-i|-l|-F) shift 2 ;; -*) shift ;; *) break ;; esac
            done
            shift
            exec /bin/sh -c "$*"

            """.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }()

    /// A host reached through the stand-in.
    static var machine: Machine {
        Machine.ssh = path
        return Machine(destination: "fake-host")
    }
}

private func tempDir(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

@Suite struct HostTests {
    @Test func destinationsAndFolders() {
        #expect(SSHHost(nickname: "Omarchy", destination: "asieke@100.99.253.119").problem == nil)
        #expect(SSHHost(nickname: "", destination: "omarchy").problem != nil)
        #expect(SSHHost.destinationProblem("-oProxyCommand=x") != nil)
        #expect(SSHHost.destinationProblem("a@b@c") != nil)
        #expect(SSHHost.destinationProblem("user name@host") != nil)
        #expect(SSHHost.destinationProblem("omarchy-1.tail.ts.net") == nil)
        #expect(SSHHost.folderProblem("apps") != nil)
        #expect(SSHHost.folderProblem("~/apps") == nil)
        #expect(SSHHost(nickname: " A ", destination: " h ", reposFolder: "/root/workspace/ ").reposFolder == "/root/workspace")
        #expect(SSHHost.machineName(destination: "root@srv1902831.example.net") == "srv1902831")
        let host = SSHHost(nickname: "Omarchy", destination: "omarchy", commands: ["claude-dev": " claude ", "codex-dev": ""])
        #expect(host.command(for: Accounts.account(id: "claude-dev")) == "claude")
        #expect(host.command(for: Accounts.account(id: "codex-dev")) == nil)
        #expect(host.command(for: Accounts.account(id: "muse")) == nil)
    }

    @Test func deployTargets() {
        let file = """
            ---
            name: x-digest
            deploy: vercel:x-digest, local:omarchy-1:~/apps/x-digest, local:Alexs-MacBook-Pro-92440:~/Desktop/WORKSPACE/x-digest   # where it runs
            merge: agent
            ---

            # x-digest
            deploy: local:not-frontmatter:/x
            """
        let targets = Locations.deployTargets(projectFile: file)
        #expect(targets.map(\.machine) == ["omarchy-1", "Alexs-MacBook-Pro-92440"])
        #expect(targets.map(\.path) == ["~/apps/x-digest", "~/Desktop/WORKSPACE/x-digest"])
        #expect(Locations.deployTargets(projectFile: "# no frontmatter").isEmpty)
        #expect(Locations.deployTargets(projectFile: "---\ndeploy: none\n---\n").isEmpty)
    }

    @Test func whereARepositoryLives() {
        let omarchy = SSHHost(nickname: "Omarchy", destination: "asieke@omarchy", machine: "omarchy-1")
        let deploy = [(machine: "omarchy-1", path: "~/apps/x-digest")]
        let root = "/Users/a/WORKSPACE"
        // PROJECT.md's deploy names a host's machine: it works there.
        #expect(Locations.resolve(repo: "asieke/x-digest", chosen: nil, deployTargets: deploy, thisMac: "mac", hosts: [omarchy], reposRoot: root)
                == RepoLocation(hostID: omarchy.id, path: "~/apps/x-digest"))
        // Without that host, in the repositories folder here.
        #expect(Locations.resolve(repo: "asieke/x-digest", chosen: nil, deployTargets: deploy, thisMac: "mac", hosts: [], reposRoot: root)
                == RepoLocation(path: "/Users/a/WORKSPACE/x-digest"))
        // This Mac's own deploy target comes first.
        let both = deploy + [(machine: "Mac", path: "/Users/a/live/x-digest")]
        #expect(Locations.resolve(repo: "asieke/x-digest", chosen: nil, deployTargets: both, thisMac: "mac", hosts: [omarchy], reposRoot: root)
                == RepoLocation(path: "/Users/a/live/x-digest"))
        // The owner's choice wins, unless its host left Settings.
        let chosen = RepoLocation(path: "/tmp/x")
        #expect(Locations.resolve(repo: "asieke/x-digest", chosen: chosen, deployTargets: deploy, thisMac: "mac", hosts: [omarchy], reposRoot: root) == chosen)
        let gone = RepoLocation(hostID: UUID(), path: "~/x")
        #expect(Locations.resolve(repo: "asieke/x-digest", chosen: gone, deployTargets: [], thisMac: "mac", hosts: [omarchy], reposRoot: root)
                == RepoLocation(path: "/Users/a/WORKSPACE/x-digest"))
    }
}

@Suite struct MachineTests {
    @Test func commandsForTheHostsShell() {
        #expect(Shell.quote("it's") == #"'it'\''s'"#)
        #expect(Machine.remotePath("~") == #""$HOME""#)
        #expect(Machine.remotePath("~/apps/x y") == #""$HOME"/'apps/x y'"#)
        #expect(Machine.remotePath("/root/w") == "'/root/w'")
        #expect(Machine.remoteCommand(script: #"exec "$@""#, arguments: ["git", "log", "-1"], in: "~/apps/x")
                == #"cd "$HOME"/'apps/x' && exec "${SHELL:-/bin/sh}" -lc 'exec "$@"' botchu 'git' 'log' '-1'"#)
        #expect(Machine.sshOptions.contains("BatchMode=yes"))
    }

    @Test func runsOnAHost() async throws {
        let folder = tempDir("botchu-host")
        defer { try? FileManager.default.removeItem(at: folder) }
        let machine = FakeSSH.machine
        let run = await machine.run(["printf", "%s|%s", "a b", "it's \"quoted\""], in: folder.path)
        #expect(run.ok)
        #expect(run.output == "a b|it's \"quoted\"")
        let pwd = await machine.script(#"printf '%s %s\n' "$(pwd -P)" "$1""#, arguments: ["one two"], in: folder.path)
        #expect(pwd.lastLine?.hasSuffix("\(folder.lastPathComponent) one two") == true)
        #expect(await machine.hasFolder(folder.path))
        #expect(!(await machine.hasFolder(folder.appendingPathComponent("gone").path)))
        // A folder that isn't there fails before the command runs.
        #expect(!(await machine.run(["true"], in: folder.appendingPathComponent("gone").path).ok))
    }

    @Test func agentRunsOnAHostAndStops() async throws {
        let folder = tempDir("botchu-host-run")
        defer { try? FileManager.default.removeItem(at: folder) }
        let machine = FakeSSH.machine
        let lines = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "printf", invocation: Invocation(arguments: [#"%s\n%s\n"#, #"{"type":"one"}"#, "two"]),
                                   on: machine, folder: folder.path)
                var seen: [String] = []
                run.onLines = { seen += $0 }
                run.onExit = { _, _ in done.resume(returning: seen) }
                try? run.start()
            }
        }
        // The process id line is BotChu's, not the CLI's.
        #expect(lines == [#"{"type":"one"}"#, "two"])

        // Stop interrupts the CLI on the host, not just the connection.
        let started = Date()
        let status = await withCheckedContinuation { (done: CheckedContinuation<Int32, Never>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "sleep", invocation: Invocation(arguments: ["30"]), on: machine, folder: folder.path)
                run.onExit = { status, _ in done.resume(returning: status) }
                try? run.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { run.stop() }
            }
        }
        #expect(status != 0)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

@Suite struct RemoteWorktreeTests {
    func git(_ args: String..., in folder: URL) async throws {
        let run = await Shell.run(["git", "-c", "user.name=BotChu", "-c", "user.email=botchu@example.com",
                                   "-c", "init.defaultBranch=main"] + args, in: folder.path)
        try #require(run.ok, "\(run.report("git \(args.joined(separator: " "))"))")
    }

    /// A local origin with one commit on main, and a pull request's head (`refs/pull/7/head`) a commit ahead.
    func origin(in root: URL) async throws -> URL {
        let origin = root.appendingPathComponent("origin.git")
        try await git("init", "--bare", "--quiet", origin.path, in: root)
        let seed = root.appendingPathComponent("seed")
        try await git("clone", "--quiet", origin.path, seed.path, in: root)
        try "hello\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try await git("add", ".", in: seed)
        try await git("commit", "--quiet", "-m", "First", in: seed)
        try await git("push", "--quiet", "origin", "HEAD:main", in: seed)
        try "change\n".write(to: seed.appendingPathComponent("CHANGE.md"), atomically: true, encoding: .utf8)
        try await git("add", ".", in: seed)
        try await git("commit", "--quiet", "-m", "Change", in: seed)
        try await git("push", "--quiet", "origin", "HEAD:refs/pull/7/head", in: seed)
        return origin
    }

    @Test func clonesThenMakesAWorktreeOnAHost() async throws {
        let root = tempDir("botchu-remote")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try await origin(in: root)
        let machine = FakeSSH.machine
        let wanted = root.appendingPathComponent("apps/hello").path
        let checkout = try await TaskWorktree.checkout(origin.path, at: wanted, on: machine).get()
        #expect(checkout == wanted)
        #expect(FileManager.default.fileExists(atPath: wanted + "/README.md"))
        // Already there: kept as it is.
        #expect(try await TaskWorktree.checkout("someone/else", at: wanted, on: machine).get() == wanted)
        let folder = try await TaskWorktree.prepare(branch: "feat/far", checkout: checkout, on: machine).get()
        #expect(folder.hasSuffix("/.claude/worktrees/feat-far"))
        #expect(await Shell.run(["git", "symbolic-ref", "--short", "HEAD"], in: folder).lastLine == "feat/far")
        // In the way: says so.
        let blocked = root.appendingPathComponent("apps/blocked")
        try FileManager.default.createDirectory(atPath: blocked.appendingPathComponent("x").path, withIntermediateDirectories: true)
        guard case .failure(let failure) = await TaskWorktree.checkout(origin.path, at: blocked.path, on: machine) else {
            Issue.record("expected a failure"); return
        }
        #expect(failure.step.contains("isn't a git checkout"))
    }

    @Test func reviewsAPullRequestInADetachedWorktree() async throws {
        let root = tempDir("botchu-review")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = try await origin(in: root)
        let checkout = root.appendingPathComponent("repo")
        try await git("clone", "--quiet", origin.path, checkout.path, in: root)
        for machine in [Machine.thisMac, FakeSSH.machine] {
            let review = try await TaskWorktree.review(number: 7, checkout: checkout.path, on: machine).get()
            #expect(review.folder.hasSuffix("/pr-7"))
            #expect(FileManager.default.fileExists(atPath: review.folder + "/CHANGE.md"))
            #expect(review.head.count == 40)
            // Detached, and the main checkout is still on main.
            #expect(!(await Shell.run(["git", "symbolic-ref", "-q", "HEAD"], in: review.folder).ok))
            #expect(await Shell.run(["git", "symbolic-ref", "--short", "HEAD"], in: checkout.path).lastLine == "main")
            #expect(await TaskWorktree.remove(review.folder, checkout: checkout.path, on: machine).ok)
            #expect(!FileManager.default.fileExists(atPath: review.folder))
        }
        guard case .failure(let failure) = await TaskWorktree.review(number: 99, checkout: checkout.path) else {
            Issue.record("expected a failure"); return
        }
        #expect(failure.step == "Couldn't fetch pull request #99 from origin")
    }
}

@Suite struct RemoteContextTests {
    let bot = Bot(name: "Scout", title: "Finds things", instructions: "Be brief.", workspace: "/Users/a/BOTS/scout")

    func task(review: BotTask.Review? = nil) -> BotTask {
        var task = BotTask(repo: "asieke/x-digest", checkout: "/home/asieke/apps/x-digest",
                           branch: review == nil ? "fix/9-feed-timeout" : "",
                           folder: review == nil ? "/home/asieke/apps/x-digest/.claude/worktrees/fix-9-feed-timeout" : "/tmp/botchu-review.abc/pr-12",
                           work: BotTask.Work(number: review == nil ? 9 : 12, title: review == nil ? "Feed timeout" : "Faster feeds",
                                              url: URL(string: "https://github.com/asieke/x-digest/\(review == nil ? "issues/9" : "pull/12")")!,
                                              isPullRequest: review != nil),
                           review: review)
        task.head = review == nil ? nil : "0123456789abcdef0123456789abcdef01234567"
        return task
    }

    @Test func aTaskOnAHostKeepsTheBotsContext() {
        let home = [ChatMessage(role: .user, text: "Fix the feed timeout on Omarchy"), ChatMessage(role: .assistant, text: "Starting a task for it.")]
        let preamble = BotContext.taskPreamble(bot: bot, task: task(), memory: "# Scout\n- likes tea", sharedMemory: "", history: [],
                                               machine: "Omarchy (asieke@omarchy)", home: home)
        #expect(preamble.contains("working on a task for your owner on Omarchy (asieke@omarchy), over SSH from your owner's Mac"))
        #expect(preamble.contains("<bot>\n# Scout\n- likes tea\n</bot>"))
        #expect(preamble.contains("put it in your reply between <remember> and </remember>"))
        #expect(preamble.contains("You are on Omarchy (asieke@omarchy), in a worktree of asieke/x-digest at /home/asieke/apps/x-digest/.claude/worktrees/fix-9-feed-timeout"))
        #expect(preamble.contains("main checkout there at /home/asieke/apps/x-digest"))
        #expect(preamble.contains("<home_conversation>\nOwner: Fix the feed timeout on Omarchy\n\nYou: Starting a task for it.\n</home_conversation>"))
        // Nothing on the host points into the Mac's folder.
        #expect(!preamble.contains("thread.jsonl"))
        #expect(!preamble.contains("/Users/a/BOTS/scout/MEMORY.md"))
    }

    @Test func reviewsSayWhetherToPost() {
        let quiet = BotContext.taskPreamble(bot: bot, task: task(review: .review), memory: "", sharedMemory: "", history: [])
        #expect(quiet.contains("in a review worktree of asieke/x-digest at /tmp/botchu-review.abc/pr-12, detached at 0123456789abcdef"))
        #expect(quiet.contains("switch no branch in it, commit nothing"))
        #expect(quiet.contains("Your task is to review pull request #12 “Faster feeds”"))
        #expect(quiet.contains("Post nothing to GitHub."))
        let posted = BotContext.taskPreamble(bot: bot, task: task(review: .comment), memory: "", sharedMemory: "", history: [])
        #expect(posted.contains("Your task is to review and comment on pull request #12 “Faster feeds”"))
        #expect(posted.contains("“Review and comment on this PR”, so post your review there, as one review, without asking again."))
        #expect(task(review: .comment).opening == "Review and comment on pull request #12 “Faster feeds”.")
        #expect(TaskNaming.title(repo: "asieke/x-digest", work: task(review: .review).work, brief: "", review: true) == "x-digest #12 review")
    }

    @Test func homeKnowsTheMachinesAndReviews() {
        let agents = BotContext.agentsFile(bot: bot, sharedMemoryPath: "/Users/a/BOTS/MEMORY.md", repositoriesPath: "/Users/a/WORKSPACE",
                                           machines: ["Omarchy", "Humanist"])
        #expect(agents.contains("`owner/name` of one of your owner's GitHub repositories"))
        #expect(agents.contains("the computer to work on: This Mac, Omarchy, Humanist"))
        #expect(agents.contains("`review`: a pull request's number"))
        #expect(agents.contains("clones the repository if it isn't checked out there yet (into `/Users/a/WORKSPACE` on this Mac)"))
    }

    @Test func requestsNameAMachineAndReviews() throws {
        let review = try TaskRequest.parse(Data(#"{"repo": "asieke/x-digest", "review": 12, "comment": true, "host": "Omarchy"}"#.utf8))
        #expect(review == TaskRequest(repo: "asieke/x-digest", pullRequest: 12, machine: "Omarchy", review: .comment))
        let quiet = try TaskRequest.parse(Data(##"{"repo": "x", "review": "#12"}"##.utf8))
        #expect(quiet.review == .review && quiet.pullRequest == 12)
        #expect(throws: TaskRequest.Problem.self) { try TaskRequest.parse(Data(#"{"repo": "x", "review": 12, "pr": 13}"#.utf8)) }
    }
}

@Suite struct MemoryNotesTests {
    @Test func remembersBlocksFromReplies() {
        let messages = [
            ChatMessage(role: .assistant, text: "Done.\n<remember>\n- Alex wants PRs small\n* Omarchy runs Arch\n</remember>"),
            ChatMessage(role: .user, text: "<remember>not from the owner</remember>"),
            ChatMessage(role: .assistant, text: "Also <REMEMBER>x-digest deploys on Omarchy</REMEMBER> and that's it."),
        ]
        #expect(MemoryNotes.remembered(in: messages) == ["Alex wants PRs small", "Omarchy runs Arch", "x-digest deploys on Omarchy"])
        #expect(MemoryNotes.remembered(in: [ChatMessage(role: .assistant, text: "Nothing to keep.")]).isEmpty)
    }

    @Test func appendsToTheMemoryFile() throws {
        let folder = tempDir("botchu-memory")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("MEMORY.md").path
        try "# Scout\n\nWhat Scout has learned.".write(toFile: file, atomically: true, encoding: .utf8)
        try MemoryNotes.append(["one"], toMemoryAt: file)
        try MemoryNotes.append(["two", "three"], toMemoryAt: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "# Scout\n\nWhat Scout has learned.\n\n- one\n- two\n- three\n")
    }

    @Test func deduplicatesReplacesForgetsAndFiltersSecrets() throws {
        let openRouterPrefix = "sk-" + "or-"
        let githubPrefix = "ghp" + "_"
        let pemHeader = "-----" + "BEGIN OPENSSH " + "PRIVATE KEY-----"
        let messages = [
            ChatMessage(role: .assistant, text: """
                <remember>
                - Alex prefers dark mode
                *   alex prefers   dark mode
                - OPENROUTER_API_KEY="\(openRouterPrefix)example"
                - \(githubPrefix)example
                - password: example-value
                - \(pemHeader)
                - OPENROUTER_API_KEY is read from the macOS Keychain
                </remember>
                """),
        ]
        #expect(MemoryNotes.remembered(in: messages) == [
            "Alex prefers dark mode",
            "OPENROUTER_API_KEY is read from the macOS Keychain",
        ])

        let folder = tempDir("botchu-memory-updates")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("MEMORY.md").path
        try "# Scout\n\nWhat Scout has learned.\n\n- Alex prefers light mode\n- Omarchy runs Arch\n- Old temporary note\n"
            .write(toFile: file, atomically: true, encoding: .utf8)

        try MemoryNotes.append([
            "omarchy   runs arch",
            "Replace: Alex prefers light mode -> Alex prefers dark mode",
            "Forget: Old temporary note",
            "\(openRouterPrefix)example",
            "Scout checks PR status before merging",
        ], toMemoryAt: file)

        #expect(try String(contentsOfFile: file, encoding: .utf8) == """
            # Scout

            What Scout has learned.

            - Alex prefers dark mode
            - Omarchy runs Arch
            - Scout checks PR status before merging

            """)
    }
}
