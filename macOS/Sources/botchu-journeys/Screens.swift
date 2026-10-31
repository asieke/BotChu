import AppKit
import BotChuCore

/// Journeys 8 to 11: the group of 5,000 calls, New Task, resizing the window, the Inbox and Settings.
extension Journeys {
    // MARK: 8. Expanding the group of 5,000 calls

    /// Opens the second bot's group of calls from its header and closes it again, `repeats` times:
    /// opening timed until the chat shows its rows, and the main thread's longest busy stretch in
    /// the second after. The fixture's run of 5,000 calls is read from disk a page at a time, so the
    /// group the chat shows on opening holds its newest calls (earlier pages come as groups of
    /// their own when the reader asks for them).
    func expandGroup() -> [JourneyResult] {
        let bot = fixture.groupBot
        var opened: [Double] = [], frames: [Double] = []
        var problem: String?
        do {
            try show(bot)
            print("journeys: 8 expands \"\(try groupHead().label)\"")
            var expectedGroup: String?
            var expectedLabel: String?
            for _ in 0..<repeats {
                let (head, group) = try groupHeadAndID()
                let label = head.label
                guard let before = head.frame else { throw HarnessFailure("The group header has no frame") }
                if let expectedGroup, let expectedLabel {
                    guard group == expectedGroup, label == expectedLabel else {
                        throw HarnessFailure("Closing and reopening changed the displayed group")
                    }
                } else { expectedGroup = group; expectedLabel = label }
                let (start, shown) = try press(head, until: FrameMarks.chat(bot.id))
                opened.append(Self.ms(start, shown.nanoseconds))
                let after = shown.nanoseconds + 1_000_000_000
                app.settle(quiet: 0.3, limit: 3)
                while AppUnderTest.now < after { usleep(20_000) }
                frames.append(app.longestBusy(from: shown.nanoseconds + 1, to: after))
                let rows = try app.window().all(identifier: group).count
                guard rows > 1 else { throw HarnessFailure("Pressed, the group of calls still shows as one row") }
                let expanded = try groupHeadAndID()
                guard expanded.group == group, expanded.head.label == label, let afterFrame = expanded.head.frame,
                      abs(afterFrame.minY - before.minY) <= 1 else {
                    throw HarnessFailure("Opening the group changed its content or moved its header")
                }
                _ = try press(expanded.head, until: FrameMarks.chat(bot.id))
                app.settle(quiet: 0.3, limit: 3)
            }
            try app.requireForeground()
        } catch {
            problem = "\(error)"
        }
        return [result(8, "expand group of calls", .quick, opened, problem: problem),
                result(8, "longest frame after expanding", .smooth, frames, problem: problem)]
    }

    /// The header of the group of calls, whose label says what it explored.
    private func groupHead() throws -> AXElement { try groupHeadAndID().head }

    private func groupHeadAndID() throws -> (head: AXElement, group: String) {
        guard let head = try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label.hasPrefix("Explored") }),
              let row = head.ancestor(where: { $0.identifier.hasPrefix("chat-item-") }) else {
            throw HarnessFailure("The chat shows no group of calls")
        }
        return (head, row.identifier)
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
                var brief = try waitFor("New Task's brief") { try app.window().first(identifier: "task-brief") }
                guard brief.text.isEmpty, brief.label.contains(bot.name) else {
                    throw HarnessFailure("New Task kept a previous brief or opened for the wrong bot")
                }
                if index == 0 {
                    // A prepared native window must discard its form on Cancel (#353). This is
                    // outside the opening measurement above; it does not prewarm that sample.
                    try brief.type("Discard this draft")
                    guard let cancel = try button("Cancel") else { throw HarnessFailure("New Task has no Cancel") }
                    try cancel.press()
                    app.settle()
                    guard try app.window().first(identifier: "task-brief") == nil,
                          let reopen = try app.window().first(identifier: "conversation-new-task") else {
                        throw HarnessFailure("Cancel did not dismiss New Task")
                    }
                    _ = try press(reopen, until: FrameMarks.newTask)
                    brief = try waitFor("New Task's fresh brief") { try app.window().first(identifier: "task-brief") }
                    guard brief.text.isEmpty, brief.label.contains(bot.name) else {
                        throw HarnessFailure("Reopening New Task restored its cancelled draft or another bot")
                    }
                }
                try brief.set(kAXValueAttribute, to: "Journey task \(index + 1): tidy the README. journey-stream=0" as CFString)
                // The project New Task chose last time, or the fixture's.
                func startTask() throws -> AXElement? { try button("Start Task") }
                if (try startTask()?.value(kAXEnabledAttribute) as? Bool) != true,
                   let project = try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label.hasPrefix(Fixture.taskRepo + ",") }) {
                    try project.press()
                }
                let startButton = try waitFor("An enabled Start Task") {
                    try startTask().flatMap { ($0.value(kAXEnabledAttribute) as? Bool) == true ? $0 : nil }
                }
                start = try press(startButton)
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
            try app.requireForeground()
        } catch {
            problem = "\(error)"
            // A sheet left open would hold up the journeys after.
            if let cancel = try? button("Cancel") {
                try? cancel.press()
                app.settle()
            }
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

    /// Widens the window showing the 5,000-message conversation by up to 20 points a step and
    /// narrows it back (it opens as narrow as its columns allow), `repeats` sweeps of 12 steps: each
    /// step timed until the frame laid out at the new size; a sweep's sample is its steps' p95.
    func resize() -> [JourneyResult] {
        var samples: [Double] = []
        var problem: String?
        do {
            try show(fixture.longBot)
            let window = try app.window()
            guard let frame = window.frame else { throw HarnessFailure("The window has no frame") }
            defer { try? window.setSize(frame.size) }
            // As far as its screen leaves room for, at most 12 steps of 20 points (accessibility's
            // frames are from the top left of the main screen, AppKit's from its bottom left).
            let height = NSScreen.screens.first?.frame.height ?? 0
            let room = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: height - frame.midY)) })
                .map { $0.visibleFrame.maxX - frame.maxX } ?? 0
            let stepWidth = min(Double(Self.resizeStep), (room / Double(Self.resizeSteps)).rounded(.down))
            guard stepWidth >= 5 else { throw HarnessFailure("The window's screen leaves no room to widen it (\(Int(room)) points)") }
            for sweep in 0..<repeats {
                var times: [Double] = []
                for step in 1...Self.resizeSteps {
                    let wider = sweep.isMultiple(of: 2)
                    let width = frame.width + stepWidth * Double(wider ? step : Self.resizeSteps - step)
                    let start = AppUnderTest.now
                    try window.setSize(CGSize(width: width, height: frame.height))
                    guard let mark = try? app.mark(FrameMarks.windowResized, after: start) else {
                        throw HarnessFailure("Asked to be \(Int(width)) points wide, the window is \(Int(window.frame?.width ?? 0)) and BotChu wrote no \"\(FrameMarks.windowResized)\" mark")
                    }
                    times.append(Self.ms(start, mark.nanoseconds))
                }
                samples.append(Self.p95(times))
                let expected = frame.width + (sweep.isMultiple(of: 2) ? stepWidth * Double(Self.resizeSteps) : 0)
                guard let now = window.frame, abs(now.width - expected) < 1 else {
                    throw HarnessFailure("The window is \(Int(window.frame?.width ?? 0)) points wide, not \(Int(expected))")
                }
            }
            app.settle()
            try checkShown(fixture.longBot)
            // Outside the timed sweeps: the native minimum must keep the composer's controls
            // inside the actual chat pane, even when asked for less width than they require.
            try window.setSize(CGSize(width: 600, height: frame.height))
            app.settle()
            try checkComposerFitsChat(window)
            try app.requireForeground()
        } catch {
            problem = "\(error)"
        }
        return [result(10, "resize step (p95 of \(Self.resizeSteps))", .instant, samples, problem: problem)]
    }

    static let resizeStep = 20
    static let resizeSteps = 12

    private func checkComposerFitsChat(_ window: AXElement) throws {
        let input = try composer()
        guard let column = window.first(where: { ["conversation-column", "conversation-rail"].contains($0.identifier) }),
              let columnFrame = column.frame,
              let split = column.ancestor(role: kAXSplitGroupRole as String),
              let inputFrame = input.frame,
              let composerGroup = input.ancestor(where: { group in
                  group.first(where: { $0.label == "Attach images" }) != nil
                      && group.first(where: { $0.label == "Send" }) != nil
              }),
              let windowFrame = window.frame else {
            throw HarnessFailure("Couldn't locate the chat pane for the minimum-width check")
        }
        // The conversation list's right edge starts the chat. The next vertical native divider
        // ends it; a hidden inspector leaves the chat extending to the window's right edge.
        let left = columnFrame.maxX
        var right = windowFrame.maxX
        var queue = [split], index = 0
        while index < queue.count, index < 20_000 {
            let element = queue[index]
            index += 1
            queue += element.children
            guard let bounds = element.frame, bounds.height > 0 else { continue }
            if element.role == kAXSplitterRole as String, bounds.height > bounds.width,
               bounds.minX > left + 0.5 { right = min(right, bounds.minX) }
        }
        var controls: [(String, CGRect)] = []
        let required = ["Model:", "Reasoning effort", "Attach images", "Send"]
        let prefixes = required + ["Fast mode", "Provider:", "Completion window:"]
        queue = [composerGroup]
        index = 0
        while index < queue.count, index < 20_000 {
            let element = queue[index]
            index += 1
            queue += element.children
            guard let bounds = element.frame, bounds.height > 0 else { continue }
            if bounds.width > 0, bounds.minY >= inputFrame.maxY - 1,
               prefixes.contains(where: { element.label.hasPrefix($0) }) {
                controls.append((element.label, bounds))
            }
        }
        guard right > left, inputFrame.minX >= left - 1, inputFrame.maxX <= right + 1 else {
            throw HarnessFailure("The message editor extends outside the chat pane at minimum width")
        }
        for prefix in required where !controls.contains(where: { $0.0.hasPrefix(prefix) }) {
            throw HarnessFailure("The minimum-width composer has no visible \(prefix) control")
        }
        for (label, bounds) in controls where bounds.minX < left - 1 || bounds.maxX > right + 1 {
            throw HarnessFailure("\(label) extends outside the chat pane at minimum width")
        }
    }

    // MARK: 11. Inbox and Settings

    /// Opens the Inbox and Settings from a bot's chat, `repeats` times each, timed until they show;
    /// then marks deliveries Done in the Inbox, timed until the Inbox shows each Done.
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
            for _ in 0..<repeats {
                // Each a delivery not done yet: the newest left, needing the owner's input.
                let n = left.deliveriesDone * 4
                left.deliveriesDone += 1
                let id = fixture.delivery(n)
                let row = try waitFor("The Inbox's row for delivery \(n + 1)") { try app.window().first(identifier: "inbox-row-\(id.uuidString)") }
                try (row.ancestor(role: kAXRowRole as String) ?? row).set(kAXSelectedAttribute, to: kCFBooleanTrue)
                let button = try waitFor("Done for delivery \(n + 1)") {
                    try app.window().first(where: { $0.identifier == "inbox-done" && $0.label == "Done" })
                }
                let start = AppUnderTest.now
                try button.press()
                done.append(Self.ms(start, try app.mark(FrameMarks.inboxDone(id, true), after: start).nanoseconds))
                app.settle()
            }
            _ = try select(bot)
            try app.requireForeground()
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
                if index > 0 { _ = try scrollUp(pages: 2) }
                guard let jump = try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label == "Jump to Latest" }) else {
                    throw HarnessFailure("Scrolled up, the chat shows no Jump to Latest")
                }
                let start = AppUnderTest.now
                try jump.press()
                jumps.append(Self.ms(start, try app.mark(FrameMarks.chat(bot.id), after: start).nanoseconds))
                app.settle()
                try checkShown(bot)
            }
            try app.requireForeground()
        } catch {
            problem = "\(error)"
        }
        return [result(7, "longest frame per page scrolled up (\(Self.scrollPages) pages)", .smooth, pages, problem: problem),
                result(7, "Jump to Latest", .quick, jumps, problem: problem)]
    }

    static let scrollPages = 12

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
