import Testing
@testable import BotChuCore

@Suite struct ConversationDetailLayoutTests {
    @Test func taskColumnAndRailAreIncludedBeforeReservingTheInspector() {
        typealias L = ConversationDetailLayout
        #expect(L.conversationMinimum(hasTasks: false, collapsed: false, taskWidth: 320) == 300)
        #expect(L.conversationMinimum(hasTasks: true, collapsed: true, taskWidth: 320) == 356)
        for (saved, expected) in [(100.0, 500.0), (240, 540), (320, 620), (500, 620)] {
            let chat = L.conversationMinimum(hasTasks: true, collapsed: false, taskWidth: saved)
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
}
