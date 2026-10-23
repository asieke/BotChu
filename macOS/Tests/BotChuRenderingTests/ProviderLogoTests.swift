import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// Each CLI family has a mark of its own that stands out in both appearances: its mark against its
    /// tile, and π's tile, the one that changes with the appearance, against the window.
    @Test func providerLogosAreDistinctAndClearInBothAppearances() throws {
        _ = NSApplication.shared
        var logos: [ColorScheme: [AgentKind: LogoPixels]] = [:]
        for scheme in [ColorScheme.light, .dark] {
            for kind in AgentKind.allCases {
                let image = ProviderLogo.image(kind, size: 16, colorScheme: scheme)
                #expect(image.size == NSSize(width: 16, height: 16))
                let pixels = try LogoPixels(image)
                // Drawn at twice its size, for Retina screens, as a tile rounded at its corners.
                #expect(pixels.width == 32 && pixels.height == 32)
                #expect(pixels.alpha(16, 1) > 0.95 && pixels.alpha(1, 16) > 0.95 && pixels.alpha(16, 30) > 0.95)
                #expect(pixels.alpha(0, 0) < 0.05, "\(kind) has rounded corners")
                // WCAG's minimum for graphics, 3:1, between the mark and its tile.
                let tile = pixels.mostCommonColor
                #expect(pixels.strongestContrast(with: tile) >= 3, "\(kind)'s mark stands out in \(scheme)")
                if kind == .pi {
                    #expect(Contrast.ratio(tile, Contrast.windowBackground(scheme)) >= 3, "π's tile stands out in \(scheme)")
                }
                logos[scheme, default: [:]][kind] = pixels
            }
        }
        let light = try #require(logos[.light]), dark = try #require(logos[.dark])
        for kind in AgentKind.allCases {
            let mark = try #require(light[kind]), darkMark = try #require(dark[kind])
            for other in AgentKind.allCases where other != kind {
                let otherMark = try #require(light[other])
                #expect(mark.differs(from: otherMark), "\(kind) and \(other) have marks of their own")
            }
            // The providers' own tiles keep their colors; only π's turns light in dark mode.
            #expect(mark.differs(from: darkMark) == (kind == .pi), "\(kind)")
        }
    }

    /// Menus show an item's image but not a drawn view, so account menus carry the marks as images:
    /// each account its CLI family's, a profile added in Providers too, drawn for the menu's appearance.
    @Test func accountMenusShowTheirFamilysLogo() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-logos-\(UUID().uuidString)")
        let domain = "BotChu.ProviderLogos.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        let settings = AppSettings(defaults: defaults)
        let custom = Account(id: "custom-research", name: "Research Codex", kind: .codex, defaultCommand: "codex-research", symbol: "terminal")
        settings.customAccounts = [custom]
        let app = AppModel(store: Store(root: root.appendingPathComponent("index")), settings: settings,
                           usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        func menuButton(_ view: some View, appearance: NSAppearance.Name = .aqua) async throws -> NSPopUpButton {
            window.appearance = NSAppearance(named: appearance)
            window.contentView = NSHostingView(rootView: view.environment(app).padding())
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let content = try #require(window.contentView)
            return try #require(popUpButtons(in: content).first)
        }

        // The status sidebar's Account menu.
        var logos: [String: LogoPixels] = [:]
        for account in [settings.account("codex-dev"), custom, settings.account("claude-dev")] {
            var bot = Bot(name: "Scout", workspace: root.appendingPathComponent("Scout").path)
            bot.selectAccount(account)
            let button = try await menuButton(RunsOnCard(settings: bot, target: .home(bot.id)))
            #expect(button.title == account.name)
            let image = try #require(button.cell?.image, "\(account.name) shows a logo")
            #expect(image.size == NSSize(width: 16, height: 16))
            logos[account.id] = try LogoPixels(image)
        }
        let codex = try #require(logos["codex-dev"]), research = try #require(logos[custom.id]), claude = try #require(logos["claude-dev"])
        #expect(!research.differs(from: codex))
        #expect(claude.differs(from: codex))

        // π's tile, dark in a light menu and light in a dark one.
        var tiles: [Double] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let button = try await menuButton(Menu {
                Button("OpenRouter") {}
            } label: {
                ProviderMenuLabel(title: "OpenRouter", kind: .pi)
            }.menuStyle(.borderlessButton), appearance: appearance)
            let image = try #require(button.cell?.image)
            tiles.append(Contrast.luminance(try LogoPixels(image).mostCommonColor))
        }
        #expect(tiles.count == 2 && tiles[0] < 0.2 && tiles[1] > 0.6)
    }

    private func popUpButtons(in view: NSView) -> [NSPopUpButton] {
        ((view as? NSPopUpButton).map { [$0] } ?? []) + view.subviews.flatMap(popUpButtons)
    }
}

/// A rendered logo's pixels, as 8-bit sRGB with alpha, top row first.
private struct LogoPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: NSImage) throws {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let (width, height) = (cgImage.width, cgImage.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    func alpha(_ x: Int, _ y: Int) -> Double { Double(bytes[(y * width + x) * 4 + 3]) / 255 }

    /// The fully opaque pixels' colors.
    private var opaqueColors: [Contrast.RGB] {
        stride(from: 0, to: bytes.count, by: 4).compactMap { i in
            bytes[i + 3] == 255 ? Contrast.RGB(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2]) : nil
        }
    }

    /// The tile's color: the one most of the logo is.
    var mostCommonColor: Contrast.RGB {
        Dictionary(grouping: opaqueColors) { $0 }.max { $0.value.count < $1.value.count }?.key ?? Contrast.RGB(r: 0, g: 0, b: 0)
    }

    func strongestContrast(with color: Contrast.RGB) -> Double {
        opaqueColors.map { Contrast.ratio($0, color) }.max() ?? 1
    }

    /// Whether another picture is a different one, beyond the odd edge pixel two renderings of the
    /// same drawing can differ by.
    func differs(from other: LogoPixels) -> Bool {
        guard width == other.width, height == other.height else { return true }
        return zip(bytes, other.bytes).filter { abs(Int($0) - Int($1)) > 8 }.count > 32
    }
}

/// WCAG contrast between sRGB colors.
private enum Contrast {
    struct RGB: Hashable {
        let r: UInt8, g: UInt8, b: UInt8
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ color: RGB) -> Double {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    /// The window's background in that appearance.
    static func windowBackground(_ scheme: ColorScheme) -> RGB {
        var color = RGB(r: 0, g: 0, b: 0)
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let srgb = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                color = RGB(r: UInt8((srgb.redComponent * 255).rounded()), g: UInt8((srgb.greenComponent * 255).rounded()),
                            b: UInt8((srgb.blueComponent * 255).rounded()))
            }
        }
        return color
    }
}
