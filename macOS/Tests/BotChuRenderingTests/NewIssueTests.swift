import AppKit
import SwiftUI
import Testing
@testable import BotChuCore
@testable import BotChu

/// What the stand-ins for the bot's CLI and gh were given: no test runs a model or files an issue.
private actor IssueCalls {
    static let reply = ###"<issue>{"title": "Press I to file an issue", "body": "## Outcome\nIt works."}</issue>"###
    private(set) var prompts: [String] = []
    private(set) var created: [[String]] = []
    /// What the bot replies, in turn, then a reply that isn't an issue; and whether gh refuses next.
    var replies = [reply]
    var fails = true

    func answer(_ job: EvaluationJob) -> String {
        prompts.append("\(job.account.id)|\(job.model)|\(job.prompt)")
        return replies.isEmpty ? "I can't." : replies.removeFirst()
    }

    func create(_ call: [String]) -> IssueFiler.Outcome {
        created.append(call)
        defer { fails = false }
        return fails ? .failed("gh couldn't create the issue:\nHTTP 401") : .filed(URL(string: "https://github.com/asieke/BotChu/issues/246"))
    }

    func replyAgain() { replies = [Self.reply] }
}

extension RenderingTests {
    /// New Issue (#245): it opens for the repository selected in Projects with Product Fox on its
    /// own profile; another bot brings its own profile (or one that can write without tools); File
    /// Issue closes the sheet at once and the bot's quick pass is filed with gh in the background,
    /// shown in Projects' header and delivered to the Inbox as the bot's. One that fails says why
    /// and is tried again as it was asked for.
    @Test func newIssueIsWrittenByProductFoxAndFiledInTheBackground() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-new-issue-\(UUID().uuidString)")
        let domain = "local.BotChu.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.set(root.appendingPathComponent("bots").path, forKey: "botsRoot")
        let scout = Bot(name: "Scout", accountID: "google", workspace: root.appendingPathComponent("bots/scout").path)
        let fox = Bot(name: "Product Fox", accountID: "codex-work", model: "gpt-6", workspace: root.appendingPathComponent("bots/fox").path)
        let store = Store(root: root.appendingPathComponent("Support"))
        for bot in [scout, fox] { try BotHome(workspace: bot.workspace).save(bot) }
        try "Write issues with ## Outcome and ## Acceptance criteria.".write(
            toFile: (fox.workspace as NSString).appendingPathComponent(BotContext.instructionsFile), atomically: true, encoding: .utf8)
        try store.saveIndex([scout, fox].map { Store.Entry(id: $0.id, workspace: $0.workspace) })
        // GitHub never answers: the sync after a filing reads nothing.
        let model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                             usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") },
                             projectGitHub: ProjectGitHub { _, _ in Shell.Result(status: 1, output: "", errors: "offline") },
                             openWorkLookup: { _ in .failure(TaskWorktree.Failure(step: "offline", output: "")) })
        model.repositories = [GitHubLookup.Repo(nameWithOwner: "asieke/BotChu", description: "Bots on a Mac")]
        let calls = IssueCalls()
        model.issueRunner = { job in await calls.answer(job) }
        model.issueCreate = { (repo: String, title: String, body: String, images: [Data]) in await calls.create([repo, title, body, "\(images.count)"]) }

        // From Projects, with BotChu selected: Product Fox, on its own profile.
        model.selectProject("asieke/BotChu")
        model.startNewIssue()
        let request = try #require(model.newIssue)
        #expect(request.repo == "asieke/BotChu" && request.botID == fox.id && request.accountID == "codex-work")
        #expect(!model.canStartNewIssue)
        #expect(model.newIssueProblem(request) == "Say what the issue is about")
        // Scout's own profile can't write without tools: it writes on the first that can.
        model.chooseIssueWriter(scout.id, for: request)
        #expect(request.accountID == "claude-personal")
        model.chooseIssueWriter(fox.id, for: request)
        request.text = "When I'm in Projects, I want to press I to file an issue."
        #expect(model.newIssueProblem(request) == nil)

        // The first try: the fox writes it, gh refuses, and the header says why.
        model.fileNewIssue(request)
        #expect(model.newIssue == nil && model.canStartNewIssue)
        #expect(model.issueFilings.map(\.state) == [.writing])
        try await waitForFiling { model.issueFilings.first?.state == .failed("gh couldn't create the issue:\nHTTP 401") }
        let prompt = try #require(await calls.prompts.first)
        #expect(prompt.hasPrefix("codex-work|gpt-6|"))
        #expect(prompt.contains("press I to file an issue") && prompt.contains("Write issues with ## Outcome") && prompt.contains("Bots on a Mac"))
        #expect(model.inbox.all.isEmpty)

        // Tried again as it was asked for: filed, in the header and the Inbox, credited to the fox.
        await calls.replyAgain()
        let id = try #require(model.issueFilings.first?.id)
        model.retryFiling(id)
        try await waitForFiling { model.issueFilings.first?.state == .filed(URL(string: "https://github.com/asieke/BotChu/issues/246"), title: "Press I to file an issue") }
        let created = await calls.created
        #expect(created.count == 2)
        #expect(created.last == ["asieke/BotChu", "Press I to file an issue",
                                 "## Outcome\nIt works.\n\n_Written up by Product Fox and filed from BotChu._\n", "0"])
        try await waitForFiling { !model.inbox.all.isEmpty }
        let delivery = try #require(model.inbox.all.first)
        #expect(delivery.botID == fox.id && delivery.taskID == nil && delivery.purpose == .completed)
        #expect(delivery.title == "Filed #246: Press I to file an issue")
        #expect(delivery.links == [Delivery.Link(repo: "asieke/BotChu", number: 246, isPullRequest: false)])

        // A reply that isn't an issue files nothing, and stays until dismissed.
        model.startNewIssue()
        let next = try #require(model.newIssue)
        next.text = "Another one"
        model.fileNewIssue(next)
        try await waitForFiling { model.issueFilings.contains { $0.state == .failed("Product Fox's reply wasn't an issue BotChu could file") } }
        #expect(await calls.created.count == 2)
        let failed = try #require(model.issueFilings.first { if case .failed = $0.state { true } else { false } })
        model.dismissFiling(failed.id)
        #expect(!model.issueFilings.contains { $0.id == failed.id })
    }

    /// I opens New Issue from Projects' window, alone, unless text is being typed or a sheet is open.
    @Test func aBareKeyWaitsForTextAndSheets() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = BareKey.KeyView()
        view.key = "i"
        let field = NSTextField()
        let content = NSView()
        content.addSubview(view)
        content.addSubview(field)
        window.contentView = content
        func key(_ text: String, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: (window ?? content.window!).windowNumber,
                             context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 34)!
        }
        window.makeFirstResponder(nil)
        #expect(view.takes(key("i")))
        #expect(view.takes(key("I", .capsLock)))
        #expect(!view.takes(key("i", .command)))
        #expect(!view.takes(key("i", .shift)))
        #expect(!view.takes(key("j")))
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        #expect(!view.takes(key("i", in: other)))
        // Typing in a field: its field editor is an NSText.
        window.makeFirstResponder(field)
        #expect(window.firstResponder is NSText)
        #expect(!view.takes(key("i")))
    }

    private func waitForFiling(line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "New Issue reached the expected state at line \(line)")
    }
}
