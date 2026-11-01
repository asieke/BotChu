import AppKit
import BotChuCore

/// The journeys on the replica of the owner's data (#422), with their ids from it: launch (1)
/// shows the real agents, switching bots (3) shows each one, every open task is a row of its bot's
/// Project Areas column, under its area or on its own (4), an area attached is hidden and shown
/// again (9), the Inbox marks real deliveries Done (11), and a relaunch keeps all of it (13). Their
/// steps are `replica: …` and report only until `baseline.json` has them; failures name no bot.
extension Journeys {
    static let replicaNumbers = [1, 3, 4, 9, 11, 13]
    /// No budget until three runs on the replica give a baseline: then the usual 25 % + 3 ms rule.
    static let reportOnly = JourneyBudget(milliseconds: 600_000, tier: "Report only")

    func replicaResult(_ journey: Int, _ step: String, _ samples: [Double], problem: String?, replica: Replica) -> JourneyResult {
        result(journey, "replica: \(step)", Self.reportOnly, samples, problem: problem.map(replica.redact))
    }

    /// Waits for the window, the sidebar's rows and a chat after `start`: what a launch shows.
    func launched(after start: UInt64) throws -> UInt64 {
        let window = try app.mark(FrameMarks.window, after: start, timeout: 60).nanoseconds
        let row = try app.mark(FrameMarks.sidebarRow, after: start, timeout: 60).nanoseconds
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let chat = app.marks(from: start).first(where: { $0.name.hasPrefix("chat ") }) { return max(window, row, chat.nanoseconds) }
            usleep(5_000)
        }
        throw HarnessFailure("No chat showed within 60 s of the launch")
    }

    /// Every agent of the replica has its row in the sidebar.
    func checkAgentsShown(_ replica: Replica) throws {
        let window = try app.window()
        let missing = replica.principal.filter { window.first(identifier: "sidebar-bot-\($0.id.uuidString)") == nil }
        guard missing.isEmpty else { throw HarnessFailure("The sidebar shows no row for \(missing.count) of the \(replica.principal.count) agents") }
    }

    // MARK: 1. Launch

    func replicaLaunch(_ replica: Replica, launches: Int = 3) -> [JourneyResult] {
        var first: [Double] = [], samples: [Double] = []
        var problem: String?
        do {
            for attempt in 0...launches {
                if attempt > 0 { app.quit() }
                let start = try app.launch()
                let time = Self.ms(start, try launched(after: start))
                if attempt == 0 { first.append(time) } else { samples.append(time) }
                app.settle(quiet: 0.5, limit: 10)
                try app.requireForeground()
                try checkAgentsShown(replica)
            }
        } catch {
            problem = "\(error)"
        }
        return [replicaResult(1, "first launch, with its migration", first, problem: problem, replica: replica),
                replicaResult(1, "launch", samples, problem: problem, replica: replica)]
    }

    // MARK: 3. Switching bots

    /// Selects each agent in turn, timed until its chat shows.
    func replicaSwitchBots(_ replica: Replica) -> [JourneyResult] {
        var samples: [Double] = []
        var problem: String?
        do {
            for bot in replica.principal + [replica.principal[0]] { samples.append(try select(bot)) }
            try app.requireForeground()
        } catch {
            problem = "\(error)"
        }
        return [replicaResult(3, "switch bot", samples, problem: problem, replica: replica)]
    }

    // MARK: 4. Open tasks and areas

    /// Each agent's open areas and tasks are rows of its column, its hidden areas behind "n hidden";
    /// opening its first row is timed until that conversation shows.
    func checkColumn(of bot: Bot, _ replica: Replica) throws {
        let layout = ProjectAreasLayout(tasks: replica.tasks(of: bot))
        let window = try app.window()
        let missing = layout.rows.filter { window.first(identifier: "conversation-tab-\($0.id.uuidString)") == nil }
        guard missing.isEmpty else {
            throw HarnessFailure("An agent's column shows \(layout.rows.count - missing.count) of its \(layout.rows.count) open areas and tasks")
        }
        if !layout.hidden.isEmpty, window.first(identifier: "conversation-hidden") == nil {
            throw HarnessFailure("An agent with \(layout.hidden.count) hidden areas has no \"hidden\" row")
        }
    }

    func replicaAreas(_ replica: Replica) -> [JourneyResult] {
        var samples: [Double] = []
        var problem: String?
        var rows = 0
        do {
            for bot in replica.principal {
                try show(bot)
                try checkColumn(of: bot, replica)
                let layout = ProjectAreasLayout(tasks: replica.tasks(of: bot))
                rows += layout.rows.count
                guard let row = layout.rows.first,
                      let tab = try app.window().first(identifier: "conversation-tab-\(row.id.uuidString)") else { continue }
                let start = try press(tab)
                samples.append(Self.ms(start, try app.mark(FrameMarks.chat(row.id), after: start).nanoseconds))
                app.settle()
            }
            print("journeys: replica: \(rows) open areas and tasks shown in their columns")
            try app.requireForeground()
        } catch {
            problem = "\(error)"
        }
        return [replicaResult(4, "open an area or task", samples, problem: problem, replica: replica)]
    }

    // MARK: 9. Attach, hide and show an area

    /// On the first agent: Attach Project Area for a new folder, timed until its row shows; then
    /// Hide from its context menu, and pressing it under "n hidden" shows it again.
    func replicaAttachArea(_ replica: Replica) -> [JourneyResult] {
        let bot = replica.principal[0]
        var sheet: [Double] = [], shown: [Double] = []
        var problem: String?
        do {
            try show(bot)
            guard let plus = try app.window().first(identifier: "conversation-new-task") else { throw HarnessFailure("The Project Areas column has no + button") }
            var start = try press(plus)
            sheet.append(Self.ms(start, try app.mark(FrameMarks.attachArea, after: start).nanoseconds))
            let name = try waitFor("Attach Project Area's folder name") { try app.window().first(identifier: "area-name") }
            try name.set(kAXFocusedAttribute, to: kCFBooleanTrue)
            app.settle(quiet: 0.1, limit: 2)
            try name.type("Replica journey area")
            let attach = try waitFor("An enabled Attach") {
                try app.window().first(identifier: "area-attach").flatMap { ($0.value(kAXEnabledAttribute) as? Bool) == true ? $0 : nil }
            }
            let known = Set(replica.tasks(of: bot).map(\.id))
            start = try press(attach)
            let deadline = Date().addingTimeInterval(5)
            var tab: FrameMarks.Mark?
            while tab == nil, Date() < deadline {
                tab = app.marks(from: start).first { mark in
                    mark.name.hasPrefix("tab ") && UUID(uuidString: String(mark.name.dropFirst(4))).map { !known.contains($0) } == true
                }
                if tab == nil { usleep(1_000) }
            }
            guard let tab, let id = UUID(uuidString: String(tab.name.dropFirst(4))) else { throw HarnessFailure("No new area's row showed after Attach") }
            shown.append(Self.ms(start, tab.nanoseconds))
            left.area = (bot, id)
            app.settle()
            try hideAndShow(id, of: bot)
            try checkColumn(of: bot, replica)
            try app.requireForeground()
        } catch {
            problem = "\(error)"
            if let cancel = try? button("Cancel") { try? cancel.press(); app.settle() }
        }
        return [replicaResult(9, "Attach Project Area opens", sheet, problem: problem, replica: replica),
                replicaResult(9, "area shows after Attach", shown, problem: problem, replica: replica)]
    }

    /// Hides the area from its row's context menu, then shows it again from under "n hidden".
    private func hideAndShow(_ id: UUID, of bot: Bot) throws {
        let identifier = "conversation-tab-\(id.uuidString)"
        func row() throws -> AXElement? { try app.window().first(identifier: identifier) }
        guard let tab = try row() else { throw HarnessFailure("The new area's row isn't in the column") }
        try tab.perform(kAXShowMenuAction)
        guard let pid = app.running?.processIdentifier else { throw HarnessFailure("BotChu isn't running") }
        let hide = try waitFor("The area's Hide") {
            AXElement.application(pid).first(limit: 5_000) { $0.role == kAXMenuItemRole as String && $0.title == "Hide" }
        }
        try hide.press()
        let hidden = try waitFor("The \"hidden\" row") { try app.window().first(identifier: "conversation-hidden") }
        app.settle()
        if let still = try row(), !still.label.hasPrefix("Hidden, ") { throw HarnessFailure("Hide left the area's row in the column") }
        if try row() == nil {
            _ = try press(hidden)
            app.settle()
        }
        guard let hiddenRow = try row(), hiddenRow.label.hasPrefix("Hidden, ") else { throw HarnessFailure("\"hidden\" doesn't list the hidden area") }
        _ = try press(hiddenRow)
        _ = try waitFor("The area shown again") { try row().flatMap { $0.label.hasPrefix("Hidden, ") ? nil : $0 } }
        app.settle()
    }

    // MARK: 11. Inbox

    /// Opens the Inbox and marks its newest deliveries that aren't Done, `repeats` of them, timed
    /// until each shows Done.
    func replicaInbox(_ replica: Replica) -> [JourneyResult] {
        var opens: [Double] = [], done: [Double] = []
        var problem: String?
        do {
            let state = replica.inbox()
            let order = InboxList.groups(replica.deliveries(), state: state, now: Date()).flatMap(\.ids).filter { !state[$0].done }
            guard !order.isEmpty else { throw HarnessFailure("The replica's Inbox has no delivery that isn't Done") }
            guard let cell = try app.window().first(identifier: "sidebar-inbox") else { throw HarnessFailure("The sidebar has no Inbox") }
            let start = AppUnderTest.now
            try (cell.ancestor(role: kAXRowRole as String) ?? cell).set(kAXSelectedAttribute, to: kCFBooleanTrue)
            opens.append(Self.ms(start, try app.mark(FrameMarks.page("inbox"), after: start).nanoseconds))
            app.settle()
            for id in order.prefix(repeats) {
                let row = try waitFor("The Inbox's row for a delivery") { try app.window().first(identifier: "inbox-row-\(id.uuidString)") }
                try (row.ancestor(role: kAXRowRole as String) ?? row).set(kAXSelectedAttribute, to: kCFBooleanTrue)
                let button = try waitFor("Done for a delivery") { try app.window().first(where: { $0.identifier == "inbox-done" && $0.label == "Done" }) }
                let start = AppUnderTest.now
                try button.press()
                done.append(Self.ms(start, try app.mark(FrameMarks.inboxDone(id, true), after: start).nanoseconds))
                left.deliveriesDone += 1
                app.settle()
            }
            replica.left.done = Array(order.prefix(repeats))
            _ = try select(replica.principal[0])
            try app.requireForeground()
        } catch {
            problem = "\(error)"
        }
        return [replicaResult(11, "Inbox opens", opens, problem: problem, replica: replica),
                replicaResult(11, "Done", done, problem: problem, replica: replica)]
    }

    // MARK: 13. Relaunch

    /// Quits and launches again, timed until a chat shows; then the agents, every column, the
    /// attached area and the deliveries marked Done are all as they were.
    func replicaRelaunch(_ replica: Replica) -> [JourneyResult] {
        var samples: [Double] = []
        var problem: String?
        do {
            app.quit()
            let start = try app.launch()
            samples.append(Self.ms(start, try launched(after: start)))
            app.settle(quiet: 0.5, limit: 10)
            try app.requireForeground()
            try checkAgentsShown(replica)
            for bot in replica.principal {
                try show(bot)
                try checkColumn(of: bot, replica)
            }
            if let area = left.area, !replica.tasks(of: area.bot).contains(where: { $0.id == area.id && $0.isArea && !$0.isArchived }) {
                throw HarnessFailure("After a relaunch, the area attached and shown again isn't an open area")
            }
            let state = replica.inbox()
            let undone = replica.left.done.filter { !state[$0].done }
            guard undone.isEmpty else { throw HarnessFailure("After a relaunch, \(undone.count) deliveries marked Done aren't Done") }
        } catch {
            problem = "\(error)"
        }
        return [replicaResult(13, "relaunch keeps the areas, tasks and Done", samples, problem: problem, replica: replica)]
    }
}
