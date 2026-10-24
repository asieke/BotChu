import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// #84: `@` agents and `#` projects in the message box.
extension RenderingTests {
    /// Return and Tab insert the chosen suggestion and never send; with the list closed Return sends.
    @Test func mentionCompletionInsertsWithReturnAndTabWithoutSending() async throws {
        let sample = try MentionSample()
        defer { sample.close() }
        let editor = sample.editor
        editor.insertText("Ask @qa", replacementRange: editor.selectedRange())
        let popup = try #require(sample.completer.popup)
        #expect(popup.query.kind == .agent)
        // Both namesakes, in the sidebar's order, the first chosen.
        #expect(popup.suggestions.map(\.title) == ["QA Duck", "QA Duck"])
        #expect(popup.selected == 0)
        editor.keyDown(with: sample.key(36, "\r"))
        #expect(sample.sent == 0)
        #expect(sample.draft.text == "Ask @QA Duck ")
        #expect(sample.draft.references == [MessageReference.agent(MentionSample.duck, at: 4)])
        #expect(sample.completer.popup == nil)

        editor.insertText("to review #bot", replacementRange: editor.selectedRange())
        #expect(sample.completer.popup?.query.kind == .project)
        #expect(sample.completer.popup?.suggestions.map(\.subtitle) == ["asieke/BotChu"])
        editor.keyDown(with: sample.key(48, "\t"))
        #expect(sample.sent == 0)
        #expect(sample.draft.text == "Ask @QA Duck to review #asieke/BotChu ")
        #expect(sample.draft.references.map(\.label) == ["@QA Duck", "#asieke/BotChu"])
        #expect(sample.draft.references.last?.login == "asieke")
        try await Task.sleep(for: .milliseconds(50))
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("mentions-linked"))
        }

        // Up and Down move through the list without reordering it; a click inserts too.
        editor.insertText("@", replacementRange: editor.selectedRange())
        let all = try #require(sample.completer.popup)
        #expect(all.suggestions.map(\.title) == ["10x Engineer Bot", "QA Duck", "QA Duck"])
        editor.keyDown(with: sample.key(125, "\u{F701}"))
        editor.keyDown(with: sample.key(125, "\u{F701}"))
        #expect(sample.completer.popup?.selected == 2)
        #expect(sample.completer.popup?.suggestions == all.suggestions)
        editor.keyDown(with: sample.key(126, "\u{F700}"))
        #expect(sample.completer.popup?.selected == 1)
        // Namesakes are told apart and keep their own IDs.
        #expect(all.suggestions[1].subtitle != all.suggestions[2].subtitle)
        sample.completer.accept(2)
        #expect(sample.draft.references.last?.target == MentionSample.twin.id.uuidString.lowercased())

        // With the list closed, Return sends as before.
        editor.keyDown(with: sample.key(36, "\r"))
        #expect(sample.sent == 1)
    }

    /// Email addresses, issue numbers and headings open nothing; an unmatched query stays ordinary text
    /// that Return sends; Escape closes the list without touching the draft, and it stays closed.
    @Test func mentionCompletionKeepsToRealQueriesAndEscapeLeavesTheDraft() async throws {
        let sample = try MentionSample()
        defer { sample.close() }
        let editor = sample.editor
        for text in ["mail alex@exa", " #123", "\n# Notes", " https://x.com/a#readme"] {
            editor.insertText(text, replacementRange: editor.selectedRange())
            #expect(sample.completer.popup == nil, "\(text)")
        }
        editor.insertText(" @zz", replacementRange: editor.selectedRange())
        let empty = try #require(sample.completer.popup)
        #expect(empty.suggestions.isEmpty && empty.selected == nil)
        editor.keyDown(with: sample.key(36, "\r"))
        #expect(sample.sent == 1)
        #expect(sample.draft.text.hasSuffix(" @zz"))
        #expect(sample.draft.references.isEmpty)

        editor.selectAll(nil)
        editor.deleteBackward(nil)
        editor.insertText("Hi @qa", replacementRange: editor.selectedRange())
        #expect(sample.completer.popup != nil)
        editor.keyDown(with: sample.key(53, "\u{1B}"))
        #expect(sample.completer.popup == nil)
        #expect(sample.draft.text == "Hi @qa")
        editor.insertText("d", replacementRange: editor.selectedRange())
        #expect(sample.completer.popup == nil)
        // A new trigger opens again; deleting back past it closes.
        editor.insertText(" @", replacementRange: editor.selectedRange())
        #expect(sample.completer.popup?.suggestions.count == 3)
        editor.deleteBackward(nil)
        #expect(sample.completer.popup == nil)
        #expect(sample.sent == 1)
    }

    /// Editing inside a chosen label leaves ordinary text; undo brings the label and its link back.
    @Test func editingAMentionUnlinksItAndUndoRelinksIt() async throws {
        let sample = try MentionSample()
        defer { sample.close() }
        let editor = sample.editor
        editor.insertText("Ask @qa", replacementRange: editor.selectedRange())
        editor.keyDown(with: sample.key(36, "\r"))
        #expect(sample.draft.references.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(sample.draft.text == "Ask @QAx Duck ")
        #expect(sample.draft.references.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        editor.undoManager?.undo()
        #expect(sample.draft.text == "Ask @QA Duck ")
        #expect(sample.draft.references == [MessageReference.agent(MentionSample.duck, at: 4)])
        // Deleting the label leaves no link behind.
        editor.setSelectedRange(NSRange(location: 4, length: 8))
        editor.deleteBackward(nil)
        #expect(sample.draft.references.isEmpty)
        // A draft restored with a link (a queued message taken back) shows it linked.
        sample.draft.text = "Ask @QA Duck"
        sample.draft.references = [MessageReference.agent(MentionSample.duck, at: 4)]
        try await Task.sleep(for: .milliseconds(50))
        #expect(editor.mentionReferences == sample.draft.references)
    }

    /// Pasted text opens nothing; text copied from a message box pastes with its links.
    @Test func pastedTextOpensNothingAndCopiedMentionsStayLinked() async throws {
        let sample = try MentionSample()
        let pasteboard = StandInPasteboard()
        defer { pasteboard.restore(); sample.close() }
        let editor = sample.editor
        pasteboard.board.clearContents()
        pasteboard.board.setString("Hi @qa", forType: .string)
        editor.paste(nil)
        #expect(sample.draft.text == "Hi @qa")
        #expect(sample.completer.popup == nil)

        editor.selectAll(nil)
        editor.deleteBackward(nil)
        editor.insertText("Ask @qa", replacementRange: editor.selectedRange())
        editor.keyDown(with: sample.key(36, "\r"))
        editor.selectAll(nil)
        editor.copy(nil)
        #expect(pasteboard.board.string(forType: .string) == "Ask @QA Duck ")
        #expect(pasteboard.board.availableType(from: [.botchuMentions]) != nil)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.paste(nil)
        #expect(sample.draft.text == "Ask @QA Duck Ask @QA Duck ")
        #expect(sample.draft.references.map(\.location) == [4, 17])
        #expect(sample.completer.popup == nil)
    }

    /// The report and New Task boxes share the editor without completion.
    @Test func sheetsHaveNoMentionCompletion() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let images = DraftImages()
        let box = MentionDraft()
        let host = NSHostingView(rootView: DraftEditor(text: Binding(get: { box.text }, set: { box.text = $0 }), focused: .constant(true),
                                                       images: images, placeholder: "Describe it").frame(width: 460))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let editor = try #require(findMentionTextView(in: host))
        window.makeFirstResponder(editor)
        editor.insertText("@qa #bot", replacementRange: editor.selectedRange())
        #expect(editor.completer == nil)
        #expect(box.text == "@qa #bot")
        #expect(editor.mentionReferences.isEmpty)
    }

    /// A sent message keeps its links, in its thread, and its bot hears what they point at, in a new
    /// session and a resumed one; a mention starts no other bot.
    @Test func sentMentionsReachTheBotInNewAndResumedSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-mentions-\(UUID().uuidString)")
        let suite = "BotChu.Mentions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let scout = Bot(name: "Scout", accountID: "codex-dev", workspace: root.appendingPathComponent("scout").path)
        let duck = Bot(name: "QA Duck", emoji: "🦆", title: "A Duck that QAs", accountID: "codex-dev",
                       workspace: root.appendingPathComponent("duck").path)
        for bot in [scout, duck] { try BotHome(workspace: bot.workspace).save(bot) }
        let cli = root.appendingPathComponent("fixture.py")
        try """
        import json, sys
        from pathlib import Path
        with Path('prompts.jsonl').open('a') as f:
            f.write(json.dumps(sys.argv[-1]) + '\\n')
        print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-session'}))
        print(json.dumps({'type': 'item.completed', 'item': {'id': 'answer', 'type': 'agent_message', 'text': 'Done.'}}))
        print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 1, 'output_tokens': 1}}))
        """.write(to: cli, atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.path
        settings.commands["codex-dev"] = "/usr/bin/python3 \(Shell.quote(cli.path))"
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: scout.id, workspace: scout.workspace), Store.Entry(id: duck.id, workspace: duck.workspace)])
        let model = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") })
        defer { model.stopAll() }
        let target = ChatTarget.home(scout.id)
        #expect(model.mentionAgents(for: target).map(\.name) == ["QA Duck"])

        let mention = MessageReference.agent(BotRosterEntry(bot: duck), at: 4)
        func sendAndWait(_ text: String, references: [MessageReference]) async throws {
            #expect(model.send(text, to: target, references: references))
            for _ in 0..<250 {
                if !model.isRunning(target), model.messageQueues[target]?.messages.isEmpty != false { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!model.isRunning(target))
        }
        try await sendAndWait("  Ask @QA Duck to check this", references: [mention.moved(by: 2), mention.moved(by: 2)])
        try await sendAndWait("And @QA Duck again", references: [mention])
        let prompts = try String(contentsOfFile: (scout.workspace as NSString).appendingPathComponent("prompts.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        try #require(prompts.count == 2)
        let section = "<message_references>"
        let id = duck.id.uuidString.lowercased()
        #expect(prompts[0].contains("<botchu_context>"))
        #expect(prompts[0].contains(section) && prompts[0].contains(id))
        #expect(prompts[0].hasSuffix("</message_references>\n\nAsk @QA Duck to check this"))
        #expect(prompts[0].components(separatedBy: "is the BotChu agent QA Duck").count == 2)
        // Resumed: the context goes with the new message, the session's preamble doesn't.
        #expect(!prompts[1].contains("<botchu_context>"))
        #expect(prompts[1].contains(section) && prompts[1].hasSuffix("And @QA Duck again"))
        // Never the other bot's private files.
        #expect(prompts.allSatisfy { !$0.contains(duck.workspace) })
        // The thread keeps the links, through a save and a reload; the duck got nothing.
        let sent = model.thread(target).filter { $0.role == .user }
        #expect(sent.map(\.mentions) == [[mention], [mention]])
        #expect(BotHome(workspace: scout.workspace).loadThread().filter { $0.role == .user }.map(\.mentions) == [[mention], [mention]])
        #expect(model.thread(.home(duck.id)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: (duck.workspace as NSString).appendingPathComponent("prompts.jsonl")))

        // A deleted agent's link resolves to nothing, never to another bot (as deleting it leaves
        // `bots`, without putting its files in the Trash here).
        #expect(model.referenceStatus(mention) == .resolved)
        model.bots.removeAll { $0.id == duck.id }
        #expect(model.referenceStatus(mention) == .agentGone)
        #expect(model.deliveredText(of: sent[0], for: target).contains("no longer exists"))
    }
}

private func findMentionTextView(in view: NSView) -> ComposerTextView? {
    if let editor = view as? ComposerTextView { return editor }
    return view.subviews.lazy.compactMap { findMentionTextView(in: $0) }.first
}

@MainActor @Observable private final class MentionDraft {
    var text = ""
    var references: [MessageReference] = []
}

/// A message box with completion over two agents (and a namesake) and two projects, in a window.
@MainActor private final class MentionSample {
    static let duck = BotRosterEntry(bot: Bot(name: "QA Duck", emoji: "🦆", title: "A Duck that QAs", workspace: "/tmp/duck"))
    static let twin = BotRosterEntry(bot: Bot(name: "QA Duck", emoji: "🐤", title: "A Duck that QAs", workspace: "/tmp/twin"))
    static let engineer = BotRosterEntry(bot: Bot(name: "10x Engineer Bot", title: "Principal engineer", workspace: "/tmp/10x"))

    let window: NSWindow
    let completer = MentionCompleter()
    let draft = MentionDraft()
    private let sends = Sends()
    let editor: ComposerTextView
    var sent: Int { sends.count }

    private final class Sends { var count = 0 }

    init() throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sources = MentionSources(
            agents: { [Self.engineer, Self.duck, Self.twin] },
            projects: { [ProjectCatalogEntry(name: "BotChu", repo: "asieke/BotChu", status: .active),
                         ProjectCatalogEntry(name: "GitChu", repo: "asieke/GitChu", status: .paused)] },
            catalog: { MentionCatalogState(login: "asieke", loaded: true, syncedAt: Date()) },
            favoredRepo: nil, status: { _ in .resolved }, loadProjects: {}, openAgents: {})
        let draft = draft, completer = completer, sends = sends
        let view = VStack {
            Spacer()
            ComposerEditor(text: Binding(get: { draft.text }, set: { draft.text = $0 }), focused: .constant(true), placeholder: "Message",
                           send: { sends.count += 1 }, pasteImages: { _ in false },
                           mentions: completer, mentionSources: sources,
                           references: Binding(get: { draft.references }, set: { draft.references = $0 }))
                .overlay(alignment: .topLeading) { MentionPopupView(completer: completer) }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        editor = try #require(findMentionTextView(in: host))
        window.makeFirstResponder(editor)
    }

    func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
