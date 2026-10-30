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
        #expect(app.inbox.unreadCount == 2 && app.inbox.unfinishedCount == 2)
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
        // Read, they are still not Done: the sidebar counts them (#189).
        #expect(app.inbox.unfinishedCount == 2)
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(!app.inbox.isReading(report.id))
    }

    /// Unresolved Needs input comes first, the rest stay newest first whatever their purpose, and
    /// reading every one files none of them (#217). Each row says its purpose, in colour while it
    /// waits on the owner.
    @Test func needsInputComesFirstAndReadingFilesNothing() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-purpose-\(UUID().uuidString)")
        let domain = "BotChu.InboxPageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fox", emoji: "🦊", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let folder = InboxFolder(home: BotHome(workspace: bot.workspace))
        func sent(_ minutes: Double) -> Date { Delivery.stamp(Date(timeIntervalSinceNow: -minutes * 60)) }
        let asking = Delivery(botID: bot.id, title: "Which?", question: Delivery.Question(text: "Which?", choices: ["A", "B"], recommended: "A"),
                              purpose: .needsInput, sentAt: sent(50))
        let review = Delivery(botID: bot.id, title: "Mockup", purpose: .review, sentAt: sent(10))
        let completed = Delivery(botID: bot.id, title: "Dashboard is live", note: "https://example.com/dash", purpose: .completed, sentAt: sent(20))
        let fyi = Delivery(botID: bot.id, title: "Found a leak", purpose: .fyi, sentAt: sent(30))
        for delivery in [asking, review, completed, fyi] { try folder.save(delivery, contents: [:]) }
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        for _ in 0..<100 where app.inbox.all.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.inbox.unfinishedCount == 4)

        // The question's label is in colour while it waits, grey once answered.
        func coloured(_ delivery: Delivery) -> Int {
            let view = NSHostingView(rootView: PurposeLabel(delivery: delivery).environment(app).padding(4))
            view.setFrameSize(view.fittingSize)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var count = 0
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.5 else { continue }
                    if colour.redComponent - colour.blueComponent > 0.3 { count += 1 }
                }
            }
            return count
        }
        #expect(coloured(asking) > 10)

        app.destination = .inbox
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InboxView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        // The oldest, but it needs input; then the rest newest first.
        #expect(app.inbox.selected == asking.id)
        let groups = InboxList.groups(app.inbox.all, state: app.inbox.state, now: .now)
        #expect(InboxList.shown(groups, showsDone: false) == [asking.id, review.id, completed.id, fyi.id])
        for delivery in [review, completed, fyi] {
            app.inbox.selected = delivery.id
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(app.inbox.unreadCount == 0 && app.inbox.unfinishedCount == 4)
        #expect([asking, review, completed, fyi].allSatisfy { !app.inbox.isDone($0.id) })
        #expect(app.inbox.awaitingInput(.home(bot.id)) == [asking.id])

        app.inbox.selected = asking.id
        try await Task.sleep(for: .milliseconds(80))
        #expect(app.inbox.reply("A", to: asking.id))
        for _ in 0..<250 where !app.inbox.isDone(asking.id) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.inbox.isDone(asking.id) && app.inbox.unfinishedCount == 3 && app.inbox.awaitingInput(.home(bot.id)).isEmpty)
        #expect(coloured(asking) == 0)
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
        #expect(app.inbox.isDone(second.id) && app.inbox.unfinishedCount == 2)
        #expect(app.inbox.selected == third.id && app.inbox.isReading(third.id))
        // The last one shown: the one before it; then none is left to read.
        app.inbox.setDone(third.id, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == first.id)
        app.inbox.setDone(first.id, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == nil && app.inbox.unfinishedCount == 0)

        // A Done one chosen opens Done; moved to the Inbox, it stays the one read.
        app.inbox.selected = second.id
        try await Task.sleep(for: .milliseconds(100))
        app.inbox.setDone(second.id, false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!app.inbox.isDone(second.id) && app.inbox.unfinishedCount == 1)
        #expect(app.inbox.selected == second.id && app.inbox.isReading(second.id))
        // With Done open, Done keeps it chosen, in Done.
        app.inbox.setDone(second.id, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.inbox.selected == second.id)
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

    /// Gmail's keys (#219): J/↓ and K/↑ read the next and previous delivery shown, skipping a closed
    /// Done; E files the one read as Done once and reads the next. None of them act while a reply is
    /// typed, a delivered page has the keyboard, a sheet is open or with a modifier, and an empty
    /// list is safe.
    @Test func gmailsKeysReadAndFileTheInboxButNeverWhileTyping() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-keys-\(UUID().uuidString)")
        let domain = "BotChu.InboxPageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let store = Store(root: root.appendingPathComponent("index"))
        let bot = Bot(name: "Fox", emoji: "🦊", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let folder = InboxFolder(home: BotHome(workspace: bot.workspace))
        func sent(_ minutes: Double) -> Date { Delivery.stamp(Date(timeIntervalSinceNow: -minutes * 60)) }
        let first = Delivery(botID: bot.id, title: "First", sentAt: sent(1))
        let second = Delivery(botID: bot.id, title: "Second", sentAt: sent(2))
        let third = Delivery(botID: bot.id, title: "Third", sentAt: sent(3))
        let html = Data("<!doctype html><title>Page</title><p>Mockup</p><input id=field>".utf8)
        let page = Delivery(botID: bot.id, title: "Page", files: [Delivery.File(name: "index.html", kind: .page, bytes: html.count)], sentAt: sent(4))
        let old = Delivery(botID: bot.id, title: "Old", sentAt: sent(5))
        for delivery in [first, second, third, old] { try folder.save(delivery, contents: [:]) }
        try folder.save(page, contents: ["index.html": html])
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        for _ in 0..<100 where app.inbox.all.count < 5 { try await Task.sleep(for: .milliseconds(20)) }
        app.inbox.setDone(old.id, true)

        app.destination = .inbox
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InboxView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(app.inbox.selected == first.id)

        func press(_ text: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeated: Bool = false) async throws {
            // Hardware arrow keys include Function and Numeric Pad flags.
            let arrow = code == 125 || code == 126
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: arrow ? flags.union([.function, .numericPad]) : flags,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
                                                      charactersIgnoringModifiers: text, isARepeat: repeated, keyCode: code))
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
            try await Task.sleep(for: .milliseconds(120))
        }
        func j() async throws { try await press("j", 38) }
        func k() async throws { try await press("k", 40) }
        func e(repeated: Bool = false) async throws { try await press("e", 14, repeated: repeated) }
        func found<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
            guard let view else { return nil }
            if let match = view as? T { return match }
            return view.subviews.lazy.compactMap { found(type, in: $0) }.first
        }

        // J/↓ and K/↑ walk the list as shown, reading each; at either end they stay.
        try await j()
        #expect(app.inbox.selected == second.id && !app.inbox.isUnread(second.id))
        try await press("\u{F701}", 125)
        #expect(app.inbox.selected == third.id && app.inbox.isReading(third.id))
        try await k()
        #expect(app.inbox.selected == second.id)
        try await press("\u{F700}", 126)
        try await k()
        #expect(app.inbox.selected == first.id)
        // Capitals (Caps Lock) too; past the last, the closed Done isn't entered.
        try await press("J", 38)
        try await j()
        try await j()
        try await j()
        #expect(app.inbox.selected == page.id)

        // With a modifier the keys are the app's.
        for (text, code, flags) in [("j", UInt16(38), NSEvent.ModifierFlags.command), ("k", 40, .shift), ("e", 14, .option), ("e", 14, .control)] {
            try await press(text, code, flags)
        }
        #expect(app.inbox.selected == page.id && !app.inbox.isDone(page.id))

        // A delivered page with the keyboard keeps its keys.
        var web: OfflinePage.WebView?
        for _ in 0..<100 where web == nil {
            web = found(OfflinePage.WebView.self, in: window.contentView)
            if web == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let pageView = try #require(web)
        #expect(window.makeFirstResponder(pageView))
        try await j()
        try await e()
        try await k()
        #expect(app.inbox.selected == page.id && !app.inbox.isDone(page.id))

        // Choosing a row (as a click does) gives the list the keys again.
        app.inbox.selected = first.id
        try await Task.sleep(for: .milliseconds(200))
        try await j()
        #expect(app.inbox.selected == second.id)

        // Typing a reply, the letters are the reply's.
        let composer = try #require(found(ComposerTextView.self, in: window.contentView))
        #expect(window.makeFirstResponder(composer))
        try await j()
        try await e()
        try await k()
        #expect(app.inbox.selected == second.id && !app.inbox.isDone(second.id))
        #expect(composer.string == "jek")
        composer.string = ""
        app.inbox.drafts[second.id] = nil

        // A sheet open: nothing.
        app.inbox.selected = first.id
        try await Task.sleep(for: .milliseconds(200))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet) { _ in }
        try await Task.sleep(for: .milliseconds(200))
        try await j()
        try await e()
        #expect(app.inbox.selected == first.id && !app.inbox.isDone(first.id))
        window.endSheet(sheet)
        try await Task.sleep(for: .milliseconds(200))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))

        // E files the one read, once, and the next is read; held down, it files no more.
        let unfinished = app.inbox.unfinishedCount
        try await e()
        #expect(app.inbox.isDone(first.id) && app.inbox.unfinishedCount == unfinished - 1)
        #expect(app.inbox.selected == second.id && app.inbox.isReading(second.id))
        try await e(repeated: true)
        #expect(!app.inbox.isDone(second.id) && app.inbox.selected == second.id)

        // On a Done one (which opens Done), E does nothing: it never moves one back.
        app.inbox.selected = old.id
        try await Task.sleep(for: .milliseconds(200))
        try await e()
        #expect(app.inbox.isDone(old.id) && app.inbox.selected == old.id)

        // With Done open, E still reads the next one not Done; after the last, none.
        app.inbox.selected = second.id
        try await Task.sleep(for: .milliseconds(200))
        try await e()
        #expect(app.inbox.selected == third.id)
        try await e()
        #expect(app.inbox.selected == page.id)
        try await e()
        #expect(app.inbox.selected == nil && app.inbox.unfinishedCount == 0)
        // Nothing left: the keys are safe.
        try await j()
        try await k()
        try await e()
        #expect(app.inbox.selected == nil && app.inbox.unfinishedCount == 0)
        #expect([first, second, third, page, old].allSatisfy { app.inbox.isDone($0.id) })
    }
}
