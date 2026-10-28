import Foundation
import Testing
@testable import BotChuCore

extension MailboxPollTests {
    @Test func watchingBeforeTheInitialScanKeepsPublishesDuringTheDrain() async throws {
        let mailbox = try await WatchedMailbox()
        defer { mailbox.cleanUp() }
        try mailbox.publish("before.json")
        let watcher = LocalMailboxWatcher(directory: mailbox.requests, recoveryInterval: nil)
        defer { watcher.cancel() }
        #expect(watcher.watchedDirectoryCount == 2)
        var hints = watcher.changes.makeAsyncIterator()
        _ = await hints.next()
        #expect(try await mailbox.transport.poll().map(\.filename) == ["before.json"])
        // No consumer is waiting. An atomic rename after the scan must leave a buffered hint.
        try mailbox.publish("during.json")
        try await waitForMailbox { watcher.notificationCount > 0 }
        _ = await hints.next()
        #expect(try await mailbox.transport.poll().map(\.filename) == ["before.json", "during.json"])
    }

    @Test func replacementDeletionAndRecreationRearmTheWatchAndRestartFindsPendingWork() async throws {
        let mailbox = try await WatchedMailbox()
        defer { mailbox.cleanUp() }
        let watcher = LocalMailboxWatcher(directory: mailbox.requests, recoveryInterval: nil)
        let probe = MailboxProbe()
        let consumer = mailbox.consume(watcher, probe: probe)
        defer { consumer.cancel(); watcher.cancel() }
        try await waitForMailbox { await probe.scans == 1 }
        let old = mailbox.root.appendingPathComponent("old-requests")
        try FileManager.default.moveItem(at: mailbox.requests, to: old)
        try FileManager.default.createDirectory(at: mailbox.requests, withIntermediateDirectories: false)
        try mailbox.publish("replacement.json")
        try await waitForMailbox { await probe.names.contains("replacement.json") }
        try FileManager.default.removeItem(at: mailbox.requests)
        try await waitForMailbox { watcher.watchedDirectoryCount == 1 }
        try FileManager.default.createDirectory(at: mailbox.requests, withIntermediateDirectories: false)
        try mailbox.publish("recreated.json")
        try await waitForMailbox { await probe.names.contains("recreated.json") }
        consumer.cancel()
        await consumer.value
        #expect(watcher.watchedDirectoryCount == 0)
        try mailbox.publish("after-cancel.json")
        let restarted = LocalMailboxWatcher(directory: mailbox.requests, recoveryInterval: nil)
        let resumed = mailbox.consume(restarted, probe: probe)
        defer { resumed.cancel(); restarted.cancel() }
        try await waitForMailbox { await probe.names.contains("after-cancel.json") }
        #expect(await probe.names == ["replacement.json", "recreated.json", "after-cancel.json"])
    }

    @Test func aMissedEventIsRecoveredAndCancellationEndsTheStream() async throws {
        let mailbox = try await WatchedMailbox()
        defer { mailbox.cleanUp() }
        // Deliberately drop all native events, retaining the production recovery path.
        let watcher = LocalMailboxWatcher(directory: mailbox.requests, recoveryInterval: 0.05, observeChanges: false)
        let probe = MailboxProbe()
        let consumer = mailbox.consume(watcher, probe: probe)
        defer { consumer.cancel(); watcher.cancel() }
        try await waitForMailbox { await probe.scans == 1 }
        try mailbox.publish("missed.json")
        try await waitForMailbox { await probe.names == ["missed.json"] }
        #expect(LocalMailboxWatcher.recoveryInterval < 5)
        #expect(watcher.notificationCount == 0)
        consumer.cancel()
        await consumer.value
        #expect(watcher.watchedDirectoryCount == 0)
        var hints = watcher.changes.makeAsyncIterator()
        #expect(await hints.next() == nil)
    }

    @Test func replacingTheMailboxParentRecoversBothDirectoryRegistrations() async throws {
        let mailbox = try await WatchedMailbox()
        defer { mailbox.cleanUp() }
        let watcher = LocalMailboxWatcher(directory: mailbox.requests, recoveryInterval: 0.05)
        let probe = MailboxProbe()
        let consumer = mailbox.consume(watcher, probe: probe)
        defer { consumer.cancel(); watcher.cancel() }
        try await waitForMailbox { await probe.scans >= 1 }
        try FileManager.default.moveItem(at: mailbox.directory, to: mailbox.root.appendingPathComponent("old-mailbox"))
        try await waitForMailbox { watcher.watchedDirectoryCount == 0 }
        try FileManager.default.createDirectory(at: mailbox.requests, withIntermediateDirectories: true)
        try mailbox.publish("new-parent.json")
        try await waitForMailbox { await probe.names == ["new-parent.json"] }
        // A recovery can overlap creating the two directories: the request scan may succeed
        // before the following recovery has registered the parent as well.
        try await waitForMailbox { watcher.watchedDirectoryCount == 2 }
        #expect(watcher.watchedDirectoryCount == 2)
    }

    @Test func twelveIdleCallersScanAtMostFifteenTimesPerSimulatedMinute() async throws {
        var mailboxes: [WatchedMailbox] = []
        var watchers: [LocalMailboxWatcher] = []
        var probes: [MailboxProbe] = []
        var consumers: [Task<Void, Never>] = []
        defer {
            consumers.forEach { $0.cancel() }
            watchers.forEach { $0.cancel() }
            mailboxes.forEach { $0.cleanUp() }
        }
        for _ in 0..<12 {
            let mailbox = try await WatchedMailbox()
            mailboxes.append(mailbox)
        }
        // Replay a minute of the previous 250 ms polling schedule against the same directories.
        var before = Array(repeating: 0, count: 12)
        for tick in 0..<240 {
            for (index, mailbox) in mailboxes.enumerated() {
                _ = try await mailbox.transport.poll(heartbeat: tick.isMultiple(of: 8))
                before[index] += 1
            }
        }
        for mailbox in mailboxes {
            let watcher = LocalMailboxWatcher(directory: mailbox.requests, recoveryInterval: nil)
            let probe = MailboxProbe()
            watchers.append(watcher); probes.append(probe)
            consumers.append(mailbox.consume(watcher, probe: probe))
        }
        for probe in probes { try await waitForMailbox { await probe.scans == 1 } }
        var recoveries = 0, heartbeats = 0
        let interval = Int(LocalMailboxWatcher.recoveryInterval * 1_000)
        for millisecond in stride(from: 500, through: 60_000, by: 500) {
            if millisecond.isMultiple(of: 2_000) {
                for mailbox in mailboxes { try await mailbox.transport.heartbeat() }
                heartbeats += 1
            }
            if millisecond.isMultiple(of: interval) {
                recoveries += 1
                for watcher in watchers { watcher.recover() }
                let expected = recoveries + 1
                for probe in probes { try await waitForMailbox { await probe.scans >= expected } }
            }
        }
        // Allow queued parent notifications from atomic heartbeat writes to arrive too.
        try await Task.sleep(for: .milliseconds(100))
        var scans: [Int] = []
        for probe in probes { scans.append(await probe.scans) }
        #expect(scans == Array(repeating: recoveries + 1, count: 12))
        #expect(scans.allSatisfy { $0 <= 15 })
        #expect(heartbeats == 30)
        print("mailbox idle/minute: before=\(before); after=\(scans); heartbeats/caller=\(heartbeats); native callbacks total=\(watchers.reduce(0) { $0 + $1.notificationCount })")
    }

    /// Opt in to the controlled latency comparison; correctness tests do not assert host timing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_MAILBOX_BENCHMARK"] != nil))
    func mailboxPickupBenchmark() async throws {
        let before = try await pickupBenchmark(watching: false)
        let after = try await pickupBenchmark(watching: true)
        let mailbox = try await WatchedMailbox()
        defer { mailbox.cleanUp() }
        let watcher = LocalMailboxWatcher(directory: mailbox.requests,
            recoveryInterval: LocalMailboxWatcher.recoveryInterval, observeChanges: false)
        let probe = MailboxProbe()
        let consumer = mailbox.consume(watcher, probe: probe)
        defer { consumer.cancel(); watcher.cancel() }
        try await waitForMailbox { await probe.scans == 1 }
        let start = Date()
        try mailbox.publish("missed.json", data: Data(String(start.timeIntervalSince1970).utf8))
        try await waitForMailbox(seconds: 6) { await probe.names.count == 1 }
        let recovery = await probe.latencies.first ?? -1
        let report = """
        64 atomic requests, identical deterministic arrival spacing, 250 ms polling vs directory hints.
        before: scans=\(before.scans), request wakeups=\(before.wakeups), p50_ms=\(before.p50), p95_ms=\(before.p95)
        after: scans=\(after.scans), request wakeups=\(after.wakeups), native callbacks=\(after.notifications), p50_ms=\(after.p50), p95_ms=\(after.p95)
        deliberately missed event: recovery_ms=\(recovery * 1_000)
        """
        print(report)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_MAILBOX_BENCHMARK"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

extension SubagentTransportTests {
    @Test func aCoalescedHintDrainsEveryBoundedBatchWithoutSpinningOnUnacknowledgedFiles() async throws {
        let mailbox = try await WatchedMailbox()
        defer { mailbox.cleanUp() }
        let probe = MailboxProbe()
        for i in 0..<100 { try mailbox.publish(String(format: "%03d.json", i)) }
        // Include the validation failures in the same drain, including a FIFO that must not block.
        try Data(repeating: 120, count: SubagentTransport.maximumRequestBytes + 1)
            .write(to: mailbox.requests.appendingPathComponent("large.json"))
        try FileManager.default.createSymbolicLink(at: mailbox.requests.appendingPathComponent("link.json"),
            withDestinationURL: mailbox.directory.appendingPathComponent("heartbeat.json"))
        #expect(mkfifo(mailbox.requests.appendingPathComponent("pipe.json").path, 0o600) == 0)
        try await mailbox.transport.drainRequests { batch in
            #expect(batch.count <= SubagentTransport.maximumBatchCount)
            for envelope in batch {
                await probe.receive(envelope)
                if ["large.json", "link.json", "pipe.json"].contains(envelope.filename) {
                    #expect(envelope.problem != nil && envelope.data.isEmpty)
                }
                // Leave the first full batch unacknowledged, as if persistence were unavailable.
                if envelope.filename >= "032.json" { try? await mailbox.transport.acknowledge(filename: envelope.filename) }
            }
            return true
        }
        #expect(await probe.names.count == 103)
        #expect(await Set(probe.names).count == 103)
        #expect(try await mailbox.transport.poll().count == 32)
        // Retrying can durably acknowledge the rest without repeating already-consumed actions.
        try await mailbox.transport.drainRequests { batch in
            for envelope in batch { try? await mailbox.transport.acknowledge(filename: envelope.filename) }
            return true
        }
        #expect(try await mailbox.transport.poll().isEmpty)
    }
}

private struct WatchedMailbox: Sendable {
    let root: URL
    let directory: URL
    let requests: URL
    let transport: SubagentTransport

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-watch-\(UUID().uuidString)")
        transport = SubagentTransport(namespace: UUID(), invocationID: UUID(), localRoot: root)
        let endpoint = try await transport.prepare(script: "#!/bin/sh\n", roster: Data("[]".utf8))
        directory = URL(fileURLWithPath: endpoint.ipcDirectory)
        requests = directory.appendingPathComponent("requests")
    }

    func publish(_ name: String, data: Data = Data("{}".utf8)) throws {
        try data.write(to: requests.appendingPathComponent(name), options: .atomic)
    }

    func consume(_ watcher: LocalMailboxWatcher, probe: MailboxProbe) -> Task<Void, Never> {
        Task {
            defer { watcher.cancel() }
            for await _ in watcher.changes {
                guard !Task.isCancelled else { break }
                await probe.wake()
                let scans = try? await transport.drainRequests { batch in
                    for envelope in batch {
                        await probe.receive(envelope)
                        try? await transport.acknowledge(filename: envelope.filename)
                    }
                    return true
                }
                await probe.scan(scans ?? 1)
            }
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private actor MailboxProbe {
    var scans = 0
    var wakeups = 0
    var names: [String] = []
    var latencies: [TimeInterval] = []
    func scan(_ count: Int = 1) { scans += count }
    func wake() { wakeups += 1 }
    func receive(_ envelope: SubagentEnvelope) {
        names.append(envelope.filename)
        if let start = Double(String(decoding: envelope.data, as: UTF8.self)) {
            latencies.append(Date().timeIntervalSince1970 - start)
        }
    }
}

private func waitForMailbox(seconds: TimeInterval = 5, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !(await condition()) {
        guard Date() < deadline else { Issue.record("Timed out waiting for mailbox"); throw CocoaError(.fileReadUnknown) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct PickupMeasurement {
    var scans: Int
    var wakeups: Int
    var notifications: Int
    var p50: Double
    var p95: Double
}

private func pickupBenchmark(watching: Bool) async throws -> PickupMeasurement {
    let mailbox = try await WatchedMailbox()
    defer { mailbox.cleanUp() }
    let probe = MailboxProbe()
    let watcher = watching ? LocalMailboxWatcher(directory: mailbox.requests) : nil
    let consumer: Task<Void, Never>
    if let watcher {
        consumer = mailbox.consume(watcher, probe: probe)
    } else {
        consumer = Task {
            while !Task.isCancelled {
                await probe.wake()
                await probe.scan()
                for envelope in (try? await mailbox.transport.poll()) ?? [] {
                    await probe.receive(envelope)
                    try? await mailbox.transport.acknowledge(filename: envelope.filename)
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
    }
    defer { consumer.cancel(); watcher?.cancel() }
    try await waitForMailbox { await probe.scans == 1 }
    for i in 0..<64 {
        try await Task.sleep(for: .milliseconds(7 + (i * 37) % 113))
        try mailbox.publish("\(i).json", data: Data(String(Date().timeIntervalSince1970).utf8))
    }
    try await waitForMailbox { await probe.names.count == 64 }
    let times = await probe.latencies.sorted()
    let scans = await probe.scans
    return await PickupMeasurement(scans: scans, wakeups: probe.wakeups, notifications: watcher?.notificationCount ?? 0,
                             p50: times[times.count / 2] * 1_000, p95: times[Int(ceil(Double(times.count) * 0.95)) - 1] * 1_000)
}
