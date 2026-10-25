import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// #128: a bot's Home and open tasks as tabs in a column beside its chat, or a rail of tiles.
extension RenderingTests {
    /// Native clicks on the column: a tab shows its conversation, the dot of an idle task turns into
    /// a close button on hover (not a running one's), + starts a new task, « and » collapse and
    /// expand, and the arrow keys move between tabs. It runs in its own process (`macOS/test.sh`),
    /// as native clicks leave AppKit state behind that can stop later tests' run loop.
    @Test func conversationColumnSwitchesClosesAndCollapsesByNativeClicks() async throws {
        _ = NSApplication.shared
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let tasks = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        // The second task's turn runs; the first is idle and the third failed.
        model.runStates[tasks[1]] = RunState(startedAt: Date().addingTimeInterval(-252), hasOutput: true, activity: .coding)
        model.show(tasks[0])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ConversationSplit(botID: bot.id) { Color.clear }
            .environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        // Rows, from the top: Home, the heading, then each task, two lines each.
        let home = NSPoint(x: 120, y: 33), heading: CGFloat = 77
        func row(_ index: Int) -> NSPoint { NSPoint(x: 120, y: 124 + CGFloat(index) * 52) }
        func click(_ point: NSPoint, in view: NSView? = nil) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { send(type, at: point, in: view ?? host) }
            try await Task.sleep(for: .milliseconds(150))
        }

        try await click(home)
        #expect(model.tab(of: bot.id) == .home(bot.id))
        try await click(row(2))
        #expect(model.tab(of: bot.id) == tasks[2])
        try await click(row(1))
        #expect(model.tab(of: bot.id) == tasks[1])

        // Hovered, a running task's dot stays: a click there shows it, and it stays open. SwiftUI
        // reads hover from the real pointer, so the row is drawn hovered on its own for this.
        try await click(home)
        let column = window.contentView
        window.contentView = NSHostingView(rootView: HoveredRow(target: tasks[1]).environment(model).defaultAppStorage(fixture.defaults))
        try await Task.sleep(for: .milliseconds(200))
        try await click(NSPoint(x: 16, y: 17), in: try #require(window.contentView))
        #expect(model.tab(of: bot.id) == tasks[1])
        #expect(model.openTasks(of: bot.id).count == 3)
        // An idle one's turns into a close button, which closes it; the tab above it shows.
        model.show(tasks[0])
        window.contentView = NSHostingView(rootView: HoveredRow(target: tasks[0]).environment(model).defaultAppStorage(fixture.defaults))
        try await Task.sleep(for: .milliseconds(200))
        try await click(NSPoint(x: 16, y: 17), in: try #require(window.contentView))
        #expect(model.openTasks(of: bot.id).map(\.id) == [fixture.tasks[1].id, fixture.tasks[2].id])
        #expect(model.tab(of: bot.id) == .home(bot.id))
        #expect(model.closedTasks(of: bot.id).map(\.id) == [fixture.tasks[0].id])
        window.contentView = column
        try await Task.sleep(for: .milliseconds(200))

        // + starts a new task, as ⌘T does.
        try await click(NSPoint(x: 188, y: heading))
        #expect(model.taskSheet?.botID == bot.id)
        model.taskSheet = nil

        // The arrow keys move between tabs while one has keyboard focus, which stays with the tabs.
        window.makeFirstResponder(host)
        sendKey("\t", code: 48, to: window)
        try await Task.sleep(for: .milliseconds(150))
        sendKey("\u{F701}", code: 125, to: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.tab(of: bot.id) == tasks[1])
        sendKey("\u{F701}", code: 125, to: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.tab(of: bot.id) == tasks[2])
        sendKey("\u{F700}", code: 126, to: window)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.tab(of: bot.id) == tasks[1])

        // « collapses the column to the rail, which the owner's choice keeps; » expands it.
        try await click(NSPoint(x: 220, y: heading))
        #expect(fixture.defaults.bool(forKey: ConversationColumnSettings.collapsedKey))
        // The rail's tiles: Home, then each task; » at its foot.
        try await click(NSPoint(x: 28, y: 28))
        #expect(model.tab(of: bot.id) == .home(bot.id))
        try await click(NSPoint(x: 28, y: 28 + 20 + 5 + 4 + 20 + 44))
        #expect(model.tab(of: bot.id) == tasks[2])
        try await click(NSPoint(x: 28, y: host.bounds.height - 22))
        #expect(!fixture.defaults.bool(forKey: ConversationColumnSettings.collapsedKey))
        try await click(home)
        #expect(model.tab(of: bot.id) == .home(bot.id))
    }

    /// The column beside the chat while the bot has an open task, in light and dark; the rail by
    /// itself at the narrowest window, and by the owner's choice, which a relaunch keeps; no column
    /// without an open task, when New Task is back in the toolbar.
    @Test func conversationColumnFollowsTheWindowAndTheOwnersChoice() async throws {
        _ = NSApplication.shared
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let tasks = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        model.runStates[tasks[1]] = RunState(startedAt: Date().addingTimeInterval(-252), hasOutput: true, activity: .coding)
        model.unread.insert(tasks[0])
        model.show(tasks[1])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1700, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func show() async throws -> NSView {
            let host = NSHostingView(rootView: ContentView().environment(model).defaultAppStorage(fixture.defaults))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await settle(window)
            return host
        }
        var host = try await show()
        func snapshot(_ name: String) {
            if let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] {
                DevHooks.snapshot(into: URL(fileURLWithPath: path).appendingPathComponent(name))
            }
        }
        func toolbarLabels() -> [String] { (window.toolbar?.items ?? []).map(\.label) }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            NSApp.appearance = NSAppearance(named: appearance)
            let name = appearance == .aqua ? "light" : "dark"
            // Wide: the column, and the chat beside it at its full readable width.
            window.setFrame(NSRect(x: 0, y: 0, width: 1700, height: 900), display: true)
            try await settle(window)
            #expect(abs(try chatInset(in: host) - ConversationColumnLayout.width) <= 1)
            snapshot("conversation-column-\(name)")
            // As narrow as the window goes: the rail, by itself, and the window still fits its columns.
            window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 900), display: true)
            try await settle(window)
            #expect(window.frame.width >= window.contentMinSize.width)
            #expect(abs(try chatInset(in: host) - ConversationColumnLayout.railWidth) <= 1)
            snapshot("conversation-rail-\(name)")
            // And back when the window widens again.
            window.setFrame(NSRect(x: 0, y: 0, width: 1700, height: 900), display: true)
            try await settle(window)
            #expect(abs(try chatInset(in: host) - ConversationColumnLayout.width) <= 1)
        }
        // Folding by itself isn't the owner's choice, so nothing is kept for it.
        #expect(fixture.defaults.object(forKey: ConversationColumnSettings.collapsedKey) == nil)
        // While the bot has an open task, New Task is the column's +, not in the toolbar.
        #expect(toolbarLabels().contains("Chat Density"))
        #expect(!toolbarLabels().contains("New Task"))

        // Collapsed by the owner (View ▸ Collapse Tasks, or «), it stays the rail, also after a relaunch.
        fixture.defaults.set(true, forKey: ConversationColumnSettings.collapsedKey)
        try await settle(window)
        #expect(abs(try chatInset(in: host) - ConversationColumnLayout.railWidth) <= 1)
        host = try await show()
        #expect(abs(try chatInset(in: host) - ConversationColumnLayout.railWidth) <= 1)
        fixture.defaults.removeObject(forKey: ConversationColumnSettings.collapsedKey)
        try await settle(window)

        // A bot with no open task has no column; New Task is back in the toolbar.
        model.show(.home(fixture.quiet.id))
        try await settle(window)
        #expect(abs(try chatInset(in: host)) <= 1)
        #expect(toolbarLabels().contains("New Task"))
        snapshot("conversation-none")
    }

    /// What the tabs and the bot's row read from the model: each conversation's state, its tab's
    /// texts, the row's dots and subtitle, and the shortcuts and close order of the tabs.
    @Test func conversationTabsReadTheModelAndMoveTheSelectionUpOnClose() throws {
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let home = ChatTarget.home(bot.id)
        let tasks = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        #expect(model.tabs(of: bot.id) == [home] + tasks)
        // Nothing running: the open tasks' count, and no dots.
        #expect(model.botRowSummary(of: bot).subtitle == "3 tasks")
        #expect(model.botRowSummary(of: bot).dots.isEmpty)
        #expect(model.botRowSummary(of: fixture.quiet).subtitle == fixture.quiet.account.name)
        // One running, one with news (and its pull request), one failed (from its thread).
        model.runStates[tasks[1]] = RunState(startedAt: Date().addingTimeInterval(-60), hasOutput: true, activity: .coding)
        model.tasks[bot.id]?[0].pullRequest = 122
        model.unread.insert(tasks[0])
        model.conversation(tasks[2]).replace([ChatMessage(role: .user, text: "Go"), ChatMessage(role: .error, text: "It broke")])
        #expect(model.tabState(of: tasks[0]).kind == .news)
        #expect(model.conversationTab(of: tasks[0])?.detail == "Finished · PR #122")
        #expect(model.conversationTab(of: tasks[1])?.detail == "Editing code…")
        #expect(model.conversationTab(of: tasks[2])?.detail == "Turn failed")
        #expect(model.conversationTab(of: tasks[2])?.title == "repo #43")
        #expect(model.conversationTab(of: tasks[2])?.subject == "Speed up the sync")
        #expect(model.conversationTab(of: home)?.detail == bot.account.name)
        let summary = model.botRowSummary(of: bot)
        #expect(summary.dots == [.news, .working, .failed])
        #expect(summary.subtitle == "Working on #42")
        // Shown, the news is read; the failure stays until the next turn starts.
        model.show(tasks[0])
        model.show(tasks[2])
        #expect(model.tabState(of: tasks[0]).kind == .idle)
        #expect(model.tabState(of: tasks[2]).kind == .failed)
        #expect(ChatView.placeholder(bot: bot, task: fixture.tasks[2]) == "Message 10x Engineer about #43")
        #expect(ChatView.placeholder(bot: bot, task: nil) == "Message 10x Engineer")

        // ⌘1 shows Home, ⌘2 to ⌘9 the tasks; also from a gallery. Past the last tab, nothing.
        model.showTab(at: 0, of: bot.id)
        #expect(model.tab(of: bot.id) == home)
        model.destination = .projects
        model.showTab(at: 3, of: bot.id)
        #expect(model.destination == nil && model.tab(of: bot.id) == tasks[2])
        model.showTab(at: 9, of: bot.id)
        #expect(model.tab(of: bot.id) == tasks[2])

        // Closing the shown task shows the tab above it; closing another leaves the shown one.
        model.runStates[tasks[1]] = nil
        model.closeTask(tasks[2])
        #expect(model.tab(of: bot.id) == tasks[1])
        model.show(tasks[1])
        model.closeTask(tasks[0])
        #expect(model.tab(of: bot.id) == tasks[1])
        model.closeTask(tasks[1])
        #expect(model.tab(of: bot.id) == home)
        // A task closed while its bot isn't shown leaves the gallery shown.
        model.reopenTask(tasks[0])
        model.destination = .agents
        model.closeTask(tasks[0])
        #expect(model.destination == .agents && model.tab(of: bot.id) == home)
    }

    /// A task's tab keeps the task's menu: its issue, branch, folder and Terminal, New Session and
    /// Close Task; Home's has New Session. Menus need no clicks (`menu(for:)`).
    @Test func conversationTabsKeepTheTaskMenu() async throws {
        _ = NSApplication.shared
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ConversationSplit(botID: bot.id) { Color.clear }
            .environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        let task = try tabMenu(at: NSPoint(x: 120, y: 124), in: host)
        #expect(task.items.map(\.title) == ["Open Issue #41", "Copy Branch Name", "Show Task Folder in Finder", "Open Task in Terminal", "",
                                            "New Session", "Close Task"])
        // Its worktree isn't made yet.
        #expect(task.items.filter { !$0.isEnabled && !$0.isSeparatorItem }.map(\.title) == ["Show Task Folder in Finder", "Open Task in Terminal"])
        let home = try tabMenu(at: NSPoint(x: 120, y: 33), in: host)
        #expect(home.items.map(\.title) == ["New Session"])
        task.performActionForItem(at: task.indexOfItem(withTitle: "Close Task"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.openTasks(of: bot.id).map(\.id) == [fixture.tasks[1].id, fixture.tasks[2].id])
    }

    /// Home's status sidebar lists only closed tasks, to open again: none while none is closed.
    @Test func homeStatusListsOnlyClosedTasks() async throws {
        _ = NSApplication.shared
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        func height() async throws -> CGFloat {
            let host = NSHostingView(rootView: ClosedTasksSection(botID: bot.id).frame(width: 340)
                .environment(model).defaultAppStorage(fixture.defaults))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            return host.fittingSize.height
        }
        #expect(try await height() == 0)
        model.closeTask(.task(fixture.tasks[0].id, of: bot.id))
        #expect(try await height() > 10)
    }

    /// How far the chat starts from the sidebar's edge: the column's or the rail's width, or
    /// nothing. The detail column runs under the sidebar (which floats over it on macOS 26), and so
    /// does the chat's scroll view when nothing is beside it.
    private func chatInset(in host: NSView) throws -> CGFloat {
        let splits = tabSplitViews(in: host)
        try #require(splits.count == 2)
        let sidebar = try #require(splits[0].arrangedSubviews.first)
        let content = try #require(splits[1].arrangedSubviews.first)
        var widest: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView != nil, scroll.frame.width > (widest?.frame.width ?? 0) { widest = scroll }
            view.subviews.forEach(visit)
        }
        visit(content)
        let chat = try #require(widest)
        return max(0, chat.convert(chat.bounds, to: nil).minX - sidebar.convert(sidebar.bounds, to: nil).maxX)
    }

    /// The context menu a right click at a point (from the host's top-left corner) shows, as AppKit
    /// asks the views under the pointer for it.
    private func tabMenu(at point: NSPoint, in host: NSView) throws -> NSMenu {
        let event = mouseEvent(.rightMouseDown, at: point, in: host)
        var view = host.hitTest(host.convert(event.locationInWindow, from: nil))
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        return try #require(menu)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<6 {
            window.updateConstraintsIfNeeded()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func tabSplitViews(in view: NSView) -> [NSSplitView] {
        ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(tabSplitViews)
    }

    /// A mouse event at a point measured from the host's top-left corner, sent to its window.
    private func send(_ type: NSEvent.EventType, at point: NSPoint, in host: NSView) {
        host.window?.sendEvent(mouseEvent(type, at: point, in: host))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in host: NSView) -> NSEvent {
        let location = host.convert(NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: host.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 1, clickCount: 1, pressure: type == .mouseMoved ? 0 : 1)!
    }

    private func sendKey(_ text: String, code: UInt16, to window: NSWindow) {
        // Hardware arrow keys include Function and Numeric Pad flags.
        let flags: NSEvent.ModifierFlags = code == 48 ? [] : [.function, .numericPad]
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
}

/// A task's tab as the column draws it under the pointer.
private struct HoveredRow: View {
    let target: ChatTarget
    @FocusState private var focus: ChatTarget?

    var body: some View {
        ConversationRow(target: target, index: 1, selected: false, hovered: true, focus: $focus) { _ in }
            .frame(width: 232)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A bot with three open tasks, each an issue with a short title, and a second bot without any.
@MainActor private final class TabsFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-tabs-\(UUID().uuidString)")
    let domain = "BotChu.TabsTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let bot: Bot
    let quiet: Bot
    let tasks: [BotTask]
    let model: AppModel

    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        bot = Bot(name: "10x Engineer", emoji: "🦊", workspace: root.appendingPathComponent("bot").path)
        quiet = Bot(name: "Scout", emoji: "🔭", workspace: root.appendingPathComponent("quiet").path)
        let titles = [41: "Fix the typo", 42: "Add a filter bar", 43: "Speed up the sync"], checkout = root.path
        tasks = (41...43).map { number in
            BotTask(repo: "fixture/repo", checkout: checkout, branch: "feat/\(number)-task",
                    work: .init(number: number, title: titles[number]!, url: URL(string: "https://github.com/fixture/repo/issues/\(number)")!,
                                isPullRequest: false),
                    createdAt: Date(timeIntervalSince1970: Double(number)))
        }
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        for task in tasks { try home.save(task) }
        try BotHome(workspace: quiet.workspace).save(quiet)
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace), Store.Entry(id: quiet.id, workspace: quiet.workspace)])
        model = AppModel(store: store, settings: AppSettings(defaults: defaults),
                         usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
    }

    func cleanUp() {
        model.runStates.removeAll()
        model.stopAll()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
