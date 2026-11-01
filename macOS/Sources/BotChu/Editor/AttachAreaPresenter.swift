import AppKit
import SwiftUI
import BotChuCore

/// Shows Attach Project Area in one window as a native sheet (#438). Its form is made ahead while
/// the Mac is idle, so `+` only orders the sheet in; each opening uses a form never shown before,
/// told its bot and repositories as it opens, and the next one is made after it closes. The sheet
/// takes the keyboard in the pass after its first frame: losing key status makes the window's
/// SwiftUI views update (about 30 ms on the journeys' fixture), which would otherwise come
/// before the sheet shows at all.
@MainActor final class AttachAreaPresenter {
    private weak var parent: NSWindow?
    private weak var model: AppModel?
    private var botID: UUID?
    private var state = AttachAreaPresentation()
    private var prepared: Sheet?
    private var shown: (request: UUID, sheet: Sheet)?
    private var preparation: Timer?

    private struct Sheet {
        let form: AttachAreaForm
        let window: AttachAreaSheetWindow
    }

    /// Run loop modes for the steps after a frame: the common ones, and the one AppKit runs the
    /// main thread in while a sheet slides in (as `FrameTimings`).
    private static let modes = [CFRunLoopMode.commonModes, CFRunLoopMode("_NSMoveTimerRunLoopMode" as CFString)]
    /// The first form waits this long after its window shows, out of the way of launch.
    private static let firstDelay: TimeInterval = 2
    /// How long the Mac has had no input before a form is made.
    private static let idleInput: TimeInterval = 0.25

    /// The model and bot of the Project Areas column the sheet belongs to.
    func update(model: AppModel, botID: UUID) {
        self.model = model
        self.botID = botID
    }

    /// The window the column is in now; nil when it left it.
    func attach(to window: NSWindow?) {
        guard window !== parent else { return }
        stop()
        parent = window
        if window != nil { prepare(after: Self.firstDelay) }
    }

    /// Ends what shows and forgets what was made, as when the column leaves its window.
    func stop() {
        preparation?.invalidate()
        preparation = nil
        if let shown, let parent, parent.attachedSheet === shown.sheet.window { parent.endSheet(shown.sheet.window) }
        shown?.sheet.window.orderOut(nil)
        shown = nil
        prepared = nil
        state.reset()
    }

    /// Opens the sheet for the bot, with the form made ahead (or one made now when none is ready).
    func present(botID: UUID) {
        guard let parent, let model, parent.attachedSheet == nil else { return }
        var made: Sheet?
        guard let opening = state.open(cold: {
            let sheet = makeSheet(model: model)
            made = sheet
            return sheet.form.id
        }()), let sheet = opening.wasPrepared ? prepared : made else { return }
        prepared = nil
        preparation?.invalidate()
        shown = (opening.request, sheet)
        sheet.form.show(for: botID, in: model)
        sheet.form.close = { [weak self] in self?.close(opening.request) }
        let window = sheet.window
        FrameTimings.mark(FrameMarks.attachArea) { [weak self] in
            guard self?.shown?.request == opening.request else { return nil }
            return window.isVisible ? true : false
        }
        afterFrame(when: { [weak self] in self?.shown?.request == opening.request ? window.isVisible : nil }) { [weak self] _ in
            guard self?.shown?.request == opening.request else { return }
            window.takeKey()
            sheet.form.isKey = true
        }
        // After the button's action returns: the sheet's opening runs a run loop of its own.
        Self.perform { [weak self] in
            guard let self, self.shown?.request == opening.request else { return }
            // Another sheet came first: this opening ends without showing.
            guard parent.attachedSheet == nil else { return self.ended(opening.request) }
            parent.beginSheet(window) { [weak self] _ in self?.ended(opening.request) }
        }
    }

    /// Closes the opening `request`, whether by Cancel, Escape or attaching; a later call for an
    /// opening that already closed does nothing.
    private func close(_ request: UUID) {
        guard let shown, shown.request == request, let parent else { return }
        let window = shown.sheet.window
        // After the frame showing what closing it did, such as the area attached.
        afterFrame { _ in
            if parent.attachedSheet === window { parent.endSheet(window) }
        }
    }

    /// The sheet has gone: its form and window are let go, and the next opening's made.
    private func ended(_ request: UUID) {
        guard state.close(request), let shown else { return }
        shown.sheet.window.orderOut(nil)
        self.shown = nil
        prepare(after: 0)
    }

    private func prepare(after delay: TimeInterval) {
        preparation?.invalidate()
        // A timer in the default mode waits out a drag, a resize or a menu.
        preparation = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareWhenIdle() }
        }
    }

    private func prepareWhenIdle() {
        guard state.needsPreparation, parent != nil, let model else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.idleInput else { return prepare(after: Self.idleInput) }
        let sheet = makeSheet(model: model)
        if let botID { sheet.form.show(for: botID, in: model) }
        prepared = sheet
        state.prepared(sheet.form.id)
    }

    private func makeSheet(model: AppModel) -> Sheet {
        let form = AttachAreaForm()
        let host = NSHostingController(rootView: AttachAreaSheet(form: form).environment(model))
        let window = AttachAreaSheetWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.title = "Attach Project Area"
        window.isReleasedWhenClosed = false
        window.cancel = { form.close() }
        window.layoutIfNeeded()
        return Sheet(form: form, window: window)
    }

    /// Runs `step` in the pass after the next frame committed once `ready` says so (`window`
    /// on screen, say); `ready` returning nil gives up.
    private func afterFrame(when ready: @escaping @MainActor () -> Bool? = { true }, _ step: @escaping @MainActor (Void) -> Void) {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                guard let shows = ready() else {
                    if let observer { CFRunLoopObserverInvalidate(observer) }
                    return
                }
                guard shows else { return }
                if let observer { CFRunLoopObserverInvalidate(observer) }
                Self.perform { step(()) }
            }
        }
        if let observer { for mode in Self.modes { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode) } }
    }

    private static func perform(_ step: @escaping @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes.compactMap { $0?.rawValue } as CFArray) { MainActor.assumeIsolated { step() } }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// Attach Project Area's sheet window: it can take the keyboard only once it is told to.
final class AttachAreaSheetWindow: NSWindow {
    private var acceptsKey = false
    var cancel: (() -> Void)?

    override var canBecomeKey: Bool { acceptsKey }

    func takeKey() {
        acceptsKey = true
        makeKey()
    }

    /// Escape, when no button takes it.
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

/// Tells the presenter which window and bot its column is in.
struct AttachAreaAnchor: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let presenter: AttachAreaPresenter
    let botID: UUID

    func makeNSView(context: Context) -> Anchor {
        presenter.update(model: model, botID: botID)
        let anchor = Anchor()
        anchor.moved = { [weak presenter] window in presenter?.attach(to: window) }
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) {
        presenter.update(model: model, botID: botID)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) {
        anchor.moved?(nil)
        anchor.moved = nil
    }

    final class Anchor: NSView {
        var moved: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moved?(window)
        }
    }
}

