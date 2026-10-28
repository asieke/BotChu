import Foundation
import Testing
import BotChuCore
@testable import BotChu

/// #271: fixed identities and dates, 20 bots, 80 tasks and 2,000 deliveries. No real CLI runs.
@MainActor final class InboxStatusFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-status-\(UUID()).noindex")
    let domain = "local.BotChu.InboxStatusTests.\(UUID())"
    let defaults: UserDefaults
    let store: Store
    let settings: AppSettings
    let bots: [Bot]
    let targets: [ChatTarget]
    let deliveries: [Delivery]
    let app: AppModel

    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        var bots: [Bot] = [], targets: [ChatTarget] = [], deliveries: [Delivery] = []
        for index in 0..<20 {
            let bot = Bot(id: Self.id(index + 1), name: "Bot \(index)",
                          workspace: root.appendingPathComponent("bots/\(index)").path)
            let home = BotHome(workspace: bot.workspace)
            try home.save(bot)
            bots.append(bot)
            var conversations = [ChatTarget.home(bot.id)]
            for n in 0..<4 {
                let task = BotTask(id: Self.id(100 + index * 4 + n), title: "Task \(n)", repo: "fixture/repo", checkout: root.path)
                try home.save(task)
                conversations.append(.task(task.id, of: bot.id))
            }
            for target in conversations {
                let messages = [ChatMessage(role: .assistant, text: "Ready")]
                if let taskID = target.taskID { try home.saveThread(messages, task: taskID) }
                else { try home.saveThread(messages) }
                for n in 0..<20 {
                    let delivery = Delivery(id: Self.id(1_000 + deliveries.count), botID: bot.id, taskID: target.taskID,
                        title: "Item \(n)", purpose: n.isMultiple(of: 2) ? .needsInput : .review,
                        sentAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n / 2)))
                    try InboxFolder(home: home).save(delivery, contents: [:])
                    deliveries.append(delivery)
                }
            }
            targets += conversations
        }
        self.bots = bots
        self.targets = targets
        self.deliveries = deliveries
        try store.saveIndex(bots.map { Store.Entry(id: $0.id, workspace: $0.workspace) })
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
    }

    func ready() async throws {
        for _ in 0..<600 {
            if app.inbox.isLoaded { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw InboxRequest.Problem("Fixture Inbox didn't load")
    }

    func cleanUp() {
        app.runStates.removeAll()
        app.stopAll()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", UInt64(n)))!
    }
}

