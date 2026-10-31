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

    /// Done from the Inbox reads the next delivery in the same change (#356), before the Inbox is
    /// drawn again: no step is left for an `onChange` to make, each of which drew the whole Inbox
    /// once more before the frame that shows Done.
    @Test func doneReadsTheNextDeliveryInTheSameChange() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-done-change-\(UUID().uuidString)")
        let domain = "BotChu.InboxPageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fox", emoji: "🦊", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let folder = InboxFolder(home: BotHome(workspace: bot.workspace))
        let first = Delivery(botID: bot.id, title: "First", purpose: .needsInput, sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -60)))
        let second = Delivery(botID: bot.id, title: "Second", purpose: .needsInput, sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -120)))
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
        #expect(app.inbox.selected == first.id && !app.inbox.isUnread(first.id) && app.inbox.isUnread(second.id))

        let derivations = app.inbox.statusDerivations
        let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
        window.sendEvent(e)
        // Filed, the next chosen and read, all before SwiftUI updates the Inbox: one change each.
        #expect(app.inbox.isDone(first.id) && app.inbox.selected == second.id && !app.inbox.isUnread(second.id))
        #expect(app.inbox.statusDerivations == derivations + 2)
        try await Task.sleep(for: .milliseconds(200))
        // Drawn, nothing more changes: what `onChange` reads again is read already.
        #expect(app.inbox.statusDerivations == derivations + 2)
        #expect(app.inbox.selected == second.id && app.inbox.isReading(second.id) && app.inbox.unfinishedCount == 2)
    }
}
