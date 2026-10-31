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
}
