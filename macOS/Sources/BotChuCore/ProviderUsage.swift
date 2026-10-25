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
    public var id: String
    public var title: String
    public var usedPercent: Double?
    public var resetsAt: Date?
    public var resetDescription: String?
    public var detail: String?

    public init(id: String, title: String, usedPercent: Double?, resetsAt: Date? = nil,
                resetDescription: String? = nil, detail: String? = nil) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.detail = detail
    }

    public func hasReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }

    /// A reading from an ended window is not the new window's usage.
    public func currentPercent(at now: Date) -> Double? { hasReset(at: now) ? nil : usedPercent }
}

/// An allowance window as a line of a compact list, such as a Providers row: its title, the share
/// used and its reset, as text.
public struct UsageLine: Identifiable, Equatable, Sendable {
    /// The parts of a line that line up with the other rows' lines: a reset is a weekday and a
    /// time, or text.
    public enum Part: Sendable { case title, percent, day, time, reset }
    public var id: String
    public var title: String
    public var percent: Double?
    public var percentText: String
    /// The reset in words: its weekday and time, or what stands for them.
    public var reset: String
    /// A reset at a known time as its weekday and its time apart, so that times line up down the
    /// table; nil when `reset` says something else ("Reset passed").
    public var resetDay: String?
    public var resetTime: String?

    public init(_ window: UsageWindow, at now: Date) {
        id = window.id
        title = window.title
        percent = window.currentPercent(at: now)
        percentText = percent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "—"
        if window.hasReset(at: now) {
            reset = "Reset passed"
        } else if let date = window.resetsAt {
            reset = date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            resetDay = date.formatted(.dateTime.weekday(.abbreviated))
            resetTime = date.formatted(.dateTime.hour().minute())
        } else {
            reset = window.resetDescription ?? "—"
        }
    }
}

extension ProviderUsage {
    /// A compact row's lines: every window up to `limit`, else one fewer, leaving a line to say how
    /// many more there are.
    public func lines(at now: Date, limit: Int = 4) -> (shown: [UsageLine], more: Int) {
        let shown = windows.count > limit ? Array(windows.prefix(limit - 1)) : windows
        return (shown.map { UsageLine($0, at: now) }, windows.count - shown.count)
    }

    /// A Providers row's lines: up to four, one fewer when its chips (`badges`) take a line.
    public func rowLines(at now: Date) -> (shown: [UsageLine], more: Int) {
        lines(at: now, limit: badges(at: now).isEmpty ? 4 : 3)
    }

    /// What the account has besides its windows' share, as chips: the money left in a window
    /// that is a spending limit (an OpenRouter key's), its usage credits and its free resets.
    public func badges(at now: Date) -> [UsageBadge] {
        let spending = windows.filter { $0.detail != nil && !$0.hasReset(at: now) }
        var badges = spending.map { window in
            let detail = window.detail ?? ""
            let scope = window.title.replacingOccurrences(of: " allowance", with: "")
            return UsageBadge(id: "spend:\(window.id)", kind: .spend, text: spending.count > 1 ? "\(scope) \(detail)" : detail,
                              available: (window.currentPercent(at: now) ?? 0) < 100, help: "\(window.title): \(detail)")
        }
        if let credits {
            let balance = credits.balance.map { $0.rounded(.down).formatted(.number.precision(.fractionLength(0))) }
            let text = credits.unlimited ? "Unlimited credits" : !credits.available ? "No credits" : balance.map { "\($0) credits" } ?? "Credits available"
            badges.append(UsageBadge(id: "credits", kind: .credits, text: text, available: credits.available || credits.unlimited,
                                     help: credits.available || credits.unlimited ? "Usage credits: \(text.lowercased())" : "No usage credits on this account"))
        }
        if let resets {
            let count = resets.available
            let text = count == 0 ? "No free resets" : count == 1 ? "1 free reset" : "\(count) free resets"
            let expiry = resets.expiries.first.map { " The \(count == 1 ? "reset expires" : "first expires") \($0.formatted(date: .abbreviated, time: .shortened))." } ?? ""
            badges.append(UsageBadge(id: "resets", kind: .resets, text: text, available: count > 0,
                                     help: count == 0 ? "No free resets of the usage limits" : "\(text) of the usage limits.\(expiry)"))
        }
        return badges
    }

    /// The reading in full, a line each, for a tooltip: each window's use and reset, then the
    /// credits, resets and note.
    public func details(at now: Date) -> String {
        let lines = windows.map { window in
            let percent = window.currentPercent(at: now).map { "\($0.formatted(.number.precision(.fractionLength(0))))% used" } ?? "not reported"
            let reset = window.hasReset(at: now) ? "reset passed, awaiting an update"
                : window.resetsAt.map { "resets \($0.formatted(date: .complete, time: .shortened))" } ?? window.resetDescription ?? "reset time not reported"
            return ["\(window.title): \(percent), \(reset)", window.hasReset(at: now) ? nil : window.detail].compactMap { $0 }.joined(separator: " · ")
        }
        let extras = badges(at: now).filter { $0.kind != .spend }.map(\.help)
        return (lines + extras + [note].compactMap { $0 }).joined(separator: "\n")
    }
}

/// Something an account has besides its windows' share, as a chip in its row: money left under a
/// spending limit, usage credits, or free resets of its limits.
public struct UsageBadge: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case spend, credits, resets }
    public var id: String
    public var kind: Kind
    public var text: String
    /// There is some to use: money, credits or resets left.
    public var available: Bool
    public var help: String
}

/// How wide each part of a usage line is: the widest across every row, so that each row's bars,
/// percentages and resets start at the same place, whatever its windows are called.
public struct UsageLineWidths: Equatable, Sendable {
    /// A longer title is cut short, so one long name doesn't push every row's bar across.
    public static let maxTitle = 160.0
    /// Between a reset's weekday and its time.
    public static let dayGap = 4.0
    public var title: Double
    public var percent: Double
    public var day: Double
    public var time: Double
    /// The widest reset given in words.
    public var resetText: Double

    public init(title: Double = 0, percent: Double = 0, day: Double = 0, time: Double = 0, resetText: Double = 0) {
        self.title = title
        self.percent = percent
        self.day = day
        self.time = time
        self.resetText = resetText
    }

    /// `measure` gives a text's width in the font its part is shown in.
    public init(_ lines: some Sequence<UsageLine>, measure: (String, UsageLine.Part) -> Double) {
        self.init()
        for line in lines {
            title = max(title, measure(line.title, .title).rounded(.up))
            percent = max(percent, measure(line.percentText, .percent).rounded(.up))
            if let day = line.resetDay, let time = line.resetTime {
                self.day = max(self.day, measure(day, .day).rounded(.up))
                self.time = max(self.time, measure(time, .time).rounded(.up))
            } else {
                resetText = max(resetText, measure(line.reset, .reset).rounded(.up))
            }
        }
        title = min(title, Self.maxTitle)
    }

    /// The reset's width: a weekday and a time, or words, whichever is wider.
    public var reset: Double { max(day + time > 0 ? day + Self.dayGap + time : 0, resetText) }
}

/// Where each part of a usage line goes across a width: the title, the share used, the bar in
/// what is left, and the reset at the end. Every line in the table is laid out from the same
/// widths, so their parts line up down it and the bars take the width the column has. Too narrow
/// for the reset beside a bar of `minimumBar`, a line leaves the reset out (it is in the tooltip);
/// narrower still, it cuts the title short.
public struct UsageLineLayout: Equatable, Sendable {
    public struct Slot: Equatable, Sendable {
        public var x: Double
        public var width: Double
        public init(x: Double, width: Double) {
            self.x = x
            self.width = width
        }
    }

    public static let spacing = 10.0
    public static let minimumBar = 48.0
    /// The bar a line asks for when it is given no width.
    public static let idealBar = 160.0
    public var title: Slot
    public var percent: Slot
    public var bar: Slot
    public var reset: Slot?

    public init(width: Double, widths: UsageLineWidths) {
        let spacing = Self.spacing
        let reset = widths.reset
        let titleWidth: Double
        if reset > 0, width >= widths.title + widths.percent + Self.minimumBar + reset + 3 * spacing {
            titleWidth = widths.title
            self.reset = Slot(x: width - reset, width: reset)
        } else {
            titleWidth = max(0, min(widths.title, width - widths.percent - Self.minimumBar - 2 * spacing))
            self.reset = nil
        }
        title = Slot(x: 0, width: titleWidth)
        percent = Slot(x: titleWidth + spacing, width: widths.percent)
        let barStart = percent.x + percent.width + spacing
        bar = Slot(x: barStart, width: max(0, (self.reset.map { $0.x - spacing } ?? width) - barStart))
    }

    /// A line's width when nothing proposes one: its parts with an `idealBar`.
    public static func idealWidth(_ widths: UsageLineWidths) -> Double {
        widths.title + widths.percent + idealBar + 2 * spacing + (widths.reset > 0 ? spacing + widths.reset : 0)
    }
}

/// How the Providers table shares out its width: the profile, its command and when it was read
/// take fixed widths for the table's size, and the allowance column the rest, so its bars grow
/// with the window. Only the allowance column changes width as the window does; a table that
/// crosses into another size is made anew for it, never left as an earlier window size had it.
public struct ProvidersColumns: Equatable, Sendable {
    public enum Size: Sendable { case compact, regular, wide }
    /// What the inset table adds to its columns: the space between them and at its edges.
    public static let chrome = 84.0
    public static let minimumAllowance = 200.0
    /// The narrowest table, in the narrowest window: its columns and the shortest allowance.
    public static let minimumWidth = 580.0
    public var size: Size
    public var provider: Double
    public var command: Double
    public var updated: Double

    public init(width: Double) {
        switch width {
        case ..<760: (size, provider, command, updated) = (.compact, 150, 58, 88)
        case ..<1_200: (size, provider, command, updated) = (.regular, 190, 150, 96)
        default: (size, provider, command, updated) = (.wide, 240, 240, 110)
        }
    }

    /// The allowance column's width in a table this wide: all the rest.
    public func allowance(in width: Double) -> Double {
        max(Self.minimumAllowance, width - Self.chrome - provider - command - updated)
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
                let title = duration(number(window["windowDurationMins"]))
                windows.append(UsageWindow(id: "\(key):\(field)", title: name.isEmpty ? title : "\(name) · \(title)",
                    usedPercent: number(window["usedPercent"]), resetsAt: date(window["resetsAt"])))
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
            let scope = group(2)
            let title = session ? "5-hour" : (scope == nil || scope == "all models" ? "Weekly" : "\(scope!) · Weekly")
            let reset = group(4)
            windows.append(UsageWindow(id: group(1)!, title: title, usedPercent: group(3).flatMap(Double.init),
                resetsAt: reset.flatMap { claudeReset($0, now: now) }, resetDescription: reset))
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
                let title = window == "weekly" ? "Weekly" : window == "5h" ? "5-hour" : window
                let remaining = number(bucket["remaining_fraction"])
                let used = remaining.flatMap { (0...1).contains($0) ? (1 - $0) * 100 : nil }
                windows.append(UsageWindow(id: bucket["id"] as? String ?? "\(prefix):\(window)",
                    title: "\(prefix) · \(title)", usedPercent: used, resetsAt: date(bucket["reset_time"])))
            }
        }
        return try requireWindows(windows, at: now)
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
            windows.append(UsageWindow(id: key, title: key == "weekly" ? "Weekly" : duration(number(w["windowDurationMins"] ?? w["window_duration_mins"]) ?? 300),
                usedPercent: used, resetsAt: reset))
        }
        // Muse's clock can run a little ahead of this Mac's, and a reading is never from the future.
        let observed = number(usage["observedAtMs"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        return try requireWindows(windows, at: min(observed ?? now, now))
    }

    /// OpenRouter's key allowance (not a claim about the account's prepaid credit balance).
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
                resetsAt: date(budget["resets_at"]), detail: "\(usd(max(0, remaining))) of \(usd(limit)) left"))
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
