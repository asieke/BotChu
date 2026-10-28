import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// #107: conversations, settings, logs and memory are saved off the main thread, each in order.
/// Writes here are slowed down (250 ms each) or held by the test; sending, switching and Stop never
/// wait for them, a turn starts only once its message is saved, and quitting, deleting and moving a
/// bot wait for what is being written.
extension RenderingTests {
    @Test func aTurnStartsOnlyOnceItsMessageIsSavedAndStopNeverWaitsForStorage() async throws {
        let control = StorageControl(delay: 0.25)
        let fixture = try PersistenceFixture(control: control)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.task
        let started = Date()
        #expect(app.send("hello", to: target))
        #expect(Date().timeIntervalSince(started) < 0.2, "Sending doesn't wait for a save")
        #expect(app.isRunning(target), "Busy at once, so nothing else starts in it")
        #expect(app.messageQueues[target]?.pending.map(\.text) == ["hello"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.calls(target) == 0, "No CLI before the queue holding the message is saved")
        try await fixture.wait { fixture.calls(target) == 1 }
        // The CLI ran once the saved transcript held the message.
        #expect(fixture.home.loadThread(task: fixture.taskID).contains { $0.text == "hello" })
        try await fixture.wait { !app.isRunning(target) }
        #expect(app.thread(target).last?.text == "reply:hello")

        // Stop while the next message is being saved: it returns at once and nothing starts.
        let stopping = Date()
        app.send("second", to: target)
        app.stop(target)
        #expect(Date().timeIntervalSince(stopping) < 0.2, "Stop doesn't wait for storage")
        #expect(!app.isRunning(target))
        await app.storage.settle()
        #expect(fixture.calls(target) == 1)
        #expect(app.messageQueues[target]?.messages.map(\.text) == ["second"])
        #expect(app.messageQueues[target]?.isPaused == true)
        let relaunched = AppModel(store: fixture.store, settings: fixture.settings, storage: app.storage)
        defer { relaunched.stopAll() }
        // Each conversation's queue is recovered off the main thread after a launch (#109).
        await relaunched.storage.settle()
        #expect(relaunched.messageQueues[target]?.messages.map(\.text) == ["second"])
        #expect(relaunched.messageQueues[target]?.isPaused == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.calls(target) == 1)
        #expect(control.onMain.isEmpty)
    }

    @Test func aMessageWhoseTranscriptCantBeSavedStaysQueuedAndStartsNoCLI() async throws {
        let fixture = try PersistenceFixture(control: StorageControl())
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.task
        let transcript = fixture.home.taskThreadURL(fixture.taskID)
        try fixture.home.saveThread([], task: fixture.taskID)
        try fixture.lock(transcript, true)
        defer { try? fixture.lock(transcript, false) }
        #expect(app.send("hello", to: target))
        await app.storage.settle()
        #expect(fixture.calls(target) == 0)
        #expect(!app.isRunning(target))
        #expect(app.messageQueues[target]?.pending.map(\.text) == ["hello"])
        #expect(app.messageQueues[target]?.isPaused == true)
        #expect(app.thread(target).last?.text == "Couldn't save this message. It is still queued.")
        #expect(!app.thread(target).contains { $0.role == .user })
        #expect(fixture.home.loadQueuedMessages(task: fixture.taskID).map(\.text) == ["hello"])

        // Once it can be saved, Send next starts it, once, and a relaunch doesn't send it again.
        try fixture.lock(transcript, false)
        app.resumeQueuedMessages(to: target)
        try await fixture.wait { fixture.calls(target) == 1 && !app.isRunning(target) }
        #expect(app.thread(target).last?.text == "reply:hello")
        await app.storage.settle()
        let relaunched = AppModel(store: fixture.store, settings: fixture.settings, storage: app.storage)
        defer { relaunched.stopAll() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.calls(target) == 1)
        #expect(relaunched.messageQueues[target]?.messages.isEmpty == true)
    }

    /// The criterion's measure: four conversations saving at 250 ms a write while the owner types and
    /// switches. Asserts what doesn't depend on load (nothing on the main thread waits for storage);
    /// prints, and with `BOTCHU_PERSISTENCE_BENCHMARK` writes, the timings.
    @Test func typingAndSwitchingStayResponsiveWhileFourConversationsSave() async throws {
        _ = NSApplication.shared
        let control = StorageControl(delay: 0.25)
        let fixture = try PersistenceFixture(control: control)
        defer { fixture.cleanUp() }
        let app = fixture.app
        let saving = [fixture.homeTarget, fixture.task, fixture.other, fixture.third]
        // The shown conversation has a turn under way, so what is typed there queues.
        let shown = fixture.fourth
        app.runStates[shown] = RunState(hasOutput: true)
        defer { app.runStates.removeAll() }
        app.show(shown)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(fixture.defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        var asking: [Double] = [], acknowledged: [Double] = [], switching: [Double] = []
        func save() {
            for target in saving {
                let start = DispatchTime.now().uptimeNanoseconds
                app.note("Still working", in: target)
                asking.append(Self.ms(since: start))
            }
            app.setModel("gpt-\(Int.random(in: 1...9))", for: fixture.task)
        }
        let busyFrom = Date()
        for round in 0..<30 {
            save()
            let typed = DispatchTime.now().uptimeNanoseconds
            #expect(app.send("Follow-up \(round)", to: shown))
            #expect(app.messageQueues[shown]?.pending.last?.text == "Follow-up \(round)")
            acknowledged.append(Self.ms(since: typed))
            let switched = DispatchTime.now().uptimeNanoseconds
            app.show(round.isMultiple(of: 2) ? fixture.homeTarget : shown)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            switching.append(Self.ms(since: switched))
        }
        let stillSaving = !app.storage.isIdle()
        await app.storage.settle()
        let committed = Date().timeIntervalSince(busyFrom)
        // Nothing on the main thread waited for a write: every save asked for, message queued and
        // switch took less than one write, and storage's own work on the main thread stayed short.
        #expect(control.onMain.isEmpty)
        #expect(asking.max() ?? 0 < 50)
        #expect(acknowledged.max() ?? 0 < 50)
        #expect(app.storage.stats.longestReport < 0.05)
        #expect(stillSaving, "Writes were still going on while the owner typed and switched")
        #expect(app.messageQueues[shown]?.pending.count == 30)
        #expect(fixture.home.loadQueuedMessages(task: shown.taskID).count == 30)

        let report = """
            #107 responsiveness, 4 conversations saving at 250 ms a write, \(switching.count) samples (debug build unless run with -c release)
            ask to save (ms): \(Self.summary(asking))
            message queued (input acknowledged, ms): \(Self.summary(acknowledged))
            switch and draw (ms): \(Self.summary(switching))
            storage's longest main-thread result (ms): \(String(format: "%.3f", app.storage.stats.longestReport * 1000))
            storage busy for \(String(format: "%.2f", committed)) s; writes \(app.storage.stats.runs), coalesced \(app.storage.stats.coalesced), \
            unchanged \(app.storage.stats.unchanged), \(String(format: "%.2f", Double(app.storage.stats.bytesWritten) / 1_048_576)) MiB

            """
        print(report)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_PERSISTENCE_BENCHMARK"], path.hasPrefix("/") {
            try report.write(toFile: path + ".responsiveness", atomically: true, encoding: .utf8)
        }
    }

    @Test func aMessageThatCantBeQueuedComesBackToTheComposer() async throws {
        _ = NSApplication.shared
        let fixture = try PersistenceFixture(control: StorageControl(delay: 0.1))
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.task
        try FileManager.default.createDirectory(at: fixture.home.queueURL(task: fixture.taskID), withIntermediateDirectories: true)
        app.show(target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ChatView(target: target).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let editor = try #require(window.firstResponder as? ComposerTextView)
        editor.insertText("Keep this", replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        // Shown as queued at once; the queue's save fails, and it comes back to the draft.
        #expect((app.drafts[target] ?? "").isEmpty)
        #expect(app.messageQueues[target]?.pending.map(\.text) == ["Keep this"])
        await app.storage.settle()
        #expect(app.drafts[target] == "Keep this")
        #expect(app.messageQueues[target]?.messages.isEmpty == true)
        #expect(app.thread(target).last?.text.hasPrefix("Couldn't save pending messages (") == true)
        #expect(fixture.calls(target) == 0)
    }

    /// Quitting through the real notification waits for writes under way; one that outlasts its
    /// limit is listed as unsaved, its file left as it was, and never taken as saved.
    @Test func quittingWaitsForTheWritesUnderWayAndSaysWhichItCouldnt() async throws {
        let control = StorageControl(delay: 0.25)
        let fixture = try PersistenceFixture(control: control)
        defer { fixture.cleanUp() }
        let app = fixture.app
        // A queue left at quitting goes out after the next launch; one the owner paused stays paused.
        app.runStates[fixture.task] = RunState(hasOutput: true)
        app.runStates[fixture.other] = RunState(hasOutput: true)
        app.send("after relaunch", to: fixture.task)
        app.send("owner paused", to: fixture.other)
        app.stop(fixture.other)
        app.note("Last words before quitting", in: fixture.homeTarget)
        let started = Date()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        #expect(Date().timeIntervalSince(started) >= 0.2, "It waited for the writes")
        #expect(app.unsavedAtQuit.isEmpty)
        #expect(fixture.home.loadThread().last?.text == "Last words before quitting")
        #expect(fixture.home.loadQueuedMessages(task: fixture.taskID).map(\.text) == ["after relaunch"])
        #expect(!fixture.home.loadQueuePaused(task: fixture.taskID))
        #expect(fixture.home.loadQueuedMessages(task: fixture.other.taskID).map(\.text) == ["owner paused"])
        #expect(fixture.home.loadQueuePaused(task: fixture.other.taskID))

        // Writes slower than the limit: quitting stops waiting, says so, and the file keeps what was saved.
        let slow = StorageControl(delay: 0.8)
        let second = try PersistenceFixture(control: slow)
        defer { second.cleanUp() }
        try second.home.saveThread([ChatMessage(role: .note, text: "Saved before")])
        second.app.quitTimeout = 0.1
        second.app.note("Not saved in time", in: second.homeTarget)
        second.app.stopAll()
        #expect(second.app.unsavedAtQuit == [second.home.conversationLane()])
        #expect(second.home.loadThread().last?.text == "Saved before")
        await second.app.storage.settle()
    }

    /// Deleting a bot drops what waits to be saved in its folder and waits for what is being
    /// written, so nothing makes the folder again; moving one waits for its writes and takes them along.
    @Test func deletingOrMovingABotNeverMakesItsOldFolderAgain() async throws {
        let control = StorageControl(delay: 0.25)
        let fixture = try PersistenceFixture(control: control)
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.note("Before the move", in: fixture.homeTarget)
        app.note("Task note", in: fixture.task)
        app.setModel("gpt-moved", for: fixture.task)
        var moved = try #require(app.bot(fixture.bot.id))
        moved.workspace = fixture.root.appendingPathComponent("moved").path
        app.update(moved)
        #expect(app.bot(fixture.bot.id)?.workspace == moved.workspace)
        let movedHome = BotHome(workspace: moved.workspace)
        app.note("After the move", in: fixture.homeTarget)
        await app.storage.settle()
        #expect(!FileManager.default.fileExists(atPath: fixture.home.url.path), "Nothing made the old folder again")
        #expect(movedHome.loadThread().map(\.text).suffix(2) == ["Before the move", "After the move"])
        #expect(movedHome.loadThread(task: fixture.taskID).last?.text == "Task note")
        #expect(movedHome.loadTasks().first { $0.id == fixture.taskID }?.model == "gpt-moved")

        // Deleting: writes waiting are dropped, the one under way finishes first.
        app.note("Never saved", in: fixture.homeTarget)
        app.note("Never saved either", in: fixture.task)
        app.log("A log line", in: movedHome)
        app.delete(fixture.bot.id)
        #expect(!FileManager.default.fileExists(atPath: movedHome.url.path))
        await app.storage.settle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: movedHome.url.path), "Nothing made the deleted folder again")
        #expect(control.onMain.isEmpty)
    }

    static func ms(since start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    static func summary(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard let max = sorted.last else { return "–" }
        let median = sorted[sorted.count / 2]
        let p95 = sorted.count >= 30 ? String(format: "%.3f", sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]) : "–"
        return String(format: "median %.3f, p95 %@, max %.3f (n=%d)", median, p95, max, sorted.count)
    }
}

/// A `StorageQueue` whose writes the test slows down, recording whether any ran on the main thread.
final class StorageControl: @unchecked Sendable {
    /// What the queue's hook keeps, apart from the control, which the queue may outlive.
    private final class Record: @unchecked Sendable {
        let lock = NSLock()
        var onMain: [String] = []
    }

    private let record = Record()
    let delay: TimeInterval
    let storage: StorageQueue

    init(delay: TimeInterval = 0) {
        self.delay = delay
        let record = record
        storage = StorageQueue(before: { work in
            if Thread.isMainThread { record.lock.withLock { record.onMain.append("\(work.label) \(work.lane)") } }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        })
    }

    /// Storage work that ran on the main thread, if any.
    var onMain: [String] { record.lock.withLock { record.onMain } }
    var ranOnMain: Bool { !onMain.isEmpty }
}

/// A bot with its Home and four tasks, on isolated data, whose account runs a stand-in CLI that
/// records each call and replies at once.
@MainActor final class PersistenceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-persistence-\(UUID().uuidString)")
    let domain = "local.BotChu.PersistenceTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let defaults: UserDefaults
    let bot: Bot
    let home: BotHome
    let app: AppModel
    let tasks: [BotTask]

    var homeTarget: ChatTarget { .home(bot.id) }
    var task: ChatTarget { .task(tasks[0].id, of: bot.id) }
    var other: ChatTarget { .task(tasks[1].id, of: bot.id) }
    var third: ChatTarget { .task(tasks[2].id, of: bot.id) }
    var fourth: ChatTarget { .task(tasks[3].id, of: bot.id) }
    var taskID: UUID { tasks[0].id }

    init(control: StorageControl, script scriptText: String = PersistenceFixture.script) throws {
        store = Store(root: root.appendingPathComponent("index"))
        defaults = UserDefaults(suiteName: domain)!
        settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        bot = Bot(name: "Saver", accountID: "codex-dev", workspace: root.appendingPathComponent("bot").path)
        home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let script = root.appendingPathComponent("cli.py")
        try scriptText.write(to: script, atomically: true, encoding: .utf8)
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(script.path))"
        var made: [BotTask] = []
        for n in 0..<4 {
            var task = BotTask(for: bot, repo: "fixture/repo\(n)", checkout: root.path, work: nil, brief: "Task \(n)")
            task.folder = root.appendingPathComponent("task\(n)").path
            try FileManager.default.createDirectory(atPath: task.folder!, withIntermediateDirectories: true)
            try home.save(task)
            made.append(task)
        }
        tasks = made
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") },
                       storage: control.storage)
    }

    /// How many times the CLI ran in the conversation's folder.
    func calls(_ target: ChatTarget) -> Int {
        let folder = app.task(target)?.folder ?? bot.workspace
        let text = (try? String(contentsOfFile: (folder as NSString).appendingPathComponent("calls.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    func lock(_ url: URL, _ locked: Bool) throws {
        try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting")
        throw CocoaError(.executableLoad)
    }

    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, sys
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    print(json.dumps({"type":"thread.started", "thread_id":"fixture-session"}), flush=True)
    prompt = sys.argv[-1]
    print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"reply:" + prompt.splitlines()[-1]}}), flush=True)
    print(json.dumps({"type":"turn.completed"}), flush=True)
    """#
}
