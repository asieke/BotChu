import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// The redesigned chat on a long agent run (`DemoActivity`): it lays out at every density, in
    /// light and dark, and at the window's narrowest. With `BOTCHU_TEST_SNAPSHOTS` set it writes
    /// each screen there for review.
    @Test func activityChatRendersGroupsCardsAndLiveWork() async throws {
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        DemoActivity.install(in: app, target: fixture.task)
        app.show(fixture.task)
        let defaults = UserDefaults(suiteName: fixture.domain)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 2400),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        let snapshots = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        for (appearance, density) in [(NSAppearance.Name.darkAqua, ChatDensity.detailed), (.aqua, .detailed), (.darkAqua, .compact), (.aqua, .raw)] {
            window.appearance = NSAppearance(named: appearance)
            defaults.set(density.rawValue, forKey: ChatDensity.storageKey)
            try await Task.sleep(for: .milliseconds(400))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(app.thread(fixture.task).count >= 50)
            if let snapshots {
                let name = "activity-\(density.rawValue)-\(appearance == .aqua ? "light" : "dark")"
                DevHooks.snapshot(into: snapshots.appendingPathComponent(name))
                // And the start of the run, above the window.
                if let scroll = Self.chatScrollView(in: window.contentView!) {
                    let bottom = scroll.contentView.bounds.minY
                    Self.dragScroller(scroll, to: 0)
                    try await Task.sleep(for: .milliseconds(200))
                    DevHooks.snapshot(into: snapshots.appendingPathComponent(name + "-top"))
                    Self.dragScroller(scroll, to: bottom)
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        // The narrowest window.
        defaults.set(ChatDensity.detailed.rawValue, forKey: ChatDensity.storageKey)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 820, height: 900))
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.frame.width >= window.contentMinSize.width)
        if let snapshots { DevHooks.snapshot(into: snapshots.appendingPathComponent("activity-compact-width")) }
    }

    /// A reader at the bottom follows new content; one who scrolled up keeps their place while it
    /// streams in, until they jump back.
    @Test func chatFollowsTheNewestContentOnlyForReadersAtTheBottom() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        var messages: [ChatMessage] = []
        for turn in 0..<30 {
            messages.append(ChatMessage(role: .user, text: "Question \(turn)"))
            messages.append(ChatMessage(role: .assistant, text: "Answer \(turn)\n\nA paragraph long enough to take a few lines in the chat, so the conversation is much taller than its window."))
        }
        let conversation = app.conversation(fixture.task)
        conversation.replace(messages)
        app.runStates[fixture.task] = RunState(hasOutput: true)
        app.show(fixture.task)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        window.contentView = NSHostingView(rootView: ChatView(target: fixture.task).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try #require(Self.chatScrollView(in: window.contentView!))
        func below() -> CGFloat {
            scroll.layoutSubtreeIfNeeded()
            return (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
        }
        #expect(below() < 40)
        // Following: a reply streaming in keeps the newest text in view.
        conversation.append(ChatMessage(role: .assistant, text: "Streaming"))
        for i in 0..<12 {
            conversation.stream { $0[$0.count - 1].text += "\n\nMore of the reply \(i), growing in place." }
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(below() < 40)
        // Reading earlier content: the place stays as the reply goes on.
        Self.dragScroller(scroll, to: 300)
        try await Task.sleep(for: .milliseconds(200))
        let held = scroll.contentView.bounds.minY
        for i in 0..<12 {
            conversation.stream { $0[$0.count - 1].text += "\n\nStill more \(i)." }
            try await Task.sleep(for: .milliseconds(40))
        }
        conversation.append(ChatMessage(role: .tool, toolID: "t", toolName: "Bash", toolInput: "swift build", toolState: .running))
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(scroll.contentView.bounds.minY - held) < 2)
        #expect(below() > 100)
    }

    /// A rich reply's web view is made after the first layout and then grows: a conversation that
    /// first fit in the window still opens at its newest content once it no longer does.
    @Test func chatOpensAtTheNewestMessageWhenARichReplyGrowsLater() async throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        let rows = (1...40).map { "| Worker \($0) | $p_{\($0)}$ | **\($0 * 1000)** |" }.joined(separator: "\n")
        app.conversation(fixture.task).replace([
            ChatMessage(role: .user, text: "Sum the primes, one worker per range."),
            ChatMessage(role: .assistant, text: "## Results\n\n| Worker | Prime | Sum |\n| --- | --- | ---: |\n" + rows
                + "\n\n$$\\sum_{i=1}^{40} s_i = 820{,}000$$\n\nThe last line of the reply."),
        ])
        app.show(.home(fixture.task.botID))
        let defaults = UserDefaults(suiteName: fixture.domain)!
        defaults.set(true, forKey: "showsStatus")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        app.show(fixture.task)
        // The web view loads, renders and reports its height, well beyond the window's.
        var below: CGFloat = .infinity
        var height: CGFloat = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            guard let scroll = Self.chatScrollView(in: window.contentView!, minimum: 0) else { continue }
            scroll.layoutSubtreeIfNeeded()
            height = scroll.documentView?.frame.height ?? 0
            below = height - scroll.contentView.bounds.maxY
        }
        #expect(height > 1_000)
        #expect(below < 40)
    }

    /// A closed task's transcript and a deleted bot's go, and the cache keeps only recent ones.
    /// A long conversation opened anew (#108) shows its newest items in the update that opens it,
    /// grouped from a bounded part of the thread, and groups its history off the main thread; then a
    /// reply streaming in is the only thing grouped again, and the cards' placement is left alone.
    @Test func aLongConversationOpensAtOnceAndGroupsItsHistoryOffTheMainThread() async throws {
        _ = NSApplication.shared
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        var messages: [ChatMessage] = []
        for turn in 0..<200 {
            messages.append(ChatMessage(role: .user, text: "Step \(turn)"))
            for call in 0..<9 {
                let path = "/work/repo/Sources/Folder\(call % 3)/File\(turn)-\(call).swift"
                messages.append(ChatMessage(role: .tool, toolID: "\(turn)-\(call)", toolName: "Read", toolInput: path,
                                            toolOutput: "let x = 1", toolState: .done))
            }
            messages.append(ChatMessage(role: .tool, toolID: "\(turn)-build", toolName: "Bash", toolInput: "swift build",
                                        toolOutput: "Build complete!", toolState: .done))
            messages.append(ChatMessage(role: .assistant, text: "Turn \(turn) done."))
        }
        let conversation = app.conversation(fixture.task)
        conversation.replace(messages)
        TranscriptCache.forget(fixture.task)
        app.show(fixture.task)
        let defaults = UserDefaults(suiteName: fixture.domain)!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 900),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close(); app.runStates.removeAll() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let model = TranscriptCache.model(for: fixture.task)
        // Opened: the newest part grouped here, the rest still being grouped.
        #expect(model.isLoadingEarlier)
        #expect(model.lastWork.processed <= TranscriptModel.recentMessages + TranscriptModel.coldLimit)
        for _ in 0..<500 where model.isLoadingEarlier { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isLoadingEarlier)
        window.contentView?.layoutSubtreeIfNeeded()
        let root = app.task(fixture.task)?.folder
        var whole = ActivityTranscript(root: root)
        whole.update(app.thread(fixture.task))
        let items = model.items(for: app.thread(fixture.task), root: root, epoch: conversation.epoch)
        #expect(items.map(\.id) == whole.items.map(\.id))
        // A reply streaming in.
        app.runStates[fixture.task] = RunState(hasOutput: true)
        conversation.append(ChatMessage(role: .assistant, text: "Streaming"))
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        let rebuilds = model.placementRebuilds
        for i in 0..<10 {
            conversation.stream { $0[$0.count - 1].text += " more \(i)" }
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(model.lastWork.processed <= 1)
        }
        #expect(model.placementRebuilds == rebuilds)
    }

    @Test func transcriptsOfClosedTasksAndDeletedBotsAreForgotten() throws {
        let fixture = try ActivityChatFixture()
        defer { fixture.cleanUp() }
        let home = ChatTarget.home(fixture.task.botID)
        _ = TranscriptCache.model(for: home)
        _ = TranscriptCache.model(for: fixture.task)
        #expect(TranscriptCache.contains(fixture.task))
        fixture.app.closeTask(fixture.task)
        #expect(!TranscriptCache.contains(fixture.task))
        #expect(TranscriptCache.contains(home))
        fixture.app.delete(fixture.task.botID)
        #expect(!TranscriptCache.contains(home))
        let oldest = ChatTarget.home(UUID())
        _ = TranscriptCache.model(for: oldest)
        for _ in 0..<TranscriptCache.capacity { _ = TranscriptCache.model(for: .home(UUID())) }
        #expect(!TranscriptCache.contains(oldest))
    }

    /// The chat's scroll view: the widest one holding more than `minimum` points of content.
    static func chatScrollView(in view: NSView, minimum: CGFloat = 1_000) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > minimum,
               scroll.frame.width > (best?.frame.width ?? 400) { best = scroll }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}

/// A bot with one task, on isolated data, for the chat's activity tests.
@MainActor final class ActivityChatFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-activity-\(UUID().uuidString)")
    let domain = "local.BotChu.ActivityTests.\(UUID().uuidString)"
    let app: AppModel
    let task: ChatTarget

    /// `script`: a stand-in CLI, in Python, that the bot's turns run (on Codex Dev).
    init(script: String? = nil) throws {
        let store = Store(root: root.appendingPathComponent("index"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        let bot = Bot(name: "Scout", emoji: "🔭", accountID: script == nil ? "claude-dev" : "codex-dev", workspace: root.appendingPathComponent("bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        if let script {
            let file = root.appendingPathComponent("cli.py")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(file.path))"
        }
        var task = BotTask(for: bot, repo: "octocat/hello-world", checkout: root.path, work: nil, brief: "Find why switching is slow")
        task.folder = root.appendingPathComponent("repo").path
        try home.save(task)
        self.task = .task(task.id, of: bot.id)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
    }

    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
