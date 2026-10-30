import AppKit
import SwiftUI
import Testing
import Vision
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
        // An OpenRouter key saved before: other profiles' readings stay shared all the same.
        settings.usageCredentialRevision = 2
        let readings = InspectorUsageProbe()
        var keyReads = 0
        let model = AppModel(store: store, settings: settings, usage: UsageCache { request, keys in
            let usesExpectedKey = keys == UsageKeys(openRouter: request.account.kind == .pi ? "test-openrouter-key" : nil)
            #expect(usesExpectedKey)
            return await readings.read(request.account.id)
        }, openRouterKey: { keyReads += 1; return "test-openrouter-key" })
        model.sailKey = { nil }
        let connectorChecks = InspectorConnectorProbe()
        model.connectorBoard.checkProfile = { kind, command, folder in
            await connectorChecks.check(kind, command, folder)
        }
        // The background has read Home's account already (#147).
        let background = try #require(model.usageRequests.first { $0.account.id == "codex-dev" })
        await model.usageBoard.refresh(background, usage: model.usage, keys: model.usageKeys, for: .background)
        #expect(await readings.accounts == ["codex-dev"])
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
        #expect(await readings.accounts == ["codex-dev"])

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
        // Mounting the model area on Home shows the background's reading without a check; on the
        // task, whose account has none, it reads it once. Other areas never start allowance
        // queries, and remounting uses the shared cache.
        #expect(await readings.accounts == ["codex-dev", "claude-work"])
        #expect(model.usageBoard.states[background]?.reading != nil)
        #expect(keyReads == 0) // Other providers never ask for an OpenRouter key.

        // Connectors (#183): Home's Codex profile is checked once in its folder and shown; the task
        // runs Claude Code on a host, where only its session's report counts, and it has none yet.
        let homeScope = try #require(model.connectorScope(of: .home(bot.id)))
        #expect(await connectorChecks.calls == ["codex \(homeScope.command) \(bot.workspace)"])
        let check = try #require(model.connectorBoard.evidence.check(for: homeScope))
        #expect(model.connectorCard(of: .home(bot.id)) == .profile(check))
        #expect(check.report?.connected.map(\.name) == ["Linear"])
        #expect(model.connectorCard(of: taskTarget) == .notReported)
        let taskScope = try #require(model.connectorScope(of: taskTarget))
        #expect(taskScope.hostID == remote.id && taskScope.folder == task.folder)
        model.connectorBoard.record([Connector(name: "Gmail", state: .connected, origin: .claudeAI)], scope: taskScope,
                                    sessionID: "task-session", for: taskTarget)
        #expect(model.connectorCard(of: taskTarget).title == "Connected at last report")
        model.runStates[taskTarget] = nil // its turn ends, so New Session can start one afresh
        model.newSession(taskTarget)
        #expect(model.connectorCard(of: taskTarget).title == "Last session report")

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
        #expect(model.connectorCard(of: homeTarget) == .unavailable(.pi))
        #expect(await connectorChecks.calls.count == 1)
    }

    /// #320: the Activity tab's Context card, made on the Quick tasks profile as a turn ends and at
    /// most every two minutes while one runs, never two at once for a conversation; a reply that
    /// isn't one keeps the card before, and the next launch shows the saved card at once while the
    /// transcript is the one it was made from. Without a Quick tasks profile nothing is asked or shown.
    @Test func theContextCardShowsWhatTheConversationIsAboutOnTheQuickTasksProfile() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-context-\(UUID().uuidString)")
        let suite = "BotChu.InspectorContext.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bot = Bot(name: "Product Fox", emoji: "🦊", workspace: root.appendingPathComponent("Fox").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let task = BotTask(repo: "fixture/protagonist", checkout: root.path, branch: "feat/103-opt-in",
                           work: .init(number: 103, title: "College Arc email opt-in", url: URL(string: "https://github.com/fixture/protagonist/issues/103")!,
                                       isPullRequest: false))
        try home.save(task)
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        func launch() -> AppModel {
            let settings = AppSettings(defaults: defaults)
            settings.botsRoot = root.appendingPathComponent("bots").path
            settings.reposRoot = root.appendingPathComponent("repos").path
            return AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        }
        let model = launch()
        defer { model.stopAll() }
        let target = ChatTarget.task(task.id, of: bot.id)
        let jobs = ContextJobs()
        let card = "You asked Product Fox to launch the College Arc opt-in. It filed #103 and waits for your postal address."
        model.summaryRunner = { job in
            jobs.add(job)
            return card
        }
        model.conversation(target).replace([ChatMessage(role: .user, text: "Which postal address should the emails show?"),
                                            ChatMessage(role: .assistant, text: "Paste the address here; a PO Box is fine.")])
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in model.saveThread(target) { _ in done.resume() } }

        // Off: its turn's end asks nothing, and the tab shows no Context section.
        model.refreshContext(target, turnEnded: true)
        #expect(model.contextRuns.isEmpty && jobs.all.isEmpty && model.context(of: target) == nil)
        defaults.set(InspectorTab.activity.rawValue, forKey: InspectorTab.storageKey)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 720), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: TaskInspector(target: target).environment(model).defaultAppStorage(defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        var text = try await inspectorText(host)
        #expect(!text.contains { $0.localizedCaseInsensitiveContains("context") }, "\(text.sorted())")
        #expect(text.contains { $0.localizedCaseInsensitiveContains("repository") }, "The rest of the tab shows: \(text.sorted())")

        // On: the turn's end asks once, on that profile and model, from this conversation.
        model.settings.quickTaskAccountID = "claude-dev"
        model.settings.quickTaskModel = "haiku"
        model.refreshContext(target, turnEnded: true)
        #expect(model.contextRuns.count == 1)
        await model.contextRuns[target]?.value
        #expect(jobs.all.map(\.account.id) == ["claude-dev"] && jobs.all.first?.model == "haiku")
        #expect(jobs.all.first?.key == "context-\(task.id.uuidString)")
        #expect(jobs.all.first?.prompt.contains("Bot: Paste the address here; a PO Box is fine.") == true)
        #expect(model.context(of: target)?.text == card && model.contextRuns.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        text = try await inspectorText(host)
        #expect(text.contains { $0.localizedCaseInsensitiveContains("context") }, "\(text.sorted())")
        #expect(text.contains { $0.contains("College") }, "\(text.sorted())")
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("context-card"))
        }

        // A reply that isn't two to four sentences keeps the card before.
        model.summaryRunner = { job in
            jobs.add(job)
            return "Sure! Here is the note"
        }
        model.refreshContext(target, turnEnded: true)
        await model.contextRuns[target]?.value
        #expect(jobs.all.count == 2 && model.context(of: target)?.text == card)

        // A turn running six minutes asks at most three times, never two at once; its end asks again.
        let started = Date()
        model.runStates[target] = RunState(startedAt: started, hasOutput: true, activity: .coding)
        model.summaryRunner = { job in
            jobs.add(job)
            return "You asked for the opt-in. Product Fox is still building it."
        }
        for second in stride(from: 0, through: 360, by: 2) {
            model.refreshContext(target, turnEnded: false, now: started.addingTimeInterval(TimeInterval(second)))
            #expect(model.contextRuns.count <= 1)
            await model.contextRuns[target]?.value
        }
        #expect(jobs.all.count == 5, "\(jobs.all.count - 2) asks while it ran")
        #expect(jobs.all.last?.prompt.contains("still working on its reply") == true)
        model.summaryRunner = { job in
            jobs.add(job)
            try await Task.sleep(for: .milliseconds(200))
            return card
        }
        model.runStates[target] = nil
        model.refreshContext(target, turnEnded: true)
        model.refreshContext(target, turnEnded: true)
        #expect(model.contextRuns.count == 1, "One at a time for a conversation")
        while let run = model.contextRuns[target] { await run.value }
        #expect(jobs.all.count == 7 && model.context(of: target)?.text == card, "Its end asked once more")

        // Home too, on its own.
        model.conversation(.home(bot.id)).replace([ChatMessage(role: .user, text: "Start a task on protagonist")])
        model.refreshContext(.home(bot.id), turnEnded: true)
        await model.contextRuns[.home(bot.id)]?.value
        #expect(jobs.all.last?.key == "context-home-\(bot.id.uuidString)" && model.context(of: .home(bot.id))?.text == card)

        // Unset again: no card, though one was made.
        model.settings.quickTaskAccountID = nil
        try await Task.sleep(for: .milliseconds(300))
        text = try await inspectorText(host)
        #expect(!text.contains { $0.localizedCaseInsensitiveContains("context") }, "\(text.sorted())")
        model.settings.quickTaskAccountID = "claude-dev"

        // The next launch shows it at once, while the transcript is the one it was made from.
        await model.storage.settle()
        let again = launch()
        defer { again.stopAll() }
        again.readContext(target)
        for _ in 0..<100 where again.context(of: target) == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(again.context(of: target)?.text == card)
        try home.writeTranscript([ChatMessage(role: .user, text: "Changed elsewhere")], task: task.id)
        let changed = launch()
        defer { changed.stopAll() }
        changed.readContext(target)
        await changed.storage.settle()
        #expect(changed.context(of: target) == nil, "A transcript changed since never shows the card as current")

        // Closing the task lets go of a context under way.
        model.summaryRunner = { job in
            jobs.add(job)
            try await Task.sleep(for: .milliseconds(300))
            return "You closed it. Nothing waits."
        }
        model.refreshContext(target, turnEnded: true)
        let closing = try #require(model.contextRuns[target])
        model.closeTask(target)
        #expect(model.contextRuns.isEmpty)
        await closing.value
        #expect(model.context(of: target)?.text == card)
        model.refreshContext(target, turnEnded: true)
        #expect(model.contextRuns.isEmpty, "Nothing is asked for a closed task")
    }

    /// The text drawn in the view, as Vision reads its pixels (SwiftUI's text isn't consistently
    /// exposed to in-process accessibility).
    private func inspectorText(_ host: NSView) async throws -> Set<String> {
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let pixels = try #require(image.cgImage)
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: pixels).perform([request])
            return Set((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
        }.value
    }

    private func pressInspectorKey(_ text: String, code: UInt16, window: NSWindow) {
        // Hardware arrow keys include Function and Numeric Pad flags.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
}

private final class ContextJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [EvaluationJob] = []

    func add(_ job: EvaluationJob) { lock.withLock { jobs.append(job) } }
    var all: [EvaluationJob] { lock.withLock { jobs } }
}

private actor InspectorConnectorProbe {
    var calls: [String] = []

    func check(_ kind: AgentKind, _ command: String, _ folder: String) -> ConnectorReport {
        calls.append("\(kind.rawValue) \(command) \(folder)")
        return ConnectorReport(connectors: [Connector(name: "Linear", state: .connected, origin: .codexApp),
                                            Connector(name: "Slack", state: .needsAuth, origin: .codexApp)])
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
