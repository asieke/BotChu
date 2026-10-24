import Foundation
import Testing
@testable import BotChuCore

@Suite struct BotSectionsTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    private func titles(_ sections: BotSections) -> [String] { sections.groups.map(\.title) }

    @Test func botsInNoSectionComeFirstThenEachSectionWhereItsFirstBotWas() {
        let sections = BotSections(order: [a, b, c, d, e], membership: [b: "Engineering", d: "Product", e: "Engineering"])
        #expect(sections.groups == [
            .init(name: nil, botIDs: [a, c]),
            .init(name: "Engineering", botIDs: [b, e]),
            .init(name: "Product", botIDs: [d]),
        ])
        #expect(titles(sections) == ["Conversations", "Engineering", "Product"])
        #expect(sections.order == [a, c, b, e, d])
        #expect(sections.names == ["Engineering", "Product"])
        #expect(sections.section(of: e) == "Engineering")
        #expect(sections.section(of: a) == nil)
    }

    @Test func withoutSectionsEveryBotIsUnderConversationsAsBefore() {
        #expect(BotSections(order: [a, b], membership: [:]).groups == [.init(name: nil, botIDs: [a, b])])
        // No bots at all still shows the heading; bots all in sections leave it out.
        #expect(BotSections(order: [], membership: [:]).groups == [.init(name: nil, botIDs: [])])
        #expect(titles(BotSections(order: [a], membership: [a: "Research"])) == ["Research"])
        // A section of a bot that isn't listed is forgotten.
        #expect(BotSections(order: [a], membership: [b: "Research"]).membership.isEmpty)
    }

    @Test func namesAreTidiedAndMatchedWhateverTheirCase() {
        let sections = BotSections(order: [a, b, c, d], membership: [a: "  Eng\n team ", b: "eng TEAM", c: "conversations", d: "   "])
        #expect(sections.groups == [.init(name: nil, botIDs: [c, d]), .init(name: "Eng team", botIDs: [a, b])])
        #expect(sections.sectionName("ENG TEAM") == "Eng team")
        #expect(sections.sectionName(" New\tsection\n") == "New section")
        #expect(sections.sectionName("Conversations") == nil)
        #expect(sections.sectionName(" ") == nil)
        // A missing bot's saved name stands for the section whose name it is, once tidied.
        #expect(BotSections.matches(" eng   TEAM", section: "Eng team"))
        #expect(!BotSections.matches("Engineering", section: "Eng team"))
        #expect(!BotSections.matches(nil, section: "Eng team"))
    }

    @Test func aMovedBotGoesLastInItsSection() {
        var sections = BotSections(order: [a, b, c, d], membership: [c: "Engineering", d: "Engineering"])
        sections.move(a, to: "engineering")
        #expect(sections.groups == [.init(name: nil, botIDs: [b]), .init(name: "Engineering", botIDs: [c, d, a])])
        // A new name starts a section, after the others.
        sections.move(b, to: "Product")
        #expect(sections.groups == [.init(name: "Engineering", botIDs: [c, d, a]), .init(name: "Product", botIDs: [b])])
        #expect(sections.order == [c, d, a, b])
        // Back to no section: Conversations, first again.
        sections.move(c, to: nil)
        #expect(sections.order == [c, d, a, b])
        #expect(titles(sections) == ["Conversations", "Engineering", "Product"])
        sections.move(e, to: "Product")
        sections.move(b, to: "Conversations")
        #expect(sections.groups == [.init(name: nil, botIDs: [c, b]), .init(name: "Engineering", botIDs: [d, a])])
        // Moving a bot to its own section, or an unknown bot, keeps everything where it is.
        let before = sections
        sections.move(d, to: "ENGINEERING")
        sections.move(e, to: "Engineering")
        #expect(sections == before)
    }

    @Test func renamingKeepsTheSectionsPlaceAndAnotherSectionsNameMergesThem() {
        var sections = BotSections(order: [a, b, c, d], membership: [a: "Engineering", b: "Engineering", c: "Product", d: "Research"])
        sections.rename("Product", to: " Design ")
        #expect(sections.names == ["Engineering", "Design", "Research"])
        sections.rename("Engineering", to: "research")
        #expect(sections.groups == [.init(name: "Design", botIDs: [c]), .init(name: "Research", botIDs: [d, a, b])])
        // A change of case alone renames it.
        sections.rename("Design", to: "DESIGN")
        #expect(sections.names == ["DESIGN", "Research"])
        // An empty name, or a section that doesn't exist, changes nothing.
        let before = sections
        sections.rename("DESIGN", to: "  ")
        sections.rename("Missing", to: "Other")
        #expect(sections == before)
        // Conversations is where the bots in no section are.
        sections.rename("DESIGN", to: "Conversations")
        #expect(sections.groups == [.init(name: nil, botIDs: [c]), .init(name: "Research", botIDs: [d, a, b])])
    }

    @Test func removingASectionReturnsItsBotsAfterTheOnesInNone() {
        var sections = BotSections(order: [a, b, c, d], membership: [b: "Engineering", c: "Engineering", d: "Product"])
        sections.remove("Engineering")
        #expect(sections.groups == [.init(name: nil, botIDs: [a, b, c]), .init(name: "Product", botIDs: [d])])
        sections.remove("Product")
        #expect(sections.groups == [.init(name: nil, botIDs: [a, b, c, d])])
        #expect(sections.membership.isEmpty)
    }

    @Test func sectionsMoveUpAndDownBelowConversations() {
        var sections = BotSections(order: [e, a, b, c], membership: [a: "A", b: "B", c: "C"])
        sections.moveSection("C", by: -1)
        #expect(sections.names == ["A", "C", "B"])
        #expect(sections.order == [e, a, c, b])
        // The first can't go up, nor the last down.
        sections.moveSection("A", by: -1)
        sections.moveSection("B", by: 1)
        #expect(sections.names == ["A", "C", "B"])
        sections.moveSection("A", by: 1)
        #expect(sections.names == ["C", "A", "B"])
        #expect(titles(sections).first == "Conversations")
    }

    @Test func searchFindsBotsInTheirSectionsAndSectionsByName() {
        let sections = BotSections(order: [a, b, c, d, e], membership: [b: "Engineering", c: "Engineering", d: "QA"])
        let text: [UUID: String] = [a: "Scout researcher", b: "Builder Claude", c: "Reviewer Codex", d: "Duck tester", e: "Fox product"]
        func search(_ query: String) -> [BotSections.Group] { sections.groups(matching: query) { text[$0] ?? "" } }
        // A bot is found in its own section, whatever the case; headings without a match are left out.
        #expect(search("CODEX") == [.init(name: "Engineering", botIDs: [c])])
        #expect(search("d") == [.init(name: nil, botIDs: [e]), .init(name: "Engineering", botIDs: [b, c]), .init(name: "QA", botIDs: [d])])
        // A section's name finds all its bots, as Conversations finds the bots in none.
        #expect(search(" engin ") == [.init(name: "Engineering", botIDs: [b, c])])
        #expect(search("qa") == [.init(name: "QA", botIDs: [d])])
        #expect(search("Conversations") == [.init(name: nil, botIDs: [a, e])])
        // An empty search finds everything; one that matches nothing, nothing.
        #expect(search("  ") == sections.groups)
        #expect(search("zebra").isEmpty)
    }

    @Test func theIndexKeepsEachBotsSectionAndReadsIndexesFromBefore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-sections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root.appendingPathComponent("support"))
        let here = Bot(name: "Here", workspace: root.appendingPathComponent("here").path)
        let loose = Bot(name: "Loose", workspace: root.appendingPathComponent("loose").path)
        try BotHome(workspace: here.workspace).save(here)
        try BotHome(workspace: loose.workspace).save(loose)
        let gone = Store.Entry(id: UUID(), workspace: root.appendingPathComponent("gone").path, section: "Research")
        try store.saveIndex([Store.Entry(id: here.id, workspace: here.workspace, section: "Engineering"),
                             Store.Entry(id: loose.id, workspace: loose.workspace), gone])
        let loaded = store.loadBots()
        #expect(loaded.bots.map(\.id) == [here.id, loose.id])
        #expect(loaded.sections == [here.id: "Engineering"])
        #expect(loaded.missing == [gone])
        // A bot in no section is written as before sections, and an index from before reads as none.
        let index = try String(contentsOf: store.indexURL, encoding: .utf8)
        #expect(index.components(separatedBy: "\"section\"").count == 3)
        try Data(#"[{"id":"\#(loose.id.uuidString)","workspace":"\#(loose.workspace)"}]"#.utf8).write(to: store.indexURL)
        #expect(store.loadBots().bots.map(\.id) == [loose.id])
        #expect(store.loadBots().sections.isEmpty)
    }
}
