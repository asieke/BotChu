import AppKit
import SwiftUI
import BotChuCore

// The providers' marks, drawn in code instead of shipped as image files. They follow GitChu's
// (asieke/GitChu: `ProviderLogo` in macOS/Sources/UsagePanel.swift, and the π tile of `AgentLogo`
// in AgentLogo.swift), so an account looks the same in both apps. The Claude, OpenAI, Google and
// Facebook marks are trademarks of Anthropic, OpenAI, Google and Meta respectively: BotChu draws
// simplified versions of them only to identify the CLI an account runs, and is not endorsed by them.
// Pi has no mark of its own, so its accounts (OpenRouter) show π on a tile, as GitChu's agents
// without a logo do.

/// The mark of an account's CLI family, so a profile added in Providers shows its family's: Claude's
/// spark, OpenAI's knot for Codex, Google's G for Antigravity, Facebook's f for Muse, π for Pi, and a
/// sailboat for Sail.
struct ProviderLogo: View {
    let kind: AgentKind
    var size: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            switch kind {
            case .codex:
                tile.fill(.white)
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .stroke(.black, lineWidth: size * 0.065)
                        .frame(width: size * 0.3, height: size * 0.66)
                        .rotationEffect(.degrees(Double(i) * 60))
                }
            case .claude:
                tile.fill(Color(hex: "D97757"))
                ClaudeSpark().fill(.white).padding(size * 0.15)
            case .antigravity:
                tile.fill(.white)
                GoogleG(lineWidth: size * 0.17).padding(size * 0.2)
            case .muse:
                tile.fill(Color(hex: "1877F2"))
                FacebookF().fill(.white)
            case .pi:
                // Dark on light and light on dark, so the tile stands out in both.
                let dark = colorScheme == .dark
                tile.fill(Color(hex: dark ? "F2F2F7" : "1C1C1E"))
                Text("π")
                    .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: dark ? "1C1C1E" : "FFFFFF"))
            case .sail:
                // Not Sail Research's mark: a sailboat symbol on a tile, as Pi's π is.
                tile.fill(Color(hex: "0B3D91"))
                Image(systemName: "sailboat.fill")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(tile)
        .overlay(tile.strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

extension ProviderLogo {
    /// The mark as a picture, for menus and pop-up buttons, which show an item's image but not a
    /// drawn view. Rendered at twice its size for the appearance it is shown in, once.
    @MainActor static func image(_ kind: AgentKind, size: CGFloat = 16, colorScheme: ColorScheme) -> NSImage {
        let key = ImageKey(kind: kind, size: size, dark: colorScheme == .dark)
        if let image = images[key] { return image }
        let renderer = ImageRenderer(content: ProviderLogo(kind: kind, size: size).environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        let image = renderer.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: size, height: size)) }
            ?? NSImage(size: NSSize(width: size, height: size))
        images[key] = image
        return image
    }

    private struct ImageKey: Hashable {
        let kind: AgentKind
        let size: CGFloat
        let dark: Bool
    }

    @MainActor private static var images: [ImageKey: NSImage] = [:]
}

/// A name beside its provider's mark: an account, or a CLI family. The mark sits on the name's
/// first line, also when the name wraps.
struct ProviderLabel: View {
    let title: String
    let kind: AgentKind
    var size: CGFloat = 14

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.4) {
            ProviderLogo(kind: kind, size: size)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + size * 0.3 }
            Text(title)
        }
    }
}

extension ProviderLabel {
    init(_ account: Account, size: CGFloat = 14) {
        self.init(title: account.name, kind: account.kind, size: size)
    }
}

/// A name beside its provider's mark in a picker or menu item, whose icon must be an image.
struct ProviderMenuLabel: View {
    let title: String
    let kind: AgentKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: ProviderLogo.image(kind, colorScheme: colorScheme))
        }
    }
}

extension ProviderMenuLabel {
    init(_ account: Account) {
        self.init(title: account.name, kind: account.kind)
    }
}

/// Claude's mark: rays of uneven length around a center.
private struct ClaudeSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let lengths: [CGFloat] = [1, 0.78, 0.95, 0.8, 1, 0.74, 0.93, 0.82, 0.98, 0.76, 0.9, 0.8]
        var path = Path()
        for (i, length) in lengths.enumerated() {
            let angle = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi - .pi / 2
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(angle) * radius * length, y: center.y + sin(angle) * radius * length))
        }
        return path.strokedPath(StrokeStyle(lineWidth: radius * 0.22, lineCap: .round))
    }
}

/// Google's G: four colored arcs and the blue bar.
private struct GoogleG: View {
    var lineWidth: CGFloat

    var body: some View {
        // Arcs run clockwise from three o'clock; the gap at the upper right is the G's mouth.
        let arcs: [(from: CGFloat, to: CGFloat, color: String)] = [
            (0, 0.12, "4285F4"), (0.11, 0.38, "34A853"), (0.37, 0.61, "FBBC05"), (0.6, 0.87, "EA4335"),
        ]
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(arcs.indices, id: \.self) { i in
                    Circle()
                        .trim(from: arcs[i].from, to: arcs[i].to)
                        .stroke(Color(hex: arcs[i].color), lineWidth: lineWidth)
                }
                Rectangle()
                    .fill(Color(hex: "4285F4"))
                    .frame(width: side / 2 + lineWidth / 2, height: lineWidth * 0.9)
                    .offset(x: side / 4 + lineWidth / 4)
            }
            .frame(width: side, height: side)
        }
    }
}

/// Facebook's f, from its 64-point logo.
private struct FacebookF: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 64
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(41.6, 40.8))
        path.addLine(to: p(42.9, 32.2))
        path.addLine(to: p(34.6, 32.2))
        path.addLine(to: p(34.6, 26.6))
        path.addCurve(to: p(39.5, 21.9), control1: p(34.6, 24.2), control2: p(35.8, 21.9))
        path.addLine(to: p(43.3, 21.9))
        path.addLine(to: p(43.3, 14.6))
        path.addCurve(to: p(36.6, 14.0), control1: p(43.3, 14.6), control2: p(39.9, 14.0))
        path.addCurve(to: p(25.2, 25.7), control1: p(29.7, 14.0), control2: p(25.2, 18.2))
        path.addLine(to: p(25.2, 32.2))
        path.addLine(to: p(17.5, 32.2))
        path.addLine(to: p(17.5, 40.8))
        path.addLine(to: p(25.2, 40.8))
        path.addLine(to: p(25.2, 64))
        path.addLine(to: p(34.6, 64))
        path.addLine(to: p(34.6, 40.8))
        path.closeSubpath()
        return path
    }
}
