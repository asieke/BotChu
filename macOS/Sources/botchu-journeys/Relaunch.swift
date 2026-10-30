import AppKit
import BotChuCore

/// Journey 13: what the owner left is all still there after quitting and launching again.
extension Journeys {
    /// Quits BotChu as the owner would and launches it again, timed until the first bot's chat
    /// shows; then checks the message journey 6 sent and the task journey 9 started, and says
    /// whether the draft journey 5 typed is kept (any of them this journey leaves itself when that
    /// journey didn't run).
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
            if left.task == nil { _ = newTask() }
            guard let draft = left.draft, let sent = left.sent, let task = left.task else { throw HarnessFailure("Couldn't leave a draft, a message and a task") }
            app.settle()
            app.quit()
            let start = try app.launch()
            let shown = try app.mark(FrameMarks.chat(fixture.longBot.id), after: start, timeout: 60)
            samples.append(Self.ms(start, shown.nanoseconds))
            app.settle(quiet: 0.5, limit: 10)
            try app.requireBackground()

            // BotChu keeps drafts in memory only, so this says what the box holds without failing.
            try show(draft.bot)
            let box = try composer().text
            print("journeys: 13: after a relaunch, \(draft.bot.name)'s draft " + (box == draft.text ? "is kept"
                : "isn't: its message box says \"\(box.prefix(40))\" (BotChu keeps drafts in memory only)"))
            try show(sent.bot)
            guard try chatShows(sent.text) else { throw HarnessFailure("After a relaunch, \(sent.bot.name)'s chat doesn't show the message sent: \"\(sent.text)\"") }
            try show(task.bot)
            guard try app.window().first(identifier: "conversation-tab-\(task.id.uuidString)") != nil else {
                throw HarnessFailure("After a relaunch, \(task.bot.name) has no tab for the task started in New Task")
            }
        } catch {
            problem = "\(error)"
        }
        return [result(13, "relaunch keeps the message and task", .launch, samples, problem: problem)]
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
