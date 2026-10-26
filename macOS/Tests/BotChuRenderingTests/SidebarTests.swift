import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func sidebarSelectionKeepsDraftsUnreadAndKeyboardCyclingScoped() throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let task = fixture.tasks[0], second = fixture.tasks[1]
        let home = ChatTarget.home(bot.id), target = ChatTarget.task(task.id, of: bot.id)
        let other = ChatTarget.task(second.id, of: bot.id)
        model.drafts[home] = "Home draft"
        model.drafts[target] = "Task draft"
        model.show(target)
        // One row per bot (#128): the bot is selected whichever of its conversations shows.
        #expect(model.sidebarSelection == .bot(bot.id))
        model.selectSidebar(.library(.projects))
        model.unread = [target, other, home]
        #expect(model.sidebarSelection == .library(.projects))
        #expect(model.tab(of: bot.id) == target)
        #expect(model.visibleBotID == nil)
        // Selecting the bot again shows the conversation it showed last, which is read.
        model.selectSidebar(.bot(bot.id))
        #expect(model.sidebarSelection == .bot(bot.id))
        #expect(model.tab(of: bot.id) == target)
        #expect(model.unread == [other, home])
        model.showTab(offset: 1, of: bot.id)
        #expect(model.tab(of: bot.id) == other)
        #expect(model.unread == [home])
        model.showTab(offset: -2, of: bot.id)
        #expect(model.tab(of: bot.id) == home)
        #expect(model.unread.isEmpty)
        model.showTab(offset: 1, of: bot.id)
        #expect(model.tab(of: bot.id) == target)
        #expect(model.drafts[home] == "Home draft")
        #expect(model.drafts[target] == "Task draft")
        // Another bot's selection keeps this one's tab for when it comes back.
        model.selectSidebar(.bot(fixture.quiet.id))
        #expect(model.tab(of: fixture.quiet.id) == .home(fixture.quiet.id))
        model.selectSidebar(.bot(bot.id))
        #expect(model.tab(of: bot.id) == target)
        model.closeTask(target)
        #expect(model.tab(of: bot.id) == home)
        #expect(!model.tabs(of: bot.id).contains(target))
        model.reopenTask(target)
        #expect(model.tab(of: bot.id) == target)
        // Settings is a page like a gallery (#191): the bot keeps its tab and draft for its return.
        model.openSettings(.hosts)
        #expect(model.sidebarSelection == .library(.settings))
        #expect(model.visibleBotID == nil)
        #expect(model.settings.settingsPage == .hosts)
        model.selectSidebar(.bot(bot.id))
        #expect(model.destination == nil)
        #expect(model.tab(of: bot.id) == target)
        #expect(model.drafts[target] == "Task draft")
        #expect(!LibraryDestination.sidebar.contains(.settings))
    }

    /// One row per bot (#128): no task rows or disclosure arrow, at the sidebar's narrowest and
    /// widest, light and dark, with the bot's busy conversations as dots on its second line.
    // Selection and model changes only: no native clicks, so it can share the test process.
    @Test func botRowsAreOneRowPerBotWithDotsAtCompactWidths() async throws {
        _ = NSApplication.shared
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot, now = Date()
        for (index, task) in fixture.tasks.enumerated() {
            model.runStates[.task(task.id, of: bot.id)] = RunState(startedAt: now.addingTimeInterval(-335),
                                                               hasOutput: true, activity: index == 0 ? .thinking : .coding)
        }
        model.unread.insert(.home(bot.id))
        model.show(.task(fixture.tasks[0].id, of: bot.id))
        let summary = model.botRowSummary(of: bot)
        #expect(summary.subtitle == "3 tasks running")
        #expect(summary.dots == [.news, .working, .working, .working])
        #expect(summary.more == 0)
        #expect(summary.spokenDots == "3 working, 1 finished")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            NSApp.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: appearance == .aqua ? 240 : 210, height: 640))
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            #expect(host.bounds.width >= 210)
            let table = try #require(sidebarTable(in: host))
            // Headers, galleries and one row for each bot: none for its tasks.
            #expect(table.numberOfRows == firstBotRow + 2)
            // No disclosure arrow, or any other button, in the bot's row.
            let botCell = try #require(table.view(atColumn: 0, row: firstBotRow, makeIfNecessary: false))
            #expect(sidebarButtons(in: botCell).isEmpty)
            if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path).appendingPathComponent(appearance == .aqua ? "sidebar-light" : "sidebar-dark")
                DevHooks.snapshot(into: folder)
                DevHooks.snapshotSidebar(model: model, into: folder)
            }
        }
        let table = try #require(sidebarTable(in: host))
        // Selecting a bot's row, as a click does, shows the conversation it showed last.
        table.selectRowIndexes(IndexSet(integer: firstBotRow + 1), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .bot(fixture.quiet.id))
        table.selectRowIndexes(IndexSet(integer: firstBotRow), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .bot(bot.id))
        #expect(model.tab(of: bot.id) == .task(fixture.tasks[0].id, of: bot.id))
        // Switching between its conversations leaves the rows as they are.
        model.showTab(offset: 1, of: bot.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(table.numberOfRows == firstBotRow + 2)
        #expect(table.selectedRow == firstBotRow)
        // Settings (the gear's) selects no row of the list, and adds none (#191).
        model.openSettings()
        try await Task.sleep(for: .milliseconds(100))
        #expect(table.numberOfRows == firstBotRow + 2)
        #expect(table.selectedRow == -1)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("sidebar-settings"))
        }
        model.selectSidebar(.bot(bot.id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(table.selectedRow == firstBotRow)
    }

    // Selection and model changes only: no native clicks, so it can share the test process.
    @Test func botWithoutOpenTasksIsASingleRowUntilItsFirstTask() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, quiet = fixture.quiet
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let table = try #require(sidebarTable(in: host))
        let rowCount = table.numberOfRows, quietRow = rowCount - 1
        #expect(model.botRowSummary(of: quiet).subtitle == quiet.account.name)
        table.selectRowIndexes(IndexSet(integer: quietRow), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .bot(quiet.id))
        #expect(model.tab(of: quiet.id) == .home(quiet.id))
        // New Task stays one command away (⌘T, the toolbar and the row's menu all ask for it).
        model.newTask(for: quiet.id)
        #expect(model.taskSheet?.botID == quiet.id)
        model.taskSheet = nil
        // Its first task is a tab beside the chat, not a row: the row says how many it has.
        let first = BotTask(repo: "fixture/quiet", checkout: fixture.root.path)
        model.tasks[quiet.id, default: []].append(first)
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == rowCount)
        #expect(model.botRowSummary(of: quiet).subtitle == "1 task")
        model.closeTask(.task(first.id, of: quiet.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.openTasks(of: quiet.id).isEmpty)
        #expect(table.numberOfRows == rowCount)
        #expect(model.botRowSummary(of: quiet).subtitle == quiet.account.name)
    }

    @Test func sectionsGroupBotsAndAreKeptInTheIndex() throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot, quiet = fixture.quiet
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [bot.id, quiet.id])])
        // A bot whose folder is missing comes back in its section, also after the section changes.
        let gone = Store.Entry(id: UUID(), workspace: fixture.root.appendingPathComponent("gone").path, section: "Research")
        model.missing = [gone]
        model.moveBot(quiet.id, toSection: " research ")
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [bot.id]), .init(name: "research", botIDs: [quiet.id])])
        model.moveBot(bot.id, toSection: "Research")
        #expect(model.bots.map(\.id) == [quiet.id, bot.id])
        #expect(model.botSections.groups == [.init(name: "research", botIDs: [quiet.id, bot.id])])
        model.renameSection("research", to: "Scouting")
        #expect(fixture.store.loadIndex().map(\.section) == ["Scouting", "Scouting", "Scouting"])
        model.moveBot(bot.id, toSection: "Building")
        model.moveSection("Building", by: -1)
        #expect(model.botSections.names == ["Building", "Scouting"])
        #expect(fixture.store.loadIndex().map(\.id) == [bot.id, quiet.id, gone.id])
        // A relaunch reads the same sections, in the same order.
        let relaunched = AppModel(store: fixture.store, settings: AppSettings(defaults: fixture.defaults),
                                  usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        #expect(relaunched.botSections == model.botSections)
        #expect(relaunched.missing == [Store.Entry(id: gone.id, workspace: gone.workspace, section: "Scouting")])
        model.removeSection("Scouting")
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [quiet.id]), .init(name: "Building", botIDs: [bot.id])])
        #expect(fixture.store.loadIndex().map(\.section) == [nil, "Building", nil])
    }

    /// #78: `index.json` can't be saved (its file is locked) while the bots' folders can. A section
    /// change and a new bot stay in the sidebar, which says why they aren't saved, until Try Again
    /// saves them, once, with the missing bot's entry; a relaunch reads them. Quitting tries again.
    @Test func sidebarChangesThatCantBeSavedShowUntilARetrySavesThem() throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot, quiet = fixture.quiet
        model.settings.botsRoot = fixture.root.appendingPathComponent("bots").path
        model.settings.reposRoot = fixture.root.appendingPathComponent("repos").path
        let gone = Store.Entry(id: UUID(), workspace: fixture.root.appendingPathComponent("gone").path, section: "Research")
        model.missing = [gone]
        model.saveIndex()
        #expect(model.indexFailure == nil)
        let index = fixture.store.root.appendingPathComponent("index.json")
        func lock(_ locked: Bool) throws { try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: index.path) }
        defer { try? lock(false) }
        try lock(true)

        // The section change shows at once, and so does why it isn't saved.
        model.moveBot(quiet.id, toSection: "Research")
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [bot.id]), .init(name: "Research", botIDs: [quiet.id])])
        let failure = try #require(model.indexFailure)
        #expect(failure.item == .botIndex)
        #expect(failure.message.hasPrefix("Couldn't save the sidebar's bots and sections ("))
        #expect(fixture.store.loadBots().sections.isEmpty)

        // So does a new bot: its folder saves, the index doesn't. Its first turn runs a stand-in.
        let helper = Bot(name: "Helper", accountID: "codex-dev", workspace: fixture.root.appendingPathComponent("helper").path)
        model.settings.commands[helper.accountID] = "/usr/bin/true"
        model.create(helper)
        defer { model.stopAll() }
        #expect(model.bots.map(\.id) == [bot.id, helper.id, quiet.id])
        #expect(model.indexFailure == failure)
        #expect(BotHome(workspace: helper.workspace).exists)
        #expect(fixture.store.loadBots().bots.map(\.id) == [bot.id, quiet.id])

        // Once the index can be saved, Try Again saves both, each bot once, with the missing one.
        try lock(false)
        model.saveIndex()
        #expect(model.indexFailure == nil)
        #expect(fixture.store.loadIndex().map(\.id) == [bot.id, helper.id, quiet.id, gone.id])
        let relaunched = AppModel(store: fixture.store, settings: AppSettings(defaults: fixture.defaults),
                                  usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        defer { relaunched.stopAll() }
        #expect(relaunched.botSections == model.botSections)
        #expect(relaunched.missing == [gone])

        // A change still unsaved when BotChu quits gets one more try.
        try lock(true)
        model.moveBot(bot.id, toSection: "Building")
        #expect(model.indexFailure != nil)
        try lock(false)
        model.stopAll()
        #expect(model.indexFailure == nil)
        #expect(fixture.store.loadIndex().map(\.id) == [helper.id, quiet.id, bot.id, gone.id])
        #expect(fixture.store.loadIndex().map(\.section) == [nil, "Research", "Building", "Research"])
    }

    // Model and defaults changes only: no native clicks, so it can share the test process.
    @Test func sectionsShowAsHeadingsThatCollapseAndRevealTheShownBot() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, quiet = fixture.quiet
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let table = try #require(sidebarTable(in: host))
        let flat = table.numberOfRows
        // Its own heading, below Conversations.
        model.moveBot(quiet.id, toSection: "Research")
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == flat + 1)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("sidebar-sections")
            DevHooks.snapshot(into: folder)
            DevHooks.snapshotSidebar(model: model, into: folder)
        }
        // The menus a right click shows: the heading's (its only section can't move), and the bot's
        // Move to Section, with its own section checked.
        let heading = try sidebarMenu(row: table.numberOfRows - 2, of: table, in: host)
        #expect(heading.items.map(\.title) == ["Rename Section…", "Move Section Up", "Move Section Down", "", "Remove Section"])
        #expect(heading.items.filter(\.isEnabled).map(\.title) == ["Rename Section…", "Remove Section"])
        let botMenu = try sidebarMenu(row: table.numberOfRows - 1, of: table, in: host)
        let move = try #require(botMenu.items.first { $0.title == "Move to Section" }?.submenu)
        #expect(move.items.map(\.title) == ["Conversations", "Research", "", "New Section…"])
        #expect(move.items.filter { $0.state == .on }.map(\.title) == ["Research"])
        // Collapsed, as its heading's disclosure leaves it, the section hides its bot, and stays so.
        fixture.defaults.set("Research", forKey: CollapsedSections.storageKey)
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == flat)
        // Opening the bot from elsewhere (Agents) shows it in its section again.
        model.show(.home(quiet.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == flat + 1)
        #expect(fixture.defaults.string(forKey: CollapsedSections.storageKey) == "")
        // So does selecting another of a bot's conversations, as ⌃Tab does, in collapsed Conversations.
        fixture.defaults.set(BotSections.unsectioned, forKey: CollapsedSections.storageKey)
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == flat)
        model.showTab(offset: 1, of: fixture.bot.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == flat + 1)
        // Removed from its heading's menu, its bot is back under Conversations.
        let shown = try sidebarMenu(row: table.numberOfRows - 2, of: table, in: host)
        shown.performActionForItem(at: shown.indexOfItem(withTitle: "Remove Section"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == flat)
        #expect(model.botSections.groups.map(\.title) == ["Conversations"])
        // And moved from its own menu into a section again.
        let again = try #require(try sidebarMenu(row: table.numberOfRows - 1, of: table, in: host)
            .items.first { $0.title == "Move to Section" }?.submenu)
        #expect(again.items.map(\.title) == ["Conversations", "", "New Section…"])
        #expect(again.items.first?.state == .on)
    }

    /// New Section… and Rename Section… ask for the name in an alert; Return names it, Escape doesn't.
    @Test func sectionsAreNamedInAnAlertFromTheirMenus() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, quiet = fixture.quiet
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let table = try #require(sidebarTable(in: host))
        /// Chooses the item in the row's menu (or its submenu), then types the name into the alert it
        /// opens, in place of the name it starts from.
        func name(row: Int, item: String, in submenu: String? = nil, from start: String = "", as text: String,
                  key: (String, UInt16) = ("\r", 36)) async throws {
            var menu = try sidebarMenu(row: row, of: table, in: host)
            if let submenu { menu = try #require(menu.items.first { $0.title == submenu }?.submenu) }
            menu.performActionForItem(at: menu.indexOfItem(withTitle: item))
            try await Task.sleep(for: .milliseconds(400))
            let sheet = try #require(window.attachedSheet)
            let field = try #require(sheet.firstResponder as? NSTextView)
            #expect(field.string == start)
            field.selectAll(nil)
            field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(100))
            sidebarKey(key.0, code: key.1, to: sheet)
            try await Task.sleep(for: .milliseconds(400))
            #expect(window.attachedSheet == nil)
        }
        try await name(row: table.numberOfRows - 1, item: "New Section…", in: "Move to Section", as: "  Research ")
        #expect(model.sections == [quiet.id: "Research"])
        // Below the first bot (its tasks are tabs beside the chat): Research's heading, then Scout.
        let heading = firstBotRow + 1
        #expect(table.numberOfRows == heading + 2)
        // Rename Section… starts from its name; Escape keeps it.
        try await name(row: heading, item: "Rename Section…", from: "Research", as: "Ignored", key: ("\u{1B}", 53))
        #expect(model.botSections.names == ["Research"])
        try await name(row: heading, item: "Rename Section…", from: "Research", as: "Scouting")
        #expect(model.botSections.names == ["Scouting"])
        #expect(fixture.store.loadIndex().map(\.section) == [nil, "Scouting"])
    }

    /// #83: Agents groups the agents under the sidebar's sections, and edits them with the sidebar's
    /// menus and naming alert, so a change made in either shows in both and is saved in the index.
    @Test func agentsGroupsAgentsUnderTheSidebarsSectionsAndEditsThem() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot, quiet = fixture.quiet
        // The sidebar's sections are Agents' headings; a search finds agents in them, and sections by name.
        #expect(AgentsView.groups(in: model, matching: "").map(\.title) == ["Conversations"])
        model.moveBot(quiet.id, toSection: "Research")
        #expect(AgentsView.groups(in: model, matching: "") == [.init(name: nil, botIDs: [bot.id]), .init(name: "Research", botIDs: [quiet.id])])
        #expect(AgentsView.groups(in: model, matching: "scout") == [.init(name: "Research", botIDs: [quiet.id])])
        #expect(AgentsView.groups(in: model, matching: "RESEARCH") == [.init(name: "Research", botIDs: [quiet.id])])
        #expect(AgentsView.groups(in: model, matching: "10x") == [.init(name: nil, botIDs: [bot.id])])
        #expect(AgentsView.groups(in: model, matching: "zebra").isEmpty)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            window.contentView = NSHostingView(rootView: AgentsView().environment(model).defaultAppStorage(fixture.defaults))
            window.makeKeyAndOrderFront(nil)
            for (name, width) in [("agents-sections", 1000.0), ("agents-sections-narrow", 620.0)] {
                window.setContentSize(NSSize(width: width, height: 700))
                try await Task.sleep(for: .milliseconds(300))
                try agentsCapture(window, into: URL(fileURLWithPath: path), name: name)
            }
        }
        // A card's Move to Section is the sidebar's, with its own section checked.
        let card = NSHostingView(rootView: AgentCardHarness(bot: bot).environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = card
        window.setContentSize(NSSize(width: 360, height: 340))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        func moveMenu() throws -> NSMenu {
            try #require(try agentsMenu(at: NSPoint(x: card.bounds.midX, y: card.bounds.midY), in: card)
                .items.first { $0.title == "Move to Section" }?.submenu)
        }
        let move = try moveMenu()
        #expect(move.items.map(\.title) == ["Conversations", "Research", "", "New Section…"])
        #expect(move.items.filter { $0.state == .on }.map(\.title) == ["Conversations"])
        // Choosing a section moves the agent there, last, and the index keeps it.
        move.performActionForItem(at: move.indexOfItem(withTitle: "Research"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.botSections.groups == [.init(name: "Research", botIDs: [quiet.id, bot.id])])
        #expect(fixture.store.loadIndex().map(\.section) == ["Research", "Research"])
        // New Section… names a new one for it in the sidebar's alert.
        let again = try moveMenu()
        again.performActionForItem(at: again.indexOfItem(withTitle: "New Section…"))
        try await Task.sleep(for: .milliseconds(400))
        let sheet = try #require(window.attachedSheet)
        let field = try #require(sheet.firstResponder as? NSTextView)
        #expect(field.string == "")
        field.insertText("  Building ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        sidebarKey("\r", code: 36, to: sheet)
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.attachedSheet == nil)
        #expect(model.sections == [quiet.id: "Research", bot.id: "Building"])
        #expect(model.botSections.names == ["Research", "Building"])
        // A heading's menu is the sidebar heading's: Move Section Up puts Building first, everywhere.
        let heading = NSHostingView(rootView: AgentSectionHeading(group: .init(name: "Building", botIDs: [bot.id]), rename: { _ in })
            .frame(width: 360, height: 44).environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = heading
        try await Task.sleep(for: .milliseconds(250))
        let point = NSPoint(x: 30, y: heading.bounds.midY)
        let menu = try agentsMenu(at: point, in: heading)
        #expect(menu.items.map(\.title) == ["Rename Section…", "Move Section Up", "Move Section Down", "", "Remove Section"])
        #expect(menu.items.filter(\.isEnabled).map(\.title) == ["Rename Section…", "Move Section Up", "Remove Section"])
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Move Section Up"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.botSections.names == ["Building", "Research"])
        #expect(fixture.store.loadIndex().map(\.section) == ["Building", "Research"])
        // Removing it returns its agent to Conversations and deletes nothing; a relaunch reads the same.
        let removing = try agentsMenu(at: point, in: heading)
        removing.performActionForItem(at: removing.indexOfItem(withTitle: "Remove Section"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [bot.id]), .init(name: "Research", botIDs: [quiet.id])])
        #expect(model.bot(bot.id) != nil && model.openTasks(of: bot.id).count == fixture.tasks.count)
        let relaunched = AppModel(store: fixture.store, settings: AppSettings(defaults: fixture.defaults),
                                  usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        #expect(relaunched.botSections == model.botSections)
    }

    @Test func darkSidebarTakesTheStatusShadeWithAnEdgeAndFollowsAppearance() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        // The status sidebar's shade as this window draws it: the display's color profile shifts
        // the values, so the sidebar is compared with this swatch rather than with numbers.
        window.appearance = NSAppearance(named: .darkAqua)
        let swatch = NSHostingView(rootView: Palette.sidebar)
        window.contentView = swatch
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let shade = try sidebarPixel(in: swatch, x: 10, fromTop: 10)
        let host = NSHostingView(rootView: SidebarView().environment(fixture.model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        // Dark, light, then dark again in one window: each change shows without a relaunch.
        for dark in [true, false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            // The bottom bar's empty middle shows the sidebar's background; its last point, the edge.
            let fromTop = host.bounds.height - 20
            let fill = try sidebarPixel(in: host, x: host.bounds.width / 2, fromTop: fromTop)
            let edge = try sidebarPixel(in: host, x: host.bounds.width - 0.5, fromTop: fromTop)
            if dark {
                #expect(sameColor(fill, shade))
                #expect(edge.alphaComponent > 0.99 && edge.brightnessComponent > fill.brightnessComponent + 0.04)
            } else {
                // The standard sidebar: no shade of BotChu's own, and no edge line.
                #expect(fill.alphaComponent < 0.01 || fill.brightnessComponent > 0.5)
                #expect(sameColor(edge, fill))
            }
        }
    }

    /// Beside Inbox, how many deliveries aren't Done, read or not (#189): it follows an arrival, Done,
    /// Move to Inbox and a deleted bot at once, on the Inbox and elsewhere, is hidden at zero, comes
    /// back at launch, and a large count fits the narrowest sidebar.
    @Test func inboxShowsHowManyDeliveriesArentDone() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 210, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func host(_ model: AppModel) -> NSHostingView<some View> {
            let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            return host
        }
        var shown = host(model)
        func badge() async throws -> InboxBadge? {
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
            let table = try #require(sidebarTable(in: shown))
            let row = 1 + (LibraryDestination.sidebar.firstIndex(of: .inbox) ?? 0)
            return try inboxBadge(in: try #require(table.view(atColumn: 0, row: row, makeIfNecessary: false)))
        }
        #expect(try await badge() == nil)

        let report = Delivery(botID: fixture.bot.id, title: "Report")
        let mockup = Delivery(botID: fixture.quiet.id, title: "Mockup")
        try await model.inbox.post(report)
        try await model.inbox.post(mockup)
        #expect(model.inbox.unfinishedCount == 2)
        let two = try #require(try await badge())
        // Reading leaves it, with the Inbox shown and once it isn't.
        model.selectSidebar(.library(.inbox))
        model.inbox.markRead(report.id)
        model.inbox.markRead(mockup.id)
        #expect(model.inbox.unreadCount == 0 && model.inbox.unfinishedCount == 2)
        #expect(try await badge()?.mask == two.mask)
        model.selectSidebar(.library(.projects))
        #expect(try await badge()?.mask == two.mask)
        // Done takes one off; Move to Inbox puts it back; all Done, it is hidden.
        model.inbox.setDone(report.id, true)
        let one = try #require(try await badge())
        #expect(one.mask != two.mask)
        model.inbox.setDone(report.id, false)
        #expect(try await badge()?.mask == two.mask)
        model.inbox.setDone(report.id, true)
        model.inbox.setDone(mockup.id, true)
        #expect(try await badge() == nil)
        model.inbox.setDone(report.id, false)
        #expect(try await badge()?.mask == one.mask)
        // Its bot deleted, its deliveries go from the count.
        model.inbox.setDone(mockup.id, false)
        #expect(try await badge()?.mask == two.mask)
        model.delete(fixture.quiet.id)
        #expect(model.inbox.unfinishedCount == 1)
        #expect(try await badge()?.mask == one.mask)

        // Read at launch with what was Done, a four-digit count stands apart from the label and
        // inside the row.
        await model.storage.settle()
        let folder = InboxFolder(home: BotHome(workspace: fixture.bot.workspace))
        for index in 1..<1234 { try folder.save(Delivery(botID: fixture.bot.id, title: "Report \(index)"), contents: [:]) }
        let done = Delivery(botID: fixture.bot.id, title: "Done")
        try folder.save(done, contents: [:])
        var state = InboxState.load(from: fixture.store.root)
        state[done.id].done = true
        try state.save(to: fixture.store.root)
        let relaunched = AppModel(store: fixture.store, settings: AppSettings(defaults: fixture.defaults),
                                  usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        defer { relaunched.stopAll() }
        for _ in 0..<250 where !relaunched.inbox.isLoaded { try await Task.sleep(for: .milliseconds(20)) }
        // The report read before stays read: the Dock's count is one fewer.
        #expect(relaunched.inbox.unfinishedCount == 1234 && relaunched.inbox.unreadCount == 1233)
        shown = host(relaunched)
        let large = try #require(try await badge())
        #expect(large.columns.count > two.columns.count * 2)
        #expect(large.columns.lowerBound > large.labelEnd)
        #expect(large.columns.upperBound < large.width - 1)
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent("sidebar-inbox-count"))
        }
    }

    /// The Inbox row's badge: the last run of drawn columns, in the row's trailing half and apart
    /// from the label, with which of its points are drawn; nil when the row has none.
    private struct InboxBadge: Equatable {
        var columns: ClosedRange<Int>
        var mask: [Bool]
        /// Where the label's drawing ends, and the row's width, in pixels.
        var labelEnd: Int
        var width: Int
    }

    private func inboxBadge(in cell: NSView) throws -> InboxBadge? {
        let rep = try #require(cell.bitmapImageRepForCachingDisplay(in: cell.bounds))
        cell.cacheDisplay(in: cell.bounds, to: rep)
        // Each row's own last point is its background: the badge stops short of the edge.
        func drawn(_ x: Int, _ y: Int) -> Bool {
            guard let point = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  let edge = rep.colorAt(x: rep.pixelsWide - 1, y: y)?.usingColorSpace(.sRGB) else { return false }
            return [point.redComponent - edge.redComponent, point.greenComponent - edge.greenComponent,
                    point.blueComponent - edge.blueComponent, point.alphaComponent - edge.alphaComponent].contains { abs($0) > 0.2 }
        }
        let inked = (0..<rep.pixelsWide).filter { x in (0..<rep.pixelsHigh).contains { drawn(x, $0) } }
        guard let last = inked.last else { return nil }
        // A gap of more than 8 points ends the label's drawing.
        let gap = Int(8 * CGFloat(rep.pixelsWide) / cell.bounds.width)
        var start = last
        while let before = inked.last(where: { $0 < start }), start - before <= gap { start = before }
        guard start > rep.pixelsWide / 2, let labelEnd = inked.last(where: { $0 < start }) else { return nil }
        let mask = (start...last).flatMap { x in (0..<rep.pixelsHigh).map { drawn(x, $0) } }
        return InboxBadge(columns: start...last, mask: mask, labelEnd: labelEnd, width: rep.pixelsWide)
    }

    /// One point of the view's own drawing, in sRGB, measured from its top-left corner.
    private func sidebarPixel(in view: NSView, x: CGFloat, fromTop y: CGFloat) throws -> NSColor {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let color = try #require(rep.colorAt(x: Int(x * scale), y: Int(y * scale)))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private func sameColor(_ a: NSColor, _ b: NSColor) -> Bool {
        [a.redComponent - b.redComponent, a.greenComponent - b.greenComponent,
         a.blueComponent - b.blueComponent, a.alphaComponent - b.alphaComponent].allSatisfy { abs($0) < 0.02 }
    }

    /// The first bot's row, below the Workspace heading, its galleries and the Conversations heading.
    private var firstBotRow: Int { LibraryDestination.sidebar.count + 2 }

    /// The context menu a right click on the row shows, as AppKit asks the views under the pointer for it.
    private func sidebarMenu(row: Int, of table: NSTableView, in host: NSView) throws -> NSMenu {
        let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: false))
        let point = rowView.convert(NSPoint(x: 60, y: rowView.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: host.window?.windowNumber ?? 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        var view = host.hitTest(host.convert(point, from: nil))
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        return try #require(menu)
    }

    /// The context menu a right click at the point shows, in a view hosted alone in a window.
    private func agentsMenu(at point: NSPoint, in host: NSView) throws -> NSMenu {
        let location = host.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: host.window?.windowNumber ?? 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        var view = host.hitTest(host.convert(location, from: nil))
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        return try #require(menu)
    }

    private func agentsCapture(_ window: NSWindow, into folder: URL, name: String) throws {
        guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private func sidebarKey(_ text: String, code: UInt16, to window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: text,
                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    private func sidebarButtons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(sidebarButtons)
    }

    private func sidebarTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(sidebarTable).first
    }
}

@MainActor private final class SidebarFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-sidebar-\(UUID().uuidString)")
    let domain = "BotChu.SidebarTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let bot: Bot
    /// A second bot, listed after the first, without any tasks.
    let quiet: Bot
    let tasks: [BotTask]
    let store: Store
    let model: AppModel

    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        bot = Bot(name: "10x Engineer", emoji: "🦊", workspace: root.appendingPathComponent("bot").path)
        quiet = Bot(name: "Scout", emoji: "🔭", workspace: root.appendingPathComponent("quiet").path)
        let checkout = root.path
        tasks = (41...43).map { number in
            BotTask(title: number == 41 ? "ScreenTimeDaddy repository improvements" : "Task \(number)",
                    repo: "fixture/repo", checkout: checkout, branch: "feat/\(number)-improve-task",
                    work: .init(number: number, isPullRequest: false, repo: "fixture/repo"),
                    createdAt: Date(timeIntervalSince1970: Double(number)))
        }
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        for task in tasks { try home.save(task) }
        try BotHome(workspace: quiet.workspace).save(quiet)
        store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace),
                             Store.Entry(id: quiet.id, workspace: quiet.workspace)])
        model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                         usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
    }

    func cleanUp() {
        model.runStates.removeAll()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

/// An agent's card as Agents shows it, with the alert that names a section for it.
private struct AgentCardHarness: View {
    let bot: Bot
    @State private var naming = SectionNaming()

    var body: some View {
        AgentCard(bot: bot) { naming.ask(.new(botID: bot.id)) }
            .frame(width: 320)
            .padding(20)
            .sectionNamingAlert($naming)
    }
}
