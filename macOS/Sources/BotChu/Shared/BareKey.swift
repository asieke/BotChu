import AppKit
import SwiftUI
import WebKit

/// A letter pressed alone, without modifiers, in the window this view is in, such as I in Projects
/// (#245). It reaches its action before the view with the keyboard (a table would take it to select
/// a row by its name), but never while text is typed (a search, a field, a page) or a sheet or
/// modal is open, when the key goes on as usual.
struct BareKey: NSViewRepresentable {
    let key: Character
    let action: () -> Void

    init(_ key: Character, action: @escaping () -> Void) {
        self.key = key
        self.action = action
    }

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.key = key
        view.action = action
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.key = key
        view.action = action
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

    final class KeyView: NSView {
        var key: Character = " "
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.takes(event) else { return event }
                self.action()
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func takes(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !event.isARepeat,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
                  event.charactersIgnoringModifiers?.lowercased() == String(key).lowercased(),
                  NSApp.modalWindow == nil, window.attachedSheet == nil else { return false }
            var view = window.firstResponder as? NSView
            while let current = view {
                if current is NSText || current is WKWebView { return false }
                view = current.superview
            }
            return true
        }
    }
}
