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
    let tasks: [BotTask]
    let model: AppModel

    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        bot = Bot(name: "10x Engineer", emoji: "🦊", workspace: root.appendingPathComponent("bot").path)
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
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                         usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
    }

    func cleanUp() {
        model.runStates.removeAll()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
