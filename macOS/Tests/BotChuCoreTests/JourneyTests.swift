import Foundation
import Testing
@testable import BotChuCore

/// The frame marks the app writes with `BOTCHU_TIMINGS` and how the journeys harness reads and
/// judges them (#323).
struct JourneyTests {
    @Test func marksRoundTripAndSkipWhatIsNotAMark() {
        let bot = UUID(uuidString: "00000000-0000-4000-8323-000000000001")!
        let text = FrameMarks.line(FrameMarks.window, at: 10) + FrameMarks.line(FrameMarks.chat(bot), at: 25)
            + "# a comment\n\n12 \n" + FrameMarks.line(FrameMarks.sidebar(shown: false), at: 40) + "99 inspector.sh"
        #expect(FrameMarks.parse(text) == [
            FrameMarks.Mark(name: "window", nanoseconds: 10),
            FrameMarks.Mark(name: "chat 00000000-0000-4000-8323-000000000001", nanoseconds: 25),
            FrameMarks.Mark(name: "sidebar.hidden", nanoseconds: 40),
            // A line still being written parses as far as it goes; the harness reads whole lines only.
            FrameMarks.Mark(name: "inspector.sh", nanoseconds: 99),
        ])
        #expect(FrameMarks.inspector(shown: true) == "inspector.shown")
        #expect(FrameMarks.sidebar(shown: true) == "sidebar.shown")
    }

    @Test func medianAndNearestRankPercentile() {
        #expect(JourneyStats.median([]) == nil)
        #expect(JourneyStats.median([5]) == 5)
        #expect(JourneyStats.median([9, 1, 5]) == 5)
        #expect(JourneyStats.median([4, 1, 3, 2]) == 2.5)
        #expect(JourneyStats.percentile(95, of: [3, 1, 2]) == 3)
        #expect(JourneyStats.percentile(95, of: Array(1...20).map(Double.init)) == 19)
        #expect(JourneyStats.percentile(50, of: [10, 20, 30, 40]) == 20)
        #expect(JourneyStats.percentile(95, of: []) == nil)
    }

    @Test func aStepPassesOnItsMedianAndSaysWhyItFailed() {
        let quick = JourneyResult(journey: 2, step: "sidebar · close", budget: .instant, baseline: 9, samples: [8, 70, 9, 10, 7])
        #expect(quick.median == 9)
        #expect(quick.p95 == 70)
        #expect(quick.passed)
        #expect(quick.report == "2 sidebar · close: budget Instant 16.0 ms, baseline 9.0 ms, median 9.0 ms, p95 70.0 ms, 5 samples — ok")

        // An injected 50 ms stall: the report names the journey, its budget, baseline and time.
        let stalled = JourneyResult(journey: 2, step: "sidebar · close", budget: .instant, baseline: 9, samples: [58, 61, 59, 60, 62])
        #expect(!stalled.passed)
        #expect(stalled.report == "2 sidebar · close: budget Instant 16.0 ms, baseline 9.0 ms, median 60.0 ms, p95 62.0 ms, 5 samples — FAILED: median over budget")

        let broken = JourneyResult(journey: 3, step: "switch bot", budget: .within(50), samples: [4], problem: "The chat doesn't show Iris's latest message")
        #expect(!broken.passed)
        #expect(broken.report.hasSuffix("— FAILED: The chat doesn't show Iris's latest message"))
        #expect(broken.report.contains("budget ≤ 50 ms 50.0 ms, baseline —"))
        #expect(!JourneyResult(journey: 1, step: "launch", budget: .launch, samples: []).passed)
    }

    @Test func aBaselineKeepsEachStepsRoundedMedianAndReadsBack() throws {
        let results = [JourneyResult(journey: 1, step: "launch", budget: .launch, samples: [812.34, 790.01, 845.55]),
                       JourneyResult(journey: 3, step: "switch bot", budget: .within(50), samples: [], problem: "no row")]
        let baseline = JourneyBaseline(recordedAt: Date(timeIntervalSince1970: 1_793_300_000), commit: "4ec0bca", machine: "Mac16,6",
                                       loadBefore: [12.5, 10, 8], loadAfter: [14, 11, 8.5], results: results)
        #expect(baseline.medians == ["1 launch": 812.3])
        let read = try JourneyBaseline.decode(baseline.encoded())
        #expect(read == baseline)
        #expect(String(decoding: try baseline.encoded(), as: UTF8.self).contains("\"recordedAt\" : \"2026-10-29T"))
    }

    @Test func journeysAreChosenByNameOrNumber() throws {
        let catalog: [(number: Int, names: [String])] = [(1, ["launch"]), (2, ["sidebar", "inspector"]), (3, ["switch-bot"])]
        #expect(try JourneySelection.parse("", catalog: catalog).numbers == [1, 2, 3])
        #expect(try JourneySelection.parse("all", catalog: catalog).numbers == [1, 2, 3])
        #expect(try JourneySelection.parse("switch-bot, Sidebar,2", catalog: catalog).numbers == [2, 3])
        #expect(try JourneySelection.parse("1", catalog: catalog).numbers == [1])
        #expect(throws: JourneySelection.Unknown(description: "No journey \"chat\". Journeys: 1 (launch); 2 (sidebar, inspector); 3 (switch-bot).")) {
            try JourneySelection.parse("launch,chat", catalog: catalog)
        }
    }
}
