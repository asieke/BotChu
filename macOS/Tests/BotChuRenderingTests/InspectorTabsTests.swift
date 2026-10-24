import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func inspectorTabsNavigateWithTheKeyboardAndRememberSelection() async throws {
        _ = NSApplication.shared
        for tab in InspectorTab.allCases {
            #expect(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title) != nil)
        }
        let suite = "BotChu.InspectorTabs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var shown: InspectorTab?
        let panel = InspectorPanel {
            Text("Character").frame(height: 90)
        } content: { tab in
            Text("Contents: \(tab.title)").onAppear { shown = tab }
        } actions: {
            Text("Actions")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: panel.defaultAppStorage(defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(shown == .activity)
        // The five segments share the available width; click the second, then use arrow keys.
        let point = host.convert(NSPoint(x: 140, y: host.isFlipped ? 135 : host.bounds.height - 135), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                          clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(defaults.string(forKey: InspectorTab.storageKey) == "model")
        pressInspectorKey("\u{F703}", code: 124, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(defaults.string(forKey: InspectorTab.storageKey) == "session")
        #expect(shown == .session)
        pressInspectorKey("\u{F702}", code: 123, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(defaults.string(forKey: InspectorTab.storageKey) == "model")
        #expect(shown == .model)

        // Recreating the panel, as switching conversations or relaunching does, restores its area.
        shown = nil
        let restored = NSHostingView(rootView: panel.defaultAppStorage(defaults))
        window.contentView = restored
        try await Task.sleep(for: .milliseconds(100))
        #expect(shown == .model)
    }

    @Test func inspectorTabsFitAndReadUsageForTheShownConversation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inspector-\(UUID().uuidString)")
        let suite = "BotChu.InspectorTabs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bot = Bot(name: "Scout", title: "Your engineering companion", accountID: "codex-dev",
                      model: "gpt-6-astra", workspace: root.appendingPathComponent("Scout").path,
                      sessionID: "home-session", sessionAccountID: "codex-dev")
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let remote = SSHHost(nickname: "Far Mac", destination: "test.invalid")
        let task = BotTask(title: "Review the repository and improve the getting started experience",
                           repo: "fixture/project", checkout: "~/apps/project", branch: "feat/getting-started",
                           folder: "~/apps/project/.claude/worktrees/feat-getting-started", accountID: "claude-work",
                           model: "sonnet", reasoningEffort: .high, sessionID: "task-session", sessionAccountID: "claude-work",
                           hostID: remote.id, hostName: remote.nickname)
        try home.save(task)
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        settings.hosts = [remote]
        let readings = InspectorUsageProbe()
        var keyReads = 0
        let model = AppModel(store: store, settings: settings, usage: UsageCache { request, key in
            let usesExpectedKey = key == (request.account.kind == .pi ? "test-openrouter-key" : nil)
            #expect(usesExpectedKey)
            return await readings.read(request.account.id)
        }, openRouterKey: { keyReads += 1; return "test-openrouter-key" })
        let taskTarget = ChatTarget.task(task.id, of: bot.id)
        model.runStates[taskTarget] = RunState(hasOutput: true, activity: .coding)
        defer { model.runStates.removeAll() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(model).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await readings.accounts.isEmpty)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            if appearance == .darkAqua { window.setContentSize(NSSize(width: 820, height: 520)) }
            for target in [ChatTarget.home(bot.id), taskTarget] {
                model.show(target)
                for tab in InspectorTab.allCases {
                    defaults.set(tab.rawValue, forKey: InspectorTab.storageKey)
                    try await Task.sleep(for: .milliseconds(300))
                    window.layoutIfNeeded()
                    #expect(window.frame.width >= window.contentMinSize.width)
                    #expect(window.frame.height >= window.contentMinSize.height)
                    if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
                        let name = "\(appearance == .aqua ? "light" : "dark-compact")-\(target.taskID == nil ? "home" : "task")-\(tab.rawValue)"
                        DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent(name))
                    }
                }
            }
        }
        // Mounting the model area on Home and the task reads their own accounts, once each;
        // other areas never start allowance queries, and remounting uses the shared cache.
        #expect(await readings.accounts == ["codex-dev", "claude-work"])
        #expect(keyReads == 0) // Other providers never ask for an OpenRouter key.

        // Switching Home to OpenRouter exercises the inspector's injected credential lookup too.
        let homeTarget = ChatTarget.home(bot.id)
        model.setAccount("openrouter", for: homeTarget)
        model.show(homeTarget)
        defaults.set(InspectorTab.model.rawValue, forKey: InspectorTab.storageKey)
        for _ in 0..<40 {
            if await readings.accounts.contains("openrouter") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await readings.accounts == ["codex-dev", "claude-work", "openrouter"])
        #expect(keyReads > 0)
    }

    private func pressInspectorKey(_ text: String, code: UInt16, window: NSWindow) {
        // Hardware arrow keys include Function and Numeric Pad flags.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
}

private actor InspectorUsageProbe {
    var accounts: [String] = []

    func read(_ account: String) -> ProviderUsage {
        accounts.append(account)
        return ProviderUsage(windows: [
            UsageWindow(id: "session", title: "5-hour", usedPercent: 24, resetsAt: .now.addingTimeInterval(7_200)),
            UsageWindow(id: "week", title: "Weekly", usedPercent: 83, resetsAt: .now.addingTimeInterval(259_200)),
        ])
    }
}
