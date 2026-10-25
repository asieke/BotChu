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

        let muse = try UsageParser.muse(UsageSamples.muse, now: now.addingTimeInterval(3_600))
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

    @Test func compactLinesShowAtMostFourWindows() {
        let resetsAt = now.addingTimeInterval(7_200)
        let windows = [UsageWindow(id: "a", title: "5-hour", usedPercent: 23.6, resetsAt: resetsAt),
                       UsageWindow(id: "b", title: "Weekly", usedPercent: 80, resetsAt: now),
                       UsageWindow(id: "c", title: "Key", usedPercent: 0, resetDescription: "No scheduled reset"),
                       UsageWindow(id: "d", title: "Unknown", usedPercent: nil)]
        let four = ProviderUsage(windows: windows).lines(at: now)
        #expect(four.more == 0)
        #expect(four.shown.map(\.id) == ["a", "b", "c", "d"])
        #expect(four.shown.map(\.percent) == [23.6, nil, 0, nil]) // a passed reset's reading isn't the new window's
        #expect(four.shown.map(\.percentText) == ["24%", "—", "0%", "—"])
        #expect(four.shown.map(\.reset) == [resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                                            "Reset passed", "No scheduled reset", "—"])
        // A reset at a known time also comes as its weekday and time apart, so times line up.
        #expect(four.shown.map(\.resetDay) == [resetsAt.formatted(.dateTime.weekday(.abbreviated)), nil, nil, nil])
        #expect(four.shown.map(\.resetTime) == [resetsAt.formatted(.dateTime.hour().minute()), nil, nil, nil])
        let five = ProviderUsage(windows: windows + [UsageWindow(id: "e", title: "Extra", usedPercent: 1)]).lines(at: now)
        #expect(five.shown.map(\.id) == ["a", "b", "c"]) // the fourth line says how many more
        #expect(five.more == 2)
    }

    @Test func lineWidthsAreTheWidestOfEveryRow() {
        let resetsAt = now.addingTimeInterval(7_200)
        let claude = ProviderUsage(windows: [UsageWindow(id: "a", title: "5-hour", usedPercent: 0, resetDescription: "Sat"),
                                             UsageWindow(id: "b", title: "Weekly", usedPercent: 54, resetsAt: now),
                                             UsageWindow(id: "d", title: "Weekly", usedPercent: 54, resetsAt: resetsAt)]).lines(at: now).shown
        let google = ProviderUsage(windows: [UsageWindow(id: "c", title: "Claude & GPT · 5-hour", usedPercent: 100)]).lines(at: now).shown
        var parts: [UsageLine.Part: Set<String>] = [:]
        let widths = UsageLineWidths(claude + google) { text, part in
            parts[part, default: []].insert(text)
            return Double(text.count) * (part == .title ? 6.5 : 6)
        }
        // Each part is measured in its own font, and rounded up to whole points.
        let day = resetsAt.formatted(.dateTime.weekday(.abbreviated)), time = resetsAt.formatted(.dateTime.hour().minute())
        #expect(parts == [.title: ["5-hour", "Weekly", "Claude & GPT · 5-hour"], .percent: ["0%", "54%", "—", "100%"],
                          .day: [day], .time: [time], .reset: ["Sat", "Reset passed", "—"]])
        #expect(widths == UsageLineWidths(title: 137, percent: 24, day: Double(day.count * 6), time: Double(time.count * 6), resetText: 72))
        // A reset is as wide as the widest weekday and time, or words, whichever is wider.
        #expect(widths.reset == max(Double((day.count + time.count) * 6) + UsageLineWidths.dayGap, 72))
        #expect(UsageLineWidths(title: 10, resetText: 30).reset == 30)
        #expect(UsageLineWidths([], measure: { _, _ in 10 }) == UsageLineWidths())
        let long = ProviderUsage(windows: [UsageWindow(id: "x", title: String(repeating: "Long ", count: 60), usedPercent: 1)]).lines(at: now).shown
        #expect(UsageLineWidths(long, measure: { text, _ in Double(text.count) * 6 }).title == UsageLineWidths.maxTitle)
    }

    @Test func linesGiveTheirBarsTheWidthLeft() {
        let widths = UsageLineWidths(title: 120, percent: 30, day: 26, time: 60, resetText: 0)
        let spacing = UsageLineLayout.spacing
        // Wide: the title, the share used, the bar in all that is left, and the reset at the end.
        let wide = UsageLineLayout(width: 900, widths: widths)
        #expect(wide.title == .init(x: 0, width: 120))
        #expect(wide.percent == .init(x: 120 + spacing, width: 30))
        #expect(wide.reset == .init(x: 900 - 90, width: 90))
        #expect(wide.bar == .init(x: 150 + 2 * spacing, width: 900 - 90 - spacing - (150 + 2 * spacing)))
        // Every extra point goes to the bar.
        #expect(UsageLineLayout(width: 1_200, widths: widths).bar.width == wide.bar.width + 300)
        // Just enough for the reset beside a shortest bar, then not: the reset goes first.
        let fits = 120 + 30 + UsageLineLayout.minimumBar + 90 + 3 * spacing
        #expect(UsageLineLayout(width: fits, widths: widths).bar.width == UsageLineLayout.minimumBar)
        let narrow = UsageLineLayout(width: fits - 1, widths: widths)
        #expect(narrow.reset == nil)
        #expect(narrow.title.width == 120)
        #expect(narrow.bar.x + narrow.bar.width == fits - 1)
        // Narrower still, the title is cut short, never the bar below its shortest.
        let tight = UsageLineLayout(width: 200, widths: widths)
        #expect(tight.title.width == 200 - 30 - UsageLineLayout.minimumBar - 2 * spacing)
        #expect(tight.bar.width == UsageLineLayout.minimumBar)
        #expect(UsageLineLayout(width: 0, widths: widths).title.width == 0)
        #expect(UsageLineLayout.idealWidth(widths) == 120 + 30 + UsageLineLayout.idealBar + 90 + 3 * spacing)
    }

    @Test func providersColumnsGiveTheAllowanceTheRest() {
        // The compact window, the default one, and the 1,908-point one #134 was filed from.
        let compact = ProvidersColumns(width: 580), regular = ProvidersColumns(width: 946), wide = ProvidersColumns(width: 1_614)
        #expect([compact.size, regular.size, wide.size] == [.compact, .regular, .wide])
        for (columns, width) in [(compact, 580.0), (regular, 946), (wide, 1_614)] {
            #expect(columns.allowance(in: width) > max(columns.provider, columns.command, columns.updated))
        }
        // Never wider than the table, at any width: each size's columns leave the allowance its
        // shortest where that size begins.
        for width in stride(from: ProvidersColumns.minimumWidth, through: 2_400, by: 1) {
            let columns = ProvidersColumns(width: width)
            #expect(columns.provider + columns.command + columns.updated + ProvidersColumns.minimumAllowance + ProvidersColumns.chrome <= width)
        }
        // Within a size, every extra point is the allowance's.
        #expect(wide.allowance(in: 1_614) == 1_614 - ProvidersColumns.chrome - 590)
        #expect(ProvidersColumns(width: 2_000) == wide)
        #expect(wide.allowance(in: 2_000) - wide.allowance(in: 1_614) == 386)
        // Wider tables give the name and command more room.
        #expect(compact.provider < regular.provider && regular.provider < wide.provider)
        #expect(compact.command < regular.command && regular.command < wide.command)
    }

    @Test func creditsAndFreeResets() throws {
        let codex = try UsageParser.codex(UsageSamples.codexCredits, now: now)
        #expect(codex.windows.map(\.title) == ["Weekly"])
        #expect(codex.credits == UsageCredits(available: true, balance: 1_234.56789))
        #expect(codex.resets == UsageResets(available: 2, expiries: [Date(timeIntervalSince1970: 1_793_299_644), Date(timeIntervalSince1970: 1_794_007_201)]))
        let badges = codex.badges(at: now)
        #expect(badges.map(\.kind) == [.credits, .resets])
        #expect(badges.map(\.text) == ["\(1_234.0.formatted(.number.precision(.fractionLength(0)))) credits", "2 free resets"])
        #expect(badges.allSatisfy(\.available))
        #expect(badges[1].help.contains(Date(timeIntervalSince1970: 1_793_299_644).formatted(date: .abbreviated, time: .shortened)))
        #expect(codex.details(at: now).contains("2 free resets of the usage limits"))
        // An older answer says nothing of either; none, and the chips say so.
        #expect(try UsageParser.codex(UsageSamples.codex, now: now).badges(at: now).isEmpty)
        let none = Data(#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}},"rateLimitResetCredits":{"availableCount":0,"credits":[{"status":"redeemed","expiresAt":1793299644}]}}"#.utf8)
        let empty = try UsageParser.codex(none, now: now)
        #expect(empty.badges(at: now).map(\.text) == ["No credits", "No free resets"])
        #expect(empty.badges(at: now).allSatisfy { !$0.available })
        #expect(empty.resets?.expiries == []) // only available resets' expiries
        let unlimited = Data(#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300},"credits":{"hasCredits":false,"unlimited":true,"balance":null}}}"#.utf8)
        #expect(try UsageParser.codex(unlimited, now: now).badges(at: now).map(\.text) == ["Unlimited credits"])
        #expect(ProviderUsage(windows: [], resets: UsageResets(available: 1)).badges(at: now).map(\.text) == ["1 free reset"])
    }

    @Test func spendingLimitsShowTheMoneyLeft() throws {
        let key = try UsageParser.openRouter(Data(#"{"data":{"limit":25,"limit_remaining":18.4,"limit_reset":"weekly"}}"#.utf8), now: now)
        #expect(key.badges(at: now).map(\.text) == ["$18.40 of $25.00 left"])
        #expect(key.badges(at: now)[0].help == "Key allowance: $18.40 of $25.00 left")
        #expect(key.badges(at: now)[0].available)
        // Spent, or past its reset: none to use, or nothing to say until the next reading.
        let spent = try UsageParser.openRouter(Data(#"{"data":{"limit":25,"limit_remaining":0,"limit_reset":null}}"#.utf8), now: now)
        #expect(spent.badges(at: now).map(\.available) == [false])
        #expect(key.badges(at: key.windows[0].resetsAt!).isEmpty)
        // With more than one, each says which it is.
        let two = try UsageParser.openRouter(Data(#"{"data":{"limit":25,"limit_remaining":18.4,"budgets":[{"scope":"member","limit_usd":50,"remaining_usd":17.5}]}}"#.utf8), now: now)
        #expect(two.badges(at: now).map(\.text) == ["Key $18.40 of $25.00 left", "Member $17.50 of $50.00 left"])
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
        // The key's own limit, which OpenRouter lists again as a budget, shows once.
        let keyLimit = #"{"scope":"key_limit","limit_usd":25,"remaining_usd":18.4,"reset_interval":"weekly","resets_at":"2026-10-26T00:00:00.000Z"}"#
        let both = try UsageParser.openRouter(Data(#"{"data":{"limit":25,"limit_remaining":18.4,"limit_reset":"weekly","budgets":[\#(keyLimit),{"scope":"organization_member","limit_usd":50,"remaining_usd":17.5}]}}"#.utf8))
        #expect(both.windows.map(\.title) == ["Key allowance", "Organization Member allowance"])
        let budgetOnly = try UsageParser.openRouter(Data(#"{"data":{"limit":null,"budgets":[\#(keyLimit)]}}"#.utf8))
        #expect(budgetOnly.windows.map(\.title) == ["Key allowance"])
    }

    @Test func museReadAnswerAndAClockAhead() throws {
        let later = Date(timeIntervalSince1970: 1_792_850_000)
        let reading = try UsageParser.muse(UsageSamples.museRead, now: later)
        #expect(reading.windows.map(\.title) == ["5-hour", "Weekly"])
        #expect(reading.windows.map(\.usedPercent) == [5, 34])
        #expect(reading.windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_854_028))
        #expect(reading.windows[1].resetsAt == Date(timeIntervalSince1970: 1_792_972_800))
        #expect(reading.readAt == Date(timeIntervalSince1970: 1_792_844_187.798))
        // Observed by Muse's clock a moment after this Mac's "now": read now, never "in 0 sec".
        let earlier = Date(timeIntervalSince1970: 1_792_844_187)
        #expect(try UsageParser.muse(UsageSamples.museRead, now: earlier).readAt == earlier)
        #expect(throws: UsageFailure.self) { try UsageParser.muse(Data(#"{"usage":null}"#.utf8)) }
        #expect(throws: UsageFailure.self) { try UsageParser.muse(Data(#"{"usage":{"tier":"0","window":{}}}"#.utf8)) }
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

    @Test func readingsAreSavedAndShownAfterARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let probe = UsageFetchProbe()
        let now = Date()
        let first = UsageCache(fetch: { request, _ in try await probe.read(request) }, file: file)
        #expect(await first.saved(request) == nil)
        let read = await first.read(request, now: now)
        #expect(read.reading != nil)
        // Only usage fields, by profile; no raw output.
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved.contains("claude-dev") && !saved.contains("Bearer"))

        // After a relaunch: the reading shows without a check, and isn't checked again until due.
        let again = UsageCache(fetch: { request, _ in try await probe.read(request) }, file: file)
        #expect(await again.saved(request) == read)
        #expect(await again.isDue(request, now: now.addingTimeInterval(60)) == false)
        #expect(await again.read(request, now: now.addingTimeInterval(60)) == read)
        #expect(await probe.count() == 1)
        // The background's longer interval, and the request's own.
        #expect(await again.isDue(request, maxAge: request.backgroundInterval, now: now.addingTimeInterval(600)) == false)
        #expect(await again.isDue(request, now: now.addingTimeInterval(600)))
        // A file from elsewhere, or none, starts empty.
        try Data("not json".utf8).write(to: file)
        #expect(await UsageCache(file: file).saved(request) == nil)
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

/// The Muse probe against a stand-in `muse serve` that speaks its JSON-RPC: what it does with
/// `usage/read` (after the answer, `answered` is 1 and `reads` counts those reads) is each test's.
@Suite struct MuseProbeTests {
    static let usage = #"{"window":{"usedPercent":5,"windowDurationMins":300,"resetsAtMs":1792854028000},"weekly":{"usedPercent":34,"resetsAtMs":1792972800000},"tier":"0","observedAtMs":1792844187798}"#

    private func probe(reads: String, turn: String = #"printf '%s\n' '{"method":"turn/started"}' '{"method":"turn/foregroundCompleted"}'"#,
                       timeout: TimeInterval = 5) throws -> (Result<ProviderUsage, UsageFailure>, log: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = """
        usage='\(Self.usage)'
        answered=0
        reads=0
        reply() { printf '{"id":%s,"result":%s}\\n' "$id" "$1"; }
        while IFS= read -r line; do
          id=$(printf '%s\\n' "$line" | sed -nE 's/.*"id":([0-9]+).*/\\1/p')
          method=$(printf '%s\\n' "$line" | sed -nE 's/.*"method":"([^"]*)".*/\\1/p' | tr -d '\\\\')
          echo "$method" >> log
          case $method in
            session/start) reply '{"session":{"sessionId":"s1"}}' ;;
            turn/start) reply '{}'; \(turn); answered=1 ;;
            usage/read)
              [ $answered = 1 ] && reads=$((reads + 1))
              \(reads) ;;
          esac
        done
        """
        let file = directory.appendingPathComponent("muse.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = try UsageProcess(command: "/bin/sh", arguments: [file.path], directory: directory, timeout: timeout)
        let result: Result<ProviderUsage, UsageFailure>
        do { result = .success(try ProviderUsageClient.museUsage(process, workspace: directory.path, poll: 0.01)) }
        catch { result = .failure(error as? UsageFailure ?? UsageFailure("unexpected")) }
        process.stop()
        let log = (try? String(contentsOf: directory.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        return (result, log)
    }

    private func reading(_ result: Result<ProviderUsage, UsageFailure>) -> ProviderUsage? {
        if case .success(let reading) = result { return reading }
        return nil
    }

    @Test func aReadingAlreadyKnownNeedsNoTurn() throws {
        let (result, log) = try probe(reads: #"reply "{\"usage\":$usage}""#)
        #expect(reading(result)?.windows.map(\.usedPercent) == [5, 34])
        #expect(!log.contains("turn/start"))
    }

    /// The reproduced failure: Muse 1.4.12 has the reading only once its turn winds down, and that
    /// can come long after the answer. The probe asked ten times, a second apart, then gave up.
    @Test func aTurnThatWindsDownLongAfterTheAnswerStillReports() throws {
        let (result, log) = try probe(reads: #"""
        if [ $reads -lt 15 ]; then reply '{}'
        else printf '%s\n' '{"method":"turn/completed"}'; reply "{\"usage\":$usage}"; fi
        """#)
        #expect(reading(result)?.windows.map(\.usedPercent) == [5, 34])
        #expect(log.components(separatedBy: "usage/read").count - 1 == 16)
    }

    /// `usage/changed` arrives while a `usage/read` is answered empty: the announced reading stays.
    @Test func aUsageNotificationDuringAnEmptyReadIsKept() throws {
        let (result, _) = try probe(reads: #"""
        if [ $reads = 3 ]; then printf '%s\n' "{\"method\":\"usage/changed\",\"params\":$usage}"; fi
        reply '{}'
        """#)
        #expect(reading(result)?.windows.map(\.usedPercent) == [5, 34])
    }

    /// Announced before the answer, during the turn: no asking needed.
    @Test func aUsageNotificationBeforeTheAnswerEndsTheProbe() throws {
        let (result, log) = try probe(reads: "reply '{}'",
            turn: #"printf '%s\n' '{"method":"turn/started"}' "{\"method\":\"usage/changed\",\"params\":$usage}""#)
        #expect(reading(result)?.windows.map(\.usedPercent) == [5, 34])
        #expect(log.components(separatedBy: "usage/read").count - 1 == 1)
    }

    @Test func missingUsageFailsSoonAfterTheTurnEnds() throws {
        let started = Date()
        let (result, log) = try probe(reads: #"""
        [ $reads = 2 ] && printf '%s\n' '{"method":"turn/completed"}'
        reply '{"usage":null}'
        """#)
        guard case .failure(let failure) = result else { Issue.record("Expected no reading"); return }
        #expect(failure.message == "Muse did not return account usage. Try refreshing later.")
        #expect(log.components(separatedBy: "usage/read").count - 1 == 8) // the first, two, then five after the end
        #expect(Date().timeIntervalSince(started) < 3)

        let (failed, _) = try probe(reads: "reply '{}'", turn: #"printf '%s\n' '{"method":"turn/failed","params":{"error":{"message":"private"}}}'"#)
        guard case .failure(let turnFailure) = failed else { Issue.record("Expected no reading"); return }
        #expect(turnFailure.message.contains("sign-in"))
        #expect(!turnFailure.message.contains("private"))
    }

    @Test func aTurnThatNeverEndsIsBoundedByTheDeadline() throws {
        let started = Date()
        let (result, _) = try probe(reads: "reply '{}'", timeout: 0.5)
        guard case .failure(let failure) = result else { Issue.record("Expected no reading"); return }
        #expect(failure.message == "Usage check timed out. Try refreshing later.")
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
