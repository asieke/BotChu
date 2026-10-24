import Foundation
import Testing
@testable import BotChuCore

/// A stand-in for `gh` that keeps what it was given beside itself (its arguments, one a line, what
/// it read on standard input, the folder it ran in and a copy of each file it was to attach) and
/// answers as gh does: with the new issue's address, or, when it `fails`, with what gh says when it
/// isn't signed in. Filing is tested without reaching GitHub.
private struct FakeGH {
    let folder: URL
    var path: String { folder.appendingPathComponent("gh").path }

    init(fails: Bool = false) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-fake-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let answer = fails
            ? "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2; exit 4"
            : "echo 'Creating issue in asieke/BotChu' >&2; echo 'https://github.com/asieke/BotChu/issues/4242'"
        try """
            #!/bin/sh
            dir=$(dirname "$0")
            printf '%s\\n' "$@" > "$dir/arguments"
            cat > "$dir/body"
            pwd > "$dir/ran-in"
            for arg in "$@"; do
              case "$arg" in --attach=*) file=${arg#--attach=}; file=${file%%#*}; cp "$file" "$dir/attached-$(basename "$file")" ;; esac
            done
            \(answer)

            """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    var arguments: [String] {
        ((try? String(contentsOf: folder.appendingPathComponent("arguments"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var body: String? { try? String(contentsOf: folder.appendingPathComponent("body"), encoding: .utf8) }

    var ranIn: String? {
        (try? String(contentsOf: folder.appendingPathComponent("ran-in"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func attached(_ name: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent("attached-" + name)) }
}

@Suite struct IssueReportTests {
    @Test func titleIsTheFirstLineOrSentenceCutAtAWord() {
        #expect(IssueReport.title(from: "The sidebar flickers when a task starts.\n\nSteps: open a bot.") == "The sidebar flickers when a task starts")
        #expect(IssueReport.title(from: "\n\n  ## Bug:   composer  loses   focus  \nmore") == "Bug: composer loses focus")
        #expect(IssueReport.title(from: "- [ ] Can bots share memory?") == "Can bots share memory?")
        #expect(IssueReport.title(from: "> **Feature:** let me pin a bot") == "Feature: let me pin a bot")
        #expect(IssueReport.title(from: "1. Open Projects") == "Open Projects")
        #expect(IssueReport.title(from: "#123 crashes on launch") == "#123 crashes on launch")
        // A line without words, like a rule or a code fence, is passed over.
        #expect(IssueReport.title(from: "---\n```\nThe app crashes on launch\n```") == "The app crashes on launch")
        // A long line gives its first sentence, run on past one too short to say anything.
        #expect(IssueReport.title(from: "Bug! The status sidebar shows the wrong account after switching. It happens every time I switch a task's account.")
                == "Bug! The status sidebar shows the wrong account after switching")
        // A long sentence is cut at a word, with an ellipsis, within the limit.
        let cut = IssueReport.title(from: "When I open the Projects table at the narrowest window width the columns overflow and the last one is cut off")
        #expect(cut == "When I open the Projects table at the narrowest window width the…")
        #expect(cut.count <= IssueReport.titleLimit)
        // One long word is cut where it must be.
        #expect(IssueReport.title(from: String(repeating: "a", count: 100)) == String(repeating: "a", count: 71) + "…")
        #expect(IssueReport.title(from: "  \n \n") == "Report from BotChu")
    }

    @Test func ghCommandAndTheIssueItPrints() {
        // The title is one word, so one that starts with "-" is never read as an option.
        #expect(IssueReport.arguments(title: "-v crashes")
                == ["gh", "issue", "create", "--repo", "asieke/BotChu", "--title=-v crashes", "--body-file", "-"])
        // Images are attached by a count, never their own names, from the folder gh runs in.
        #expect(IssueReport.arguments(title: "Glitch", images: 2).suffix(2)
                == ["--attach=./image-1.png#Image 1", "--attach=./image-2.png#Image 2"])
        #expect(IssueReport.issueURL(in: "\nhttps://github.com/asieke/BotChu/issues/53\n") == URL(string: "https://github.com/asieke/BotChu/issues/53"))
        #expect(IssueReport.issueURL(in: "http://github.com/asieke/botchu/issues/7") == URL(string: "https://github.com/asieke/BotChu/issues/7"))
        #expect(IssueReport.issueURL(in: "https://github.com/someone/else/issues/9") == nil)
        #expect(IssueReport.issueURL(in: "") == nil)
        #expect(IssueReport.number(of: URL(string: "https://github.com/asieke/BotChu/issues/53")!) == 53)
    }

    @Test func failuresSayWhyInGhsOwnWords() {
        #expect(IssueReport.outcome(of: Shell.Result(status: 0, output: "https://github.com/asieke/BotChu/issues/5\n", errors: ""))
                == .filed(URL(string: "https://github.com/asieke/BotChu/issues/5")))
        #expect(IssueReport.outcome(of: Shell.Result(status: 0, output: "", errors: "")) == .filed(nil))
        #expect(IssueReport.outcome(of: Shell.Result(status: 127, output: "", errors: "botchu:1: command not found: gh"))
                == .failed("BotChu couldn't run gh, the GitHub CLI. Install it and sign in with gh auth login in Terminal, then try again."))
        #expect(IssueReport.outcome(of: Shell.Result(status: 1, output: "", errors: "HTTP 401: Bad credentials (https://api.github.com/graphql)\n"))
                == .failed("gh couldn't create the issue:\nHTTP 401: Bad credentials (https://api.github.com/graphql)"))
        #expect(IssueReport.outcome(of: Shell.Result(status: 2, output: "", errors: " \n")) == .failed("gh couldn't create the issue (exit status 2)."))
        // Nothing shaped like a token is shown.
        #expect(IssueReport.outcome(of: Shell.Result(status: 1, output: "", errors: "bad token gho_abcdefghijklmnopqrst"))
                == .failed("gh couldn't create the issue:\nbad token [token hidden]"))

        // An image that didn't upload: gh makes the issue with the others, prints its address and fails.
        #expect(IssueReport.outcome(of: Shell.Result(status: 1, output: "https://github.com/asieke/BotChu/issues/6\n",
                                                     errors: "failed to upload ./image-2.png: unexpected EOF\n"), images: 2)
                == .filed(URL(string: "https://github.com/asieke/BotChu/issues/6"), problem: "Not every image was attached:\nfailed to upload ./image-2.png: unexpected EOF"))
        // A gh from before --attach, and an account that can't attach to the repository.
        let usage = "unknown flag: --attach\n\nUsage:  gh issue create [flags]\n\nFlags:\n"
            + ["assignee", "body", "body-file", "editor", "label", "milestone", "project", "title", "web"].map { "      --\($0) string   …\n" }.joined()
        #expect(IssueReport.outcome(of: Shell.Result(status: 1, output: "", errors: usage), images: 1)
                == .failed("This gh can't attach images: that takes gh 2.99 or later. Update gh (brew upgrade gh, if Homebrew installed it), or remove the images to file the report without them."))
        #expect(IssueReport.outcome(of: Shell.Result(status: 1, output: "", errors: "attaching files requires write access to the repository\n"), images: 1)
                == .failed("gh couldn't create the issue:\nattaching files requires write access to the repository\n\nRemove the images to file the report without them."))
    }

    @Test func filesThroughGhWithTheBodyOnStandardInput() async throws {
        let gh = try FakeGH()
        defer { try? FileManager.default.removeItem(at: gh.folder) }
        let snapshot = IssueSnapshot(info: nil, screen: .projects, bots: 1, runningTurns: 0)
        let report = "Projects never finish loading.\n\nThe spinner keeps going."
        #expect(await IssueFiler(gh: gh.path).file(report, snapshot: snapshot) == .filed(URL(string: "https://github.com/asieke/BotChu/issues/4242")))
        #expect(gh.arguments == ["issue", "create", "--repo", "asieke/BotChu", "--title=Projects never finish loading", "--body-file", "-"])
        #expect(gh.body == IssueReport.body(report: report, snapshot: snapshot))
    }

    @Test func attachesImagesFromAFolderThatGoesAfterwards() async throws {
        let gh = try FakeGH()
        defer { try? FileManager.default.removeItem(at: gh.folder) }
        let snapshot = IssueSnapshot(info: nil, screen: .projects, bots: 1, runningTurns: 0)
        let images = [Data("first image".utf8), Data("second image".utf8)]
        #expect(await IssueFiler(gh: gh.path).file("The table overflows.", images: images, snapshot: snapshot)
                == .filed(URL(string: "https://github.com/asieke/BotChu/issues/4242")))
        #expect(gh.arguments.suffix(2) == ["--attach=./image-1.png#Image 1", "--attach=./image-2.png#Image 2"])
        #expect(gh.body == IssueReport.body(report: "The table overflows.", images: 2, snapshot: snapshot))
        #expect(gh.attached("image-1.png") == images[0])
        #expect(gh.attached("image-2.png") == images[1])
        // gh ran in a folder of BotChu's own, which is gone.
        let ranIn = try #require(gh.ranIn)
        #expect(ranIn.contains("botchu-report-"))
        #expect(!FileManager.default.fileExists(atPath: ranIn))
    }

    @Test func aReportThatIsNotFiledSaysWhy() async throws {
        let gh = try FakeGH(fails: true)
        defer { try? FileManager.default.removeItem(at: gh.folder) }
        let snapshot = IssueSnapshot(info: nil, screen: .agents, bots: 0, runningTurns: 0)
        #expect(await IssueFiler(gh: gh.path).file("It crashed", snapshot: snapshot)
                == .failed("gh couldn't create the issue:\nTo get started with GitHub CLI, please run:  gh auth login"))
        // Without gh at all.
        let missing = await IssueFiler(gh: gh.folder.appendingPathComponent("missing").path).file("It crashed", snapshot: snapshot)
        #expect(missing == .failed("BotChu couldn't run gh, the GitHub CLI. Install it and sign in with gh auth login in Terminal, then try again."))
        // An empty report, one with too many images, or one too long for GitHub, never reaches gh.
        let never = IssueFiler { _, _, _ in
            Issue.record("gh ran")
            return .filed(nil)
        }
        #expect(await never.file(" \n ", snapshot: snapshot) == .failed("Write the report first."))
        #expect(await never.file("It crashed", images: Array(repeating: Data([1]), count: 9), snapshot: snapshot)
                == .failed("Attach up to 8 images."))
        if case .failed(let why) = await never.file(String(repeating: "a", count: IssueReport.bodyLimit), snapshot: snapshot) {
            #expect(why.contains("too long"))
        } else {
            Issue.record("A report too long for GitHub was filed")
        }
    }

    @Test func bodyHasTheReportThenTheAppState() {
        let snapshot = IssueSnapshot(info: ["CFBundleShortVersionString": "0.1"], system: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1),
                                     screen: .noBot, bots: 0, runningTurns: 0)
        let body = IssueReport.body(report: "  Add a dark icon.\n", snapshot: snapshot)
        #expect(body.hasPrefix("Add a dark icon.\n\n### App state\n\n- Version: 0.1\n- System: macOS 27.0.1, "))
        #expect(body.hasSuffix("\n- Screen: no bot selected\n- Bots: 0, no turns running\n\n_Filed from BotChu. The app state holds categories and counts only: no conversations, instructions, memory, paths or names._\n"))
        // Images come after the report, each as the file gh attaches, which it points at its upload.
        #expect(IssueReport.body(report: "Add a dark icon.", images: 2, snapshot: snapshot)
            .hasPrefix("Add a dark icon.\n\n![Image 1](./image-1.png)\n\n![Image 2](./image-2.png)\n\n### App state\n\n- Version: 0.1\n"))
    }

    /// A window's screenshot keeps every pixel it shows up to 2,048 on its longest edge, and is
    /// scaled down, keeping its shape, past that; never up.
    @Test func screenshotsKeepTheWindowsPixelsUpToTheEdgeLimit() {
        #expect(IssueReport.screenshotSize(width: 820, height: 600, scale: 2) == (1640, 1200))
        #expect(IssueReport.screenshotSize(width: 1240, height: 800, scale: 2) == (2048, 1321))
        #expect(IssueReport.screenshotSize(width: 800, height: 1728, scale: 2) == (948, 2048))
        #expect(IssueReport.screenshotSize(width: 1240, height: 800, scale: 1) == (1240, 800))
        #expect(IssueReport.screenshotSize(width: 3000, height: 3000, scale: 1) == (2048, 2048))
        #expect(IssueReport.screenshotSize(width: 0, height: 0, scale: 0) == (1, 1))
    }
}

@Suite struct IssueSnapshotTests {
    @Test func versionComesFromTheBuildOrSaysDevelopmentBuild() {
        #expect(IssueSnapshot.version(info: ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "412", "BotChuCommit": "cece785"])
                == "0.1 (build 412, commit cece785)")
        #expect(IssueSnapshot.version(info: ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "412", "BotChuCommit": "cece785-dirty"])
                == "0.1 (build 412, commit cece785-dirty)")
        #expect(IssueSnapshot.version(info: ["CFBundleShortVersionString": "1.2.3"]) == "1.2.3")
        #expect(IssueSnapshot.version(info: nil) == "development build")
        #expect(IssueSnapshot.version(info: ["CFBundleExecutable": "BotChu", "BotChuCommit": "cece785"]) == "development build (commit cece785)")
        // Anything else in those keys is left out.
        #expect(IssueSnapshot.version(info: ["CFBundleShortVersionString": "0.1 /Users/alex", "CFBundleVersion": "1", "BotChuCommit": "x"])
                == "development build")
        #expect(IssueSnapshot.version(info: ["CFBundleShortVersionString": "0.2", "CFBundleVersion": "412 on alex-mac", "BotChuCommit": ""])
                == "0.2")
    }

    @Test func aTaskOnAHostKeepsCategoriesAndCountsOnly() {
        var bot = Bot(name: "Secret Agent", emoji: "🕵️", title: "Handles payroll for Acme", instructions: "The vault code is hunter2.",
                      accountID: "claude-work", model: "opus", reasoningEffort: .high, workspace: "/Users/alexsieke/BotChu/secret-agent",
                      appearance: "a brass robot")
        bot.sessionID = "11111111-2222-3333-4444-555555555555"
        bot.sessionAccountID = "claude-work"
        let host = SSHHost(nickname: "Omarchy", destination: "alex@omarchy.tail.ts.net", machine: "omarchy-1", reposFolder: "~/apps")
        let work = BotTask.Work(number: 12, title: "Rotate the payroll key", url: URL(string: "https://github.com/acme/payroll-private/issues/12")!,
                                isPullRequest: false)
        let task = BotTask(for: bot, repo: "acme/payroll-private", checkout: "~/apps/payroll-private", work: work,
                           brief: "Use the staging vault for now", branch: "feat/12-rotate-payroll-key", host: host)
        let messages = [
            ChatMessage(role: .user, text: "My bank password is hunter2."),
            ChatMessage(role: .tool, toolID: "t1", toolName: "Bash", toolInput: "cat ~/.ssh/id_rsa", toolOutput: "ssh key material", toolState: .done),
            ChatMessage(role: .assistant, text: "Done, see /Users/alexsieke/apps/payroll-private."),
            ChatMessage(role: .error, text: "Couldn't make this task's worktree on Omarchy. scripts/worktree.sh feat/12-rotate-payroll-key failed.\n"
                        + "$ make the worktree in ~/apps/payroll-private\nfatal: could not read Password for 'https://ghp_secret@github.com'"),
        ]
        let status = BotStatus.make(task: task, messages: messages, run: nil)
        let conversation = IssueSnapshot.Conversation(settings: task, task: task, status: status, queued: 2, queuePaused: true, subagents: 1)
        let snapshot = IssueSnapshot(info: ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "412", "BotChuCommit": "cece785"],
                                     system: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0),
                                     screen: .conversation(statusArea: "Memory"), conversation: conversation,
                                     window: IssueSnapshot.Window(width: 1240.4, height: 799.6, dark: true), bots: 3, runningTurns: 2)
        #expect(snapshot.lines.count == 8)
        #expect(snapshot.lines[0] == "Version: 0.1 (build 412, commit cece785)")
        #expect(snapshot.lines[1].hasPrefix("System: macOS 27.0, "))
        #expect(Array(snapshot.lines[2...]) == [
            "Screen: conversation, status sidebar on Memory",
            "Conversation: task on an SSH host, working on an issue, no worktree yet; 2 messages, 1 tool call; 2 messages waiting to send (paused); 1 sub-agent running",
            "Provider: Claude Code, a built-in account; model: opus; effort: high",
            "State: last turn failed: couldn't make the task's worktree; its next message starts a new CLI session",
            "Window: 1240 × 800 points, dark appearance",
            "Bots: 3, 2 turns running",
        ])
        let body = IssueReport.body(report: "The worktree wasn't made.", snapshot: snapshot)
        for secret in ["Secret Agent", "Acme", "acme", "hunter2", "brass", "alexsieke", "payroll", "Omarchy", "omarchy", "ghp_", "staging",
                       "11111111", "id_rsa", "key material", "Bash", "feat/", "worktree.sh", "#12", "Rotate", "~/apps", "claude-work", "Claude Work"] {
            #expect(!body.contains(secret), "“\(secret)” reached the issue")
        }
    }

    @Test func homeOnAnAddedProfileLeavesItsNameAndModelOut() {
        let profile = Account(id: "codex-alex", name: "Alex's Secret Codex", kind: .codex, defaultCommand: "~/bin/secret-codex", symbol: "c.circle")
        var bot = Bot(name: "Scout", accountID: profile.id, model: "acme/private-finetune", workspace: "/Users/alexsieke/BotChu/scout")
        bot.accountProfile = profile
        bot.sessionID = "abc"
        bot.sessionAccountID = profile.id
        let start = Date(timeIntervalSince1970: 1_000_000)
        let status = BotStatus.make(bot: bot, messages: [ChatMessage(role: .user, text: "Look at acme's books.")],
                                    run: RunState(startedAt: start, hasOutput: true, activity: .coding))
        let conversation = IssueSnapshot.Conversation(settings: bot, task: nil, status: status, openTasks: 2, now: start.addingTimeInterval(151))
        #expect(conversation.lines == [
            "Conversation: Home with 2 open tasks; 1 message, 0 tool calls",
            "Provider: Codex, an added profile; model: a custom ID (left out); effort: auto",
            "State: working (coding) for 2:31; its next message continues its CLI session",
        ])
        #expect(!conversation.lines.joined().contains("Secret"))
        #expect(!conversation.lines.joined().contains("Scout"))
    }

    @Test func taskKindsAndStates() {
        let bot = Bot(name: "Reviewer", accountID: "openrouter", workspace: "/tmp/reviewer")
        let pullRequest = BotTask.Work(number: 7, isPullRequest: true, repo: "o/r")
        let review = BotTask(for: bot, repo: "o/r", checkout: "/tmp/r", work: pullRequest, brief: "", origin: .home, review: .comment)
        var continuing = BotTask(for: bot, repo: "o/r", checkout: "/tmp/r", work: pullRequest, brief: "", review: nil)
        continuing.folder = "/tmp/r/.claude/worktrees/x"
        var brief = BotTask(for: bot, repo: "o/r", checkout: "/tmp/r", work: nil, brief: "Tidy up")
        brief.folder = "/tmp/r/.claude/worktrees/y"
        brief.sessionID = "s"
        brief.sessionAccountID = "codex-dev"
        let preparing = BotStatus.make(task: review, messages: [], run: RunState(preparing: true))
        #expect(IssueSnapshot.Conversation(settings: review, task: review, status: preparing).lines.first
                == "Conversation: task on this Mac, reviewing a pull request and posting the review, started by its bot, no worktree yet; 0 messages, 0 tool calls")
        let starting = BotStatus.make(task: continuing, messages: [], run: RunState())
        #expect(IssueSnapshot.Conversation(settings: continuing, task: continuing, status: starting).lines.first
                == "Conversation: task on this Mac, continuing a pull request; 0 messages, 0 tool calls")
        #expect(IssueSnapshot.Conversation(settings: continuing, task: continuing, status: starting).lines[1]
                == "Provider: Pi (OpenRouter), a built-in account; model: the account's default; effort: auto")
        let idle = BotStatus.make(task: brief, messages: [], run: nil)
        #expect(IssueSnapshot.Conversation(settings: brief, task: brief, status: idle).lines
                == ["Conversation: task on this Mac, new work from a brief; 0 messages, 0 tool calls",
                    "Provider: Pi (OpenRouter), a built-in account; model: the account's default; effort: auto",
                    "State: idle; its next message starts a new CLI session (account changed)"])
        #expect(IssueSnapshot.Conversation.state(preparing, now: Date()).hasPrefix("preparing its turn for 0:0"))
        #expect(IssueSnapshot.Conversation.state(starting, now: Date()).hasPrefix("turn started, no output yet for 0:0"))
    }

    @Test func errorsBecomeKindsWithoutTheirText() {
        let kinds: [(String, String)] = [
            ("Couldn't make this task's worktree on Omarchy. scripts/worktree.sh feat/x failed.", "couldn't make the task's worktree"),
            ("Couldn't reach Omarchy over SSH:\nssh: connect to host 10.0.0.2 port 22: Connection refused", "couldn't reach the host over SSH"),
            ("Claude Dev exited with status 1:\n/Users/alex/.local/bin/claude-dev: line 3: no such file", "the CLI exited with status 1"),
            ("Alex's Codex exited with status 137 without replying.", "the CLI exited with status 137 without replying"),
            ("Couldn't send images: The file “x.png” couldn't be opened.", "couldn't send the attached images"),
            ("Couldn't start Claude Dev: The operation couldn't be completed.", "couldn't start the CLI"),
            ("Couldn't prepare delegation: no Python 3 on omarchy", "couldn't prepare sub-agents"),
            ("Couldn't prepare /Users/alex/BotChu/scout: permission denied", "couldn't prepare the bot's folder"),
            ("Couldn't save this message. It is still queued.", "couldn't save"),
            ("Couldn't save to Scout's MEMORY.md: disk full", "couldn't save"),
            ("Couldn't move this bot's history to /Volumes/x: exists", "couldn't move the bot's folder"),
            ("Add your OpenRouter API key in BotChu ▸ Settings first.", "no OpenRouter key in Settings"),
            ("This task works on Omarchy over SSH, which isn't in Settings ▸ Hosts any more.", "its host isn't in Settings any more"),
            (#"API Error: 401 {"error":"invalid x-api-key sk-ant-123"}"#, "an error from the CLI (its text is left out)"),
            ("", "an error from the CLI (its text is left out)"),
        ]
        for (text, kind) in kinds { #expect(IssueSnapshot.errorKind(text) == kind, "\(text)") }
    }

    @Test func screensAndTheWindow() {
        func lines(_ screen: IssueSnapshot.Screen) -> [String] {
            IssueSnapshot(info: nil, screen: screen, window: IssueSnapshot.Window(width: 820, height: 600, dark: false), bots: 1, runningTurns: 1).lines
        }
        #expect(lines(.projects)[2...] == ["Screen: Projects", "Window: 820 × 600 points, light appearance", "Bots: 1, 1 turn running"])
        #expect(lines(.agents)[2] == "Screen: Agents")
        #expect(lines(.providers)[2] == "Screen: Providers")
        #expect(lines(.skills)[2] == "Screen: Skills")
        #expect(lines(.jobs)[2] == "Screen: Jobs")
        #expect(lines(.conversation(statusArea: nil))[2] == "Screen: conversation, status sidebar hidden")
        #expect(lines(.noBot)[2] == "Screen: no bot selected")
    }
}
