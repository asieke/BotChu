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

    /// Providers names each limit's models once, beside a meter in 5-hour and one in Weekly.
    @Test func windowsGroupByModelsWithTheirShortAndLongWindow() throws {
        let claude = try UsageParser.claude(UsageSamples.claude, now: now).groups(at: now)
        #expect(claude.map(\.name) == ["All models", "Fable"])
        #expect(claude.map { [$0.short?.title, $0.long?.title] } == [["5-hour", "Weekly"], [nil, "Fable · Weekly"]])
        let google = try UsageParser.antigravity(UsageSamples.antigravity, now: now).groups(at: now)
        #expect(google.map(\.name) == ["Gemini", "Claude & GPT"])
        #expect(google.map { [$0.short?.title, $0.long?.title] } == [["Gemini · 5-hour", "Gemini · Weekly"], ["Claude & GPT · 5-hour", "Claude & GPT · Weekly"]])
        let codex = try UsageParser.codex(UsageSamples.codex, now: now).groups(at: now)
        #expect(codex.map(\.name) == ["All models"])
        #expect(codex[0].short == nil && codex[0].long?.title == "Weekly")
        // A daily window goes under 5-hour and says it is daily; one of unknown length, under Weekly.
        let daily = ProviderUsage(windows: [UsageWindow(id: "i", title: "Images · Daily", usedPercent: 61),
                                            UsageWindow(id: "a", title: "Allowance", usedPercent: 3)]).groups(at: now)
        #expect(daily.map(\.name) == ["Images · Daily", "All models"])
        #expect(daily[0].short?.id == "i" && daily[1].long?.id == "a")
        // Two of a kind in one group take a line each.
        let two = ProviderUsage(windows: [UsageWindow(id: "a", title: "5-hour", usedPercent: 1), UsageWindow(id: "b", title: "2-hour", usedPercent: 2)])
        #expect(two.groups(at: now).map(\.name) == ["All models", "All models · 2-hour"])
        // An OpenRouter key's spending limit is under Weekly, whatever its reset.
        let key = try UsageParser.openRouter(Data(#"{"data":{"limit":25,"limit_remaining":18.4,"limit_reset":"daily","budgets":[{"scope":"member","limit_usd":50,"remaining_usd":17.5}]}}"#.utf8), now: now)
        #expect(key.groups(at: now).map(\.name) == ["All models", "Member"])
        #expect(key.groups(at: now).allSatisfy { $0.short == nil && $0.long != nil })
    }

    @Test func parsersSayEachWindowsModelsAndLength() throws {
        let claude = try UsageParser.claude(UsageSamples.claude, now: now)
        #expect(claude.windows.map(\.group) == ["All models", "All models", "Fable"])
        #expect(claude.windows.map(\.period) == [18_000, 604_800, 604_800])
        let google = try UsageParser.antigravity(UsageSamples.antigravity, now: now)
        #expect(google.windows.map(\.group) == ["Gemini", "Gemini", "Claude & GPT", "Claude & GPT"])
        #expect(google.windows.map(\.period) == [604_800, 18_000, 604_800, 18_000])
        let extra = Data(#"{"rateLimitsByLimitId":{"review":{"limitName":"Code review","primary":{"usedPercent":0,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":1,"windowDurationMins":300}}}}"#.utf8)
        let codex = try UsageParser.codex(extra)
        #expect(codex.windows.map(\.group) == ["All models", "Code review"])
        #expect(codex.windows.map(\.period) == [18_000, 604_800])
        let muse = try UsageParser.muse(UsageSamples.muse, now: now.addingTimeInterval(3_600))
        #expect(muse.windows.map(\.period) == [18_000, 604_800])
        #expect(UsageParser.antigravityPeriod("daily") == 86_400 && UsageParser.antigravityPeriod("30m") == 1_800 && UsageParser.antigravityPeriod("soon") == nil)
        // A reading saved before windows had them takes them from its titles.
        let saved = Data(#"[{"id":"g","title":"Gemini · 5-hour","usedPercent":4},{"id":"k","title":"Key allowance","usedPercent":null,"detail":"$1.00 of $2.00 left"}]"#.utf8)
        let windows = try JSONDecoder().decode([UsageWindow].self, from: saved)
        #expect(windows.map(\.group) == ["Gemini", "All models"])
        #expect(windows.map(\.period) == [18_000, nil])
        #expect(windows[1].detail == "$1.00 of $2.00 left")
        let again = try JSONDecoder().decode([UsageWindow].self, from: JSONEncoder().encode(claude.windows))
        #expect(again == claude.windows)
    }

    /// Every reset says how long until it, and when: the time alone today, a weekday within six
    /// days, else a date.
    @Test func resetsGiveTheTimeLeftAndWhen() throws {
        let calendar = Calendar.current
        // Sunday 25 October, 6:12 AM, here.
        let sunday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 6, minute: 12)))
        func line(in seconds: TimeInterval) -> UsageLine { UsageLine(UsageWindow(id: "w", title: "Weekly", usedPercent: 9, resetsAt: sunday.addingTimeInterval(seconds)), at: sunday) }
        let soon = line(in: 4 * 3_600 + 28 * 60)
        #expect(soon.timeLeft == "4h 28m")
        #expect(soon.resetTime == sunday.addingTimeInterval(4 * 3_600 + 28 * 60).formatted(date: .omitted, time: .shortened))
        #expect(soon.resetSentence == "Resets in 4h 28m, today at \(soon.resetTime!)")
        let monday = line(in: 34 * 3_600 + 48 * 60) // Monday 5:00 PM
        #expect(monday.timeLeft == "1d 10h") // rounded down
        #expect(monday.resetTime == sunday.addingTimeInterval(34 * 3_600 + 48 * 60).formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        #expect(monday.resetSentence.hasPrefix("Resets in 1d 10h, Monday at "))
        let week = line(in: 6 * 86_400 + 19 * 3_600 + 44 * 60) // Sunday, Nov 1, 1:56 AM
        let nextSunday = sunday.addingTimeInterval(6 * 86_400 + 19 * 3_600 + 44 * 60)
        #expect(week.timeLeft == "6d 19h")
        #expect(week.resetTime == "\(nextSunday.formatted(.dateTime.month(.abbreviated).day())), \(nextSunday.formatted(date: .omitted, time: .shortened))")
        #expect(week.resetSentence == "Resets in 6d 19h, \(nextSunday.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) at \(nextSunday.formatted(date: .omitted, time: .shortened))")
        #expect(week.help == "Weekly: 9% used. \(week.resetSentence)")
        #expect(line(in: 28 * 60).timeLeft == "28m")
        #expect(line(in: 30).timeLeft == "<1m")
        // Tonight at 8:00 PM, the time alone; tomorrow at 5:00 PM, its weekday.
        let tonight = try #require(calendar.date(bySettingHour: 20, minute: 0, second: 0, of: sunday))
        #expect(line(in: tonight.timeIntervalSince(sunday)).resetTime == tonight.formatted(date: .omitted, time: .shortened))
        let five = try #require(calendar.date(bySettingHour: 17, minute: 0, second: 0, of: sunday))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: five))
        #expect(line(in: tomorrow.timeIntervalSince(sunday)).resetTime == tomorrow.formatted(.dateTime.weekday(.abbreviated).hour().minute()))

        // A passed reset hides the old share until the next reading.
        let passedAt = sunday.addingTimeInterval(-32 * 60)
        let passed = UsageLine(UsageWindow(id: "s", title: "5-hour", usedPercent: 2, resetsAt: passedAt), at: sunday)
        #expect(passed.hasReset && passed.percent == nil && passed.percentText == "—" && passed.timeLeft == nil)
        #expect(passed.reset == "Reset at \(passedAt.formatted(date: .omitted, time: .shortened))")
        #expect(passed.help == "5-hour: not read since its reset. \(passed.reset), waiting for a new reading")
        // A reset in words takes both slots; none says so.
        let words = UsageLine(UsageWindow(id: "k", title: "Key allowance", usedPercent: 0, resetDescription: "No scheduled reset", detail: "$25.00 of $25.00 left"), at: sunday)
        #expect(words.timeLeft == nil && words.reset == "No scheduled reset" && words.resetSentence == "No scheduled reset")
        #expect(words.help == "Key allowance: 0% used. No scheduled reset · $25.00 of $25.00 left")
        let unknown = UsageLine(UsageWindow(id: "u", title: "Weekly", usedPercent: nil), at: sunday)
        #expect(unknown.reset == "—" && unknown.resetSentence == "Reset time not reported" && unknown.help == "Weekly: not reported. Reset time not reported")
    }

    /// The table's columns are fixed widths for its size, and Agents takes the rest; under its
    /// narrowest, Credits & resets takes it.
    @Test func providersColumnsGiveAgentsTheRest() {
        // The 1,908-point window #148 was filed from, with the inspector open, a 1,180-point window, and narrower.
        let wide = ProvidersColumns(width: 1_615), regular = ProvidersColumns(width: 1_295), compact = ProvidersColumns(width: 887)
        #expect([wide.size, regular.size, compact.size] == [.wide, .regular, .compact])
        #expect([wide.provider, wide.models, wide.window, wide.credits] == [230, 110, 430, 200])
        #expect([regular.provider, regular.models, regular.window, regular.credits] == [190, 96, 322, 190])
        #expect([compact.provider, compact.models, compact.window, compact.credits] == [160, 96, 180, 160])
        #expect(wide.showsAgents && regular.showsAgents && compact.showsAgents)
        #expect(wide.rest(in: 1_615) == 1_615 - ProvidersColumns.edges - 1_400)
        #expect(wide.rest(in: 2_000) - wide.rest(in: 1_615) == 385) // every extra point is Agents'
        let noAgents = ProvidersColumns(width: 820)
        #expect(noAgents.size == .compact && !noAgents.showsAgents)
        #expect(noAgents.rest(in: 820) == 820 - ProvidersColumns.edges - 616) // Credits & resets takes it
        let tight = ProvidersColumns(width: ProvidersColumns.minimumWidth)
        #expect(tight.size == .tight && !tight.showsAgents)
        // Never wider than the table, at any width.
        for width in stride(from: ProvidersColumns.minimumWidth, through: 2_400, by: 1) {
            let columns = ProvidersColumns(width: width)
            let total = columns.provider + columns.models + 2 * columns.window + (columns.showsAgents ? columns.credits : 0) + columns.rest(in: width)
            #expect(total + ProvidersColumns.edges == width)
            #expect(columns.rest(in: width) >= (columns.showsAgents ? 56 : columns.credits))
        }
    }

    /// One bar width for every meter, up to 200 points, with the share, the time left and the reset
    /// time while it keeps 60, then without the reset time, the bar never under 40.
    @Test func metersKeepTheirSlotsAndGiveTheBarTheRest() {
        let wide = UsageMeterLayout(column: 430), regular = UsageMeterLayout(column: 322)
        let compact = UsageMeterLayout(column: 180), tight = UsageMeterLayout(column: 102)
        #expect([wide.bar, regular.bar, compact.bar, tight.bar] == [176, 68, 40, 40])
        #expect([wide.showsResetTime, regular.showsResetTime, compact.showsResetTime, tight.showsResetTime] == [true, true, false, false])
        #expect([wide.showsTimeLeft, regular.showsTimeLeft, compact.showsTimeLeft, tight.showsTimeLeft] == [true, true, true, false])
        #expect(UsageMeterLayout(column: 1_000).bar == UsageMeterLayout.maximumBar)
        #expect(ProvidersColumns(width: 1_615).meter == wide)
    }

    /// Line 2 under a profile's name: its family while all is well, else what is wrong.
    @Test func rowsSayWhatIsWrongByException() {
        let request = UsageRequest(account: Accounts.account(id: "codex-dev"), command: "codex-dev")
        let reading = ProviderUsage(windows: [UsageWindow(id: "w", title: "Weekly", usedPercent: 41, resetsAt: now.addingTimeInterval(86_400)),
                                              UsageWindow(id: "s", title: "5-hour", usedPercent: 7, resetsAt: now.addingTimeInterval(3_600)),
                                              UsageWindow(id: "r", title: "Code review · Weekly", usedPercent: 63)], readAt: now,
                                    credits: UsageCredits(available: true, balance: 12))
        func row(_ state: UsageState?, checking: Bool = false, found: Bool? = true, newest: Date? = nil) -> ProviderRow {
            ProviderRow(request: request, state: state, checking: checking, found: found, newest: newest ?? now, now: now)
        }
        let current = row(UsageState(reading: reading, checkedAt: now))
        #expect(current.status == .current)
        #expect(current.groups.map(\.name) == ["All models", "Code review"])
        #expect(current.badges.map(\.text) == ["12 credits"])
        #expect(current.shortShare == 7 && current.longShare == 63)
        #expect(current.id == "codex-dev" && current.name == "Codex Dev")
        // Ten minutes behind the page's newest reading, it says how old.
        #expect(row(UsageState(reading: reading, checkedAt: now), newest: now.addingTimeInterval(599)).status == .current)
        #expect(row(UsageState(reading: reading, checkedAt: now), newest: now.addingTimeInterval(600)).status == .behind(now))
        // Older than the background's interval, or a later check failed: stale.
        var old = reading
        old.readAt = now.addingTimeInterval(-request.backgroundInterval)
        #expect(row(UsageState(reading: old, checkedAt: old.readAt)).status == .stale(old.readAt))
        #expect(row(UsageState(reading: reading, error: "Timed out", checkedAt: now)).status == .stale(now))
        // Nothing read: failed, or checking while a check runs or none has been made.
        #expect(row(UsageState(error: "Could not read", checkedAt: now)).status == .failed("Could not read"))
        #expect(row(UsageState(error: "Could not read", checkedAt: now), checking: true).status == .checking)
        #expect(row(nil).status == .checking)
        #expect(row(nil).groups.isEmpty && row(nil).shortShare == -1 && row(nil).longShare == -1)
        // A command the login shell can't find, whatever was read.
        #expect(row(UsageState(reading: reading, checkedAt: now), found: false).status == .missingCommand)
        #expect(row(nil, found: nil).status == .checking)
        // A reading with no windows says what it has instead.
        let note = row(UsageState(reading: ProviderUsage(windows: [], note: "No key spending limit · $1.25 used", readAt: now), checkedAt: now))
        #expect(note.note == "No key spending limit · $1.25 used" && note.groups.isEmpty)
        #expect(ProviderRow.newest([nil, UsageState(reading: old), UsageState(reading: reading), UsageState(error: "x")]) == now)
        #expect(ProviderRow.newest([UsageState?]()) == nil)
    }

    @Test func creditsAndFreeResets() throws {
        let codex = try UsageParser.codex(UsageSamples.codexCredits, now: now)
        #expect(codex.windows.map(\.title) == ["Weekly"])
        #expect(codex.credits == UsageCredits(available: true, balance: 1_234.56789))
        let expiries = [Date(timeIntervalSince1970: 1_793_299_644), Date(timeIntervalSince1970: 1_794_007_201)]
        #expect(codex.resets == UsageResets(available: 2, expiries: expiries))
        let badges = codex.badges(at: now)
        let balance = 1_234.0.formatted(.number.precision(.fractionLength(0)))
        #expect(badges.map(\.kind) == [.credits, .resets])
        #expect(badges.map(\.text) == ["\(balance) credits", "2 free resets"]) // a week and more away
        #expect(badges.map(\.amount) == [balance, "2"])
        #expect(badges.allSatisfy { $0.available })
        let days = expiries.map { $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
        #expect(badges[1].help == "2 free resets of the usage limits, expiring \(days[0]) and \(days[1])")
        #expect(codex.facts == [UsageFact(label: "Usage credits", value: balance), UsageFact(label: "Free resets", value: "2"),
                                UsageFact(label: "They expire", value: expiries.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }.joined(separator: " · "))])
        // The soonest within three days says when.
        let soon = expiries[0].addingTimeInterval(-2 * 86_400)
        let weekday = expiries[0].formatted(.dateTime.weekday(.abbreviated))
        #expect(codex.badges(at: soon)[1].text == "2 free resets · 1 expires \(weekday)")
        let one = ProviderUsage(windows: [], resets: UsageResets(available: 1, expiries: [expiries[0]]))
        #expect(one.badges(at: soon).map(\.text) == ["1 free reset · expires \(weekday)"])
        #expect(one.badges(at: soon)[0].help == "1 free reset of the usage limits, expiring \(days[0])")
        #expect(one.facts.last == UsageFact(label: "It expires", value: expiries[0].formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())))
        let sameDay = ProviderUsage(windows: [], resets: UsageResets(available: 2, expiries: [expiries[0], expiries[0].addingTimeInterval(60)]))
        #expect(sameDay.badges(at: soon).map(\.text) == ["2 free resets · all expire \(weekday)"])
        #expect(sameDay.badges(at: expiries[0].addingTimeInterval(-60)).map(\.text).first?.hasSuffix(" · all expire today") == true)
        // An older answer says nothing of either; none, and the lines say so, dimmed.
        #expect(try UsageParser.codex(UsageSamples.codex, now: now).badges(at: now).isEmpty)
        #expect(try UsageParser.codex(UsageSamples.codex, now: now).facts.isEmpty)
        let none = Data(#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300},"credits":{"hasCredits":false,"unlimited":false,"balance":"0"}},"rateLimitResetCredits":{"availableCount":0,"credits":[{"status":"redeemed","expiresAt":1793299644}]}}"#.utf8)
        let empty = try UsageParser.codex(none, now: now)
        #expect(empty.badges(at: now).map(\.text) == ["No credits", "No free resets"])
        #expect(empty.badges(at: now).allSatisfy { !$0.available && $0.amount == nil })
        #expect(empty.facts == [UsageFact(label: "Usage credits", value: "None"), UsageFact(label: "Free resets", value: "None")])
        #expect(empty.resets?.expiries == []) // only available resets' expiries
        let unlimited = Data(#"{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300},"credits":{"hasCredits":false,"unlimited":true,"balance":null}}}"#.utf8)
        let endless = try UsageParser.codex(unlimited, now: now)
        #expect(endless.badges(at: now).map(\.text) == ["Unlimited credits"])
        #expect(endless.badges(at: now).map(\.amount) == ["Unlimited"])
        #expect(endless.facts == [UsageFact(label: "Usage credits", value: "Unlimited")])
        #expect(ProviderUsage(windows: [], resets: UsageResets(available: 1)).badges(at: now).map(\.text) == ["1 free reset"])
    }

    @Test func spendingLimitsShowTheMoneyLeft() throws {
        let key = try UsageParser.openRouter(Data(#"{"data":{"limit":25,"limit_remaining":18.4,"limit_reset":"weekly"}}"#.utf8), now: now)
        #expect(key.badges(at: now).map(\.text) == ["$18.40 of $25.00 left"])
        #expect(key.badges(at: now).map(\.amount) == ["$18.40"])
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
        async let second = cache.read(request, for: .manual, now: now)
        let results = await [first, second]
        #expect(results[0] == results[1])
        #expect(await probe.count() == 1)
        _ = await cache.read(request, now: now.addingTimeInterval(299))
        _ = await cache.read(request, for: .manual, now: now.addingTimeInterval(29))
        #expect(await probe.count() == 1)
        _ = await cache.read(request, for: .manual, now: now.addingTimeInterval(31))
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
        // Refresh waits for the provider's retry, which is later than its own limit.
        #expect(failed.nextManualCheck(interval: request.manualInterval) == now.addingTimeInterval(1_201))
        _ = await cache.read(request, for: .manual, now: now.addingTimeInterval(1_200))
        #expect(await probe.count() == 2)
        _ = await cache.read(request, for: .manual, now: now.addingTimeInterval(1_201))
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
        #expect(await again.isDue(request, for: .background, now: now.addingTimeInterval(600)) == false)
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
        _ = await cache.read(muse, for: .manual, now: now.addingTimeInterval(299))
        #expect(await probe.count() == 1)
        _ = await cache.read(muse, now: now.addingTimeInterval(3_600))
        #expect(await probe.count() == 2)
    }

    /// Model & Usage shows the reading the background keeps current (#147): opened on one younger
    /// than the background's interval, however often, it checks nothing; a missing or older one is
    /// checked once, and Refresh still checks within its own limit.
    @Test func modelAndUsageShowsTheBackgroundsReadingInsteadOfChecking() async {
        let probe = UsageFetchProbe()
        let cache = UsageCache { request, _ in try await probe.read(request) }
        let now = Date()
        // Nothing read yet: opening it checks.
        #expect(await cache.isDue(request, for: .background, now: now))
        let background = await cache.read(request, for: .background, now: now)
        #expect(await probe.count() == 1)
        // Opened again and again, or on another conversation on the account, within the interval.
        for minutes in [0.5, 5, 10, 14.9] {
            #expect(await cache.read(request, for: .background, now: now.addingTimeInterval(minutes * 60)) == background)
        }
        #expect(await probe.count() == 1)
        // Where Providers would check by now, it waits for the background's interval.
        #expect(await cache.isDue(request, for: .providers, now: now.addingTimeInterval(600)))
        #expect(await !cache.isDue(request, for: .background, now: now.addingTimeInterval(600)))
        // A reading as old as that is checked, once.
        let later = now.addingTimeInterval(request.backgroundInterval)
        let current = await cache.read(request, for: .background, now: later)
        #expect(current.checkedAt == later)
        #expect(await cache.read(request, for: .background, now: later.addingTimeInterval(60)) == current)
        #expect(await probe.count() == 2)
        // Refresh checks within it, at most every 30 seconds.
        #expect(current.nextManualCheck(interval: request.manualInterval) == later.addingTimeInterval(30))
        _ = await cache.read(request, for: .manual, now: later.addingTimeInterval(29))
        #expect(await probe.count() == 2)
        _ = await cache.read(request, for: .manual, now: later.addingTimeInterval(30))
        #expect(await probe.count() == 3)
    }

    /// What the background reads is what Model & Usage shows, also after a relaunch, and a check it
    /// makes is what the background and Providers show: one reading per profile.
    @Test func everyViewOfAProfileSharesOneReading() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let probe = UsageFetchProbe()
        let now = Date()
        let claude = Accounts.account(id: "claude-dev"), pi = Accounts.account(id: "openrouter")
        // Saving another OpenRouter key starts only a Pi profile's readings afresh.
        let shown = UsageRequest(account: claude, command: "claude-dev", openRouterKeyRevision: 3)
        #expect(shown == UsageRequest(account: claude, command: "claude-dev", openRouterKeyRevision: 0))
        #expect(UsageRequest(account: pi, command: "pi", openRouterKeyRevision: 3) != UsageRequest(account: pi, command: "pi", openRouterKeyRevision: 2))

        let background = UsageCache(fetch: { request, _ in try await probe.read(request) }, file: file)
        let read = await background.read(shown, for: .background, now: now)
        let relaunched = UsageCache(fetch: { request, _ in try await probe.read(request) }, file: file)
        #expect(await relaunched.saved(shown) == read)
        #expect(await relaunched.read(shown, for: .background, now: now.addingTimeInterval(600)) == read)
        #expect(await probe.count() == 1)
        // Refresh from Model & Usage: the next background or Providers look finds it, unchecked.
        let refreshed = await relaunched.read(shown, for: .manual, now: now.addingTimeInterval(601))
        #expect(await relaunched.saved(shown) == refreshed)
        #expect(await !relaunched.isDue(shown, for: .providers, now: now.addingTimeInterval(660)))
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
