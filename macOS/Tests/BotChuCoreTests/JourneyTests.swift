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
        let quick = JourneyResult(journey: 2, step: "sidebar · close", budget: .instant, baseline: 9, samples: [8, 70, 9, 10, 7], load: 4.24)
        #expect(quick.median == 9)
        #expect(quick.p95 == 70)
        #expect(quick.passed)
        #expect(quick.report == "2 sidebar · close: budget Instant 16.0 ms, baseline 9.0 ms, median 9.0 ms, p95 70.0 ms, 5 samples, load 4.2 — ok")

        // Over budget: the report names the journey, its budget, baseline and time.
        let stalled = JourneyResult(journey: 2, step: "sidebar · close", budget: .instant, baseline: 9, samples: [58, 61, 59, 60, 62])
        #expect(!stalled.passed)
        #expect(stalled.report == "2 sidebar · close: budget Instant 16.0 ms, baseline 9.0 ms, median 60.0 ms, p95 62.0 ms, 5 samples"
            + " — FAILED: median 60.0 ms over its budget of 16.0 ms")

        let broken = JourneyResult(journey: 3, step: "switch bot", budget: .within(50), samples: [4], problem: "The chat doesn't show Iris's latest message")
        #expect(!broken.passed)
        #expect(broken.report.hasSuffix("— FAILED: The chat doesn't show Iris's latest message"))
        #expect(broken.report.contains("budget ≤ 50 ms 50.0 ms, baseline —"))
        #expect(!JourneyResult(journey: 1, step: "launch", budget: .launch, samples: []).passed)
    }

    @Test func aStepWithinBudgetFailsWhenItIsAQuarterAndThreeMillisecondsSlowerThanItsBaseline() {
        func step(baseline: Double, median: Double) -> JourneyResult {
            JourneyResult(journey: 4, step: "switch task", budget: .within(50), baseline: baseline, samples: [median])
        }
        // 30 % and 6 ms slower, within the 50 ms budget.
        let slower = step(baseline: 20, median: 26)
        #expect(slower.failure == "median 26.0 ms is 30 % (6.0 ms) slower than the baseline 20.0 ms")
        #expect(slower.report.contains("budget ≤ 50 ms 50.0 ms, baseline 20.0 ms, median 26.0 ms"))
        // 25 % or less, or 3 ms or less, is noise.
        #expect(step(baseline: 20, median: 25).passed)
        #expect(step(baseline: 8, median: 11).passed)
        #expect(!step(baseline: 8, median: 11.5).passed)
        // Faster always passes, and so does a step with no baseline yet.
        #expect(step(baseline: 40, median: 10).passed)
        #expect(JourneyResult(journey: 4, step: "switch task", budget: .within(50), samples: [49]).passed)
    }

    @Test func aBaselineOverBudgetRatchetsTheBudgetToItPlusATenthAndSaysSo() {
        // Journey 2's recorded sidebar toggle, 44.1 ms against Instant's 16 ms.
        let atBaseline = JourneyResult(journey: 2, step: "sidebar · close", budget: .instant, baseline: 44.1, samples: [44, 46, 43, 45, 47, 44])
        #expect(atBaseline.ratcheted)
        #expect(atBaseline.limit == 48.5)
        #expect(atBaseline.passed)
        #expect(atBaseline.report == "2 sidebar · close: budget Instant 16.0 ms (ratcheted to 48.5 ms: the baseline is over budget), "
            + "baseline 44.1 ms, median 44.5 ms, p95 47.0 ms, 6 samples — ok")

        // An injected 50 ms stall on top fails it, naming the budget, the baseline and the time.
        let stalled = JourneyResult(journey: 2, step: "sidebar · close", budget: .instant, baseline: 44.1, samples: [94, 96, 93, 95, 97, 94])
        #expect(stalled.failure == "median 94.5 ms over its budget of 48.5 ms")
        #expect(stalled.report.contains("budget Instant 16.0 ms (ratcheted to 48.5 ms: the baseline is over budget), baseline 44.1 ms, median 94.5 ms"))

        // A baseline within budget leaves the budget alone.
        let within = JourneyResult(journey: 3, step: "switch bot", budget: .within(50), baseline: 47.8, samples: [51])
        #expect(!within.ratcheted)
        #expect(within.limit == 50)
        #expect(within.failure == "median 51.0 ms over its budget of 50.0 ms")
    }

    @Test func aStepMeasuredAgainSaysWhyAndTheLoad() {
        let again = JourneyResult(journey: 5, step: "echo while 4 stream (p95)", budget: .instant, baseline: 9, samples: [10, 11, 9],
                                  load: 31.04, retried: "median 40.0 ms over its budget of 16.0 ms (load 52.3)")
        #expect(again.passed)
        #expect(again.report == "5 echo while 4 stream (p95): budget Instant 16.0 ms, baseline 9.0 ms, median 10.0 ms, p95 11.0 ms, 3 samples, "
            + "load 31.0; measured again after: median 40.0 ms over its budget of 16.0 ms (load 52.3) — ok")
    }

    @Test func busyStretchesAndStreamedLengthsReadBack() {
        let bot = UUID(uuidString: "00000000-0000-4000-8323-000000000001")!
        #expect(FrameMarks.busyMilliseconds(FrameMarks.busy(milliseconds: 37.256)) == 37.26)
        #expect(FrameMarks.busyMilliseconds("busyness") == nil)
        #expect(FrameMarks.streamedLength(FrameMarks.streamed(bot, length: 812), of: bot) == 812)
        #expect(FrameMarks.streamedLength(FrameMarks.streamed(UUID(), length: 812), of: bot) == nil)
        #expect(FrameMarks.isContinuous(FrameMarks.busy(milliseconds: 5)))
        #expect(FrameMarks.isContinuous(FrameMarks.avatarFrame))
        #expect(!FrameMarks.isContinuous(FrameMarks.composer))
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
