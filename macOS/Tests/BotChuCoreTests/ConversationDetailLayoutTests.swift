import Testing
@testable import BotChuCore

@Suite struct ConversationDetailLayoutTests {
    /// #407: the Project Areas column is always beside the chat, so the minimum is the same for a
    /// bot with areas or none, and the owner's saved width is kept within its range.
    @Test func theAreasColumnIsIncludedBeforeReservingTheInspector() {
        typealias L = ConversationDetailLayout
        for (saved, expected) in [(100.0, 500.0), (240, 540), (320, 620), (500, 620)] {
            let chat = L.conversationMinimum(areasWidth: saved)
            #expect(chat == expected)
            #expect(L.minimum(conversation: chat, showsInspector: true) == expected + 281)
            #expect(L.minimum(conversation: chat, showsInspector: false) == expected)
        }
    }

    @Test func restoredInspectorWidthsRemainUsable() {
        typealias L = ConversationDetailLayout
        #expect(L.clampedInspector(150) == 280)
        #expect(L.clampedInspector(340) == 340)
        #expect(L.clampedInspector(700) == 380)
        #expect(L.clampedInspector(.nan) == 380)
    }

    /// #437: the native window split carries over the sidebar SwiftUI's split left, as AppKit saved it
    /// on this Mac, and from then on lets AppKit restore its own.
    @Test func theSidebarOpensAsItWasLeft() {
        typealias L = WindowSidebarLayout
        let swiftUI = ["0.000000, 0.000000, 268.500000, 960.000000, NO, NO", "268.500000, 0.000000, 1643.500000, 960.000000, NO, NO"]
        #expect(L.initial(saved: nil, legacy: swiftUI) == .init(width: 268.5, collapsed: false))
        #expect(L.initial(saved: ["0, 0, 300, 960, NO, NO"], legacy: swiftUI) == nil)
        #expect(L.initial(saved: nil, legacy: nil) == .init(width: 240, collapsed: false))
        #expect(L.saved(frames: ["0.000000, 0.000000, 0.000000, 960.000000, YES, NO"]) == .init(width: 240, collapsed: true))
        #expect(L.saved(frames: ["0, 0, 900, 960, NO, NO"])?.width == 320)
        #expect(L.saved(frames: ["0, 0, 90, 960, NO, NO"])?.width == 210)
        #expect(L.saved(frames: ["garbage"]) == nil)
        #expect(L.saved(frames: []) == nil)
        #expect(L.defaultsKey(autosaveName: L.legacyAutosaveName) == "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView")
    }
}
