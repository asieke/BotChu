import Foundation
import Testing
@testable import BotChuCore

/// #368: `botchu-subagent resume <id>` relaunches an interrupted run for the turns that may, and
/// `wait` from a later turn collects one; a run whose CLI still runs isn't relaunched.
@Suite struct SubagentResumeTests {
    private let botID = UUID(), taskID = UUID(), invocation = UUID()
    private let bot = Bot(name: "Worker", workspace: "/tmp/worker")

    private func run(_ phase: SubagentPhase = .stopped, task: UUID? = nil, parent: UUID? = nil, root: UUID? = nil) -> SubagentRun {
        var run = SubagentRun(rootBotID: root ?? botID, rootTaskID: task, parentSubagentID: parent, depth: parent == nil ? 1 : 2,
                              targetBot: bot, title: "Fix the parser", brief: "Fix it", workingDirectory: "/repo/wt", phase: phase)
        run.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return run
    }

    private func caller(task: UUID? = nil, parent: UUID? = nil, bot: UUID? = nil) -> SubagentCallerContext {
        SubagentCallerContext(invocationID: invocation, botID: bot ?? botID, taskID: task, parentSubagentID: parent,
                              depth: parent == nil ? 0 : 1, workingDirectory: "/repo/wt")
    }

    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @Test func requestsComeOnlyFromTheTurnWhoseMailboxTheyAreIn() throws {
        let runID = UUID()
        let stamp = ISO8601DateFormatter().string(from: Date())
        var fields: [String: Any] = ["kind": "resume", "id": UUID().uuidString, "runID": runID.uuidString, "invocationID": invocation.uuidString,
                                     "callerBotID": botID.uuidString, "callerTaskID": taskID.uuidString, "depth": 0, "createdAt": stamp]
        let request = try SubagentResumeRequest.parse(json(fields))
        let data = try json(fields)
        #expect(SubagentResumeRequest.isRequest(data) && !SubagentAttachRequest.isRequest(data))
        #expect(request.runID == runID)
        try request.validate(caller(task: taskID))
        // Another turn's, another task's, or a depth it doesn't have: refused.
        #expect(throws: InboxRequest.Problem.self) { try request.validate(caller(task: nil)) }
        #expect(throws: InboxRequest.Problem.self) { try request.validate(caller(task: taskID, parent: UUID())) }
        var other = request
        other.invocationID = UUID()
        #expect(throws: InboxRequest.Problem.self) { try other.validate(caller(task: taskID)) }
        // Stale on this Mac; a host's clock isn't checked.
        fields["createdAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let stale = try SubagentResumeRequest.parse(json(fields))
        #expect(throws: InboxRequest.Problem.self) { try stale.validate(caller(task: taskID)) }
        try stale.validate(caller(task: taskID), now: nil)
        fields["runID"] = nil
        #expect(throws: InboxRequest.Problem.self) { try SubagentResumeRequest.parse(json(fields)) }

        var attach: [String: Any] = ["kind": "attach", "id": UUID().uuidString, "runIDs": [runID.uuidString], "invocationID": invocation.uuidString,
                                     "callerBotID": botID.uuidString, "depth": 0, "createdAt": stamp]
        #expect(try SubagentAttachRequest.parse(json(attach)).runIDs == [runID])
        attach["runIDs"] = [String]()
        #expect(throws: InboxRequest.Problem.self) { try SubagentAttachRequest.parse(json(attach)) }
        attach["runIDs"] = (0...SubagentAttachRequest.maxRuns).map { _ in UUID().uuidString }
        #expect(throws: InboxRequest.Problem.self) { try SubagentAttachRequest.parse(json(attach)) }
        attach["runIDs"] = ["../../etc"]
        #expect(throws: InboxRequest.Problem.self) { try SubagentAttachRequest.parse(json(attach)) }
    }

    @Test func whoMayResumeWhoseRun() {
        let parentRun = UUID(), sibling = UUID()
        let taskRun = run(task: taskID)
        // The task's next turn, and the bot's Home turn.
        #expect(SubagentResume.problem(collecting: taskRun, by: caller(task: taskID)) == nil)
        #expect(SubagentResume.problem(collecting: taskRun, by: caller()) == nil)
        // Another of its tasks, a sub-agent's turn, or another bot: never.
        #expect(SubagentResume.problem(collecting: taskRun, by: caller(task: UUID())) != nil)
        #expect(SubagentResume.problem(collecting: taskRun, by: caller(task: taskID, parent: parentRun)) != nil)
        #expect(SubagentResume.problem(collecting: taskRun, by: caller(task: taskID, bot: UUID())) != nil)
        #expect(SubagentResume.problem(collecting: taskRun, by: caller(bot: UUID())) != nil)
        // A nested run: its parent run's (resumed) CLI, and Home; not a sibling's, nor the task's own turn.
        let nested = run(task: taskID, parent: parentRun)
        #expect(SubagentResume.problem(collecting: nested, by: caller(task: taskID, parent: parentRun)) == nil)
        #expect(SubagentResume.problem(collecting: nested, by: caller()) == nil)
        #expect(SubagentResume.problem(collecting: nested, by: caller(task: taskID, parent: sibling)) != nil)
        #expect(SubagentResume.problem(collecting: nested, by: caller(task: taskID)) != nil)
        // Home's own run: not from a task.
        let homeRun = run()
        #expect(SubagentResume.problem(collecting: homeRun, by: caller()) == nil)
        #expect(SubagentResume.problem(collecting: homeRun, by: caller(task: taskID)) != nil)
    }

    @Test func onlyAnInterruptedRunIsRelaunchedAndOthersSayWhatToRun() {
        #expect(SubagentResume.problem(resuming: run(.stopped)) == nil)
        var failed = run(.failed)
        #expect(SubagentResume.problem(resuming: failed)?.contains("delegate it again") == true)
        failed.interruption = SubagentInterruption(cause: .failed)
        #expect(SubagentResume.problem(resuming: failed) == nil)
        let completed = run(.completed)
        #expect(SubagentResume.problem(resuming: completed) == "\(completed.id.uuidString.lowercased()) completed: botchu-subagent wait \(completed.id.uuidString.lowercased()) prints its handoff.")
        #expect(SubagentResume.problem(resuming: run(.running))?.contains("under way") == true)
    }

    @Test func aContinuedSessionThatFailsBeforeAnyToolCallStartsANewOneOnce() {
        #expect(SubagentResume.startsANewSession(continuedSession: true, failed: true, toolCallsSinceLaunch: 0))
        // The new launch continues no session, so it doesn't start another.
        #expect(!SubagentResume.startsANewSession(continuedSession: false, failed: true, toolCallsSinceLaunch: 0))
        // It got going in its session, or it didn't fail: its outcome stands.
        #expect(!SubagentResume.startsANewSession(continuedSession: true, failed: true, toolCallsSinceLaunch: 1))
        #expect(!SubagentResume.startsANewSession(continuedSession: true, failed: false, toolCallsSinceLaunch: 0))
    }

    @Test func theDeltaCarriesHowItEndedTheWorkspaceNowAndItsInterruptedRuns() {
        var record = run(task: taskID)
        record.interruption = SubagentInterruption(cause: .parentEnded, at: record.startedAt!.addingTimeInterval(90), toolCalls: 7,
                                                   lastAction: "`swift test`")
        var child = run(task: taskID, parent: record.id)
        child.title = "Run `the` checks\nnow"
        let workspace = SubagentWorkspaceState(branch: "feat/x", head: "abc1234 WIP", uncommitted: ["a.swift"])
        let delta = SubagentResume.delta(for: record, workspace: workspace, interruptedChildren: [child], session: true)
        #expect(delta.hasPrefix("<botchu_resume>\n") && delta.hasSuffix("\n</botchu_resume>"))
        #expect(delta.contains("continuing your session."))
        #expect(delta.contains("How it ended: The turn that called it ended before its handoff, after 7 tool calls in 1m 30s. "
            + "Last action: `swift test`. Workspace: /repo/wt on `feat/x` at `abc1234 WIP`, 1 uncommitted: `a.swift`."))
        #expect(delta.contains("- \(child.id.uuidString.lowercased()) “Run 'the' checks now” (Worker)"))
        #expect(delta.contains("botchu-subagent resume <id>"))
        let fresh = SubagentResume.delta(for: record, workspace: nil, interruptedChildren: [], session: false)
        #expect(fresh.contains("your session couldn't be continued, so your brief is above."))
        #expect(!fresh.contains("Sub-agent runs you started"))
        var failed = run(.failed, task: taskID)
        failed.interruption = SubagentInterruption(cause: .failed, toolCalls: 1)
        failed.errorMessage = failed.interruption?.outcome(for: failed, failure: "quota exceeded")
        #expect(SubagentResume.delta(for: failed, workspace: nil, interruptedChildren: [], session: true).contains("Its error: quota exceeded"))
    }

    @Test func aProcessMarkedWithTheRunOrItsChildrensIDIsFoundAndNothingElse() async throws {
        #expect(SubagentLiveness.parse("123\n456\nscanned\n") == [123, 456])
        #expect(SubagentLiveness.parse("123\n") == nil, "A scan that didn't finish refuses")
        let marked = UUID(), other = UUID()
        let process = Process()
        // A CLI of the run, and what it started, which inherits its environment. (macOS hides the
        // environment of its own platform binaries, such as /bin/sh, but not of a CLI's.)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); time.sleep(30)"]
        process.environment = ["PATH": "/usr/bin:/bin", "BOTCHU_CALLER_SUBAGENT_ID": marked.uuidString]
        try process.run()
        defer { process.terminate() }
        try await Task.sleep(for: .milliseconds(800))
        let found = try await SubagentLiveness.processes(marked: [other, marked]).get()
        #expect(found.contains(process.processIdentifier))
        #expect(found.count == 2, "The shell and the sleep it started: \(found)")
        let none = try await SubagentLiveness.processes(marked: [other]).get()
        #expect(none.isEmpty)
    }
}

/// The helper's side: `resume` and `wait` from a later turn.
@Suite struct SubagentResumeHelperTests {
    private final class Mailbox {
        let root: URL
        let ipc: SubagentIPC
        let helper: URL
        let botID = UUID(), invocationID = UUID()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-resume-\(UUID().uuidString)").resolvingSymlinksInPath()
            ipc = SubagentIPC(root: root.appendingPathComponent("mailbox"))
            helper = try SubagentHookInstaller.install(binDirectory: root.appendingPathComponent("bin"))
            try ipc.prepare()
            try ipc.writeHeartbeat()
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func start(_ arguments: [String]) throws -> (Process, Pipe, Pipe) {
            let process = Process()
            process.executableURL = helper
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin", "BOTCHU_IPC_DIR": ipc.root.path, "BOTCHU_INVOCATION_ID": invocationID.uuidString,
                                   "BOTCHU_CALLER_BOT_ID": botID.uuidString, "BOTCHU_CALLER_DEPTH": "0",
                                   "BOTCHU_WAIT_TIMEOUT_SECONDS": "5", "BOTCHU_LOAD_AVERAGE": "0"]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            return (process, out, err)
        }

        func finish(_ started: (Process, Pipe, Pipe)) -> (code: Int32, output: String, error: String) {
            started.0.waitUntilExit()
            return (started.0.terminationStatus, String(decoding: started.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: started.2.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        /// The first request the helper writes, as JSON.
        func request() throws -> (file: URL, object: [String: Any]) {
            let deadline = Date().addingTimeInterval(3)
            while ipc.pendingRequests().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let pending = try #require(ipc.pendingRequests().first)
            return (pending.file, try #require(try JSONSerialization.jsonObject(with: pending.data) as? [String: Any]))
        }
    }

    @Test func resumeAsksBotChuThenWaitsForTheRunsNewHandoffNotItsOldResult() throws {
        let mailbox = try Mailbox()
        let runID = UUID()
        // This turn already got the run's Interrupted result: it must not be taken for the new one.
        try mailbox.ipc.writeResult(SubagentResult(id: runID, targetBotName: "Worker", phase: .stopped, errorMessage: "OLD", interrupted: true))
        let started = try mailbox.start(["resume", runID.uuidString])
        defer { if started.0.isRunning { started.0.terminate() } }
        let (file, request) = try mailbox.request()
        #expect(request["kind"] as? String == "resume")
        #expect(request["runID"] as? String == runID.uuidString.lowercased())
        #expect(request["invocationID"] as? String == mailbox.invocationID.uuidString.lowercased())
        #expect(request["callerBotID"] as? String == mailbox.botID.uuidString.lowercased())
        #expect(!FileManager.default.fileExists(atPath: mailbox.ipc.resultURL(runID).path))
        let id = try #require((request["id"] as? String).flatMap(UUID.init(uuidString:)))
        _ = mailbox.ipc.removeRequest(file)
        try SubagentIPC.encode(SubagentResumeAnswer(id: id, runID: runID, resumed: true)).write(to: mailbox.ipc.resultURL(id))
        Thread.sleep(forTimeInterval: 0.3)
        // Answered and waiting: it sent no attach request for the run it resumed.
        #expect(mailbox.ipc.pendingRequests().isEmpty)
        try mailbox.ipc.writeResult(SubagentResult(id: runID, targetBotName: "Worker", phase: .completed, handoffOutput: "NEW HANDOFF"))
        let done = mailbox.finish(started)
        #expect(done.code == 0)
        #expect(done.output.contains("NEW HANDOFF") && !done.output.contains("OLD"))
        #expect(done.error.contains("Resumed \(runID.uuidString.lowercased())"))
    }

    @Test func aRefusedResumeSaysWhyAndNoWaitPrintsTheID() throws {
        let mailbox = try Mailbox()
        let runID = UUID()
        let refused = try mailbox.start(["resume", runID.uuidString])
        let (file, request) = try mailbox.request()
        let id = try #require((request["id"] as? String).flatMap(UUID.init(uuidString:)))
        _ = mailbox.ipc.removeRequest(file)
        try SubagentIPC.encode(SubagentResumeAnswer(id: id, runID: runID, refused: "\(runID) is under way: collect it.")).write(to: mailbox.ipc.resultURL(id))
        let no = mailbox.finish(refused)
        #expect(no.code == 1 && no.error.contains("Not resumed: \(runID) is under way: collect it."))

        let detached = try mailbox.start(["resume", "--no-wait", runID.uuidString])
        let second = try mailbox.request()
        let secondID = try #require((second.object["id"] as? String).flatMap(UUID.init(uuidString:)))
        _ = mailbox.ipc.removeRequest(second.file)
        try SubagentIPC.encode(SubagentResumeAnswer(id: secondID, runID: runID, resumed: true)).write(to: mailbox.ipc.resultURL(secondID))
        let printed = mailbox.finish(detached)
        #expect(printed.code == 0 && printed.output.trimmingCharacters(in: .whitespacesAndNewlines) == runID.uuidString.lowercased())
    }

    @Test func aLaterTurnsWaitAsksBotChuOnlyForRunsItsMailboxDoesntKnow() throws {
        let mailbox = try Mailbox()
        let earlier = UUID(), known = UUID()
        try mailbox.ipc.writeStatus(SubagentStatus(id: known, phase: .running, activity: "Working"))
        let started = try mailbox.start(["wait", earlier.uuidString, known.uuidString])
        defer { if started.0.isRunning { started.0.terminate() } }
        let (file, request) = try mailbox.request()
        #expect(request["kind"] as? String == "attach")
        #expect(request["runIDs"] as? [String] == [earlier.uuidString.lowercased()])
        _ = mailbox.ipc.removeRequest(file)
        try mailbox.ipc.writeResult(SubagentResult(id: earlier, targetBotName: "Worker", phase: .completed, handoffOutput: "EARLIER HANDOFF"))
        try mailbox.ipc.writeResult(SubagentResult(id: known, targetBotName: "Worker", phase: .completed, handoffOutput: "KNOWN HANDOFF"))
        let done = mailbox.finish(started)
        #expect(done.code == 0 && done.output.contains("EARLIER HANDOFF") && done.output.contains("KNOWN HANDOFF"))
        #expect(mailbox.ipc.pendingRequests().isEmpty, "One attach request, once")
    }
}
