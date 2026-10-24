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
        #expect(model.sidebarSelection == .botTask(botID: bot.id, taskID: task.id))
        model.selectSidebar(.library(.projects))
        model.unread = [target, other, home]
        #expect(model.sidebarSelection == .library(.projects))
        #expect(model.tab(of: bot.id) == target)
        #expect(model.visibleBotID == nil)
        model.selectSidebar(.botHome(bot.id))
        #expect(model.sidebarSelection == .botHome(bot.id))
        #expect(model.unread == [target, other])
        model.showTab(offset: 1, of: bot.id)
        #expect(model.sidebarSelection == .botTask(botID: bot.id, taskID: task.id))
        #expect(model.unread == [other])
        model.selectSidebar(.botTask(botID: bot.id, taskID: second.id))
        #expect(model.unread.isEmpty)
        model.showTab(offset: -1, of: bot.id)
        #expect(model.tab(of: bot.id) == target)
        #expect(model.drafts[home] == "Home draft")
        #expect(model.drafts[target] == "Task draft")
        model.closeTask(target)
        #expect(model.sidebarSelection == .botHome(bot.id))
        #expect(!model.sidebarStructure.taskIDs[bot.id, default: []].contains(task.id))
        model.reopenTask(target)
        #expect(model.sidebarSelection == .botTask(botID: bot.id, taskID: task.id))
    }

    @Test func sidebarExpansionRevealsNewTasksAndSelectionsButRespectsCollapse() throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, botID = fixture.bot.id
        var expansion = SidebarExpansion()
        expansion.update(model.sidebarStructure)
        #expect(expansion.botIDs.contains(botID))
        expansion.toggle(botID)
        // Output/status changes leave structure unchanged and do not undo the owner's collapse.
        model.runStates[.task(fixture.tasks[0].id, of: botID)] = RunState()
        expansion.update(model.sidebarStructure)
        #expect(!expansion.botIDs.contains(botID))
        #expect(model.runningTaskCount(for: botID) == 1)
        model.showTab(offset: 1, of: botID)
        expansion.update(model.sidebarStructure)
        #expect(expansion.botIDs.contains(botID))
        expansion.toggle(botID)
        let created = BotTask(repo: "fixture/new", checkout: fixture.root.path)
        model.tasks[botID, default: []].append(created)
        expansion.update(model.sidebarStructure)
        #expect(expansion.botIDs.contains(botID))
        expansion.toggle(botID)
        // Clicking an already-selected Home row must still reopen its group.
        expansion.reveal(.botHome(botID))
        #expect(expansion.botIDs.contains(botID))
        model.bots.removeAll()
        expansion.update(model.sidebarStructure)
        #expect(expansion.botIDs.isEmpty)
    }

    @Test func nestedSidebarShowsThreeRunningTasksAtCompactWidths() async throws {
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
        model.show(.task(fixture.tasks[0].id, of: bot.id))
        #expect(model.runningTaskCount(for: bot.id) == 3)
        let status = try #require(model.status(of: model.tab(of: bot.id)))
        #expect(SidebarTaskRow.subtitle(task: fixture.tasks[0], status: status, now: now) == "#41 · Thinking… · 5:35")
        let row = BotRow(bot: bot, status: model.status(of: bot), selected: true,
                         runningTasks: model.runningTaskCount(for: bot.id), openTasks: 3, isExpanded: true)
        #expect(row.subtitle == "3 tasks running")

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
            // Headers, galleries, Home, three tasks and New task all remain separate List rows.
            #expect(table.numberOfRows >= 10)
            if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: path).appendingPathComponent(appearance == .aqua ? "sidebar-light" : "sidebar-dark")
                DevHooks.snapshot(into: folder)
                DevHooks.snapshotSidebar(model: model, into: folder)
            }
        }
        let table = try #require(sidebarTable(in: host))
        let expandedRowCount = table.numberOfRows
        // Programmatic native selection exercises List's binding without requiring the test
        // runner to become the active application (synthetic row clicks are ignored otherwise).
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .botHome(bot.id))
        table.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .botTask(botID: bot.id, taskID: fixture.tasks[1].id))
        let botCell = try #require(table.view(atColumn: 0, row: 5, makeIfNecessary: false))
        let disclosure = try #require(sidebarButtons(in: botCell).first)
        disclosure.performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .botTask(botID: bot.id, taskID: fixture.tasks[1].id))
        #expect(table.numberOfRows == expandedRowCount - 4)
        model.showTab(offset: -1, of: bot.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(table.numberOfRows == expandedRowCount)
        #expect(model.sidebarSelection == .botTask(botID: bot.id, taskID: fixture.tasks[0].id))
        let newTaskCell = try #require(table.view(atColumn: 0, row: 9, makeIfNecessary: false))
        let newTask = try #require(sidebarButtons(in: newTaskCell).first)
        newTask.performClick(nil)
        #expect(model.taskSheet?.botID == bot.id)
        #expect(model.sidebarSelection == .botTask(botID: bot.id, taskID: fixture.tasks[0].id))
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
        func quietButtons() throws -> [NSButton] {
            try sidebarButtons(in: #require(table.view(atColumn: 0, row: quietRow, makeIfNecessary: false)))
        }
        // No arrow, and opening its Home, as a click on the row does, reveals nothing beneath it.
        #expect(try quietButtons().isEmpty)
        table.selectRowIndexes(IndexSet(integer: quietRow), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .botHome(quiet.id))
        #expect(table.numberOfRows == rowCount)
        // New Task stays one command away (⌘T and the row's menu both ask for it).
        model.newTask(for: quiet.id)
        #expect(model.taskSheet?.botID == quiet.id)
        model.taskSheet = nil
        // Its first task brings the arrow, with the task revealed and New task beneath it.
        let first = BotTask(repo: "fixture/quiet", checkout: fixture.root.path)
        model.tasks[quiet.id, default: []].append(first)
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == rowCount + 2)
        #expect(try quietButtons().count == 1)
        // Closing its last task takes the arrow and the nested rows away again.
        model.closeTask(.task(first.id, of: quiet.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.openTasks(of: quiet.id).isEmpty)
        #expect(table.numberOfRows == rowCount)
        #expect(try quietButtons().isEmpty)
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
        #expect(table.numberOfRows == flat - 4)
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
        #expect(table.numberOfRows == 12)
        // Rename Section… starts from its name; Escape keeps it.
        try await name(row: 10, item: "Rename Section…", from: "Research", as: "Ignored", key: ("\u{1B}", 53))
        #expect(model.botSections.names == ["Research"])
        try await name(row: 10, item: "Rename Section…", from: "Research", as: "Scouting")
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
