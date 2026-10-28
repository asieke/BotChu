import Foundation
import Testing
@testable import BotChuCore

@Suite @MainActor struct UsageLedgerTests {
    nonisolated private static func waitForWorker(_ signal: DispatchSemaphore) { signal.wait() }
    private func home() -> BotHome { BotHome(workspace: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path) }
    private func entry(_ kind: UsageLedger.Kind = .home, usage: TurnUsage? = nil) -> UsageLedger.Entry {
        UsageLedger.Entry(at: Date(timeIntervalSince1970: 1_793_145_600), startedAt: Date(timeIntervalSince1970: 1_793_145_500),
                          kind: kind, botID: UUID(), messageID: UUID(), accountID: "claude-work", provider: .claude,
                          model: "requested-model", modelSource: .requested, outcome: .finished, usage: usage)
    }

    @Test func allKindsAndNilVersusZeroRoundTrip() async throws {
        let home = home(), queue = StorageQueue()
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        for kind: UsageLedger.Kind in [.home, .task, .job, .subagent] {
            UsageLedger.append(entry(kind), in: home, queue: queue)
        }
        let zero = TurnUsage(models: [ModelUsage(model: "reported-model", uncachedInput: 0, output: 0)], reportedCostUSD: 0)
        UsageLedger.append(entry(usage: zero), in: home, queue: queue)
        await queue.settle()
        let read = try UsageLedger.read(in: home)
        #expect(read.entries.count == 5)
        #expect(read.entries.prefix(4).allSatisfy { $0.usage == nil && $0.modelSource == .requested })
        #expect(read.entries.last?.usage == zero)
        #expect(read.entries.last?.model == "reported-model" && read.entries.last?.modelSource == .reported)
        let file = try #require(FileManager.default.contentsOfDirectory(at: UsageLedger.directory(in: home), includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"usage\":null"))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func damagedLinesTornTailAndDuplicateEntriesPreserveOtherRecords() async throws {
        let home = home(), queue = StorageQueue(), original = entry()
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        UsageLedger.append(original, in: home, queue: queue)
        await queue.settle()
        let file = try #require(FileManager.default.contentsOfDirectory(at: UsageLedger.directory(in: home), includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("broken\n{\"truncated\":".utf8)); try handle.close()
        UsageLedger.append(original, in: home, queue: queue)
        let next = entry()
        UsageLedger.append(next, in: home, queue: queue)
        await queue.settle()
        let read = try UsageLedger.read(in: home)
        #expect(read.entries.map(\.id) == [original.id, next.id])
        #expect(read.unreadableLines == 2)
    }

    @Test func amendmentsAreIdempotentAcrossRelaunchAndKeepLatestWholeTurnCost() async throws {
        let home = home(), queue = StorageQueue(), original = entry()
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        UsageLedger.append(original, in: home, queue: queue)
        let amend = UsageLedger.Amendment(amends: original.id, actualCostUSD: 0.12)
        UsageLedger.amend(amend, at: original.at, in: home, queue: queue)
        UsageLedger.amend(amend, at: original.at, in: home, queue: queue)
        await queue.settle()
        let nextQueue = StorageQueue()
        UsageLedger.amend(amend, at: original.at, in: home, queue: nextQueue)
        await nextQueue.settle()
        let file = try #require(FileManager.default.contentsOfDirectory(at: UsageLedger.directory(in: home), includingPropertiesForKeys: nil).first)
        #expect(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count == 2)
        UsageLedger.amend(.init(amends: original.id, actualCostUSD: 0), at: original.at, in: home, queue: nextQueue)
        await nextQueue.settle()
        let read = try UsageLedger.read(in: home)
        #expect(read.entries.count == 1 && read.amendments == [.init(amends: original.id, actualCostUSD: 0)])
    }

    @Test func captureKeepsLaunchAccountAndAllLiveResultsExactlyOnce() async throws {
        let home = home(), queue = StorageQueue()
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        var source = entry()
        source.providerID = "anthropic"
        source.remote = true; source.usesLegacyOpenRouterKey = false
        let capture = UsageLedger.Capture(source)
        source.accountID = "switched-account"
        source.remote = false; source.usesLegacyOpenRouterKey = true
        let second = UUID(), third = UUID()
        // Inputs may be taken during tool work, before a result. No FIFO attribution is assumed.
        capture.include(messageID: second); capture.include(messageID: third)
        capture.record(.usage(TurnUsage(models: [ModelUsage(model: "claude", uncachedInput: 10, output: 2)], reportedCostUSD: 0.1)))
        capture.record(.finished)
        capture.record(.usage(TurnUsage(models: [ModelUsage(model: "claude", uncachedInput: 20, output: 3)], reportedCostUSD: 0.2)))
        capture.record(.finished)
        capture.finish(.finished, in: home, queue: queue)
        capture.finish(.stopped, in: home, queue: queue)
        await queue.settle()
        let read = try UsageLedger.read(in: home), saved = try #require(read.entries.first)
        #expect(read.entries.count == 1 && saved.accountID == "claude-work" && saved.providerID == "anthropic")
        #expect(saved.remote && !saved.usesLegacyOpenRouterKey)
        #expect(saved.messageIDs == [source.messageID!, second, third])
        #expect(saved.usage?.models == [ModelUsage(model: "claude", uncachedInput: 30, output: 5)])
        #expect(abs((saved.usage?.reportedCostUSD ?? 0) - 0.3) < 0.00001)
    }

    @Test func cumulativeReportsReplaceWithinInvocationAndPreserveResumeBaseline() async throws {
        let home = home(), queue = StorageQueue(), session = UUID()
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        var original = entry(); original.provider = .codex; original.resumed = true
        let capture = UsageLedger.Capture(original)
        capture.record(.session(session.uuidString))
        capture.record(.usage(TurnUsage(models: [ModelUsage(model: "", uncachedInput: 100)], cumulative: true)))
        capture.record(.usage(TurnUsage(models: [ModelUsage(model: "", uncachedInput: 200)], cumulative: true)))
        capture.finish(.finished, in: home, queue: queue)
        await queue.settle()
        let saved = try #require(UsageLedger.read(in: home).entries.first)
        #expect(saved.sessionID == session.uuidString.lowercased() && saved.resumed)
        #expect(saved.usage?.models.first?.uncachedInput == 200)
    }

    @Test func contentPathsAndSessionSecretsNeverReachDisk() async throws {
        let home = home(), queue = StorageQueue()
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        let planted = "/private/planted-secret/prompt-and-tool-output"
        for outcome: UsageLedger.Outcome in [.failed, .stopped] {
            var original = entry()
            original.model = planted; original.providerID = planted
            let capture = UsageLedger.Capture(original)
            capture.record(.session(planted))
            capture.record(.textDelta(planted))
            capture.record(.text(planted))
            capture.record(.toolStarted(id: planted, name: planted, input: planted, arguments: planted))
            capture.record(.toolFinished(id: planted, name: planted, output: planted, isError: true))
            capture.record(.failed(planted))
            capture.finish(outcome, in: home, queue: queue)
        }
        await queue.settle()
        let read = try UsageLedger.read(in: home)
        #expect(read.entries.count == 2 && read.entries.allSatisfy { $0.sessionID == nil && $0.usage == nil })
        for file in try FileManager.default.contentsOfDirectory(at: UsageLedger.directory(in: home), includingPropertiesForKeys: nil) {
            #expect(try !String(contentsOf: file, encoding: .utf8).contains("planted-secret"))
        }
    }

    @Test func explicitReportedPrimaryModelWinsOverUsageArrayOrder() async throws {
        let home = home(), queue = StorageQueue()
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        let capture = UsageLedger.Capture(entry())
        capture.record(.model("primary-B"))
        let usage = TurnUsage(models: [ModelUsage(model: "secondary-A", output: 2), ModelUsage(model: "primary-B", output: 10)])
        capture.record(.usage(usage))
        capture.finish(.finished, in: home, queue: queue)
        await queue.settle()
        let saved = try #require(UsageLedger.read(in: home).entries.first)
        #expect(saved.model == "primary-B" && saved.modelSource == .reported && saved.usage == usage)
    }

    @MainActor @Test func turnEndOnlySubmitsWorkWhileStorageIsBlocked() async throws {
        let home = home(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        let queue = StorageQueue(before: { work in
            #expect(!Thread.isMainThread)
            if work.label == "hold" { entered.signal(); release.wait() }
        })
        queue.submit(UsageLedger.lane(in: home), label: "hold", work: {})
        await Task.detached { Self.waitForWorker(entered) }.value
        let capture = UsageLedger.Capture(entry())
        capture.finish(.finished, in: home, queue: queue)
        // Completion returned despite a blocked writer, without even creating the directory.
        #expect(!FileManager.default.fileExists(atPath: UsageLedger.directory(in: home).path))
        release.signal()
        await queue.settle()
        #expect(try UsageLedger.read(in: home).entries.count == 1)
        #expect(queue.stats.runs == 2)
    }

    /// Opt-in timing for #295. The same handoff is measured with empty and large existing history;
    /// writes are held on their worker so elapsed time measures only MainActor turn-end work.
    @MainActor @Test func usageLedgerEnqueueBenchmark() async throws {
        guard let output = ProcessInfo.processInfo.environment["BOTCHU_LEDGER_BENCHMARK"] else { return }
        var rows = ["existing lines,turn ends,main actor total ms,main actor us per end"]
        for count in [0, 100_000] {
            let home = home(), value = entry()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let queue = StorageQueue(before: { work in
                if work.label == "hold" { entered.signal(); release.wait() }
            })
            if count > 0 {
                let folder = UsageLedger.directory(in: home)
                try await Task.detached {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data(String(repeating: "{}\n", count: count).utf8).write(to: folder.appendingPathComponent("2020-01.jsonl"))
                }.value
            }
            queue.submit(UsageLedger.lane(in: home), label: "hold", work: {})
            await Task.detached { Self.waitForWorker(entered) }.value
            let turns = 500, began = ProcessInfo.processInfo.systemUptime
            for _ in 0..<turns {
                let capture = UsageLedger.Capture(value)
                capture.finish(.finished, in: home, queue: queue)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            rows.append("\(count),\(turns),\(elapsed * 1000),\(elapsed * 1_000_000 / Double(turns))")
            release.signal()
            await queue.settle()
            try FileManager.default.removeItem(at: home.url.deletingLastPathComponent())
        }
        try rows.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
