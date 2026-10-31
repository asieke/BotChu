import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func toolPolicyChangedDuringPreparationAppliesToTheLaunch() async throws {
        let gate = SessionPreparationTestGate()
        let storage = StorageQueue(before: { work in if work.label == "session-preparation" { gate.wait() } })
        let fixture = try SubagentFixture(storage: storage)
        defer { gate.release(); fixture.cleanUp() }
        let app = fixture.app
        let command = fixture.root.appendingPathComponent("gh")
        try "#!/bin/sh\necho UNBLOCKED\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        // Match the real locator: the temporary directory can contain /var -> /private/var.
        let location = ToolLocation(path: command.path, realPath: try #require(ToolLocator.realPath(command.path)))
        app.tools.locate = { _ in (catalog: ["gh": [location]], declared: [:]) }
        _ = await app.loadedThread(fixture.target)
        app.drafts[fixture.target] = "POLICY_CHECK"
        app.send("POLICY_CHECK", to: fixture.target)
        try await fixture.wait { gate.started }
        app.tools.change { $0.enforcedSince = Date() }
        gate.release()
        try await fixture.wait { !app.isRunning(fixture.target) && app.task(fixture.target)?.sessionID != nil }
        #expect(app.thread(fixture.target).last(where: { $0.role == .assistant })?.text == "TOOL-BLOCKED")
    }

    /// #145: Antigravity printed a sub-agent's handoff and the end of its turn, then never exited
    /// (and ignored Stop), so the run stayed running until BotChu restarted. Its handoff now goes
    /// back a short while after the turn ended, completed, with a note saying why it took so long.
    @Test func aWorkerThatNeverExitsAfterItsReplyStillHandsOff() async throws {
        let limit = AgentRun.defaultLingerLimit, killDelay = AgentRun.defaultKillDelay
        AgentRun.defaultLingerLimit = 1
        // It ignores SIGTERM too: killed soon after, not 5 s later.
        AgentRun.defaultKillDelay = 0.2
        defer { AgentRun.defaultLingerLimit = limit; AgentRun.defaultKillDelay = killDelay }
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let caller = try await fixture.app.delegation.prepareCaller(target: fixture.target, directory: fixture.folder.path, machine: .thisMac, hostID: nil)
        defer { fixture.app.delegation.endCaller(caller.id) }
        let ipc = SubagentIPC(root: URL(fileURLWithPath: caller.environment["BOTCHU_IPC_DIR"]!))
        let request = SubagentRequest(invocationID: caller.id, callerBotID: fixture.parent.id, callerTaskID: fixture.target.taskID,
                                     depth: 0, targetAgent: "Worker", brief: "LINGER")
        try SubagentIPC.encode(request).write(to: ipc.requestURL(request.id), options: .atomic)
        try await fixture.wait { FileManager.default.fileExists(atPath: ipc.resultURL(request.id).path) }
        let result = try SubagentIPC.decode(SubagentResult.self, from: Data(contentsOf: ipc.resultURL(request.id)))
        #expect(result.phase == .completed)
        #expect(result.handoffOutput == "HANDOFF-LINGER")
        let thread = fixture.home.loadSubagentThread(id: request.id, taskID: fixture.target.taskID)
        #expect(thread.last?.role == .note)
        #expect(thread.last?.text == "Codex Work didn't exit after its reply, so BotChu ended it.")
    }

    /// #361: four runs stream, each 160 items long. A batch to one redraws only its row in the list;
    /// in its details, only the Transcript's rows that changed, and the Transcript lists its last
    /// `window` items as they come, not all of them. Another run's batch redraws nothing there.
    @Test func aStreamingRunRedrawsOnlyItsOwnRowsAndItsTranscriptListsItsTail() async throws {
        _ = NSApplication.shared
        let fixture = try SubagentFixture()
        defer { fixture.cleanUp() }
        let turn = UUID()
        let runs = (0..<4).map { index in
            var run = SubagentRun(rootBotID: fixture.parent.id, rootTaskID: fixture.target.taskID, depth: 1, targetBot: fixture.worker,
                                  title: "Streaming \(index)", brief: "Keep going.", workingDirectory: fixture.folder.path,
                                  callerInvocationID: turn, phase: .running)
            run.startedAt = .now
            return run
        }
        var calls = 0
        func call(_ text: String = "Next.") -> [ChatMessage] {
            calls += 1
            return [ChatMessage(role: .assistant, text: text),
                    ChatMessage(role: .tool, toolID: "call-\(calls)", toolName: "Bash", toolInput: "ls notes/\(calls)", toolState: .done)]
        }
        fixture.app.delegation.records[fixture.target] = runs
        for run in runs {
            fixture.app.delegation.threads[run.id] = [ChatMessage(role: .user, text: "Keep going.")] + (0..<80).flatMap { _ in call() }
            fixture.app.delegation.states[run.id] = RunState(hasOutput: true)
        }
        let tab = SubagentTabState(target: fixture.target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: InspectorPanel {
            EmptyView()
        } content: { _ in
            SubagentsInspectorContent(target: fixture.target, state: tab)
        } actions: {
            EmptyView()
        }.environment(fixture.app))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        var rows: [UUID: Int] = [:], details: [UUID: Int] = [:], items: [UUID: Int] = [:]
        SubagentDiagnostics.didEvaluateRow = { rows[$0, default: 0] += 1 }
        SubagentDiagnostics.didEvaluateDetails = { details[$0, default: 0] += 1 }
        SubagentDiagnostics.didEvaluateTranscriptItem = { items[$0, default: 0] += 1 }
        defer {
            SubagentDiagnostics.didEvaluateRow = nil
            SubagentDiagnostics.didEvaluateDetails = nil
            SubagentDiagnostics.didEvaluateTranscriptItem = nil
        }
        /// A batch as the runtime applies one: new messages, and the turn's activity when it changes.
        func batch(_ run: SubagentRun, _ change: (inout [ChatMessage]) -> Void, activity: BotActivity? = nil) async throws {
            rows.removeAll(); details.removeAll(); items.removeAll()
            fixture.app.delegation.live(run.id).update(change)
            if let activity { fixture.app.delegation.states[run.id] = RunState(hasOutput: true, activity: activity) }
            try await Task.sleep(for: .milliseconds(120))
            window.layoutIfNeeded()
        }
        var shown: Int {
            tab.frames.keys.filter { if case .block(let name) = $0 { name.hasPrefix("message-") } else { false } }.count
        }

        // The list: each batch redraws the streaming run's row alone.
        let streaming = runs[1]
        for (index, activity) in [BotActivity.coding, .thinking, .coding].enumerated() {
            try await batch(streaming, { $0 += call("Batch \(index).") }, activity: activity)
            #expect(rows[streaming.id, default: 0] > 0)
            #expect(rows.keys.allSatisfy { $0 == streaming.id }, "Only the streaming run's row: \(rows)")
        }

        // Its details: the Transcript lists the last `window` items as they come.
        tab.push(.run(streaming.id), opened: streaming.id)
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        #expect(tab.transcriptOpen[streaming.id] == true)
        #expect(shown == SubagentTranscriptList.window)
        var counted: [String] = []
        for index in 0..<6 {
            // A text chunk to its last reply, then a new reply and tool call.
            try await batch(streaming) { $0[$0.count - 2].text += " More \(index)." }
            let grown = try #require(fixture.app.delegation.threads[streaming.id]?.dropLast().last)
            #expect(details.isEmpty, "The details' head, Brief and Run don't redraw: \(details)")
            #expect(items.keys.allSatisfy { $0 == grown.id }, "Only the reply that grew: \(items.count) items")
            counted.append("chunk \(items.values.reduce(0, +))")
            try await batch(streaming) { $0 += call("Reply \(index).") }
            let added = Set(fixture.app.delegation.threads[streaming.id]?.suffix(2).map(\.id) ?? [])
            #expect(details.isEmpty)
            #expect(items.keys.allSatisfy { added.contains($0) }, "Only the new rows: \(items.count) items")
            #expect(shown == SubagentTranscriptList.window, "It follows the last items")
            counted.append("call \(items.values.reduce(0, +))")
        }
        let last = try #require(fixture.app.delegation.threads[streaming.id]?.last?.id)
        #expect(tab.frames[.block("message-" + last.uuidString)] != nil, "The newest item shows")
        // Only what shows is bounded: the transcript itself is whole.
        #expect(fixture.app.delegation.threads[streaming.id]?.count == 1 + 2 * (80 + 3 + 6))

        // Another run streaming redraws nothing of these details.
        try await batch(runs[2], { $0 += call() }, activity: .coding)
        #expect(details.isEmpty && items.isEmpty)
        print("subagents: item bodies per batch while following \(counted.joined(separator: ", "))")
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
    let host: SSHHost?
    let originalSSH: String

    init(remote: Bool = false, storage: StorageQueue = .shared) throws {
        originalSSH = Machine.ssh
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
        for account in [parent.accountID, worker.accountID] { settings.commands[account] = "/usr/bin/python3 \(Shell.quote(script.path)) --machine local" }
        if remote {
            let remoteHome = root.appendingPathComponent("remote-home")
            try FileManager.default.createDirectory(at: remoteHome, withIntermediateDirectories: true)
            let ssh = root.appendingPathComponent("ssh")
            // Its HOME, helper, mailbox and captured stdin all belong to this isolated fixture.
            try """
                #!/bin/sh
                while [ $# -gt 0 ]; do
                  case $1 in -o|-p|-i|-l|-F) shift 2 ;; -*) shift ;; *) break ;; esac
                done
                shift
                export HOME=\(Shell.quote(remoteHome.path))
                incoming=$(/usr/bin/mktemp \(Shell.quote(root.appendingPathComponent("ssh-input.XXXXXX").path)))
                /bin/cat > "$incoming"
                if [ -f \(Shell.quote(root.appendingPathComponent("fail-result-once").path)) ] && /usr/bin/grep -q 'results' "$incoming"; then
                  /bin/rm \(Shell.quote(root.appendingPathComponent("fail-result-once").path))
                  echo 'Connection dropped during result delivery' >&2
                  exit 255
                fi
                case "$*" in
                  *'exec python3 -c'*)
                    if [ -f \(Shell.quote(root.appendingPathComponent("fail-transport").path)) ]; then
                      echo 'python3 unavailable on test host' >&2
                      exit 127
                    fi ;;
                esac
                exec /bin/sh -c "$*" < "$incoming"

                """.write(to: ssh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
            Machine.ssh = ssh.path
            let commands = Dictionary(uniqueKeysWithValues: [parent.accountID, worker.accountID].map {
                ($0, "/usr/bin/python3 \(Shell.quote(script.path)) --machine remote")
            })
            host = SSHHost(nickname: "Isolated test host", destination: "fixture-host", reposFolder: root.path, commands: commands)
            settings.hosts = [host!]
        } else { host = nil }
        var task = BotTask(for: parent, repo: "fixture/repo", checkout: root.path, work: nil, brief: "Test delegation", host: host)
        folder = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        task.folder = folder.path
        try home.save(task)
        target = .task(task.id, of: parent.id)
        try store.saveIndex([Store.Entry(id: parent.id, workspace: parent.workspace), Store.Entry(id: worker.id, workspace: worker.workspace)])
        app = AppModel(store: store, settings: settings, usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") }, storage: storage)
    }

    func wait(seconds: Int = 20, _ condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 40) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out: \(app.thread(target).map(\.text)) / \(app.delegation.all.map { "\($0.title): \($0.phase) \($0.errorMessage ?? "")" })")
        throw CocoaError(.executableLoad)
    }
    func cleanUp() {
        app.stopAll()
        Machine.ssh = originalSSH
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }

    static let script = #"""
    import json, os, re, signal, subprocess, sys, time
    def emit(value): print(json.dumps(value), flush=True)
    def helper(*args):
        result = subprocess.run(["botchu-subagent", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.stdout + result.stderr
    depth = int(os.environ["BOTCHU_CALLER_DEPTH"])
    prompt = sys.argv[-1]
    with open(os.path.join(os.path.dirname(__file__), "session-prompts.txt"), "a") as output:
        output.write(prompt + "\n")
    emit({"type":"thread.started", "thread_id":"fixture-session"})
    if depth:
        assert "WORKER-SOUL" in prompt
        brief = re.search(r"<handoff_brief>\s*(.*?)\s*</handoff_brief>", prompt, re.S).group(1)
    else:
        brief = prompt.splitlines()[-1]
    if brief == "POLICY_CHECK":
        try:
            result = subprocess.run([os.path.join(os.path.dirname(__file__), "gh")], capture_output=True)
            answer = "TOOL-BLOCKED" if result.returncode else "UNBLOCKED"
        except OSError:
            answer = "TOOL-BLOCKED"
    elif brief == "REMOTE_WORKSPACES":
        shared = helper("call", "--agent", "Worker", "--workspace", "shared", "--brief", "LOCATION")
        own = helper("call", "--agent", "Worker", "--workspace", "bot_home", "--brief", "LOCATION")
        answer = shared + "\n" + own
    elif brief == "REMOTE_MEMORY":
        answer = helper("call", "--agent", "Worker", "--brief", "REMEMBER")
    elif brief == "REMEMBER":
        answer = "Handoff Report: complete. <remember>REMOTE-LESSON</remember>"
    elif brief == "TASK_MEMORY":
        answer = "That's my default now.\n<remember>\n- TASK-LESSON\n</remember>\n<remember scope=\"shared\">\n- SHARED-LESSON\n</remember>"
    elif brief == "MEMORY_REPORT":
        reported = "<memory_updates>" in prompt and "Couldn't save 1 note to your MEMORY.md" in prompt
        answer = "MEMORY-REPORTED" if reported else "NO-MEMORY-REPORT"
    elif brief == "LOCATION":
        machine = sys.argv[sys.argv.index("--machine") + 1]
        answer = "LOCATION|" + os.getcwd() + "|" + machine + "|" + os.environ["HOME"]
    elif brief == "FANOUT":
        one = helper("spawn", "--agent", "Worker", "--brief", "NEST").strip()
        two = helper("spawn", "--agent", "Worker", "--brief", "LEAF").strip()
        answer = helper("wait", one, two)
    elif brief == "NEST":
        answer = helper("call", "--agent", "Worker", "--brief", "LEAF")
    elif brief == "STOP_TREE":
        answer = helper("call", "--agent", "Worker", "--brief", "STOP_CHILD")
    elif brief == "STOP_CHILD":
        answer = helper("call", "--agent", "Worker", "--brief", "BLOCK")
    elif brief == "SAVE_FAILURE":
        def stop_after_cleanup(signum, frame):
            time.sleep(.4)
            open("child-exited", "w").close()
            sys.exit(130)
        signal.signal(signal.SIGINT, stop_after_cleanup)
        open("waiting-for-save", "w").close()
        while not os.path.exists("fail-ready"): time.sleep(.01)
        emit({"type":"item.completed", "item":{"type":"agent_message", "text":"Cannot persist this reply"}})
        while True: time.sleep(.1)
    elif brief == "BLOCK":
        while True: time.sleep(.1)
    elif brief == "LINGER":
        # Antigravity in #145: the handoff and the end of its turn, then it never exits and ignores Stop.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        emit({"type":"item.completed", "item":{"type":"agent_message", "text":"HANDOFF-LINGER"}})
        emit({"type":"turn.completed"})
        while True: time.sleep(.1)
    elif brief == "STUBBORN_TREE":
        answer = helper("call", "--agent", "Worker", "--brief", "STUBBORN")
    elif brief == "STUBBORN":
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        while True: time.sleep(.1)
    elif brief == "STREAM_PARENT":
        answer = helper("call", "--agent", "Worker", "--brief", "STREAM_CHILD")
    elif brief == "STREAM_CHILD":
        def shell(i):
            emit({"type":"item.completed", "item":{"id":"item_%d" % i, "type":"command_execution", "command":"echo %d" % i,
                  "aggregated_output":"x" * 256, "exit_code":0, "status":"completed"}})
        shell(0)
        while not os.path.exists("stream-go"): time.sleep(.01)
        for i in range(1, 101):
            shell(i)
            time.sleep(.005)
        while not os.path.exists("stream-done"): time.sleep(.01)
        answer = "HANDOFF-STREAM"
    elif brief == "REVIEWED_PARENT":
        emit({"type":"item.completed", "item":{"id":"item_parent", "type":"command_execution", "command":"git status",
              "aggregated_output":"clean", "exit_code":0, "status":"completed"}})
        answer = helper("call", "--agent", "Worker", "--brief", "REVIEWED_CHILD").strip()
    elif brief == "REVIEWED_CHILD":
        emit({"type":"item.completed", "item":{"id":"item_child", "type":"command_execution", "command":"swift test",
              "aggregated_output":"passed", "exit_code":0, "status":"completed"}})
        answer = "HANDOFF-REVIEWED"
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

/// Holds only a storage worker, never MainActor. Shared by the session-preparation runtime tests.
final class SessionPreparationTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var started: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered
    }
    func wait() {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(20)
        while !released && condition.wait(until: deadline) {}
        condition.unlock()
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
