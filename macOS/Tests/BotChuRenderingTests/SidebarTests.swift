import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func oneConversationsActivityOnlyReevaluatesItsSidebarRow() async throws {
        _ = NSApplication.shared
        let fixture = try InboxStatusFixture()
        defer { fixture.cleanUp() }
        try await fixture.ready()
        let app = fixture.app, changed = fixture.targets[1]
        app.destination = .projects
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 1_400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        var bodies: [UUID: Int] = [:], derivations: [UUID: Int] = [:]
        SidebarStatusDiagnostics.didEvaluateRow = { bodies[$0, default: 0] += 1 }
        SidebarStatusDiagnostics.didDeriveSummary = { derivations[$0, default: 0] += 1 }
        defer {
            SidebarStatusDiagnostics.didEvaluateRow = nil
            SidebarStatusDiagnostics.didDeriveSummary = nil
        }
        window.contentView = NSHostingView(rootView: SidebarView().environment(app).defaultAppStorage(fixture.defaults))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        #expect(bodies[changed.botID, default: 0] > 0)
        bodies.removeAll(); derivations.removeAll()
        let regroupings = app.inbox.statusDerivations
        app.runStates[changed] = RunState(hasOutput: true, activity: .coding)
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(bodies[changed.botID, default: 0] > 0)
        #expect(derivations[changed.botID, default: 0] > 0)
        #expect(bodies.keys.allSatisfy { $0 == changed.botID }, "Unrelated row bodies stay untouched: \(bodies)")
        #expect(derivations.keys.allSatisfy { $0 == changed.botID }, "Unrelated statuses stay untouched: \(derivations)")
        #expect(app.inbox.statusDerivations == regroupings)
        let activityRows = bodies.count, activityDerivations = derivations.values.reduce(0, +)

        bodies.removeAll(); derivations.removeAll()
        let delivery = try #require(fixture.deliveries.first { $0.taskID == changed.taskID && $0.purpose == .needsInput })
        app.inbox.setDone(delivery.id, true)
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        #expect(bodies[changed.botID, default: 0] > 0)
        #expect(bodies.keys.allSatisfy { $0 == changed.botID })
        #expect(derivations.keys.allSatisfy { $0 == changed.botID })
        #expect(app.inbox.statusDerivations == regroupings + 1)

        // Unread dots and task lists are observed by conversation and by bot, as activity is (#340).
        let inboxRows = bodies.count, inboxDerivations = derivations.values.reduce(0, +)
        let other = fixture.bots[5].id
        let changes: [(name: String, botID: UUID, change: () -> Void)] = [
            ("unread", changed.botID, { app.unread.insert(changed) }),
            ("task metadata", changed.botID, { app.tasks[changed.botID]?[0].title = "Renamed task" }),
            ("new task", other, { app.tasks[other, default: []].append(BotTask(title: "New", repo: "fixture/repo", checkout: "/")) }),
        ]
        var counters: [String] = []
        for (name, botID, change) in changes {
            bodies.removeAll(); derivations.removeAll()
            change()
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
            #expect(bodies[botID, default: 0] > 0, "\(name) redraws its bot's row")
            #expect(bodies.keys.allSatisfy { $0 == botID }, "\(name) leaves the other rows untouched: \(bodies)")
            #expect(derivations.keys.allSatisfy { $0 == botID }, "\(name) leaves the other statuses untouched: \(derivations)")
            counters.append("\(name) \(bodies.count)/\(derivations.values.reduce(0, +))")
        }
        #expect(app.inbox.statusDerivations == regroupings + 1, "Metadata and unread changes never regroup the Inbox")
        print("#271 sidebar counters (rows / summary derivations): activity \(activityRows)/\(activityDerivations), Inbox question \(inboxRows)/\(inboxDerivations), \(counters.joined(separator: ", "))")
    }

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
        for unread in [target, other, home] { model.unread.insert(unread) }
        func unread() -> Set<ChatTarget> { Set([target, other, home].filter(model.unread.contains)) }
        #expect(model.sidebarSelection == .library(.projects))
        #expect(model.tab(of: bot.id) == target)
        #expect(model.visibleBotID == nil)
        // Selecting the bot again shows the conversation it showed last, which is read.
        model.selectSidebar(.bot(bot.id))
        #expect(model.sidebarSelection == .bot(bot.id))
        #expect(model.tab(of: bot.id) == target)
        #expect(unread() == [other, home])
        model.showTab(offset: 1, of: bot.id)
        #expect(model.tab(of: bot.id) == other)
        #expect(unread() == [home])
        model.showTab(offset: -2, of: bot.id)
        #expect(model.tab(of: bot.id) == home)
        #expect(unread().isEmpty)
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
        #expect(summary.subtitle == "Claude Personal · default")
        // The most urgent first (#218): the turns under way, then Home's finished one.
        #expect(summary.dots == [.working, .working, .working, .news])
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

    /// #359: in the list, a bot with more than eight open tasks has eight dots, in two rows of four,
    /// and +N, all of them shown in the middle of a row as tall as a bot's without any; so is the
    /// collapsed Specialists heading, as tall with eight dots as with none.
    // Model changes only: no native clicks, so it can share the test process.
    @Test func eightDotsKeepTheListsRowAndHeadingHeights() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture(taskCount: 9)
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        // Its nine tasks' turns run: violet dots.
        for task in fixture.tasks { model.runStates[.task(task.id, of: bot.id)] = RunState(hasOutput: true, activity: .coding) }
        let summary = model.botRowSummary(of: bot)
        #expect(summary.dots == Array(repeating: .working, count: 8) && summary.more == 1)
        #expect(model.botRowSummary(of: fixture.quiet).dots.isEmpty)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let snapshots = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("sidebar-dot-grid") }
        let outline = try #require(sidebarTable(in: host) as? NSOutlineView)
        func height(_ row: Int) -> CGFloat { outline.rect(ofRow: row).height }
        #expect(outline.numberOfRows == firstBotRow + 2)
        #expect(height(firstBotRow) == height(firstBotRow + 1), "eight dots and +1: \(height(firstBotRow)), none: \(height(firstBotRow + 1))")
        if let snapshots { try agentsCapture(window, into: snapshots, name: "agents") }
        let row = try #require(outline.rowView(atRow: firstBotRow, makeIfNecessary: false))
        let dots = try #require(try violet(in: row), "the busy bot's dots")
        // All of the grid shows, four 6-point dots 4 apart and two rows, in the middle of the row.
        #expect(abs(dots.width - 36) < 1 && abs(dots.height - 16) < 1 && abs(dots.midY - row.bounds.height / 2) < 1.5,
                "\(dots) in a row \(row.bounds.height) tall")
        func heading() -> Int? { (0..<outline.numberOfRows).last { outline.level(forRow: $0) == 0 } }
        // A specialist without dots, then one with eight and +1 too: the collapsed heading shows them.
        var quiet = try #require(model.bot(fixture.quiet.id))
        quiet.role = .specialist
        model.update(quiet)
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let bare = height(try #require(heading()))
        var busy = try #require(model.bot(bot.id))
        busy.role = .specialist
        model.update(busy)
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let merged = BotRowSummary(merging: model.specialists.map { ($0.name, model.botRowSummary(of: $0)) })
        #expect(merged.dots == Array(repeating: .working, count: 8) && merged.more == 1)
        let full = try #require(heading())
        #expect(height(full) == bare, "Specialists with eight dots and +1: \(height(full)), none: \(bare)")
        if let snapshots { try agentsCapture(window, into: snapshots, name: "specialists") }
        let headingRow = try #require(outline.rowView(atRow: full, makeIfNecessary: false))
        let headingDots = try #require(try violet(in: headingRow), "the Specialists heading's dots")
        #expect(abs(headingDots.width - 36) < 1 && abs(headingDots.height - 16) < 1
                && headingDots.minY >= 0 && headingDots.maxY <= headingRow.bounds.height,
                "\(headingDots) in a heading \(headingRow.bounds.height) tall")
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
        #expect(model.botRowSummary(of: quiet).subtitle == "Claude Personal · default")
        #expect(model.botRowSummary(of: quiet).dots.isEmpty)
        table.selectRowIndexes(IndexSet(integer: quietRow), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sidebarSelection == .bot(quiet.id))
        #expect(model.tab(of: quiet.id) == .home(quiet.id))
        // New Task stays one command away (⌘T, the toolbar and the row's menu all ask for it).
        model.newTask(for: quiet.id)
        #expect(model.taskSheet?.botID == quiet.id)
        model.taskSheet = nil
        // Its first task is a tab beside the chat, not a row: the row shows its ring (#324).
        let first = BotTask(repo: "fixture/quiet", checkout: fixture.root.path)
        model.tasks[quiet.id, default: []].append(first)
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == rowCount)
        #expect(model.botRowSummary(of: quiet).subtitle == "Claude Personal · default")
        #expect(model.botRowSummary(of: quiet).dots == [.idle])
        model.closeTask(.task(first.id, of: quiet.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.openTasks(of: quiet.id).isEmpty)
        #expect(table.numberOfRows == rowCount)
        #expect(model.botRowSummary(of: quiet).subtitle == "Claude Personal · default")
        #expect(model.botRowSummary(of: quiet).dots.isEmpty)
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

    /// #231: a bot dragged in the sidebar goes where it is dropped, before another bot or last, in
    /// its section or another, and Agents and a relaunch show the same order, with the missing bot's
    /// entry. What is shown, drafts, running turns and collapsed sections stay as they were. A drop
    /// that changes nothing saves nothing; one that can't be saved stays, with the banner, until Try Again.
    @Test func draggedBotsGoWhereTheyAreDroppedAndStayThere() throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot, quiet = fixture.quiet
        let task = ChatTarget.task(fixture.tasks[0].id, of: bot.id)
        let gone = Store.Entry(id: UUID(), workspace: fixture.root.appendingPathComponent("gone").path, section: "Research")
        model.missing = [gone]
        model.show(task)
        model.drafts[.home(bot.id)] = "Home draft"
        model.runStates[task] = RunState(startedAt: Date(), hasOutput: true, activity: .coding)
        fixture.defaults.set("Research", forKey: CollapsedSections.storageKey)

        // Within Conversations, before the bot above it.
        model.dropBot(quiet.id, inSection: nil, before: bot.id)
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [quiet.id, bot.id])])
        #expect(fixture.store.loadIndex().map(\.id) == [quiet.id, bot.id, gone.id])
        // On a collapsed section's heading it goes last there; then before the bot already in it.
        model.moveBot(bot.id, toSection: "Research")
        model.dropBot(quiet.id, inSection: "Research", before: nil)
        #expect(model.botSections.groups == [.init(name: "Research", botIDs: [bot.id, quiet.id])])
        model.dropBot(quiet.id, inSection: "Research", before: bot.id)
        #expect(model.botSections.groups == [.init(name: "Research", botIDs: [quiet.id, bot.id])])
        #expect(AgentsView.groups(in: model, matching: "") == model.botSections.groups)
        #expect(fixture.store.loadIndex().map(\.id) == [quiet.id, bot.id, gone.id])
        #expect(fixture.store.loadIndex().map(\.section) == ["Research", "Research", "Research"])
        // Nothing else moved with it.
        #expect(model.sidebarSelection == .bot(bot.id))
        #expect(model.tab(of: bot.id) == task)
        #expect(model.drafts[.home(bot.id)] == "Home draft")
        #expect(model.isRunning(task))
        #expect(fixture.defaults.string(forKey: CollapsedSections.storageKey) == "Research")
        let relaunched = AppModel(store: fixture.store, settings: AppSettings(defaults: fixture.defaults),
                                  usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
        #expect(relaunched.botSections == model.botSections)
        #expect(relaunched.missing == [gone])
        #expect(AgentsView.groups(in: relaunched, matching: "") == model.botSections.groups)

        // On itself, just above the bot after it, or a bot that isn't listed: nothing changes or is saved.
        let index = fixture.store.root.appendingPathComponent("index.json")
        let saved = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        model.dropBot(quiet.id, inSection: "Research", before: quiet.id)
        model.dropBot(quiet.id, inSection: "Research", before: bot.id)
        model.dropBot(UUID(), inSection: nil, before: bot.id)
        #expect(model.botSections.groups == [.init(name: "Research", botIDs: [quiet.id, bot.id])])
        #expect(!FileManager.default.fileExists(atPath: index.path))
        try saved.write(to: index)

        // A drop that can't be saved shows at once, with why; Try Again saves it.
        func lock(_ locked: Bool) throws { try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: index.path) }
        defer { try? lock(false) }
        try lock(true)
        model.dropBot(bot.id, inSection: nil, before: nil)
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [bot.id]), .init(name: "Research", botIDs: [quiet.id])])
        #expect(model.indexFailure?.item == .botIndex)
        #expect(fixture.store.loadIndex().map(\.section) == ["Research", "Research", "Research"])
        try lock(false)
        model.saveIndex()
        #expect(model.indexFailure == nil)
        #expect(fixture.store.loadIndex().map(\.id) == [bot.id, quiet.id, gone.id])
        #expect(fixture.store.loadIndex().map(\.section) == [nil, "Research", "Research"])
    }

    /// #231: a bot's row carries its bot to where it is dropped; anything else dropped carries none.
    @Test func aDraggedBotRowCarriesItsBotOnly() async throws {
        let id = UUID()
        var dropped: [UUID] = []
        let carried = BotDrag.load([BotDrag.provider(for: id)]) { dropped.append($0) }
        let text = BotDrag.load([NSItemProvider(object: id.uuidString as NSString)]) { dropped.append($0) }
        let nothing = BotDrag.load([]) { dropped.append($0) }
        #expect(carried && !text && !nothing)
        for _ in 0..<50 where dropped.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(dropped == [id])
    }

    /// The sidebar's own list takes a dragged bot: between bots through its outline view, and on a
    /// section's heading, collapsed or not, through the heading's drop target, as AppKit hands a real
    /// drag over; text, and drops among the Workspace rows, aren't taken (#231).
    @Test func theSidebarListTakesADraggedBotBetweenBotsAndOnHeadings() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot, quiet = fixture.quiet
        model.moveBot(quiet.id, toSection: "Research")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(250))
        let outline = try #require(sidebarTable(in: host) as? NSOutlineView)
        let source = try #require(outline.dataSource)
        // Workspace, Conversations and Research are the top-level rows; the bots are their children.
        func headings() -> [Int] { (0..<outline.numberOfRows).filter { outline.level(forRow: $0) == 0 } }
        try #require(headings().count == 3)
        func settle(until done: () -> Bool) async throws {
            for _ in 0..<50 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        }
        func pasteboard(_ data: Data, as type: String) -> NSPasteboard {
            let board = NSPasteboard(name: .init("BotChu.SidebarTests.\(UUID().uuidString)"))
            board.clearContents()
            board.setData(data, forType: .init(type))
            return board
        }
        let botType = BotDrag.contentType.identifier, textType = NSPasteboard.PasteboardType.string.rawValue

        // A bot's row gives a drag its bot, as BotChu's own type.
        let botRow = headings()[1] + 1
        let rowItem = try #require(outline.item(atRow: botRow))
        let writer = try #require(source.outlineView?(outline, pasteboardWriterForItem: rowItem))
        #expect(writer.writableTypes(for: .general).contains { $0.rawValue.caseInsensitiveCompare(botType) == .orderedSame })

        // Between bots: dropped first in Conversations, before the bot there.
        func dropBetween(_ data: Data, as type: String, heading: Int, at index: Int) -> Bool {
            let drag = SidebarDrag(pasteboard(data, as: type), in: window)
            let item = outline.item(atRow: heading)
            guard source.outlineView?(outline, validateDrop: drag, proposedItem: item, proposedChildIndex: index) != [] else { return false }
            return source.outlineView?(outline, acceptDrop: drag, item: item, childIndex: index) ?? false
        }
        #expect(!dropBetween(Data(quiet.id.uuidString.utf8), as: textType, heading: headings()[1], at: 0))
        #expect(!dropBetween(BotSections.dragPayload(quiet.id), as: botType, heading: headings()[0], at: 1))
        #expect(dropBetween(BotSections.dragPayload(quiet.id), as: botType, heading: headings()[1], at: 0))
        try await settle { model.botSections.groups.count == 1 }
        #expect(model.botSections.groups == [.init(name: nil, botIDs: [quiet.id, bot.id])])

        // On a heading, collapsed or not: last in that section.
        model.moveBot(quiet.id, toSection: "Research")
        fixture.defaults.set("Research", forKey: CollapsedSections.storageKey)
        try await Task.sleep(for: .milliseconds(150))
        func dropOnHeading(_ data: Data, as type: String, _ heading: Int) throws -> Bool {
            let row = try #require(outline.rowView(atRow: heading, makeIfNecessary: true))
            let target = try #require(dropTarget(in: row))
            let drag = SidebarDrag(pasteboard(data, as: type), in: window,
                                   at: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil))
            guard target.draggingEntered(drag) != [] else { return false }
            return target.performDragOperation(drag)
        }
        #expect(try !dropOnHeading(Data(bot.id.uuidString.utf8), as: textType, headings()[2]))
        #expect(try dropOnHeading(BotSections.dragPayload(bot.id), as: botType, headings()[2]))
        try await settle { model.botSections.groups.count == 1 }
        #expect(model.botSections.groups == [.init(name: "Research", botIDs: [quiet.id, bot.id])])
        #expect(fixture.defaults.string(forKey: CollapsedSections.storageKey) == "Research")
        #expect(fixture.store.loadIndex().map(\.section) == ["Research", "Research"])
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
        // A row's Move to Section is the sidebar's, with its own section checked.
        let row = NSHostingView(rootView: AgentRowHarness(bot: bot).environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = row
        window.setContentSize(NSSize(width: 1000, height: 100))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        func moveMenu() throws -> NSMenu {
            try #require(try agentsMenu(at: NSPoint(x: 40, y: row.bounds.midY), in: row)
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

    /// #250: specialists leave the owner's sections for one Specialists section, last and collapsed
    /// until opened, whose heading has no menu and takes no drops. A specialist's row has no New
    /// Task… or Move to Section and gives no drag; showing one opens the section. Its section is
    /// kept, so it is back in it as an agent.
    @Test func specialistsAreLastInTheSidebarCollapsedWithoutTaskActions() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        model.moveBot(fixture.quiet.id, toSection: "Research")
        var quiet = try #require(model.bot(fixture.quiet.id))
        quiet.role = .specialist
        model.update(quiet)
        #expect(model.agentSections.groups == [.init(name: nil, botIDs: [bot.id])])
        #expect(model.specialists.map(\.id) == [quiet.id])
        #expect(model.sections[quiet.id] == "Research")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let outline = try #require(sidebarTable(in: host) as? NSOutlineView)
        let source = try #require(outline.dataSource)
        func headings() -> [Int] { (0..<outline.numberOfRows).filter { outline.level(forRow: $0) == 0 } }
        // Workspace, Conversations with the agent, then Specialists, collapsed: its row is hidden.
        #expect(headings().count == 3)
        #expect(outline.numberOfRows == firstBotRow + 2)
        #expect(headings().last == outline.numberOfRows - 1)
        #expect(!fixture.defaults.bool(forKey: "sidebar.specialistsExpanded"))
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            DevHooks.snapshotSidebar(model: model, into: URL(fileURLWithPath: path).appendingPathComponent("sidebar-specialists"))
        }
        // Its heading has no section menu and takes no bot, dropped on it or among its rows.
        let specialistsHeading = try #require(headings().last)
        #expect(try sidebarMenuIfAny(row: specialistsHeading, of: outline, in: host)?.items.contains { $0.title == "Rename Section…" } != true)
        let headingRow = try #require(outline.rowView(atRow: specialistsHeading, makeIfNecessary: true))
        #expect(dropTarget(in: headingRow) == nil)
        let board = NSPasteboard(name: .init("BotChu.SidebarTests.\(UUID().uuidString)"))
        board.clearContents()
        board.setData(BotSections.dragPayload(bot.id), forType: .init(BotDrag.contentType.identifier))
        #expect(source.outlineView?(outline, validateDrop: SidebarDrag(board, in: window),
                                    proposedItem: outline.item(atRow: specialistsHeading), proposedChildIndex: 0) == [])
        // Opened, its specialist's menu starts no task and moves it nowhere, and its row gives no drag.
        fixture.defaults.set(true, forKey: "sidebar.specialistsExpanded")
        try await Task.sleep(for: .milliseconds(150))
        #expect(outline.numberOfRows == firstBotRow + 3)
        let menu = try sidebarMenu(row: outline.numberOfRows - 1, of: outline, in: host)
        #expect(menu.items.map(\.title) == ["Edit…", "New Session", "Show Workspace in Finder", "", "Delete…"])
        let item = try #require(outline.item(atRow: outline.numberOfRows - 1))
        #expect(source.outlineView?(outline, pasteboardWriterForItem: item) == nil)
        // An agent's menu still has them.
        let agentMenu = try sidebarMenu(row: firstBotRow, of: outline, in: host)
        #expect(agentMenu.items.map(\.title).contains("New Task…") && agentMenu.items.map(\.title).contains("Move to Section"))
        // A specialist dropped on a section stays out of it.
        model.dropBot(quiet.id, inSection: nil, before: bot.id)
        #expect(model.sections[quiet.id] == "Research")
        // Collapsed again, showing the specialist opens it.
        fixture.defaults.set(false, forKey: "sidebar.specialistsExpanded")
        try await Task.sleep(for: .milliseconds(150))
        #expect(outline.numberOfRows == firstBotRow + 2)
        model.show(.home(quiet.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.defaults.bool(forKey: "sidebar.specialistsExpanded"))
        #expect(outline.numberOfRows == firstBotRow + 3)
        // An agent again, it is back in its section, and Specialists is gone.
        quiet.role = .agent
        model.update(quiet)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.agentSections.groups == [.init(name: nil, botIDs: [bot.id]), .init(name: "Research", botIDs: [quiet.id])])
        #expect(headings().count == 3)
        #expect(outline.numberOfRows == firstBotRow + 3)
    }

    /// #250: Agents is a table per section, then the specialists' table with New Specialist; the
    /// top count and the sections' tables are the agents'. A search finds specialists as agents. A
    /// specialist's row has no task counts and its menu no task, job or section actions.
    @Test func agentsShowsAgentsAndSpecialistsInSeparateTables() async throws {
        _ = NSApplication.shared
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        var quiet = fixture.quiet
        quiet.role = .specialist
        model.update(quiet)
        quiet = try #require(model.bot(quiet.id))
        #expect(AgentsView.groups(in: model, matching: "") == [.init(name: nil, botIDs: [bot.id])])
        #expect(AgentsView.specialists(in: model, matching: "").map(\.id) == [quiet.id])
        #expect(AgentsView.groups(in: model, matching: "scout").isEmpty)
        #expect(AgentsView.specialists(in: model, matching: "scout").map(\.id) == [quiet.id])
        #expect(AgentsView.specialists(in: model, matching: "SPECIAL").map(\.id) == [quiet.id])
        #expect(AgentsView.specialists(in: model, matching: "10x").isEmpty)
        // Tasks · Jobs: the agent's three open tasks and no jobs; nothing for the specialist.
        #expect(AgentTableRow.counts(of: bot, in: model) == "3 · 0")
        #expect(AgentTableRow.counts(of: quiet, in: model) == nil)
        // Columns: all of them wide; narrower, counts go and status folds, then account is its mark.
        #expect(AgentColumns(width: 1000).showsCounts && !AgentColumns(width: 1000).statusInName)
        #expect(!AgentColumns(width: 979).showsCounts && AgentColumns(width: 979).statusInName && !AgentColumns(width: 979).accountMarkOnly)
        #expect(AgentColumns(width: 779).accountMarkOnly && AgentColumns(width: 779).account == 40 && !AgentColumns(width: 779).effortGlyphOnly)
        #expect(AgentColumns(width: 679).effortGlyphOnly)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let gallery = NSHostingView(rootView: AgentsView().environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = gallery
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
            for (name, width) in [("agents-specialists", 1000.0), ("agents-specialists-900", 900.0), ("agents-specialists-700", 700.0)] {
                window.setContentSize(NSSize(width: width, height: 700))
                try await Task.sleep(for: .milliseconds(300))
                try agentsCapture(window, into: URL(fileURLWithPath: path), name: name)
            }
            window.setContentSize(NSSize(width: 1000, height: 700))
        }
        // New Agent, at the top, and New Specialist, beside its heading, open New Bot in their roles.
        func click(across xs: [CGFloat], fromTop y: CGFloat, in host: NSView, until done: () -> Bool) async throws {
            for x in xs where !done() {
                let point = host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                                clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                try await Task.sleep(for: .milliseconds(60))
            }
        }
        // The page's heading is 24 points in, its button at its trailing end.
        try await click(across: stride(from: gallery.bounds.width - 30, to: gallery.bounds.width - 200, by: -15).map { $0 },
                        fromTop: 24 + 20, in: gallery) { model.editor != nil }
        #expect(model.editor?.isNew == true && model.editor?.bot.role == .agent)
        model.editor = nil
        let heading = NSHostingView(rootView: SpecialistsHeading(count: 1).frame(width: 420, height: 44)
            .environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = heading
        try await Task.sleep(for: .milliseconds(250))
        try await click(across: stride(from: 130, to: 400, by: 12).map { $0 }, fromTop: 22, in: heading) { model.editor != nil }
        #expect(model.editor?.isNew == true && model.editor?.bot.role == .specialist)
        model.editor = nil

        // A row's menu: an agent's has its task, job and section actions; a specialist's has none.
        func rowMenu(_ bot: Bot) async throws -> [String] {
            let row = NSHostingView(rootView: AgentRowHarness(bot: bot).environment(model).defaultAppStorage(fixture.defaults))
            window.contentView = row
            try await Task.sleep(for: .milliseconds(250))
            return try agentsMenu(at: NSPoint(x: 40, y: row.bounds.midY), in: row).items.map(\.title)
        }
        #expect(try await rowMenu(bot) == ["Open Chat", "Edit…", "", "New Task…", "New Job…", "Show Jobs", "",
                                           "Move to Section", "Show Workspace in Finder", "", "Delete…"])
        #expect(try await rowMenu(quiet) == ["Open Chat", "Edit…", "", "Show Workspace in Finder", "", "Delete…"])
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

    /// The context menu a right click on the row shows, if any.
    private func sidebarMenuIfAny(row: Int, of table: NSTableView, in host: NSView) throws -> NSMenu? {
        let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: false))
        let point = rowView.convert(NSPoint(x: 60, y: rowView.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: host.window?.windowNumber ?? 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        var view = host.hitTest(host.convert(point, from: nil))
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        return nil
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

    /// Where a view draws violet (the working dots), in points from its top left, within its last 80 points.
    private func violet(in view: NSView) throws -> CGRect? {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        var found: CGRect?
        for y in 0..<rep.pixelsHigh {
            for x in Int((view.bounds.width - 80) * scale)..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), colour.alphaComponent > 0.5,
                      colour.saturationComponent > 0.4, (0.66...0.78).contains(colour.hueComponent) else { continue }
                let pixel = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
                found = found.map { $0.union(pixel) } ?? pixel
            }
        }
        return found
    }

    private func sidebarButtons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(sidebarButtons)
    }

    /// The deepest view in a row that takes drops, as a heading's `onDrop` puts there.
    private func dropTarget(in view: NSView) -> NSView? {
        for subview in view.subviews { if let found = dropTarget(in: subview) { return found } }
        return view.registeredDraggedTypes.isEmpty ? nil : view
    }

    private func sidebarTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap(sidebarTable).first
    }
}

/// A drag as AppKit hands it to a drop target, carrying a pasteboard.
private final class SidebarDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    init(_ pasteboard: NSPasteboard, in window: NSWindow, at location: NSPoint = .zero) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingLocation = location
    }
    var draggingSourceOperationMask: NSDragOperation { [.move, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
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

    /// `taskCount` tasks for the first bot.
    init(taskCount: Int = 3) throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        bot = Bot(name: "10x Engineer", emoji: "🦊", workspace: root.appendingPathComponent("bot").path)
        quiet = Bot(name: "Scout", emoji: "🔭", workspace: root.appendingPathComponent("quiet").path)
        let checkout = root.path
        tasks = (41..<41 + taskCount).map { number in
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

/// A bot's row as Agents shows it at full width, with the alert that names a section for it.
private struct AgentRowHarness: View {
    let bot: Bot
    @State private var naming = SectionNaming()

    var body: some View {
        AgentTableRow(bot: bot, columns: AgentColumns(width: 1000), newSection: { naming.ask(.new(botID: bot.id)) }, delete: {})
            .frame(width: 952)
            .padding(24)
            .sectionNamingAlert($naming)
    }
}
