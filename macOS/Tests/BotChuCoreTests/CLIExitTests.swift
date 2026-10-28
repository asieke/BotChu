import Foundation
import Testing
@testable import BotChuCore

/// #145: a sub-agent's Antigravity CLI printed its result, then never exited and ignored Stop's
/// SIGINT and SIGTERM, so its run, handoff written, stayed running until BotChu restarted. A CLI
/// still running a while after it said its turn ended is ended, its turn standing, and Stop kills
/// a CLI that ignores it, with what it started.
@Suite struct CLIExitTests {
    // Captured from agy on 2026-10-25 (a background `sleep 40`, then "ok"), with IDs, paths and
    // usage trimmed. Its result comes only once its background task has finished and it has said
    // so, and agy exited 0.15 s after it: the result is the end of its turn.
    static let backgroundTurn = [
        #"{"event":"init","conversation_id":"conversation","init":{"model":"gemini-4-argon-medium","cwd":"/tmp/agy"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"conversation","step_index":4,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"sleep 40"}}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"conversation","step_index":4,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":40.106835,"tool_info":{"name":"run_command","parameters":{"CommandLine":"sleep 40"},"output":"Command exited with code 0.\n\nNo output from the command."}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"conversation","step_index":5,"state":"DONE","step_type":"agent_response","text_delta":"ok\n","duration_seconds":13.235852}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"conversation","step_index":6,"state":"DONE","step_type":"system_message","duration_seconds":0.000183}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"conversation","step_index":7,"state":"ACTIVE","step_type":"agent_response","text_delta":"Background command `sleep 40` has finished (exit code 0)."}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"conversation","step_index":7,"state":"DONE","step_type":"agent_response","text_delta":"\n","duration_seconds":4.885614}}"#,
        #"{"event":"result","result":{"conversation_id":"conversation","status":"SUCCESS","response":"ok\nBackground command `sleep 40` has finished (exit code 0).\n","duration_seconds":53.662119,"num_turns":1}}"#,
    ]

    /// A stand-in for the stuck agy: it prints its arguments as its output, then ignores SIGINT
    /// and SIGTERM and never exits, and neither does a process it started that holds its output
    /// open (as agy's language server or a background command could).
    static let stuck = #"""
    import os, signal, subprocess, sys, time
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    open("pid", "w").write(str(os.getpid()))
    subprocess.Popen(["/bin/sleep", "600"])
    print("root agent idle; waiting up to 30m0s for 1 background task(s)", file=sys.stderr, flush=True)
    for line in sys.argv[1:]: print(line, flush=True)
    time.sleep(600)
    """#

    @Test func antigravitySaysItsTurnEndedOnlyAfterItsBackgroundTasks() {
        var parser = AntigravityParser()
        let events = Self.backgroundTurn.flatMap { parser.parse(line: $0) }
        #expect(events.last == .finished)
        #expect(events.filter { $0 == .finished }.count == 1)
        #expect(events.contains(.textDelta("Background command `sleep 40` has finished (exit code 0).")))
    }

    @Test func aCLIStillRunningAfterItsTurnEndedIsEndedAndItsTurnStands() async {
        let ending = await Self.run(Self.stuck, arguments: Self.backgroundTurn, kind: .antigravity) {
            $0.lingerLimit = 0.5
            $0.killDelay = 0.5
        }
        #expect(!ending.hung)
        #expect(ending.lingered)
        // A CLI that only didn't exit (#145) left nothing unfinished.
        #expect(!ending.endedBackgroundTasks)
        #expect(!ending.stopped)
        #expect(ending.events.last == .finished)
        #expect(ending.events.contains(.textDelta("ok\n")))
        #expect(ending.stderr.hasPrefix("root agent idle"))
        #expect(ending.stderr.hasSuffix("BotChu ended it: it was still running 0.5 s after it said its turn had ended."))
    }

    /// The wait for its exit starts only once it has nothing more to read: a CLI that takes input
    /// keeps running between turns, for as long as BotChu keeps its input open.
    @Test func aCLIThatTakesInputIsEndedOnlyOnceItsInputIsClosed() async {
        let script = #"""
        import json, os, signal, sys, time
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        open("pid", "w").write(str(os.getpid()))
        for line in sys.stdin:
            print(json.dumps({"type":"result", "subtype":"success", "is_error":False, "result":"ok"}), flush=True)
        time.sleep(600)
        """#
        let runningWithInputOpen = Flag()
        let ending = await Self.run(script, input: ["hello"], kind: .claude) {
            $0.lingerLimit = 0.5
            $0.killDelay = 0.5
        } started: { run, ended in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                runningWithInputOpen.value = !ended.value
                run.closeInput()
            }
        }
        #expect(runningWithInputOpen.value)
        #expect(!ending.hung)
        #expect(ending.lingered)
        #expect(ending.events == [.finished])
    }

    /// Output after the end (more work) means the CLI carried on: it isn't cut short.
    @Test func aCLIThatCarriesOnAfterItsTurnEndedIsLeftToFinish() async {
        let script = #"""
        import json, time
        print(json.dumps({"type":"turn.completed"}), flush=True)
        time.sleep(0.1)
        print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"more"}}), flush=True)
        time.sleep(1.5)
        print(json.dumps({"type":"turn.completed"}), flush=True)
        """#
        let ending = await Self.run(script, kind: .codex) { $0.lingerLimit = 1 }
        #expect(!ending.lingered)
        #expect(ending.status == 0)
        #expect(ending.events == [.finished, .text("more"), .finished])
    }

    /// #255: Claude Code ends its turn with a test run going in the background, waits for it, then
    /// carries on in a new turn of its own. Waiting longer than `lingerLimit` isn't lingering.
    static let waitsForItsBackgroundTask = #"""
    import json, sys, time
    def say(**line): print(json.dumps(line), flush=True)
    say(type="system", subtype="background_tasks_changed", tasks=[{"task_id": "b1"}])
    say(type="assistant", message={"id": "m1", "content": [{"type": "text", "text": "started"}]})
    say(type="result", subtype="success", is_error=False, result="started")
    time.sleep(float(sys.argv[1]))
    say(type="system", subtype="background_tasks_changed", tasks=[])
    say(type="system", subtype="init", session_id="s")
    say(type="assistant", message={"id": "m2", "content": [{"type": "text", "text": "finished"}]})
    say(type="result", subtype="success", is_error=False, result="finished")
    """#

    @Test func aCLIWaitingForItsBackgroundTasksIsLeftToCarryOn() async {
        let ending = await Self.run(Self.waitsForItsBackgroundTask, arguments: ["1.5"], kind: .claude) {
            $0.lingerLimit = 0.5
            $0.killDelay = 0.5
        }
        #expect(!ending.lingered)
        #expect(ending.status == 0)
        #expect(ending.events == [
            .backgroundTasks([.working]), .text("started"), .finished, .backgroundTasks([.working]),
            .backgroundTasks([]), .session("s"), .text("finished"), .finished,
        ])
    }

    /// Background tasks that never end don't keep it running forever: it is ended `backgroundLimit`
    /// after its turn.
    @Test func aCLIWaitingTooLongForItsBackgroundTasksIsEnded() async {
        let ending = await Self.run(Self.waitsForItsBackgroundTask, arguments: ["600"], kind: .claude) {
            $0.lingerLimit = 0.5
            $0.backgroundLimit = 1
            $0.killDelay = 0.5
        }
        #expect(!ending.hung)
        #expect(ending.lingered)
        // Its background tasks ended unfinished: the heartbeat checks on them (#261).
        #expect(ending.endedBackgroundTasks)
        #expect(ending.events.last == .backgroundTasks([.working]))
        #expect(ending.stderr.hasSuffix("BotChu ended it: it was still running 1 s after it said its turn had ended, waiting for its background tasks."))
    }

    @Test func museApprovalEndsTheProcessAndPreservesItsFailure() async {
        let approval = #"{"payload_type":"approval.requested","payload":{}}"#
        let ending = await Self.run(Self.stuck, arguments: [approval], kind: .muse) {
            $0.killDelay = 0.1
        }
        #expect(!ending.hung)
        #expect(!ending.stopped)
        #expect(!ending.lingered)
        #expect(ending.status != 0)
        #expect(ending.events == [.failed("Muse is waiting for an approval BotChu can't show")])
    }

    @Test func stopEndsACLIThatIgnoresInterruptAndTerminate() async {
        let ending = await Self.run(Self.stuck, kind: .antigravity) {
            $0.killDelay = 0.5
        } started: { run, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { run.stop() }
        }
        #expect(!ending.hung)
        #expect(ending.stopped)
        #expect(!ending.lingered)
        #expect(ending.status != 0)
    }

    final class Flag: @unchecked Sendable { var value = false }

    struct Ending {
        var events: [AgentEvent] = []
        var status: Int32 = 0
        var stderr = ""
        var lingered = false
        var endedBackgroundTasks = false
        var stopped = false
        /// It was still running after the test's limit (then killed by the test).
        var hung = false
    }

    /// Runs `script` with Python as a CLI of `kind`, set up by `configure`, and hands it to
    /// `started` once it has started. One still running after `limit` seconds is killed here,
    /// with what it started, and reported hung.
    static func run(_ script: String, arguments: [String] = [], input: [String]? = nil, kind: AgentKind,
                    limit: TimeInterval = 20, configure: @escaping (AgentRun) -> Void = { _ in },
                    started: @escaping (AgentRun, Flag) -> Void = { _, _ in }) async -> Ending {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-exit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return await withCheckedContinuation { (done: CheckedContinuation<Ending, Never>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "/usr/bin/python3", invocation: Invocation(arguments: ["-c", script] + arguments, input: input),
                                   directory: folder)
                configure(run)
                var ending = Ending()
                let ended = Flag()
                run.deliverEvents(parsedBy: StreamParsers.make(for: kind)) { ending.events += $0 }
                run.onExit = { [weak run] status, stderr in
                    guard !ended.value else { return }
                    ended.value = true
                    ending.status = status
                    ending.stderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    ending.lingered = run?.lingered == true
                    ending.endedBackgroundTasks = run?.endedBackgroundTasks == true
                    ending.stopped = run?.stopped == true
                    done.resume(returning: ending)
                }
                do { try run.start() } catch {
                    Issue.record(error)
                    ended.value = true
                    return done.resume(returning: ending)
                }
                started(run, ended)
                DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                    guard !ended.value else { return }
                    ended.value = true
                    if let pid = Int32((try? String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)) ?? "") {
                        Darwin.killpg(pid, SIGKILL)
                    }
                    ending.hung = true
                    done.resume(returning: ending)
                }
            }
        }
    }
}
