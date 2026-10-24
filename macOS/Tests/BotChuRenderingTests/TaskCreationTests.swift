import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func tasksManageTheirOwnBranchesAndKeepDetailsInAgentContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-task-creation-\(UUID().uuidString)")
        let suite = "BotChu.TaskCreation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bot = Bot(name: "Builder", accountID: "codex-dev", workspace: root.appendingPathComponent("bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let checkout = root.appendingPathComponent("project").path
        #expect(await Shell.run(["git", "init", "-b", "main", checkout], in: root.path).ok)
        #expect(await Shell.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                                 "commit", "--allow-empty", "-m", "Initial"], in: checkout).ok)
        let cli = root.appendingPathComponent("fixture.py")
        try """
        import json, sys
        from pathlib import Path
        Path('prompt.txt').write_text(sys.argv[-1])
        print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-session'}))
        print(json.dumps({'type': 'item.completed', 'item': {'id': 'answer', 'type': 'agent_message', 'text': 'Done.'}}))
        print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 1, 'output_tokens': 1}}))
        """.write(to: cli, atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: defaults)
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(cli.path))"
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let model = AppModel(store: store, settings: settings)
        defer { model.stopAll() }
        let issue = BotTask.Work(number: 17, title: "Improve startup", url: URL(string: "https://example.com/issues/17")!, isPullRequest: false)
        var prepared: [BotTask] = []
        // New Task supplies no branch: matching briefs get distinct workspaces, and issues keep
        // their numbered branch. The agent still receives the real branch and path in its context.
        for work in [BotTask.Work?.none, nil, issue] {
            let task = BotTask(for: bot, repo: "fixture/project", checkout: checkout, work: work, brief: "Improve startup")
            let target = ChatTarget.task(task.id, of: bot.id)
            model.startTask(task, for: bot.id, show: false)
            for _ in 0..<250 {
                if !model.isRunning(target) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!model.isRunning(target))
            let errors = model.thread(target).filter { $0.role == .error }.map(\.text)
            #expect(errors.isEmpty)
            let made = try #require(model.task(target))
            let folder = try #require(made.folder)
            #expect(!made.branch.isEmpty)
            let prompt = try String(contentsOfFile: (folder as NSString).appendingPathComponent("prompt.txt"), encoding: .utf8)
            #expect(prompt.contains("on branch \(made.branch)"))
            #expect(model.thread(target).filter { $0.role == .note }.map(\.text) == ["Task workspace ready"])
            prepared.append(made)
        }
        #expect(Set(prepared.map(\.branch)).count == 3)
        #expect(Set(prepared.compactMap(\.folder)).count == 3)
        #expect(prepared[2].branch.hasPrefix("feat/17-"))
        #expect(await Shell.run(["git", "branch", "--show-current"], in: checkout).output.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        #expect(model.thread(.home(bot.id)).allSatisfy { !$0.text.contains("feat/") && !$0.text.contains("PR #") })
        #expect(home.loadTasks().allSatisfy { !$0.branch.isEmpty && $0.folder != nil })
    }

    /// New Task asks for the project and what to do, nothing else: a screenshot pasted into its box
    /// goes with the task's first message, ⌘Return starts it where the project lives, on the bot's
    /// account, and the project is chosen first next time.
    @Test func newTaskTakesAProjectAndABriefWithImages() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-new-task-\(UUID().uuidString)")
        let suite = "BotChu.NewTask.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bot = Bot(name: "Builder", accountID: "codex-dev", workspace: root.appendingPathComponent("bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        // The project is checked out in the repositories folder, where a task works by default.
        let checkout = root.appendingPathComponent("repos/project").path
        #expect(await Shell.run(["git", "init", "-b", "main", checkout], in: root.path).ok)
        #expect(await Shell.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                                 "commit", "--allow-empty", "-m", "Initial"], in: checkout).ok)
        let cli = root.appendingPathComponent("fixture.py")
        try """
        import json, sys
        from pathlib import Path
        Path('argv.json').write_text(json.dumps(sys.argv))
        print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-session'}))
        print(json.dumps({'type': 'item.completed', 'item': {'id': 'answer', 'type': 'agent_message', 'text': 'Done.'}}))
        print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 1, 'output_tokens': 1}}))
        """.write(to: cli, atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: defaults)
        settings.reposRoot = root.appendingPathComponent("repos").path
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(cli.path))"
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let model = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") })
        defer { model.stopAll() }
        // Your repositories as gh would list them, read just now.
        model.repositories = [GitHubLookup.Repo(nameWithOwner: "fixture/project", description: "The fixture"),
                              GitHubLookup.Repo(nameWithOwner: "fixture/other")]
        model.repositoriesReadAt = Date()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NewTaskSheet(botID: bot.id, initialRepo: "fixture/project")
            .environment(model).defaultAppStorage(defaults))
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let editor = try #require(window.firstResponder as? ComposerTextView)
        editor.insertText("Fix the flaky login test", replacementRange: NSRange(location: NSNotFound, length: 0))
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore() }
        let picture = NSImage(size: NSSize(width: 24, height: 16))
        picture.lockFocus(); NSColor.systemPurple.setFill(); NSRect(x: 0, y: 0, width: 24, height: 16).fill(); picture.unlockFocus()
        pasteboard.board.clearContents()
        pasteboard.board.setData(try #require(picture.tiffRepresentation), forType: .tiff)
        #expect(editor.validateMenuItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")))
        editor.paste(nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(editor.string == "Fix the flaky login test")
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("new-task"))
        }

        let start = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        if !window.performKeyEquivalent(with: start) { window.sendEvent(start) }
        let task = try #require(model.tasks[bot.id]?.first)
        let target = ChatTarget.task(task.id, of: bot.id)
        for _ in 0..<250 {
            if !model.isRunning(target) && model.thread(target).contains(where: { $0.role == .assistant }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.thread(target).filter { $0.role == .error }.isEmpty)
        #expect(task.repo == "fixture/project" && task.checkout == checkout && task.hostID == nil)
        #expect(task.brief == "Fix the flaky login test" && task.work == nil && task.review == nil)
        #expect(task.accountID == bot.accountID)
        let first = try #require(model.thread(target).first { $0.role == .user })
        #expect(first.text == "Fix the flaky login test")
        let image = try #require(first.images.first)
        #expect(first.images.count == 1)
        #expect(NSImage(contentsOf: home.imageURL(image)) != nil)
        // The CLI was handed the image with the first message.
        let folder = try #require(model.task(target)?.folder)
        let argv = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("argv.json")))
        #expect(argv.contains("--image"))
        #expect(argv.contains(home.imageURL(image).path))
        #expect(defaults.string(forKey: "newTaskRepo") == "fixture/project")
        // Working where it lives by default isn't a choice to remember.
        #expect(settings.repoLocations.isEmpty)

        // Opened for a pull request from Projects, it says what the task does with it, which needs no brief.
        let pull = BotTask.Work(number: 7, title: "Speed up the sync", url: URL(string: "https://github.com/fixture/project/pull/7")!, isPullRequest: true)
        window.contentView = NSHostingView(rootView: NewTaskSheet(botID: bot.id, initialRepo: "fixture/project", initialWork: pull, initialPurpose: .comment)
            .environment(model).defaultAppStorage(defaults))
        try await Task.sleep(for: .milliseconds(300))
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("new-task-review"))
        }
    }
}
