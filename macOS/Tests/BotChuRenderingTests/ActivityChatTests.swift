import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
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
