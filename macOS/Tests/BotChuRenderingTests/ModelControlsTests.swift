import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func modelSearchAndEffortCanBeSelectedWithTheKeyboard() async throws {
        _ = NSApplication.shared
        var pickedModel: String?
        let picker = ModelPicker(data: ModelPickerData(kind: .codex, model: "", openRouterDefault: ""),
                                 accountName: "Codex Test", catalog: ModelCatalog(), disabled: false,
                                 select: { pickedModel = $0 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: picker)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("astra", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        press("\r", code: 36, in: window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(pickedModel == "gpt-6-astra")

        var pickedEffort: ReasoningEffort?
        window.contentView = NSHostingView(rootView: EffortPicker(efforts: [.low, .medium, .high], selected: .medium,
            disabled: false, select: { pickedEffort = $0 }))
        try await Task.sleep(for: .milliseconds(150))
        press("\u{F701}", code: 125, in: window)
        // SwiftUI commits the focus change between hardware events.
        try await Task.sleep(for: .milliseconds(50))
        press("\r", code: 36, in: window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(pickedEffort == .high)
    }

    private func press(_ text: String, code: UInt16, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }

    @Test func selectionsPersistOnTheirOwnConversationAndKeepSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "BotChu.ModelControlsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Test", accountID: "claude-dev", model: "opus", reasoningEffort: .high,
                      workspace: root.appendingPathComponent("bot").path,
                      sessionID: "home-session", sessionAccountID: "claude-dev")
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        var task = BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "Test")
        task.sessionID = "task-session"
        task.sessionAccountID = "claude-dev"
        try home.save(task)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults))
        let homeTarget = ChatTarget.home(bot.id)
        let taskTarget = ChatTarget.task(task.id, of: bot.id)

        // The composer and inspector use these same actions, each with its own ChatTarget.
        app.setModel("sonnet", for: taskTarget)
        app.setReasoningEffort(.medium, for: taskTarget)
        #expect(app.runSettings(of: homeTarget)?.model == "opus")
        #expect(app.runSettings(of: homeTarget)?.reasoningEffort == .high)
        #expect(app.runSettings(of: taskTarget)?.model == "sonnet")
        #expect(home.loadTasks().first?.reasoningEffort == .medium)
        #expect(home.loadTasks().first?.resumableSessionID == "task-session")

        app.setModel("haiku", for: homeTarget)
        app.setReasoningEffort(.high, for: homeTarget)
        #expect(home.loadBot()?.model == "haiku")
        #expect(home.loadBot()?.reasoningEffort == nil)
        #expect(home.loadBot()?.resumableSessionID == "home-session")
        #expect(home.loadTasks().first?.model == "sonnet")

        app.runStates[taskTarget] = RunState()
        app.setModel("opus", for: taskTarget)
        app.setReasoningEffort(.max, for: taskTarget)
        #expect(app.runSettings(of: taskTarget)?.model == "sonnet")
        #expect(app.runSettings(of: taskTarget)?.reasoningEffort == .medium)
        #expect(home.loadTasks().first?.model == "sonnet")
        app.runStates[taskTarget] = nil
    }

    @Test func accountsChangeIndependentlyForHomeAndTasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-account-selection-\(UUID().uuidString)")
        let domain = "BotChu.AccountSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        let bot = Bot(name: "Test", accountID: "codex-work", model: "gpt-6-astra", reasoningEffort: .xhigh,
                      workspace: root.appendingPathComponent("bot").path,
                      sessionID: "home-session", sessionAccountID: "codex-work")
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        var task = BotTask(for: bot, repo: "test/repo", checkout: root.path, work: nil, brief: "Test")
        task.sessionID = "task-session"
        task.sessionAccountID = "codex-work"
        try home.save(task)
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let settings = AppSettings(defaults: defaults)
        let custom = Account(id: "custom-research", name: "Research", kind: .codex, defaultCommand: "codex-research", symbol: "terminal")
        settings.customAccounts = [custom]
        let app = AppModel(store: store, settings: settings)
        let homeTarget = ChatTarget.home(bot.id)
        let taskTarget = ChatTarget.task(task.id, of: bot.id)
        defer { app.runStates.removeAll() }

        // A busy task does not prevent changing Home. Same-family switches keep generation choices.
        app.runStates[taskTarget] = RunState()
        app.setAccount(custom.id, for: homeTarget)
        #expect(home.loadBot()?.account == custom)
        #expect(home.loadBot()?.model == "gpt-6-astra")
        #expect(home.loadBot()?.reasoningEffort == .xhigh)
        #expect(home.loadBot()?.resumableSessionID == nil)
        #expect(home.loadTasks().first?.resumableSessionID == "task-session")

        // Both kinds of conversation reject account changes while their own turn is active.
        app.runStates[homeTarget] = RunState()
        app.setAccount("claude-dev", for: homeTarget)
        app.setAccount("claude-dev", for: taskTarget)
        #expect(app.bot(bot.id)?.account == custom)
        #expect(app.task(taskTarget)?.accountID == "codex-work")

        // An idle task can switch while Home is busy; a new family clears incompatible choices.
        app.runStates[taskTarget] = nil
        app.setAccount("claude-work", for: taskTarget)
        #expect(home.loadTasks().first?.accountID == "claude-work")
        #expect(home.loadTasks().first?.model == "")
        #expect(home.loadTasks().first?.reasoningEffort == nil)
        #expect(home.loadTasks().first?.resumableSessionID == nil)
        let restored = AppModel(store: store, settings: AppSettings(defaults: defaults))
        #expect(restored.bot(bot.id)?.account == custom)
        #expect(restored.task(taskTarget)?.accountID == "claude-work")
    }
}
