import AppKit
import BotChuCore

/// The 13 journeys of #323, against the app under test on the fixture. Each step is timed from just
/// before the harness acts until the app's frame mark for what it shows, then checked on screen
/// through accessibility; nothing reads the screen while a step is timed.
struct Journeys {
    static let catalog: [(number: Int, names: [String])] = [
        (1, ["launch"]),
        (2, ["sidebar", "inspector"]),
        (3, ["switch-bot", "switch", "bots"]),
        (4, ["switch-task", "tasks"]),
        (5, ["typing", "type"]),
        (6, ["send", "stream", "chat"]),
        (7, ["scroll", "history"]),
        (8, ["expand", "group"]),
        (9, ["new-task"]),
        (10, ["resize"]),
        (11, ["inbox", "settings"]),
        (12, ["subagent", "sub-agent"]),
        (13, ["relaunch", "quit"]),
    ]

    /// What earlier journeys left for journey 13 to find after a relaunch.
    final class Left {
        var draft: (bot: Bot, text: String)?
        var sent: (bot: Bot, text: String)?
        var task: (bot: Bot, id: UUID)?
    }

    let app: AppUnderTest
    let fixture: Fixture
    let baseline: JourneyBaseline?
    let repeats: Int
    /// A stall injected into journey 2's sidebar toggles (`--stall`), to see the run fail.
    var stall: Double = 0
    let left = Left()
    let report: (JourneyResult) -> Void

    func result(_ journey: Int, _ step: String, _ budget: JourneyBudget, _ samples: [Double], problem: String? = nil) -> JourneyResult {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        return JourneyResult(journey: journey, step: step, budget: budget, baseline: baseline?.medians["\(journey) \(step)"],
                             samples: samples, problem: problem, load: (load[0] * 10).rounded() / 10)
    }

    func notRun(_ journey: Int, because reason: String) -> JourneyResult {
        result(journey, "not run", .instant, [], problem: reason)
    }

    static func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(Int64(to) - Int64(from)) / 1_000_000 }

    /// Runs one journey; when a step fails, measures the journey again once, saying why and the load.
    func run(_ number: Int, _ journey: () -> [JourneyResult]) -> [JourneyResult] {
        let first = journey()
        let failed = first.filter { !$0.passed }
        guard !failed.isEmpty else { first.forEach(report); return first }
        let why = failed.map { "\($0.step): \($0.failure ?? "")" + ($0.load.map { String(format: " (load %.1f)", $0) } ?? "") }.joined(separator: "; ")
        print("journeys: journey \(number) failed (\(why)); measuring it again")
        let again = journey().map { result -> JourneyResult in
            var result = result
            result.retried = failed.first(where: { $0.step == result.step }).map { "\($0.failure ?? "")" + ($0.load.map { String(format: " (load %.1f)", $0) } ?? "") }
                ?? "another step failed"
            return result
        }
        again.forEach(report)
        return again
    }

    // MARK: Helpers

    /// Shows `bot`'s conversation, unless it shows already, and waits for it to settle.
    func show(_ bot: Bot) throws {
        if (try? app.window().title) == bot.name, try app.window().first(identifier: "message-input") != nil { return }
        _ = try select(bot)
    }

    /// The shown conversation's message box.
    func composer() throws -> AXElement {
        guard let composer = try app.window().first(identifier: "message-input") else { throw HarnessFailure("The chat shows no message box") }
        return composer
    }

    /// Types `text` a character at a time at the end of the message box, each timed until the frame
    /// showing it.
    func type(_ text: String, into composer: AXElement) throws -> [Double] {
        try composer.moveCaretToEnd()
        var times: [Double] = []
        for character in text {
            let start = AppUnderTest.now
            try composer.type(String(character))
            times.append(Self.ms(start, try app.mark(FrameMarks.composer, after: start).nanoseconds))
        }
        return times
    }

    /// Writes `text` into the shown conversation's message box and presses Send; the time until the
    /// chat shows a new row.
    @discardableResult
    func send(_ text: String, to bot: Bot) throws -> Double {
        try show(bot)
        let composer = try composer()
        var start = AppUnderTest.now
        try composer.set(kAXValueAttribute, to: text as CFString)
        _ = try app.mark(FrameMarks.composer, after: start)
        guard let button = try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label == "Send" }) else {
            throw HarnessFailure("The message box has no Send button")
        }
        start = AppUnderTest.now
        try button.press()
        let shown = try app.mark(FrameMarks.chat(bot.id), after: start)
        return Self.ms(start, shown.nanoseconds)
    }

    /// Waits until the shown conversation's turn has ended: its message box says Send again.
    func awaitIdle(timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label == "Stop" }) == nil { return }
            usleep(50_000)
        }
        throw HarnessFailure("The turn didn't end within \(Int(timeout)) s")
    }

    /// Waits until `find` finds an element.
    func waitFor(_ what: String, timeout: TimeInterval = 10, _ find: () throws -> AXElement?) throws -> AXElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = try find() { return element }
            usleep(50_000)
        }
        throw HarnessFailure("\(what) didn't show within \(Int(timeout)) s")
    }

    static func p95(_ values: [Double]) -> Double { JourneyStats.percentile(95, of: values) ?? 0 }

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
    func checkShown(_ bot: Bot) throws {
        let window = try app.window()
        guard window.title == bot.name else { throw HarnessFailure("The window's title is \"\(window.title)\", not \(bot.name)") }
        if window.first(identifier: "sidebar-bot-\(bot.id.uuidString)") == nil {
            throw HarnessFailure("The sidebar shows no row for \(bot.name)")
        }
        guard let last = fixture.lastItem[bot.id], window.first(identifier: "chat-item-\(last.uuidString)") != nil else {
            throw HarnessFailure("The chat doesn't show \(bot.name)'s latest message")
        }
    }

    // MARK: 2. Sidebar and inspector

    /// Closes and opens the sidebar, then the status sidebar (the inspector), `repeats` times each.
    /// Then checks itself: the sidebar toggled with a 50 ms stall injected must fail its step against
    /// this run's own times, or the journey can't see the stalls it is there to catch.
    func sidebarAndInspector() -> [JourneyResult] {
        var results = toggles("sidebar", button: sidebarButton, shown: FrameMarks.sidebar(shown:), check: checkSidebar(shown:), stall: stall)
            + toggles("inspector", button: statusButton, shown: FrameMarks.inspector(shown:), check: checkInspector(shown:), stall: stall)
        if stall == 0, let close = results.first, close.problem == nil, let median = close.median {
            let stalled = toggles("sidebar", button: sidebarButton, shown: FrameMarks.sidebar(shown:), check: checkSidebar(shown:),
                                  stall: Self.selfCheckStall, repeats: 3)[0]
            var check = stalled
            check.baseline = median
            check.budget = close.budget
            if let failure = check.failure, stalled.problem == nil {
                print("journeys: self-check: with a \(Int(Self.selfCheckStall)) ms stall injected, \(check.report.replacingOccurrences(of: "— FAILED", with: "— fails as it should"))")
                _ = failure
            } else {
                results[0].problem = "A \(Int(Self.selfCheckStall)) ms stall injected into the sidebar's toggle went unnoticed: \(check.report)"
            }
        }
        return results
    }

    static let selfCheckStall = 50.0

    private func toggles(_ name: String, button: () throws -> AXElement, shown mark: (Bool) -> String,
                         check: (Bool) throws -> Void, stall: Double = 0, repeats: Int? = nil) -> [JourneyResult] {
        var close: [Double] = [], open: [Double] = []
        var problem: String?
        do {
            for _ in 0..<(repeats ?? self.repeats) {
                close.append(try toggle(button, mark: mark(false), stall: stall))
                try check(false)
                open.append(try toggle(button, mark: mark(true), stall: stall))
                try check(true)
            }
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(2, "\(name) · close", .instant, close, problem: problem), result(2, "\(name) · open", .instant, open, problem: problem)]
    }

    /// Presses the button `find` finds and times it until `mark`, then lets the animation finish.
    /// With `stall`, the app is stopped that long just after the press.
    private func toggle(_ find: () throws -> AXElement, mark: String, stall: Double = 0) throws -> Double {
        let button = try find()
        let start = AppUnderTest.now
        try button.press()
        app.stall(milliseconds: stall)
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
    func select(_ bot: Bot) throws -> Double {
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
