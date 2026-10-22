import CoreGraphics
import ImageIO
import SwiftUI
import BotChuCore

/// A bot's pet, decoded: every animation it has (the atlas rows it uses and BotChu's extra
/// animations) as frames, and the square around its head for small avatars.
final class PetSheet: @unchecked Sendable {
    struct Animation {
        let frames: [CGImage]
        let heads: [CGImage]
        /// Seconds per frame.
        let durations: [Double]
        var total: Double { durations.reduce(0, +) }

        /// The frame `elapsed` seconds in, looping.
        func index(at elapsed: Double, loops: Bool = true) -> Int? {
            guard total > 0 else { return 0 }
            if !loops, elapsed >= total { return nil }
            var t = elapsed.truncatingRemainder(dividingBy: total)
            for (i, d) in durations.enumerated() {
                if t < d { return i }
                t -= d
            }
            return frames.count - 1
        }
    }

    let name: String
    let animations: [String: Animation]

    private init(name: String, animations: [String: Animation]) {
        self.name = name
        self.animations = animations
    }

    /// The animation for `activity`, falling back as `BotActivity.animations` says.
    func animation(for activity: BotActivity) -> Animation? {
        activity.animation(among: Set(animations.keys)).flatMap { animations[$0] } ?? animations["idle"]
    }

    /// Reads a pet's atlas and extra frames. Nil when the atlas can't be read or isn't 8 × 9 or
    /// 8 × 11 cells of 192 × 208.
    static func load(_ pet: PetPackage) -> PetSheet? {
        guard let atlas = image(at: pet.sheetURL),
              PetAtlas.isValidSize(width: atlas.width, height: atlas.height),
              let pixels = Pixels(atlas) else { return nil }
        let cellW = PetAtlas.cellWidth, cellH = PetAtlas.cellHeight

        var frames: [String: [CGImage]] = [:]
        for row in PetAtlas.rows {
            var cells: [CGImage] = []
            for column in 0..<PetAtlas.columns {
                let rect = CGRect(x: column * cellW, y: row.index * cellH, width: cellW, height: cellH)
                // A row's frames run from the left until the first empty cell.
                guard pixels.opaqueBounds(in: rect) != nil, let cell = atlas.cropping(to: rect) else { break }
                cells.append(cell)
            }
            if !cells.isEmpty { frames[row.name] = cells }
        }
        guard let idleRow = PetAtlas.row(named: "idle"),
              let idleBounds = pixels.opaqueBounds(in: CGRect(x: 0, y: idleRow.index * cellH, width: cellW, height: cellH)),
              frames["idle"] != nil else { return nil }
        // Idle's first frame is the top-left cell.
        let head = headRect(bodyBounds: idleBounds, cell: CGSize(width: cellW, height: cellH))

        var animations: [String: Animation] = [:]
        for row in PetAtlas.rows {
            guard let cells = frames[row.name] else { continue }
            animations[row.name] = make(cells, durations: row.durations(frameCount: cells.count), head: head)
        }
        for extra in pet.extras {
            let cells = extra.frameURLs.compactMap(image(at:))
            guard cells.count == extra.frameURLs.count else { continue }
            animations[extra.id] = make(cells, durations: extra.durations, head: head)
        }
        return PetSheet(name: pet.manifest.displayName, animations: animations)
    }

    /// A portrait square: the whole head and most of the body, with a little room above.
    static func headRect(bodyBounds b: CGRect, cell: CGSize) -> CGRect {
        let side = min(min(cell.width, cell.height), max(b.width, b.height * 0.82) * 1.08)
        // Kept whole inside the cell, so it stays square.
        let x = min(max(0, b.midX - side / 2), cell.width - side)
        let y = min(max(0, b.minY - side * 0.06), cell.height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    private static func make(_ cells: [CGImage], durations: [Int], head: CGRect) -> Animation {
        let heads = cells.map { cell -> CGImage in
            // Extra frames are cells of the same size; anything else is shown whole.
            guard cell.width == PetAtlas.cellWidth, cell.height == PetAtlas.cellHeight else { return cell }
            return cell.cropping(to: head.integral) ?? cell
        }
        return Animation(frames: cells, heads: heads, durations: durations.map { Double($0) / 1000 })
    }

    private static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// An image's alpha channel, to find the empty cells and the body's outline.
    private struct Pixels {
        let width: Int
        let height: Int
        let alpha: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            var buffer = [UInt8](repeating: 0, count: width * height)
            let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            alpha = buffer
        }

        /// The box around the clearly visible pixels in `rect`; both in image pixels, top-left origin
        /// (the bitmap's first row is the image's top).
        func opaqueBounds(in rect: CGRect, threshold: UInt8 = 40) -> CGRect? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in Int(rect.minY)..<min(Int(rect.maxY), height) {
                let row = y * width
                for x in Int(rect.minX)..<min(Int(rect.maxX), width) where alpha[row + x] > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }
}

/// A pet, animated for what its bot is doing: the whole figure, or just its head.
struct PetSpriteView: View {
    enum Style { case figure, head }

    let sheet: PetSheet
    let activity: BotActivity
    var style: Style = .figure
    /// Off shows the activity's first frame, for small or many avatars.
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        Group {
            if animates && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    frame(at: context.date.timeIntervalSince(started))
                }
            } else {
                frame(at: 0)
            }
        }
        .onChange(of: activity) { started = Date() }
        .accessibilityHidden(true)
    }

    private func frame(at elapsed: Double) -> some View {
        var image = sheet.animations["idle"].flatMap { pick($0, at: elapsed) }
        if let animation = sheet.animation(for: activity) {
            if let index = animation.index(at: elapsed, loops: !activity.isOneShot) {
                image = pick(animation, index: index)
            } else if let idle = sheet.animations["idle"] {
                // A one-shot reaction has played: back to idle.
                image = pick(idle, at: elapsed - animation.total)
            }
        }
        return Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
    }

    private func pick(_ animation: PetSheet.Animation, at elapsed: Double) -> CGImage? {
        animation.index(at: elapsed).map { pick(animation, index: $0) }
    }

    private func pick(_ animation: PetSheet.Animation, index: Int) -> CGImage {
        let images = style == .head ? animation.heads : animation.frames
        return images[min(index, images.count - 1)]
    }
}
