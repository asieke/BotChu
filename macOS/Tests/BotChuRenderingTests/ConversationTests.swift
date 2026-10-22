import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func composerSendsWithReturnWhileRunningAndKeepsTaskQueuesSeparate() async throws {
        _ = NSApplication.shared
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.runStates[target] = RunState(hasOutput: true, activity: .coding)
        app.show(target)
        let defaults = UserDefaults(suiteName: fixture.domain)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Also update the documentation", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["Also update the documentation"])
        #expect((app.drafts[target] ?? "").isEmpty)
        #expect(app.isRunning(target))
        #expect(app.thread(target).isEmpty)

        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("working"))
        }
        app.show(.home(fixture.bot.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(app.messageQueues[.home(fixture.bot.id)]?.messages.isEmpty == true)
        #expect(app.status(of: .home(fixture.bot.id))?.phase == .idle)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("idle"))
        }
        app.show(target)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 820, height: 600))
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.frame.width >= window.contentMinSize.width)
        #expect(app.messageQueues[target]?.messages.count == 1)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("dark-compact"))
        }
    }

    @Test func composerGrowsWithShiftReturnAndPastesQueuedImages() async throws {
        _ = NSApplication.shared
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.runStates[target] = RunState(hasOutput: true)
        app.show(target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        window.contentView = NSHostingView(rootView: ChatView(target: target).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let editor = try #require(window.firstResponder as? ComposerTextView)
        let scroll = try #require(editor.enclosingScrollView)
        let initialHeight = scroll.frame.height
        editor.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<6 {
            let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(enter)
        }
        editor.insertText("last", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(app.drafts[target] == "first" + String(repeating: "\n", count: 6) + "last")
        #expect(app.messageQueues[target]?.messages.isEmpty != false)
        #expect(scroll.frame.height > initialHeight)
        editor.insertText(String(repeating: "\nmore", count: 30), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(scroll.frame.height <= 200)
        #expect(scroll.hasVerticalScroller)
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 40, height: 20).fill(); image.unlockFocus()
        let bytes = try #require(image.tiffRepresentation)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(bytes, forType: .tiff)
        #expect(editor.onPasteImages(board))
        let attachment = try #require(app.draftImages[target]?.first)
        #expect(app.draftImages[.home(fixture.bot.id)] == nil)
        let copy = try Data(contentsOf: fixture.home.imageURL(attachment))
        #expect(NSImage(data: copy) != nil)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            try await Task.sleep(for: .milliseconds(100))
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("composer-images"))
        }
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.messageQueues[target]?.messages.first?.images == [attachment])
        #expect(app.draftImages[target] == nil)
        #expect((app.drafts[target] ?? "").isEmpty)
        #expect(scroll.frame.height == initialHeight)
        let recovered = AppModel(store: fixture.store, settings: fixture.settings)
        let queued = try #require(recovered.messageQueues[target]?.messages.first)
        recovered.editQueuedMessage(queued.id, in: target)
        #expect(recovered.draftImages[target] == [attachment])
        #expect(recovered.drafts[target]?.hasPrefix("first\n") == true)
    }

    @Test func stoppingBeforeImageDeliveryDoesNotLaunchTheCLI() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let image = try fixture.home.saveImage(Data([1, 2, 3]), name: "fixture.png")
        #expect(fixture.app.send("Inspect", to: fixture.taskTarget, images: [image]))
        fixture.app.stop(fixture.taskTarget)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!fixture.app.isRunning(fixture.taskTarget))
        #expect(!FileManager.default.fileExists(atPath: fixture.folder(fixture.taskTarget).appendingPathComponent("calls.jsonl").path))
    }

    @Test func imageOnlyMessagesReachTheCLIAndPreserveTheirTranscript() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 10, height: 10).fill(); image.unlockFocus()
        try fixture.app.addImage(try #require(image.tiffRepresentation), name: "screen.png", to: fixture.taskTarget)
        let images = try #require(fixture.app.draftImages[fixture.taskTarget])
        #expect(fixture.app.send("", to: fixture.taskTarget, images: images))
        try await fixture.wait { !fixture.app.isRunning(fixture.taskTarget) }
        let call = try #require(fixture.calls(fixture.taskTarget).first)
        #expect(call.contains("--image"))
        #expect(call.contains(fixture.home.imageURL(images[0]).path))
        #expect(fixture.home.loadThread(task: fixture.taskTarget.taskID!).first { $0.role == .user }?.images == images)
        #expect(fixture.app.messageQueues[fixture.taskTarget]?.messages.isEmpty == true)
    }

    @Test func followUpsDrainInOrderOnTheirOwnTaskAndResumeItsSession() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        #expect(app.send("WAIT", to: target))
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        #expect(app.send("second", to: target))
        #expect(app.send("third", to: target))
        #expect(app.thread(target).filter { $0.role == .user }.map(\.text) == ["WAIT"])
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["second", "third"])
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).count == 2)
        app.show(.home(fixture.bot.id))
        #expect(app.status(of: .home(fixture.bot.id))?.phase == .idle)
        #expect(app.status(of: fixture.otherTaskTarget)?.phase == .idle)
        #expect(app.status(of: target)?.phase == .working)
        #expect(app.status(of: fixture.bot).phase == .working)
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) && app.messageQueues[target]?.messages.isEmpty == true }
        #expect(app.thread(target).filter { $0.role == .user }.map(\.text) == ["WAIT", "second", "third"])
        #expect(app.thread(target).filter { $0.role == .assistant }.map(\.text) == ["reply:WAIT", "reply:second", "reply:third"])
        #expect(app.thread(.home(fixture.bot.id)).allSatisfy { $0.role.isNote })
        #expect(app.runSettings(of: target)?.resumableSessionID == "fixture-session")
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
        let calls = try fixture.calls(target)
        #expect(calls.count == 3)
        #expect(calls.dropFirst().allSatisfy { $0.prefix(3) == ["exec", "resume", "fixture-session"] })
        #expect(!app.thread(target).contains { $0.role == .error })
    }

    @Test func stopKeepsMessagesAndRelaunchRecoversThemPaused() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("keep this", to: target)
        app.stop(target)
        try await fixture.wait { !app.isRunning(target) }
        #expect(try fixture.calls(target).count == 1)
        #expect(app.messageQueues[target]?.isPaused == true)
        let recovered = AppModel(store: fixture.store, settings: fixture.settings)
        #expect(recovered.messageQueues[target]?.messages.map(\.text) == ["keep this"])
        #expect(recovered.messageQueues[target]?.isPaused == true)
        #expect(!recovered.isRunning(target))
        recovered.drafts[target] = "a draft already here"
        let id = try #require(recovered.messageQueues[target]?.messages.first?.id)
        recovered.editQueuedMessage(id, in: target)
        #expect(recovered.drafts[target] == "keep this\n\na draft already here")
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
    }

    @Test func failedTurnPausesQueueAndExplicitResumeSendsIt() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT FAIL", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("try again", to: target)
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.messageQueues[target]?.isPaused == true)
        #expect(app.messageQueues[target]?.messages.count == 1)
        app.resumeQueuedMessages(to: target)
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.thread(target).last?.text == "reply:try again")
    }

    @Test func simultaneousConversationsKeepTheirOwnQueueAndStopState() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.bot.id), task = fixture.taskTarget
        app.send("WAIT", to: home)
        app.send("WAIT", to: task)
        try await fixture.wait {
            app.runSettings(of: home)?.resumableSessionID != nil && app.runSettings(of: task)?.resumableSessionID != nil
        }
        app.send("home follow-up", to: home)
        app.send("task follow-up", to: task)
        app.stop(home)
        try fixture.release(task)
        try await fixture.wait { !app.isRunning(home) && !app.isRunning(task) }
        #expect(app.messageQueues[home]?.messages.map(\.text) == ["home follow-up"])
        #expect(app.messageQueues[home]?.isPaused == true)
        #expect(app.messageQueues[task]?.messages.isEmpty == true)
        #expect(app.thread(task).last?.text == "reply:task follow-up")
        #expect(!app.thread(home).contains { $0.role == .user && $0.text == "task follow-up" })
        #expect(try fixture.calls(home).count == 1)
        #expect(try fixture.calls(task).count == 2)
    }

    @Test func failedQueueWriteDoesNotAcceptOrLoseTheDraft() throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        let file = fixture.home.taskURL(target.taskID!).appendingPathComponent("queued.jsonl")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        app.runStates[target] = RunState()
        app.drafts[target] = "Keep my draft"
        #expect(!app.send("Keep my draft", to: target))
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.drafts[target] == "Keep my draft")
        #expect(app.thread(target).last?.role == .error)
        app.runStates.removeAll()
    }

    @Test func queuedMessagesDuringPreparationCanBeStoppedWithoutStarting() throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.runStates[target] = RunState(preparing: true)
        app.send("after setup", to: target)
        app.resumeQueuedMessages(to: target)
        #expect(app.runStates[target]?.preparing == true)
        app.stop(target)
        #expect(!app.isRunning(target))
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["after setup"])
        #expect(app.messageQueues[target]?.isPaused == true)
        #expect(app.thread(target).allSatisfy { $0.role.isNote })
    }

    @Test func profileActivityAndReactionsAreScopedToTheirConversation() throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.bot.id), target = fixture.taskTarget
        app.reactions.removeAll()
        app.runStates[target] = RunState(hasOutput: true, activity: .coding)
        for selected in [home, fixture.otherTaskTarget, target, home] {
            app.show(selected)
            #expect(app.tab(of: fixture.bot.id) == selected)
            #expect(app.status(of: selected)?.phase == (selected == target ? .working : .idle))
            #expect(app.status(of: selected)?.activity == (selected == target ? .coding : .idle))
        }
        app.runStates[target] = nil
        app.react(.done, for: target, seconds: 3)
        #expect(app.status(of: target)?.activity == .done)
        #expect(app.status(of: home)?.activity == .idle)
        app.runStates[home] = RunState(hasOutput: true)
        #expect(app.status(of: target)?.phase == .idle)
        #expect(app.status(of: fixture.otherTaskTarget)?.phase == .idle)
        app.runStates.removeAll()
    }
}

/// A real child process with deterministic streaming and interruption, on isolated bot data.
/// The lock directory makes overlapping CLI processes fail, and the SIGINT tail checks draining.
@MainActor private final class ConversationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-conversation-\(UUID().uuidString)")
    let domain = "local.BotChu.ConversationTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let bot: Bot
    let home: BotHome
    let app: AppModel
    let taskTarget: ChatTarget
    let otherTaskTarget: ChatTarget

    init() throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        bot = Bot(name: "Fixture", accountID: "codex-dev", workspace: root.appendingPathComponent("bot").path)
        home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(script.path))"
        var task = BotTask(for: bot, repo: "fixture/repo", checkout: root.path, work: nil, brief: "Test")
        task.folder = root.appendingPathComponent("task").path
        try FileManager.default.createDirectory(atPath: task.folder!, withIntermediateDirectories: true)
        try home.save(task)
        taskTarget = .task(task.id, of: bot.id)
        let other = BotTask(for: bot, repo: "fixture/other", checkout: root.path, work: nil, brief: "Other")
        try home.save(other)
        otherTaskTarget = .task(other.id, of: bot.id)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
    }

    func folder(_ target: ChatTarget) -> URL {
        URL(fileURLWithPath: app.task(target)?.folder ?? bot.workspace)
    }
    func release(_ target: ChatTarget) throws {
        try Data().write(to: folder(target).appendingPathComponent("release"))
    }
    func calls(_ target: ChatTarget) throws -> [[String]] {
        let text = try String(contentsOf: folder(target).appendingPathComponent("calls.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for the fixture process")
        throw CocoaError(.executableLoad)
    }
    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, os, signal, sys, time
    from pathlib import Path
    def emit(value):
        print(json.dumps(value), flush=True)
    def reply(text):
        emit({"type":"item.completed", "item":{"type":"agent_message", "text":text}})
    try:
        os.mkdir("active")
    except FileExistsError:
        emit({"type":"turn.failed", "error":{"message":"Overlapping processes"}})
        sys.exit(1)
    def interrupt(signum, frame):
        time.sleep(0.05)
        reply("interrupted tail")
        os.rmdir("active")
        sys.exit(130)
    signal.signal(signal.SIGINT, interrupt)
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    prompt = sys.argv[-1]
    if "WAIT" in prompt:
        while not Path("release").exists():
            time.sleep(0.02)
    if "FAIL" in prompt:
        emit({"type":"turn.failed", "error":{"message":"Fixture failure"}})
    else:
        # Fresh sessions contain a preamble; the actual request is its final line.
        reply("reply:" + prompt.splitlines()[-1])
        emit({"type":"turn.completed"})
    os.rmdir("active")
    """#
}
