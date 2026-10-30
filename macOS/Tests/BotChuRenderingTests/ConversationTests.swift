import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// The message box observes its draft apart from the transcript (#340): typing, attaching and an
    /// attachment's error redraw the composer, never the transcript above it. The draft starts with
    /// an image and an error, so what changes after doesn't change the composer's height, which
    /// would resize the transcript's visible part and lay it out again.
    @Test func draftChangesRedrawTheComposerButNotTheTranscript() async throws {
        _ = NSApplication.shared
        let fixture = try ConversationFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.taskTarget
        app.show(target)
        try await fixture.wait { app.conversation(target).isLoaded }
        let image = try fixture.home.saveImage(Data([1, 2, 3]), name: "draft.png")
        let second = try fixture.home.saveImage(Data([4, 5, 6]), name: "second.png")
        app.draftImages[target] = [image]
        app.attachmentErrors[target] = "Attach up to 8 images per message."
        let transcript = TranscriptCache.model(for: target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(target: target).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let editor = try #require(window.firstResponder as? ComposerTextView)
        let editorY = editor.convert(editor.bounds, to: nil).minY
        let drawn = transcript.evaluations
        #expect(drawn > 0)
        app.drafts[target] = "Typed"
        app.draftReferences[target] = []
        app.draftImages[target] = [image, second]
        app.attachmentErrors[target] = "Attach up to 8 files per message."
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        app.draftImages[target] = [image]
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(editor.string == "Typed")
        #expect(editor.convert(editor.bounds, to: nil).minY == editorY)
        #expect(transcript.evaluations == drawn, "The draft redrew the transcript")
        app.append(ChatMessage(role: .assistant, text: "Done"), to: target)
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(transcript.evaluations > drawn, "A message redraws the transcript")
    }

    /// #46: a reply streaming into a task doesn't invalidate anything a view of another
    /// conversation reads, nor the task's own status (its sidebar row) while only its text grows.
    @Test func streamingIntoATaskLeavesOtherConversationsAndItsStatusAlone() async throws {
        let fixture = try ConversationFixture(accountID: "claude-dev", script: ConversationFixture.streamScript)
        defer { fixture.cleanUp() }
        let app = fixture.app, shown = ChatTarget.home(fixture.bot.id), streaming = fixture.taskTarget
        app.show(shown)
        #expect(app.send("STREAM", to: streaming))
        try await fixture.wait { app.thread(streaming).last?.text.hasPrefix("first") == true }
        let shownChanged = Flag(), otherTaskChanged = Flag(), statusChanged = Flag(), threadChanged = Flag()
        withObservationTracking {
            _ = app.thread(shown)
            _ = app.runStates[shown]?.preparing
            _ = app.isRunning(shown)
            _ = app.messageQueues[shown]
            _ = app.reactions[shown]
            _ = app.status(of: shown)
        } onChange: { shownChanged.set() }
        withObservationTracking {
            _ = app.thread(fixture.otherTaskTarget)
            _ = app.status(of: fixture.otherTaskTarget)
        } onChange: { otherTaskChanged.set() }
        withObservationTracking { _ = app.status(of: streaming) } onChange: { statusChanged.set() }
        withObservationTracking { _ = app.thread(streaming) } onChange: { threadChanged.set() }
        try fixture.release(streaming)
        try await fixture.wait { app.thread(streaming).last?.text.contains("token199") == true }
        #expect(threadChanged.value)
        #expect(!shownChanged.value)
        #expect(!otherTaskChanged.value)
        #expect(!statusChanged.value)
        try Data().write(to: fixture.folder(streaming).appendingPathComponent("finish"))
        try await fixture.wait { !app.isRunning(streaming) }
        #expect(app.thread(streaming).filter { $0.role == .assistant }.map(\.text).first?.hasSuffix("token199") == true)
    }
}

/// Whether an observation fired.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
    func set() {
        lock.lock()
        fired = true
        lock.unlock()
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
    /// The lines of a file the fixture CLI wrote in the conversation's folder; none before it has.
    func lines(_ name: String, _ target: ChatTarget) throws -> [String] {
        let url = folder(target).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
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

    /// Claude Code streaming a reply: its first word, then, once released, 200 more in bursts; it
    /// ends once told to finish.
    static let streamScript = #"""
    import json, sys, time
    from pathlib import Path
    def emit(value):
        print(json.dumps(value), flush=True)
    def event(value):
        emit({"type":"stream_event", "event":value, "parent_tool_use_id":None})
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    emit({"type":"system", "subtype":"init", "session_id":"claude-stream"})
    first = json.loads(sys.stdin.readline())
    first.update({"session_id": "claude-stream", "parent_tool_use_id": None, "isReplay": True})
    emit(first)
    event({"type":"message_start", "message":{"id":"m1"}})
    event({"type":"content_block_start", "index":0, "content_block":{"type":"text"}})
    event({"type":"content_block_delta", "index":0, "delta":{"type":"text_delta", "text":"first "}})
    while not Path("release").exists():
        time.sleep(0.02)
    for i in range(200):
        event({"type":"content_block_delta", "index":0, "delta":{"type":"text_delta", "text":"token%d " % i}})
        if i % 10 == 9:
            time.sleep(0.01)
    while not Path("finish").exists():
        time.sleep(0.02)
    event({"type":"content_block_stop", "index":0})
    emit({"type":"result", "subtype":"success", "is_error":False, "result":"ok"})
    """#
}
