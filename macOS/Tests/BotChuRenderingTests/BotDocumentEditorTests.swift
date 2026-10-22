import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test(arguments: BotDocument.allCases) func documentModalUsesHalfTheWindowAndSavesOrCancels(document: BotDocument) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-editor-\(UUID().uuidString)")
        let domain = "local.BotChu.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.set(root.appendingPathComponent("bots").path, forKey: "botsRoot")
        let bot = Bot(name: "Scout", workspace: root.appendingPathComponent("bots/scout").path)
        let store = Store(root: root.appendingPathComponent("Support"))
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                             usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") })
        let host = NSHostingView(rootView: ContentView().environment(model).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        model.editDocument(document, for: bot.id)
        try await Task.sleep(for: .milliseconds(350))
        let sheet = try #require(window.attachedSheet)
        let size = try #require(sheet.contentView?.bounds.size)
        #expect(abs(size.width - host.bounds.width * 0.5) < 3)
        #expect(abs(size.height - host.bounds.height * 0.5) < 3)
        let editor = try #require(sheet.firstResponder as? NSTextView)
        let markdown = "# Edited\n\n- Keep this exact text ✨\n"
        editor.selectAll(nil)
        editor.insertText(markdown, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        sendDocumentKey("s", code: 1, modifiers: .command, to: sheet)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.documentEditor == nil)
        #expect(try String(contentsOf: document.url(for: bot), encoding: .utf8) == markdown)

        model.editDocument(document, for: bot.id)
        try await Task.sleep(for: .milliseconds(350))
        let cancelSheet = try #require(window.attachedSheet)
        let cancelEditor = try #require(cancelSheet.firstResponder as? NSTextView)
        cancelEditor.selectAll(nil)
        cancelEditor.insertText("Discard this", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        sendDocumentKey("\u{1B}", code: 53, to: cancelSheet)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.documentEditor == nil)
        #expect(try String(contentsOf: document.url(for: bot), encoding: .utf8) == markdown)

        // A bot can write new notes while its owner is editing. Save keeps the draft open on conflict.
        model.editDocument(document, for: bot.id)
        try await Task.sleep(for: .milliseconds(350))
        let conflictSheet = try #require(window.attachedSheet)
        try "New notes on disk".write(to: document.url(for: bot), atomically: true, encoding: .utf8)
        sendDocumentKey("s", code: 1, modifiers: .command, to: conflictSheet)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.documentEditor != nil)
        #expect(try String(contentsOf: document.url(for: bot), encoding: .utf8) == "New notes on disk")
        sendDocumentKey("\u{1B}", code: 53, to: conflictSheet)
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.documentEditor == nil)
    }

    @Test func inspectorSectionsCollapseFromTheirHeadingAndRememberTheirState() async throws {
        _ = NSApplication.shared
        let domain = "local.BotChu.sections.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let host = NSHostingView(rootView: InspectorSection("Memory") {
            Text("Memory cards").frame(height: 70)
        }.padding().frame(width: 320).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        window.setContentSize(host.fittingSize)
        window.layoutIfNeeded()
        let expandedHeight = host.fittingSize.height
        clickSectionHeading(in: host, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(defaults.object(forKey: "inspector.expanded.Memory") as? Bool == false)
        #expect(host.fittingSize.height < expandedHeight - 60)

        let restored = NSHostingView(rootView: InspectorSection("Memory") {
            Text("Memory cards").frame(height: 70)
        }.padding().frame(width: 320).defaultAppStorage(defaults))
        window.contentView = restored
        try await Task.sleep(for: .milliseconds(100))
        window.setContentSize(restored.fittingSize)
        window.layoutIfNeeded()
        clickSectionHeading(in: restored, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(defaults.object(forKey: "inspector.expanded.Memory") as? Bool == true)
        #expect(restored.fittingSize.height >= expandedHeight)
    }

    private func clickSectionHeading(in host: NSView, window: NSWindow) {
        let point = host.convert(NSPoint(x: 80, y: host.isFlipped ? 24 : host.bounds.height - 24), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                          clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }

    @Test func newSessionsLoadCurrentFilesWhileResumedTurnsKeepTheirContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-session-documents-\(UUID().uuidString)")
        let domain = "local.BotChu.documents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        let bot = Bot(name: "Scout", accountID: "claude-dev", workspace: root.appendingPathComponent("bots/scout").path)
        try BotHome(workspace: bot.workspace).save(bot)
        let store = Store(root: root.appendingPathComponent("Support"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let script = root.appendingPathComponent("fixture-cli")
        try """
        #!/usr/bin/env python3
        import json, sys
        from pathlib import Path
        Path(__file__).with_name('prompt.txt').write_text(sys.argv[-1])
        print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'fixture-session'}))
        print(json.dumps({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'OK'}]}}))
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.commands[bot.accountID] = script.path
        let model = AppModel(store: store, settings: settings)
        let target = ChatTarget.home(bot.id)
        let captured = root.appendingPathComponent("prompt.txt")
        model.send("First", to: target)
        try await waitForDocumentTurn(model, target: target)
        #expect(try String(contentsOf: captured, encoding: .utf8).contains(BotContext.seedSoul(bot: bot).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(model.bot(bot.id)?.resumableSessionID == "fixture-session")

        for document in BotDocument.allCases {
            var draft = try BotDocumentDraft(bot: bot, document: document)
            draft.text = document == .soul ? "Now speak like a pirate." : "The owner likes tea."
            try draft.save()
        }
        model.send("Resume", to: target)
        try await waitForDocumentTurn(model, target: target)
        #expect(try String(contentsOf: captured, encoding: .utf8) == "Resume")
        model.newSession(target)
        model.send("Fresh session", to: target)
        try await waitForDocumentTurn(model, target: target)
        let fresh = try String(contentsOf: captured, encoding: .utf8)
        #expect(fresh.contains("<personality>\nNow speak like a pirate.\n</personality>"))
        #expect(fresh.contains("The owner likes tea."))

        // Moving is blocked while either Home or a task is using the old context paths.
        var moved = try #require(model.bot(bot.id))
        moved.workspace = root.appendingPathComponent("moved").path
        let busyTask = ChatTarget.task(UUID(), of: bot.id)
        model.runStates[busyTask] = RunState()
        #expect(model.workspaceProblem(moved.workspace, for: bot.id) != nil)
        model.update(moved)
        #expect(model.bot(bot.id)?.workspace == bot.workspace)
        #expect(FileManager.default.fileExists(atPath: BotDocument.memory.url(for: bot).path))
        model.runStates[busyTask] = nil
        model.update(moved)
        #expect(model.bot(bot.id)?.workspace == moved.workspace)
        #expect(try String(contentsOf: BotDocument.soul.url(for: moved), encoding: .utf8) == "Now speak like a pirate.")
    }

    private func waitForDocumentTurn(_ model: AppModel, target: ChatTarget) async throws {
        for _ in 0..<150 {
            if !model.isRunning(target) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        model.stop(target)
        Issue.record("The fixture CLI did not finish")
    }

    private func sendDocumentKey(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        if modifiers.contains(.command) {
            #expect(window.performKeyEquivalent(with: event))
        } else {
            window.sendEvent(event)
        }
    }
}
