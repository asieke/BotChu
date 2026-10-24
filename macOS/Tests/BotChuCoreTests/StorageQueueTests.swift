import Foundation
import Testing
@testable import BotChuCore

/// #107: BotChu's file work runs off the main thread, each target's in order, targets side by side.
/// These tests block only their own threads, never the main one, which other suites time.
@Suite struct StorageQueueTests {
    /// What ran, where and in which order, with a gate that holds a chosen lane's work.
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(lane: String, label: String, main: Bool, start: TimeInterval, end: TimeInterval)] = []
        private var held: Set<String> = []
        private var delay: TimeInterval = 0

        func record(_ work: StorageQueue.Work) {
            let start = ProcessInfo.processInfo.systemUptime
            lock.lock()
            entries.append((work.lane, work.label, Thread.isMainThread, start, .infinity))
            let index = entries.count - 1, pause = delay
            lock.unlock()
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            while isHeld(work.lane) { Thread.sleep(forTimeInterval: 0.002) }
            lock.withLock { entries[index].end = ProcessInfo.processInfo.systemUptime }
        }

        /// When the first piece of work labelled `label` started and ended its hook.
        func span(_ label: String) -> (start: TimeInterval, end: TimeInterval)? {
            lock.withLock { entries.first { $0.label == label }.map { ($0.start, $0.end) } }
        }

        func hold(_ lane: String) { lock.withLock { _ = held.insert(lane) } }
        func release(_ lane: String) { lock.withLock { _ = held.remove(lane) } }
        func slow(_ seconds: TimeInterval) { lock.withLock { delay = seconds } }
        private func isHeld(_ lane: String) -> Bool { lock.withLock { held.contains(lane) } }

        var labels: [String] { lock.withLock { entries.map(\.label) } }
        func labels(_ lane: String) -> [String] { lock.withLock { entries.filter { $0.lane == lane }.map(\.label) } }
        var ranOnMain: Bool { lock.withLock { entries.contains { $0.main } } }
        var count: Int { lock.withLock { entries.count } }
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Value] = []
        func append(_ value: Value) { lock.withLock { stored.append(value) } }
        var all: [Value] { lock.withLock { stored } }
    }

    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor @Test func workRunsOffTheMainThreadInOrderPerLaneAndSideBySideAcrossLanes() async throws {
        let trace = Trace()
        trace.slow(0.25)
        let storage = StorageQueue(before: trace.record)
        let started = Date()
        for lane in ["a", "b", "c", "d"] { storage.submit(lane, label: "\(lane)1", work: { () }) }
        for n in 2...3 { storage.submit("a", label: "a\(n)", work: { () }) }
        // Asking, here on the main actor, returns at once, however slow the writes are.
        #expect(Date().timeIntervalSince(started) < 0.2)
        await storage.settle()
        #expect(!trace.ranOnMain)
        #expect(trace.labels("a") == ["a1", "a2", "a3"])
        // A lane's work runs one after another; different lanes' side by side.
        let a1 = try #require(trace.span("a1")), a2 = try #require(trace.span("a2"))
        #expect(a2.start >= a1.end)
        for other in ["b1", "c1", "d1"] {
            let span = try #require(trace.span(other))
            #expect(span.start < a1.end && a1.start < span.end, "\(other) ran while a1 did")
        }
        #expect(storage.stats.runs == 6)
    }

    @Test func aNewerStateTakesThePlaceOfOneNotWrittenYetAndNeverComesAfterLaterWork() async throws {
        let storage = StorageQueue()
        let written = Box<Int>()
        let heard = Box<Int>()
        let writing = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        func save(_ value: Int) {
            storage.replace("lane", slot: "file", value: value, write: { value in
                if value == 1 {
                    writing.signal()
                    proceed.wait()
                }
                written.append(value)
                return 8
            }) { result in
                if case .success(let value) = result { heard.append(value) }
            }
        }
        save(1)
        writing.wait()
        // 1 is being written; 2 waits, then 3 and 4 take its place.
        save(2)
        storage.submit("lane", label: "later", work: { written.append(100) })
        save(3)
        save(4)
        proceed.signal()
        await storage.settle()
        #expect(written.all == [1, 4, 100], "4 is written where 2 waited, before the work asked for after 2")
        #expect(heard.all.sorted() == [1, 4, 4, 4], "Whoever gave 2 or 3 hears how 4 went")
        #expect(storage.stats.coalesced == 2)
        #expect(storage.stats.peakRetained == 1 || storage.stats.peakRetained == 2)
        #expect(storage.stats.bytesWritten == 16)
    }

    @Test func aStateWrittenAlreadyIsNotWrittenAgain() async throws {
        let storage = StorageQueue()
        let written = Box<String>()
        for version in ["v1", "v1", "v2", "v2"] {
            storage.replace("lane", slot: "file", value: version, version: version, write: { written.append($0); return 0 })
            await storage.settle()
        }
        #expect(written.all == ["v1", "v2"])
        #expect(storage.stats.unchanged == 2)
    }

    @Test func aFailedWriteIsWrittenAgainNextTime() async throws {
        let storage = StorageQueue()
        let failing = Box<Bool>()
        failing.append(true)
        let errors = Box<Bool>()
        for _ in 0..<2 {
            storage.replace("lane", slot: "file", value: "same", version: "same", write: { _ in
                if failing.all.count == 1 { failing.append(false); throw CocoaError(.fileWriteOutOfSpace) }
                return 0
            }) { result in errors.append((try? result.get()) == nil) }
            await storage.settle()
        }
        #expect(errors.all == [true, false])
        #expect(storage.stats.unchanged == 0)
    }

    @Test func waitBlocksUntilTheWorkIsDoneAndListsWhatIsNot() throws {
        let trace = Trace()
        let storage = StorageQueue(before: trace.record)
        trace.slow(0.2)
        storage.submit("/bots/a/.botchu/thread.jsonl", work: { () })
        #expect(storage.wait(timeout: 2).isEmpty)
        trace.slow(0.6)
        storage.submit("/bots/a/.botchu/thread.jsonl", work: { () })
        storage.submit("/bots/b/.botchu/thread.jsonl", work: { () })
        let started = Date()
        #expect(storage.wait(under: "/bots/a/.botchu", timeout: 0.1) == ["/bots/a/.botchu/thread.jsonl"])
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(storage.wait(timeout: 3).isEmpty)
    }

    @Test func aStateWaitingForItsDelayIsWrittenWhenQuittingOrBySaveThatCantWait() async throws {
        let storage = StorageQueue()
        let written = Box<String>()
        storage.replace("a", slot: "file", value: "checkpoint", delay: 60, write: { written.append($0); return 0 })
        #expect(written.all.isEmpty)
        #expect(storage.wait(timeout: 2).isEmpty)
        #expect(written.all == ["checkpoint"])
        storage.replace("b", slot: "file", value: "checkpoint", delay: 60, write: { written.append($0); return 0 })
        storage.replace("b", slot: "file", value: "final", write: { written.append($0); return 0 })
        await storage.settle()
        #expect(written.all == ["checkpoint", "final"])
    }

    @Test func cancelDropsAStateNotWrittenYet() async throws {
        let storage = StorageQueue()
        let written = Box<String>()
        let failures = Box<StorageQueue.Failure>()
        storage.replace("a", slot: "file", value: "checkpoint", delay: 60, write: { written.append($0); return 0 }) { result in
            if case .failure(let error as StorageQueue.Failure) = result { failures.append(error) }
        }
        storage.cancel("a", slot: "file")
        storage.submit("a", work: { written.append("final") })
        await storage.settle()
        #expect(written.all == ["final"])
        #expect(failures.all == [.superseded])
    }

    @Test func aRetiredFolderDropsWhatWaitsAndRefusesMoreUntilReopened() async throws {
        let trace = Trace()
        let storage = StorageQueue(before: trace.record)
        let folder = "/bots/gone/.botchu"
        let written = Box<String>()
        let failures = Box<String>()
        trace.hold("\(folder)/thread.jsonl")
        storage.submit("\(folder)/thread.jsonl", label: "running", work: { written.append("running") })
        await waitFor { trace.count == 1 }
        storage.submit("\(folder)/thread.jsonl", label: "waiting", work: { written.append("waiting") }) { result in
            if case .failure = result { failures.append("waiting") }
        }
        storage.replace("\(folder)/tasks/t/task.json", slot: "task", value: "state", delay: 60, write: { written.append($0); return 0 }) { result in
            if case .failure = result { failures.append("state") }
        }
        storage.submit("/bots/kept/.botchu/thread.jsonl", work: { written.append("kept") })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { trace.release("\(folder)/thread.jsonl") }
        // Waits for the write under way, drops what waits.
        #expect(storage.retire(folder, timeout: 2).isEmpty)
        #expect(Set(written.all) == ["running", "kept"])
        storage.submit("\(folder)/bot.json", work: { written.append("refused") }) { result in
            if case .failure(let error as StorageQueue.Failure) = result, error == .retired { failures.append("refused") }
        }
        await storage.settle()
        #expect(Set(failures.all) == ["waiting", "state", "refused"])
        #expect(!written.all.contains("refused"))
        storage.reopen(folder)
        storage.submit("\(folder)/bot.json", work: { written.append("again") })
        await storage.settle()
        #expect(written.all.last == "again")
        #expect(storage.isIdle())
    }

    @Test func aReadOnTheLaneWaitsForTheWritesAskedForBefore() async throws {
        let trace = Trace()
        trace.slow(0.1)
        let storage = StorageQueue(before: trace.record)
        let written = Box<String>()
        storage.submit("lane", label: "write", work: { written.append("written") })
        let read = storage.sync("lane", label: "read") { written.all }
        #expect(read == ["written"])
    }
}
