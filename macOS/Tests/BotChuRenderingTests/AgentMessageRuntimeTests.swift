import Foundation
import Testing
import BotChuCore
@testable import BotChu

/// A bot messages a remote queue bot with `botchu-message send`; the remote bot's reply, over the
/// queue's HTTP endpoint, comes back into the conversation that sent it, once, and starts a turn.
extension RenderingTests {
    @Test func aBotMessagesARemoteBotAndItsReplyComesBackIntoTheConversation() async throws {
        let fixture = try AgentMessageFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app, home = ChatTarget.home(fixture.fox.id)
        let token = "fixture-token-for-agent-messages"
        app.remoteQueue.readToken = { token }
        app.remoteQueue.saveToken = { _ in true }
        fixture.settings.remoteQueuePort = Int(try remoteTestAvailablePort())
        var danny = Bot(name: "Danny", workspace: "")
        danny.kind = .remoteQueue
        app.create(danny)
        let dannyHome = ChatTarget.home(danny.id)
        fixture.settings.remoteQueueEnabled = true
        app.remoteQueue.restart()
        try await fixture.wait { app.remoteQueue.servingURL != nil }
        let base = try #require(app.remoteQueue.servingURL)

        app.send("MESSAGE_DANNY", to: home)
        try await fixture.wait { !app.isRunning(home) && app.thread(home).contains { $0.role == .assistant } }
        let sent = try #require(app.thread(home).last { $0.role == .assistant }?.text)
        #expect(sent.contains("Sent to Danny. Its reply will arrive in this conversation"), "\(sent)")
        // Danny's Home shows it as Fox's, not the owner's.
        let asked = try #require(app.thread(dannyHome).first)
        #expect(asked.text == "Is the roster final?" && asked.fromAgent?.botID == fixture.fox.id && asked.fromAgent?.name == "Fox")
        #expect(asked.documents.map(\.name) == ["roster.pdf"])

        let next = try await agentCurl(base + "/v1/queue/next", token: token)
        let message = try #require(JSONSerialization.jsonObject(with: next.body) as? [String: Any])
        #expect((message["from"] as? [String: Any])?["name"] as? String == "Fox")
        let id = try #require(message["id"] as? String)
        let fileID = try #require((message["files"] as? [[String: Any]])?.first?["id"] as? String)
        #expect(try await agentCurl(base + RemoteQueueEndpoint.filesPath + fileID, token: token).body == Data("%PDF draft".utf8))
        let reply = try JSONSerialization.data(withJSONObject: ["id": id, "text": "Final, with one change.",
            "files": [["name": "roster-final.pdf", "type": "application/pdf", "data": Data("%PDF final".utf8).base64EncodedString()]]])
        #expect(try await agentCurl(base + "/v1/queue/reply", token: token, body: reply).status == 200)

        // Into Fox's Home as Danny's, which Fox reads with its file's path, in a turn of its own.
        try await fixture.wait { app.thread(home).contains { $0.text.hasPrefix("GOT-DANNY") } && !app.isRunning(home) }
        let arrived = try #require(app.thread(home).first { $0.fromAgent?.botID == danny.id })
        #expect(arrived.role == .user && arrived.text == "Final, with one change.")
        #expect(arrived.fromAgent?.messageID?.uuidString.lowercased() == id.lowercased())
        let document = try #require(arrived.documents.first)
        let copy = try #require(app.fileURL(document, for: home))
        #expect(copy.path.hasPrefix(BotHome(workspace: fixture.fox.workspace).url.path))
        #expect(try Data(contentsOf: copy) == Data("%PDF final".utf8))
        let answer = try #require(app.thread(home).last { $0.role == .assistant }?.text)
        #expect(answer == "GOT-DANNY \(id.lowercased()) FILE-OK", "\(answer)")

        // Reconciling again, as after a relaunch, hands it over no second time.
        await app.remoteQueue.reconcile()
        try await Task.sleep(for: .milliseconds(200))
        #expect(app.thread(home).filter { $0.fromAgent?.botID == danny.id }.count == 1)
        fixture.settings.remoteQueueEnabled = false
    }
}

@MainActor private final class AgentMessageFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-agent-message-\(UUID().uuidString)")
    let domain = "local.BotChu.AgentMessageTests.\(UUID().uuidString)"
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
    import json, os, re, subprocess, sys
    def emit(value): print(json.dumps(value), flush=True)
    prompt = sys.argv[-1]
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    reply = re.search(r"\[Danny, a remote agent, replied to your message \(([0-9a-f-]+)\)", prompt)
    if reply:
        paths = re.findall(r"^- (/.*)$", prompt, re.M)
        answer = "GOT-DANNY " + reply.group(1) + (" FILE-OK" if paths and all(os.path.exists(p) for p in paths) else " NO-FILE")
    elif prompt.splitlines()[-1] == "MESSAGE_DANNY":
        with open("roster.pdf", "w") as handle: handle.write("%PDF draft")
        result = subprocess.run(["botchu-message", "send", "--agent", "Danny", "--text", "Is the roster final?", "--file", "roster.pdf"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        answer = result.stdout + result.stderr
    else:
        answer = "Done"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}

private func agentCurl(_ url: String, token: String, body: Data? = nil) async throws -> (status: Int, body: Data) {
    try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["--silent", "--show-error", "--max-time", "10", "--write-out", "\n%{http_code}", "--header", "Authorization: Bearer \(token)"]
        let input = Pipe(), output = Pipe()
        if body != nil { arguments += ["--header", "Content-Type: application/json", "--data-binary", "@-"] }
        arguments.append(url)
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        if let body { try input.fileHandleForWriting.write(contentsOf: body) }
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let newline = data.lastIndex(of: 10), let status = Int(String(decoding: data[data.index(after: newline)...], as: UTF8.self)) else {
            throw CocoaError(.fileReadUnknown)
        }
        return (status, Data(data[..<newline]))
    }.value
}
