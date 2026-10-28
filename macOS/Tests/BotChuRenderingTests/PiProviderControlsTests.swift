import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func piProviderSelectionFiltersModelsAndStartsOnlyThatConversationsNewSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-controls-\(UUID().uuidString)")
        let domain = "BotChu.PiControls.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        var bot = Bot(name: "Pi", accountID: "openrouter", model: "vendor/old", reasoningEffort: .high,
                      workspace: root.appendingPathComponent("bot").path, sessionID: "old-session", sessionAccountID: "openrouter")
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        var task = BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "Test")
        task.sessionID = "task-session"
        try home.save(task)
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        var keyReads = 0
        let settings = AppSettings(defaults: defaults)
        let app = AppModel(store: store, settings: settings, openRouterKey: { keyReads += 1; return nil })
        let scope = try #require(app.modelCatalogScope(for: bot))
        app.modelCatalog.listModels = { _ in [
            ModelOption(id: "vendor/old", name: "Old model", efforts: [.high], provider: "openrouter"),
            ModelOption(id: "kimi-k3", name: "Kimi K3", efforts: [.low, .high, .max], provider: "moonshotai")
        ] }
        await app.modelCatalog.refresh(scope)
        let target = ChatTarget.home(bot.id)
        app.setProvider("moonshotai", for: target)
        bot = try #require(app.bot(bot.id))
        #expect(bot.resolvedProvider == "moonshotai")
        #expect(bot.model.isEmpty && bot.reasoningEffort == nil && bot.resumableSessionID == nil)
        #expect(app.nativeModels(for: bot)?.map(\.id) == ["kimi-k3"])
        #expect(app.thread(target).contains { $0.role == .note && $0.text.contains("New session") })
        #expect(app.runSettings(of: .task(task.id, of: bot.id))?.resumableSessionID == "task-session")
        app.setModel("kimi-k3", for: target)
        app.setReasoningEffort(.max, for: target)
        #expect(app.bot(bot.id)?.reasoningEffort == .max)
        app.setReasoningEffort(.medium, for: target)
        #expect(app.bot(bot.id)?.reasoningEffort == .max)
        app.storage.wait(timeout: 5)
        #expect(home.loadBot()?.provider == "moonshotai")
        #expect(keyReads == 0)
        let backendRequest = app.usageRequest(for: bot)
        #expect(!backendRequest.usesLegacyOpenRouterKey)
        task.hostID = UUID()
        let remoteRequest = app.usageRequest(for: task)
        #expect(remoteRequest.remote == true && remoteRequest.command.isEmpty)
        #expect(!remoteRequest.usesLegacyOpenRouterKey)
        await app.usageBoard.refresh(remoteRequest, usage: app.usage, openRouterKey: app.openRouterKey)
        #expect(keyReads == 0)

        // Bot model/effort edits apply to the next turn; provider changes wait for this one.
        app.runStates[target] = RunState()
        app.setProvider("openrouter", for: target)
        #expect(app.bot(bot.id)?.resolvedProvider == "moonshotai")
        app.setModel("kimi-k3", ofBot: bot.id)
        app.setReasoningEffort(.high, ofBot: bot.id)
        #expect(app.bot(bot.id)?.reasoningEffort == .high)
        app.runStates[target] = nil

        // The same provider control is used in composer, inspector, editor and job form.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ModelMenu(settings: bot, disabled: false,
            onModel: { _ in }, onEffort: { _ in }, onProvider: { app.setProvider($0, for: target) }, inForm: true).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.contentView?.fittingSize.height ?? 0 > 0)
    }
}
