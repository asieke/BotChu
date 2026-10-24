import Darwin
import Foundation
import Testing
@testable import BotChuCore

/// Markdown for long replies being written (#106): converting the next revision of prose, code,
/// shell code with `$HOME`, equation-heavy and table-and-diagram replies; a 128 KB reply given 100
/// rapid deltas, with the worker's counts; and the memory ten 128 KB replies keep. Not part of
/// `scripts/check.sh`, and it asserts nothing about time, which varies with load: it runs only with
/// `BOTCHU_MARKDOWN_BENCHMARK` set, prints a table and, when the variable names a file, writes it.
///
///     BOTCHU_MARKDOWN_BENCHMARK=/tmp/markdown-bench.txt swift test --configuration release \
///         --package-path macOS --filter markdownBenchmark
@Suite struct MarkdownBenchmark {
    static let paragraph = "A **measured** answer has `code`, a [link](https://example.test), and explanation.\n\n"
    static let fixtures: [(name: String, unit: String, sizes: [Int])] = [
        ("prose", paragraph, [8_192, 32_768, 131_072]),
        ("fenced code", "```swift\nlet item = 123\nlet other = item + 1\n```\n\n", [8_192, 32_768, 131_072]),
        ("shell with $HOME", "Run it:\n\n```sh\nexport PATH=\"$HOME/bin:$PATH\"\necho \"$HOME\"\n```\n\n", [8_192, 32_768, 131_072]),
        ("equation-heavy", paragraph + "The equation is $x^2+y^2=z^2$.\n\n", [2_048, 8_192, 32_768, 131_072]),
        ("table and diagram", "| Step | Owner | State |\n| --- | --- | ---: |\n| Parse | Worker | **done** |\n| Render | WebKit | `pending` |\n\n```mermaid\nflowchart LR\n  A[Delta] --> B[Worker]\n```\n\n", [8_192, 32_768, 131_072]),
    ]

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_MARKDOWN_BENCHMARK"] != nil))
    func markdownBenchmark() async throws {
        var lines = ["Markdown benchmark · \(Self.machine()) · load \(Self.load())", "",
                     "Converting the next revision (about 20 bytes more), uncached",
                     Self.row("Fixture", "bytes", "median", "max", "n", "parses")]
        for fixture in Self.fixtures {
            for size in fixture.sizes {
                var text = String(repeating: fixture.unit, count: max(1, size / fixture.unit.utf8.count))
                let bytes = text.utf8.count
                _ = MarkdownRendering(text)
                var samples: [Double] = []
                var parses = 0
                for index in 0..<10 {
                    text += " token\(index) more words"
                    let source = text
                    let start = DispatchTime.now().uptimeNanoseconds
                    parses += MarkdownParses.counting { _ = MarkdownRendering(source) }
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                let label = fixture.name == "equation-heavy" ? "\(fixture.name), \(bytes / fixture.unit.utf8.count) equations" : fixture.name
                lines.append(Self.row(label, "\(bytes)", Self.ms(Self.median(samples)), Self.ms(samples.max()!), "\(samples.count)",
                                      String(format: "%.1f", Double(parses) / Double(samples.count))))
            }
        }

        // A 128 KB reply given 100 deltas 2 ms apart, as the chat shows it.
        let cache = MarkdownCache()
        let worker = MarkdownWorker(cache: cache, limit: 2)
        let preparation = MarkdownPreparation(worker: worker, cache: cache)
        var text = String(repeating: Self.paragraph, count: 131_072 / Self.paragraph.utf8.count)
        _ = preparation.display(for: text)
        preparation.update(text)
        var mainThread: [Double] = []
        var held = 0
        let parsesOnMain = MarkdownParses.main
        for index in 0..<100 {
            text += " delta \(index) with **bold** words"
            let start = DispatchTime.now().uptimeNanoseconds
            _ = preparation.display(for: text)
            preparation.update(text)
            mainThread.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            held = max(held, worker.heldBytes)
            try await Task.sleep(for: .milliseconds(2))
        }
        let lastDelta = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<1_000 {
            if preparation.source == text { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let settled = Double(DispatchTime.now().uptimeNanoseconds - lastDelta) / 1_000_000
        let stats = worker.statistics
        lines += ["", "A 128 KB reply given 100 deltas 2 ms apart (worker limit \(worker.limit), one parse under way and one revision waiting per reply)",
                  "Main thread per delta (show and ask): median \(Self.ms(Self.median(mainThread))), max \(Self.ms(mainThread.max()!)), n \(mainThread.count); parses on the main thread: \(MarkdownParses.main - parsesOnMain)",
                  "Revisions asked \(stats.requested), parses started \(stats.started), completed \(stats.completed), replaced while waiting \(stats.superseded), found parsed \(stats.hits), most at once \(stats.peak), shown \(preparation.published)",
                  "Last delta to its rendering shown: \(Self.ms(settled)); most text held waiting or parsing: \(held / 1024) KB; final matches a full parse: \(preparation.rendering == MarkdownRendering(text))"]

        // Ten distinct 128 KB replies, each written in 16 KB revisions, then memory pressure.
        let budgetCache = MarkdownCache()
        let budgetWorker = MarkdownWorker(cache: budgetCache, limit: 2)
        let before = Self.heap()
        var replies: [String] = []
        for reply in 0..<10 {
            let full = "Reply \(reply)\n\n" + String(repeating: Self.paragraph, count: 131_072 / Self.paragraph.utf8.count)
            let done = Done()
            let client = UUID()
            for end in stride(from: 16_384, to: full.utf8.count, by: 16_384) + [full.utf8.count] {
                let source = String(decoding: full.utf8.prefix(end), as: UTF8.self)
                budgetWorker.prepare(source, for: client) { _ in if source == full { done.mark() } }
            }
            for _ in 0..<5_000 {
                if done.isDone { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            replies.append(full)
        }
        try await Task.sleep(for: .milliseconds(100))
        let kept = Self.heap() - before
        let estimated = budgetCache.bytes
        let entries = budgetCache.count
        budgetCache.removeAll()
        let released = Self.heap() - before
        lines += ["", "Ten distinct 128 KB replies written in 16 KB revisions (app-wide budget \(MarkdownCache.defaultBudget >> 20) MB)",
                  "Kept: \(entries) entries, estimated \(estimated >> 20) MB; heap grew \(kept >> 20) MB; after memory pressure \(released >> 20) MB; replies' text kept: \(replies.count)"]

        let report = lines.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_MARKDOWN_BENCHMARK"], path.hasPrefix("/") {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func mark() { lock.lock(); done = true; lock.unlock() }
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    static func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
    static func ms(_ value: Double) -> String { String(format: "%.3f ms", value) }

    static func row(_ name: String, _ bytes: String, _ median: String, _ max: String, _ count: String, _ parses: String) -> String {
        name.padding(toLength: 34, withPad: " ", startingAt: 0) + [bytes, median, max, count, parses]
            .map { String(repeating: " ", count: Swift.max(0, 12 - $0.count)) + $0 }.joined()
    }

    static func heap() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory >> 30
        return "\(String(cString: model)), \(memory) GB, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static func load() -> String {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? String(format: "%.1f %.1f %.1f", loads[0], loads[1], loads[2]) : "?"
    }
}
