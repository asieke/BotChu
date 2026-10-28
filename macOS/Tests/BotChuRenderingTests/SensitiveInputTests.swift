import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func sensitiveInputSavesOnlyAtApprovedDestinationAndCancelsWithTurn() async throws {
        let fixture = try SensitiveInputFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.bot.id)
        let runtime = app.delegation.sensitiveInput
        runtime.present = { _ in }
        app.send("ASK_SECRET", to: home)
        try await fixture.wait { runtime.current != nil }
        let prompt = try #require(runtime.current)
        #expect(prompt.botName == "Fox" && prompt.request.label == "Test service key")
        #expect(prompt.request.destination == fixture.destination.path)
        let secret = "synthetic-private-value-266"
        try await runtime.submit(secret, id: prompt.id)
        try await fixture.wait { !app.isRunning(home) }
        await app.storage.settle()
        #expect(runtime.current == nil)
        #expect(try String(contentsOf: fixture.destination, encoding: .utf8) == secret)
        #expect(app.thread(home).last?.text.contains("Sensitive input: saved.") == true)
        #expect(!app.thread(home).contains { $0.text.contains(secret) })
        let files = try #require(FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files where file != fixture.destination {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                #expect((try Data(contentsOf: file)).range(of: Data(secret.utf8)) == nil)
            }
        }
        try FileManager.default.removeItem(at: fixture.destination)
        app.send("ASK_SECRET", to: home)
        try await fixture.wait { runtime.current != nil }
        runtime.finish(try #require(runtime.current).id)
        try await fixture.wait { !app.isRunning(home) }
        #expect(app.thread(home).last?.text.contains("Sensitive input: cancelled.") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        app.send("ASK_SECRET", to: home)
        try await fixture.wait { runtime.current != nil }
        app.stop(home)
        try await fixture.wait { runtime.current == nil && !app.isRunning(home) }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test func sensitiveInputPopupUsesSecureFieldAndDropsValueWhenClosed() async throws {
        _ = NSApplication.shared
        let runtime = SensitiveInputRuntime()
        let request = SensitiveInputRequest(invocationID: UUID(), callerBotID: UUID(), label: "Test key",
            destination: "/private/tmp/botchu-unused-test-value")
        var receipt: SensitiveInputResult.Status?
        runtime.enqueue(request, botName: "Fox") { receipt = $0 }
        let panel = try #require(NSApp.windows.first { $0.identifier?.rawValue == "sensitive-input" && $0.contentView != nil })
        defer { runtime.finish(request.id) }
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func secureField(_ view: NSView) -> NSSecureTextField? {
            if let field = view as? NSSecureTextField { return field }
            return view.subviews.compactMap(secureField).first
        }
        let content = try #require(panel.contentView)
        let field = try #require(secureField(content))
        #expect(panel is NSPanel && (panel as? NSPanel)?.isFloatingPanel == true)
        #expect(panel.sharingType == .none)
        #expect(field.stringValue.isEmpty)
        panel.performClose(nil)
        #expect(runtime.current == nil && receipt == .cancelled)
        #expect(panel.contentView == nil)
    }

    @Test(arguments: [false, true]) func sensitiveInputCancellationReportsWhetherWriterCommitted(committed: Bool) async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SensitiveInputWriteGate(committed: committed)
        let runtime = SensitiveInputRuntime(write: gate.write)
        runtime.present = { _ in }
        let request = SensitiveInputRequest(invocationID: UUID(), callerBotID: UUID(), label: "Fixture",
            destination: root.appendingPathComponent("value").path)
        var receipt: SensitiveInputResult.Status?
        runtime.enqueue(request, botName: "Fox") { receipt = $0 }
        let submission = Task { try await runtime.submit("synthetic-value", id: request.id) }
        defer { gate.release.signal(); submission.cancel() }
        for _ in 0..<200 {
            if gate.entered.wait(timeout: .now()) == .success { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(runtime.saving.contains(request.id))
        runtime.finish(request.id)
        #expect(runtime.current == nil && receipt == nil)
        gate.release.signal()
        try await submission.value
        #expect(receipt == (committed ? .saved : .cancelled))
        #expect(FileManager.default.fileExists(atPath: request.destination) == committed)
    }

    @Test func sensitiveInputQueueExpiresAndNeverDeliversAfterCancellation() async throws {
        let runtime = SensitiveInputRuntime()
        runtime.present = { _ in }
        let invocation = UUID()
        let request = SensitiveInputRequest(invocationID: invocation, callerBotID: UUID(), label: "Test key",
            destination: "/private/tmp/botchu-unused-test-value", createdAt: Date().addingTimeInterval(-300))
        var receipt: SensitiveInputResult.Status?
        runtime.enqueue(request, botName: "Fox") { receipt = $0 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runtime.current == nil && receipt == .expired)
        await #expect(throws: SensitiveInputError.self) { try await runtime.submit("fixture", id: request.id) }
        var active = request
        active.id = UUID(); active.createdAt = Date()
        runtime.enqueue(active, botName: "Fox") { receipt = $0 }
        runtime.cancel(active.id, invocationID: UUID())
        #expect(runtime.current?.id == active.id)
        runtime.cancel(invocationID: invocation)
        #expect(receipt == .cancelled && runtime.current == nil)
        // Separate envelopes may be sorted with cancellation first; admission must still refuse it.
        active.id = UUID()
        runtime.cancel(active.id, invocationID: invocation)
        runtime.enqueue(active, botName: "Fox") { receipt = $0 }
        #expect(receipt == .cancelled && runtime.current == nil)
        await #expect(throws: SensitiveInputError.self) { try await runtime.submit("fixture", id: active.id) }
    }
}

@MainActor private final class SensitiveInputFixture {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("botchu-sensitive-\(UUID().uuidString)")
    let domain = "local.BotChu.SensitiveInputTests.\(UUID().uuidString)"
    let bot: Bot
    let app: AppModel
    var destination: URL { root.appendingPathComponent("value") }

    init() throws {
        let store = Store(root: root.appendingPathComponent("index"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        bot = Bot(name: "Fox", accountID: "codex-dev", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: bot.workspace).save(bot)
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(script.path))"
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") })
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CocoaError(.executableLoad)
    }

    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, pathlib, subprocess, sys
    def emit(value): print(json.dumps(value), flush=True)
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if sys.argv[-1].splitlines()[-1] == "ASK_SECRET":
        result = subprocess.run(["botchu-secret", "request", "--label", "Test service key",
            "--destination", str(pathlib.Path(__file__).parent / "value")],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        answer = result.stdout + result.stderr
    else:
        answer = "Done"
    emit({"type":"item.completed", "item":{"id":"answer", "type":"agent_message", "text":answer}})
    emit({"type":"turn.completed", "usage":{"input_tokens":1, "output_tokens":1}})
    """#
}

private final class SensitiveInputWriteGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let committed: Bool
    init(committed: Bool) { self.committed = committed }
    func write(_ value: String, _ destination: String) throws {
        #expect(!Thread.isMainThread)
        if committed { try SensitiveInputDestination.save(value, to: destination) }
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
        if !committed { try SensitiveInputDestination.save(value, to: destination) }
    }
}
