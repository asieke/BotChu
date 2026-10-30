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

    /// A row of this bot's shown conversation showed.
    public static func chat(_ botID: UUID) -> String { "chat \(botID.uuidString)" }

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
    public static let launch = JourneyBudget(milliseconds: 1_500, tier: "Launch")
    public static func within(_ milliseconds: Double) -> JourneyBudget { JourneyBudget(milliseconds: milliseconds, tier: "≤ \(Int(milliseconds)) ms") }
}

/// One measured step of a journey: its samples in milliseconds and how they compare with the budget
/// and the recorded baseline.
public struct JourneyResult: Equatable, Sendable {
    public var journey: Int
    public var step: String
    public var budget: JourneyBudget
    public var baseline: Double?
    public var samples: [Double]
    /// Why the step couldn't be measured or didn't show what it should: it fails whatever its times.
    public var problem: String?

    public init(journey: Int, step: String, budget: JourneyBudget, baseline: Double? = nil, samples: [Double], problem: String? = nil) {
        self.journey = journey
        self.step = step
        self.budget = budget
        self.baseline = baseline
        self.samples = samples
        self.problem = problem
    }

    /// The key a baseline keeps this step's median under.
    public var key: String { "\(journey) \(step)" }
    public var median: Double? { JourneyStats.median(samples) }
    public var p95: Double? { JourneyStats.percentile(95, of: samples) }
    public var passed: Bool { problem == nil && (median.map { $0 <= budget.milliseconds } ?? false) }

    /// `2 sidebar · close  Instant 16 ms  baseline 9.1 ms  median 8.7 ms  p95 12.0 ms  ok`, or why it failed.
    public var report: String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "—" }
        var line = "\(journey) \(step): budget \(budget.tier) \(ms(budget.milliseconds)), baseline \(ms(baseline)), "
            + "median \(ms(median)), p95 \(ms(p95)), \(samples.count) samples"
        if let problem { line += " — FAILED: \(problem)" }
        else if passed { line += " — ok" }
        else { line += " — FAILED: median over budget" }
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
