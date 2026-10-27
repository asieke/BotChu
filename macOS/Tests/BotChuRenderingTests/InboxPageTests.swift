import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
import BotChuCore
@testable import BotChu

/// A delivery's HTML page runs its scripts with the network off (`OfflinePage`).
extension RenderingTests {
    @Test func aDeliveredPageRunsItsScriptsButReachesNothingBeyondItsFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("index.html")
        try """
            <!doctype html><title>Sample</title><script>
            document.title = 'Ran';
            fetch('https://example.com/').then(() => { window.remote = 'reached' }).catch(() => { window.remote = 'blocked' });
            </script>
            """.write(to: page, atomically: true, encoding: .utf8)
        let compiled = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BotChuInboxOfflineTest",
                                                                                          encodedContentRuleList: OfflinePage.rules)
        let rules = try #require(compiled)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        view.loadFileURL(page, allowingReadAccessTo: folder)
        var remote: String?
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            remote = try? await view.evaluateJavaScript("window.remote") as? String
            if remote != nil { break }
        }
        #expect(view.title == "Ran")
        #expect(remote == "blocked")
    }

    /// The page opens on what needs the owner, reads it (clearing its conversation's dot), and stops
    /// counting as reading once it is left.
    @Test func theInboxOpensOnWhatNeedsTheOwnerAndReadsIt() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-page-\(UUID().uuidString)")
        let domain = "BotChu.InboxPageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fox", emoji: "🦊", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let folder = InboxFolder(home: BotHome(workspace: bot.workspace))
        let report = Delivery(botID: bot.id, title: "Report", note: "Read me", sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -60)))
        let asking = Delivery(botID: bot.id, title: "Which should I file?", note: "Two options.",
                              files: [Delivery.File(name: "notes.md", kind: .document, bytes: 7)],
                              question: Delivery.Question(text: "Which?", choices: ["A", "B"]), sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -600)))
        try folder.save(report, contents: [:])
        try folder.save(asking, contents: ["notes.md": Data("# Notes".utf8)])
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        for _ in 0..<100 where app.inbox.all.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.inbox.unreadCount == 2)
        app.unread.insert(.home(bot.id))

        app.destination = .inbox
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InboxView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        window.layoutIfNeeded()
        // The question comes first, though the report is newer, and reading it clears Home's dot.
        #expect(app.inbox.selected == asking.id)
        #expect(app.inbox.isReading(asking.id))
        #expect(!app.inbox.isUnread(asking.id) && app.inbox.isUnread(report.id))
        #expect(!app.unread.contains(.home(bot.id)))

        // Choosing another reads it; leaving the page, nothing is being read.
        app.inbox.selected = report.id
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.unreadCount == 0)
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(!app.inbox.isReading(report.id))
    }

    /// Done moves the delivery being read out of its group at once: with Done closed, the next one
    /// is read, and after the last, none; a Done one chosen opens Done, and Move to Inbox keeps it.
    @Test func doneMovesTheDeliveryBeingReadAtOnce() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-done-\(UUID().uuidString)")
        let domain = "BotChu.InboxPageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fox", emoji: "🦊", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let folder = InboxFolder(home: BotHome(workspace: bot.workspace))
        let first = Delivery(botID: bot.id, title: "First", sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -60)))
        let second = Delivery(botID: bot.id, title: "Second", sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -120)))
        let third = Delivery(botID: bot.id, title: "Third", sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -180)))
        for delivery in [first, second, third] { try folder.save(delivery, contents: [:]) }
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        for _ in 0..<100 where app.inbox.all.count < 3 { try await Task.sleep(for: .milliseconds(20)) }

        app.destination = .inbox
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InboxView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(app.inbox.selected == first.id)

        // The one being read, though it keeps its place while read, goes to Done: the next is read.
        app.inbox.selected = second.id
        try await Task.sleep(for: .milliseconds(100))
        app.inbox.setDone(second.id, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.isDone(second.id))
        #expect(app.inbox.selected == third.id && app.inbox.isReading(third.id))
        // The last one shown: the one before it; then none is left to read.
        app.inbox.setDone(third.id, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == first.id)
        app.inbox.setDone(first.id, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == nil)

        // A Done one chosen opens Done; moved to the Inbox, it stays the one read.
        app.inbox.selected = second.id
        try await Task.sleep(for: .milliseconds(100))
        app.inbox.setDone(second.id, false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!app.inbox.isDone(second.id))
        #expect(app.inbox.selected == second.id && app.inbox.isReading(second.id))
        // With Done open, Done keeps it chosen, in Done.
        app.inbox.setDone(second.id, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == second.id)
    }

    /// A question's choice answers it from the keyboard, once; the delivery is Done and its
    /// conversation opens. Its card in the chat offers the choices until then.
    @Test func aChoiceAnswersTheQuestionAndOpensItsConversation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-choice-\(UUID().uuidString)")
        let domain = "BotChu.InboxPageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fox", emoji: "🦊", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let asking = Delivery(botID: bot.id, title: "Which should I file?", note: "Two options.",
                              question: Delivery.Question(text: "Which?", choices: ["Answer first", "Hold, but say so"]))
        try InboxFolder(home: BotHome(workspace: bot.workspace)).save(asking, contents: [:])
        let settings = AppSettings(defaults: defaults)
        // The turn the answer starts runs nothing.
        settings.commands[bot.accountID] = "/usr/bin/true"
        let app = AppModel(store: store, settings: settings, openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        for _ in 0..<100 where app.inbox.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }

        let card = NSHostingView(rootView: DeliveryCard(id: asking.id, fallback: "").environment(app).frame(width: 520))
        let asked = card.fittingSize.height

        app.destination = .inbox
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InboxView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<250 where !app.inbox.isReading(asking.id) { try await Task.sleep(for: .milliseconds(20)) }
        window.layoutIfNeeded()
        #expect(app.inbox.isReading(asking.id))

        let command1 = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, characters: "1",
                                                     charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        #expect(window.performKeyEquivalent(with: command1))
        for _ in 0..<250 where !app.inbox.isDone(asking.id) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.inbox.isDone(asking.id) && app.inbox.state.isAnswered(asking))
        #expect(app.destination == nil && app.isShown(.home(bot.id)))
        #expect(app.thread(.home(bot.id)).filter { $0.delivery == asking.id && $0.role == .user }.map(\.text) == ["Answer first"])
        // Answered, the card's choices are gone.
        card.layoutSubtreeIfNeeded()
        #expect(card.fittingSize.height < asked - 20)
    }
}
