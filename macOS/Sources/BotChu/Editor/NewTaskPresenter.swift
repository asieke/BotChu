import AppKit
import SwiftUI
import Observation
import BotChuCore

extension TaskSheetRequest {
    /// Project/issue/PR requests retain SwiftUI's normal sheet lifecycle.
    var usesPreparedSheet: Bool { repo == nil && work == nil && purpose == .work && brief.isEmpty }
}

/// Read presentation state here, rather than invalidating the whole ContentView on open/close.
struct NewTaskPresentationModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let fallback = model.taskSheet.flatMap { $0.usesPreparedSheet ? nil : $0 }
        content
            .background { NewTaskPresenter() }
            .sheet(item: Binding(get: { fallback }, set: { replacement in
                // A delayed custom-sheet dismissal must not withdraw a newer blank request.
                if model.taskSheet?.id == fallback?.id { model.taskSheet = replacement }
            })) { request in
                NewTaskSheet(botID: request.botID, initialRepo: request.repo, initialWork: request.work,
                             initialPurpose: request.purpose, initialBrief: request.brief)
                    .environment(model)
            }
    }
}

/// Keeps one blank task form ready for this window's selected bot. Each dismissal discards its
/// draft, images, completion and async work; only the native window is reused (#353).
struct NewTaskPresenter: View {
    @Environment(AppModel.self) private var model
    @AppStorage("newTaskRepo") private var lastRepo = ""

    var body: some View {
        let wanted = DevHooks.dataDir == nil ? lastRepo : DevHooks.env["BOTCHU_TASK_REPO"] ?? ""
        TaskSheetWindow(model: model, request: model.taskSheet.flatMap { $0.usesPreparedSheet ? $0 : nil },
                        preferredBotID: model.selection.flatMap { model.bot($0)?.canOwnTasks == true ? $0 : nil },
                        rememberedRepo: wanted,
                        cachedRepo: model.repositories?.first(where: { $0.nameWithOwner == wanted })?.nameWithOwner,
                        remember: { lastRepo = $0 })
            .frame(width: 0, height: 0)
    }
}

/// Native presentation supplies an explicit dismissal and repository preference. The small outer
/// view owns AppStorage; the new window inherits its own live system environment, not the parent
/// split view's presentation, shape, enabled or activation state.
@MainActor @Observable final class TaskSheetPresentation {
    var shown = false
    let rememberedRepo: String
    let remember: (String) -> Void
    let close: (TaskSheetPresentation) -> Void
    @ObservationIgnored weak var window: NSWindow?

    init(rememberedRepo: String, remember: @escaping (String) -> Void,
         close: @escaping (TaskSheetPresentation) -> Void) {
        self.rememberedRepo = rememberedRepo
        self.remember = remember
        self.close = close
    }
}

private struct TaskSheetWindow: NSViewRepresentable {
    let model: AppModel
    var request: TaskSheetRequest?
    let preferredBotID: UUID?
    let rememberedRepo: String
    let cachedRepo: String?
    let remember: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return anchor
    }

    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.update(self)
        context.coordinator.attach(view.window)
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.stop() }

    final class Anchor: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }

    private struct Preparation: Equatable {
        let botID: UUID
        let rememberedRepo: String
        let cachedRepo: String?
    }

    @MainActor final class Coordinator {
        private weak var parent: NSWindow?
        private var configuration: TaskSheetWindow?
        private var sheet: NSWindow?
        private var prepared: Preparation?
        private var presentation: TaskSheetPresentation?
        private var presentedID: UUID?
        private var closing = false
        private var stopped = false
        private var preparation: Task<Void, Never>?
        private var preparing: Preparation?
        private var reconciliationScheduled = false
        private var observations: [NSObjectProtocol] = []
        private var activityMonitor: Any?
        private var lastActivity = ProcessInfo.processInfo.systemUptime

        func update(_ configuration: TaskSheetWindow) {
            self.configuration = configuration
            scheduleReconciliation()
        }

        func attach(_ window: NSWindow?) {
            guard !stopped, parent !== window else { return }
            if parent != nil { stop(); return }
            guard let window else { return }
            parent = window
            lastActivity = ProcessInfo.processInfo.systemUptime
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .keyDown, .keyUp, .flagsChanged, .scrollWheel,
                .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                .otherMouseDown, .otherMouseUp, .otherMouseDragged
            ]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, let parent = self.parent, event.window === parent {
                        self.lastActivity = ProcessInfo.processInfo.systemUptime
                    }
                    return event
                }
            }
            observations = [
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stop() }
                },
                NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.reconcile() }
                }
            ]
            scheduleReconciliation()
        }

        private func scheduleReconciliation() {
            guard !reconciliationScheduled else { return }
            reconciliationScheduled = true
            Task { @MainActor [weak self] in
                self?.reconciliationScheduled = false
                self?.reconcile()
            }
        }

        private var wanted: Preparation? {
            guard let configuration, let botID = configuration.request?.botID ?? configuration.preferredBotID,
                  configuration.model.bot(botID)?.canOwnTasks == true else { return nil }
            return Preparation(botID: botID, rememberedRepo: configuration.rememberedRepo, cachedRepo: configuration.cachedRepo)
        }

        private func reconcile() {
            guard !stopped, !closing, let parent, let configuration else { return }
            if let presentedID {
                if configuration.model.taskSheet?.id != presentedID { end() }
                return
            }
            guard parent.attachedSheet == nil, configuration.request?.id == configuration.model.taskSheet?.id else { return }
            guard let wanted else { discardForm(); return }
            guard let request = configuration.request else {
                // Debounce browsing; preparing a different bot must not delay its first chat frame.
                if prepared != wanted, preparing != wanted {
                    preparation?.cancel()
                    preparing = wanted
                    preparation = Task { @MainActor [weak self] in
                        var delay: Duration = .milliseconds(250)
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: delay) } catch { return }
                            guard !Task.isCancelled, let next = self?.prepareWhenIdle(wanted) else { return }
                            delay = next
                        }
                    }
                }
                return
            }
            preparation?.cancel()
            preparation = nil
            preparing = nil
            if prepared != wanted { prepare(wanted) }
            guard let sheet, let presentation else { return }
            presentedID = request.id
            presentation.shown = true
            // beginSheet runs a nested animation loop: a Swift task resumes only afterward. The
            // existing committed-frame observer checks actual visibility, attachment and focus in
            // that loop, so hidden preparation and animation completion cannot masquerade as ready.
            FrameTimings.mark(FrameMarks.newTask, when: { [weak presentation] in
                guard let presentation, presentation.shown, let window = presentation.window else { return nil }
                return window.isVisible && window.sheetParent != nil
                    && (window.firstResponder as? ComposerTextView)?.accessibilityIdentifier() == "task-brief"
            })
            // Keep cleanup alive through dismissal, but release its owner before reusing the
            // window: AppKit may keep a completed sheet callback until the next presentation.
            let completion = DismissalCompletion(owner: self)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                parent.beginSheet(sheet) { _ in completion.finish() }
            }
        }

        @MainActor private final class DismissalCompletion {
            private var owner: Coordinator?
            init(owner: Coordinator) { self.owner = owner }
            func finish() {
                let current = owner
                owner = nil
                current?.finished()
            }
        }

        /// Input monitoring records time only; form construction waits until this window is quiet.
        /// A requested sheet bypasses this timer in reconcile().
        private func prepareWhenIdle(_ key: Preparation) -> Duration? {
            guard preparing == key else { return nil }
            guard !stopped, let current = configuration, let parent,
                  current.model.taskSheet == nil, current.model.selection == key.botID,
                  current.request == nil, wanted == key, parent.attachedSheet == nil else {
                preparing = nil
                preparation = nil
                return nil
            }
            let remaining = 0.25 - (ProcessInfo.processInfo.systemUptime - lastActivity)
            if remaining > 0 { return .seconds(remaining) }
            if parent.inLiveResize || NSEvent.pressedMouseButtons != 0
                || (parent.firstResponder as? NSTextInputClient)?.hasMarkedText() == true {
                return .milliseconds(250)
            }
            preparing = nil
            preparation = nil
            prepare(key)
            return nil
        }

        private func prepare(_ key: Preparation) {
            guard let configuration else { return }
            discardForm()
            let state = TaskSheetPresentation(rememberedRepo: key.rememberedRepo,
                remember: { [weak self] in self?.configuration?.remember($0) },
                close: { [weak self] in self?.close($0) })
            let form = NewTaskSheet(botID: key.botID, cachedRepo: key.cachedRepo, presentation: state)
                .environment(configuration.model)
            let controller = NSHostingController(rootView: form)
            // This form has one fixed content size; no min/ideal/max window-size probes are needed.
            controller.sizingOptions = []
            let window = sheet ?? NSWindow(contentViewController: controller)
            window.styleMask = [.titled]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 560, height: 720))
            sheet = window
            state.window = window
            presentation = state
            prepared = key
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        private func close(_ presentation: TaskSheetPresentation) {
            guard self.presentation === presentation, let presentedID, let configuration else { return }
            if configuration.model.taskSheet?.id == presentedID { configuration.model.taskSheet = nil }
            if self.configuration?.request?.id == presentedID { self.configuration?.request = nil }
            // Let updateNSView reconcile dismissal after SwiftUI has processed the request and
            // selected task. Ending the sheet inside Start's action blocks that parent update
            // in AppKit's closing animation loop.
        }

        private func end() {
            guard !closing, let sheet else { return }
            closing = true
            presentation?.shown = false
            if let parent = sheet.sheetParent { parent.endSheet(sheet) }
            else { finished() }
        }

        private func finished() {
            sheet?.orderOut(nil)
            presentedID = nil
            closing = false
            discardForm()
            if stopped {
                sheet?.close()
                sheet = nil
            } else {
                // Start the next request (or prepare its blank form) after the closing animation.
                scheduleReconciliation()
            }
        }

        private func discardForm() {
            sheet?.makeFirstResponder(nil)
            sheet?.undoManager?.removeAllActions()
            sheet?.contentViewController = nil
            presentation = nil
            prepared = nil
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
            activityMonitor = nil
            preparation?.cancel()
            preparation = nil
            for observation in observations { NotificationCenter.default.removeObserver(observation) }
            observations.removeAll()
            if let presentedID, configuration?.model.taskSheet?.id == presentedID { configuration?.model.taskSheet = nil }
            if presentedID != nil || closing {
                // sheetParent can be nil before AppKit calls the dismissal completion.
                // That completion still owns the visible form and its window until it finishes.
                end()
            } else {
                discardForm()
                sheet?.close()
                sheet = nil
            }
            parent = nil
        }
    }
}
