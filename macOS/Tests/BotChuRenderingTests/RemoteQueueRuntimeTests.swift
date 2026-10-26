import Foundation
import AppKit
import SwiftUI
import Vision
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func remoteQueueViewsOmitLocalControlsAndShowConnectionSettings() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-remote-ui-\(UUID())")
        let domain = "local.BotChu.RemoteViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let app = AppModel(store: Store(root: root), settings: AppSettings(defaults: defaults), usage: UsageCache { _, _ in throw UsageFailure("fixture") }, openRouterKey: { nil })
        defer { app.stopAll() }
        var reads = 0
        app.remoteQueue.readToken = { reads += 1; return nil }
        var bot = Bot(name: "Danny fixture", workspace: "")
        bot.kind = .remoteQueue
        app.create(bot)
        bot = try #require(app.bot(bot.id))
        let views: [(AnyView, String)] = [
            (AnyView(NavigationStack { ChatView(target: .home(bot.id)).modifier(ChatToolbar()) }.environment(app)), "Message Danny fixture"),
            (AnyView(BotEditor(request: EditorRequest(bot: bot, isNew: false)).environment(app)), "Name"),
            (AnyView(BotInspector(botID: bot.id).environment(app)), "Remote queue bot"),
            (AnyView(Form { RemoteQueueSection() }.formStyle(.grouped).environment(app)), "Listen address")
        ]
        for (view, expected) in views {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 800),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            defer { window.contentView = nil; window.close() }
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).defaultAppStorage(defaults))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            // Let SwiftUI commit its first display. Its drawn text isn't consistently exposed
            // by in-process accessibility on supported macOS versions, so recognize the actual
            // fixture pixels as well as checking native controls and toolbar item labels.
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try image.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("remote-\(expected).png"))
            }
            let pixels = try #require(image.cgImage)
            let visible = try await Task.detached {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                return Set((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            }.value
            let labels = remoteLabels(window).union(visible)
            #expect(labels.contains(expected), "Rendered text and control labels: \(labels.sorted())")
            for absent in ["Account", "Model", "Workspace", "New Task", "New Session", "Attach images", "Model & Usage"] {
                #expect(!labels.contains(absent), "Remote view included local control: \(absent)")
            }
        }
        #expect(reads == 0)
    }

    @Test func remoteQueueCurlRoundTripIsDurableAndDoesNotRunALocalCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-remote-http-\(UUID())")
        let domain = "local.BotChu.RemoteQueueTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let settings = AppSettings(defaults: defaults)
        settings.remoteQueuePort = Int(try remoteTestAvailablePort())
        let usage = UsageCache { _, _ in throw UsageFailure("No usage in tests") }
        let app = AppModel(store: store, settings: settings, usage: usage, openRouterKey: { nil })
        defer { app.stopAll() }
        var fakeToken = "fixture-token-never-used-outside-this-test"
        app.remoteQueue.readToken = { fakeToken }
        app.remoteQueue.saveToken = { fakeToken = $0; return true }
        var bot = Bot(name: "Danny fixture", workspace: "")
        bot.kind = .remoteQueue
        app.create(bot)
        bot = try #require(app.bot(bot.id))
        let target = ChatTarget.home(bot.id)
        #expect(bot.workspace.isEmpty)
        #expect(bot.accountID.isEmpty)
        #expect(app.thread(target).isEmpty)
        #expect(!app.delegation.roster.contains { $0.id == bot.id })
        app.newTask(for: bot.id)
        app.jobs.newJob(for: bot.id)
        #expect(app.taskSheet == nil)
        #expect(app.jobs.editor == nil)
        settings.remoteQueueEnabled = true
        app.remoteQueue.restart()
        try await remoteEventually { app.remoteQueue.servingURL != nil }
        let base = try #require(app.remoteQueue.servingURL)
        #expect(try await remoteCurl(base + "/v1/health", token: nil).status == 401)
        #expect(try await remoteCurl(base + "/v1/queue/next", token: fakeToken).status == 204)
        #expect(app.remoteQueue.online)
        // Repeated observed/manual starts reuse the listener; rapid off/on waits for the old
        // port binding to finish cancelling before its replacement starts.
        app.remoteQueue.restart()
        app.remoteQueue.restart()
        #expect(app.remoteQueue.servingURL == base)
        settings.remoteQueueEnabled = false
        app.remoteQueue.restart()
        settings.remoteQueueEnabled = true
        app.remoteQueue.restart()
        try await remoteEventually { app.remoteQueue.servingURL == base }
        #expect(try await remoteCurl(base + "/v1/health", token: fakeToken).status == 200)
        let id = UUID()
        #expect(await app.sendAccepted("Reply with the word pineapple.", to: target, id: id))
        #expect(app.isRunning(target))
        let next = try await remoteCurl(base + "/v1/queue/next", token: fakeToken)
        #expect(next.status == 200)
        let received = try #require(JSONSerialization.jsonObject(with: next.body) as? [String: String])
        #expect(received["id"]?.lowercased() == id.uuidString.lowercased())
        #expect(received["text"] == "Reply with the word pineapple.")
        #expect(received["sent_at"] != nil)
        let answer = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "text": "pineapple"])
        #expect(try await remoteCurl(base + "/v1/queue/reply", token: fakeToken, body: answer).status == 200)
        #expect(try await remoteCurl(base + "/v1/queue/reply", token: fakeToken, body: answer).status == 200)
        #expect(app.thread(target).map(\.text) == ["Reply with the word pineapple.", "pineapple"])
        #expect(!app.isRunning(target))
        #expect(app.bot(bot.id)?.sessionID == nil)

        // A second message can fail remotely; it ends working and shows the error in Home.
        let failed = UUID()
        #expect(await app.sendAccepted("A turn that fails", to: target, id: failed))
        let error = try JSONSerialization.data(withJSONObject: ["id": failed.uuidString, "error": "Fixture remote failure"])
        #expect(try await remoteCurl(base + "/v1/queue/reply", token: fakeToken, body: error).status == 200)
        #expect(app.thread(target).last?.role == .error)
        #expect(app.thread(target).last?.text == "Fixture remote failure")
        #expect(!app.isRunning(target))

        let oldToken = fakeToken
        #expect(app.remoteQueue.regenerateToken())
        try await remoteEventually { app.remoteQueue.servingURL != nil }
        #expect(try await remoteCurl(base + "/v1/health", token: oldToken).status == 401)
        #expect(try await remoteCurl(base + "/v1/health", token: fakeToken).status == 200)
        #expect(app.thread(target).allSatisfy { !$0.text.contains(fakeToken) && !$0.text.contains(oldToken) })

        // Simulate a crash after the journal save but before Home's save, then recover the whole
        // conversation from the journal once. The pending message is offered again on relaunch.
        let pending = UUID()
        #expect(await app.sendAccepted("Still waiting", to: target, id: pending))
        settings.remoteQueueEnabled = false
        app.stopAll()
        let home = BotHome(workspace: bot.persistencePath)
        try home.saveThread([])
        let reopened = AppModel(store: store, settings: settings, usage: usage, openRouterKey: { nil })
        defer { reopened.stopAll() }
        reopened.remoteQueue.readToken = { fakeToken }
        await reopened.remoteQueue.reconcile()
        #expect(reopened.thread(target).map(\.text) == ["Reply with the word pineapple.", "pineapple", "A turn that fails", "Fixture remote failure", "Still waiting"])
        #expect(reopened.remoteQueue.pending == 1)
        await reopened.remoteQueue.reconcile()
        #expect(reopened.thread(target).count == 5)
        settings.remoteQueueEnabled = true
        reopened.remoteQueue.restart()
        try await remoteEventually { reopened.remoteQueue.servingURL != nil }
        let redelivered = try await remoteCurl(base + "/v1/queue/next", token: fakeToken)
        #expect((try JSONSerialization.jsonObject(with: redelivered.body) as? [String: String])?["id"]?.lowercased() == pending.uuidString.lowercased())
        settings.remoteQueueEnabled = false
    }

    @Test func remoteQueueCarriesDocumentsBothWaysOverHTTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-remote-files-\(UUID())")
        let domain = "local.BotChu.RemoteFileTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(defaults: defaults)
        settings.remoteQueuePort = Int(try remoteTestAvailablePort())
        let app = AppModel(store: Store(root: root), settings: settings, usage: UsageCache { _, _ in throw UsageFailure("fixture") }, openRouterKey: { nil })
        defer { app.stopAll() }
        let token = "fixture-token-for-files-only"
        app.remoteQueue.readToken = { token }
        app.remoteQueue.saveToken = { _ in true }
        var bot = Bot(name: "Danny fixture", workspace: "")
        bot.kind = .remoteQueue
        app.create(bot)
        let target = ChatTarget.home(bot.id)
        settings.remoteQueueEnabled = true
        app.remoteQueue.restart()
        try await remoteEventually { app.remoteQueue.servingURL != nil }
        let base = try #require(app.remoteQueue.servingURL)

        let source = root.appendingPathComponent("schedule.pdf")
        let pdf = Data("%PDF-1.7 fixture schedule".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try pdf.write(to: source)
        app.addFiles([source], to: target)
        let files = try #require(app.draftFiles[target])
        #expect(files.map(\.name) == ["schedule.pdf"])
        #expect(files.first?.type == "application/pdf")
        let sent: Bool = await withCheckedContinuation { continuation in
            if !app.send("", to: target, files: files, accepted: { continuation.resume(returning: $0) }) { continuation.resume(returning: false) }
        }
        #expect(sent)
        let next = try await remoteCurl(base + "/v1/queue/next", token: token)
        let message = try #require(JSONSerialization.jsonObject(with: next.body) as? [String: Any])
        let listed = try #require((message["files"] as? [[String: Any]])?.first)
        #expect(listed["name"] as? String == "schedule.pdf")
        let fileID = try #require(listed["id"] as? String)
        let download = try await remoteCurl(base + RemoteQueueEndpoint.filesPath + fileID, token: token)
        #expect(download.status == 200)
        #expect(download.body == pdf)
        #expect(try await remoteCurl(base + RemoteQueueEndpoint.filesPath + fileID, token: nil).status == 401)

        let roster = Data("%PDF-1.7 bald eagles roster".utf8)
        let reply = try JSONSerialization.data(withJSONObject: ["id": try #require(message["id"] as? String), "text": "Here's the roster.",
            "files": [["name": "bald-eagles-roster-2026-27.pdf", "type": "application/pdf", "data": roster.base64EncodedString()]]])
        #expect(try await remoteCurl(base + "/v1/queue/reply", token: token, body: reply).status == 200)
        let answer = try #require(app.thread(target).last)
        #expect(answer.role == .assistant)
        #expect(answer.text == "Here's the roster.")
        let received = try #require(answer.documents.first)
        #expect(received.name == "bald-eagles-roster-2026-27.pdf")
        #expect(try Data(contentsOf: try #require(app.fileURL(received, for: target))) == roster)
        #expect(try await remoteCurl(base + RemoteQueueEndpoint.filesPath + fileID, token: token).status == 404)
        settings.remoteQueueEnabled = false
    }

    @Test func remoteQueueFullShowsNoticeAndKeepsTheUnacceptedDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-remote-full-\(UUID())")
        let domain = "local.BotChu.RemoteFullTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let app = AppModel(store: Store(root: root), settings: AppSettings(defaults: defaults), usage: UsageCache { _, _ in throw UsageFailure("fixture") }, openRouterKey: { nil })
        defer { app.stopAll() }
        var bot = Bot(name: "Remote fixture", workspace: "")
        bot.kind = .remoteQueue
        app.create(bot)
        let target = ChatTarget.home(bot.id)
        for n in 0..<10 { #expect(await app.sendAccepted("Waiting \(n)", to: target)) }
        let accepted: Bool = await withCheckedContinuation { continuation in
            app.drafts[target] = "Eleventh"
            let started = app.send("Eleventh", to: target, accepted: { accepted in
                if !accepted { app.returnToDraft("Eleventh", references: [], images: [], in: target) }
                continuation.resume(returning: accepted)
            })
            if started { app.drafts[target] = nil }
            else { continuation.resume(returning: false) }
        }
        #expect(!accepted)
        #expect(app.drafts[target] == "Eleventh")
        #expect(app.thread(target).filter { $0.role == .user }.count == 10)
        #expect(app.thread(target).last?.text.contains("queue is full") == true)
        #expect(app.remoteQueue.pending == 10)
    }
}

@MainActor private func remoteEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(condition())
}

@MainActor private func remoteLabels(_ root: Any) -> Set<String> {
    var seen = Set<ObjectIdentifier>()
    var strings = Set<String>()
    func walk(_ value: Any) {
        guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted, seen.count < 3_000 else { return }
        func attribute(_ name: String) -> Any? {
            object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
        }
        for name in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityPlaceholderValue"] {
            if let text = attribute(name) as? String { strings.insert(text) }
            if let text = attribute(name) as? NSAttributedString { strings.insert(text.string) }
        }
        for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder"] {
            for child in attribute(name) as? [Any] ?? [] { walk(child) }
        }
        if let view = object as? NSView { view.subviews.forEach(walk) }
        if let window = object as? NSWindow {
            if let content = window.contentView { walk(content) }
            for item in window.toolbar?.items ?? [] {
                strings.insert(item.label)
                if let group = item as? NSToolbarItemGroup { for child in group.subitems { strings.insert(child.label) } }
            }
        }
    }

    walk(root)
    return strings
}

/// Exercise the actual socket and HTTP framing with curl. Tokens here are disposable fixtures;
/// neither this helper nor the production server prints request headers or response text.
private func remoteCurl(_ url: String, token: String?, body: Data? = nil) async throws -> (status: Int, body: Data) {
    try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["--silent", "--show-error", "--max-time", "10", "--write-out", "\n%{http_code}"]
        if let token { arguments += ["--header", "Authorization: Bearer \(token)"] }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        if body != nil { arguments += ["--header", "Content-Type: application/json", "--data-binary", "@-"] }
        arguments.append(url)
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        if let body { try input.fileHandleForWriting.write(contentsOf: body) }
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let newline = data.lastIndex(of: 10),
              let status = Int(String(decoding: data[data.index(after: newline)...], as: UTF8.self)) else {
            throw CocoaError(.fileReadUnknown)
        }
        return (status, Data(data[..<newline]))
    }.value
}
