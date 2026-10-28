import AppKit
import Foundation
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// A bot asks for a key with `botchu-secret ask` (#266): BotChu shows a popup, and what the owner
/// pastes is put in the bot's .env without entering the conversation; Cancel tells the bot so.
extension RenderingTests {
    @Test func aBotAsksForAKeyAndWhatIsPastedNeverEntersTheConversation() async throws {
        let fixture = try SecretPromptFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        var shown: [UUID?] = []
        app.secrets.present = { shown.append($0?.id) }

        app.send("ASK_SECRET", to: home)
        try await fixture.wait { app.secrets.current != nil }
        let prompt = try #require(app.secrets.current)
        #expect(prompt.request.title == "Stripe sandbox key" && prompt.request.note == "For test mode")
        #expect(prompt.botName == "Fox" && prompt.conversation == "Home")
        let env = URL(fileURLWithPath: fixture.fox.workspace).appendingPathComponent(".env")
        #expect(prompt.request.destinations.count == 1)
        if case .env(let name, let path) = prompt.request.destinations.first {
            #expect(name == "STRIPE_KEY" && path.hasSuffix("/fox/.env"))
        } else { Issue.record("Not an .env destination: \(prompt.request.destinations)") }
        #expect(shown == [prompt.id])
        // The popup lays out at its width, with the field and the destination in it.
        let view = NSHostingView(rootView: SecretPromptView(prompt: prompt).environment(app))
        #expect(view.fittingSize.width == 440 && view.fittingSize.height > 120)

        #expect(!app.secrets.save(prompt.id, value: "  \n"))
        #expect(app.secrets.save(prompt.id, value: " sk_test_runtime_123\n"))
        #expect(app.secrets.current == nil && shown == [prompt.id, nil])
        try await fixture.wait { !app.isRunning(home) && app.thread(home).contains { $0.role == .assistant } }
        #expect(try String(contentsOf: env, encoding: .utf8) == "STRIPE_KEY=sk_test_runtime_123\n")
        let reply = try #require(app.thread(home).last { $0.role == .assistant }?.text)
        #expect(reply.contains("Your owner pasted Stripe sandbox key; it was saved without being shown here, to:"), "\(reply)")
        #expect(!app.thread(home).contains { $0.text.contains("sk_test_runtime") })
        // Nor in any file BotChu keeps: transcripts, logs, the mailbox; only in the .env.
        #expect(!folderContains(fixture.root, "sk_test_runtime", except: env))

        // Cancelled, it says so, and nothing changes.
        app.send("ASK_SECRET", to: home)
        try await fixture.wait { app.secrets.current != nil }
        app.secrets.cancel(try #require(app.secrets.current).id)
        try await fixture.wait { !app.isRunning(home) && app.thread(home).filter { $0.role == .assistant }.count == 2 }
        #expect(app.thread(home).last?.text.contains("Your owner cancelled: nothing was saved for Stripe sandbox key.") == true)
        #expect(try String(contentsOf: env, encoding: .utf8) == "STRIPE_KEY=sk_test_runtime_123\n")
    }

    /// A turn that ends while its popup waits takes the popup with it.
    @Test func aSecretPromptClosesWhenItsTurnEnds() async throws {
        let fixture = try SecretPromptFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        app.secrets.present = { _ in }
        app.send("ASK_SECRET", to: home)
        try await fixture.wait { app.secrets.current != nil }
        app.stop(home)
        try await fixture.wait { app.secrets.current == nil && !app.isRunning(home) }
    }
}

private func folderContains(_ folder: URL, _ text: String, except: URL) -> Bool {
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
    for case let file as URL in files where file.standardizedFileURL != except.standardizedFileURL
        && (try? Data(contentsOf: file))?.range(of: Data(text.utf8)) != nil { return true }
    return false
}

@MainActor private final class SecretPromptFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-secret-prompt-\(UUID().uuidString)")
    let domain = "local.BotChu.SecretPromptTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let fox: Bot
    let app: AppModel

    init() throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        fox = Bot(name: "Fox", accountID: "codex-dev", workspace: root.appendingPathComponent("fox").path)
        try BotHome(workspace: fox.workspace).save(fox)
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        settings.commands[fox.accountID] = "/usr/bin/python3 \(Shell.quote(script.path))"
        try store.saveIndex([Store.Entry(id: fox.id, workspace: fox.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
    }

    func wait(seconds: Int = 30, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 40) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out: \(app.thread(.home(fox.id)).map(\.text))")
        throw CocoaError(.executableLoad)
    }

    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, subprocess, sys
    def emit(value): print(json.dumps(value), flush=True)
    prompt = sys.argv[-1]
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if prompt.splitlines()[-1] == "ASK_SECRET":
        result = subprocess.run(["botchu-secret", "ask", "--title", "Stripe sandbox key", "--note", "For test mode",
                                 "--name", "STRIPE_KEY", "--env-file", ".env"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        answer = result.stdout + result.stderr
    else:
        answer = "Done"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}
