import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// A view whose body reads an `@AppStorage` value is evaluated again at every UserDefaults write,
    /// whatever its key: AppKit's split views save their widths there as the sidebar shows, and the
    /// status sidebar's toggle saves itself. The conversation shown reads none, so such writes leave
    /// its transcript alone (#348), and the status sidebar still shows and hides with its setting.
    @Test func settingsWritesLeaveTheShownTranscriptAlone() async throws {
        _ = NSApplication.shared
        let fixture = try InboxStatusFixture()
        defer { fixture.cleanUp() }
        try await fixture.ready()
        let app = fixture.app, target = ChatTarget.home(fixture.bots[0].id)
        app.selectSidebar(.bot(target.botID))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: ContentView().environment(app).defaultAppStorage(fixture.defaults))
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<100 where !app.conversation(target).isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let transcript = TranscriptCache.model(for: target)
        // SwiftUI evaluates a view that reads a setting once more at the first write after it shows.
        fixture.defaults.set(0, forKey: "settings.unrelated")
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        let drawn = transcript.evaluations
        #expect(drawn > 0)
        for n in 1...3 {
            fixture.defaults.set(n, forKey: "settings.unrelated")
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
        }
        #expect(transcript.evaluations == drawn, "An unrelated UserDefaults write redrew the transcript")

        func inspectorShown() -> Bool {
            func splitViews(in view: NSView) -> [NSSplitView] {
                ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
            }
            // The status sidebar is its split view's last column, 280 to 380 points wide while it shows.
            return splitViews(in: window.contentView!).contains { split in
                guard split.arrangedSubviews.count > 1, let last = split.arrangedSubviews.last else { return false }
                return !last.isHidden && !split.isSubviewCollapsed(last) && (279...381).contains(last.frame.width)
            }
        }
        #expect(inspectorShown())
        fixture.defaults.set(false, forKey: "showsStatus")
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        #expect(!inspectorShown())
        fixture.defaults.set(true, forKey: "showsStatus")
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        #expect(inspectorShown())
    }

    /// Selecting another bot redraws only the rows whose selection changed: the one it leaves and the
    /// one it selects, not every bot's row, status and summary (#348, journey 3). An unrelated
    /// UserDefaults write updates neither the rows nor the list around them.
    @Test func selectingABotRedrawsOnlyTheTwoRowsWhoseSelectionChanged() async throws {
        _ = NSApplication.shared
        let fixture = try InboxStatusFixture()
        defer { fixture.cleanUp() }
        try await fixture.ready()
        let app = fixture.app, first = fixture.bots[0].id, second = fixture.bots[3].id
        app.selectSidebar(.bot(first))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 1_400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var bodies: [UUID: Int] = [:], lists = 0
        SidebarStatusDiagnostics.didEvaluateRow = { bodies[$0, default: 0] += 1 }
        SidebarStatusDiagnostics.didEvaluateList = { lists += 1 }
        defer { SidebarStatusDiagnostics.didEvaluateRow = nil; SidebarStatusDiagnostics.didEvaluateList = nil }
        window.contentView = NSHostingView(rootView: SidebarView().environment(app).defaultAppStorage(fixture.defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        #expect(bodies.count > 2, "The rows showed: \(bodies)")
        bodies.removeAll()
        app.selectSidebar(.bot(second))
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(Set(bodies.keys) == [first, second], "Only the two rows whose selection changed redraw: \(bodies)")

        // SwiftUI evaluates a view that reads a setting once more at the first write after it shows.
        fixture.defaults.set(0, forKey: "settings.unrelated")
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        bodies.removeAll()
        lists = 0
        for n in 1...3 {
            fixture.defaults.set(n, forKey: "settings.unrelated")
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
        }
        #expect(bodies.isEmpty, "An unrelated UserDefaults write redrew sidebar rows: \(bodies)")
        #expect(lists == 0, "An unrelated UserDefaults write evaluated the sidebar's list \(lists) times")

        // Its sections still open and close with their settings.
        fixture.defaults.set(true, forKey: "sidebar.specialistsExpanded")
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        #expect(lists > 0, "Opening the specialists didn't update the sidebar's list")
    }
}
