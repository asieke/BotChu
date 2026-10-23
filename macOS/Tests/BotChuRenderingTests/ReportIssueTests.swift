import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// What a stand-in filer was given, in place of gh: no test files a real issue.
private actor Filings {
    private(set) var all: [(title: String, body: String)] = []
    func add(_ title: String, _ body: String) { all.append((title, body)) }
}

extension RenderingTests {
    /// Report a Bug or Feature, from the toolbar: its app state leaves the bot's name, folder and
    /// conversation out; ⌘Return files the report; one that isn't filed stays, with why; once filed,
    /// the sheet gives the issue's link, and Done closes it.
    @Test func reportSheetFilesTheReportOrKeepsItWithWhy() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-report-\(UUID().uuidString)")
        let domain = "local.BotChu.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.set(root.appendingPathComponent("bots").path, forKey: "botsRoot")
        let bot = Bot(name: "Secret Scout", workspace: root.appendingPathComponent("bots/secret-scout").path)
        let store = Store(root: root.appendingPathComponent("Support"))
        try BotHome(workspace: bot.workspace).save(bot)
        try BotHome(workspace: bot.workspace).saveThread([ChatMessage(role: .user, text: "The vault code is hunter2."),
                                                          ChatMessage(role: .assistant, text: "Noted.")])
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                             usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") })
        let filings = Filings()
        model.issueFiler = IssueFiler { title, body in
            await filings.add(title, body)
            return .failed("gh couldn't create the issue:\nHTTP 401: Bad credentials")
        }
        let host = NSHostingView(rootView: ContentView().environment(model).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        // The toolbar's button opens the sheet.
        let item = try #require(window.toolbar?.items.first { $0.label == "Report a Bug or Feature" })
        #expect(item.toolTip?.contains("public issue") == true)
        let view = try #require(item.view)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                clickCount: 1, pressure: 1)!)
        }
        try await Task.sleep(for: .milliseconds(400))
        let sheet = try #require(window.attachedSheet)
        let request = try #require(model.issueReport)
        #expect(!model.canReportIssue)
        let state = request.snapshot.lines.joined(separator: "\n")
        #expect(state.contains("Conversation: Home; 2 messages, 0 tool calls"))
        #expect(state.contains("Bots: 1, no turns running"))
        for secret in ["Secret Scout", "secret-scout", root.path, "hunter2", "Noted"] {
            #expect(!state.contains(secret), "“\(secret)” would reach the issue")
        }

        let editor = try #require(sheet.firstResponder as? NSTextView)
        let report = "The sidebar flickers.\n\nIt happens when a task starts."
        editor.insertText(report, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        #expect(request.text == report)
        #expect(request.title == "The sidebar flickers")
        Self.sendKey("\r", code: 36, modifiers: .command, to: sheet)
        try await Task.sleep(for: .milliseconds(300))
        #expect(request.state == .failed("gh couldn't create the issue:\nHTTP 401: Bad credentials"))
        #expect(editor.string == report)
        #expect(window.attachedSheet === sheet)
        let filed = await filings.all
        #expect(filed.count == 1)
        #expect(filed.first?.title == "The sidebar flickers")
        #expect(filed.first?.body == IssueReport.body(report: report, snapshot: request.snapshot))

        // Tried again, it is filed: the sheet links the issue, and Done closes it.
        model.issueFiler = IssueFiler { _, _ in .filed(URL(string: "https://github.com/asieke/BotChu/issues/52")) }
        Self.sendKey("\r", code: 36, modifiers: .command, to: sheet)
        try await Task.sleep(for: .milliseconds(300))
        #expect(request.state == .filed(URL(string: "https://github.com/asieke/BotChu/issues/52")))
        Self.sendKey("\r", code: 36, to: sheet)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.issueReport == nil)
        #expect(window.attachedSheet == nil)
        #expect(model.canReportIssue)

        // A gallery's report says which; Escape closes the sheet without filing.
        model.destination = .projects
        model.reportIssue()
        try await Task.sleep(for: .milliseconds(400))
        let gallery = try #require(window.attachedSheet)
        #expect(model.issueReport?.snapshot.lines.contains("Screen: Projects") == true)
        #expect(model.issueReport?.snapshot.lines.contains { $0.hasPrefix("Conversation:") } == false)
        Self.sendKey("\u{1B}", code: 53, to: gallery)
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.issueReport == nil)
        #expect(await filings.all.count == 1)
    }

    private static func sendKey(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: text,
                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }
}
