import Foundation
import Testing
@testable import BotChuCore

/// #78: `index.json` that can't be saved (its file is locked, while the bots' folders stay
/// writable). A section change or a new bot stays pending, the failure says which file and why, and
/// the next save that works saves everything since, once, with the missing bots' entries.
@Suite struct BotIndexTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-index-\(UUID().uuidString)")
        let store: Store
        let builder: Bot
        let scout: Bot
        /// A bot whose folder is missing, in Engineering.
        let gone: Store.Entry

        init() throws {
            store = Store(root: root.appendingPathComponent("support"))
            builder = Bot(name: "Builder", workspace: root.appendingPathComponent("builder").path)
            scout = Bot(name: "Scout", workspace: root.appendingPathComponent("scout").path)
            gone = Store.Entry(id: UUID(), workspace: root.appendingPathComponent("gone").path, section: "Engineering")
            try BotHome(workspace: builder.workspace).save(builder)
            try BotHome(workspace: scout.workspace).save(scout)
            try store.saveIndex([Store.Entry(id: scout.id, workspace: scout.workspace),
                                 Store.Entry(id: builder.id, workspace: builder.workspace, section: "Engineering"), gone])
        }

        func lock(_ locked: Bool) throws {
            try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: store.indexURL.path)
        }

        /// The index for `bots` as `layout` arranges them, as the app saves it.
        func commit(_ bots: [Bot], _ layout: BotSections, missing: [Store.Entry]) -> SaveFailure? {
            let ordered = layout.order.compactMap { id in bots.first { $0.id == id } }
            return store.commitIndex(Store.entries(for: ordered, sections: layout.membership, missing: missing))
        }

        func cleanUp() {
            try? lock(false)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func sectionChangesThatCantBeSavedStayPendingUntilARetrySavesThem() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let loaded = fixture.store.loadBots()
        var layout = BotSections(order: loaded.bots.map(\.id), membership: loaded.sections)
        var missing = loaded.missing
        try fixture.lock(true)

        layout.move(fixture.scout.id, to: "Design")
        let failure = try #require(fixture.commit(loaded.bots, layout, missing: missing))
        #expect(failure.item == .botIndex)
        #expect(failure.file == fixture.store.indexURL)
        #expect(failure.message.hasPrefix("Couldn't save the sidebar's bots and sections ("))
        #expect(failure.message.contains("aren't saved until Try Again or a later change saves them."))
        // Nothing of it is saved: a relaunch now would read the index as it was.
        #expect(fixture.store.loadBots().sections == [fixture.builder.id: "Engineering"])

        // A second change while the first is pending, renaming the missing bot's section too.
        layout.rename("Engineering", to: "Platform")
        for i in missing.indices where BotSections.matches(missing[i].section, section: "Engineering") { missing[i].section = "Platform" }
        #expect(fixture.commit(loaded.bots, layout, missing: missing) == failure)

        // Once the index can be saved, the retry saves both changes, and saving again changes nothing.
        try fixture.lock(false)
        #expect(fixture.commit(loaded.bots, layout, missing: missing) == nil)
        let first = try Data(contentsOf: fixture.store.indexURL)
        #expect(fixture.commit(loaded.bots, layout, missing: missing) == nil)
        #expect(try Data(contentsOf: fixture.store.indexURL) == first)
        let reloaded = fixture.store.loadBots()
        #expect(BotSections(order: reloaded.bots.map(\.id), membership: reloaded.sections) == layout)
        #expect(layout.names == ["Platform", "Design"])
        #expect(reloaded.missing == [Store.Entry(id: fixture.gone.id, workspace: fixture.gone.workspace, section: "Platform")])
    }

    @Test func aNewBotThatCantBeAddedToTheIndexIsSavedOnceByTheRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let loaded = fixture.store.loadBots()
        var layout = BotSections(order: loaded.bots.map(\.id), membership: loaded.sections)
        try fixture.lock(true)

        // Its folder saves; only the index doesn't.
        let helper = Bot(name: "Helper", workspace: fixture.root.appendingPathComponent("helper").path)
        try BotHome(workspace: helper.workspace).save(helper)
        layout.add(helper.id)
        #expect(layout.order == [fixture.scout.id, helper.id, fixture.builder.id])
        let bots = loaded.bots + [helper]
        #expect(fixture.commit(bots, layout, missing: loaded.missing)?.item == .botIndex)
        #expect(fixture.store.loadBots().bots.map(\.id) == [fixture.scout.id, fixture.builder.id])

        try fixture.lock(false)
        #expect(fixture.commit(bots, layout, missing: loaded.missing) == nil)
        #expect(fixture.commit(bots, layout, missing: loaded.missing) == nil)
        let entries = fixture.store.loadIndex()
        #expect(entries.map(\.id) == [fixture.scout.id, helper.id, fixture.builder.id, fixture.gone.id])
        let reloaded = fixture.store.loadBots()
        #expect(reloaded.bots.map(\.id) == [fixture.scout.id, helper.id, fixture.builder.id])
        #expect(reloaded.sections == [fixture.builder.id: "Engineering"])
        #expect(reloaded.missing == [fixture.gone])
    }

    @Test func theIndexListsEachBotOnceBotsBeforeMissingEntries() {
        let a = Bot(name: "A", workspace: "/tmp/a"), b = Bot(name: "B", workspace: "/tmp/b")
        let gone = Store.Entry(id: UUID(), workspace: "/tmp/gone", section: "Research")
        // A missing entry for a bot that is listed is left out.
        let entries = Store.entries(for: [b, a], sections: [a.id: "Research"],
                                    missing: [Store.Entry(id: a.id, workspace: "/tmp/old-a"), gone])
        #expect(entries == [Store.Entry(id: b.id, workspace: "/tmp/b"), Store.Entry(id: a.id, workspace: "/tmp/a", section: "Research"), gone])
    }

    @Test func newBotsGoLastAmongTheBotsInNoSection() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var sections = BotSections(order: [a, b], membership: [b: "Research"])
        sections.add(c)
        #expect(sections.order == [a, c, b])
        #expect(sections.section(of: c) == nil)
        // Already listed, it stays where it is.
        sections.add(b)
        #expect(sections.order == [a, c, b])
        // With every bot in a section, a new one comes first, under Conversations.
        var sectioned = BotSections(order: [a], membership: [a: "Research"])
        sectioned.add(d)
        #expect(sectioned.groups == [.init(name: nil, botIDs: [d]), .init(name: "Research", botIDs: [a])])
    }
}
