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
    /// Sail's list (#326): read with the saved key into the same saved book as every profile's, kept
    /// through a failed check, and another list once the key changes.
    @Test func sailsListIsKeptLikeEveryProfilesAndReadWithItsKeyOnly() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-sail-picker-\(UUID().uuidString)")
        let domain = "BotChu.SailPickerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        let settings = AppSettings(defaults: defaults)
        settings.sailModel = "sail/default"
        let store = Store(root: root.appendingPathComponent("index"))
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        var keyReads = 0
        var savedKey: String?
        app.sailKey = { keyReads += 1; return savedKey }

        // A key is read only for the list that needs it, and never for a host's.
        let sail = try #require(app.modelCatalogScope(for: settings.account("sail")))
        #expect(app.modelListKeys(for: try #require(app.modelCatalogScope(for: settings.account("claude-dev")))).isEmpty && keyReads == 0)
        #expect(app.modelListKeys(for: sail).isEmpty && keyReads == 1)
        savedKey = "saved-test-key"
        #expect(app.modelListKeys(for: sail) == [Sail.keyVariable: "saved-test-key"])
        var hosted = sail
        hosted.machine = Machine(destination: "me@omarchy")
        #expect(app.modelListKeys(for: hosted).isEmpty && keyReads == 2)

        let calls = ListCalls()
        let listed = [ModelOption(id: "sail/default", name: "Default Model", efforts: [], effortsKnown: false, contextLength: 128_000),
                      ModelOption(id: "sail/other", name: "Other Model", efforts: [], effortsKnown: false)]
        app.modelCatalog.listModels = { scope in
            #expect(scope.kind == .sail)
            let count = await calls.next()
            try await Task.sleep(for: .milliseconds(50))
            if count == 2 { throw ModelListFailure("Sail didn't list its models (HTTP 503: busy).") }
            return listed
        }
        let bot = Bot(name: "Sail Test", accountID: "sail", workspace: root.appendingPathComponent("bot").path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        // The menu alone checks nothing; its picker opening checks a list that is due, once.
        window.contentView = NSHostingView(rootView: ModelMenu(settings: bot, disabled: false, onModel: { _ in }, onEffort: { _ in }).environment(app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await calls.count == 0)
        var picked: String?
        window.contentView = NSHostingView(rootView: SailPickerTestView(app: app, settings: bot, select: { picked = $0 }))
        for _ in 0..<100 where app.modelCatalog.models(for: sail) == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await calls.count == 1)
        #expect(app.modelCatalog.models(for: sail) == listed)
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("other", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(50))
        #expect(picked == "sail/other")

        // Fresh: opening again checks nothing. A failed Refresh models keeps the list and says why.
        await app.modelCatalog.refresh(sail)
        #expect(await calls.count == 1)
        await app.modelCatalog.refresh(sail, force: true)
        #expect(await calls.count == 2)
        #expect(app.modelCatalog.models(for: sail) == listed)
        #expect(app.modelCatalog.status(for: sail).failure == "Sail didn't list its models (HTTP 503: busy).")

        // Saved between launches, like every profile's.
        app.modelCatalog.flush()
        let saved = try Data(contentsOf: store.root.appendingPathComponent("model-catalogs.json"))
        #expect(NativeCatalogFile.decode(saved)[sail.key]?.models == listed)
        #expect(!String(decoding: saved, as: UTF8.self).contains("saved-test-key"))
        // A new key is another account's list, unread until checked.
        settings.sailUsageCredentialRevision += 1
        let rekeyed = try #require(app.modelCatalogScope(for: settings.account("sail")))
        #expect(rekeyed != sail && app.modelCatalog.models(for: rekeyed) == nil)
    }

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
        // Muse lists its models too (#248), and every other family since #326.
        #expect(app.modelCatalogScope(for: settings.account("muse"))?.kind == .muse)
        for id in ["claude-dev", "google", "openrouter", "sail"] { #expect(app.modelCatalogScope(for: settings.account(id)) != nil) }

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

        // Every local conversation and job set to the profile shares the list; a host's task has its host's.
        let bot = Bot(name: "Scout", accountID: "codex-work", model: "gpt-6.1-terra", reasoningEffort: .ultra,
                      workspace: root.appendingPathComponent("Scout").path, sessionID: "s", sessionAccountID: "codex-work")
        #expect(app.nativeModels(for: bot) == listed)
        #expect(app.nativeModels(for: BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "Here")) == listed)
        var remote = BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "On a host")
        remote.hostID = UUID()
        // A host that is no longer in Settings has no list to read: the starters stand in.
        #expect(app.modelCatalogScope(for: remote) == nil && app.nativeModels(for: remote) == nil)
        let omarchy = SSHHost(nickname: "Omarchy", destination: "me@omarchy", commands: ["codex-work": "codex --profile work"])
        settings.hosts = [omarchy]
        remote.hostID = omarchy.id
        let hosted = try #require(app.modelCatalogScope(for: remote))
        // Read there, with the command its turns run there, and never this Mac's list meanwhile.
        #expect(hosted.machine.destination == "me@omarchy" && hosted.command == "codex --profile work" && hosted.folder == "~")
        #expect(app.nativeModels(for: remote) == nil && app.modelListKeys(for: hosted).isEmpty)
        // An open task's host is kept fresh with the profiles; a closed one's isn't.
        app.tasks[bot.id] = [remote]
        #expect(app.modelCatalogScopes().contains(hosted))
        app.tasks[bot.id]?[0].archivedAt = Date()
        #expect(!app.modelCatalogScopes().contains(hosted))
        app.tasks[bot.id] = nil
        let hostList = [ModelOption(id: "gpt-host-only", name: "Host Only", efforts: [.low])]
        let local = app.modelCatalog.listModels
        app.modelCatalog.listModels = { scope in scope.machine.isRemote ? hostList : listed }
        await app.modelCatalog.refresh(hosted)
        #expect(app.nativeModels(for: remote) == hostList && app.nativeModels(for: bot) == listed)
        app.modelCatalog.listModels = local
        settings.hosts = []

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

/// Rebuilds the picker's data from the observable catalog, as ModelMenu's popover does.
private struct SailPickerTestView: View {
    let app: AppModel
    let settings: Bot
    let select: (String) -> Void

    var body: some View {
        ModelPicker(data: ModelPickerData(kind: .sail, model: "", openRouterDefault: "openrouter/model", sailDefault: "sail/default",
                                           native: app.nativeModels(for: settings)),
                    accountName: "Sail Test", catalog: app.modelCatalog, disabled: false, select: select,
                    scope: app.modelCatalogScope(for: settings))
    }
}
