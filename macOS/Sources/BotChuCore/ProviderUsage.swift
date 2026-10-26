import Foundation

/// Account allowance, independent of a bot's token counts or conversation.
public struct ProviderUsage: Equatable, Sendable, Codable {
    public var windows: [UsageWindow]
    public var note: String?
    public var readAt: Date
    /// Credits the account can spend besides its limits, when its CLI reports them (Codex).
    public var credits: UsageCredits?
    /// Free resets of the account's limits, when its CLI reports them (Codex).
    public var resets: UsageResets?

    public init(windows: [UsageWindow], note: String? = nil, readAt: Date = .now, credits: UsageCredits? = nil, resets: UsageResets? = nil) {
        self.windows = windows
        self.note = note
        self.readAt = readAt
        self.credits = credits
        self.resets = resets
    }
}

/// Whether an account has usage credits, and how many.
public struct UsageCredits: Equatable, Sendable, Codable {
    public var available: Bool
    public var unlimited: Bool
    public var balance: Double?

    public init(available: Bool, unlimited: Bool = false, balance: Double? = nil) {
        self.available = available
        self.unlimited = unlimited
        self.balance = balance.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// How many free resets of its limits an account can use, and when each runs out.
public struct UsageResets: Equatable, Sendable, Codable {
    public var available: Int
    /// The available resets' expiry dates, soonest first.
    public var expiries: [Date]

    public init(available: Int, expiries: [Date] = []) {
        self.available = max(0, available)
        self.expiries = expiries.sorted()
    }
}

public struct UsageWindow: Identifiable, Equatable, Sendable, Codable {
    /// The group of a limit on every model the account runs.
    public static let allModels = "All models"
    public static let fiveHours: TimeInterval = 18_000
    public static let day: TimeInterval = 86_400
    public static let week: TimeInterval = 604_800
    public var id: String
    public var title: String
    /// The models the limit covers ("All models", "Fable", "Gemini"), named once in Providers.
    public var group: String
    /// How long the window is, when its CLI says: Providers shows one of a day or less under
    /// 5-hour, and any other under Weekly.
    public var period: TimeInterval?
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var resetDescription: String?
    public var detail: String?

    /// Without a group or a period, the window takes the ones its title gives ("Gemini · 5-hour").
    public init(id: String, title: String, usedPercent: Double?, resetsAt: Date? = nil,
                resetDescription: String? = nil, detail: String? = nil, group: String? = nil, period: TimeInterval? = nil) {
        let titled = Self.titled(title)
        self.id = id
        self.title = title
        self.group = group ?? titled.group
        self.period = period ?? titled.period
        self.usedPercent = usedPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.detail = detail
    }

    /// A window saved before windows had a group and a period takes the ones its title gives.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id), title: try container.decode(String.self, forKey: .title),
                  usedPercent: try container.decodeIfPresent(Double.self, forKey: .usedPercent),
                  resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
                  resetDescription: try container.decodeIfPresent(String.self, forKey: .resetDescription),
                  detail: try container.decodeIfPresent(String.self, forKey: .detail),
                  group: try container.decodeIfPresent(String.self, forKey: .group),
                  period: try container.decodeIfPresent(TimeInterval.self, forKey: .period))
    }

    /// The group and period a title names: "Gemini · 5-hour" is Gemini's five hours, "Weekly" all
    /// models' week, and "Key allowance" all models' for no set period.
    static func titled(_ title: String) -> (group: String, period: TimeInterval?) {
        let parts = title.components(separatedBy: " · ")
        let group = parts.count > 1 ? parts.dropLast().joined(separator: " · ") : allModels
        return (group, UsageParser.period(named: parts.last ?? title))
    }

    public func hasReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }

    /// A reading from an ended window is not the new window's usage.
    public func currentPercent(at now: Date) -> Double? { hasReset(at: now) ? nil : usedPercent }

    /// A window of a day or less, which Providers shows under 5-hour.
    public var isShort: Bool { period.map { $0 <= Self.day } ?? false }
}

/// An allowance window as one line of Providers' meters and the inspector: the share used, and its
/// reset as the time left and when it is.
public struct UsageLine: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var percent: Double?
    public var percentText: String
    /// How long until the reset, rounded down, in its two largest units ("4h 28m", "1d 10h"), which
    /// Providers shows after "in"; nil when the reset isn't a time ahead.
    public var timeLeft: String?
    /// When the reset is: the time alone today ("10:40 AM"), the weekday and time within six days
    /// ("Mon 5:00 PM"), else the date and time ("Nov 1, 1:56 AM").
    public var resetTime: String?
    /// The reset in words where it isn't a time ahead: "Reset at 5:40 AM" once it has passed, what
    /// the CLI said, or "—"; for one ahead, the time left and when.
    public var reset: String
    /// The reset as the inspector says it: "Resets in 1d 10h, Monday at 5:00 PM".
    public var resetSentence: String
    /// "Weekly: 9% used. Resets in 6d 19h, Sunday, Nov 1 at 1:56 AM", and the money left under a
    /// spending limit.
    public var help: String
    /// The window has reset since it was read, so its share is unknown until the next reading.
    public var hasReset: Bool

    public init(_ window: UsageWindow, at now: Date) {
        id = window.id
        title = window.title
        hasReset = window.hasReset(at: now)
        percent = window.currentPercent(at: now)
        percentText = percent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "—"
        if hasReset, let date = window.resetsAt {
            reset = "Reset at \(UsageTime.when(date, now: now))"
            resetSentence = "\(reset), waiting for a new reading"
        } else if let date = window.resetsAt {
            let left = UsageTime.left(date.timeIntervalSince(now))
            timeLeft = left
            resetTime = UsageTime.when(date, now: now)
            reset = "in \(left), \(resetTime!)"
            resetSentence = "Resets in \(left), \(UsageTime.whenInWords(date, now: now))"
        } else if let text = window.resetDescription {
            reset = text
            resetSentence = text == "No scheduled reset" ? text : "Resets \(text)"
        } else {
            reset = "—"
            resetSentence = "Reset time not reported"
        }
        let share = hasReset ? "not read since its reset" : percent == nil ? "not reported" : "\(percentText) used"
        let money = hasReset ? nil : window.detail
        help = "\(window.title): \(share). \(resetSentence)" + (money.map { " · \($0)" } ?? "")
    }
}

/// How Providers says when a reset is.
enum UsageTime {
    /// Rounded down, in its two largest units: "28m", "4h 28m", "1d 10h"; under a minute, "<1m".
    static func left(_ interval: TimeInterval) -> String {
        guard interval >= 60 else { return "<1m" }
        return Duration.seconds(interval).formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 2,
                                                           fractionalPart: .hide(rounded: .down)))
    }

    /// The time alone today, the weekday and time within six days, else the date and time, so no
    /// weekday is ever a week out.
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if abs(date.timeIntervalSince(now)) < 6 * UsageWindow.day { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// "today at 10:40 AM", "Monday at 5:00 PM", "Sunday, Nov 1 at 1:56 AM".
    static func whenInWords(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if date.timeIntervalSince(now) < 6 * UsageWindow.day { return "\(date.formatted(.dateTime.weekday(.wide))) at \(time)" }
        return "\(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) at \(time)"
    }
}

/// The windows of one model group, as a Providers row shows them: the short one (a day or less)
/// under 5-hour and the long one under Weekly, beside the group's name.
public struct UsageGroup: Identifiable, Equatable, Sendable {
    public var id: Int
    /// The group, and a window's length when it isn't its column's: "Gemini", "Images · Daily".
    public var name: String
    public var short: UsageLine?
    public var long: UsageLine?
}

extension ProviderUsage {
    /// The windows by model group, in the order the CLI first names each, every group with its short
    /// and its long window. A group with two of either takes a second line for the other.
    public func groups(at now: Date) -> [UsageGroup] {
        var slots: [(group: String, short: UsageWindow?, long: UsageWindow?)] = []
        for window in windows {
            let short = window.isShort
            if let index = slots.firstIndex(where: { $0.group == window.group && (short ? $0.short : $0.long) == nil }) {
                if short { slots[index].short = window } else { slots[index].long = window }
            } else {
                slots.append((window.group, short ? window : nil, short ? nil : window))
            }
        }
        return slots.enumerated().map { index, slot in
            // A short window of other than five hours, or a long one of other than a week, says how long it is.
            let lengths = [slot.short.flatMap { $0.period == UsageWindow.fiveHours ? nil : $0.period },
                           slot.long.flatMap { $0.period == UsageWindow.week ? nil : $0.period }]
                .compactMap { $0 }.map { UsageParser.duration($0 / 60) }
            return UsageGroup(id: index, name: ([slot.group] + lengths).joined(separator: " · "),
                              short: slot.short.map { UsageLine($0, at: now) }, long: slot.long.map { UsageLine($0, at: now) })
        }
    }

    /// What the account has besides its windows' share, a line each in Providers' Credits & resets:
    /// the money left in a window that is a spending limit (an OpenRouter key's), its usage credits
    /// and its free resets, with the soonest expiry when that is within three days.
    public func badges(at now: Date) -> [UsageBadge] {
        let spending = windows.filter { $0.detail != nil && !$0.hasReset(at: now) }
        var badges = spending.map { window in
            let detail = window.detail ?? ""
            let scope = window.title.replacingOccurrences(of: " allowance", with: "")
            return UsageBadge(id: "spend:\(window.id)", kind: .spend, text: spending.count > 1 ? "\(scope) \(detail)" : detail,
                              amount: detail.components(separatedBy: " of ").first,
                              available: (window.currentPercent(at: now) ?? 0) < 100, help: "\(window.title): \(detail)")
        }
        if let credits {
            let balance = credits.balance.map { $0.rounded(.down).formatted(.number.precision(.fractionLength(0))) }
            let amount = credits.unlimited ? "Unlimited" : credits.available ? balance : nil
            let text = !credits.available && !credits.unlimited ? "No credits" : amount.map { "\($0) credits" } ?? "Credits available"
            badges.append(UsageBadge(id: "credits", kind: .credits, text: text, amount: amount, available: credits.available || credits.unlimited,
                                     help: credits.available || credits.unlimited ? "Usage credits the account can spend after its limits: \(text.lowercased())"
                                         : "No usage credits on this account"))
        }
        if let resets {
            let count = resets.available
            var text = count == 0 ? "No free resets" : count == 1 ? "1 free reset" : "\(count) free resets"
            if count > 0, let soonest = resets.expiries.first, soonest > now, soonest.timeIntervalSince(now) < 3 * UsageWindow.day {
                let calendar = Calendar.current
                let day = calendar.isDate(soonest, inSameDayAs: now) ? "today" : soonest.formatted(.dateTime.weekday(.abbreviated))
                let that = resets.expiries.filter { calendar.isDate($0, inSameDayAs: soonest) }.count
                text += count == 1 ? " · expires \(day)" : that >= count ? " · all expire \(day)" : " · \(that) expire\(that == 1 ? "s" : "") \(day)"
            }
            let expiring = resets.expiries.map { $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            badges.append(UsageBadge(id: "resets", kind: .resets, text: text, amount: count > 0 ? "\(count)" : nil, available: count > 0,
                                     help: count == 0 ? "No free resets of the usage limits"
                                         : "\(count == 1 ? "1 free reset" : "\(count) free resets") of the usage limits"
                                         + (expiring.isEmpty ? "" : ", expiring \(expiring.formatted(.list(type: .and)))")))
        }
        return badges
    }

    /// What the inspector lists under the windows: the usage credits, the free resets and when
    /// they expire.
    public var facts: [UsageFact] {
        var facts: [UsageFact] = []
        if let credits {
            let balance = credits.balance.map { $0.rounded(.down).formatted(.number.precision(.fractionLength(0))) }
            facts.append(UsageFact(label: "Usage credits", value: credits.unlimited ? "Unlimited" : !credits.available ? "None" : balance ?? "Available"))
        }
        if let resets {
            facts.append(UsageFact(label: "Free resets", value: resets.available == 0 ? "None" : "\(resets.available)"))
            if resets.available > 0, !resets.expiries.isEmpty {
                facts.append(UsageFact(label: resets.expiries.count == 1 ? "It expires" : "They expire",
                                       value: resets.expiries.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }.joined(separator: " · ")))
            }
        }
        return facts
    }
}

/// Something an account has besides its windows' share, a line in Providers' Credits & resets:
/// money left under a spending limit, usage credits, or free resets of its limits.
public struct UsageBadge: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case spend, credits, resets }
    public var id: String
    public var kind: Kind
    public var text: String
    /// The part of `text` that says how much ("65,292", "$24.99", "2"), shown brighter while there
    /// is some to use.
    public var amount: String?
    /// There is some to use: money, credits or resets left.
    public var available: Bool
    public var help: String
}

/// A label and its value in the inspector's Usage card: "Usage credits", "65,292".
public struct UsageFact: Identifiable, Equatable, Sendable {
    public var label: String
    public var value: String
    public var id: String { label }
}

/// How the Providers table shares out its width. The provider, its model groups, the 5-hour and
/// Weekly columns and its credits take fixed widths for the table's size, and Agents takes the rest,
/// so the two window columns stay alike and the table resizes only one column itself; a table that
/// crosses into another size is made anew for it, never left as an earlier window size had it.
/// The widths are the columns' pitch, the space between them included.
public struct ProvidersColumns: Equatable, Sendable {
    public enum Size: Sendable { case tight, compact, regular, wide }
    /// What the inset table puts between its columns (which the widths below include) and at its edges.
    public static let spacing = 17.0
    public static let edges = 16.0
    /// The narrowest table, in the narrowest window.
    public static let minimumWidth = 580.0
    public var size: Size
    public var provider: Double
    public var models: Double
    /// The 5-hour and Weekly columns, each.
    public var window: Double
    public var credits: Double
    /// Whether Agents fits, after the others; under it, Credits & resets takes the rest.
    public var showsAgents: Bool
    public var meter: UsageMeterLayout

    public init(width: Double) {
        let room = width - Self.edges
        // Each size's columns, and the narrowest Agents it is used with.
        let wide = (230.0, 110.0, 430.0, 200.0, 100.0), regular = (190.0, 96.0, 322.0, 190.0, 60.0), compact = (160.0, 96.0, 180.0, 160.0, 56.0)
        func fixed(_ size: (Double, Double, Double, Double, Double)) -> Double { size.0 + size.1 + 2 * size.2 + size.3 }
        let chosen: (Double, Double, Double, Double, Double)
        if room >= fixed(wide) + wide.4 {
            (size, chosen) = (.wide, wide)
        } else if room >= fixed(regular) + regular.4 {
            (size, chosen) = (.regular, regular)
        } else if room >= fixed(compact) {
            (size, chosen) = (.compact, compact)
        } else {
            // Narrower still: the meters keep their bar and share, the rest in their tooltips.
            (size, chosen) = (.tight, (150, 80, 102, 130, 56))
        }
        (provider, models, window, credits) = (chosen.0, chosen.1, chosen.2, chosen.3)
        showsAgents = room >= fixed(chosen) + chosen.4
        meter = UsageMeterLayout(column: window)
    }

    /// The column that takes the rest of a table this wide: Agents, or Credits & resets without it.
    public func rest(in width: Double) -> Double {
        let others = provider + models + 2 * window + (showsAgents ? credits : 0)
        return max(showsAgents ? 56 : credits, width - Self.edges - others)
    }
}

/// How a meter line fills its column: a bar of at most 200 points, then the share, the time left and
/// when the reset is, each in a slot of its own so they line up down the column. In a column too
/// narrow for a bar of 60 beside them, the reset time goes (it is in the tooltip), and then the time
/// left; the bar is never under 40. Every meter in the table has the same.
public struct UsageMeterLayout: Equatable, Sendable {
    public static let spacing = 10.0
    public static let share = 36.0
    public static let timeLeft = 68.0
    public static let resetTime = 104.0
    public static let maximumBar = 200.0
    public var bar: Double
    public var showsTimeLeft: Bool
    public var showsResetTime: Bool

    /// `column` is the column's pitch, the 8-point insets of its cells included.
    public init(column: Double) {
        let room = column - 16 - Self.spacing - Self.share
        if room - 2 * Self.spacing - Self.timeLeft - Self.resetTime >= 60 {
            (bar, showsTimeLeft, showsResetTime) = (min(Self.maximumBar, room - 2 * Self.spacing - Self.timeLeft - Self.resetTime), true, true)
        } else if room - Self.spacing - Self.timeLeft >= 40 {
            (bar, showsTimeLeft, showsResetTime) = (min(Self.maximumBar, room - Self.spacing - Self.timeLeft), true, false)
        } else {
            (bar, showsTimeLeft, showsResetTime) = (max(40, min(Self.maximumBar, room)), false, false)
        }
    }
}

/// A profile's row in Providers: what line 2 under its name says, its windows by model group, what
/// it has besides, and the shares it sorts by.
public struct ProviderRow: Identifiable, Equatable, Sendable {
    /// Line 2 under the name: the family while all is well, else what is wrong.
    public enum Status: Equatable, Sendable {
        /// Read with the page's newest: the family alone.
        case current
        /// Read `behindAfter` or more before the page's newest reading: the family, and when.
        case behind(Date)
        /// Older than the profile's background interval, or a later check failed: since when.
        case stale(Date)
        /// Nothing read, and the check failed.
        case failed(String)
        /// The login shell can't find the profile's command.
        case missingCommand
        /// Nothing read yet, and a check under way.
        case checking

        /// The reading shown is stale, so its bars and shares are dimmed.
        public var isStale: Bool { if case .stale = self { true } else { false } }
    }

    /// How much older than the page's newest a reading is before its row says how old.
    public static let behindAfter: TimeInterval = 600
    public var account: Account
    public var status: Status
    public var groups: [UsageGroup]
    public var badges: [UsageBadge]
    /// What a reading with no windows says instead ("No key spending limit · $1.25 used").
    public var note: String?
    /// The highest share used of the row's short windows, and of its long ones: -1 for none.
    public var shortShare: Double
    public var longShare: Double
    public var id: String { account.id }
    public var name: String { account.name }

    /// `newest` is when the page's newest reading was made; `found`, whether the login shell finds
    /// the command, when that has been checked.
    public init(request: UsageRequest, state: UsageState?, checking: Bool, found: Bool?, newest: Date?, now: Date) {
        account = request.account
        let reading = state?.reading
        if found == false {
            status = .missingCommand
        } else if let reading {
            if state?.isStale(at: now, interval: request.backgroundInterval) == true {
                status = .stale(reading.readAt)
            } else if let newest, newest.timeIntervalSince(reading.readAt) >= Self.behindAfter {
                status = .behind(reading.readAt)
            } else {
                status = .current
            }
        } else if let error = state?.error, !checking {
            status = .failed(error)
        } else {
            status = .checking
        }
        groups = reading?.groups(at: now) ?? []
        badges = reading?.badges(at: now) ?? []
        note = reading?.windows.isEmpty == true ? reading?.note : nil
        shortShare = groups.compactMap { $0.short?.percent }.max() ?? -1
        longShare = groups.compactMap { $0.long?.percent }.max() ?? -1
    }

    /// When the newest of these readings was made.
    public static func newest(_ states: some Sequence<UsageState?>) -> Date? {
        states.compactMap { $0?.reading?.readAt }.max()
    }
}

public struct UsageFailure: LocalizedError, Sendable {
    public let message: String
    public var retryAfter: TimeInterval?
    public var errorDescription: String? { message }
    public init(_ message: String, retryAfter: TimeInterval? = nil) {
        self.message = message
        self.retryAfter = retryAfter
    }
    static let unrecognized = UsageFailure("The provider did not report recognizable account usage.")
}

/// Only usage fields leave these parsers; raw CLI output and account identifiers are never saved.
public enum UsageParser {
    typealias JSON = [String: Any]

    static func object(_ data: Data) throws -> JSON {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw UsageFailure.unrecognized
        }
        return value
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func date(_ value: Any?) -> Date? {
        if let n = number(value), n > 0 { return Date(timeIntervalSince1970: n) }
        guard let s = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func duration(_ minutes: Double?) -> String {
        switch minutes {
        case 10_080: return "Weekly"
        case 1_440: return "Daily"
        case let n? where n > 0 && n < 525_600:
            return n.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(n / 60))-hour" : "\(Int(n))-minute"
        default: return "Allowance"
        }
    }

    /// A window's length from the name `duration` gives it: "Weekly", "Daily", "5-hour", "90-minute".
    static func period(named name: String) -> TimeInterval? {
        switch name {
        case "Weekly": return UsageWindow.week
        case "Daily": return UsageWindow.day
        default:
            for (suffix, unit) in [("-hour", 3_600.0), ("-minute", 60.0)] where name.hasSuffix(suffix) {
                if let count = Double(name.dropLast(suffix.count)), count > 0 { return count * unit }
            }
            return nil
        }
    }

    static func requireWindows(_ windows: [UsageWindow], at now: Date, note: String? = nil) throws -> ProviderUsage {
        guard !windows.isEmpty else { throw UsageFailure.unrecognized }
        return ProviderUsage(windows: windows, note: note, readAt: now)
    }

    /// Codex app-server: account/rateLimits/read. Prefer the complete map over its legacy duplicate.
    public static func codex(_ data: Data, now: Date = .now) throws -> ProviderUsage {
        let frame = try object(data)
        let result = frame["result"] as? JSON ?? frame
        var buckets = result["rateLimitsByLimitId"] as? [String: JSON] ?? [:]
        if buckets.isEmpty, let single = result["rateLimits"] as? JSON {
            buckets[single["limitId"] as? String ?? "codex"] = single
        }
        var windows: [UsageWindow] = []
        for key in buckets.keys.sorted(by: { $0 == "codex" ? $1 != "codex" : $1 != "codex" && $0 < $1 }) {
            guard let bucket = buckets[key] else { continue }
            let name = key == "codex" ? "" : (bucket["limitName"] as? String ?? key)
            for field in ["primary", "secondary"] {
                guard let window = bucket[field] as? JSON else { continue }
                let minutes = number(window["windowDurationMins"])
                let title = duration(minutes)
                windows.append(UsageWindow(id: "\(key):\(field)", title: name.isEmpty ? title : "\(name) · \(title)",
                    usedPercent: number(window["usedPercent"]), resetsAt: date(window["resetsAt"]),
                    group: name.isEmpty ? UsageWindow.allModels : name, period: minutes.flatMap { $0 > 0 ? $0 * 60 : nil }))
            }
        }
        var reading = try requireWindows(windows, at: now)
        // Usage credits and free resets of the limits are the account's, whichever bucket says so.
        if let credits = (result["rateLimits"] as? JSON)?["credits"] as? JSON ?? buckets["codex"]?["credits"] as? JSON,
           let available = credits["hasCredits"] as? Bool {
            let unlimited = credits["unlimited"] as? Bool == true
            reading.credits = UsageCredits(available: available || unlimited, unlimited: unlimited,
                                           balance: (credits["balance"] as? String).flatMap(Double.init) ?? number(credits["balance"]))
        }
        if let resets = result["rateLimitResetCredits"] as? JSON {
            let available = (resets["credits"] as? [JSON] ?? []).filter { $0["status"] as? String == "available" }
            reading.resets = UsageResets(available: number(resets["availableCount"]).map { Int($0) } ?? available.count,
                                         expiries: available.compactMap { date($0["expiresAt"]) })
        }
        return reading
    }

    /// Claude's native /usage command returns prose in a JSON result, with no model tokens used.
    /// Match only its allowance lines, never the unrelated local-session attribution below them.
    public static func claude(_ data: Data, now: Date = .now) throws -> ProviderUsage {
        let body = try object(data)
        guard body["is_error"] as? Bool != true, let result = body["result"] as? String else {
            throw UsageFailure.unrecognized
        }
        let pattern = #"^Current (session|week(?: \(([^)]+)\))?): ([0-9]+(?:\.[0-9]+)?)% used(?: · resets (.+))?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var windows: [UsageWindow] = []
        for line in result.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            let session = group(1) == "session"
            let scope = group(2).flatMap { $0 == "all models" ? nil : $0 }
            let title = session ? "5-hour" : scope.map { "\($0) · Weekly" } ?? "Weekly"
            let reset = group(4)
            windows.append(UsageWindow(id: group(1)!, title: title, usedPercent: group(3).flatMap(Double.init),
                resetsAt: reset.flatMap { claudeReset($0, now: now) }, resetDescription: reset,
                group: scope ?? UsageWindow.allModels, period: session ? UsageWindow.fiveHours : UsageWindow.week))
        }
        return try requireWindows(windows, at: now)
    }

    /// Claude supplies a local time plus an IANA timezone; infer the omitted year/day only.
    static func claudeReset(_ text: String, now: Date) -> Date? {
        guard let zoneStart = text.range(of: " (", options: .backwards), text.hasSuffix(")"),
              let zone = TimeZone(identifier: String(text[zoneStart.upperBound...].dropLast())) else { return nil }
        let value = String(text[..<zoneStart.lowerBound])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.calendar = calendar
        formatter.isLenient = false
        let includesDay = value.contains(" at ")
        for timeFormat in ["ha", "h:mma"] {
            formatter.dateFormat = includesDay ? "yyyy MMM d 'at' \(timeFormat)" : "yyyy-MM-dd \(timeFormat)"
            let components = calendar.dateComponents([.year, .month, .day], from: now)
            let prefix = includesDay ? "\(components.year!)" : String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
            guard var date = formatter.date(from: "\(prefix) \(value)") else { continue }
            let rollover = includesDay ? 180.0 * 86_400 : 12.0 * 3_600
            if now.timeIntervalSince(date) > rollover {
                date = calendar.date(byAdding: includesDay ? .year : .day, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }

    public static func antigravity(_ data: Data, now: Date = .now) throws -> ProviderUsage {
        let command = try object(data)["command"] as? JSON
        let body = command?["data"] as? JSON
        var windows: [UsageWindow] = []
        for group in body?["groups"] as? [JSON] ?? [] {
            let name = group["name"] as? String ?? "Models"
            let prefix = name == "Gemini Models" ? "Gemini" : name == "Claude and GPT models" ? "Claude & GPT" : name
            for bucket in group["buckets"] as? [JSON] ?? [] {
                let window = bucket["window"] as? String ?? "Allowance"
                let period = antigravityPeriod(window)
                let title = period.map { duration($0 / 60) } ?? window
                let remaining = number(bucket["remaining_fraction"])
                let used = remaining.flatMap { (0...1).contains($0) ? (1 - $0) * 100 : nil }
                windows.append(UsageWindow(id: bucket["id"] as? String ?? "\(prefix):\(window)",
                    title: "\(prefix) · \(title)", usedPercent: used, resetsAt: date(bucket["reset_time"]), group: prefix, period: period))
            }
        }
        return try requireWindows(windows, at: now)
    }

    /// Antigravity's window names: "weekly", "daily", "5h", "30m".
    static func antigravityPeriod(_ window: String) -> TimeInterval? {
        switch window {
        case "weekly": return UsageWindow.week
        case "daily": return UsageWindow.day
        default:
            guard let unit = window.last.flatMap({ ["h": 3_600.0, "m": 60.0, "d": UsageWindow.day][String($0)] }),
                  let count = Double(window.dropLast()), count > 0 else { return nil }
            return count * unit
        }
    }

    public static func muse(_ data: Data, now: Date = .now) throws -> ProviderUsage {
        let body = try object(data)
        let usage = body["usage"] as? JSON ?? body
        var windows: [UsageWindow] = []
        for key in ["window", "weekly"] {
            guard let w = usage[key] as? JSON else { continue }
            let used = number(w["usedPercent"] ?? w["used_percent"])
            let rawReset = w["resetsAtMs"] ?? w["resets_at_ms"] ?? w["resets_at"]
            var reset = date(rawReset)
            if let n = number(rawReset) {
                let seconds = n >= 1e17 ? n / 1e9 : n >= 1e14 ? n / 1e6 : n >= 1e11 ? n / 1e3 : n
                reset = date(seconds)
            }
            guard used != nil || reset != nil else { continue }
            let minutes = key == "weekly" ? 10_080 : number(w["windowDurationMins"] ?? w["window_duration_mins"]) ?? 300
            windows.append(UsageWindow(id: key, title: key == "weekly" ? "Weekly" : duration(minutes),
                usedPercent: used, resetsAt: reset, period: minutes * 60))
        }
        // Muse's clock can run a little ahead of this Mac's, and a reading is never from the future.
        let observed = number(usage["observedAtMs"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return try requireWindows(windows, at: min(observed ?? now, now))
    }

    /// OpenRouter's key allowance (not a claim about the account's prepaid credit balance). Its
    /// limits are spending limits, with no window length of their own, so Providers shows them
    /// under Weekly whatever their reset; the key's is all models', a shared budget its scope's.
    public static func openRouter(_ data: Data, now: Date = .now) throws -> ProviderUsage {
        guard let body = try object(data)["data"] as? JSON else { throw UsageFailure.unrecognized }
        var windows: [UsageWindow] = []
        let resetPeriod = body["limit_reset"] as? String
        let limit = number(body["limit"])
        let remaining = number(body["limit_remaining"])
        if let limit, limit >= 0, let remaining {
            windows.append(UsageWindow(id: "key", title: "Key allowance", usedPercent: limit > 0 ? max(0, (limit - remaining) / limit * 100) : nil,
                resetsAt: openRouterReset(resetPeriod, now: now), resetDescription: resetPeriod == nil ? "No scheduled reset" : nil,
                detail: "\(usd(max(0, remaining))) of \(usd(limit)) left"))
        }
        for (index, budget) in (body["budgets"] as? [JSON] ?? []).enumerated() {
            guard let limit = number(budget["limit_usd"]), limit >= 0, let remaining = number(budget["remaining_usd"]) else { continue }
            let scope = budget["scope"] as? String ?? "Shared"
            // The key's own limit comes again as a budget of its own.
            if scope == "key_limit", windows.contains(where: { $0.id == "key" }) { continue }
            let title = scope == "key_limit" ? "Key" : scope.replacingOccurrences(of: "_", with: " ").capitalized
            windows.append(UsageWindow(id: "budget:\(index)", title: "\(title) allowance",
                usedPercent: limit > 0 ? max(0, (limit - remaining) / limit * 100) : nil,
                resetsAt: date(budget["resets_at"]), detail: "\(usd(max(0, remaining))) of \(usd(limit)) left",
                group: title == "Key" ? UsageWindow.allModels : title))
        }
        if windows.isEmpty {
            guard let usage = number(body["usage"]), usage >= 0, body["limit"] is NSNull else { throw UsageFailure.unrecognized }
            return ProviderUsage(windows: [], note: "No key spending limit · \(usd(usage)) used", readAt: now)
        }
        return ProviderUsage(windows: windows, readAt: now)
    }

    static func usd(_ amount: Double) -> String { amount.formatted(.currency(code: "USD")) }

    static func openRouterReset(_ period: String?, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let component: Calendar.Component
        switch period {
        case "daily": component = .day
        case "weekly": component = .weekOfYear
        case "monthly": component = .month
        default: return nil
        }
        return calendar.dateInterval(of: component, for: now)?.end
    }
}
