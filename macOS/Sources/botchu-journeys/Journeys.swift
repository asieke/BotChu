import AppKit
import BotChuCore

/// Journeys 1–3 of #323, against the app under test on the fixture. Each step is timed from just
/// before the harness acts until the app's frame mark for what it shows, then checked on screen
/// through accessibility; nothing reads the screen while a step is timed.
struct Journeys {
    static let catalog: [(number: Int, names: [String])] = [
        (1, ["launch"]),
        (2, ["sidebar", "inspector"]),
        (3, ["switch-bot", "switch", "bots"]),
    ]

    let app: AppUnderTest
    let fixture: Fixture
    let baseline: JourneyBaseline?
    let repeats: Int
    let report: (JourneyResult) -> Void

    private func result(_ journey: Int, _ step: String, _ budget: JourneyBudget, _ samples: [Double], problem: String? = nil) -> JourneyResult {
        let result = JourneyResult(journey: journey, step: step, budget: budget, baseline: baseline?.medians["\(journey) \(step)"],
                                   samples: samples, problem: problem)
        report(result)
        return result
    }

    func notRun(_ journey: Int, because reason: String) -> JourneyResult {
        result(journey, "not run", .instant, [], problem: reason)
    }

    private static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(Int64(to) - Int64(from)) / 1_000_000 }

    // MARK: 1. Cold launch

    /// Until the window, the sidebar's rows and the first bot's latest messages show: a first
    /// launch on the new fixture (not counted), then `launches` timed ones. The app stays open.
    func launch(launches: Int = 3) -> [JourneyResult] {
        var samples: [Double] = []
        do {
            for attempt in 0...launches {
                if attempt > 0 { app.quit() }
                try fixture.markProjectsSynced()
                let start = try app.launch()
                let shown = [FrameMarks.window, FrameMarks.sidebarRow, FrameMarks.chat(fixture.longBot.id)]
                let last = try shown.map { try app.mark($0, after: start, timeout: 60).nanoseconds }.max()!
                let time = Self.ms(start, last)
                if attempt == 0 { print(String(format: "journeys: first launch on the new fixture %.0f ms (not counted)", time)) }
                else { samples.append(time) }
                app.settle(quiet: 0.5, limit: 10)
                try app.requireBackground()
                try checkShown(fixture.longBot)
            }
            return [result(1, "launch", .launch, samples)]
        } catch {
            return [result(1, "launch", .launch, samples, problem: "\(error)")]
        }
    }

    /// The bot's conversation shows: its name as the window's title, its row in the sidebar and its
    /// latest message in the chat.
    func checkShown(_ bot: Bot, sidebar: Bool = true) throws {
        let window = try app.window()
        guard window.title == bot.name else { throw HarnessFailure("The window's title is \"\(window.title)\", not \(bot.name)") }
        if sidebar, window.first(identifier: "sidebar-bot-\(bot.id.uuidString)") == nil {
            throw HarnessFailure("The sidebar shows no row for \(bot.name)")
        }
        guard let last = fixture.lastItem[bot.id], window.first(identifier: "chat-item-\(last.uuidString)") != nil else {
            throw HarnessFailure("The chat doesn't show \(bot.name)'s latest message")
        }
    }

    // MARK: 2. Sidebar and inspector

    /// Closes and opens the sidebar, then the status sidebar (the inspector), `repeats` times each.
    func sidebarAndInspector() -> [JourneyResult] {
        toggles("sidebar", button: sidebarButton, shown: FrameMarks.sidebar(shown:), check: checkSidebar(shown:))
            + toggles("inspector", button: statusButton, shown: FrameMarks.inspector(shown:), check: checkInspector(shown:))
    }

    private func toggles(_ name: String, button: () throws -> AXElement, shown mark: (Bool) -> String,
                         check: (Bool) throws -> Void) -> [JourneyResult] {
        var close: [Double] = [], open: [Double] = []
        var problem: String?
        do {
            for _ in 0..<repeats {
                close.append(try toggle(button, mark: mark(false)))
                try check(false)
                open.append(try toggle(button, mark: mark(true)))
                try check(true)
            }
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(2, "\(name) · close", .instant, close, problem: problem), result(2, "\(name) · open", .instant, open, problem: problem)]
    }

    /// Presses the button `find` finds and times it until `mark`, then lets the animation finish.
    private func toggle(_ find: () throws -> AXElement, mark: String) throws -> Double {
        let button = try find()
        let start = AppUnderTest.now
        try button.press()
        let shown = try app.mark(mark, after: start)
        app.settle(quiet: 0.5)
        return Self.ms(start, shown.nanoseconds)
    }

    /// The toolbar's Hide Sidebar / Show Sidebar button (the split view's own, without an identifier).
    private func sidebarButton() throws -> AXElement {
        let window = try app.window()
        guard let toolbar = window.children.first(where: { $0.role == kAXToolbarRole as String }),
              let button = toolbar.first(where: { $0.role == kAXButtonRole as String && ["Hide Sidebar", "Show Sidebar"].contains($0.label) }) else {
            throw HarnessFailure("The toolbar has no Hide Sidebar button")
        }
        return button
    }

    /// The toolbar's Hide Status / Show Status button.
    private func statusButton() throws -> AXElement {
        let window = try app.window()
        guard let button = window.first(identifier: "toolbar-status")
                ?? window.first(where: { $0.role == kAXButtonRole as String && ["Hide Status", "Show Status"].contains($0.label) }) else {
            throw HarnessFailure("The toolbar has no Hide Status button")
        }
        return button
    }

    /// The sidebar's button says what it does next, and the first bot's row is in view or not.
    private func checkSidebar(shown: Bool) throws {
        let label = try sidebarButton().label
        let row = try app.window().first(identifier: "sidebar-bot-\(fixture.longBot.id.uuidString)")
        let visible = (row?.frame).map { $0.width > 0 && $0.height > 0 } ?? false
        guard label == (shown ? "Hide Sidebar" : "Show Sidebar"), visible == shown else {
            throw HarnessFailure("After the sidebar was \(shown ? "opened" : "closed"), its button says \"\(label)\" and the first bot's row is \(visible ? "in view" : "out of view")")
        }
    }

    private func checkInspector(shown: Bool) throws {
        let button = try statusButton()
        let label = button.label.isEmpty ? button.title : button.label
        let expected = shown ? "Hide Status" : "Show Status"
        guard label == expected else { throw HarnessFailure("The status button says \"\(label)\" after the status sidebar was \(shown ? "opened" : "closed")") }
    }

    // MARK: 3. Switching bots

    /// Selects other bots in the sidebar, each followed by the first bot (its 5,000-message
    /// conversation), `repeats` times each, timed until the selected bot's chat rows show.
    func switchBots() -> [JourneyResult] {
        var others: [Double] = [], long: [Double] = []
        var problem: String?
        do {
            for index in 0..<repeats {
                let other = fixture.bots[2 + index % (fixture.bots.count - 2)]
                others.append(try select(other))
                long.append(try select(fixture.longBot))
            }
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(3, "switch bot", .within(50), others, problem: problem),
                result(3, "switch to 5,000 messages", .within(50), long, problem: problem)]
    }

    /// Selects `bot`'s row in the sidebar; the time until its chat shows a row.
    private func select(_ bot: Bot) throws -> Double {
        let window = try app.window()
        guard let cell = window.first(identifier: "sidebar-bot-\(bot.id.uuidString)") else { throw HarnessFailure("The sidebar shows no row for \(bot.name)") }
        let row = cell.ancestor(role: kAXRowRole as String) ?? cell
        let start = AppUnderTest.now
        try row.set(kAXSelectedAttribute, to: kCFBooleanTrue)
        let shown = try app.mark(FrameMarks.chat(bot.id), after: start)
        app.settle()
        try checkShown(bot)
        return Self.ms(start, shown.nanoseconds)
    }
}
