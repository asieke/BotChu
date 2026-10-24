import Foundation

/// Account allowance, independent of a bot's token counts or conversation.
public struct ProviderUsage: Equatable, Sendable {
    public var windows: [UsageWindow]
    public var note: String?
    public var readAt: Date

    public init(windows: [UsageWindow], note: String? = nil, readAt: Date = .now) {
        self.windows = windows
        self.note = note
        self.readAt = readAt
    }
}

public struct UsageWindow: Identifiable, Equatable, Sendable {
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
        return try requireWindows(windows, at: now)
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
            windows.append(UsageWindow(id: "budget:\(index)", title: "\(scope.capitalized) allowance",
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
