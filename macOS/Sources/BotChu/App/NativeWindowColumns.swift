import AppKit
import SwiftUI
import BotChuCore

/// Whether the window's sidebar shows, for the toolbar button that toggles it. Only that button
/// reads it, so a toggle updates one toolbar item and AppKit animates the split by itself (#437).
@MainActor @Observable final class WindowSidebar {
    private(set) var shown = true
    @ObservationIgnored fileprivate weak var controller: NativeWindowSplitController?

    func toggle() { controller?.toggleSidebar(nil) }

    fileprivate func changed(_ shown: Bool) {
        if self.shown != shown { self.shown = shown }
    }
}

/// The window's sidebar and detail as a native split (#437), replacing SwiftUI's navigation split:
/// opening or closing the sidebar and resizing the window move AppKit views, and SwiftUI lays out
/// only the host whose size changed, never the window's whole view graph. The detail's toolbar
/// items and title still reach the window's toolbar, through its host's scene bridging.
struct NativeWindowColumns: NSViewControllerRepresentable {
    let model: AppModel
    let sidebar: WindowSidebar
    let reduceMotion: Bool

    func makeNSViewController(context: Context) -> NativeWindowSplitController {
        let store = model.settings.preferenceStore
        return NativeWindowSplitController(
            sidebar: NativeColumnHost(rootView: SidebarView().environment(model).defaultAppStorage(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            detail: NativeColumnHost(rootView: DetailColumn().environment(model).defaultAppStorage(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity), sizingOptions: .minSize, bridgesScene: true),
            state: sidebar)
    }

    func updateNSViewController(_ controller: NativeWindowSplitController, context: Context) {
        controller.animates = !reduceMotion
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeWindowSplitController, context: Context) -> CGSize? {
        let minimum = nsViewController.minimumWidth()
        return CGSize(width: max(minimum, proposal.width ?? minimum), height: proposal.height ?? 800)
    }
}

@MainActor final class NativeWindowSplitController: NSSplitViewController {
    private let sidebarItem: NSSplitViewItem
    private let detailItem: NSSplitViewItem
    private let state: WindowSidebar
    private var collapseObservation: NSKeyValueObservation?
    /// The width to open at when AppKit has none saved yet, set once the split has a size.
    private var initialWidth: Double?
    var animates = true

    init(sidebar: NSViewController, detail: NSViewController, state: WindowSidebar) {
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = WindowSidebarLayout.widths.lowerBound
        sidebarItem.maximumThickness = WindowSidebarLayout.widths.upperBound
        sidebarItem.canCollapseFromWindowResize = false
        detailItem = NSSplitViewItem(viewController: detail)
        self.state = state
        super.init(nibName: nil, bundle: nil)
        let defaults = UserDefaults.standard
        let initial = WindowSidebarLayout.initial(
            saved: defaults.stringArray(forKey: WindowSidebarLayout.defaultsKey(autosaveName: WindowSidebarLayout.autosaveName)),
            legacy: defaults.stringArray(forKey: WindowSidebarLayout.defaultsKey(autosaveName: WindowSidebarLayout.legacyAutosaveName)))
        splitView.identifier = NSUserInterfaceItemIdentifier("window-split")
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        // AppKit saves the sidebar's width and whether it is collapsed, and restores them at launch.
        splitView.autosaveName = WindowSidebarLayout.autosaveName
        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        if let initial {
            if initial.collapsed { sidebarItem.isCollapsed = true }
            else { initialWidth = initial.width }
        }
        state.controller = self
        state.changed(!sidebarItem.isCollapsed)
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            guard let hidden = change.newValue else { return }
            MainActor.assumeIsolated { self?.collapseChanged(hidden) }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(sidebar:detail:state:)") }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let width = initialWidth, splitView.bounds.width > CGFloat(width) else { return }
        initialWidth = nil
        splitView.setPosition(CGFloat(width), ofDividerAt: 0)
    }

    /// AppKit animates the collapse, unless Reduce Motion is on.
    override func toggleSidebar(_ sender: Any?) {
        if animates { super.toggleSidebar(sender) }
        else { sidebarItem.isCollapsed.toggle() }
    }

    /// The sidebar's narrowest width while it shows, beside the detail's published minimum.
    func minimumWidth() -> Double {
        let detail = Double(detailItem.viewController.view.fittingSize.width)
        guard !sidebarItem.isCollapsed else { return detail }
        return detail + Double(sidebarItem.minimumThickness + splitView.dividerThickness)
    }

    private func collapseChanged(_ hidden: Bool) {
        state.changed(!hidden)
        // The window's minimum width changes with the sidebar; SwiftUI measures it again after
        // this frame, so the toggle's first frame waits for nothing.
        DispatchQueue.main.async { [weak self] in self?.view.invalidateIntrinsicContentSize() }
    }
}

/// The toolbar's Hide Sidebar / Show Sidebar button; the only view that reads whether it shows.
struct SidebarToggle: View {
    let sidebar: WindowSidebar

    var body: some View {
        Button { sidebar.toggle() } label: {
            Label(sidebar.shown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
        }
        .help(sidebar.shown ? "Hide Sidebar" : "Show Sidebar")
    }
}
