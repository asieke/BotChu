import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

@Suite(.serialized) @MainActor struct ModelControlsTests {
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
}
