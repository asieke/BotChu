import AppKit
import SwiftUI
import BotChuCore

/// Only the conversation/inspector pair has a native split. The window's original navigation
/// sidebar, galleries, toolbar and sheet presentation remain in the same SwiftUI scene (#354).
struct NativeConversationColumns: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showsStatus") private var showsStatus = true
    @State private var inspectorWidth = ConversationDetailLayout.inspectorWidth
    @AppStorage(ProjectAreasColumnSettings.widthKey) private var areasWidth = ConversationColumnLayout.width

    var body: some View {
        // The Project Areas column is always beside the chat (#402), whether the bot has areas or not.
        let minimum = ConversationDetailLayout.conversationMinimum(areasWidth: areasWidth)
        ConversationNativeSplit(model: model, conversationMinimum: minimum, showsInspector: showsStatus,
                                inspectorWidth: ConversationDetailLayout.clampedInspector(inspectorWidth), reduceMotion: reduceMotion,
                                resized: { inspectorWidth = $0 }, collapsed: { showsStatus = !$0 })
            .frame(minHeight: 520)
            // The native split owns the full-height detail. Its child hosts retain their normal
            // safe areas, applying the window toolbar inset once rather than to a nested split.
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: showsStatus) { _, shown in FrameTimings.mark(FrameMarks.inspector(shown: shown)) }
    }
}

/// Each host observes its current conversation itself; assigning a new root on every parent
/// preference write would recreate the invalidation work this split removes.
private struct LiveConversationPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.visibleBotID, model.bot(id) != nil {
            let target = model.tab(of: id)
            ConversationSplit(botID: id) {
                ChatView(target: target)
                    .id(target)
                    .onAppear { model.hydrate(target) }
            }
        }
    }
}

private struct LiveInspectorPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.visibleBotID, model.bot(id) != nil {
            let target = model.tab(of: id)
            // An area, a task or a job run (#405); Home keeps the bot's.
            if target.taskID != nil { ConversationInspector(target: target).id(target) }
            else { BotInspector(botID: id) }
        }
    }
}

private struct ConversationNativeSplit: NSViewControllerRepresentable {
    let model: AppModel
    let conversationMinimum: Double
    let showsInspector: Bool
    let inspectorWidth: Double
    let reduceMotion: Bool
    let resized: (Double) -> Void
    let collapsed: (Bool) -> Void

    func makeNSViewController(context: Context) -> NativeConversationSplitController {
        NativeConversationSplitController(model: model, minimum: conversationMinimum,
                                          inspectorWidth: inspectorWidth, showsInspector: showsInspector)
    }

    func updateNSViewController(_ controller: NativeConversationSplitController, context: Context) {
        controller.resized = resized
        controller.collapsed = collapsed
        controller.configure(minimum: conversationMinimum, inspectorWidth: inspectorWidth,
                             showsInspector: showsInspector, animated: !reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeConversationSplitController, context: Context) -> CGSize? {
        let minimum = max(ConversationDetailLayout.minimum(conversation: conversationMinimum, showsInspector: showsInspector),
                          nsViewController.minimumWidth(conversationMinimum: conversationMinimum, showsInspector: showsInspector))
        return CGSize(width: max(minimum, proposal.width ?? minimum), height: proposal.height ?? 800)
    }
}

/// The inspector keeps its preferred width when a smaller window temporarily compresses it.
/// Dragging remembers the width only after the gesture. Like the original inspector, leaving the
/// conversation for a gallery resets that width; no new persistent preference is introduced.
@MainActor final class NativeConversationSplitController: NSSplitViewController {
    private let conversation: NSSplitViewItem
    private let inspector: NSSplitViewItem
    private let nativeSplit = DividerTrackingSplitView()
    private var widthPreference: NSLayoutConstraint?
    private var preferredWidth: Double
    private var trackingDivider = false
    private var desiredInspectorVisibility: Bool
    private var collapseObservation: NSKeyValueObservation?
    var resized: ((Double) -> Void)?
    var collapsed: ((Bool) -> Void)?

    init(model: AppModel, minimum: Double, inspectorWidth: Double, showsInspector: Bool) {
        let store = model.settings.preferenceStore
        let chatHost = NativeColumnHost(rootView: LiveConversationPane().environment(model).defaultAppStorage(store).frame(maxWidth: .infinity, maxHeight: .infinity), sizingOptions: .minSize)
        let inspectorHost = NativeColumnHost(rootView: LiveInspectorPane().environment(model).defaultAppStorage(store).frame(maxWidth: .infinity, maxHeight: .infinity))
        conversation = NSSplitViewItem(viewController: chatHost)
        conversation.minimumThickness = minimum
        conversation.holdingPriority = NSLayoutConstraint.Priority(rawValue: 248)
        inspector = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        inspector.minimumThickness = ConversationDetailLayout.inspectorWidths.lowerBound
        inspector.maximumThickness = ConversationDetailLayout.inspectorWidths.upperBound
        inspector.holdingPriority = NSLayoutConstraint.Priority(rawValue: 249)
        inspector.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspector.canCollapseFromWindowResize = false
        inspector.isCollapsed = !showsInspector
        preferredWidth = inspectorWidth
        desiredInspectorVisibility = showsInspector
        super.init(nibName: nil, bundle: nil)
        let split = nativeSplit
        split.identifier = NSUserInterfaceItemIdentifier("conversation-detail-split")
        split.isVertical = true
        split.dividerStyle = .thin
        split.started = { [weak self] in
            guard let self else { return }
            self.trackingDivider = true
            self.widthPreference?.isActive = false
        }
        split.ended = { [weak self] moved in
            self?.finishedDragging(moved: moved)
        }
        splitView = split
        addSplitViewItem(conversation)
        addSplitViewItem(inspector)
        if showsInspector { installWidthPreference() }
        collapseObservation = inspector.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let hidden = change.newValue else { return }
            MainActor.assumeIsolated { self?.nativeCollapseChanged(hidden) }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(model:minimum:inspectorWidth:showsInspector:)") }

    /// The composer can require more than the chat's floor (provider/effort/Fast controls).
    /// Use the hosting view's published minimum, not its current stretched frame or ideal width.
    func minimumWidth(conversationMinimum: Double, showsInspector: Bool) -> Double {
        let content = max(conversationMinimum, Double(conversation.viewController.view.fittingSize.width))
        return content + (showsInspector ? Double(inspector.minimumThickness + splitView.dividerThickness) : 0)
    }

    func configure(minimum: Double, inspectorWidth: Double, showsInspector: Bool, animated: Bool) {
        if conversation.minimumThickness != minimum { conversation.minimumThickness = minimum }
        preferredWidth = inspectorWidth
        desiredInspectorVisibility = showsInspector
        if showsInspector { installWidthPreference() }
        if widthPreference?.constant != CGFloat(inspectorWidth) { widthPreference?.constant = inspectorWidth }
        widthPreference?.isActive = showsInspector && !trackingDivider
        if inspector.isCollapsed == showsInspector {
            if animated { inspector.animator().isCollapsed = !showsInspector }
            else { inspector.isCollapsed = !showsInspector }
        }
    }

    private func installWidthPreference() {
        guard widthPreference == nil else { return }
        let constraint = inspector.viewController.view.widthAnchor.constraint(equalToConstant: preferredWidth)
        // The window's required geometry may compress this preference, and a native divider drag
        // must win over it. Holding priorities remain lower so the conversation takes extra space.
        constraint.priority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.dragThatCannotResizeWindow.rawValue - 1)
        widthPreference = constraint
        constraint.isActive = !trackingDivider
    }

    private func nativeCollapseChanged(_ hidden: Bool) {
        if !hidden { installWidthPreference() }
        widthPreference?.isActive = !hidden && !trackingDivider
        guard desiredInspectorVisibility == hidden else { return }
        desiredInspectorVisibility = !hidden
        collapsed?(hidden)
    }

    private func finishedDragging(moved: Bool) {
        trackingDivider = false
        let hidden = inspector.isCollapsed
        if moved, !hidden {
            preferredWidth = ConversationDetailLayout.clampedInspector(splitView.arrangedSubviews.last.map { Double($0.frame.width) } ?? preferredWidth)
            widthPreference?.constant = preferredWidth
            resized?(preferredWidth)
        }
        widthPreference?.isActive = !hidden
    }
}

/// The native inspector adds a container around its child. Pin the hosting view explicitly so its
/// content follows that container instead of retaining the hosting view's initial fitting size.
@MainActor private final class NativeColumnHost<Content: View>: NSViewController {
    private let host: NSHostingController<Content>

    init(rootView: Content, sizingOptions: NSHostingSizingOptions = []) {
        host = NSHostingController(rootView: rootView)
        host.sizingOptions = sizingOptions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    override func loadView() {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        view = container
        addChild(host)
        let content = host.view
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

private final class DividerTrackingSplitView: NSSplitView {
    private var trackingMouse = false
    var started: (() -> Void)?
    var ended: ((Bool) -> Void)?

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        guard !trackingMouse else {
            super.setPosition(position, ofDividerAt: dividerIndex)
            return
        }
        let before = arrangedSubviews.last?.frame.width
        started?()
        super.setPosition(position, ofDividerAt: dividerIndex)
        let moved = before != arrangedSubviews.last?.frame.width
        // Publish the requested width before laying out, while the preferred-width constraint is
        // still suspended; otherwise the old preference would undo an accessibility adjustment.
        ended?(moved)
        if moved {
            // A divider can move during this split's layout pass. Finish its already-constrained
            // descendants synchronously, so their content has the new size in this same frame.
            for pane in arrangedSubviews where !isSubviewCollapsed(pane) {
                pane.needsLayout = true
                pane.layoutSubtreeIfNeeded()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        trackingMouse = true
        started?()
        super.mouseDown(with: event)
        trackingMouse = false
        let moved = NSApp.currentEvent.map { abs($0.locationInWindow.x - event.locationInWindow.x) > 0.5 } ?? false
        ended?(moved)
    }
}
