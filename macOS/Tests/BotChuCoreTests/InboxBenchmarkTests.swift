import Foundation
import Testing
@testable import BotChuCore

/// Opt-in list preparation measurements. The baseline reproduces the old view's full sort plus
/// grouping, including all Done IDs. The new path prepares only the cached list's candidates.
/// No window, provider, file contents or timing assertions are involved.
@Suite struct InboxBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTCHU_INBOX_BENCHMARK"] != nil))
    func inboxArchiveBenchmark() throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOTCHU_INBOX_BENCHMARK"])
        let now = Date(timeIntervalSinceReferenceDate: 815_000_000), bot = UUID()
        var lines = ["#275 Inbox list preparation, synthetic data, 30 warm samples, milliseconds (median)",
                     "archive | visible candidates | before sort/group | after cached candidates/group | build index"]
        for count in [100, 1_000, 10_000] {
            let archived = (0..<count).map { Delivery(botID: bot, title: "Archive \($0)", sentAt: now.addingTimeInterval(-Double($0 + 2) * 86_400)) }
            let visible = (0..<20).map { Delivery(botID: bot, title: "Current \($0)", sentAt: now.addingTimeInterval(-Double($0))) }
            let all = archived + visible
            var state = InboxState()
            for item in archived { state.setDone(item.id, true, at: item.updatedAt) }
            for item in visible.suffix(10) { state.setDone(item.id, true, at: now) }
            let index = InboxList.Index(all, state: state, now: now)
            func measure(_ body: () -> Int) -> Double {
                _ = body()
                var samples: [Double] = []
                for _ in 0..<30 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = body()
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    #expect(result > 0)
                }
                return samples.sorted()[samples.count / 2]
            }
            let before = measure {
                let sorted = all.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
                let grouped = Dictionary(grouping: sorted) { InboxList.section(of: $0, state: state, now: now) }
                return grouped.values.flatMap { deliveries in
                    deliveries.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }.map(\.id)
                }.count
            }
            let after = measure { InboxList.groups(index.deliveries.values, state: state, now: now).flatMap(\.ids).count }
            let build = measure { InboxList.Index(all, state: state, now: now).deliveries.count }
            #expect(index.deliveries.count == 20)
            lines.append(String(format: "%d | %d | %.3f | %.3f | %.3f", count, index.deliveries.count, before, after, build))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
    }
}
