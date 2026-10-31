import AppKit
import BotChuCore

/// Journey 13: what the owner left is all still there after quitting and launching again.
extension Journeys {
    /// Quits BotChu as the owner would and launches it again, timed until the first bot's chat
    /// shows; then checks that the draft journey 5 typed is back in its message box, and the
    /// message journey 6 sent and the area journey 9 attached are there (any of them this journey
    /// leaves itself when that journey didn't run).
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
        } catch {
            problem = "\(error)"
        }
        return [result(13, "relaunch keeps the message and area", .launch, samples, problem: problem)]
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
