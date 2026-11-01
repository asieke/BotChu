import Foundation

/// A turn or sub-agent run that failed because its account hit a usage limit (#442): when the
/// limit resets, read from the CLI's failure text, so BotChu pauses the work until then rather
/// than failing it. Claude Code says `You've hit your 5-hour limit · resets 12:10am
/// (America/New_York)` (or `session limit`, `weekly limit`, with a date when it isn't today), and
/// before that `Claude AI usage limit reached|<epoch seconds>`. Other CLIs' texts join once a real
/// sample of each is captured.
public enum UsageLimit {
    /// How far back a reset time of day still counts as today's: a CLI that says "resets 12:10am"
    /// at 12:12am means the one that just passed, not tomorrow's.
    public static let grace: TimeInterval = 10 * 60

    /// When the account's limit resets, for `text` that says it hit one and names when; nil for
    /// any other failure. A time without a zone is in `timeZone`.
    public static func resetDate(in text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = epoch.firstMatch(in: text, range: range), let seconds = TimeInterval(group(1, of: match, in: text) ?? "") {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let match = resets.firstMatch(in: text, range: range),
              let hourText = group(3, of: match, in: text), var hour = Int(hourText), (1...12).contains(hour),
              let meridiem = group(5, of: match, in: text)?.lowercased() else { return nil }
        let minute = group(4, of: match, in: text).flatMap(Int.init) ?? 0
        guard (0..<60).contains(minute) else { return nil }
        hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group(6, of: match, in: text).flatMap(TimeZone.init(identifier:)) ?? timeZone
        let earliest = now.addingTimeInterval(-grace)
        if let monthText = group(1, of: match, in: text), let day = group(2, of: match, in: text).flatMap(Int.init) {
            guard let month = months.firstIndex(where: { monthText.lowercased().hasPrefix($0) }).map({ $0 + 1 }) else { return nil }
            let year = calendar.component(.year, from: now)
            for candidate in [year, year + 1] {
                guard let date = calendar.date(from: DateComponents(year: candidate, month: month, day: day, hour: hour, minute: minute)) else { return nil }
                if date >= earliest { return date }
            }
            return nil
        }
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
        if today >= earliest { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// The time as the conversation and run cards say it: `12:10am` or `2pm` within the next (or
    /// last) 20 hours, as the CLIs do, `Tue 9am` within the week, `Nov 8, 9am` further off.
    public static func timeText(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "ha" : "h:mma"
        let time = formatter.string(from: date)
        if abs(date.timeIntervalSince(now)) < 20 * 3600 { return time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        formatter.dateFormat = (0..<7).contains(days) ? "EEE" : "MMM d,"
        return formatter.string(from: date) + " " + time
    }

    /// What a paused conversation or run says: "Paused until 12:10am".
    public static func pausedText(until date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        "Paused until " + timeText(date, now: now, timeZone: timeZone)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let epoch = try! NSRegularExpression(pattern: #"usage limit reached\|(\d{9,11})\b"#, options: [.caseInsensitive])
    /// "limit … resets [Nov 3, [at]] 12:10am [(Zone/Name)]", also "limit will reset at 3pm".
    private static let resets = try! NSRegularExpression(
        pattern: #"\blimit\b[^\n]{0,80}?\bresets?\s+(?:at\s+)?(?:([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b(?:\s*\(([A-Za-z_]+(?:/[A-Za-z0-9_+-]+)*)\))?"#,
        options: [.caseInsensitive])

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}

/// The conversations whose turn paused on a usage limit (#442), each with when BotChu sends it the
/// heartbeat that carries it on, kept in BotChu's folder so a pause outlives a relaunch. Runs that
/// paused keep their reset in their own records (`SubagentInterruption.resetsAt`).
public struct LimitPauseBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var botID: UUID
        public var taskID: UUID?
        /// When the limit resets, which the conversation shows.
        public var resetsAt: Date
        /// When its heartbeat goes out (`Heartbeat.resumeDate`).
        public var resumeAt: Date

        public init(botID: UUID, taskID: UUID?, resetsAt: Date, resumeAt: Date) {
            self.botID = botID
            self.taskID = taskID
            self.resetsAt = resetsAt
            self.resumeAt = resumeAt
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public func entry(botID: UUID, taskID: UUID?) -> Entry? {
        entries.first { $0.botID == botID && $0.taskID == taskID }
    }

    /// Pauses the conversation, replacing a pause it had.
    public mutating func pause(_ entry: Entry) {
        clear(botID: entry.botID, taskID: entry.taskID)
        entries.append(entry)
    }

    @discardableResult
    public mutating func clear(botID: UUID, taskID: UUID?) -> Bool {
        let count = entries.count
        entries.removeAll { $0.botID == botID && $0.taskID == taskID }
        return entries.count != count
    }

    /// Takes out the pauses due by `now`.
    public mutating func takeDue(at now: Date) -> [Entry] {
        let due = entries.filter { $0.resumeAt <= now }
        entries.removeAll { $0.resumeAt <= now }
        return due
    }

    /// Keeps only the conversations `exists` still knows.
    public mutating func prune(_ exists: (UUID, UUID?) -> Bool) {
        entries.removeAll { !exists($0.botID, $0.taskID) }
    }

    public var nextResume: Date? { entries.map(\.resumeAt).min() }

    /// The book saved at `url`, empty when there is none or it can't be read.
    public static func load(_ url: URL) -> LimitPauseBook {
        guard let data = try? Data(contentsOf: url) else { return LimitPauseBook() }
        return (try? decoder.decode(LimitPauseBook.self, from: data)) ?? LimitPauseBook()
    }

    public func save(_ url: URL) throws {
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Store.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// What carries on when usage limits reset (#442): the paused turns and runs due by a time, each
/// conversation's together, so it hears one heartbeat naming the runs BotChu resumed.
public enum LimitResume {
    public struct Due: Equatable, Sendable {
        public var botID: UUID
        public var taskID: UUID?
        /// The conversation's own turn had paused.
        public var turnPaused: Bool
        /// The runs to resume, in the order they were delegated.
        public var runs: [UUID]
    }

    /// When a paused run is resumed: a minute after its limit resets.
    public static func resumeDate(of run: SubagentRun) -> Date? {
        run.pausedUntil.map { $0.addingTimeInterval(Heartbeat.afterReset) }
    }

    /// The paused runs BotChu resumes itself: those not tried already (`tried`), and not beneath a
    /// paused run, which resumes them as its own children (`SubagentResume.delta` lists them).
    public static func candidates(_ runs: [SubagentRun], tried: Set<UUID>) -> [SubagentRun] {
        let paused = Set(runs.filter { $0.pausedUntil != nil }.map(\.id))
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func underPaused(_ run: SubagentRun) -> Bool {
            var parent = run.parentSubagentID, steps = 0
            while let id = parent, steps <= SubagentLimits.maxDepth + 1 {
                if paused.contains(id) { return true }
                parent = byID[id]?.parentSubagentID
                steps += 1
            }
            return false
        }
        return runs.filter { paused.contains($0.id) && !tried.contains($0.id) && !underPaused($0) }
    }

    /// Takes the turns due by `now` out of `book`, with the runs due then, grouped by conversation.
    public static func due(book: inout LimitPauseBook, runs: [SubagentRun], tried: Set<UUID>, now: Date) -> [Due] {
        var found: [Due] = book.takeDue(at: now).map { Due(botID: $0.botID, taskID: $0.taskID, turnPaused: true, runs: []) }
        for run in candidates(runs, tried: tried) where resumeDate(of: run).map({ $0 <= now }) == true {
            if let i = found.firstIndex(where: { $0.botID == run.rootBotID && $0.taskID == run.rootTaskID }) {
                found[i].runs.append(run.id)
            } else {
                found.append(Due(botID: run.rootBotID, taskID: run.rootTaskID, turnPaused: false, runs: [run.id]))
            }
        }
        return found
    }

    /// When the next paused turn or run is due, nil with none.
    public static func nextWake(book: LimitPauseBook, runs: [SubagentRun], tried: Set<UUID>) -> Date? {
        ([book.nextResume] + candidates(runs, tried: tried).map(resumeDate)).compactMap { $0 }.min()
    }
}
