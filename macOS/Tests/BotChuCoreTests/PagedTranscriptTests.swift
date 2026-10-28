import Foundation
import Testing
@testable import BotChuCore

extension HistoryTests {
    static func pagedFixture(_ count: Int) -> [ChatMessage] {
        (0..<count).map { i in
            ChatMessage(role: i % 2 == 0 ? .user : .assistant, text: String(format: "%06d ", i) + String(repeating: "payload ", count: 16),
                        date: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
        }
    }

    @Test(arguments: [5_000, 50_000])
    func indexedOpeningAndCheckpointsHaveBoundedPayloadWork(_ count: Int) throws {
        let fixture = try Fixture()
        let messages = Self.pagedFixture(count)
        try fixture.home.writeTranscript(messages)
        let original = try Data(contentsOf: fixture.home.threadURL)
        HistoryCounters.shared.reset(under: fixture.root)
        let loaded = fixture.home.loadHistory()
        #expect(loaded.messages == Array(messages.suffix(PagedTranscript.residentLimit)))
        #expect(loaded.start == count - PagedTranscript.residentLimit)
        #expect(loaded.digest == ThreadDigest(messages))
        #expect(!loaded.reindexed)
        #expect(fixture.counts.decoded <= PagedTranscript.residentLimit + PagedTranscript.pageSize)
        #expect(fixture.counts.bytesRead < 150_000)
        let beforeSave = fixture.counts
        var tail = loaded.messages
        tail[tail.count - 1].text += " changed"
        try fixture.home.writeTranscript(.init(tail, start: loaded.start, base: loaded.messages))
        #expect(fixture.counts.encoded - beforeSave.encoded == 1)
        #expect(fixture.counts.bytesWritten - beforeSave.bytesWritten < 1_000)
        #expect(fixture.counts.journalBytesWritten - beforeSave.journalBytesWritten < 2_000)
        // The ordinary path still holds complete ordered history, without rewriting its prefix.
        let saved = try Data(contentsOf: fixture.home.threadURL)
        let lastLine = try BotHome.encodeThread([messages.last!]).count
        #expect(saved.prefix(original.count - lastLine) == original.prefix(original.count - lastLine))
        let all = fixture.home.loadThread()
        #expect(all.map(\.id) == messages.map(\.id))
        #expect(all.last == tail.last)
        HistoryCounters.shared.reset(under: fixture.root)
        try fixture.home.writeTranscript(.init(tail, start: loaded.start, base: tail))
        #expect(fixture.counts.encoded == 0 && fixture.counts.writes == 0)
        let old = fixture.home.loadHistory(before: 256, limit: 128)
        #expect(old.messages == Array(messages[128..<256]))
        #expect(old.start == 128)
    }

    @Test func resumeContextAndReportsReachBeyondAToolOnlyTail() throws {
        let fixture = try Fixture()
        let conversation = Self.pagedFixture(200)
        let receipt = ChatMessage(role: .receipt, text: "An earlier task completed", taskID: UUID())
        let tools = (0..<1_000).map { ChatMessage(role: .tool, toolID: "call-\($0)", toolOutput: "large output", toolState: .done) }
        let messages = conversation + [receipt] + tools
        try fixture.home.writeTranscript(messages)
        let tail = fixture.home.loadHistory()
        #expect(tail.messages.allSatisfy { $0.role == .tool })
        #expect(tail.digest.lastReply == conversation.last?.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let context = try PagedTranscript.context(fixture.home.threadURL)
        #expect(BotContext.recap(context) == BotContext.recap(messages))
        #expect(context.first(where: { $0.id == receipt.id })?.text == receipt.text)
        #expect(context.filter { $0.role == .tool }.allSatisfy { $0.toolOutput == nil })
        #expect(try PagedTranscript.context(fixture.home.threadURL, through: conversation[20].id).last?.id == conversation[20].id)
    }

    @Test func externalEditsAndAppendsSurviveASaveOfAnAlreadyLoadedTail() throws {
        let fixture = try Fixture()
        var messages = Self.pagedFixture(1_000)
        try fixture.home.writeTranscript(messages)
        let tail = fixture.home.loadHistory()
        messages[0].text = "externally edited old page"
        messages[900].text = "externally edited tail"
        let external = ChatMessage(role: .note, text: "external append", date: Date(timeIntervalSince1970: 1_800_000_000))
        try BotHome.writeThread(messages + [external], to: fixture.home.threadURL)
        // Another reader can reindex the edit before the stale writer gets its lane.
        _ = fixture.home.loadHistory()
        var incoming = tail.messages
        incoming[incoming.count - 1].text = "streamed by app"
        let added = ChatMessage(role: .assistant, text: "new reply", date: Date(timeIntervalSince1970: 1_800_000_000))
        incoming.append(added)
        try fixture.home.writeTranscript(.init(incoming, start: tail.start, base: tail.messages))
        let all = fixture.home.loadThread()
        #expect(all.count == 1_002)
        #expect(all[0].text == messages[0].text)
        #expect(all[900].text == messages[900].text)
        #expect(all[999].text == "streamed by app")
        #expect(Array(all.suffix(2)) == [external, added])
        #expect(Set(all.map(\.id)).count == all.count)
    }

    @Test func reportsKeepTheirPrefixCountsAndReplyTruncationAcrossTailCommits() throws {
        let fixture = try Fixture()
        let reply = ChatMessage(role: .assistant, text: String(repeating: "reply ", count: 500), date: Date(timeIntervalSince1970: 1_800_000_000))
        let tools = (0..<1_000).map { ChatMessage(role: .tool, date: Date(timeIntervalSince1970: 1_800_000_000 + Double($0)), toolID: "call-\($0)", toolName: "Bash", toolState: .done) }
        try fixture.home.saveThread([reply] + tools)
        let tail = fixture.home.loadHistory()
        let more = (0..<300).map { ChatMessage(role: .tool, date: Date(timeIntervalSince1970: 1_800_001_000 + Double($0)), toolID: "new-\($0)", toolName: "Read", toolState: .done) }
        try fixture.home.writeTranscript(.init(tail.messages + more, start: tail.start, base: tail.messages))
        let loaded = fixture.home.loadHistory()
        let expected = ThreadDigest([reply] + tools + more)
        #expect(loaded.digest == expected)
        #expect(loaded.prefix.lastReplyCut)
        let recovered = fixture.home.recover(transcript: loaded.messages, start: loaded.start, prefix: loaded.prefix)
        #expect(recovered.digest == expected)
        #expect(recovered.history?.start == loaded.start)
    }

    @Test func recoveryRecognizesTakenAndQueuedIDsInCompletedPages() throws {
        let fixture = try Fixture()
        let messages = Self.pagedFixture(1_000)
        try fixture.home.writeTranscript(messages)
        let missing = ChatMessage(role: .user, text: "taken after checkpoint", date: Date(timeIntervalSince1970: 1_800_000_000))
        let pending = ChatMessage(role: .user, text: "send next", date: Date(timeIntervalSince1970: 1_800_000_000))
        try fixture.home.saveQueue(MessageQueue(saved: [messages[0], pending], taken: [messages[10], missing]))
        let recovery = fixture.home.recover()
        #expect(recovery.queue.messages == [pending])
        #expect(recovery.queue.taken.isEmpty)
        #expect(recovery.history?.start == 744)
        let all = fixture.home.loadThread()
        #expect(Array(all.prefix(1_000)) == messages)
        #expect(all.filter { $0.id == missing.id }.count == 1)
        #expect(fixture.home.recover().history?.digest.count == all.count)
    }

    @Test(arguments: ["locked-index", "corrupt-journal"])
    func fallbackReadsHonorTheRequestedRangeWithoutDuplicatingTheTail(_ failure: String) throws {
        let fixture = try Fixture()
        let messages = Self.pagedFixture(1_000)
        try fixture.home.saveThread(messages)
        let tail = fixture.home.loadHistory()
        let index = fixture.home.indexURL()
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: index.path) }
        if failure == "locked-index" {
            try Data("broken cache".utf8).write(to: index)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: index.path)
        } else {
            try Data("broken journal".utf8).write(to: PagedTranscript.commitURL(fixture.home.threadURL))
        }
        let prefix = fixture.home.loadHistory(before: tail.start, limit: Int.max)
        #expect(prefix.start == 0)
        #expect(prefix.messages + tail.messages == messages)
        let page = fixture.home.loadHistory(before: 500, limit: 128)
        #expect(page.start == 372)
        #expect(page.messages == Array(messages[372..<500]))
        #expect(page.prefix == ThreadDigest(Array(messages.prefix(372))))
        #expect(page.digest == ThreadDigest(messages))
        let newest = fixture.home.loadHistory()
        #expect(newest.messages == tail.messages)
        #expect(newest.start == tail.start)
    }
}

extension TranscriptTests {
    @Test func aLateToolResultUpdatesItsOriginalPageWithoutEncodingOtherMessages() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ChatMessage(role: .tool, date: date, toolID: "slow", toolName: "Bash", toolState: .running)
        let messages = [tool] + HistoryTests.pagedFixture(5_000)
        try home.saveThread(messages)
        let tail = home.loadHistory()
        var pending = PagedTranscript.Pending(position: 0, message: tool)
        pending.message.toolOutput = "Late output"
        pending.message.toolState = .done
        HistoryCounters.shared.reset(under: root)
        try home.writeTranscript(.init(tail.messages, start: tail.start, base: tail.messages, pending: [pending]))
        let work = HistoryCounters.shared.counts(under: root)
        #expect(work.encoded == 1)
        #expect(work.bytesCopied > 0) // exceptional compatibility-file copy, explicitly counted
        #expect(work.decoded < 512)
        let read = home.loadThread()
        #expect(read.map(\.id) == messages.map(\.id))
        #expect(read.first?.toolOutput == "Late output")
        #expect(read.first?.toolState == .done)
        #expect(home.loadHistory().digest.count == messages.count)
    }

    @Test func anInterruptedOldToolReplacementLeavesACompleteFileAndCanBeRetried() throws {
        let (root, home) = tempHome()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: home.threadURL.path)
            try? FileManager.default.removeItem(at: root)
        }
        let tool = ChatMessage(role: .tool, date: date, toolID: "slow", toolName: "Read", toolState: .running)
        let messages = [tool] + HistoryTests.pagedFixture(1_000)
        try home.saveThread(messages)
        let original = try Data(contentsOf: home.threadURL)
        let tail = home.loadHistory()
        var pending = PagedTranscript.Pending(position: 0, message: tool)
        pending.message.toolOutput = "late completion"
        pending.message.toolState = .done
        let snapshot = PagedTranscript.Snapshot(tail.messages, start: tail.start, base: tail.messages, pending: [pending])
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: home.threadURL.path)
        #expect(throws: (any Error).self) { try home.writeTranscript(snapshot) }
        #expect(try Data(contentsOf: home.threadURL) == original)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: home.threadURL.path)
        try home.writeTranscript(snapshot)
        // Simulate interruption after atomic replacement and before publication of its index.
        try FileManager.default.removeItem(at: home.indexURL())
        _ = home.loadHistory()
        #expect(home.loadThread().map(\.id) == messages.map(\.id))
        #expect(home.loadThread().first?.toolOutput == "late completion")
        HistoryCounters.shared.reset(under: root)
        try home.writeTranscript(snapshot)
        #expect(HistoryCounters.shared.counts(under: root).bytesCopied == 0)
        #expect(HistoryCounters.shared.counts(under: root).encoded == 0)
    }

    @Test func anExternalInsertionDoesNotMisplaceALateToolResult() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ChatMessage(role: .tool, date: date, toolID: "slow", toolName: "Read", toolState: .running)
        let messages = [tool] + HistoryTests.pagedFixture(1_000)
        try home.saveThread(messages)
        let tail = home.loadHistory()
        var pending = PagedTranscript.Pending(position: 0, message: tool)
        pending.message.toolOutput = "late completion"
        pending.message.toolState = .done
        let inserted = ChatMessage(role: .note, text: "external insertion", date: date)
        var edited = tool
        edited.toolInput = "external correction"
        try BotHome.writeThread([inserted, edited] + messages.dropFirst(), to: home.threadURL)
        _ = home.loadHistory() // the index is current before the stale snapshot arrives
        try home.writeTranscript(.init(tail.messages, start: tail.start, base: tail.messages, pending: [pending]))
        let saved = home.loadThread()
        #expect(saved.map(\.id) == ([inserted] + messages).map(\.id))
        #expect(saved[1].toolInput == "external correction")
        #expect(saved[1].toolOutput == "late completion")
        #expect(saved[1].toolState == .done)
    }

    @Test(arguments: ["\n", "\r\n"])
    func legacyBlankLinesAndWhitespaceDoNotChangePageBoundaries(_ newline: String) throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try home.prepare()
        let messages = HistoryTests.pagedFixture(260)
        var lines = try messages.map(line)
        lines.insert(contentsOf: ["", " \t "], at: 127)
        lines.insert("", at: 0)
        let original = Data(lines.joined(separator: newline).utf8) // no final newline
        try original.write(to: home.threadURL)
        let page = home.loadHistory(before: 131, limit: 5)
        #expect(page.messages == Array(messages[126..<131]))
        #expect(page.digest.count == 260)
        #expect(home.loadThread() == messages)
        #expect(try Data(contentsOf: home.threadURL.deletingPathExtension().appendingPathExtension("original.jsonl")) == original)
    }

    @Test(arguments: [0, 1, 2, 3])
    func corruptPageMetadataIsRebuiltWithoutTrustingItsOffsets(_ variant: Int) throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = HistoryTests.pagedFixture(400)
        try home.saveThread(messages)
        var index = try #require(PagedTranscript.validIndex(home.threadURL))
        switch variant {
        case 0: index.pages![0].offset = -1
        case 1: index.pages![1].start += 1
        case 2: index.pages![0].bytes = Int.max
        default: index.pages![0].count = -10
        }
        try JSONEncoder().encode(index).write(to: home.indexURL())
        #expect(home.readDigest() == nil)
        let page = home.loadHistory()
        #expect(page.reindexed)
        #expect(page.messages == Array(messages.suffix(256)))
        #expect(home.loadThread() == messages)
    }

    @Test(arguments: [false, true])
    func migrationKeepsOriginalBytesAndRebuildsAfterAnInterruptedIndexWrite(_ backgroundDigest: Bool) throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        try home.prepare()
        let messages = HistoryTests.pagedFixture(1_000)
        try BotHome.writeThread(messages, to: home.threadURL)
        let original = try Data(contentsOf: home.threadURL)
        if backgroundDigest { _ = home.rebuildDigest() }
        _ = home.loadHistory()
        let kept = home.threadURL.deletingPathExtension().appendingPathExtension("original.jsonl")
        #expect(try Data(contentsOf: kept) == original)
        try FileManager.default.removeItem(at: home.indexURL())
        let loaded = home.loadHistory()
        var tail = loaded.messages
        tail.append(ChatMessage(role: .note, text: "saved after migration"))
        try home.writeTranscript(.init(tail, start: loaded.start, base: loaded.messages))
        #expect(Array(home.loadThread().prefix(1_000)) == messages)
        #expect(try Data(contentsOf: kept) == original)
    }

    @Test(arguments: [0, 1, 2, 3])
    func interruptedTailCommitsReplayExactlyOnce(_ phase: Int) throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = HistoryTests.pagedFixture(400)
        try home.saveThread(messages)
        let original = try Data(contentsOf: home.threadURL)
        let old = try BotHome.encodeThread(Array(messages.suffix(2)))
        var changed = Array(messages.suffix(2))
        changed[1].text = "committed replacement with a much longer streaming suffix"
        changed.append(ChatMessage(role: .assistant, text: "committed append", date: Date(timeIntervalSince1970: 1_800_000_000)))
        let new = try BotHome.encodeThread(changed)
        let offset = original.count - old.count
        let index = try #require(PagedTranscript.validIndex(home.threadURL))
        let prefix = original[max(0, offset - TranscriptIndex.tailLength)..<offset]
        let commit = PagedTranscript.Commit(offset: offset, inode: index.stamp.inode, prefix: ContentHash.of(prefix), old: old, new: new)
        try PagedTranscript.durable(JSONEncoder().encode(commit), to: PagedTranscript.commitURL(home.threadURL))
        if phase == 1 {
            let file = try FileHandle(forWritingTo: home.threadURL)
            try file.seek(toOffset: UInt64(offset))
            try file.write(contentsOf: new.prefix(new.count / 2))
            try file.close()
        } else if phase >= 2 {
            try PagedTranscript.apply(commit, to: home.threadURL)
            if phase == 3 { try FileManager.default.removeItem(at: home.indexURL()) }
        }
        _ = home.loadHistory()
        let expected = Array(messages.dropLast(2)) + changed
        #expect(home.loadThread() == expected)
        #expect(home.loadHistory().digest == ThreadDigest(expected))
        #expect(!FileManager.default.fileExists(atPath: PagedTranscript.commitURL(home.threadURL).path))
        #expect(home.loadThread() == expected)
    }

    @Test(arguments: [0, 1, 17, 200, 500])
    func partialTailWritesAtDifferentByteCutsRecoverTheCommittedOrder(_ cut: Int) throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = HistoryTests.pagedFixture(400)
        try home.saveThread(messages)
        let old = try BotHome.encodeThread(Array(messages.suffix(3)))
        var incoming = Array(messages.suffix(3))
        incoming[0].text = "replacement"
        incoming[2].text += String(repeating: "long suffix ", count: 100)
        let new = try BotHome.encodeThread(incoming)
        let index = try #require(PagedTranscript.validIndex(home.threadURL))
        let offset = Int(index.stamp.size) - old.count
        let prefix = try PagedTranscript.bytes(home.threadURL, offset: max(0, offset - 4_096), count: min(offset, 4_096))
        let commit = PagedTranscript.Commit(offset: offset, inode: index.stamp.inode, prefix: ContentHash.of(prefix), old: old, new: new)
        try PagedTranscript.durable(JSONEncoder().encode(commit), to: PagedTranscript.commitURL(home.threadURL))
        let file = try FileHandle(forWritingTo: home.threadURL)
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: new.prefix(cut))
        try file.close()
        _ = home.loadHistory()
        #expect(home.loadThread() == Array(messages.dropLast(3)) + incoming)
    }

    @Test func aPendingCommitAndExternalAtomicEditPreserveBothHistories() throws {
        let (root, home) = tempHome()
        defer { try? FileManager.default.removeItem(at: root) }
        var messages = HistoryTests.pagedFixture(400)
        try home.saveThread(messages)
        let old = try BotHome.encodeThread([messages.last!])
        var reply = messages.last!
        reply.text = "committed stream"
        let new = try BotHome.encodeThread([reply])
        let index = try #require(PagedTranscript.validIndex(home.threadURL))
        let offset = Int(index.stamp.size) - old.count
        let prefix = try PagedTranscript.bytes(home.threadURL, offset: max(0, offset - 4_096), count: min(offset, 4_096))
        let commit = PagedTranscript.Commit(offset: offset, inode: index.stamp.inode, prefix: ContentHash.of(prefix), old: old, new: new)
        try PagedTranscript.durable(JSONEncoder().encode(commit), to: PagedTranscript.commitURL(home.threadURL))
        messages[0].text = "external old-page edit"
        let external = ChatMessage(role: .note, text: "external append during interruption", date: Date(timeIntervalSince1970: 1_800_000_000))
        try BotHome.writeThread(messages + [external], to: home.threadURL)
        _ = home.loadHistory()
        let recovered = home.loadThread()
        #expect(recovered.count == 401)
        #expect(recovered[0] == messages[0])
        #expect(recovered[399] == reply)
        #expect(recovered.last == external)
        #expect(Set(recovered.map(\.id)).count == recovered.count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.url.path).contains { $0.hasPrefix("thread.conflict-") })
    }
}

extension ConversationStorageTests {
    @Test func aPagedSavePreservesCompletedHistoryAndAcknowledgesOnlyItsTakenMessages() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let messages = HistoryTests.pagedFixture(1_000)
        try fixture.home.saveThread(messages)
        let tail = fixture.home.loadHistory()
        let first = Self.user("taken"), second = Self.user("taken later")
        fixture.queue.enqueue(first)
        fixture.queue.markInFlight(first.id)
        _ = fixture.queue.acknowledge()
        fixture.trace.hold(fixture.files.lane)
        fixture.files.saveTranscript(.init(tail.messages + [first], start: tail.start, base: tail.messages), queue: fixture.access,
                                     failed: { _ in Issue.record("Unexpected save failure") })
        fixture.queue.enqueue(second)
        fixture.queue.markInFlight(second.id)
        _ = fixture.queue.acknowledge()
        fixture.trace.release(fixture.files.lane)
        await fixture.storage.settle()
        #expect(fixture.queue.taken == [second])
        #expect(fixture.home.loadThread().map(\.id) == (messages + [first]).map(\.id))
        let recovery = fixture.home.recover()
        #expect(recovery.queue.taken.isEmpty)
        #expect(fixture.home.loadThread().filter { $0.id == second.id }.count == 1)
    }
}

extension SubagentArchiveTests {
    @Test func aPagedHandoffIsDurableAfterItsCompleteTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-paged-archive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        var run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: Bot(name: "Worker", workspace: "/tmp/worker"),
                              title: "Paged", brief: "Do it", workingDirectory: "/tmp")
        let messages = HistoryTests.pagedFixture(5_000)
        let archive = SubagentArchive()
        try await archive.save(.init(record: run, messages: messages, home: home))
        let tail = try home.loadSubagentHistory(id: run.id)
        let reply = ChatMessage(role: .assistant, text: "Complete handoff", date: Date(timeIntervalSince1970: 1_800_000_000))
        run.phase = .completed
        run.handoffOutput = reply.text
        HistoryCounters.shared.reset(under: root)
        try await archive.save(.init(record: run, messages: tail.messages + [reply], home: home, start: tail.start, base: tail.messages))
        #expect(HistoryCounters.shared.counts(under: root).encoded == 1)
        #expect(home.loadSubagentThread(id: run.id) == messages + [reply])
        #expect(home.loadSubagents().first?.handoffOutput == reply.text)
    }
}
