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

    /// #43: quitting BotChu (every deploy restarts it) is not the owner's Stop. Messages left
    /// queued go out on their own after the next launch.
    @Test func relaunchSendsMessagesLeftQueuedWhenBotChuQuit() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("after relaunch", to: target)
        app.stopAll()
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.messageQueues[target]?.isPaused == false)
        #expect(!fixture.home.loadQueuePaused(task: target.taskID))
        #expect(try fixture.calls(target).count == 1)
        let relaunched = AppModel(store: fixture.store, settings: fixture.settings)
        defer { relaunched.stopAll() }
        #expect(relaunched.messageQueues[target]?.isPaused == false)
        try await fixture.wait { relaunched.thread(target).last?.text == "reply:after relaunch" }
        #expect(relaunched.messageQueues[target]?.messages.isEmpty == true)
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
        #expect(try fixture.calls(target).count == 2)
    }

    /// #43: a turn that recovers from an error (Codex's reconnects) and finishes, then exits
    /// nonzero, used to pause the queue as if it had failed.
    @Test func turnThatRecoversFromAnErrorStillSendsTheNextMessage() async throws {
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.send("WAIT FLAKY EXIT3", to: target)
        try await fixture.wait { app.runSettings(of: target)?.resumableSessionID != nil }
        app.send("next", to: target)
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) && app.thread(target).last?.text == "reply:next" }
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.messageQueues[target]?.isPaused == false)
        #expect(try fixture.calls(target).count == 2)
    }

    /// Claude Code takes a follow-up mid-turn, at its next tool call, in the same process; the
    /// message joins the transcript where the CLI took it, and leaves the queue only then.
    @Test func claudeTakesAFollowUpAtItsNextToolCall() async throws {
        let fixture = try ConversationFixture(accountID: "claude-dev", script: ConversationFixture.claudeScript)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        #expect(app.takesFollowUpsMidTurn(target))
        app.send("WAIT", to: target)
        try await fixture.wait { app.runStates[target]?.takesInput == true }
        app.send("steer me", to: target)
        let id = try #require(app.messageQueues[target]?.messages.first?.id)
        #expect(app.messageQueues[target]?.isInFlight(id) == true)
        // Already written to the CLI: it can't be taken back into the composer.
        app.editQueuedMessage(id, in: target)
        #expect(app.messageQueues[target]?.messages.count == 1)
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).map(\.id) == [id])
        try fixture.release(target)
        try await fixture.wait { !app.isRunning(target) }
        let thread = app.thread(target).filter { !$0.role.isNote }
        #expect(thread.map(\.role) == [.user, .tool, .user, .assistant])
        #expect(thread.filter { $0.role == .user }.map(\.text) == ["WAIT", "steer me"])
        #expect(thread.last?.text == "steered:steer me")
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(fixture.home.loadQueuedMessages(task: target.taskID).isEmpty)
        let calls = try fixture.calls(target)
        #expect(calls.count == 1)
        #expect(calls.first?.contains("--replay-user-messages") == true)
        #expect(!app.thread(target).contains { $0.role == .error })
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

    init(accountID: String = "codex-dev", script source: String = ConversationFixture.script) throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        bot = Bot(name: "Fixture", accountID: accountID, workspace: root.appendingPathComponent("bot").path)
        home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let script = root.appendingPathComponent("cli.py")
        try source.write(to: script, atomically: true, encoding: .utf8)
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
    if "FLAKY" in prompt:
        # Codex reports problems it recovers from, such as a dropped stream, as errors.
        emit({"type":"error", "message":"Reconnecting... 1/5"})
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
    if "EXIT3" in prompt:
        sys.exit(3)
    """#

    /// Claude Code with `--input-format stream-json --replay-user-messages`: messages on stdin,
    /// each echoed when taken; one written during a tool call is taken after its result; the CLI
    /// ends when stdin closes.
    static let claudeScript = #"""
    import json, os, select, sys, time
    from pathlib import Path
    def emit(value):
        print(json.dumps(value), flush=True)
    buffer = b""
    def read_line(timeout=None):
        global buffer
        while b"\n" not in buffer:
            ready, _, _ = select.select([0], [], [], timeout)
            if not ready:
                return None
            chunk = os.read(0, 65536)
            if not chunk:
                return ""
            buffer += chunk
        line, buffer = buffer.split(b"\n", 1)
        return line.decode()
    def text(line):
        return json.loads(line)["message"]["content"][0]["text"]
    def replay(line):
        value = json.loads(line)
        value.update({"session_id": "claude-fixture", "parent_tool_use_id": None, "isReplay": True})
        emit(value)
    def say(words):
        emit({"type":"assistant", "message":{"id":"m" + str(time.time()), "role":"assistant",
              "content":[{"type":"text", "text":words}]}, "parent_tool_use_id":None})
    def result():
        emit({"type":"result", "subtype":"success", "is_error":False, "result":"ok"})
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    emit({"type":"system", "subtype":"init", "session_id":"claude-fixture"})
    first = read_line()
    replay(first)
    prompt = text(first).splitlines()[-1]
    if "WAIT" in prompt:
        emit({"type":"assistant", "message":{"id":"m1", "role":"assistant", "content":[{"type":"tool_use",
              "id":"toolu_1", "name":"Bash", "input":{"command":"sleep 1"}}]}, "parent_tool_use_id":None})
        pending = []
        while not Path("release").exists():
            line = read_line(0.02)
            if line:
                pending.append(line)
        emit({"type":"user", "message":{"role":"user", "content":[{"tool_use_id":"toolu_1", "type":"tool_result",
              "content":"done", "is_error":False}]}, "parent_tool_use_id":None})
        for line in pending:
            replay(line)
            say("steered:" + text(line))
    else:
        say("reply:" + prompt)
    result()
    while True:
        line = read_line()
        if not line:
            break
        replay(line)
        say("reply:" + text(line))
        result()
    """#
}
