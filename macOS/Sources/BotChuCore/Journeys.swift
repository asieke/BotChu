import Foundation

/// The frame marks a BotChu run with `BOTCHU_TIMINGS=<file>` appends to that file, and that the
/// journeys harness (`botchu-journeys`, #323) reads: one line per mark, `<uptime ns> <name>`, the
/// time on the clock both processes share (`DispatchTime`, mach absolute time) at which the frame
/// showing what the mark names was committed. Without the variable the app writes nothing.
public enum FrameMarks {
    public static let environmentKey = "BOTCHU_TIMINGS"

    public struct Mark: Equatable, Sendable {
        public var name: String
        public var nanoseconds: UInt64

        public init(name: String, nanoseconds: UInt64) {
            self.name = name
            self.nanoseconds = nanoseconds
        }
    }

    /// The window's content first showed.
    public static let window = "window"
    /// A row of the sidebar's bots showed.
    public static let sidebarRow = "sidebar.row"

    /// The sidebar started to show or hide.
    public static func sidebar(shown: Bool) -> String { shown ? "sidebar.shown" : "sidebar.hidden" }

    /// The status sidebar (the inspector) started to show or hide.
    public static func inspector(shown: Bool) -> String { shown ? "inspector.shown" : "inspector.hidden" }

    /// A row of this bot's shown conversation showed; for a task's conversation, also under the task's id.
    public static func chat(_ id: UUID) -> String { "chat \(id.uuidString)" }

    /// A task's tab showed beside the chat.
    public static func tab(_ taskID: UUID) -> String { "tab \(taskID.uuidString)" }

    /// A message box's text changed (typed, set or cleared).
    public static let composer = "composer"

    /// The window's content was laid out at a new size.
    public static let windowResized = "window.resized"

    /// The chat's visible part moved.
    public static let chatScrolled = "chat.scrolled"

    /// Attach Project Area started to show: the first frame of its opening animation.
    public static let attachArea = "attach-area"

    /// A page of the window (`inbox`, `settings`) showed.
    public static func page(_ name: String) -> String { "page \(name)" }

    /// The delivery being read shows it is Done, or not: its Done button says so, or Done (while
    /// Done is closed) takes it out of the list.
    public static func inboxDone(_ id: UUID, _ done: Bool) -> String { "inbox.done \(id.uuidString) \(done)" }

    /// A frame of the working ring round the bot's face in the status sidebar.
    public static let avatarFrame = "avatar.frame"

    /// The streaming reply of this bot's shown conversation showed this much text (UTF-16 units).
    public static func streamed(_ botID: UUID, length: Int) -> String { "streamed \(botID.uuidString) \(length)" }

    /// The length a `streamed` mark of this bot names.
    public static func streamedLength(_ name: String, of botID: UUID) -> Int? {
        let prefix = "streamed \(botID.uuidString) "
        return name.hasPrefix(prefix) ? Int(name.dropFirst(prefix.count)) : nil
    }

    /// The main thread was busy this long without letting a frame be committed: from waking until
    /// it waited again, Core Animation's commit included. Written as it ends, for stretches of
    /// `busyThreshold` or more.
    public static func busy(milliseconds: Double) -> String { String(format: "busy %.2f", milliseconds) }
    public static let busyThreshold = 4.0

    public static func busyMilliseconds(_ name: String) -> Double? {
        name.hasPrefix("busy ") ? Double(name.dropFirst(5)) : nil
    }

    /// Marks that keep coming while something animates or the main thread works, which waiting
    /// for the app to settle leaves out.
    public static func isContinuous(_ name: String) -> Bool { name == avatarFrame || name.hasPrefix("busy ") }

    public static func line(_ name: String, at nanoseconds: UInt64) -> String { "\(nanoseconds) \(name)\n" }

    /// The marks in `text`; a line that isn't a mark is left out (the harness reads only whole lines).
    public static func parse(_ text: String) -> [Mark] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let space = line.firstIndex(of: " "), let time = UInt64(line[..<space]) else { return nil }
            let name = line[line.index(after: space)...]
            return name.isEmpty ? nil : Mark(name: String(name), nanoseconds: time)
        }
    }
}

/// How fast a journey's step must be (#323): its median over the repeats must be within the budget.
public struct JourneyBudget: Equatable, Sendable {
    public var milliseconds: Double
    public var tier: String

    public init(milliseconds: Double, tier: String) {
        self.milliseconds = milliseconds
        self.tier = tier
    }

    /// Two frames at 120 Hz.
    public static let instant = JourneyBudget(milliseconds: 16, tier: "Instant")
    public static let quick = JourneyBudget(milliseconds: 100, tier: "Quick")
    /// No frame over 33 ms while something goes on (two frames at 60 Hz).
    public static let smooth = JourneyBudget(milliseconds: 33, tier: "Smooth")
    public static let launch = JourneyBudget(milliseconds: 1_500, tier: "Launch")
    public static func within(_ milliseconds: Double) -> JourneyBudget { JourneyBudget(milliseconds: milliseconds, tier: "≤ \(Int(milliseconds)) ms") }
}

/// One measured step of a journey: its samples in milliseconds and how they compare with the budget
/// and the recorded baseline (#323): it fails when its median is over budget, or more than 25 % and
/// more than 3 ms slower than the baseline. While the baseline itself misses the budget, the budget
/// is the baseline + 10 % (the ratchet), until a fix and a new baseline bring it back.
public struct JourneyResult: Equatable, Sendable {
    public var journey: Int
    public var step: String
    public var budget: JourneyBudget
    public var baseline: Double?
    public var samples: [Double]
    /// Why the step couldn't be measured or didn't show what it should: it fails whatever its times.
    public var problem: String?
    /// The 1-minute load average when the step was measured.
    public var load: Double?
    /// How its first attempt failed, when it was measured again.
    public var retried: String?

    public init(journey: Int, step: String, budget: JourneyBudget, baseline: Double? = nil, samples: [Double], problem: String? = nil,
                load: Double? = nil, retried: String? = nil) {
        self.journey = journey
        self.step = step
        self.budget = budget
        self.baseline = baseline
        self.samples = samples
        self.problem = problem
        self.load = load
        self.retried = retried
    }

    public static let slowerShare = 0.25
    public static let slowerMilliseconds = 3.0
    public static let ratchetShare = 0.10

    /// The key a baseline keeps this step's median under.
    public var key: String { "\(journey) \(step)" }
    public var median: Double? { JourneyStats.median(samples) }
    public var p95: Double? { JourneyStats.percentile(95, of: samples) }

    /// Whether the baseline misses the budget, so the budget is the baseline + 10 % for now.
    public var ratcheted: Bool { (baseline ?? 0) > budget.milliseconds }

    /// What the median is held to: the budget, or the ratchet's.
    public var limit: Double {
        guard ratcheted, let baseline else { return budget.milliseconds }
        return (baseline * (1 + Self.ratchetShare) * 10).rounded() / 10
    }

    /// Why it failed, or nil when it passed.
    public var failure: String? {
        if let problem { return problem }
        guard let median else { return "no samples" }
        if median > limit { return String(format: "median %.1f ms over its budget of %.1f ms", median, limit) }
        if let baseline, median > baseline * (1 + Self.slowerShare), median - baseline > Self.slowerMilliseconds {
            return String(format: "median %.1f ms is %.0f %% (%.1f ms) slower than the baseline %.1f ms",
                          median, (median / baseline - 1) * 100, median - baseline, baseline)
        }
        return nil
    }

    public var passed: Bool { failure == nil }

    /// `2 sidebar · close: budget Instant 16.0 ms, baseline 9.1 ms, median 8.7 ms, p95 12.0 ms, 6 samples, load 4.2 — ok`,
    /// or why it failed, with the ratchet and a retry when there was one.
    public var report: String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "—" }
        var line = "\(journey) \(step): budget \(budget.tier) \(ms(budget.milliseconds))"
        if ratcheted { line += " (ratcheted to \(ms(limit)): the baseline is over budget)" }
        line += ", baseline \(ms(baseline)), median \(ms(median)), p95 \(ms(p95)), \(samples.count) samples"
        if let load { line += String(format: ", load %.1f", load) }
        if let retried { line += "; measured again after: \(retried)" }
        line += failure.map { " — FAILED: \($0)" } ?? " — ok"
        return line
    }
}

public enum JourneyStats {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The nearest-rank percentile: the smallest sample that at least `percent` of them don't exceed.
    public static func percentile(_ percent: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((percent / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// The medians a run recorded, with what the Mac was doing then, kept in `macOS/Journeys/baseline.json`
/// and changed only by a pull request that says why.
public struct JourneyBaseline: Codable, Equatable, Sendable {
    public var recordedAt: Date
    public var commit: String
    public var machine: String
    /// The 1-, 5- and 15-minute load averages when the run started and ended.
    public var loadBefore: [Double]
    public var loadAfter: [Double]
    /// Each step's median in milliseconds, by `JourneyResult.key`.
    public var medians: [String: Double]

    public init(recordedAt: Date, commit: String, machine: String, loadBefore: [Double], loadAfter: [Double], medians: [String: Double]) {
        self.recordedAt = recordedAt
        self.commit = commit
        self.machine = machine
        self.loadBefore = loadBefore
        self.loadAfter = loadAfter
        self.medians = medians
    }

    public init(recordedAt: Date, commit: String, machine: String, loadBefore: [Double], loadAfter: [Double], results: [JourneyResult]) {
        self.init(recordedAt: recordedAt, commit: commit, machine: machine, loadBefore: loadBefore, loadAfter: loadAfter,
                  medians: Dictionary(results.compactMap { result in result.median.map { (result.key, ($0 * 10).rounded() / 10) } },
                                      uniquingKeysWith: { $1 }))
    }

    public static func decode(_ data: Data) throws -> JourneyBaseline {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JourneyBaseline.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

/// What a run measured (`botchu-journeys --results`, #362), kept outside the repository for
/// `scripts/journeys-report.py`: the baseline's shape, so it reads back as one, plus how each step
/// went and what the report's header names. Written when steps fail too.
public struct JourneyRun: Codable, Equatable, Sendable {
    public var recordedAt: Date
    public var commit: String
    public var branch: String
    public var machine: String
    /// The refresh rate of the display the window was on, when the harness could tell.
    public var hertz: Int?
    public var loadBefore: [Double]
    public var loadAfter: [Double]
    /// How long the run took.
    public var seconds: Int
    public var medians: [String: Double]
    public var steps: [Step]

    public struct Step: Codable, Equatable, Sendable {
        public var journey: Int
        public var step: String
        public var key: String
        public var budget: Double
        public var tier: String
        public var baseline: Double?
        /// What the median was held to: the budget, or the ratchet's.
        public var limit: Double
        public var ratcheted: Bool
        public var median: Double?
        public var p95: Double?
        public var samples: [Double]
        public var passed: Bool
        public var failure: String?
        public var load: Double?
        public var retried: String?

        public init(_ result: JourneyResult) {
            journey = result.journey
            step = result.step
            key = result.key
            budget = result.budget.milliseconds
            tier = result.budget.tier
            baseline = result.baseline
            limit = result.limit
            ratcheted = result.ratcheted
            median = result.median
            p95 = result.p95
            samples = result.samples
            passed = result.passed
            failure = result.failure
            load = result.load
            retried = result.retried
        }
    }

    public init(recordedAt: Date, commit: String, branch: String, machine: String, hertz: Int?, loadBefore: [Double], loadAfter: [Double],
                seconds: Int, results: [JourneyResult]) {
        let baseline = JourneyBaseline(recordedAt: recordedAt, commit: commit, machine: machine, loadBefore: loadBefore, loadAfter: loadAfter,
                                       results: results)
        self.recordedAt = recordedAt
        self.commit = commit
        self.branch = branch
        self.machine = machine
        self.hertz = hertz
        self.loadBefore = loadBefore
        self.loadAfter = loadAfter
        self.seconds = seconds
        self.medians = baseline.medians
        self.steps = results.map(Step.init)
    }

    public static func decode(_ data: Data) throws -> JourneyRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JourneyRun.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }
}

/// The journeys a run asks for: names or numbers, separated by commas (`--journeys sidebar,3`).
public struct JourneySelection: Equatable, Sendable {
    public var numbers: [Int]

    public init(numbers: [Int]) { self.numbers = numbers }

    /// `catalog` is each journey's number and names; an empty `spec` selects every one.
    public static func parse(_ spec: String, catalog: [(number: Int, names: [String])]) throws -> JourneySelection {
        let words = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if words.isEmpty || words == ["all"] { return JourneySelection(numbers: catalog.map(\.number)) }
        var numbers: [Int] = []
        for word in words {
            guard let entry = catalog.first(where: { String($0.number) == word || $0.names.contains(word) }) else {
                let known = catalog.map { "\($0.number) (\($0.names.joined(separator: ", ")))" }.joined(separator: "; ")
                throw Unknown(description: "No journey \"\(word)\". Journeys: \(known).")
            }
            if !numbers.contains(entry.number) { numbers.append(entry.number) }
        }
        return JourneySelection(numbers: numbers.sorted())
    }

    public struct Unknown: Error, CustomStringConvertible, Equatable {
        public var description: String
    }
}
