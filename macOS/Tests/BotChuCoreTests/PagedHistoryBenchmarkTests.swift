import Foundation
import Testing
@testable import BotChuCore

/// Opt-in, separate processes for seed/legacy/paged so the peak memory of legacy hydration does
/// not contaminate the paged measurement. The legacy path measures the former JSONL payload
/// read/write; it omits the old index rebuild, so its checkpoint time is a conservative baseline.
@Suite struct PagedHistoryBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_HISTORY_BENCHMARK"] != nil))
    func pagedHistoryBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["BOTCHU_HISTORY_BENCH_MODE"] ?? "paged"
        let folder = URL(fileURLWithPath: env["BOTCHU_HISTORY_BENCH_FIXTURE"] ?? "/tmp/botchu-history-benchmark.noindex")
        var report = ["#274 history benchmark: \(mode); \(ProcessInfo.processInfo.operatingSystemVersionString)",
                      "Warm file cache; 5 samples; milliseconds median/max. Fresh process per mode.",
                      "History hydration only; UI switch/launch latency uses LaunchBenchmarkTests. Legacy checkpoint omits index rebuilding.",
                      "messages | open ms | checkpoint ms | retained payload B | peak RSS B | opening counters | checkpoint counters"]
        for count in [5_000, 50_000] {
            let home = BotHome(workspace: folder.appendingPathComponent("\(count)").path)
            if mode == "seed" {
                try home.saveThread(HistoryTests.pagedFixture(count))
                continue
            }
            var opens: [Double] = [], saves: [Double] = []
            var retained = 0
            var originalText: String?
            var opening = HistoryCounters.Counts(), saving = HistoryCounters.Counts()
            for sample in 0..<5 {
                HistoryCounters.shared.reset(under: home.url)
                let start = DispatchTime.now().uptimeNanoseconds
                let load: HistoryLoad
                if mode == "legacy" {
                    let messages = TranscriptRead.read(home.threadURL).messages
                    load = HistoryLoad(messages: messages, digest: ThreadDigest(messages), bytes: 0, reindexed: false)
                } else { load = home.loadHistory() }
                opens.append(Self.ms(start))
                opening = HistoryCounters.shared.counts(under: home.url)
                retained = HistoryBudget<String>.estimate(load.messages)
                var messages = load.messages
                originalText = originalText ?? messages.last!.text
                messages[messages.count - 1].text = originalText! + " revision \(sample)"
                HistoryCounters.shared.reset(under: home.url)
                let save = DispatchTime.now().uptimeNanoseconds
                if mode == "legacy" {
                    let data = try BotHome.encodeThread(messages)
                    HistoryCounters.shared.record(home.threadURL) { $0.encoded += messages.count }
                    try BotHome.write(data, to: home.url.appendingPathComponent("legacy.jsonl"))
                } else { try home.writeTranscript(.init(messages, start: load.start, base: load.messages)) }
                saves.append(Self.ms(save))
                saving = HistoryCounters.shared.counts(under: home.url)
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            report.append("\(count) | \(Self.times(opens)) | \(Self.times(saves)) | \(retained) | \(usage.ru_maxrss) | \(opening.summary) | \(saving.summary)")
        }
        let text = report.joined(separator: "\n") + "\n"
        print(text)
        if let path = env["BOTCHU_HISTORY_BENCHMARK"], path.hasPrefix("/") {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    static func times(_ values: [Double]) -> String {
        let values = values.sorted()
        return String(format: "%.3f/%.3f", values[values.count / 2], values.last ?? 0)
    }
}
