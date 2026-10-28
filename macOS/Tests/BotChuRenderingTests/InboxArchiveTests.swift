import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func archivedDeliveriesOpenFromCardsAndSearchAndCanMoveBackToInbox() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-archive-page-\(UUID())")
        let domain = "BotChu.InboxArchiveTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fox", emoji: "🦊", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let active = Delivery(botID: bot.id, title: "Current report")
        let archived = Delivery(botID: bot.id, title: "Earlier release", sentAt: Date(timeIntervalSinceNow: -3 * 86_400))
        let folder = InboxFolder(home: BotHome(workspace: bot.workspace))
        for delivery in [active, archived] { try folder.save(delivery, contents: [:]) }
        var state = InboxState()
        state.setDone(archived.id, true, at: Date(timeIntervalSinceNow: -2 * 86_400))
        try state.save(to: store.root)
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults),
                           usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") }, openRouterKey: { nil },
                           projectGitHub: ProjectGitHub { _, _ in await ProjectGitHub.command(["/usr/bin/false"], body: nil) },
                           openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        for _ in 0..<150 where !app.inbox.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.inbox.deliveries.count == 2 && app.inbox.listIndex.deliveries.count == 1)
        #expect(app.inbox.unfinishedCount == 1)

        // A card/notification selects the archived item before the Inbox's view appears.
        app.showDelivery(archived.id)
        let host = NSHostingView(rootView: InboxView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        func editors(_ view: NSView) -> [NSTextView] {
            ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors)
        }
        func fields(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        #expect(app.inbox.selected == archived.id && app.inbox.isReading(archived.id))
        #expect(!editors(host).isEmpty, "The archived delivery's reader and composer are visible")
        app.inbox.selected = active.id
        try await Task.sleep(for: .milliseconds(100))
        let search = try #require(fields(host).first { $0.placeholderString == "Search Inbox and archive" })
        search.stringValue = "Earlier release"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await Task.sleep(for: .milliseconds(200))
        #expect(app.inbox.selected == archived.id && app.inbox.isDone(archived.id))
        #expect(!editors(host).isEmpty)
        #expect(app.inbox.unfinishedCount == 1 && app.inbox.listIndex.deliveries.count == 1)

        // A query can find the same rows as before, while none is selected (for example after
        // Show Done). It still opens the first result even though the visible IDs didn't change.
        app.inbox.selected = nil
        try await Task.sleep(for: .milliseconds(100))
        search.stringValue = "release"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == archived.id)

        app.inbox.setDone(archived.id, false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == archived.id && app.inbox.listIndex.deliveries.count == 2)
        #expect(app.inbox.unfinishedCount == 2 && app.inbox.state[archived.id].doneAt == nil)
        app.inbox.setDone(archived.id, true)
        #expect(app.inbox.state[archived.id].doneAt != nil && app.inbox.listIndex.deliveries.count == 2)
        await app.storage.settle()
        #expect(InboxState.load(from: store.root)[archived.id].doneAt == app.inbox.state[archived.id].doneAt)
        #expect(folder.load().count == 2)
    }
}
