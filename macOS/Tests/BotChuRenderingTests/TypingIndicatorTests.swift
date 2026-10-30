import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// #63: the typing dots move. Each rises and brightens in turn, smoothly, and all rest before
    /// the next wave; drawn a moment apart they differ (the dots before animated between two equal
    /// values, so they never moved).
    @Test func typingDotsRiseInTurn() throws {
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

        func image(at date: Date) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: TypingDots(date: date).padding(8).background(Color.white))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let frames = try stride(from: 0.0, to: TypingWave.period, by: TypingWave.period / 8).map { try image(at: start.addingTimeInterval($0)) }
        let resting0 = try #require(frames.first?.representation(using: .png, properties: [:]))
        let rising = try #require(frames[2].representation(using: .png, properties: [:]))
        #expect(resting0 != rising)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("typing")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (n, frame) in frames.enumerated() {
                try frame.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("dots-\(n).png"))
            }
        }
    }
}
