import Foundation
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test(arguments: ["disabled", "removed", "remapped", "replaced", "stopped", "cancelled"])
    func telegramDeliveryChecksCurrentAuthorizationOnTheMainActor(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-telegram-boundary-\(UUID().uuidString)")
        let domain = "local.BotChu.TelegramBoundaryTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let store = Store(root: root.appendingPathComponent("index"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        let bot = Bot(name: "Fixture", accountID: "codex-dev", workspace: root.appendingPathComponent("bot").path)
        try BotHome(workspace: bot.workspace).save(bot)
        settings.commands[bot.accountID] = "/usr/bin/false"
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        defer { app.stopAll() }
        app.telegram.readToken = { "123:AAFakeTokenForTestsOnly" }
        app.telegram.transport = BridgeTelegramStandIn([])
        settings.telegramChats = [TelegramChat(id: 42, botID: bot.id)]
        settings.telegramEnabled = true
        app.telegram.restart()
        let connection = app.telegram.connection()
        switch change {
        case "disabled": settings.telegramEnabled = false
        case "removed": settings.telegramChats = []
        case "remapped": settings.telegramChats = [TelegramChat(id: 42, botID: UUID())]
        case "replaced": app.telegram.restart()
        case "stopped":
            connection.gatewayChanged(.stopped(reason: "Stopped by the fixture."))
            connection.gatewayChanged(.connected("late callback"))
        default: break
        }
        // Delivery was already fetched, but has not yet reached AppModel.send. This exercises
        // the real main-actor boundary even if the settings observer hasn't restarted it yet.
        if change == "cancelled" {
            let delivery = Task { await connection.deliver("must not run", references: [], id: UUID(), to: bot.id, from: 42, mapped: bot.id) }
            delivery.cancel()
            #expect(await delivery.value == .discarded)
        } else {
            #expect(await connection.deliver("must not run", references: [], id: UUID(), to: bot.id, from: 42, mapped: bot.id) == .discarded)
        }
        #expect(app.thread(.home(bot.id)).allSatisfy { $0.role != .user })
        #expect(app.messageQueues[.home(bot.id)]?.messages.isEmpty != false)
        #expect(!app.isRunning(.home(bot.id)))
        settings.telegramEnabled = false
    }

    /// #60: a message from the allowed Telegram chat runs a turn in its bot's Home (a stand-in CLI)
    /// and the reply goes back to that chat; a stranger gets nothing; the mapping and the offset
    /// survive a relaunch. Telegram is a stand-in too, and no Keychain is read.
    @Test func telegramMessageRunsAHomeTurnAndItsReplyGoesBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-telegram-\(UUID().uuidString)")
        let domain = "local.BotChu.TelegramBridgeTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let store = Store(root: root.appendingPathComponent("index"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        let bot = Bot(name: "Fixture", accountID: "codex-dev", workspace: root.appendingPathComponent("bot").path)
        try BotHome(workspace: bot.workspace).save(bot)
        let script = root.appendingPathComponent("cli.py")
        try #"""
        import json, sys
        def emit(value):
            print(json.dumps(value), flush=True)
        emit({"type": "thread.started", "thread_id": "telegram-session"})
        # Fresh sessions open with BotChu's context; the message is the prompt's last line.
        emit({"type": "item.completed", "item": {"type": "agent_message", "text": "reply:" + sys.argv[-1].splitlines()[-1]}})
        emit({"type": "turn.completed"})
        """#.write(to: script, atomically: true, encoding: .utf8)
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(script.path))"
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let usage = UsageCache { _, _ in throw UsageFailure("No allowance in tests.") }
        let app = AppModel(store: store, settings: settings, usage: usage)
        defer { app.stopAll() }
        #expect(app.telegram.state == .off)

        let telegram = BridgeTelegramStandIn([[
            #"{"update_id":10,"message":{"message_id":7,"date":0,"chat":{"id":42,"type":"private","first_name":"Alex"},"from":{"id":42,"is_bot":false,"first_name":"Alex"},"text":"hello from Telegram"}}"#,
            #"{"update_id":11,"message":{"message_id":3,"date":0,"chat":{"id":99,"type":"private","first_name":"Eve"},"from":{"id":99,"is_bot":false,"first_name":"Eve"},"text":"let me in"}}"#,
        ]])
        app.telegram.readToken = { "123:AAFakeTokenForTestsOnly" }
        app.telegram.transport = telegram
        settings.telegramChats = [TelegramChat(id: 42, botID: bot.id, label: "Alex")]
        settings.telegramEnabled = true
        let home = ChatTarget.home(bot.id)
        for _ in 0..<500 {
            if await !telegram.sent.isEmpty, !app.isRunning(home) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let id = TelegramInbound.messageID(bot: 123, chat: 42, message: 7)
        #expect(app.thread(home).filter { $0.role == .user || $0.role == .assistant }.map(\.text) == ["hello from Telegram", "reply:hello from Telegram"])
        #expect(app.thread(home).first { $0.role == .user }?.id == id)
        #expect(app.bot(bot.id)?.sessionID == "telegram-session")
        let sent = await telegram.sent
        #expect(sent.map(\.chat) == [42])
        #expect(sent.first?.text == "reply:hello from Telegram")
        #expect(sent.first?.replyTo == 7)
        #expect(app.telegram.refused.map(\.id) == [99])
        #expect(app.telegram.state == .running(.connected("@chu_bot")))
        #expect(TelegramState.load(from: store.root.appendingPathComponent("telegram.json")).offset == 12)

        // Turned off, then BotChu relaunched: the chat still reaches the same bot, and the gateway
        // goes on after the last update it handled.
        settings.telegramEnabled = false
        for _ in 0..<50 where app.telegram.state != .off { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.telegram.state == .off)
        let reopened = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        #expect(reopened.telegramChats == [TelegramChat(id: 42, botID: bot.id, label: "Alex")])
        #expect(!reopened.telegramEnabled)
        let relaunched = AppModel(store: store, settings: reopened, usage: usage)
        defer { relaunched.stopAll() }
        // The shown Home is read off the main thread after the launch (#109).
        #expect(await relaunched.loadedThread(home)?.contains { $0.id == id } == true)
        relaunched.telegram.readToken = { "123:AAFakeTokenForTestsOnly" }
        relaunched.telegram.transport = telegram
        let polled = await telegram.offsets.count
        reopened.telegramEnabled = true
        for _ in 0..<250 {
            if await telegram.offsets.count > polled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let offsets = await telegram.offsets
        #expect(offsets.count > polled && offsets[polled] == 12)
        #expect(await telegram.sent.count == 1)
        reopened.telegramEnabled = false
    }
}

extension RenderingTests {
    /// #114: from the chat Settings gives Danny (a COO), `/task @Worker #fixture/project …` makes a
    /// Task of Worker's own, in the left sidebar under Worker, with its own conversation and session:
    /// not a sub-agent run of Danny's, nor anything under Danny. `@Worker #… text` reaches Worker's
    /// Home with the repository as a `#` mention.
    @Test func telegramTaskRequestMakesATopLevelTaskForTheChosenBot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-telegram-task-\(UUID().uuidString)")
        let domain = "local.BotChu.TelegramTaskTests.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let store = Store(root: root.appendingPathComponent("index"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        let danny = Bot(name: "Danny", title: "COO", accountID: "codex-dev", workspace: root.appendingPathComponent("danny").path)
        let worker = Bot(name: "Worker", accountID: "codex-work", workspace: root.appendingPathComponent("worker").path)
        for bot in [danny, worker] { try BotHome(workspace: bot.workspace).save(bot) }
        let checkout = root.appendingPathComponent("repos/project").path
        for arguments in [["git", "init", "-q", "-b", "main", checkout],
                          ["git", "-C", checkout, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                           "commit", "-q", "--allow-empty", "-m", "Initial"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            git.arguments = arguments
            try git.run()
            git.waitUntilExit()
        }
        let script = root.appendingPathComponent("cli.py")
        try #"""
        import json, sys
        def emit(value):
            print(json.dumps(value), flush=True)
        emit({"type": "thread.started", "thread_id": "telegram-task-session"})
        emit({"type": "item.completed", "item": {"type": "agent_message", "text": "done:" + sys.argv[-1].splitlines()[-1]}})
        emit({"type": "turn.completed"})
        """#.write(to: script, atomically: true, encoding: .utf8)
        for account in [danny.accountID, worker.accountID] { settings.commands[account] = "/usr/bin/python3 \(Shell.quote(script.path))" }
        try store.saveIndex([Store.Entry(id: danny.id, workspace: danny.workspace), Store.Entry(id: worker.id, workspace: worker.workspace)])
        let app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        defer { app.stopAll() }
        app.repositories = [GitHubLookup.Repo(nameWithOwner: "fixture/project")]
        app.repositoriesReadAt = Date()

        let telegram = BridgeTelegramStandIn([[
            #"{"update_id":10,"message":{"message_id":7,"date":0,"chat":{"id":42,"type":"private","first_name":"Alex"},"from":{"id":42,"is_bot":false,"first_name":"Alex"},"text":"/task @Worker #fixture/project Ship the fix"}}"#,
            ##"{"update_id":11,"message":{"message_id":8,"date":0,"chat":{"id":42,"type":"private","first_name":"Alex"},"from":{"id":42,"is_bot":false,"first_name":"Alex"},"text":"#fixture/project how is it going?"}}"##,
        ]])
        app.telegram.readToken = { "123:AAFakeTokenForTestsOnly" }
        app.telegram.transport = telegram
        settings.telegramChats = [TelegramChat(id: 42, botID: danny.id, label: "Alex")]
        settings.telegramEnabled = true
        defer { settings.telegramEnabled = false }
        let workerHome = ChatTarget.home(worker.id)
        for _ in 0..<500 {
            if await telegram.sent.count >= 2, app.tasks[worker.id]?.isEmpty == false, !app.isRunning(workerHome) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let task = try #require(app.tasks[worker.id]?.first)
        let target = ChatTarget.task(task.id, of: worker.id)
        #expect(task.id == TelegramInbound.messageID(bot: 123, chat: 42, message: 7))
        #expect(task.repo == "fixture/project" && task.checkout == checkout && task.brief == "Ship the fix")
        #expect(task.origin == .owner && task.requestedBy == nil && task.accountID == worker.accountID)
        #expect(app.openTasks(of: worker.id).map(\.id) == [task.id])
        #expect(app.tasks[danny.id]?.isEmpty != false)
        #expect((app.delegation.records[.home(danny.id)] ?? []).isEmpty)
        #expect(app.thread(target).first { $0.role == .user }?.text == "Ship the fix")
        // Danny's Home never got either message: Worker is who the chat talks to now.
        #expect(!app.thread(.home(danny.id)).contains { $0.role == .user })
        let asked = try #require(app.thread(workerHome).first { $0.role == .user })
        #expect(asked.text == "#fixture/project how is it going?" && asked.mentions.map(\.target) == ["fixture/project"])
        let sent = await telegram.sent
        #expect(sent.first?.text == TelegramReply.taskStarted(task.title, bot: "Worker", repo: "fixture/project"))
        #expect(sent.contains { $0.replyTo == 8 && $0.text == "Worker:\ndone:#fixture/project how is it going?" })
    }
}

/// Telegram's Bot API, played here: one batch of updates, then none (after a short wait, as a
/// long poll would), and every message sent recorded.
actor BridgeTelegramStandIn: TelegramTransport {
    struct Sent {
        let chat: Int64
        let text: String
        let replyTo: Int64?
    }

    private var batches: [[String]]
    private(set) var sent: [Sent] = []
    private(set) var offsets: [Int64?] = []

    init(_ batches: [[String]]) { self.batches = batches }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        switch request.url?.lastPathComponent {
        case "getMe":
            return ok(#"{"id":123,"is_bot":true,"first_name":"Chu","username":"chu_bot"}"#)
        case "getUpdates":
            offsets.append((json["offset"] as? NSNumber)?.int64Value)
            guard !batches.isEmpty else {
                try await Task.sleep(for: .milliseconds(50))
                return ok("[]")
            }
            return ok("[" + batches.removeFirst().joined(separator: ",") + "]")
        case "sendMessage":
            sent.append(Sent(chat: (json["chat_id"] as? NSNumber)?.int64Value ?? 0, text: json["text"] as? String ?? "",
                             replyTo: ((json["reply_parameters"] as? [String: Any])?["message_id"] as? NSNumber)?.int64Value))
            return ok(#"{"message_id":\#(500 + sent.count),"date":0,"chat":{"id":42,"type":"private"}}"#)
        default:
            return ok("true")
        }
    }

    private func ok(_ result: String) -> (Data, Int) { (Data(#"{"ok":true,"result":\#(result)}"#.utf8), 200) }
}
