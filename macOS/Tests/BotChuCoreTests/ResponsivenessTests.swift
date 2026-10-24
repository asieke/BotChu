import Foundation
import Testing
@testable import BotChuCore

/// #46: a CLI's output is parsed off the main thread and reaches it in batches; statuses don't
/// scan threads; replies are parsed once; sub-agent transcripts are checkpointed, not rewritten
/// for every batch. No assertion here depends on how fast the machine is.
@Suite struct StreamDeliveryTests {
    /// Parses as Codex does, and notes the threads it ran on.
    final class RecordingParser: StreamParser, @unchecked Sendable {
        private var codex = CodexParser()
        private let lock = NSLock()
        private(set) var onMain = 0
        private(set) var calls = 0

        func parse(line: String) -> [AgentEvent] {
            lock.lock()
            calls += 1
            if Thread.isMainThread { onMain += 1 }
            lock.unlock()
            return codex.parse(line: line)
        }
    }

    private static let burst = #"""
    import json, sys, time
    for i in range(600):
        print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"reply %d" % i}}), flush=True)
        if i % 20 == 19:
            time.sleep(0.003)
    print(json.dumps({"type":"turn.completed"}), flush=True)
    """#

    @Test func linesAreParsedOffTheMainThreadAndDeliveredInFewBatchesBeforeTheExit() async throws {
        let parser = RecordingParser()
        let start = Date()
        let (batches, events, exitedAfterAll) = await withCheckedContinuation { (done: CheckedContinuation<(Int, [AgentEvent], Bool), Never>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "/usr/bin/python3", invocation: Invocation(arguments: ["-c", Self.burst]),
                                   directory: FileManager.default.temporaryDirectory)
                var batches = 0
                var events: [AgentEvent] = []
                var mainThreadDeliveries = true
                run.deliverEvents(parsedBy: parser) { batch in
                    mainThreadDeliveries = mainThreadDeliveries && Thread.isMainThread
                    batches += 1
                    events += batch
                }
                run.onLines = { _ in Issue.record("Lines go to onLines only without a parser") }
                run.onExit = { _, _ in done.resume(returning: (batches, events, mainThreadDeliveries && events.last == .finished)) }
                try? run.start()
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(events.count == 601)
        #expect(events.first == .text("reply 0"))
        #expect(events.dropLast().last == .text("reply 599"))
        #expect(exitedAfterAll)
        #expect(parser.calls == 601)
        #expect(parser.onMain == 0)
        // At most one delivery per interval (after the first), however the reads fell.
        #expect(batches <= Int(elapsed / 0.04) + 2)
        #expect(batches < 601)
    }

    @Test func flushingDeliversWhatIsWaitingAtOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = #"""
        import json, time
        from pathlib import Path
        print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"first"}}), flush=True)
        time.sleep(0.3)
        print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"second"}}), flush=True)
        Path("printed").touch()
        time.sleep(3)
        """#
        let result = await withCheckedContinuation { (done: CheckedContinuation<(beforeExit: [AgentEvent], all: [AgentEvent]), Never>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "/usr/bin/python3", invocation: Invocation(arguments: ["-c", script]), directory: folder)
                // Long enough that only a flush delivers the second reply before the exit.
                run.deliveryInterval = 60
                var events: [AgentEvent] = []
                var flushedBeforeExit: [AgentEvent] = []
                run.deliverEvents(parsedBy: CodexParser()) { events += $0 }
                run.onExit = { _, _ in done.resume(returning: (flushedBeforeExit, events)) }
                try? run.start()
                func flushWhenPrinted() {
                    guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("printed").path) else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { flushWhenPrinted() }
                        return
                    }
                    run.flushOutput()
                    if events.count < 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { flushWhenPrinted() }
                    } else {
                        flushedBeforeExit = events
                    }
                }
                flushWhenPrinted()
            }
        }
        #expect(result.beforeExit == [.text("first"), .text("second")])
        #expect(result.all == [.text("first"), .text("second")])
    }

    /// A CLI whose first lines aren't events (a login shell's greeting) has still started.
    @Test func theFirstOutputIsDeliveredEvenWithoutEvents() async throws {
        let script = #"""
        import json, time
        print("Welcome to the login shell", flush=True)
        time.sleep(0.3)
        print("not json either", flush=True)
        print(json.dumps({"type":"turn.completed"}), flush=True)
        """#
        let batches = await withCheckedContinuation { (done: CheckedContinuation<[[AgentEvent]], Never>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "/usr/bin/python3", invocation: Invocation(arguments: ["-c", script]),
                                   directory: FileManager.default.temporaryDirectory)
                var batches: [[AgentEvent]] = []
                run.deliverEvents(parsedBy: CodexParser()) { batches.append($0) }
                run.onExit = { _, _ in done.resume(returning: batches) }
                try? run.start()
            }
        }
        #expect(batches == [[], [.finished]])
    }

    @Test func linesStillReachOnLinesWithoutAParser() async throws {
        let lines = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            DispatchQueue.main.async {
                let run = AgentRun(command: "printf", invocation: Invocation(arguments: [#"%s\n%s\nlast"#, "one", "two"]),
                                   directory: FileManager.default.temporaryDirectory)
                var seen: [String] = []
                run.onLines = { seen += $0 }
                run.onExit = { _, _ in done.resume(returning: seen) }
                try? run.start()
            }
        }
        // The last line has no newline; it still comes, before the exit.
        #expect(lines == ["one", "two", "last"])
    }
}

@Suite struct ThreadAssemblyTests {
    @Test func deltasFindTheOpenReplyFromTheEndOfALongThread() {
        var messages = (0..<5_000).map { ChatMessage(role: .tool, toolID: "\($0)", toolName: "Shell", toolState: .done) }
        var assembler = ThreadAssembler()
        assembler.apply(.textDelta("Hello"), to: &messages)
        // A note can follow the reply being written (a task's receipt in Home).
        messages.append(ChatMessage(role: .receipt, text: "Task finished"))
        assembler.apply(.textDelta(", world"), to: &messages)
        assembler.apply(.textEnd, to: &messages)
        #expect(messages.count == 5_002)
        #expect(messages[5_000].text == "Hello, world")
        #expect(messages.last?.role == .receipt)
    }
}

@Suite struct ThreadSummaryTests {
    private func message(_ role: ChatMessage.Role, _ text: String = "", at offset: TimeInterval) -> ChatMessage {
        ChatMessage(role: role, text: text, date: Date(timeIntervalSince1970: 1_000 + offset))
    }

    @Test func countsMessagesAndToolCallsAndTheLastWordButNotNotes() {
        let messages = [message(.user, at: 0), message(.assistant, at: 1), message(.tool, at: 2), message(.error, "usage limit", at: 3),
                        message(.note, "Stopped", at: 4), message(.receipt, "Task finished", at: 5)]
        let summary = ThreadSummary(messages)
        #expect(summary.messageCount == 2)
        #expect(summary.toolCallCount == 1)
        #expect(summary.lastActivity == Date(timeIntervalSince1970: 1_003))
        #expect(summary.lastError == "usage limit")
        #expect(ThreadSummary([]) == ThreadSummary())
    }

    @Test func extendingAsAThreadGrowsMatchesSummarizingItAgain() {
        var generator = SystemRandomNumberGenerator()
        let roles: [ChatMessage.Role] = [.user, .assistant, .tool, .error, .note, .receipt]
        for _ in 0..<50 {
            var messages: [ChatMessage] = []
            var summary = ThreadSummary()
            for step in 0..<40 {
                let start = messages.count
                for _ in 0..<Int.random(in: 0...3, using: &generator) {
                    messages.append(message(roles.randomElement(using: &generator)!, "m\(step)", at: Double(messages.count)))
                }
                // A reply or a tool call already there is written further; its role stays.
                if let last = messages.indices.last, [.assistant, .tool].contains(messages[last].role) { messages[last].text += " more" }
                summary.extend(with: messages, from: start)
                #expect(summary == ThreadSummary(messages))
            }
        }
    }

    @Test func statusesFromASummaryMatchStatusesFromTheirThread() {
        let bot = Bot(name: "Ada", workspace: "/tmp/ada")
        let messages = [message(.user, at: 0), message(.assistant, at: 1), message(.error, "boom", at: 2), message(.note, at: 3)]
        let run = RunState(hasOutput: true, activity: .coding)
        for state in [nil, run] {
            #expect(BotStatus.make(settings: bot, summary: ThreadSummary(messages), run: state, reaction: .done)
                        == BotStatus.make(bot: bot, messages: messages, run: state, reaction: .done))
        }
    }
}

@Suite struct MarkdownCacheTests {
    @Test func aReplyIsParsedOnceAndKeepsItsKind() {
        let cache = MarkdownCache(capacity: 16)
        guard case .blocks(let blocks) = cache.rendering(for: "## Title\n\nSome **bold** text.") else {
            Issue.record("A plain reply is drawn natively")
            return
        }
        #expect(blocks.count == 2)
        #expect(cache.cached("## Title\n\nSome **bold** text.") != nil)
        guard case .rich(let html) = cache.rendering(for: "Euler: $e^{i\\pi} + 1 = 0$") else {
            Issue.record("A reply with math is drawn in WebKit")
            return
        }
        #expect(html.contains("class=\"tex\""))
        #expect(cache.count == 2)
    }

    @Test func aStreamingReplyReplacesItsShorterVersions() {
        let cache = MarkdownCache(capacity: 16)
        _ = cache.rendering(for: "Done.")
        var text = ""
        for word in ["Hello", " there,", " how", " are", " you?"] {
            text += word
            _ = cache.rendering(for: text)
        }
        #expect(cache.count == 2)
        #expect(cache.cached("Hello there, how are you?") != nil)
        #expect(cache.cached("Hello there,") == nil)
        #expect(cache.cached("Done.") != nil)
    }

    @Test func keepsTheRepliesUsedMostRecently() {
        let cache = MarkdownCache(capacity: 8)
        for i in 0..<8 { _ = cache.rendering(for: "Reply number \(i) of eight") }
        _ = cache.rendering(for: "Reply number 0 of eight")
        for i in 8..<12 { _ = cache.rendering(for: "Reply number \(i) of eight") }
        #expect(cache.count <= 8)
        #expect(cache.cached("Reply number 0 of eight") != nil)
        #expect(cache.cached("Reply number 11 of eight") != nil)
        #expect(cache.cached("Reply number 1 of eight") == nil)
    }

    @Test func warmingParsesAheadWithoutDroppingReplies() async {
        let cache = MarkdownCache(capacity: 64)
        let replies = (0..<20).map { "Reply \($0): see `code` and a [link](https://example.test/\($0))." } + ["Reply 1", "Reply 12"]
        await Task.detached { cache.warm(replies) }.value
        #expect(cache.count == replies.count)
        #expect(replies.allSatisfy { cache.cached($0) != nil })
    }
}

@Suite struct SubagentArchiveTests {
    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var saved: [[String]] = []
        var fail = false
        func record(_ snapshot: SubagentArchive.Snapshot) throws {
            lock.lock()
            defer { lock.unlock() }
            if fail { throw CocoaError(.fileWriteNoPermission) }
            saved.append(snapshot.messages.map(\.text))
        }
        var all: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return saved
        }
    }

    private func snapshot(_ record: SubagentRun, _ texts: [String]) -> SubagentArchive.Snapshot {
        SubagentArchive.Snapshot(record: record, messages: texts.map { ChatMessage(role: .assistant, text: $0) },
                                 home: BotHome(workspace: "/tmp/unused"))
    }

    private var record: SubagentRun {
        SubagentRun(rootBotID: UUID(), depth: 1, targetBot: Bot(name: "Worker", workspace: "/tmp/worker"),
                    title: "Work", brief: "Do it", workingDirectory: "/tmp")
    }

    @MainActor @Test func checkpointsWhileStreamingAreWrittenTogether() async throws {
        let writes = Writes()
        let archive = SubagentArchive(interval: 0.2) { try writes.record($0) }
        let run = record
        var texts: [String] = []
        for i in 0..<100 {
            texts.append("chunk \(i)")
            archive.checkpoint(snapshot(run, texts)) { _ in Issue.record("No write fails here") }
        }
        try await Task.sleep(for: .milliseconds(600))
        // One write, or two should the machine pause this loop for longer than the interval.
        #expect((1...2).contains(writes.all.count))
        #expect(writes.all.last == texts)
    }

    @MainActor @Test func aSaveIsWrittenAtOnceAndNoOlderCheckpointReplacesIt() async throws {
        let writes = Writes()
        let archive = SubagentArchive(interval: 0.2) { try writes.record($0) }
        let run = record
        archive.checkpoint(snapshot(run, ["streaming"])) { _ in }
        try await archive.save(snapshot(run, ["streaming", "handoff"]))
        #expect(writes.all == [["streaming", "handoff"]])
        try await Task.sleep(for: .milliseconds(400))
        #expect(writes.all == [["streaming", "handoff"]])
    }

    @MainActor @Test func flushWritesWhatIsWaitingBeforeQuitting() {
        let writes = Writes()
        let archive = SubagentArchive(interval: 60) { try writes.record($0) }
        archive.checkpoint(snapshot(record, ["one"])) { _ in }
        archive.checkpoint(snapshot(record, ["two"])) { _ in }
        let run = record
        archive.checkpoint(snapshot(run, ["three"])) { _ in }
        archive.checkpoint(snapshot(run, ["three", "four"])) { _ in }
        #expect(writes.all.isEmpty)
        archive.flush()
        #expect(Set(writes.all) == [["one"], ["two"], ["three", "four"]])
    }

    @MainActor @Test func aFailedCheckpointIsReportedOnTheMainQueue() async throws {
        let writes = Writes()
        writes.fail = true
        let archive = SubagentArchive(interval: 0.05) { try writes.record($0) }
        let reported = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            archive.checkpoint(snapshot(record, ["lost"])) { _ in done.resume(returning: Thread.isMainThread) }
        }
        #expect(reported)
        await #expect(throws: (any Error).self) { try await archive.save(snapshot(record, ["final"])) }
    }

    /// #107: each run has its own lane, so a run's end is never written behind another run's slow
    /// checkpoint, and waiting for it never blocks the caller.
    @Test func aRunsSaveNeverWaitsBehindAnotherRunsWrite() async throws {
        let slow = DispatchSemaphore(value: 0), writing = DispatchSemaphore(value: 0)
        let writes = Writes()
        let blocked = record
        let archive = SubagentArchive(interval: 0) { snapshot in
            if snapshot.record.id == blocked.id {
                writing.signal()
                slow.wait()
            }
            try writes.record(snapshot)
        }
        archive.checkpoint(snapshot(blocked, ["slow"])) { _ in }
        writing.wait()
        // The other run's write is held until after this save: were they in one lane, this would never return.
        try await archive.save(snapshot(record, ["handoff"]))
        #expect(writes.all == [["handoff"]])
        slow.signal()
        await archive.storage.settle()
        #expect(writes.all == [["handoff"], ["slow"]])
    }

    /// #107: clearing a finished run drops its checkpoint still waiting and removes its folder after
    /// any write of it, so nothing makes the folder again.
    @MainActor @Test func clearingARunNeverLeavesItsFolderBehind() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = BotHome(workspace: folder.path)
        let run = record
        let archive = SubagentArchive(interval: 60)
        try await archive.save(SubagentArchive.Snapshot(record: run, messages: [ChatMessage(role: .user, text: "Do it")], home: home))
        archive.checkpoint(SubagentArchive.Snapshot(record: run, messages: [ChatMessage(role: .assistant, text: "late")], home: home)) { _ in }
        let removed: Error?? = await withCheckedContinuation { done in
            archive.remove(run.id, taskID: nil, home: home) { done.resume(returning: $0) }
        }
        #expect(removed.flatMap { $0 } == nil)
        #expect(archive.flush(timeout: 2).isEmpty)
        await archive.storage.settle()
        #expect(!FileManager.default.fileExists(atPath: home.subagentURL(id: run.id).path))
        #expect(home.loadSubagents().isEmpty)
    }

    @Test func snapshotsAreWrittenToTheOwningBotsFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = BotHome(workspace: folder.path)
        var run = record
        run.rootTaskID = UUID()
        try await SubagentArchive().save(SubagentArchive.Snapshot(record: run, messages: [ChatMessage(role: .user, text: "Do it")], home: home))
        #expect(home.loadSubagents(taskID: run.rootTaskID).map(\.id) == [run.id])
        #expect(home.loadSubagentThread(id: run.id, taskID: run.rootTaskID).map(\.text) == ["Do it"])
    }
}

@Suite struct MailboxPollTests {
    @Test func aPollCanRefreshTheHeartbeat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-poll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SubagentTransport(namespace: UUID(), invocationID: UUID(), localRoot: root)
        let endpoint = try await transport.prepare(script: "#!/bin/sh\n", roster: Data("[]".utf8))
        let heartbeat = URL(fileURLWithPath: endpoint.ipcDirectory).appendingPathComponent("heartbeat.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: heartbeat.path)
        _ = try await transport.poll()
        let untouched = try FileManager.default.attributesOfItem(atPath: heartbeat.path)[.modificationDate] as? Date
        #expect(untouched == Date(timeIntervalSince1970: 0))
        _ = try await transport.poll(heartbeat: true)
        let touched = try FileManager.default.attributesOfItem(atPath: heartbeat.path)[.modificationDate] as? Date
        #expect((touched ?? .distantPast) > Date(timeIntervalSinceNow: -60))
    }
}
