import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// The main window's split view needs more width as its sidebar and status widen (it counts the
/// sidebar twice). In a window narrower than that, SwiftUI lays the columns out forever and AppKit
/// aborts, so a regression ends this test run with a crash rather than a failed expectation.
extension RenderingTests {
    @Test func windowIsNeverNarrowerThanItsColumnsNeed() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-window-\(UUID().uuidString)", isDirectory: true)
        let suite = "local.BotChu.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let bot = Bot(name: "Scout", workspace: root.appendingPathComponent("Scout").path)
        try BotHome(workspace: bot.workspace).save(bot)
        let store = Store(root: root.appendingPathComponent("Support", isDirectory: true))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                             usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })

        // Restored at the old fixed minimum, with the status shown.
        let host = NSHostingView(rootView: ContentView().environment(model).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        #expect(window.frame.width >= window.contentMinSize.width)

        // The sidebar and the status as wide as they go, then the window as narrow as it lets itself be.
        let splits = splitViews(in: host)
        try #require(splits.count == 2)
        splits[0].setPosition(320, ofDividerAt: 0)
        try await settle(window)
        splits[1].setPosition(splits[1].frame.width - 380, ofDividerAt: 0)
        try await settle(window)
        window.setFrame(NSRect(x: 0, y: 0, width: 820, height: 600), display: true)
        try await settle(window)
        #expect(window.frame.width >= window.contentMinSize.width)

        // Changing the model or effort can change the new controls' labels while already narrow.
        model.setModel("custom-model-with-a-long-account-specific-name", for: .home(bot.id))
        model.setReasoningEffort(.max, for: .home(bot.id))
        try await settle(window)
        #expect(window.frame.width >= window.contentMinSize.width)

        // Hidden and shown again in a narrow window.
        defaults.set(false, forKey: "showsStatus")
        try await settle(window)
        window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 600), display: true)
        try await settle(window)
        defaults.set(true, forKey: "showsStatus")
        try await settle(window)
        #expect(window.frame.width >= window.contentMinSize.width)
    }

    /// Runs the window's layout and a few turns of the run loop, where AppKit lays it out again.
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            window.updateConstraintsIfNeeded()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
    }
}
