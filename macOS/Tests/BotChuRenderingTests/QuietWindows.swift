import AppKit
import ObjectiveC

extension NSWindow {
    /// Once swapped in, what `order(_:relativeTo:)` does: `makeKeyAndOrderFront`, `orderFront`,
    /// `setIsVisible` and sheets all end here.
    @objc fileprivate func botchuQuietOrder(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { QuietWindows.quiet(self) }
        botchuQuietOrder(place, relativeTo: other)  // the original, after the swap
    }

    /// Once swapped in, what `orderFrontRegardless` does: it alone goes around `order`.
    @objc fileprivate func botchuQuietOrderFrontRegardless() {
        QuietWindows.quiet(self)
        botchuQuietOrderFrontRegardless()
    }
}

/// Window tests show their windows fully transparent and deaf to the real mouse, so a run never
/// covers what the owner is doing or catches their clicks. Nothing the tests check depends on being
/// seen: they lay out, draw (`cacheDisplay`) and take events sent to the window as before, and
/// under the test runner WebKit already counts every window as hidden. A test that needs the window
/// server's own picture shows its window again itself. `BOTCHU_SHOW_TEST_WINDOWS=1` shows them all.
@MainActor enum QuietWindows {
    private static let isOn = ProcessInfo.processInfo.environment["BOTCHU_SHOW_TEST_WINDOWS"] != "1"

    /// Swaps once per process; the window tests' suite asks for it before each test.
    static let install: Void = {
        for (original, quiet) in [(#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.botchuQuietOrder(_:relativeTo:))),
                                  (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.botchuQuietOrderFrontRegardless))] {
            method_exchangeImplementations(class_getInstanceMethod(NSWindow.self, original)!,
                                           class_getInstanceMethod(NSWindow.self, quiet)!)
        }
    }()

    fileprivate static func quiet(_ window: NSWindow) {
        guard isOn else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
    }
}
