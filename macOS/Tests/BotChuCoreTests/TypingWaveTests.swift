import Foundation
import Testing
@testable import BotChuCore

/// #63: the typing dots move. Each rises and brightens in turn, smoothly, and all rest before the
/// next wave (the dots before animated between two equal values, so they never moved).
struct TypingWaveTests {
    @Test func eachDotRisesInTurnAndAllRestBeforeTheNextWave() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000 * TypingWave.period)
        let times = stride(from: 0.0, to: TypingWave.period, by: 0.005).map { start.addingTimeInterval($0) }
        for dot in 0..<3 {
            let lifts = times.map { TypingWave.lift(dot: dot, at: $0) }
            #expect(lifts.max()! > 0.99)
            #expect(lifts.min()! == 0)
            #expect(lifts.allSatisfy { (0...1).contains($0) })
            #expect(zip(lifts, lifts.dropFirst()).allSatisfy { abs($0 - $1) < 0.05 })
        }
        let peaks = (0..<3).map { dot in times.max { TypingWave.lift(dot: dot, at: $0) < TypingWave.lift(dot: dot, at: $1) }! }
        #expect(peaks[0] < peaks[1] && peaks[1] < peaks[2])
        let resting = times.filter { time in (0..<3).allSatisfy { TypingWave.lift(dot: $0, at: time) == 0 } }
        #expect(Double(resting.count) * 0.005 > 0.15)
    }
}
