import Foundation
import Testing
import BotChuCore
@testable import BotChu

/// #261: a task whose turn ends saying its work goes on, with nothing running, hears BotChu's
/// heartbeat a little later, at most `Heartbeat.maxPulses` times in a row.
extension RenderingTests {
    /// Says its tests are still running, except to a heartbeat when `ack` is in the folder, and to
    /// "done", which it answers as finished.
    static let heartbeatCLI = #"""
    import json, os, sys
    with open("calls.jsonl", "a") as file:
        file.write(json.dumps(sys.argv[1:]) + "\n")
    print(json.dumps({"type":"thread.started", "thread_id":"fixture-session"}), flush=True)
    prompt = sys.argv[-1].splitlines()[-1]
    if prompt == "done":
        reply = "Merged and cleaned up."
    elif "BotChu heartbeat" in prompt and os.path.exists("ack"):
        reply = "HEARTBEAT_OK"
    else:
        reply = "Pushed. The full test suite is still running; I'll report back when it finishes."
    print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":reply}}), flush=True)
    print(json.dumps({"type":"turn.completed"}), flush=True)
    """#

    private func heartbeatFixture(ack: Bool) throws -> PersistenceFixture {
        let fixture = try PersistenceFixture(control: StorageControl(), script: Self.heartbeatCLI)
        if ack { FileManager.default.createFile(atPath: (fixture.app.task(fixture.task)!.folder! as NSString).appendingPathComponent("ack"), contents: nil) }
        return fixture
    }

    @Test func aTurnThatLeavesWorkGoingIsCheckedOnAndItsAcknowledgementLeavesANote() async throws {
        let saved = Heartbeat.delays
        Heartbeat.delays = [0.3, 0.3, 0.3]
        defer { Heartbeat.delays = saved }
        let fixture = try heartbeatFixture(ack: true)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.task

        #expect(app.send("fix it", to: target))
        try await fixture.wait { fixture.calls(target) == 2 && !app.isRunning(target) }
        let thread = app.thread(target)
        let heartbeat = try #require(thread.first { $0.heartbeat != nil })
        #expect(heartbeat.heartbeat == 1)
        #expect(heartbeat.role == .user)
        #expect(heartbeat.text.hasPrefix("BotChu heartbeat (1 of 3): "))
        // Its bare acknowledgement isn't shown, just a note.
        #expect(!thread.contains { $0.role == .assistant && $0.text.contains(Heartbeat.ack) })
        #expect(thread.last?.text == Heartbeat.acknowledged)
        try await Task.sleep(for: .milliseconds(800))
        #expect(fixture.calls(target) == 2, "Nothing more after the acknowledgement")
    }

    @Test func anyMessageBeforeTheHeartbeatAnswersIt() async throws {
        let saved = Heartbeat.delays
        Heartbeat.delays = [1, 1, 1]
        defer { Heartbeat.delays = saved }
        let fixture = try heartbeatFixture(ack: false)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.task

        #expect(app.send("fix it", to: target))
        try await fixture.wait { fixture.calls(target) == 1 && !app.isRunning(target) }
        #expect(app.pendingHeartbeats[target] != nil)
        #expect(app.send("done", to: target))
        try await fixture.wait { fixture.calls(target) == 2 && !app.isRunning(target) }
        #expect(app.pendingHeartbeats[target] == nil, "A finished reply plans none")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(fixture.calls(target) == 2)
        #expect(!app.thread(target).contains { $0.heartbeat != nil })
    }

    @Test func aTaskThatStillStallsIsLeftAfterTheLastHeartbeat() async throws {
        let saved = Heartbeat.delays
        Heartbeat.delays = [0.2, 0.2, 0.2]
        defer { Heartbeat.delays = saved }
        let fixture = try heartbeatFixture(ack: false)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.task

        #expect(app.send("fix it", to: target))
        try await fixture.wait { fixture.calls(target) == 4 && !app.isRunning(target) && app.thread(target).last?.text == Heartbeat.gaveUp }
        #expect(app.thread(target).compactMap(\.heartbeat) == [1, 2, 3])
        try await Task.sleep(for: .milliseconds(600))
        #expect(fixture.calls(target) == 4)
    }

    @Test func turnedOffNoHeartbeatIsPlanned() async throws {
        let fixture = try heartbeatFixture(ack: false)
        defer { fixture.cleanUp() }
        let app = fixture.app, target = fixture.task
        app.settings.heartbeat = false
        #expect(app.send("fix it", to: target))
        try await fixture.wait { fixture.calls(target) == 1 && !app.isRunning(target) }
        #expect(app.pendingHeartbeats[target] == nil)
    }
}
