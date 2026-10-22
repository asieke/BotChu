import Foundation
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func tasksManageTheirOwnBranchesAndKeepDetailsInAgentContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-task-creation-\(UUID().uuidString)")
        let suite = "BotChu.TaskCreation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let bot = Bot(name: "Builder", accountID: "codex-dev", workspace: root.appendingPathComponent("bot").path)
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        let checkout = root.appendingPathComponent("project").path
        #expect(await Shell.run(["git", "init", "-b", "main", checkout], in: root.path).ok)
        #expect(await Shell.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                                 "commit", "--allow-empty", "-m", "Initial"], in: checkout).ok)
        let cli = root.appendingPathComponent("fixture.py")
        try """
        import json, sys
        from pathlib import Path
        Path('prompt.txt').write_text(sys.argv[-1])
        print(json.dumps({'type': 'thread.started', 'thread_id': 'fixture-session'}))
        print(json.dumps({'type': 'item.completed', 'item': {'id': 'answer', 'type': 'agent_message', 'text': 'Done.'}}))
        print(json.dumps({'type': 'turn.completed', 'usage': {'input_tokens': 1, 'output_tokens': 1}}))
        """.write(to: cli, atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: defaults)
        settings.commands[bot.accountID] = "/usr/bin/python3 \(Shell.quote(cli.path))"
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let model = AppModel(store: store, settings: settings)
        defer { model.stopAll() }
        let issue = BotTask.Work(number: 17, title: "Improve startup", url: URL(string: "https://example.com/issues/17")!, isPullRequest: false)
        var prepared: [BotTask] = []
        // New Task supplies no branch: matching briefs get distinct workspaces, and issues keep
        // their numbered branch. The agent still receives the real branch and path in its context.
        for work in [BotTask.Work?.none, nil, issue] {
            let task = BotTask(for: bot, repo: "fixture/project", checkout: checkout, work: work, brief: "Improve startup")
            let target = ChatTarget.task(task.id, of: bot.id)
            model.startTask(task, for: bot.id, show: false)
            for _ in 0..<250 {
                if !model.isRunning(target) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!model.isRunning(target))
            let errors = model.thread(target).filter { $0.role == .error }.map(\.text)
            #expect(errors.isEmpty)
            let made = try #require(model.task(target))
            let folder = try #require(made.folder)
            #expect(!made.branch.isEmpty)
            let prompt = try String(contentsOfFile: (folder as NSString).appendingPathComponent("prompt.txt"), encoding: .utf8)
            #expect(prompt.contains("on branch \(made.branch)"))
            #expect(model.thread(target).filter { $0.role == .note }.map(\.text) == ["Task workspace ready"])
            prepared.append(made)
        }
        #expect(Set(prepared.map(\.branch)).count == 3)
        #expect(Set(prepared.compactMap(\.folder)).count == 3)
        #expect(prepared[2].branch.hasPrefix("feat/17-"))
        #expect(await Shell.run(["git", "branch", "--show-current"], in: checkout).output.trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        #expect(model.thread(.home(bot.id)).allSatisfy { !$0.text.contains("feat/") && !$0.text.contains("PR #") })
        #expect(home.loadTasks().allSatisfy { !$0.branch.isEmpty && $0.folder != nil })
    }
}
