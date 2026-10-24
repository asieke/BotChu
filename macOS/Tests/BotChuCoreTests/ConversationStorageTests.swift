import Foundation
import Testing
@testable import BotChuCore

/// #107: a conversation's transcript and queue are saved off the main thread, and #77's and #79's
/// guarantees hold whatever the order the writes and the CLI's messages come in: a message the CLI
/// took is never lost nor sent again, and only the messages a written transcript holds leave the
/// saved queue.
@MainActor @Suite struct ConversationStorageTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-conversation-storage-\(UUID().uuidString)")
        let home: BotHome
        let trace = StorageQueueTests.Trace()
        let storage: StorageQueue
        let files: ConversationStorage
        var queue = MessageQueue()
        var failures: [SaveFailure] = []
        /// Where the conversation's files are now, when its bot moved; `files` otherwise.
        var moved: ConversationStorage?

        @MainActor init() throws {
            home = BotHome(workspace: root.path)
            try home.save(Bot(name: "Fixture", workspace: root.path))
            storage = StorageQueue(before: trace.record)
            files = ConversationStorage(storage: storage, home: home, task: nil)
        }

        @MainActor var access: ConversationStorage.Queue {
            ConversationStorage.Queue(get: { [unowned self] in queue }, set: { [unowned self] in queue = $0 }, files: { [unowned self] in moved ?? files })
        }

        @MainActor func save(_ transcript: [ChatMessage], done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
            files.saveTranscript(transcript, queue: access, failed: { [unowned self] in failures += $0 }, done: done)
        }

        func lock(_ url: URL, _ locked: Bool) throws {
            try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path)
        }

        var takenURL: URL { home.url.appendingPathComponent("taken.jsonl") }

        /// The queue a relaunch finds, and the transcript it recovers.
        func relaunch() -> (transcript: [ChatMessage], queue: MessageQueue) {
            var transcript = home.loadThread()
            let recovered = home.recoverQueue(transcript: &transcript)
            return (transcript, recovered.queue)
        }

        func remove() {
            for url in [home.url, home.threadURL, home.queueURL(), takenURL] { try? lock(url, false) }
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }

    /// A follow-up taken while an older transcript is being written stays taken: only the messages
    /// the written transcript holds leave the queue, from the queue as it is once that write is done.
    @Test func aFollowUpTakenWhileAnOlderTranscriptIsWrittenStaysTakenUntilOneHoldsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lane = fixture.files.lane
        var transcript = [Self.user("start")]
        let first = Self.user("first follow-up"), second = Self.user("second follow-up")
        for message in [first, second] { fixture.queue.enqueue(message) }
        try fixture.home.saveQueue(fixture.queue)
        fixture.queue.markInFlight(first.id)
        fixture.queue.markInFlight(second.id)
        _ = fixture.queue.acknowledge()
        transcript.append(first)
        fixture.trace.hold(lane)
        fixture.save(transcript)
        // The CLI takes the second while the transcript holding the first is being written.
        for _ in 0..<200 where fixture.trace.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        _ = fixture.queue.acknowledge()
        transcript.append(second)
        #expect(fixture.queue.taken.map(\.text) == ["first follow-up", "second follow-up"])
        fixture.trace.release(lane)
        await fixture.storage.settle()
        #expect(fixture.queue.taken.map(\.text) == ["second follow-up"], "Only what the written transcript holds left the queue")
        // A relaunch now loses nothing and sends nothing again: the second is in the saved queue as taken.
        let between = fixture.home.loadQueue(delivered: fixture.home.loadThread())
        #expect(fixture.home.loadThread().filter { $0.role == .user }.map(\.text) == ["start", "first follow-up"])
        #expect(between.taken.map(\.text) == ["second follow-up"])
        #expect(between.messages.isEmpty)
        fixture.save(transcript)
        await fixture.storage.settle()
        #expect(fixture.queue.taken.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.takenURL.path))
        #expect(fixture.home.loadThread().filter { $0.role == .user }.map(\.text) == ["start", "first follow-up", "second follow-up"])
        #expect(fixture.failures.isEmpty)
    }

    /// The transcript can't be written while it holds a taken message: the message stays in the saved
    /// queue as taken, pending ones pause, the failure is shown once, and a relaunch puts it back.
    @Test func aTranscriptThatCantBeWrittenKeepsTheTakenMessageInTheQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.home.saveThread([Self.user("start")])
        let taken = Self.user("steer"), pending = Self.user("later")
        fixture.queue.enqueue(taken)
        fixture.queue.enqueue(pending)
        fixture.queue.markInFlight(taken.id)
        _ = fixture.queue.acknowledge()
        try fixture.lock(fixture.home.threadURL, true)
        let saved = Box()
        fixture.save([Self.user("start"), taken]) { saved.value = $0 }
        await fixture.storage.settle()
        #expect(saved.value == false)
        #expect(fixture.queue.isPaused)
        #expect(fixture.queue.taken.map(\.text) == ["steer"])
        #expect(fixture.failures.map(\.item) == [.conversation(paused: true)])
        try fixture.lock(fixture.home.threadURL, false)
        let relaunched = fixture.relaunch()
        #expect(relaunched.transcript.filter { $0.role == .user }.map(\.text) == ["start", "steer"])
        #expect(relaunched.queue.messages.map(\.text) == ["later"])
        #expect(relaunched.queue.isPaused)
    }

    /// The transcript is written but the queue can't be: the failure is shown, the taken message is
    /// in the saved transcript, so a relaunch neither loses it nor sends it again.
    @Test func aQueueThatCantBeWrittenAfterItsTranscriptLosesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let taken = Self.user("steer")
        fixture.queue.enqueue(taken)
        fixture.queue.markInFlight(taken.id)
        _ = fixture.queue.acknowledge()
        // The CLI's take was saved in the queue before; now the queue's file can't change.
        try fixture.home.saveQueue(fixture.queue)
        try fixture.lock(fixture.takenURL, true)
        try fixture.lock(fixture.home.queueURL(), true)
        fixture.save([Self.user("start"), taken])
        await fixture.storage.settle()
        #expect(fixture.failures.map(\.item) == [.pendingMessages])
        #expect(fixture.queue.taken.isEmpty, "The saved transcript holds it")
        let relaunched = fixture.relaunch()
        #expect(relaunched.transcript.filter { $0.role == .user }.map(\.text) == ["start", "steer"])
        #expect(relaunched.queue.messages.isEmpty)
    }

    /// Neither can be written: the conversation says so, delivery pauses, and the files are as they
    /// were, with the take recorded earlier still there for a relaunch.
    @Test func whenNeitherCanBeWrittenTheFilesStayAsTheyWereAndItSaysSo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.home.saveThread([Self.user("start")])
        let taken = Self.user("steer"), pending = Self.user("later")
        fixture.queue.enqueue(taken)
        fixture.queue.enqueue(pending)
        fixture.queue.markInFlight(taken.id)
        _ = fixture.queue.acknowledge()
        try fixture.home.saveQueue(fixture.queue)
        for url in [fixture.home.threadURL, fixture.takenURL, fixture.home.queueURL()] { try fixture.lock(url, true) }
        fixture.save([Self.user("start"), taken])
        await fixture.storage.settle()
        #expect(fixture.failures.map(\.item) == [.conversation(paused: true), .pendingMessages])
        #expect(fixture.queue.isPaused)
        #expect(fixture.queue.next == nil)
        for url in [fixture.home.threadURL, fixture.takenURL, fixture.home.queueURL()] { try fixture.lock(url, false) }
        let relaunched = fixture.relaunch()
        #expect(relaunched.transcript.filter { $0.role == .user }.map(\.text) == ["start", "steer"])
        #expect(relaunched.queue.messages.map(\.text) == ["later"])
    }

    /// A message a turn starts with stays in the saved queue until a saved transcript holds it, and
    /// waits again when that transcript can't be saved.
    @Test func aMessageStartingATurnLeavesTheSavedQueueOnlyOnceTheTranscriptHoldsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let message = Self.user("hello")
        fixture.queue.enqueue(message)
        try fixture.home.saveQueue(fixture.queue)
        fixture.queue.deliver(message.id)
        #expect(fixture.queue.pending.isEmpty)
        #expect(fixture.queue.next == nil)
        try fixture.lock(fixture.home.threadURL.deletingLastPathComponent(), true)
        fixture.save([message])
        await fixture.storage.settle()
        try fixture.lock(fixture.home.threadURL.deletingLastPathComponent(), false)
        #expect(fixture.queue.delivering == [message.id], "Not saved: still waiting for a transcript")
        #expect(fixture.home.loadQueuedMessages().map(\.id) == [message.id])
        fixture.save([message])
        await fixture.storage.settle()
        #expect(fixture.queue.messages.isEmpty)
        #expect(fixture.queue.delivering.isEmpty)
        #expect(fixture.home.loadQueuedMessages().isEmpty)
        #expect(fixture.home.loadThread().map(\.id) == [message.id])
    }

    /// The bot moves while its transcript is being written: the queue saved after that write goes
    /// where the conversation is now, and nothing is written in the old folder after it.
    @Test func theQueueSavedAfterATranscriptGoesWhereTheConversationIsThen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = BotHome(workspace: fixture.root.appendingPathComponent("moved").path)
        let taken = Self.user("steer")
        fixture.queue.enqueue(taken)
        fixture.queue.markInFlight(taken.id)
        _ = fixture.queue.acknowledge()
        fixture.trace.hold(fixture.files.lane)
        fixture.save([Self.user("start"), taken])
        for _ in 0..<200 where fixture.trace.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        fixture.moved = ConversationStorage(storage: fixture.storage, home: destination, task: nil)
        fixture.trace.release(fixture.files.lane)
        await fixture.storage.settle()
        #expect(fixture.queue.taken.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.queueURL().path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.queueURL().path))
    }

    /// However many saves are asked for while one is written, the file ends with the newest, and
    /// the main actor never waits for any of them.
    @Test func lateSavesNeverOverwriteANewerTranscript() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.trace.slow(0.05)
        var transcript: [ChatMessage] = []
        let started = Date()
        for n in 0..<20 {
            transcript.append(Self.user("message \(n)"))
            fixture.save(transcript)
            fixture.files.saveQueue(fixture.queue)
        }
        #expect(Date().timeIntervalSince(started) < 0.05, "Asking to save never waits for a write")
        await fixture.storage.settle()
        #expect(fixture.home.loadThread().map(\.text) == transcript.map(\.text))
        #expect(fixture.storage.stats.coalesced > 0)
        #expect(!fixture.trace.ranOnMain)
    }

    final class Box: @unchecked Sendable {
        var value: Bool?
    }
}
