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

        /// Where `elapsed` seconds falls: the frame, the frame after it (nil at the end of an
        /// animation that doesn't loop), and how far to blend into that one, 0 to 1. The blend runs
        /// over the last `share` of each frame's time, eased, so poses flow into each other.
        func position(at elapsed: Double, loops: Bool = true, share: Double = 0.5) -> (index: Int, next: Int?, blend: Double)? {
            guard total > 0, !frames.isEmpty else { return (0, nil, 0) }
            if !loops, elapsed >= total { return nil }
            var t = loops ? elapsed.truncatingRemainder(dividingBy: total) : max(0, elapsed)
            if t < 0 { t += total }
            for (i, d) in durations.enumerated() {
                if t < d {
                    let next = i + 1 < frames.count ? i + 1 : (loops ? 0 : nil)
                    let start = d * (1 - share)
                    let blend = t <= start ? 0 : PetSheet.ease((t - start) / (d * share))
                    return (i, next, blend)
                }
                t -= d
            }
            return (frames.count - 1, loops ? 0 : nil, 0)
        }
    }

    let name: String
    let animations: [String: Animation]

    /// Smoothstep: slow in, slow out.
    static func ease(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }

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

/// A pet, animated for what its bot is doing: the whole figure, or just its head. Frames blend into
/// each other, and a change of activity cross-fades, so the motion is smooth rather than stepped.
struct PetSpriteView: View {
    enum Style { case figure, head }

    let sheet: PetSheet
    let activity: BotActivity
    var style: Style = .figure
    /// Off shows the activity's first frame, for small or many avatars.
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    /// The activity before the last change and when it started, faded out over `fade`.
    @State private var previous: (activity: BotActivity, started: Date)?
    @State private var changed = Date.distantPast

    private static let fade = 0.3

    var body: some View {
        Group {
            if animates && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                    layers(at: context.date)
                }
            } else {
                still
            }
        }
        .onChange(of: activity) { old, _ in
            let now = Date()
            previous = (old, started)
            changed = now
            started = now
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var still: some View {
        if let animation = sheet.animation(for: activity) ?? sheet.animations["idle"] {
            picture(images(of: animation)[0])
        }
    }

    /// Every image showing at `date` with its weight; the weights add up to 1.
    private func layers(at date: Date) -> some View {
        var weighted = frames(for: activity, elapsed: date.timeIntervalSince(started))
        let sinceChange = date.timeIntervalSince(changed)
        if let previous, sinceChange < Self.fade {
            let keep = 1 - PetSheet.ease(sinceChange / Self.fade)
            weighted = weighted.map { ($0.0, $0.1 * (1 - keep)) }
                + frames(for: previous.activity, elapsed: date.timeIntervalSince(previous.started)).map { ($0.0, $0.1 * keep) }
        }
        let shown = weighted.filter { $0.1 > 0.002 }
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, layer in
                // Adding the weighted layers gives a true cross-dissolve, with no dip in opacity
                // where the two poses differ.
                picture(layer.0)
                    .opacity(layer.1)
                    .blendMode(.plusLighter)
            }
        }
        // Drawn offscreen on transparency first; otherwise the layers would add onto the card.
        .drawingGroup()
    }

    /// The frames of `activity`'s animation `elapsed` seconds in, with their weights. A one-shot
    /// reaction that has played blends back into idle.
    private func frames(for activity: BotActivity, elapsed: Double) -> [(CGImage, Double)] {
        let idle = sheet.animations["idle"]
        guard let animation = sheet.animation(for: activity) ?? idle else { return [] }
        let loops = !activity.isOneShot
        if let p = animation.position(at: elapsed, loops: loops) {
            let images = images(of: animation)
            let current = images[min(p.index, images.count - 1)]
            let next: CGImage? = p.next.map { images[min($0, images.count - 1)] }
                ?? idle.map { self.images(of: $0)[0] }
            guard let next, p.blend > 0 else { return [(current, 1)] }
            return [(current, 1 - p.blend), (next, p.blend)]
        }
        guard let idle else { return [] }
        return frames(forIdle: idle, elapsed: elapsed - animation.total)
    }

    private func frames(forIdle idle: PetSheet.Animation, elapsed: Double) -> [(CGImage, Double)] {
        guard let p = idle.position(at: elapsed) else { return [] }
        let images = images(of: idle)
        let current = images[min(p.index, images.count - 1)]
        guard let next = p.next, p.blend > 0 else { return [(current, 1)] }
        return [(current, 1 - p.blend), (images[min(next, images.count - 1)], p.blend)]
    }

    private func images(of animation: PetSheet.Animation) -> [CGImage] {
        style == .head ? animation.heads : animation.frames
    }

    private func picture(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}


/// How a pet drawing is going, with Cancel (or Dismiss, after a failure).
struct PetDrawingStatus: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        if let drawing = model.petDrawings[botID] {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if drawing.isActive {
                    ProgressView().controlSize(.mini)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(drawing.summary)
                        Text("Started \(drawing.startedAt.formatted(date: .omitted, time: .shortened)); this takes a while.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Cancel") { model.cancelPetDrawing(botID) }
                } else {
                    Text(drawing.summary)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("Dismiss") { model.dismissPetDrawing(botID) }
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
    }
}
