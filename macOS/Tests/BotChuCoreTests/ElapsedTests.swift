import Foundation
import Testing
@testable import BotChuCore

@Suite struct ElapsedTests {
    @Test func elapsedShowsMinutesHoursAndClockCorrections() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(BotStatus.formatElapsed(from: start, to: start.addingTimeInterval(-4)) == "0:00")
        #expect(BotStatus.formatElapsed(from: start, to: start.addingTimeInterval(59.99)) == "0:59")
        #expect(BotStatus.formatElapsed(from: start, to: start.addingTimeInterval(335)) == "5:35")
        #expect(BotStatus.formatElapsed(from: start, to: start.addingTimeInterval(3_599)) == "59:59")
        #expect(BotStatus.formatElapsed(from: start, to: start.addingTimeInterval(3_600)) == "1:00:00")
        #expect(BotStatus.formatElapsed(from: start, to: start.addingTimeInterval(86_461)) == "24:01:01")
    }
}
