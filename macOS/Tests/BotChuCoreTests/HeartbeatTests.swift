import Foundation
import Testing
@testable import BotChuCore

@Suite struct HeartbeatTests {
    /// #261: the replies three tasks ended on while nothing ran any more.
    @Test func repliesThatSayWorkGoesOnPromiseMore() {
        #expect(Heartbeat.promisesMore("Pushed the fix. The full test suite is running through the gate now; I'll report back when it finishes."))
        #expect(Heartbeat.promisesMore("PR #256 is open. Tests are still running in the background."))
        #expect(Heartbeat.promisesMore("Started the merge train. I’ll let you know once it’s merged."))
        #expect(Heartbeat.promisesMore("Waiting for the tests to pass, then I merge."))
        #expect(Heartbeat.promisesMore("Kicked off `scripts/test.sh`. I'll check back on it shortly."))
    }

    @Test func finishedRepliesAndTheOwnersSideDoNot() {
        #expect(!Heartbeat.promisesMore("Merged #256 and removed its worktree. Nothing else is open."))
        #expect(!Heartbeat.promisesMore("The PR is ready. Let me know when it's done and I'll merge it once you approve."))
        #expect(!Heartbeat.promisesMore("Should I go on? If you want, I can report back on the other repos too."))
        #expect(!Heartbeat.promisesMore(""))
    }

    @Test func onlyTheEndOfALongReplyCounts() {
        let reply = "I'll report back when it finishes. " + String(repeating: "Details of what changed. ", count: 60) + "All done."
        #expect(!Heartbeat.promisesMore(reply))
    }

    @Test func acknowledgementsAreTheTokenWithAtMostAShortRemark() {
        #expect(Heartbeat.isAck("HEARTBEAT_OK"))
        #expect(Heartbeat.isAck("  **HEARTBEAT_OK**\n"))
        #expect(Heartbeat.isAck("`HEARTBEAT_OK`."))
        #expect(Heartbeat.isAck("Checked: the PR merged and the worktree is gone. HEARTBEAT_OK"))
        #expect(!Heartbeat.isAck("All green, merging now."))
        #expect(!Heartbeat.isAck("I'll mention HEARTBEAT_OK only if nothing is left, but tests failed, so fixing them."))
        #expect(!Heartbeat.isAck(String(repeating: "Long report. ", count: 40) + "HEARTBEAT_OK"))
    }

    @Test func aStalledTurnIsPulsedThreeTimesInARowAtMost() {
        let promise = "Tests are still running; I'll report back."
        #expect(Heartbeat.next(after: .init(reply: promise)) == .pulse(number: 1, after: 120, stall: .promised))
        #expect(Heartbeat.next(after: .init(reply: promise, pulse: 1)) == .pulse(number: 2, after: 600, stall: .promised))
        #expect(Heartbeat.next(after: .init(reply: promise, pulse: 2)) == .pulse(number: 3, after: 1800, stall: .promised))
        #expect(Heartbeat.next(after: .init(reply: promise, pulse: 3)) == .gaveUp)
    }

    @Test func backgroundTasksEndedUnfinishedStallWhateverTheReplySaid() {
        #expect(Heartbeat.next(after: .init(reply: "Done.", endedBackgroundTasks: true))
            == .pulse(number: 1, after: 120, stall: .backgroundEnded))
    }

    @Test func finishedStoppedFailedOrAcknowledgedTurnsAreLeftAlone() {
        let promise = "I'll report back when it finishes."
        #expect(Heartbeat.next(after: .init(reply: "Merged.")) == .none)
        #expect(Heartbeat.next(after: .init(reply: nil)) == .none)
        #expect(Heartbeat.next(after: .init(reply: promise, stopped: true)) == .none)
        #expect(Heartbeat.next(after: .init(reply: promise, failed: true)) == .none)
        #expect(Heartbeat.next(after: .init(reply: "HEARTBEAT_OK", pulse: 1, endedBackgroundTasks: true)) == .none)
    }

    @Test func thePromptAsksForTheAcknowledgementWhenNothingIsLeft() {
        let prompt = Heartbeat.prompt(.promised, number: 2)
        #expect(prompt.hasPrefix("BotChu heartbeat (2 of 3): "))
        #expect(prompt.hasSuffix("reply with just HEARTBEAT_OK."))
        #expect(Heartbeat.prompt(.backgroundEnded, number: 1).contains("background tasks"))
    }

    @Test func aHeartbeatMessageKeepsItsNumberWhenSaved() throws {
        var message = ChatMessage(role: .user, text: Heartbeat.prompt(.promised, number: 1))
        message.heartbeat = 1
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.heartbeat == 1)
        let older = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"id":"\#(UUID())","role":"user","text":"hi","date":0}"#.utf8))
        #expect(older.heartbeat == nil)
    }
}
