import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func sailWindowIsSavedPerConversationAndKeysStayWithTheirProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sail-controls-\(UUID().uuidString)")
        let domain = "BotChu.SailControls.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let bot = Bot(name: "Sail", accountID: "sail", workspace: root.appendingPathComponent("bot").path,
                      sessionID: "session", sessionAccountID: "sail")
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let task = BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "Check")
        try home.save(task)
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        var routerReads = 0
        var sailReads = 0
        let settings = AppSettings(defaults: defaults)
        let app = AppModel(store: store, settings: settings, openRouterKey: { routerReads += 1; return "router-dummy" })
        app.sailKey = { sailReads += 1; return "sail-dummy" }
        let target = ChatTarget.home(bot.id)
        app.setSailCompletionWindow(.balanced, for: target)
        #expect(app.bot(bot.id)?.effectiveSailCompletionWindow == .balanced)
        #expect(app.bot(bot.id)?.resumableSessionID == "session")
        #expect(app.runSettings(of: .task(task.id, of: bot.id))?.effectiveSailCompletionWindow == .flex)
        app.runStates[target] = RunState()
        app.setSailCompletionWindow(.asap, for: target)
        #expect(app.bot(bot.id)?.effectiveSailCompletionWindow == .balanced)
        app.runStates[target] = nil
        app.storage.wait(timeout: 5)
        #expect(home.loadBot()?.sailCompletionWindow == .balanced)
        let before = app.usageRequest(for: bot)
        #expect(app.usageKeys(before).sail == "sail-dummy")
        #expect(routerReads == 0 && sailReads == 1)
        var remote = before
        remote.remote = true
        #expect(app.usageKeys(remote) == UsageKeys())
        #expect(routerReads == 0 && sailReads == 1)
        settings.sailUsageCredentialRevision += 1
        #expect(app.usageRequest(for: bot) != before)
        #expect(AppSettings(defaults: defaults).sailUsageCredentialRevision == settings.sailUsageCredentialRevision)

        let current = try #require(app.bot(bot.id))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ModelMenu(settings: current, disabled: false,
            onModel: { _ in }, onEffort: { _ in }, onSailCompletionWindow: { app.setSailCompletionWindow($0, for: target) },
            inForm: true).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.contentView?.fittingSize.height ?? 0 > 0)
    }
}
