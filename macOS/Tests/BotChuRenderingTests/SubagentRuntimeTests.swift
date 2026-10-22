import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func subagentFanoutReturnsNestedHandoffsToTheCallingTask() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("FANOUT", to: fixture.target)
        try await fixture.wait { !app.isRunning(fixture.target) }
        let runs = app.delegation.records[fixture.target] ?? []
        #expect(runs.count == 3)
        #expect(runs.allSatisfy { $0.phase == .completed })
        #expect(runs.filter { $0.parentSubagentID != nil }.count == 1)
        #expect(runs.map(\.depth).sorted() == [1, 1, 2])
        #expect(runs.allSatisfy { $0.workingDirectory == fixture.folder.path && $0.accountID == "codex-work" })
        #expect(app.delegation.records[.home(fixture.parent.id)]?.isEmpty != false)
        #expect(app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("HANDOFF-LEAF") == true)
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).count == 3)
        for run in runs {
            #expect(fixture.home.loadSubagentThread(id: run.id, taskID: fixture.target.taskID).contains { $0.role == .assistant })
        }
        // The target's Home session and its transcript are untouched by delegation.
        #expect(app.bot(fixture.worker.id)?.sessionID == "worker-home-session")
        #expect(app.thread(.home(fixture.worker.id)).isEmpty)
    }

    @Test func stoppingAParentStopsNestedRunsAndLeavesNoActiveChildren() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let app = fixture.app
        app.send("STOP_TREE", to: fixture.target)
        try await fixture.wait { app.delegation.all.filter { $0.phase == .running }.count == 2 }
        app.stop(fixture.target)
        try await fixture.wait { !app.isRunning(fixture.target) }
        #expect(app.delegation.all.count == 2)
        #expect(app.delegation.all.allSatisfy { $0.phase == .stopped })
        #expect(app.delegation.states.isEmpty)
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).allSatisfy { $0.phase == .stopped })
    }

    @Test func subagentDepthAndUnknownNamesFailWithoutHangingTheCaller() async throws {
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        fixture.app.send("DEPTH", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(fixture.app.delegation.all.count == 3)
        #expect(fixture.app.delegation.all.map(\.depth).sorted() == [1, 2, 3])
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.lowercased().contains("depth") == true)
        fixture.app.send("UNKNOWN", to: fixture.target)
        try await fixture.wait { !fixture.app.isRunning(fixture.target) }
        #expect(fixture.app.thread(fixture.target).last(where: { $0.role == .assistant })?.text.contains("missing-bot") == true)
    }

    @Test func restartMarksPersistedSubagentsStoppedAndInspectorRendersTheirTree() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        var parent = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID,
                                 depth: 1, targetBot: fixture.worker, title: "Audit changes", brief: "Inspect the task's changes",
                                 workingDirectory: fixture.folder.path, phase: .running)
        parent.startedAt = .now.addingTimeInterval(-30)
        let child = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, parentSubagentID: parent.id,
                               depth: 2, targetBot: fixture.worker, title: "Run checks", brief: "Verify the audit",
                               workingDirectory: fixture.folder.path, phase: .completed)
        try fixture.home.saveSubagent(parent)
        try fixture.home.saveSubagent(child)
        let restored = AppModel(store: fixture.store, settings: fixture.settings)
        defer { restored.stopAll() }
        #expect(restored.delegation.run(parent.id)?.phase == .stopped)
        #expect(restored.delegation.run(child.id)?.phase == .completed)
        #expect(fixture.home.loadSubagents(taskID: fixture.target.taskID).allSatisfy { !$0.phase.isActive })
        let defaults = UserDefaults(suiteName: fixture.domain)!
        defaults.set("subagents", forKey: InspectorTab.storageKey)
        restored.show(fixture.target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: TaskInspector(target: fixture.target).environment(restored).defaultAppStorage(defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(window.contentView?.fittingSize.width ?? 0 <= 380)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("subagents"))
        }
        restored.delegation.clear(parent.id)
        #expect(restored.delegation.all.isEmpty)
    }
}

@MainActor private final class SubagentFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-subagent-runtime-\(UUID().uuidString)")
    let domain = "local.BotChu.SubagentTests.\(UUID().uuidString)"
    let store: Store
    let settings: AppSettings
    let parent: Bot
    let worker: Bot
    let home: BotHome
    let app: AppModel
    let target: ChatTarget
    let folder: URL

    init() throws {
        store = Store(root: root.appendingPathComponent("index"))
        settings = AppSettings(defaults: UserDefaults(suiteName: domain)!)
        settings.botsRoot = root.appendingPathComponent("bots").path
        settings.reposRoot = root.appendingPathComponent("repos").path
        parent = Bot(name: "Parent", accountID: "codex-dev", workspace: root.appendingPathComponent("parent").path)
        worker = Bot(name: "Worker", instructions: "Use the worker persona", accountID: "codex-work", workspace: root.appendingPathComponent("worker").path,
                     sessionID: "worker-home-session", sessionAccountID: "codex-work")
        home = BotHome(workspace: parent.workspace)
        try home.save(parent)
        try BotHome(workspace: worker.workspace).save(worker)
        try "WORKER-SOUL".write(toFile: worker.workspace + "/SOUL.md", atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("cli.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        for account in [parent.accountID, worker.accountID] { settings.commands[account] = "/usr/bin/python3 \(Shell.quote(script.path))" }
        var task = BotTask(for: parent, repo: "fixture/repo", checkout: root.path, work: nil, brief: "Test delegation")
        folder = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        task.folder = folder.path
        try home.save(task)
        target = .task(task.id, of: parent.id)
        try store.saveIndex([Store.Entry(id: parent.id, workspace: parent.workspace), Store.Entry(id: worker.id, workspace: worker.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") })
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out: \(app.thread(target).map(\.text)) / \(app.delegation.all.map { "\($0.title): \($0.phase) \($0.errorMessage ?? "")" })")
        throw CocoaError(.executableLoad)
    }
    func cleanUp() {
        app.stopAll()
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, os, re, subprocess, sys, time
    def emit(value): print(json.dumps(value), flush=True)
    def helper(*args):
        result = subprocess.run(["botchu-subagent", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout + result.stderr
    depth = int(os.environ["BOTCHU_CALLER_DEPTH"])
    prompt = sys.argv[-1]
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if depth:
        assert "WORKER-SOUL" in prompt
        brief = re.search(r"<handoff_brief>\s*(.*?)\s*</handoff_brief>", prompt, re.S).group(1)
    else:
        brief = prompt.splitlines()[-1]
    if brief == "FANOUT":
        one = helper("spawn", "--agent", "Worker", "--brief", "NEST").strip()
        two = helper("spawn", "--agent", "Worker", "--brief", "LEAF").strip()
        answer = helper("wait", one, two)
    elif brief == "NEST":
        answer = helper("call", "--agent", "Worker", "--brief", "LEAF")
    elif brief == "STOP_TREE":
        answer = helper("call", "--agent", "Worker", "--brief", "STOP_CHILD")
    elif brief == "STOP_CHILD":
        answer = helper("call", "--agent", "Worker", "--brief", "BLOCK")
    elif brief == "BLOCK":
        while True: time.sleep(.1)
    elif brief == "DEPTH":
        answer = helper("call", "--agent", "Worker", "--brief", "DEPTH")
    elif brief == "UNKNOWN":
        answer = helper("call", "--agent", "missing-bot", "--brief", "LEAF")
    else:
        answer = "HANDOFF-LEAF"
    emit({"type":"item.completed", "item":{"type":"agent_message", "text":answer}})
    emit({"type":"turn.completed"})
    """#
}
