import AppKit
import BotChuCore

/// Journeys 8 to 11: the group of 5,000 calls, New Task, resizing the window, the Inbox and Settings.
extension Journeys {
    // MARK: 8. Expanding the group of 5,000 calls

    /// Opens the second bot's group of 5,000 calls from its header and closes it again, `repeats`
    /// times: opening timed until the chat shows its rows, and the main thread's longest busy
    /// stretch in the second after.
    func expandGroup() -> [JourneyResult] {
        let bot = fixture.groupBot
        var opened: [Double] = [], frames: [Double] = []
        var problem: String?
        do {
            try show(bot)
            for _ in 0..<repeats {
                let head = try groupHead()
                let closedLabel = head.label
                let start = AppUnderTest.now
                try head.press()
                let shown = try app.mark(FrameMarks.chat(bot.id), after: start)
                opened.append(Self.ms(start, shown.nanoseconds))
                app.settle(quiet: 0.3, limit: 3)
                let after = max(AppUnderTest.now, shown.nanoseconds + 1_000_000_000)
                while AppUnderTest.now < after { usleep(20_000) }
                frames.append(app.longestBusy(from: shown.nanoseconds + 1, to: after))
                guard try groupHead().label != closedLabel || app.window().first(where: { $0.label.hasPrefix("Read Sources/Module") }) != nil else {
                    throw HarnessFailure("Pressed, the group's header still says \"\(closedLabel)\" and no call shows")
                }
                let close = AppUnderTest.now
                try groupHead().press()
                _ = try app.mark(FrameMarks.chat(bot.id), after: close)
                app.settle(quiet: 0.3, limit: 3)
            }
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(8, "expand 5,000 calls", .quick, opened, problem: problem),
                result(8, "longest frame after expanding", .smooth, frames, problem: problem)]
    }

    /// The header of the group of calls, whose label says what it explored.
    private func groupHead() throws -> AXElement {
        guard let head = try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label.hasPrefix("Explored") }) else {
            throw HarnessFailure("The chat shows no group of calls")
        }
        return head
    }

    // MARK: 9. New Task

    /// Opens New Task from the tabs beside a bot's chat, timed until the sheet shows; writes a brief
    /// and presses Start Task, timed until the new task's tab shows; `repeats` times.
    func newTask() -> [JourneyResult] {
        let bot = fixture.bots[7]
        var sheets: [Double] = [], tabs: [Double] = []
        var problem: String?
        do {
            try show(bot)
            var known = Set(fixture.tasks(of: bot))
            for index in 0..<repeats {
                guard let plus = try app.window().first(identifier: "conversation-new-task") else { throw HarnessFailure("The tabs beside the chat have no New Task button") }
                var start = AppUnderTest.now
                try plus.press()
                let sheet = try app.mark(FrameMarks.newTask, after: start)
                sheets.append(Self.ms(start, sheet.nanoseconds))
                let brief = try waitFor("New Task's brief") { try app.window().first(identifier: "task-brief") }
                try brief.set(kAXValueAttribute, to: "Journey task \(index + 1): tidy the README. journey-stream=0" as CFString)
                let startButton = try waitFor("An enabled Start Task") {
                    try app.window().first(where: { $0.role == kAXButtonRole as String && $0.title == "Start Task" && ($0.value(kAXEnabledAttribute) as? Bool) == true })
                }
                start = AppUnderTest.now
                try startButton.press()
                let deadline = Date().addingTimeInterval(5)
                var tab: FrameMarks.Mark?
                while tab == nil {
                    tab = app.marks(from: start).first { mark in
                        mark.name.hasPrefix("tab ") && UUID(uuidString: String(mark.name.dropFirst(4))).map { !known.contains($0) } == true
                    }
                    guard tab == nil, Date() < deadline else { break }
                    usleep(1_000)
                }
                guard let tab, let id = UUID(uuidString: String(tab.name.dropFirst(4))) else { throw HarnessFailure("No new task's tab showed after Start Task") }
                tabs.append(Self.ms(start, tab.nanoseconds))
                known.insert(id)
                left.task = (bot, id)
                app.settle()
                guard try app.window().first(identifier: "conversation-tab-\(id.uuidString)") != nil else { throw HarnessFailure("The new task's tab isn't beside the chat") }
            }
            try awaitIdle()
            _ = try selectTabHome(of: bot)
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(9, "New Task opens", .instant, sheets, problem: problem),
                result(9, "task shows after Start Task", .quick, tabs, problem: problem)]
    }

    private func selectTabHome(of bot: Bot) throws -> Bool {
        guard let home = try app.window().first(identifier: "conversation-tab-home") else { return false }
        try home.press()
        app.settle()
        return true
    }

    // MARK: 10. Resizing the window

    /// Narrows the window showing the 5,000-message conversation by 20 points a step and widens it
    /// back, `repeats` sweeps of 12 steps: each step timed until the frame laid out at the new
    /// size; a sweep's sample is its steps' p95.
    func resize() -> [JourneyResult] {
        var samples: [Double] = []
        var problem: String?
        do {
            try show(fixture.longBot)
            let window = try app.window()
            guard let frame = window.frame else { throw HarnessFailure("The window has no frame") }
            defer { try? window.setSize(frame.size) }
            for sweep in 0..<repeats {
                var times: [Double] = []
                for step in 1...Self.resizeSteps {
                    let narrower = sweep.isMultiple(of: 2)
                    let width = frame.width - Double(Self.resizeStep) * Double(narrower ? step : Self.resizeSteps - step)
                    let start = AppUnderTest.now
                    try window.setSize(CGSize(width: width, height: frame.height))
                    times.append(Self.ms(start, try app.mark(FrameMarks.windowResized, after: start).nanoseconds))
                }
                samples.append(Self.p95(times))
                let expected = frame.width - (sweep.isMultiple(of: 2) ? Double(Self.resizeStep * Self.resizeSteps) : 0)
                guard let now = window.frame, abs(now.width - expected) < 1 else {
                    throw HarnessFailure("The window is \(Int(window.frame?.width ?? 0)) points wide, not \(Int(expected))")
                }
            }
            app.settle()
            try checkShown(fixture.longBot)
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(10, "resize step (p95 of \(Self.resizeSteps))", .instant, samples, problem: problem)]
    }

    static let resizeStep = 20
    static let resizeSteps = 12

    // MARK: 11. Inbox and Settings

    /// Opens the Inbox and Settings from a bot's chat, `repeats` times each, timed until they show;
    /// then marks deliveries Done in the Inbox, timed until the Done button says it is done.
    func inboxAndSettings() -> [JourneyResult] {
        let bot = fixture.bots[8]
        var inbox: [Double] = [], settings: [Double] = [], done: [Double] = []
        var problem: String?
        do {
            try show(bot)
            for _ in 0..<repeats {
                inbox.append(try openInbox())
                _ = try select(bot)
                guard let gear = try app.window().first(identifier: "sidebar-settings") else { throw HarnessFailure("The sidebar has no Settings button") }
                let start = AppUnderTest.now
                try gear.press()
                settings.append(Self.ms(start, try app.mark(FrameMarks.page("settings"), after: start).nanoseconds))
                app.settle()
                guard try app.window().first(where: { $0.identifier.hasPrefix("settings-page-") }) != nil else { throw HarnessFailure("Settings shows no page") }
                _ = try select(bot)
            }
            _ = try openInbox()
            for index in 0..<repeats {
                let id = fixture.delivery(index * 4)
                let row = try waitFor("The Inbox's row for delivery \(index * 4 + 1)") { try app.window().first(identifier: "inbox-row-\(id.uuidString)") }
                try (row.ancestor(role: kAXRowRole as String) ?? row).set(kAXSelectedAttribute, to: kCFBooleanTrue)
                let button = try waitFor("Done for delivery \(index * 4 + 1)") {
                    try app.window().first(where: { $0.identifier == "inbox-done" && $0.label == "Done" })
                }
                let start = AppUnderTest.now
                try button.press()
                done.append(Self.ms(start, try app.mark(FrameMarks.inboxDone(id, true), after: start).nanoseconds))
                app.settle()
            }
            _ = try select(bot)
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(11, "Inbox opens", .quick, inbox, problem: problem),
                result(11, "Settings opens", .quick, settings, problem: problem),
                result(11, "Done", .instant, done, problem: problem)]
    }

    /// Selects the Inbox in the sidebar; the time until it shows.
    private func openInbox() throws -> Double {
        guard let cell = try app.window().first(identifier: "sidebar-inbox") else { throw HarnessFailure("The sidebar has no Inbox") }
        let start = AppUnderTest.now
        try (cell.ancestor(role: kAXRowRole as String) ?? cell).set(kAXSelectedAttribute, to: kCFBooleanTrue)
        let shown = try app.mark(FrameMarks.page("inbox"), after: start)
        app.settle()
        guard try app.window().first(identifier: "inbox-list") != nil else { throw HarnessFailure("The Inbox shows no list") }
        return Self.ms(start, shown.nanoseconds)
    }
}

extension Journeys {
    // MARK: 7. Scrolling the 5,000-message history

    /// Scrolls the first bot's 5,000-message conversation up a page at a time, as the scroller's
    /// page part does, showing earlier messages whenever the top of those shown is reached: each
    /// page's sample is the main thread's longest busy stretch until it settled. Then Jump to
    /// Latest, timed until the latest message shows: from there, and `repeats` − 1 times more from
    /// a few pages up.
    func scrollHistory() -> [JourneyResult] {
        let bot = fixture.longBot
        var pages: [Double] = [], jumps: [Double] = []
        var problem: String?
        do {
            try show(bot)
            pages = try scrollUp(pages: Self.scrollPages)
            for index in 0..<repeats {
                if index > 0 { _ = try scrollUp(pages: 3) }
                guard let jump = try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label == "Jump to Latest" }) else {
                    throw HarnessFailure("Scrolled up, the chat shows no Jump to Latest")
                }
                let start = AppUnderTest.now
                try jump.press()
                jumps.append(Self.ms(start, try app.mark(FrameMarks.chat(bot.id), after: start).nanoseconds))
                app.settle()
                try checkShown(bot)
            }
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(7, "longest frame per page scrolled up (\(Self.scrollPages) pages)", .smooth, pages, problem: problem),
                result(7, "Jump to Latest", .quick, jumps, problem: problem)]
    }

    static let scrollPages = 18

    /// Presses the chat's scroller above its knob `pages` times, or Show earlier at the top of what
    /// shows; each press's longest busy stretch until the chat settled.
    private func scrollUp(pages: Int) throws -> [Double] {
        guard let last = fixture.lastItem[fixture.longBot.id], let item = try app.window().first(identifier: "chat-item-\(last.uuidString)"),
              let area = item.ancestor(role: kAXScrollAreaRole as String) else { throw HarnessFailure("The chat has no scroll area") }
        var frames: [Double] = []
        while frames.count < pages {
            let bar = area.children.first { $0.role == kAXScrollBarRole as String }
            let atTop = ((bar?.value(kAXValueAttribute) as? NSNumber)?.doubleValue ?? 0) <= 0.0001
            let press: AXElement
            if atTop {
                guard let earlier = area.first(where: { $0.role == "AXLink" && $0.label.hasPrefix("Show ") && $0.label.hasSuffix(" earlier") }) else {
                    throw HarnessFailure("At the top of what the chat shows, it offers no earlier messages")
                }
                press = earlier
            } else {
                guard let page = bar?.children.first(where: { $0.subrole == "AXDecrementPage" }) else { throw HarnessFailure("The chat's scroller has no page part") }
                press = page
            }
            let start = AppUnderTest.now
            try press.press()
            app.settle(quiet: 0.15, limit: 3)
            frames.append(app.longestBusy(from: start, to: AppUnderTest.now))
        }
        return frames
    }
}
