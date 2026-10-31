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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-offline-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("delivery")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = try OfflinePageListener()
        defer { listener.stop() }
        try "window.sibling = true".write(to: folder.appendingPathComponent("sibling.js"), atomically: true, encoding: .utf8)
        try "window.outside = true".write(to: root.appendingPathComponent("outside.js"), atomically: true, encoding: .utf8)
        let page = folder.appendingPathComponent("index.html")
        try """
            <!doctype html><title>Sample</title>
            <script src="sibling.js"></script>
            <script src="../outside.js" onerror="window.outsideBlocked = true"></script>
            <script>
            window.attempts = []; window.errors = [];
            const pending = [];
            for (const host of ['127.0.0.1', 'localhost']) {
                const base = 'http://' + host + ':\(listener.port)/';
                function attempt(api, action) {
                    attempts.push(host + ':' + api);
                    pending.push(new Promise(resolve => {
                        try { action(resolve); } catch (error) { errors.push(api + ": " + error); resolve(); }
                    }));
                }
                attempt('fetch', done => fetch(base + 'fetch', {mode: 'no-cors'}).then(done, done));
                for (const [tag, api] of [['img', 'image'], ['script', 'script'], ['link', 'stylesheet'], ['iframe', 'frame']]) {
                    attempt(api, done => {
                        const element = document.createElement(tag);
                        element.onload = element.onerror = done;
                        if (tag === 'link') { element.rel = 'stylesheet'; element.href = base + api; }
                        else element.src = base + api;
                        document.head.appendChild(element);
                        // WebKit emits neither load nor error for a blocked subframe.
                        if (tag === 'iframe') done();
                    });
                }
                attempt('beacon', done => { navigator.sendBeacon(base + 'beacon', 'probe'); done(); });
                attempt('websocket', done => {
                    const socket = new WebSocket('ws://' + host + ':\(listener.port)/socket');
                    socket.onopen = () => { socket.close(); done(); };
                    socket.onerror = socket.onclose = done;
                });
            }
            // Resource completion also gives fire-and-forget beacons a turn through WebKit's loader.
            Promise.all(pending).then(() => setTimeout(() => { window.finished = true; }, 20));
            </script>
            """.write(to: page, atomically: true, encoding: .utf8)
        let compiled = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BotChuInboxOfflineTest",
                                                                                          encodedContentRuleList: OfflinePage.rules)
        let rules = try #require(compiled)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { view.stopLoading() }
        func finished(control: Bool = false) async throws {
            let ready = control ? "window.outside === true && window.attempts.length === 14 && window.errors.length === 0"
                                : "window.finished === true"
            for _ in 0..<100 {
                if (try? await view.evaluateJavaScript(ready)) as? Bool == true,
                   !control || listener.connections > 0 { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("The local page's resource probes did not finish")
        }
        view.loadFileURL(page, allowingReadAccessTo: folder)
        try await finished()
        #expect(try await view.evaluateJavaScript("window.sibling === true") as? Bool == true)
        #expect(try await view.evaluateJavaScript("window.outsideBlocked === true && window.outside !== true") as? Bool == true)
        #expect(try await view.evaluateJavaScript("window.attempts.length") as? Int == 14)
        #expect(try await view.evaluateJavaScript("JSON.stringify(window.errors)") as? String == "[]")
        #expect(listener.connections == 0, "No network connection may escape the delivered page")

        // The identical page, without the rule list: the listener must observe real connections.
        // Broadening only this control's file access proves the outside script itself is valid.
        configuration.userContentController.removeAllContentRuleLists()
        _ = try await view.evaluateJavaScript("window.finished = false")
        view.loadFileURL(page, allowingReadAccessTo: root)
        // A real accepted connection proves this control; waiting for all its HTTP responses
        // would test the server, not the blocker, and needlessly lengthen this security check.
        try await finished(control: true)
        #expect(listener.connections > 0, "The negative control must reach the loopback listener, even offline")
        #expect(try await view.evaluateJavaScript("window.outside === true") as? Bool == true)
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
        var first = Delivery(botID: bot.id, title: "First", purpose: .needsInput, sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -60)))
        var second = Delivery(botID: bot.id, title: "Second", purpose: .needsInput, sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -120)))
        let third = Delivery(botID: bot.id, title: "Third", sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -180)))
        first.note = String(repeating: "A long delivery note.\n\n", count: 60)
        second.note = first.note
        first.files = [.init(name: "index.html", kind: .page, bytes: 64)]
        second.files = first.files
        for delivery in [first, second, third] {
            try folder.save(delivery, contents: ["index.html": Data("<title>\(delivery.title)</title><p>\(delivery.title)</p>".utf8)])
        }
        let app = AppModel(store: store, settings: AppSettings(defaults: defaults), openRouterKey: { nil }, projectGitHub: ProjectGitHub { _, _ in
            await ProjectGitHub.command(["/usr/bin/false"], body: nil)
        }, openWorkLookup: { _ in .success(GitHubLookup.OpenWork(items: [])) })
        defer { app.stopAll() }
        for _ in 0..<100 where app.inbox.all.count < 3 { try await Task.sleep(for: .milliseconds(20)) }

        app.destination = .inbox
        app.inbox.drafts[first.id] = "First draft"
        app.inbox.drafts[second.id] = "Second draft"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InboxView().environment(app).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(app.inbox.selected == first.id && !app.inbox.isUnread(first.id) && app.inbox.isUnread(second.id))

        func editor(in view: NSView) -> ComposerTextView? {
            (view as? ComposerTextView) ?? view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
        }
        let contents = try #require(window.contentView)
        let readerScroll = try #require(descendants(contents, as: NSScrollView.self).first {
            !($0 is ComposerScrollView) && $0.bounds.width > 500 && ($0.documentView?.bounds.height ?? 0) > 1_000
        })
        let firstPage = try #require(descendants(contents, as: WKWebView.self).first)
        let reply = try #require(window.contentView.flatMap { editor(in: $0) })
        let previousResponder = window.firstResponder
        window.makeFirstResponder(reply)
        reply.insertText(" edited", replacementRange: NSRange(location: reply.string.utf16.count, length: 0))
        #expect(app.inbox.drafts[first.id] == "First draft edited")
        #expect(reply.undoManager?.canUndo == true)
        window.makeFirstResponder(previousResponder)
        readerScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        readerScroll.reflectScrolledClipView(readerScroll.contentView)
        #expect(readerScroll.contentView.bounds.minY > 400)
        let derivations = app.inbox.statusDerivations
        let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))
        window.sendEvent(e)
        // Filed, the next chosen and read, all before SwiftUI updates the Inbox: one change each.
        #expect(app.inbox.isDone(first.id) && app.inbox.selected == second.id && !app.inbox.isUnread(second.id))
        #expect(app.inbox.statusDerivations == derivations + 1)
        try await Task.sleep(for: .milliseconds(200))
        // Drawn, nothing more changes: what `onChange` reads again is read already.
        #expect(app.inbox.statusDerivations == derivations + 1)
        #expect(app.inbox.selected == second.id && app.inbox.isReading(second.id) && app.inbox.unfinishedCount == 2)
        #expect(window.contentView.flatMap { editor(in: $0) } === reply, "Changing delivery retains the native editor")
        #expect(reply.string == "Second draft" && reply.undoManager?.canUndo == false)
        #expect(reply.selectedRange() == NSRange(location: 0, length: 0))
        #expect(abs(readerScroll.contentView.bounds.minY) < 1, "A new delivery starts at the top, including its padding")
        let secondPage = try #require(descendants(contents, as: WKWebView.self).first)
        #expect(secondPage !== firstPage, "Page state must not survive a different delivery with the same filename")
        for _ in 0..<100 where secondPage.title != "Second" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(secondPage.title == "Second" && secondPage.url == folder.fileURL("index.html", of: second.id))
        #expect(app.inbox.drafts[first.id] == "First draft edited")

        // Switch away during an input-method composition: both the old text and the new binding
        // stay with their own delivery, and the new editor has no old marked text or undo actions.
        window.makeFirstResponder(reply)
        reply.setMarkedText("二", selectedRange: NSRange(location: 1, length: 0),
                            replacementRange: NSRange(location: reply.string.utf16.count, length: 0))
        #expect(reply.hasMarkedText())
        let composed = reply.string
        app.inbox.selected = third.id
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.contentView.flatMap { editor(in: $0) } === reply)
        #expect(!reply.hasMarkedText() && reply.string.isEmpty && reply.undoManager?.canUndo == false)
        #expect(app.inbox.drafts[second.id] == composed)
        #expect(app.inbox.drafts[first.id] == "First draft edited")
        #expect(window.firstResponder !== reply)
        window.makeFirstResponder(reply)
        reply.insertText("Third draft", replacementRange: NSRange(location: 0, length: 0))
        #expect(app.inbox.drafts[third.id] == "Third draft" && app.inbox.drafts[second.id] == composed)

        // Equal text still starts a different draft: retain the TextKit contents, but reset its
        // selection and undo history even when the unfocused editor needs no input-method work.
        app.inbox.drafts[second.id] = "Third draft"
        reply.setSelectedRange(NSRange(location: 3, length: 2))
        window.makeFirstResponder(previousResponder)
        app.inbox.selected = second.id
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.contentView.flatMap { editor(in: $0) } === reply && reply.string == "Third draft")
        #expect(reply.selectedRange() == NSRange(location: 0, length: 0) && reply.undoManager?.canUndo == false)
        #expect(app.inbox.drafts[third.id] == "Third draft")

        // A stale Done action can still read its intended successor. Missing deliveries and an
        // entirely unchanged action must neither fabricate entries nor derive/persist status.
        app.inbox.markRead(third.id, false)
        let beforeReadOnly = app.inbox.statusDerivations
        app.inbox.setDone(first.id, true, reading: third.id)
        #expect(!app.inbox.isUnread(third.id) && app.inbox.statusDerivations == beforeReadOnly + 1)
        app.inbox.setDone(first.id, true, reading: third.id)
        app.inbox.setDone(first.id, true, reading: UUID())
        #expect(app.inbox.statusDerivations == beforeReadOnly + 1)
        app.inbox.markRead(third.id, false)
        let beforeMissing = app.inbox.statusDerivations
        app.inbox.setDone(UUID(), true, reading: third.id)
        #expect(!app.inbox.isUnread(third.id) && app.inbox.statusDerivations == beforeMissing + 1)

    }
}

/// Counts accepted TCP connections, before HTTP or CORS can hide a request from the page.
/// Bound only to loopback; every accepted connection gets a small response and closes promptly.
private final class OfflinePageListener: @unchecked Sendable {
    let port: UInt16
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var accepted = 0
    var connections: Int { lock.lock(); defer { lock.unlock() }; return accepted }

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw CocoaError(.fileReadUnknown) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(socket, 64) == 0 else {
            Darwin.close(socket); throw CocoaError(.fileReadUnknown)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { Darwin.close(socket); throw CocoaError(.fileReadUnknown) }
        port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(socket, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: DispatchQueue(label: "BotChu.offline-page-probe"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = Darwin.accept(socket, nil, nil)
                guard client >= 0 else { break }
                self.lock.lock(); self.accepted += 1; self.lock.unlock()
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                let response = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                response.withCString { _ = Darwin.send(client, $0, strlen($0), 0) }
                Darwin.close(client)
            }
        }
        source.setCancelHandler { Darwin.close(socket) }
        source.resume()
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }
}
