import Foundation
import Testing
@testable import BotChuCore

@Suite struct ProviderUsageTests {
    let now = Date(timeIntervalSince1970: 1_792_679_400) // 2026-10-22 14:30 UTC

    @Test func capturedNativeReadings() throws {
        let claude = try UsageParser.claude(UsageSamples.claude, now: now)
        #expect(claude.windows.map(\.title) == ["5-hour", "Weekly", "Fable · Weekly"])
        #expect(claude.windows.map(\.usedPercent) == [0, 8, 7])
        #expect(claude.windows[0].resetsAt == nil)
        #expect(claude.windows[1].resetsAt == ISO8601DateFormatter().date(from: "2026-10-26T13:00:00Z"))

        let codex = try UsageParser.codex(UsageSamples.codex, now: now)
        #expect(codex.windows.count == 1) // legacy and map are the same bucket
        #expect(codex.windows[0].title == "Weekly")
        #expect(codex.windows[0].usedPercent == 100)
        #expect(codex.windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_106_332))

        let google = try UsageParser.antigravity(UsageSamples.antigravity, now: now)
        #expect(google.windows.map(\.title) == ["Gemini · Weekly", "Gemini · 5-hour", "Claude & GPT · Weekly", "Claude & GPT · 5-hour"])
        #expect(abs(google.windows[0].usedPercent! - 5.43961524963379) < 0.00001)
        #expect(google.windows[2].usedPercent == 0)

        let muse = try UsageParser.muse(UsageSamples.muse, now: now)
        #expect(muse.windows.map(\.usedPercent) == [3, 20])
        #expect(muse.windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_687_416))
        #expect(muse.readAt == Date(timeIntervalSince1970: 1_792_681_252.222))
    }

    @Test func codexLegacyExtraBucketsAndMissingFields() throws {
        let legacy = Data(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300},"secondary":{"usedPercent":null,"resetsAt":1793106332}}}"#.utf8)
        let reading = try UsageParser.codex(legacy)
        #expect(reading.windows.map(\.title) == ["5-hour", "Allowance"])
        #expect(reading.windows[1].usedPercent == nil)
        let extra = Data(#"{"rateLimitsByLimitId":{"review":{"limitName":"Code review","primary":{"usedPercent":0,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":true,"windowDurationMins":300}}}}"#.utf8)
        let buckets = try UsageParser.codex(extra)
        #expect(buckets.windows.map(\.title) == ["5-hour", "Code review · Weekly"])
        #expect(buckets.windows[0].usedPercent == nil) // booleans must not become 1%
    }

    @Test func unknownAndErrorResponsesAreUnavailableNotZero() {
        for data in [Data(), Data("{}".utf8), Data(#"{"error":{"message":"secret text"}}"#.utf8)] {
            #expect(throws: UsageFailure.self) { try UsageParser.codex(data) }
            #expect(throws: UsageFailure.self) { try UsageParser.claude(data) }
            #expect(throws: UsageFailure.self) { try UsageParser.antigravity(data) }
            #expect(throws: UsageFailure.self) { try UsageParser.muse(data) }
            #expect(throws: UsageFailure.self) { try UsageParser.openRouter(data) }
        }
        #expect(throws: UsageFailure.self) {
            try UsageParser.claude(Data(#"{"is_error":true,"result":"Current session: 0% used"}"#.utf8))
        }
        let invalid = UsageWindow(id: "a", title: "A", usedPercent: -.infinity)
        #expect(invalid.usedPercent == nil)
    }

    @Test func resetExpiryAndClaudeTimezones() {
        let window = UsageWindow(id: "a", title: "A", usedPercent: 80, resetsAt: now)
        #expect(window.currentPercent(at: now.addingTimeInterval(-1)) == 80)
        #expect(window.currentPercent(at: now) == nil)
        #expect(window.hasReset(at: now))
        let iso = ISO8601DateFormatter()
        #expect(UsageParser.claudeReset("3:30pm (America/New_York)", now: now) == iso.date(from: "2026-10-22T19:30:00Z"))
        #expect(UsageParser.claudeReset("9am (America/New_York)", now: now) == iso.date(from: "2026-10-22T13:00:00Z"))
        let december = iso.date(from: "2026-12-30T12:00:00Z")!
        #expect(UsageParser.claudeReset("Jan 2 at 9am (America/New_York)", now: december) == iso.date(from: "2027-01-02T14:00:00Z"))
        #expect(UsageParser.claudeReset("tomorrow-ish", now: now) == nil)
        #expect(UsageParser.claudeReset("9am (Not/A_Zone)", now: now) == nil)
    }

    @Test func openRouterLimitsAndUTCResets() throws {
        let data = Data(#"{"data":{"limit":100,"limit_remaining":74.5,"limit_reset":"weekly","usage":999,"usage_weekly":25.5}}"#.utf8)
        let reading = try UsageParser.openRouter(data, now: now)
        #expect(reading.windows[0].usedPercent == 25.5) // lifetime usage is not this week's usage
        #expect(reading.windows[0].resetsAt == ISO8601DateFormatter().date(from: "2026-10-26T00:00:00Z"))
        let unlimited = try UsageParser.openRouter(Data(#"{"data":{"limit":null,"limit_remaining":null,"usage":15}}"#.utf8))
        #expect(unlimited.windows.isEmpty)
        #expect(unlimited.note?.hasPrefix("No key spending limit") == true)
        let zero = try UsageParser.openRouter(Data(#"{"data":{"limit":0,"limit_remaining":0,"limit_reset":null}}"#.utf8))
        #expect(zero.windows[0].usedPercent == nil)
        #expect(zero.windows[0].resetsAt == nil)
        let budget = try UsageParser.openRouter(Data(#"{"data":{"limit":null,"budgets":[{"scope":"member","limit_usd":50,"remaining_usd":17.5,"resets_at":"2026-10-26T00:00:00.000Z"}]}}"#.utf8))
        #expect(budget.windows[0].title == "Member allowance")
        #expect(budget.windows[0].usedPercent == 65)
        #expect(budget.windows[0].resetsAt != nil)
    }

    @Test func museLegacyTimestampUnits() throws {
        for reset in [1_793_106_332.0, 1_793_106_332_000.0, 1_793_106_332_000_000.0] {
            let data = try JSONSerialization.data(withJSONObject: ["usage": ["window": ["used_percent": 5, "resets_at": reset, "window_duration_mins": 300]]])
            let reading = try UsageParser.muse(data)
            #expect(reading.windows[0].usedPercent == 5)
            #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_793_106_332))
        }
    }
}

private actor UsageFetchProbe {
    var calls = 0
    var failure: UsageFailure?
    func fail(_ error: UsageFailure) { failure = error }
    func count() -> Int { calls }
    func read(_ request: UsageRequest) async throws -> ProviderUsage {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        if let failure { throw failure }
        return ProviderUsage(windows: [UsageWindow(id: request.account.id, title: request.account.name, usedPercent: 25)])
    }
}

@Suite struct UsageCacheTests {
    let request = UsageRequest(account: Accounts.account(id: "claude-dev"), command: "claude-dev")

    @Test func coalescesAndThrottlesRefreshes() async {
        let probe = UsageFetchProbe()
        let cache = UsageCache { request, _ in try await probe.read(request) }
        let now = Date()
        async let first = cache.read(request, now: now)
        async let second = cache.read(request, manual: true, now: now)
        let results = await [first, second]
        #expect(results[0] == results[1])
        #expect(await probe.count() == 1)
        _ = await cache.read(request, now: now.addingTimeInterval(299))
        _ = await cache.read(request, manual: true, now: now.addingTimeInterval(29))
        #expect(await probe.count() == 1)
        _ = await cache.read(request, manual: true, now: now.addingTimeInterval(31))
        #expect(await probe.count() == 2)
    }

    @Test func accountCommandAndCredentialChangesCannotShareReadings() async {
        let probe = UsageFetchProbe()
        let cache = UsageCache { request, _ in try await probe.read(request) }
        _ = await cache.read(request)
        var other = request
        other.account = Accounts.account(id: "claude-work")
        let reading = await cache.read(other)
        #expect(reading.reading?.windows[0].id == "claude-work")
        other = request
        other.command = "custom-claude"
        _ = await cache.read(other)
        other.credentialRevision += 1
        _ = await cache.read(other)
        #expect(await probe.count() == 4)
    }

    @Test func failurePreservesDatedReadingAndHonorsBackoff() async {
        let probe = UsageFetchProbe()
        let cache = UsageCache { request, _ in try await probe.read(request) }
        let now = Date()
        let good = await cache.read(request, now: now)
        await probe.fail(UsageFailure("Try later", retryAfter: 900))
        let failed = await cache.read(request, now: now.addingTimeInterval(301))
        #expect(failed.reading == good.reading)
        #expect(failed.error == "Try later")
        #expect(failed.isStale(at: now, interval: 300))
        _ = await cache.read(request, manual: true, now: now.addingTimeInterval(1_200))
        #expect(await probe.count() == 2)
        _ = await cache.read(request, manual: true, now: now.addingTimeInterval(1_201))
        #expect(await probe.count() == 3)
    }

    @Test func museDoesNotSpendAllowanceOnEverySelectionOrTurn() async {
        let probe = UsageFetchProbe()
        let cache = UsageCache { request, _ in try await probe.read(request) }
        let muse = UsageRequest(account: Accounts.account(id: "muse"), command: "muse")
        let now = Date()
        _ = await cache.read(muse, now: now)
        _ = await cache.read(muse, now: now.addingTimeInterval(3_599))
        _ = await cache.read(muse, manual: true, now: now.addingTimeInterval(299))
        #expect(await probe.count() == 1)
        _ = await cache.read(muse, now: now.addingTimeInterval(3_600))
        #expect(await probe.count() == 2)
    }
}

@Suite struct UsageProcessTests {
    private func withProcess(_ script: String, timeout: TimeInterval = 2,
                             _ body: (UsageProcess) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("probe.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = try UsageProcess(command: "/bin/sh", arguments: [file.path], directory: directory, timeout: timeout)
        defer { process.stop() }
        try body(process)
    }

    @Test func nativeRPCWaitsForMatchingResponseAndHandlesNotifications() throws {
        try withProcess(#"""
        read -r request
        printf '%s\n' 'not json' '{"method":"usage/changed","params":{"window":{"usedPercent":7,"windowDurationMins":300}}}' '{"id":99,"result":{}}' '{"id":1,"result":{"ok":true}}'
        read -r next_request
        """#) { process in
            let result = try process.call("initialize")
            #expect(result["ok"] as? Bool == true)
            #expect(process.museReading?.windows[0].usedPercent == 7)
        }
    }

    @Test func stderrAndRawRPCFailuresAreNeverUserFacing() throws {
        try withProcess("echo 'private credentials' >&2\nexit 1\n") { process in
            do {
                _ = try process.output()
                Issue.record("Expected failure")
            } catch {
                #expect(!error.localizedDescription.contains("private credentials"))
            }
        }
        try withProcess(#"""
        read -r request
        printf '%s\n' '{"id":1,"error":{"message":"private credentials"}}'
        """#) { process in
            #expect(throws: UsageFailure.self) { try process.call("initialize") }
        }
    }

    @Test func deadlineBoundsAHostThatNeverResponds() throws {
        let started = Date()
        try withProcess("exec /bin/sleep 20\n", timeout: 0.3) { process in
            #expect(throws: UsageFailure.self) { try process.call("initialize") }
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
