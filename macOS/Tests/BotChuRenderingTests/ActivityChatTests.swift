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
                    let bottom = scroll.contentView.bounds.origin
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try await Task.sleep(for: .milliseconds(200))
                    DevHooks.snapshot(into: snapshots.appendingPathComponent(name + "-top"))
                    scroll.contentView.scroll(to: bottom)
                    scroll.reflectScrolledClipView(scroll.contentView)
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
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
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

    init() throws {
        let store = Store(root: root.appendingPathComponent("index"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        let bot = Bot(name: "Scout", emoji: "🔭", accountID: "claude-dev", workspace: root.appendingPathComponent("bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
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
