import Foundation

/// The typing indicator's wave (#63): each of its dots rises and brightens in turn, smoothly, and
/// all of them rest before the next wave.
public enum TypingWave {
    /// How long one wave takes.
    public static let period: TimeInterval = 1.3

    /// How far a dot is through its rise, 0 at rest and 1 at the top: a smooth bump over the
    /// first half of its turn, each dot starting a little after the one before it.
    public static func lift(dot: Int, at date: Date) -> Double {
        var phase = (date.timeIntervalSinceReferenceDate / period - Double(dot) * 0.15).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        guard phase < 0.5 else { return 0 }
        return (1 - cos(2 * .pi * phase / 0.5)) / 2
    }
}
