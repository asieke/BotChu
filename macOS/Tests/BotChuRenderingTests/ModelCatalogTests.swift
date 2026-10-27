import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// How many lists were asked for, by a stand-in that never starts a CLI.
private actor ListCalls {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

extension RenderingTests {
    /// A Codex profile's own list (#220), as the app keeps it and its pickers and Quick tasks use it.
    @Test func aCodexProfilesOwnListServesEveryPickerSetToIt() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-model-catalog-\(UUID().uuidString)")
        let domain = "BotChu.ModelCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        let store = Store(root: root.appendingPathComponent("index"))
        let settings = AppSettings(defaults: defaults)
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        let work = try #require(app.modelCatalogScope(for: settings.account("codex-work")))
        // Tests start no check by themselves, and nothing is read yet: the starters stand in.
        #expect(app.modelCatalog.listModels == nil)
        #expect(app.modelCatalog.models(for: work) == nil)
        #expect(app.modelCatalogScope(for: settings.account("claude-dev")) == nil)

        let calls = ListCalls()
        let listed = [ModelOption(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", efforts: [.low, .medium, .high]),
                      ModelOption(id: "gpt-6.1-terra", name: "GPT-6.1 Terra", efforts: [.low, .medium, .high, .xhigh, .max, .ultra])]
        app.modelCatalog.listModels = { _ in
            _ = await calls.next()
            try await Task.sleep(for: .milliseconds(150))
            return listed
        }

        // Opening a picker checks a list that is due, once, however many ask meanwhile.
        var picked: String?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ModelPicker(data: ModelPickerData(kind: .codex, model: "", openRouterDefault: ""),
                                                                 accountName: "Codex Work", catalog: app.modelCatalog, disabled: false,
                                                                 select: { picked = $0 }, scope: work))
        window.makeKeyAndOrderFront(nil)
        await app.modelCatalog.refresh(work, force: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await calls.count == 1)
        #expect(app.modelCatalog.models(for: work) == listed)
        #expect(app.modelCatalog.status(for: work).checkedAt != nil)
        // Fresh: opening again checks nothing; Refresh models does.
        await app.modelCatalog.refresh(work)
        #expect(await calls.count == 1)
        await app.modelCatalog.refresh(work, force: true)
        #expect(await calls.count == 2)

        // The picker chooses from the list, by keyboard as before.
        window.contentView = NSHostingView(rootView: ModelPicker(
            data: ModelPickerData(kind: .codex, model: "", openRouterDefault: "", native: app.modelCatalog.models(for: work)),
            accountName: "Codex Work", catalog: app.modelCatalog, disabled: false, select: { picked = $0 }, scope: work))
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("terra", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(50))
        #expect(picked == "gpt-6.1-terra")

        // Every local conversation and job set to the profile shares the list; a host's task doesn't.
        let bot = Bot(name: "Scout", accountID: "codex-work", model: "gpt-6.1-terra", reasoningEffort: .ultra,
                      workspace: root.appendingPathComponent("Scout").path, sessionID: "s", sessionAccountID: "codex-work")
        #expect(app.nativeModels(for: bot) == listed)
        var remote = BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "On a host")
        remote.hostID = UUID()
        #expect(app.modelCatalogScope(for: remote) == nil && app.nativeModels(for: remote) == nil)
        #expect(app.nativeModels(for: BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "Here")) == listed)

        // Quick tasks offer the profile's list, and their section checks a profile's that is due.
        settings.quickTaskAccountID = "codex-dev"
        let dev = try #require(app.modelCatalogScope(for: settings.account("codex-dev")))
        window.contentView = NSHostingView(rootView: Form { QuickTaskSettings() }.formStyle(.grouped).environment(app).frame(width: 380))
        try await Task.sleep(for: .milliseconds(500))
        #expect(await calls.count == 3)
        #expect(app.modelCatalog.models(for: dev) == listed)
        #expect(QuickTasks.models(for: .codex, catalog: app.modelCatalog.models(for: dev), chosen: "gpt-6.1-terra").map(\.name)
                == ["GPT-6.1-Sol", "GPT-6.1 Terra"])

        // The list is saved, by an opaque key, and read at the next launch; a check saves nothing else.
        app.modelCatalog.flush()
        let saved = try String(contentsOf: store.root.appendingPathComponent("model-catalogs.json"), encoding: .utf8)
        #expect(saved.contains("gpt-6.1-terra") && !saved.contains(".local/bin"))
        let relaunched = AppModel(store: store, settings: AppSettings(defaults: defaults),
                                  usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        #expect(relaunched.modelCatalog.models(for: work) == listed)
        // The saved choice, effort and session are the bot's own: reading a list changes none of them.
        #expect(bot.model == "gpt-6.1-terra" && bot.reasoningEffort == .ultra && bot.resumableSessionID == "s")

        // Another command for the profile is another list, not this one.
        settings.commands["codex-work"] = "codex --profile elsewhere"
        let changed = try #require(app.modelCatalogScope(for: settings.account("codex-work")))
        #expect(changed != work && app.modelCatalog.models(for: changed) == nil)
    }
}
