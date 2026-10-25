import Foundation
import Testing
@testable import BotChuCore

/// #109: conversations are read when they are needed. A transcript's digest is kept beside it and
/// never describes a transcript changed since; recovery reads a transcript only when messages wait
/// for it; a read's result is taken only while it is the latest; and inactive histories leave
/// memory within a byte budget, never one that is pinned.
@Suite struct HistoryTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-history-\(UUID().uuidString)")
        let home: BotHome
        let task = UUID()

        init() throws {
            home = BotHome(workspace: root.path)
            try home.save(Bot(name: "Fixture", workspace: root.path))
            HistoryCounters.shared.reset(under: root)
        }

        var counts: HistoryCounters.Counts { HistoryCounters.shared.counts(under: root) }
        func decoded(_ url: URL) -> Int { HistoryCounters.shared.decodedFiles(under: root)[url.path] ?? 0 }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    static func thread(_ replies: Int, error: String? = nil) -> [ChatMessage] {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var messages: [ChatMessage] = []
        for i in 0..<replies {
            messages.append(ChatMessage(role: .user, text: "Question \(i)", date: start.addingTimeInterval(Double(i) * 10)))
            messages.append(ChatMessage(role: .tool, date: start.addingTimeInterval(Double(i) * 10 + 1), toolID: "t\(i)", toolName: "Read",
                                        toolInput: "/tmp/file\(i)", toolOutput: "line\n", toolState: .done))
            messages.append(ChatMessage(role: .assistant, text: "Answer \(i)", date: start.addingTimeInterval(Double(i) * 10 + 2)))
        }
        if let error { messages.append(ChatMessage(role: .error, text: error, date: start.addingTimeInterval(Double(replies) * 10))) }
        messages.append(ChatMessage(role: .note, text: "a note", date: start.addingTimeInterval(Double(replies) * 10 + 5)))
        return messages
    }

    // MARK: Digest and index

    @Test func aDigestHasTheSummaryAndTheStartOfTheLastReply() {
        let messages = Self.thread(3, error: "It broke")
        let digest = ThreadDigest(messages)
        #expect(digest.summary == ThreadSummary(messages))
        #expect(digest.summary.messageCount == 6)
        #expect(digest.summary.lastError == "It broke")
        #expect(digest.count == messages.count)
        #expect(digest.lastReply == "Answer 2")
        #expect(!digest.lastReplyCut)

        let long = String(repeating: "word ", count: 600)
        let cut = ThreadDigest([ChatMessage(role: .assistant, text: "  \n" + long)])
        #expect(cut.lastReply?.count == ThreadDigest.replyKept)
        #expect(cut.lastReplyCut)
        #expect(ThreadDigest([]).lastReply == nil)
    }

    @Test func aReportFromADigestReadsAsOneFromTheWholeReply() {
        let bot = Bot(name: "Reporter", workspace: "/tmp/reporter")
        let task = BotTask(for: bot, repo: "o/r", checkout: "/tmp/r", work: nil, brief: "Do it")
        let status = BotStatus.make(settings: task, summary: ThreadSummary(), run: nil)
        let long = String(repeating: "a", count: 3_000)
        let whole = BotContext.taskReport(task, status: status, pullRequest: 4, lastReply: long)
        let digest = ThreadDigest([ChatMessage(role: .assistant, text: long)])
        #expect(BotContext.taskReport(task, status: status, pullRequest: 4, lastReply: digest.lastReply, replyCut: digest.lastReplyCut) == whole)
        #expect(BotContext.taskReport(task, status: status, pullRequest: 4, lastReply: digest.lastReply, replyCut: digest.lastReplyCut, replyLimit: 240)
            == BotContext.taskReport(task, status: status, pullRequest: 4, lastReply: long, replyLimit: 240))
        let short = ThreadDigest([ChatMessage(role: .assistant, text: "Done.")])
        #expect(BotContext.taskReport(task, status: status, pullRequest: nil, lastReply: short.lastReply, replyCut: short.lastReplyCut)
            == BotContext.taskReport(task, status: status, pullRequest: nil, lastReply: "Done."))
    }

    @Test func savingATranscriptSavesItsIndexAndTheDigestReadsWithoutTheTranscript() throws {
        let fixture = try Fixture()
        let messages = Self.thread(20)
        try fixture.home.writeTranscript(messages, task: fixture.task)
        #expect(FileManager.default.fileExists(atPath: fixture.home.indexURL(task: fixture.task).path))
        HistoryCounters.shared.reset(under: fixture.root)
        #expect(fixture.home.readDigest(task: fixture.task) == ThreadDigest(messages))
        #expect(fixture.counts.reads == 0)
        #expect(fixture.counts.decoded == 0)
        #expect(fixture.counts.indexReads == 1)
        // A conversation with no transcript is empty.
        #expect(fixture.home.readDigest(task: UUID()) == ThreadDigest([]))
    }

    @Test func aTranscriptChangedOutsideBotChuIsNeverDescribedByItsOldIndex() throws {
        let fixture = try Fixture()
        let url = fixture.home.transcriptURL(task: fixture.task)
        try fixture.home.writeTranscript(Self.thread(5), task: fixture.task)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        // The same size, in place (the same inode), with the modification date put back.
        var data = try Data(contentsOf: url)
        let range = try #require(data.range(of: Data("Answer 4".utf8)))
        data.replaceSubrange(range, with: Data("Answer X".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: data)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let kept = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        #expect(abs(kept.timeIntervalSince(modified)) < 0.001)
        #expect(try Data(contentsOf: url).count == data.count)
        #expect(fixture.home.readDigest(task: fixture.task) == nil)

        // Reading it finds the change, makes the index again, and the digest is the new one's.
        let load = fixture.home.loadHistory(task: fixture.task)
        #expect(load.reindexed)
        #expect(load.messages.last(where: { $0.role == .assistant })?.text == "Answer X")
        #expect(fixture.home.readDigest(task: fixture.task)?.lastReply == "Answer X")
        // Read again unchanged, the index stands.
        #expect(!fixture.home.loadHistory(task: fixture.task).reindexed)
    }

    @Test func anIndexWhoseStampMatchesButWhoseEndDoesntIsStale() throws {
        let fixture = try Fixture()
        try fixture.home.writeTranscript(Self.thread(5), task: fixture.task)
        let indexURL = fixture.home.indexURL(task: fixture.task)
        var index = try JSONDecoder().decode(TranscriptIndex.self, from: Data(contentsOf: indexURL))
        index.tail = "0"
        try JSONEncoder().encode(index).write(to: indexURL)
        #expect(fixture.home.readDigest(task: fixture.task) == nil)
        index.tail = try ContentHash.tail(of: Data(contentsOf: fixture.home.transcriptURL(task: fixture.task)))
        index.version = TranscriptIndex.currentVersion + 1
        try JSONEncoder().encode(index).write(to: indexURL)
        #expect(fixture.home.readDigest(task: fixture.task) == nil)
        try Data("not json".utf8).write(to: indexURL)
        #expect(fixture.home.readDigest(task: fixture.task) == nil)
        try FileManager.default.removeItem(at: indexURL)
        #expect(fixture.home.readDigest(task: fixture.task) == nil)
    }

    @Test func aMissingIndexIsMadeAgainFromAnOlderJSONLOnlyTranscript() throws {
        let fixture = try Fixture()
        let messages = Self.thread(8, error: "late failure")
        try fixture.home.writeTranscript(messages)
        try FileManager.default.removeItem(at: fixture.home.indexURL())
        #expect(fixture.home.readDigest() == nil)
        #expect(fixture.home.rebuildDigest() == ThreadDigest(messages))
        #expect(fixture.home.readDigest() == ThreadDigest(messages))
        // Nothing was written but the index.
        #expect(fixture.counts.writes == 1)
        #expect(fixture.counts.indexWrites == 2)
    }

    @Test func rebuildingADamagedTranscriptsDigestNeitherRepairsNorCopiesIt() throws {
        let fixture = try Fixture()
        let url = fixture.home.transcriptURL(task: fixture.task)
        try fixture.home.writeTranscript(Self.thread(2), task: fixture.task)
        let original = try Data(contentsOf: url) + Data("{not json\n".utf8)
        try original.write(to: url)
        HistoryCounters.shared.reset(under: fixture.root)
        #expect(fixture.home.rebuildDigest(task: fixture.task).summary.messageCount == 4)
        #expect(try Data(contentsOf: url) == original)
        #expect(fixture.counts.copies == 0)
        #expect(fixture.counts.repairs == 0)
        #expect(fixture.counts.writes == 0)
        // Opening it keeps the original and notes what was left out (#79), with the index.
        let load = fixture.home.loadHistory(task: fixture.task)
        #expect(load.messages.last?.role == .note)
        #expect(fixture.counts.copies == 1)
        let kept = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.contains(".unreadable-") }
        #expect(kept.count == 1)
        #expect(fixture.home.readDigest(task: fixture.task) == load.digest)
    }

    // MARK: Recovery

    @Test func recoveryLeavesATranscriptUnreadWhenNothingWaitsInItsQueue() throws {
        let fixture = try Fixture()
        let messages = Self.thread(30)
        try fixture.home.writeTranscript(messages, task: fixture.task)
        HistoryCounters.shared.reset(under: fixture.root)
        let recovery = fixture.home.recover(task: fixture.task)
        #expect(recovery.history == nil)
        #expect(recovery.digest == ThreadDigest(messages))
        #expect(recovery.queue == MessageQueue())
        #expect(fixture.decoded(fixture.home.transcriptURL(task: fixture.task)) == 0)
        #expect(fixture.counts.writes == 0)
    }

    @Test func recoveryReadsTheTranscriptForMessagesWaitingOrTaken() throws {
        let fixture = try Fixture()
        var messages = Self.thread(3)
        let delivered = ChatMessage(role: .user, text: "already in the transcript")
        messages.append(delivered)
        try fixture.home.writeTranscript(messages, task: fixture.task)
        let waiting = ChatMessage(role: .user, text: "send me")
        let taken = ChatMessage(role: .user, text: "the CLI took me")
        var queue = MessageQueue(saved: [delivered, waiting])
        queue.enqueue(taken)
        queue.markInFlight(taken.id)
        _ = queue.acknowledge()
        try fixture.home.saveQueue(queue, task: fixture.task)

        let recovery = fixture.home.recover(task: fixture.task)
        let history = try #require(recovery.history)
        #expect(recovery.queue.messages.map(\.text) == ["send me"])
        #expect(recovery.queue.taken.isEmpty)
        #expect(history.messages.contains { $0.id == taken.id })
        #expect(history.messages.last?.role == .note)
        // What recovery put back is saved, transcript and index, before anything is sent.
        #expect(fixture.home.loadThread(task: fixture.task).map(\.id) == history.messages.map(\.id))
        #expect(fixture.home.readDigest(task: fixture.task) == history.digest)
        #expect(fixture.home.readTakenMessages(task: fixture.task).messages.isEmpty)
        // A second launch finds nothing more to put back.
        let again = fixture.home.recover(task: fixture.task)
        #expect(again.history?.messages.map(\.id) == history.messages.map(\.id))
        #expect(again.queue.messages.map(\.text) == ["send me"])
    }

    @Test func recoveryOfAConversationInMemoryUsesItsTranscript() throws {
        let fixture = try Fixture()
        try fixture.home.writeTranscript(Self.thread(1), task: fixture.task)
        let memory = Self.thread(2)
        let recovery = fixture.home.recover(task: fixture.task, transcript: memory)
        #expect(recovery.history?.messages == memory)
        #expect(fixture.decoded(fixture.home.transcriptURL(task: fixture.task)) == 0)
    }

    // MARK: State and budget

    @Test func onlyTheLatestReadOrRecoveryIsTaken() throws {
        var state = HistoryState(recovery: .none)
        #expect(!state.isBusy)
        let first = try #require(state.begin(load: true, recover: true) as Int?)
        #expect(state.isBusy)
        let during = state.begin(load: true, recover: false)
        #expect(during == nil)
        // Moved meanwhile: back to where it was, and the first read's result is never taken.
        state.abandon(first)
        #expect(state.phase == .unloaded)
        #expect(state.recovery == .none)
        var taken = state.finish(first, loaded: true, recovered: true)
        #expect(!taken)
        let second = try #require(state.begin(load: false, recover: true) as Int?)
        #expect(state.phase == .unloaded)
        taken = state.finish(second, loaded: false, recovered: true)
        #expect(taken)
        #expect(state.recovery == .recovered)
        #expect(state.phase == .unloaded)
        let nothing = state.begin(load: false, recover: false)
        #expect(nothing == nil)
        let read = try #require(state.begin(load: true, recover: false) as Int?)
        taken = state.finish(read, loaded: true, recovered: false)
        #expect(taken)
        #expect(state.isLoaded)
        #expect(state.recovery == .recovered)
        let again = state.begin(load: true, recover: false)
        #expect(again == nil)
        // Dropped from memory, then read again: an older read's result isn't taken.
        var evicted = state.evict()
        #expect(evicted)
        #expect(state.phase == .unloaded)
        let third = try #require(state.begin(load: true, recover: false) as Int?)
        evicted = state.evict()
        #expect(!evicted)
        state.adopt()
        taken = state.finish(third, loaded: true, recovered: false)
        #expect(!taken)
        #expect(state.isLoaded)
        #expect(HistoryState.created.isLoaded && HistoryState.created.recovery == .recovered)
    }

    @Test func recoveringAConversationInMemoryKeepsItInMemory() throws {
        var state = HistoryState.created
        let ticket = try #require(state.begin(load: true, recover: true) as Int?)
        #expect(state.isLoaded)
        let taken = state.finish(ticket, loaded: false, recovered: true)
        #expect(taken)
        #expect(state.isLoaded)
    }

    @Test func theBudgetDropsTheLeastRecentlyUsedInactiveHistoriesFirst() {
        var budget = HistoryBudget<String>(limit: 100)
        budget.use("a", bytes: 60)
        budget.use("b", bytes: 30)
        budget.use("c", bytes: 50)
        #expect(budget.overflow { _ in false } == ["a"])
        // Shown or running: never dropped, and not counted against the limit.
        #expect(budget.overflow { $0 == "a" } == [])
        budget.use("a", bytes: 60)
        #expect(budget.order == ["b", "c", "a"])
        #expect(budget.overflow { _ in false } == ["b", "c"])
        #expect(budget.overflow { $0 == "c" } == [])
        budget.remove("a")
        #expect(budget.total == 80)
        #expect(budget.overflow { _ in false } == [])
        #expect(HistoryBudget<String>.estimate(Self.thread(1)) > 3 * 200)
    }

    @Test func countersAreKeptPerFolder() throws {
        let one = try Fixture(), two = try Fixture()
        try one.home.writeTranscript(Self.thread(2))
        _ = one.home.loadHistory()
        #expect(one.counts.reads == 1)
        #expect(one.counts.decoded == 7)
        #expect(two.counts == HistoryCounters.Counts())
    }
}
