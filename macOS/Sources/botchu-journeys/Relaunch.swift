import AppKit
import BotChuCore

/// Journey 13: what the owner left is all still there after quitting and launching again.
extension Journeys {
    /// Quits BotChu as the owner would and launches it again, timed until the first bot's chat
    /// shows; then checks that the draft journey 5 typed is back in its message box, and the
    /// message journey 6 sent and the area journey 9 attached are there (any of them this journey
    /// leaves itself when that journey didn't run), and that an area's turn is one work row.
    func relaunch() -> [JourneyResult] {
        var samples: [Double] = []
        var problem: String?
        do {
            if left.draft == nil {
                let bot = fixture.longBot
                try show(bot)
                let composer = try composer()
                let start = AppUnderTest.now
                try composer.set(kAXValueAttribute, to: "A draft to keep" as CFString)
                _ = try app.mark(FrameMarks.composer, after: start)
                left.draft = (bot, "A draft to keep")
            }
            if left.sent == nil {
                let bot = fixture.bots[6]
                let text = "A message to keep. journey-stream=0"
                try send(text, to: bot)
                try awaitIdle()
                left.sent = (bot, text)
            }
            if left.area == nil { _ = attachArea() }
            guard let draft = left.draft, let sent = left.sent, let area = left.area else { throw HarnessFailure("Couldn't leave a draft, a message and an area") }
            try cameoBesideTheAreasBot(in: area)
            app.settle()
            app.quit()
            let start = try app.launch()
            let shown = try app.mark(FrameMarks.chat(fixture.longBot.id), after: start, timeout: 60)
            samples.append(Self.ms(start, shown.nanoseconds))
            app.settle(quiet: 0.5, limit: 10)
            try app.requireForeground()

            // The draft is back in its own message box (#357), and a sent message isn't in its box again.
            try show(draft.bot)
            let box = try composer().text
            guard box == draft.text else {
                throw HarnessFailure("After a relaunch, \(draft.bot.name)'s message box says \"\(box.prefix(40))\", not the draft left in it: \"\(draft.text.prefix(40))\"")
            }
            try show(sent.bot)
            guard try chatShows(sent.text) else { throw HarnessFailure("After a relaunch, \(sent.bot.name)'s chat doesn't show the message sent: \"\(sent.text)\"") }
            let sentBox = try composer().text
            guard sentBox.isEmpty else {
                throw HarnessFailure("After a relaunch, \(sent.bot.name)'s message box says \"\(sentBox.prefix(40))\", though its message was sent")
            }
            try show(area.bot)
            guard try app.window().first(identifier: "conversation-tab-\(area.id.uuidString)") != nil else {
                throw HarnessFailure("After a relaunch, \(area.bot.name) has no row for the area attached in Attach Project Area")
            }
            try checkAreaWorkRow()
        } catch {
            problem = "\(error)"
        }
        return [result(13, "relaunch keeps the message and area", .launch, samples, problem: problem)]
    }

    /// In the area, a message chooses another bot with `@` completion, whose cameo turn streams
    /// for a while; meanwhile a plain message is answered by the area's own bot at once, its turn
    /// starting and ending while the cameo's goes on (#424). Then the cameo's turn ends.
    private func cameoBesideTheAreasBot(in area: (bot: Bot, id: UUID)) throws {
        guard let other = fixture.bots.first(where: { $0.id != area.bot.id && $0.id != fixture.longBot.id }) else { return }
        // The area: still shown after Attach Project Area, or pressed in its bot's column.
        let identifier = "conversation-tab-\(area.id.uuidString)"
        if try app.window().first(identifier: identifier) == nil { _ = try? select(area.bot) }
        guard let tab = try app.window().first(identifier: identifier) else { throw HarnessFailure("\(area.bot.name)'s column has no row for its area") }
        _ = try press(tab)
        app.settle()
        try awaitIdle(timeout: 60)
        let began = AppUnderTest.now
        var box = try composer()
        try box.set(kAXValueAttribute, to: "" as CFString)
        try box.type("@" + other.name.prefix(4))
        // The list's row for it, beside the list's "Agents" heading.
        func heading(_ element: AXElement) -> Bool {
            (element.text == "Agents" || element.label == "Agents") && element.identifier != "sidebar-agents"
        }
        let row: AXElement
        do {
            row = try waitFor("@ completion's row for \(other.name)") {
                try app.window().first(where: heading)?.parent?.children
                    .first { $0.label == other.name || $0.label.hasPrefix(other.name + ", ") }
            }
        } catch {
            var lines: [String] = []
            let window = try app.window()
            print("journeys: the message box says \"\(try composer().text)\"; Agents heading: \(window.first(where: heading).map { "\($0)" } ?? "none")")
            if let list = window.first(where: heading)?.parent { list.dump(maxDepth: 3, into: &lines) }
            print(lines.prefix(40).joined(separator: "\n"))
            throw error
        }
        // Choosing it closes the list, which accessibility can report as a failed press.
        try? row.press()
        _ = try waitFor("\(other.name) chosen in the message box") { try composer().text.contains(other.name) ? try composer() : nil }
        box = try composer()
        try box.moveCaretToEnd()
        try box.type(" take your time. journey-stream=6")
        guard let send = try button("Send") else { throw HarnessFailure("The area's message box has no Send button") }
        _ = try press(send)
        // The cameo's CLI streams.
        let streaming = try FakeLog.waitFor(app, "\(other.name)'s cameo streaming", after: began, timeout: 20) { !FakeLog.streaming($0).isEmpty }
        guard let cameo = FakeLog.streaming(streaming).first else { throw HarnessFailure("No cameo turn streamed") }
        // The area's own bot takes a plain message now: Send, not Stop, and its turn ends before the cameo's.
        let plain = AppUnderTest.now
        box = try composer()
        try box.set(kAXValueAttribute, to: "And a quick one for you. journey-stream=0" as CFString)
        guard let again = try button("Send") else {
            throw HarnessFailure("While \(other.name)'s cameo runs, the area's message box has no Send button: its own bot is kept waiting")
        }
        _ = try press(again)
        let lines = try FakeLog.waitFor(app, "the area's own bot's turn ending", after: plain, timeout: 20) {
            !FakeLog.ended($0).subtracting([cameo]).isEmpty
        }
        let ends = lines.filter { $0.words.first == "end" }
        guard let own = ends.first(where: { $0.pid != cameo }) else { throw HarnessFailure("The area's own bot's turn didn't end") }
        if let cameoEnd = ends.first(where: { $0.pid == cameo }), cameoEnd.time <= own.time {
            throw HarnessFailure("The area's own bot answered only after \(other.name)'s cameo ended")
        }
        print("journeys: the area's bot answered in \(Int(Self.ms(plain, own.time))) ms while \(other.name)'s cameo streamed")
        try FakeLog.waitFor(app, "\(other.name)'s cameo ending", after: began, timeout: 30) { FakeLog.ended($0).contains(cameo) }
        app.settle(quiet: 0.5, limit: 5)
    }

    /// An area reads as a chat (#425): its one turn, nine calls and an interim reply, is one work
    /// row before the reply, which opens to show the calls.
    private func checkAreaWorkRow() throws {
        let bot = fixture.bots[11]
        let area = fixture.areas(of: bot)[0]
        try show(bot)
        guard let tab = try app.window().first(identifier: "conversation-tab-\(area.uuidString)") else {
            throw HarnessFailure("\(bot.name)'s Project Areas column has no row for its area")
        }
        _ = try press(tab, until: FrameMarks.chat(area))
        app.settle()
        func workRows() throws -> [AXElement] {
            var rows: [AXElement] = []
            _ = try app.window().first { element in
                if element.role == kAXButtonRole as String, element.label.hasPrefix("Worked ") { rows.append(element) }
                return false
            }
            return rows
        }
        let rows = try workRows()
        guard rows.count == 1, let row = rows.first else {
            throw HarnessFailure("\(bot.name)'s area shows \(rows.count) work rows for its one turn, not one: \(rows.map(\.label))")
        }
        guard let last = fixture.lastItem[area], try app.window().first(identifier: "chat-item-\(last.uuidString)") != nil else {
            throw HarnessFailure("\(bot.name)'s area doesn't show its turn's reply under the work row")
        }
        guard try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label.hasPrefix("Explored") }) == nil else {
            throw HarnessFailure("\(bot.name)'s area shows its turn's calls outside the work row")
        }
        _ = try press(row)
        app.settle()
        guard try app.window().first(where: { $0.role == kAXButtonRole as String && $0.label.hasPrefix("Explored") }) != nil else {
            throw HarnessFailure("Opening \(bot.name)'s work row (\(row.label)) didn't show its calls")
        }
    }

    /// Whether the chat shows a text with these words, paging up through at most `pages` pages for
    /// it (only the rows near the visible part are laid out, so a long reply after it hides it).
    private func chatShows(_ text: String, pages: Int = 6) throws -> Bool {
        for page in 0...pages {
            if try app.window().first(where: { element in
                element.role == kAXStaticTextRole as String && (element.text.contains(text) || element.label.contains(text))
            }) != nil { return true }
            guard page < pages, let area = try app.window().first(where: { $0.identifier.hasPrefix("chat-item-") })?.ancestor(role: kAXScrollAreaRole as String),
                  let bar = area.children.first(where: { $0.role == kAXScrollBarRole as String }),
                  let up = bar.children.first(where: { $0.subrole == "AXDecrementPage" }) else { return false }
            _ = try press(up)
            app.settle(quiet: 0.15, limit: 3)
        }
        return false
    }
}
