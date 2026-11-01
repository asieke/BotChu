import AppKit
import BotChuCore

/// Journey 3's ⌘K switcher (#428), driven from the keyboard as the owner drives it.
extension Journeys {
    private enum Key {
        static let k: CGKeyCode = 40, down: CGKeyCode = 125, up: CGKeyCode = 126, enter: CGKeyCode = 36, escape: CGKeyCode = 53
    }

    /// Opens the switcher with ⌘K, timed until it shows; types another bot's name a key at a time,
    /// each timed until its results show; presses Return, timed until that bot's chat shows;
    /// `repeats` times; then selects the first bot again. The first time also checks that a second ⌘K leaves one switcher, that Esc
    /// closes it, and that Down highlights the next result.
    func switcher() -> [JourneyResult] {
        var opens: [Double] = [], keys: [Double] = [], navigations: [Double] = []
        var problem: String?
        do {
            for index in 0..<repeats {
                let target = fixture.bots[7 - index % 6]
                opens.append(try openSwitcher())
                if index == 0 { try checkSwitcherKeys() }
                let typed = target.name.lowercased()
                for character in typed {
                    let start = AppUnderTest.now
                    app.post(key: 0, text: String(character))
                    keys.append(Self.ms(start, try app.mark(FrameMarks.switcherResults, after: start).nanoseconds))
                }
                app.settle(quiet: 0.1, limit: 2)
                let field = try switcherField()
                guard field.text == typed else { throw HarnessFailure("The switcher's field says \"\(field.text)\" after typing \"\(typed)\"") }
                guard try app.window().first(identifier: "switcher-result")?.label == "\(target.name), Agent" else {
                    throw HarnessFailure("The switcher's first result for \"\(typed)\" isn't the agent \(target.name)")
                }
                let start = AppUnderTest.now
                app.post(key: Key.enter)
                navigations.append(Self.ms(start, try app.mark(FrameMarks.chat(target.id), after: start).nanoseconds))
                app.settle()
                guard try app.window().first(identifier: "switcher-field") == nil else { throw HarnessFailure("Return left the switcher open") }
                try checkShown(target)
            }
            // Back on the first bot, where switching bots left it, so a retry of journey 3 starts
            // from the same conversation.
            _ = try select(fixture.longBot)
            try app.requireForeground()
        } catch {
            problem = "\(error)"
            if (try? app.window().first(identifier: "switcher-field")) != nil {
                app.post(key: Key.escape)
                app.settle()
            }
            _ = try? select(fixture.longBot)
        }
        return [result(3, "switcher opens", .instant, opens, problem: problem),
                result(3, "switcher results per key", .instant, keys, problem: problem),
                result(3, "switcher opens a bot", .within(50), navigations, problem: problem)]
    }

    /// Presses ⌘K; the time until the switcher shows.
    private func openSwitcher() throws -> Double {
        let start = AppUnderTest.now
        app.post(key: Key.k, command: true)
        let shown = try app.mark(FrameMarks.switcher, after: start)
        app.settle(quiet: 0.1, limit: 2)
        guard try switcherField().text.isEmpty else { throw HarnessFailure("The switcher opened with a previous search") }
        return Self.ms(start, shown.nanoseconds)
    }

    private func switcherField() throws -> AXElement {
        try waitFor("The switcher's search field", timeout: 3) { try app.window().first(identifier: "switcher-field") }
    }

    /// With the switcher open and empty: ⌘K again leaves one; Down then Return opens the second
    /// result; Esc closes it. Leaves it open and empty again. Not timed.
    private func checkSwitcherKeys() throws {
        guard try switcherField().value(kAXFocusedAttribute) as? Bool == true else { throw HarnessFailure("The switcher opened without focus in its field") }
        app.post(key: Key.k, command: true)
        app.settle(quiet: 0.1, limit: 2)
        guard try app.window().all(identifier: "switcher-field").count == 1 else { throw HarnessFailure("A second ⌘K opened another switcher") }
        app.post(key: Key.escape)
        app.settle(quiet: 0.1, limit: 2)
        guard try app.window().first(identifier: "switcher-field") == nil else { throw HarnessFailure("Esc didn't close the switcher") }
        // Down twice and Up once highlight the second result, which Return opens.
        _ = try openSwitcher()
        let results = try app.window().all(identifier: "switcher-result")
        guard results.count > 2, let second = fixture.bots.first(where: { results[1].label == "\($0.name), Agent" }) else {
            throw HarnessFailure("The empty switcher doesn't list the agents first")
        }
        for key in [Key.down, Key.down, Key.up] { app.post(key: key) }
        let start = AppUnderTest.now
        app.post(key: Key.enter)
        _ = try app.mark(FrameMarks.chat(second.id), after: start)
        app.settle()
        try checkShown(second)
        _ = try openSwitcher()
    }
}

extension AppUnderTest {
    /// Posts a key press to BotChu as the keyboard does: menus' shortcuts first, then the focused
    /// view. `text` stands for what the key types.
    func post(key: CGKeyCode, command: Bool = false, shift: Bool = false, text: String? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.flags = command ? (shift ? [.maskCommand, .maskShift] : .maskCommand) : []
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.postToPid(pid)
        }
    }
}
