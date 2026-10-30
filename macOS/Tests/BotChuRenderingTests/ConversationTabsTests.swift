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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ConversationSplit(botID: bot.id) { Color.clear }
            .environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        // Rows, from the top: Home's two lines, the heading, then each task's three (#192).
        let home = NSPoint(x: 120, y: 33), heading: CGFloat = 77
        func row(_ index: Int) -> NSPoint { NSPoint(x: 120, y: 134 + CGFloat(index) * 70) }
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
        try await checkColumnControlsAtReportedAndMinimumWidths(fixture)
    }

    /// #312: window/inspector changes keep task labels and the saved width in light and dark.
    /// Only the owner's choice shows the rail, including after recreating the window.
    @Test func conversationColumnFollowsTheWindowAndTheOwnersChoice() async throws {
        _ = NSApplication.shared
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        model.show(.home(bot.id))
        // The report: Home with two open tasks and Model & Usage shown.
        model.closeTask(.task(fixture.tasks[2].id, of: bot.id))
        fixture.defaults.set(InspectorTab.model.rawValue, forKey: InspectorTab.storageKey)
        fixture.defaults.set(320.0, forKey: ConversationColumnSettings.widthKey)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1571, height: 960),
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
            for width in [1571.0, 1240, 600, 1700] {
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 960), display: true)
                try await settle(window)
                #expect(window.frame.width >= window.contentMinSize.width)
                #expect(abs(try chatInset(in: host) - 320) <= 1,
                        "Tasks keep their labels at requested window width \(width)")
                try checkChatFits(in: host)
                if width == 1571 { snapshot("conversation-reported-\(name)") }
                if width == 600 { snapshot("conversation-minimum-\(name)") }
            }
        }
        #expect(fixture.defaults.object(forKey: ConversationColumnSettings.collapsedKey) == nil)
        #expect(toolbarLabels().contains("Chat Density"))
        #expect(!toolbarLabels().contains("New Task"))

        // Restoring every supported width keeps it through inspector changes and resizing, without
        // overwriting it or implicitly saving a collapse. A fresh view restores the same settings.
        for width in [200.0, 280, 320] {
            fixture.defaults.set(width, forKey: ConversationColumnSettings.widthKey)
            for showsStatus in [false, true] {
                fixture.defaults.set(showsStatus, forKey: "showsStatus")
                for requested in [600.0, 1571] {
                    window.setFrame(NSRect(x: 0, y: 0, width: requested, height: 960), display: true)
                    try await settle(window)
                    #expect(abs(try chatInset(in: host) - width) <= 1)
                    #expect(window.frame.width >= window.contentMinSize.width)
                    try checkChatFits(in: host)
                }
            }
            #expect(fixture.defaults.double(forKey: ConversationColumnSettings.widthKey) == width)
            host = try await show()
            #expect(abs(try chatInset(in: host) - width) <= 1)
        }
        #expect(fixture.defaults.object(forKey: ConversationColumnSettings.collapsedKey) == nil)

        fixture.defaults.set(true, forKey: ConversationColumnSettings.collapsedKey)
        try await settle(window)
        #expect(abs(try chatInset(in: host) - ConversationColumnLayout.railWidth) <= 1)
        host = try await show()
        #expect(abs(try chatInset(in: host) - ConversationColumnLayout.railWidth) <= 1)
        for showsStatus in [false, true] {
            fixture.defaults.set(showsStatus, forKey: "showsStatus")
            window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 960), display: true)
            try await settle(window)
            #expect(abs(try chatInset(in: host) - ConversationColumnLayout.railWidth) <= 1)
            #expect(fixture.defaults.bool(forKey: ConversationColumnSettings.collapsedKey))
        }
        // Expanding at the rail's minimum must make room for the column immediately, and persist.
        fixture.defaults.set(false, forKey: ConversationColumnSettings.collapsedKey)
        try await settle(window)
        #expect(abs(try chatInset(in: host) - 320) <= 1)
        #expect(window.frame.width >= window.contentMinSize.width)
        try checkChatFits(in: host)
        host = try await show()
        #expect(abs(try chatInset(in: host) - 320) <= 1)
        #expect(!fixture.defaults.bool(forKey: ConversationColumnSettings.collapsedKey))

        // A bot with no open task has no column; New Task is back in the toolbar.
        model.show(.home(fixture.quiet.id))
        try await settle(window)
        #expect(abs(try chatInset(in: host)) <= 1)
        #expect(toolbarLabels().contains("New Task"))
        snapshot("conversation-none")
    }

    /// #144: the selected tab is a card inset as far from the column's trailing edge as from its
    /// leading one, Home's as a task's, in light and dark. Measured in the column's own drawing,
    /// where the card is the only thing in the chat's colour.
    @Test func selectedTabIsACardInsetEvenlyFromTheColumnsEdges() async throws {
        _ = NSApplication.shared
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let tasks = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        model.runStates[tasks[1]] = RunState(startedAt: Date().addingTimeInterval(-252), hasOutput: true, activity: .coding)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let swatch = NSHostingView(rootView: Palette.chat)
        let host = NSHostingView(rootView: ConversationSplit(botID: bot.id) { Color.clear }
            .environment(model).defaultAppStorage(fixture.defaults))
        window.makeKeyAndOrderFront(nil)
        // 8 points from each of the column's edges.
        let width = CGFloat(ConversationColumnLayout.width), inset: CGFloat = 8

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            NSApp.appearance = NSAppearance(named: appearance)
            // The chat's colour as this window draws it: the display's color profile shifts the
            // values, so the card is found by this swatch rather than by numbers.
            window.contentView = swatch
            try await settle(window)
            let fill = try #require(try Drawing(of: swatch).color(x: 10, y: 10))
            window.contentView = host
            for target in [tasks[1], .home(bot.id)] {
                model.show(target)
                try await settle(window)
                let drawing = try Drawing(of: host)
                // Down the card's leading part, left of its dot, then across its middle, where only
                // its texts are between its edges.
                let card = try #require(drawing.bounds(in: CGRect(x: inset + 9, y: 0, width: 0.5, height: host.bounds.height)) { near($0, fill) })
                let across = try #require(drawing.bounds(in: CGRect(x: 0, y: card.midY, width: width, height: 0.5)) { near($0, fill) })
                let leading = across.minX, trailing = width - across.maxX
                #expect(abs(leading - inset) <= 1.5, "\(appearance.rawValue), \(target): the card starts \(leading) from the column's leading edge")
                #expect(abs(trailing - leading) <= 1, "\(appearance.rawValue), \(target): \(leading) from the leading edge, \(trailing) from the trailing one")
            }
        }
    }

    /// #144: a bot row's dots sit at its end, centred on the row, not on its second line; an idle
    /// task's ring comes last (#324).
    @Test func botRowDotsAreCentredOnTheRow() async throws {
        _ = NSApplication.shared
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let tasks = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        model.runStates[tasks[1]] = RunState(startedAt: Date().addingTimeInterval(-252), hasOutput: true, activity: .coding)
        model.unread.insert(tasks[0])
        let summary = model.botRowSummary(of: bot)
        try #require(summary.dots == [.working, .news, .idle])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: BotRow(bot: bot, status: model.status(of: bot), summary: summary, selected: false)
            .frame(width: 220).environment(model))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        // Right of the avatar, the dots are the only colour that isn't grey: violet (dark mode's is
        // pale), then green.
        let drawing = try Drawing(of: host)
        let dots = try #require(drawing.bounds(in: CGRect(x: 60, y: 0, width: host.bounds.width - 60, height: host.bounds.height)) {
            $0.alphaComponent > 0.5 && $0.saturationComponent > 0.25
        })
        // Both 6-point dots, 4 points apart.
        #expect(abs(dots.width - 16) <= 1 && abs(dots.height - 6) <= 1, "the dots are \(dots)")
        #expect(abs(dots.midY - host.bounds.height / 2) <= 1, "the dots' middle is \(dots.midY) in a row \(host.bounds.height) tall")
        // Then the idle task's grey ring, 4 points on, at the row's end.
        let ring = try #require(drawing.bounds(in: CGRect(x: dots.maxX + 1, y: 0, width: host.bounds.width - dots.maxX - 1, height: host.bounds.height)) {
            $0.alphaComponent > 0.5
        })
        #expect(abs(ring.width - 6) <= 1 && abs(ring.minX - dots.maxX - 4) <= 1 && abs(ring.midY - dots.midY) <= 1, "the ring is \(ring), after \(dots)")
        #expect(host.bounds.width - ring.maxX < 8, "the dots end \(host.bounds.width - ring.maxX) from the row's end, \(ring) in \(host.bounds)")
    }

    /// #218: each state's dot has its own colour and shape, in light and dark: rings while idle
    /// (grey) and preparing (violet), a violet dot while working, a green one for a finished turn
    /// not yet seen, a red dot for a failure, a red square for the owner's Stop, and an orange
    /// diamond while it waits on the owner's input.
    @Test func eachStatusHasItsOwnColourAndShape() async throws {
        _ = NSApplication.shared
        enum Hue { case grey, violet, green, red, orange }
        enum Shape { case ring, circle, square, diamond }
        let cases: [(TabState.Kind, Hue, Shape)] = [
            (.idle, .grey, .ring), (.preparing, .violet, .ring), (.starting, .violet, .ring), (.working, .violet, .circle),
            (.news, .green, .circle), (.failed, .red, .circle), (.stopped, .red, .square), (.needsInput, .orange, .diamond),
        ]
        func hue(_ c: NSColor) -> Hue? {
            if c.saturationComponent < 0.15 { return .grey }
            let degrees = c.hueComponent * 360
            switch degrees {
            case ..<15, 345...: return .red
            case 22..<50: return .orange
            case 90..<160: return .green
            case 240..<290: return .violet
            default: return nil
            }
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (kind, expectedHue, expectedShape) in cases {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                defer { window.contentView = nil; window.close() }
                let host = NSHostingView(rootView: StatusDot(kind: kind, size: 32).padding(4))
                window.contentView = host
                window.setContentSize(host.fittingSize)
                window.orderFront(nil)
                try await settle(window)
                let drawing = try Drawing(of: host)
                let label = "\(appearance.rawValue), \(kind)"
                let bounds = try #require(drawing.bounds(in: host.bounds) { $0.alphaComponent > 0.5 }, "\(label): nothing drawn")
                // As wide as the frame, whatever the shape; the square a little less, so it looks as big.
                #expect((25...34).contains(bounds.width) && abs(bounds.height - bounds.width) <= 1, "\(label): \(bounds)")
                var filled = 0, total = 0
                var hues: [Hue?] = []
                for y in stride(from: bounds.minY + 0.25, to: bounds.maxY, by: 0.5) {
                    for x in stride(from: bounds.minX + 0.25, to: bounds.maxX, by: 0.5) {
                        total += 1
                        guard let colour = drawing.color(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
                        filled += 1
                        if colour.alphaComponent > 0.95 { hues.append(hue(colour)) }
                    }
                }
                // The share of its box it fills tells the shapes apart: a ring little, a diamond
                // half, a circle π/4, a square nearly all.
                let share = Double(filled) / Double(total)
                let shape: Shape = share < 0.4 ? .ring : share < 0.65 ? .diamond : share < 0.88 ? .circle : .square
                #expect(shape == expectedShape, "\(label): fills \(share) of its box")
                let common = Dictionary(grouping: hues.compactMap { $0 }, by: { $0 }).max { $0.value.count < $1.value.count }?.key
                let centre = drawing.color(x: bounds.midX, y: bounds.midY).map { "hue \(Int($0.hueComponent * 360))°, saturation \($0.saturationComponent)" }
                #expect(common == expectedHue, "\(label): \(String(describing: common)); the centre's \(centre ?? "-")")
            }
        }
    }

    /// #237: a bot row's dots are drawn as the task column's, in light and dark. Unselected, each is
    /// its tab's dot, only smaller. Where a List raises a selected row's background prominence, each
    /// sits on a disc of the column's own background, as a rail tile's does, so it is drawn on the
    /// same ground as its tab's: on the white disc it had, dark mode's colours, made for a dark
    /// ground, read pale.
    @Test func botRowDotsAreDrawnAsTheColumnsAlsoOnASelectedRow() async throws {
        _ = NSApplication.shared
        func draw<Content: View>(_ view: Content, in appearance: NSAppearance.Name) async throws -> Drawing {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            defer { window.contentView = nil; window.close() }
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.orderFront(nil)
            try await settle(window)
            return try Drawing(of: host)
        }
        // The middle of what is drawn; the rest of each drawing is clear.
        func middle(of drawing: Drawing) throws -> CGPoint {
            let drawn = try #require(drawing.bounds(in: CGRect(x: 0, y: 0, width: 100, height: 100)) { $0.alphaComponent > 0.5 })
            return CGPoint(x: drawn.midX, y: drawn.midY)
        }
        let filled: [TabState.Kind] = [.working, .news, .failed, .stopped, .needsInput]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            // The column's background as this window draws it: the display's color profile shifts
            // the values, so the dots' ground is found by this swatch rather than by numbers.
            let swatch = try await draw(Palette.conversationColumn.frame(width: 20, height: 20), in: appearance)
            let swatchMiddle = try middle(of: swatch)
            let ground = try #require(swatch.colours(around: swatchMiddle, at: 0...0.8).first, "\(appearance.rawValue): the column's ground")
            for kind in [TabState.Kind.preparing, .starting] + filled {
                let label = "\(appearance.rawValue), \(kind)"
                var summary = BotRowSummary(runsOn: "Claude Dev · default", home: .idle(since: nil), tasks: [])
                summary.dots = [kind]
                // The column's 8-point dot, and the row's 6-point one, unselected and selected.
                let column = try await draw(StatusDot(kind: kind).padding(4), in: appearance)
                let row = try await draw(BotRowDots(summary: summary).padding(4), in: appearance)
                let selected = try await draw(BotRowDots(summary: summary).padding(4).environment(\.backgroundProminence, .increased),
                                              in: appearance)
                let columnMiddle = try middle(of: column), rowMiddle = try middle(of: row), selectedMiddle = try middle(of: selected)
                // Selected, all round the dot (between its 3-point radius and its disc's 5) is the column's ground.
                let around = selected.colours(around: selectedMiddle, at: 3.6...4.4)
                #expect(around.count >= 8 && around.filter { near($0, ground) }.count * 4 >= around.count * 3,
                        "\(label): around the selected row's dot \(around.prefix(3)), the column's ground \(ground)")
                let selectedCentre = selected.colours(around: selectedMiddle, at: 0...0.8)
                if filled.contains(kind) {
                    let colour = try #require(column.colours(around: columnMiddle, at: 0...0.8).first, "\(label): the column's dot")
                    for (name, centre) in [("unselected", row.colours(around: rowMiddle, at: 0...0.8)), ("selected", selectedCentre)] {
                        #expect(!centre.isEmpty && centre.allSatisfy { near($0, colour) }, "\(label): the \(name) row's dot is \(centre), the column's \(colour)")
                    }
                } else {
                    // A ring shows its ground through it, as in the column.
                    #expect(!selectedCentre.isEmpty && selectedCentre.allSatisfy { near($0, ground) },
                            "\(label): inside the selected row's ring \(selectedCentre), the column's ground \(ground)")
                }
            }
        }
    }

    /// #359: a bot row's dots, up to eight, are a grid of two rows of four at its end, the first row
    /// filled first; past eight, +N follows the grid, centred on it. With any number of dots the row
    /// is as tall as without, and its name and subtitle stay where they are.
    @Test func botRowDotsAreTwoRowsOfFourAndKeepTheRowsHeight() async throws {
        _ = NSApplication.shared
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.quiet
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func draw<Content: View>(_ view: Content) async throws -> (size: CGSize, drawing: Drawing) {
            let host = NSHostingView(rootView: view.environment(model))
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.orderFront(nil)
            try await settle(window)
            return (host.fittingSize, try Drawing(of: host))
        }
        let working = TabState.working(.coding, since: Date())
        func summary(_ count: Int) -> BotRowSummary {
            BotRowSummary(runsOn: "Codex Dev · default", home: .idle(since: nil), tasks: Array(repeating: working, count: count))
        }
        func ink(_ drawing: Drawing, in rect: CGRect) -> CGRect? { drawing.bounds(in: rect) { $0.alphaComponent > 0.5 } }
        // The dots alone: 6 points each, 4 apart, in up to four columns and two rows.
        let inset: CGFloat = 4, grid = CGRect(x: 0, y: 0, width: inset + 37, height: 30)
        func span(_ dots: Int) -> CGFloat { CGFloat(dots * 10 - 4) }
        for count in [1, 4, 5, 8, 9, 20] {
            let shown = min(count, 8), columns = min(shown, 4), rows = shown > 4 ? 2 : 1
            let (size, drawing) = try await draw(BotRowDots(summary: summary(count)).padding(inset))
            let dots = try #require(ink(drawing, in: grid), "\(count) dots")
            #expect(abs(dots.minX - inset) < 0.75 && abs(dots.width - span(columns)) < 1 && abs(dots.height - span(rows)) < 1,
                    "\(count) dots: \(dots), \(columns) columns and \(rows) rows")
            if rows == 2 {
                // The second row starts under the first dot.
                let second = try #require(ink(drawing, in: CGRect(x: 0, y: dots.maxY - 6, width: grid.width, height: 6)), "\(count) dots")
                #expect(abs(second.minX - dots.minX) < 0.75 && abs(second.width - span(shown - 4)) < 1, "\(count) dots: the second row \(second)")
            }
            // +N is in the secondary label colour, half transparent.
            let more = drawing.bounds(in: CGRect(x: grid.maxX + 1, y: 0, width: size.width, height: size.height)) { $0.alphaComponent > 0.2 }
            #expect((more != nil) == (count > 8), "\(count) dots: +N \(String(describing: more))")
            if let more { #expect(abs(more.midY - dots.midY) < 1.5, "\(count) dots: +N \(more), the grid \(dots)") }
        }
        // The row: as tall with dots as without, centred on it, its name and subtitle drawn as they were.
        let width: CGFloat = 260, text = CGRect(x: 0, y: 0, width: 160, height: 60)
        func row(_ count: Int) async throws -> (size: CGSize, drawing: Drawing) {
            try await draw(BotRow(bot: bot, status: model.status(of: bot), summary: summary(count), selected: false).frame(width: width))
        }
        let (plain, bare) = try await row(0)
        #expect(ink(bare, in: CGRect(x: text.maxX, y: 0, width: width - text.maxX, height: plain.height)) == nil)
        for count in [1, 4, 5, 8, 9, 20] {
            let (size, drawing) = try await row(count)
            #expect(size.height == plain.height, "\(count) dots: the row is \(size.height) points tall, \(plain.height) without")
            let dots = try #require(ink(drawing, in: CGRect(x: text.maxX, y: 0, width: width - text.maxX, height: size.height)), "\(count) dots")
            #expect(abs(dots.midY - size.height / 2) < 1, "\(count) dots: \(dots) in a row \(size.height) tall")
            #expect(drawing.matches(bare, in: text), "\(count) dots: the name and subtitle moved")
        }
    }

    /// #218: a conversation waits on the owner while a Needs input delivery it sent isn't answered
    /// or Done, whatever else it does, and reading it doesn't change that; the owner's Stop shows
    /// until the next turn, also once looked at; and both come back after a relaunch.
    @Test func needsInputAndAnOwnersStopLastUntilHandledAndAcrossRelaunch() async throws {
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let bot = fixture.bot
        let home = ChatTarget.home(bot.id)
        let tasks = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        let question = Delivery.Question(text: "Which filter?", choices: ["Status", "Owner"])
        let asking = Delivery(botID: bot.id, taskID: fixture.tasks[0].id, title: "Which filter first?", question: question, purpose: .needsInput)
        let homeAsks = Delivery(botID: bot.id, title: "Deploy now?", question: question, purpose: .needsInput)
        let fyi = Delivery(botID: bot.id, taskID: fixture.tasks[2].id, title: "Found a leak", purpose: .fyi)
        let folder = InboxFolder(home: BotHome(workspace: bot.workspace))
        for delivery in [asking, homeAsks, fyi] { try folder.save(delivery, contents: [:]) }
        let model = fixture.model
        model.inbox.load(bots: [bot])
        for _ in 0..<200 where model.inbox.all.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.inbox.all.count == 3)

        // Running, it still waits on the owner; an FYI asks nothing.
        model.runStates[tasks[0]] = RunState(startedAt: Date(), hasOutput: true, activity: .coding)
        #expect(model.tabState(of: tasks[0]).kind == .needsInput)
        #expect(model.conversationTab(of: tasks[0])?.status == "Needs input")
        #expect(model.tabState(of: tasks[2]).kind == .idle)
        #expect(model.botRowSummary(of: bot).dots == [.needsInput, .needsInput, .idle, .idle])
        #expect(model.botRowSummary(of: bot).subtitle == "Claude Personal · default")
        // Shown, its deliveries are read, and it still waits; Done, it doesn't.
        model.show(tasks[0])
        #expect(!model.inbox.isUnread(asking.id) && model.tabState(of: tasks[0]).kind == .needsInput)
        model.inbox.setDone(asking.id, true)
        #expect(model.tabState(of: tasks[0]).kind == .working)
        model.runStates[tasks[0]] = nil

        // The owner stops a turn: red until the next one, shown or not.
        model.conversation(tasks[1]).replace([ChatMessage(role: .user, text: "Go"), ChatMessage(role: .assistant, text: "Partial")])
        model.runStates[tasks[1]] = RunState(startedAt: Date(), preparing: true)
        model.stop(tasks[1])
        #expect(model.tabState(of: tasks[1]).kind == .stopped)
        #expect(model.conversationTab(of: tasks[1])?.status == "Stopped")
        model.unread.insert(tasks[1])
        model.show(tasks[1])
        #expect(model.tabState(of: tasks[1]).kind == .stopped)
        // A finished turn not yet seen is green, until it is shown.
        model.conversation(tasks[2]).replace([ChatMessage(role: .user, text: "Go"), ChatMessage(role: .assistant, text: "Done")])
        model.unread.insert(tasks[2])
        #expect(model.tabState(of: tasks[2]).kind == .news)
        model.show(tasks[2])
        #expect(model.tabState(of: tasks[2]).kind == .idle)
        #expect(model.botRowSummary(of: bot).dots == [.needsInput, .stopped, .idle, .idle])

        // Relaunched: Home still waits on the owner, and the task is still stopped.
        model.saveThread(tasks[1])
        await model.storage.settle()
        let again = fixture.relaunch()
        defer { again.stopAll() }
        for _ in 0..<200 where again.inbox.all.count < 3 || again.tabState(of: tasks[1]).kind != .stopped {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(again.tabState(of: home).kind == .needsInput)
        #expect(again.tabState(of: tasks[0]).kind == .idle)
        #expect(again.tabState(of: tasks[1]).kind == .stopped)
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
        // Nothing running: a ring for each open task, and what the bot runs on (#324).
        #expect(model.botRowSummary(of: bot).subtitle == "Claude Personal · default")
        #expect(model.botRowSummary(of: bot).dots == [.idle, .idle, .idle])
        #expect(model.botRowSummary(of: fixture.quiet).subtitle == "Claude Personal · default")
        #expect(model.botRowSummary(of: fixture.quiet).dots.isEmpty)
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
        // The most urgent first (#218).
        #expect(summary.dots == [.failed, .working, .news])
        #expect(summary.subtitle == "Claude Personal · default")
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

    /// A task's tab keeps the task's menu: its issue, branch, folder and Terminal, Rename… and
    /// Regenerate Title (#236), New Session and Close Task; Home's has New Session. Menus need no
    /// clicks (`menu(for:)`).
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
                                            "Rename…", "Regenerate Title", "", "New Session", "Close Task"])
        // Its worktree isn't made yet.
        #expect(task.items.filter { !$0.isEnabled && !$0.isSeparatorItem }.map(\.title) == ["Show Task Folder in Finder", "Open Task in Terminal"])
        let home = try tabMenu(at: NSPoint(x: 120, y: 33), in: host)
        #expect(home.items.map(\.title) == ["New Session"])
        task.performActionForItem(at: task.indexOfItem(withTitle: "Close Task"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.openTasks(of: bot.id).map(\.id) == [fixture.tasks[1].id, fixture.tasks[2].id])
    }

    /// #192: a task's row has three lines, its summary on the second, at every width of the column
    /// (one line each, never wrapped), and Home's keeps two. Drawing them asks no model.
    @Test func taskRowsHaveThreeLinesAtEveryColumnWidth() async throws {
        _ = NSApplication.shared
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let jobs = SummaryJobs()
        model.summaryRunner = { job in jobs.add(job); return "Never asked for" }
        model.settings.quickTaskAccountID = "claude-dev"
        model.settings.quickTaskModel = "haiku"
        let task = ChatTarget.task(fixture.tasks[0].id, of: bot.id), other = ChatTarget.task(fixture.tasks[1].id, of: bot.id)
        model.tasks[bot.id]?[0].summary = "Typo in the README"
        model.runStates[task] = RunState(startedAt: Date().addingTimeInterval(-252), hasOutput: true, activity: .thinking)
        model.runStates[other] = RunState(startedAt: Date().addingTimeInterval(-60), hasOutput: true, activity: .thinking)
        // Two tasks thinking in the same repository still read apart.
        #expect(model.conversationTab(of: task)?.label == "Typo in the README")
        #expect(model.conversationTab(of: other)?.label == "Add a filter bar")
        #expect(model.conversationTab(of: task)?.status == "Thinking…")
        func height(_ target: ChatTarget, column: CGFloat) async throws -> CGFloat {
            let host = NSHostingView(rootView: PlainRow(target: target).frame(width: column - 2 * ConversationColumn.rowInset)
                .environment(model).defaultAppStorage(fixture.defaults))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            return host.fittingSize.height
        }
        let narrow = ConversationColumnLayout.widths.lowerBound, wide = ConversationColumnLayout.widths.upperBound
        let rows = try await [height(task, column: narrow), height(task, column: wide), height(other, column: narrow)]
        let home = try await height(.home(bot.id), column: narrow)
        #expect(rows.allSatisfy { abs($0 - rows[0]) <= 0.5 }, "every task row is as tall at 200 and 320 points: \(rows)")
        #expect(rows[0] - home >= 12 && rows[0] <= 72, "a third line, compact: \(rows[0]) against Home's \(home)")
        #expect(jobs.all.isEmpty)
    }

    /// #192: a new task's summary is asked for once, in the background, on the Quick tasks profile
    /// and model, only once they are chosen; an invalid reply gets one correction (#315),
    /// then leaves the task named as before if still invalid. A saved one is in its task.json.
    @Test func aNewTasksSummaryIsAskedForOnceOnTheQuickTasksProfile() async throws {
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let targets = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        let jobs = SummaryJobs()
        model.summaryRunner = { job in
            jobs.add(job)
            return job.prompt.contains("Fix the typo") ? "“Typo fix in README.”" : "Sure! Here is a label for this task: Add a filter"
        }
        // Off until a profile and model are chosen: nothing is asked.
        model.summarizeNewTask(targets[0])
        #expect(model.summaryRuns.isEmpty)
        model.settings.quickTaskAccountID = "google"
        model.settings.quickTaskModel = "gemini-4-argon-medium"
        model.summarizeNewTask(targets[0])
        #expect(model.summaryRuns.isEmpty, "Antigravity can't run without tools, and no other account stands in")
        model.settings.quickTaskAccountID = "claude-dev"
        model.settings.quickTaskModel = "haiku"
        model.summarizeNewTask(targets[0])
        model.summarizeNewTask(targets[1])
        #expect(model.summaryRuns.count == 2)
        await model.lastSummaryRun?.value
        #expect(jobs.all.map(\.account.id) == ["claude-dev", "claude-dev", "claude-dev"])
        #expect(jobs.all.last?.prompt.contains("exactly THREE words") == true)
        #expect(jobs.all.allSatisfy { $0.model == "haiku" })
        #expect(model.task(targets[0])?.summary == "Typo fix in README")
        #expect(model.task(targets[1])?.summary == nil)
        #expect(model.conversationTab(of: targets[1])?.label == "Add a filter bar")
        // Once: never asked again.
        model.summarizeNewTask(targets[0])
        #expect(model.summaryRuns.isEmpty && jobs.all.count == 3)
        let home = BotHome(workspace: bot.workspace)
        for _ in 0..<100 where home.loadTasks().first(where: { $0.id == targets[0].taskID })?.summary == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(home.loadTasks().first { $0.id == targets[0].taskID }?.summary == "Typo fix in README")
    }

    /// #236: Rename… and Regenerate Title. Made again, a title comes from the task's brief and its
    /// own latest messages, on the Quick tasks profile and model only, once at a time; one that
    /// doesn't come keeps the old title and says why. A rename wins over a title still being made,
    /// and a late one never reaches a closed task. The chat, its draft and the tab shown stay as they
    /// are, and the title is in its task.json for the next launch.
    @Test func aTasksTitleIsRenamedOrMadeAgainFromItsOwnConversation() async throws {
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let targets = fixture.tasks.map { ChatTarget.task($0.id, of: bot.id) }
        let ids = fixture.tasks.map(\.id)
        let jobs = SummaryJobs()
        model.summaryRunner = { job in
            jobs.add(job)
            return "“Status filter chips.”"
        }
        model.conversation(targets[0]).replace([ChatMessage(role: .user, text: fixture.tasks[0].opening),
                                                ChatMessage(role: .assistant, text: "The filter now uses status chips.")])
        model.conversation(targets[1]).replace([ChatMessage(role: .user, text: "Words only the second task has")])
        model.show(targets[0])
        model.drafts[targets[0]] = "Half a thought"

        // Off: it says where to choose a profile, and asks no other account.
        model.regenerateTitle(targets[0])
        #expect(model.titleNotice?.kind == .notConfigured && model.titleNotice?.action == "Open Quick Tasks Settings")
        #expect(model.titleRuns.isEmpty && jobs.all.isEmpty && model.task(targets[0])?.summary == nil)
        model.titleNotice = nil

        model.settings.quickTaskAccountID = "claude-dev"
        model.settings.quickTaskModel = "haiku"
        model.regenerateTitle(targets[0])
        model.regenerateTitle(targets[0])
        #expect(model.isRegeneratingTitle(targets[0]) && model.titleRuns.count == 1, "A second click asks nothing more")
        await model.titleRuns[ids[0]]?.value
        #expect(jobs.all.map(\.account.id) == ["claude-dev"] && jobs.all.first?.model == "haiku")
        let prompt = try #require(jobs.all.first?.prompt)
        #expect(prompt.contains("Bot: The filter now uses status chips.") && prompt.contains("Fix the typo"))
        #expect(!prompt.contains("Words only the second task has"), "No other task's conversation")
        #expect(model.task(targets[0])?.summary == "Status filter chips")
        #expect(model.conversationTab(of: targets[0])?.label == "Status filter chips")
        #expect(!model.isRegeneratingTitle(targets[0]) && model.titleRuns.isEmpty && model.titleNotice == nil)
        // Its issue, branch, conversation and draft, and the tab shown, are as they were.
        #expect(model.task(targets[0])?.work?.title == "Fix the typo" && model.task(targets[0])?.branch == "feat/41-task")
        #expect(model.conversationTab(of: targets[0])?.title == "repo #41")
        #expect(model.thread(targets[0]).count == 2 && model.drafts[targets[0]] == "Half a thought" && model.tab(of: bot.id) == targets[0])

        // A reply that isn't a title keeps the old one, and says why.
        model.summaryRunner = { job in
            jobs.add(job)
            return "Sure! Here is a title for this task: Filter chips"
        }
        model.regenerateTitle(targets[0])
        await model.titleRuns[ids[0]]?.value
        #expect(model.task(targets[0])?.summary == "Status filter chips")
        #expect(model.titleNotice?.kind == .failed("Its reply wasn’t a title of three or four words"))
        #expect(model.titleNotice?.action == "Try Again")

        // Renamed while a title is being made: the rename wins, and Cancel's empty name changes nothing.
        model.summaryRunner = { job in
            jobs.add(job)
            try await Task.sleep(nanoseconds: 300_000_000)
            return "Late title from before"
        }
        model.regenerateTitle(targets[0])
        let late = try #require(model.titleRuns[ids[0]])
        model.askToRename(targets[0])
        #expect(model.renamingTask == targets[0] && model.renamingText == "Status filter chips")
        #expect(!model.renameTask(targets[0], to: "  \n "))
        #expect(model.renameTask(targets[0], to: "  Chips for the status filter, then sorting "))
        #expect(model.titleNotice == nil && !model.isRegeneratingTitle(targets[0]))
        await late.value
        #expect(model.task(targets[0])?.summary == "Chips for the status filter, then sorting")
        #expect(model.titleNotice == nil)

        // Closed while one is being made: the late title doesn't reach it, nor open it again.
        model.regenerateTitle(targets[1])
        let closing = try #require(model.titleRuns[ids[1]])
        model.closeTask(targets[1])
        await closing.value
        #expect(model.task(targets[1])?.summary == nil && model.task(targets[1])?.isArchived == true)
        #expect(model.titleNotice == nil)

        // The next launch shows the name it was given.
        await model.storage.settle()
        let again = fixture.relaunch()
        defer { again.stopAll() }
        #expect(again.task(targets[0])?.summary == "Chips for the status filter, then sorting")
        #expect(again.conversationTab(of: targets[0])?.label == "Chips for the status filter, then sorting")
        #expect(again.task(targets[1])?.summary == nil)
    }

    /// #236 in the window: Rename… opens an alert starting from the label the tab shows, and Rename
    /// saves what was typed. A window shows one alert at a time, so a notice that comes while it is
    /// open waits, then shows once it closes, saying only why; Try Again with Quick tasks off offers
    /// their settings instead, and opens them.
    @Test func aTitleNoticeWaitsForTheRenameAlertToClose() async throws {
        _ = NSApplication.shared
        let fixture = try TabsFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model, bot = fixture.bot
        let first = ChatTarget.task(fixture.tasks[0].id, of: bot.id)
        model.settings.settingsPage = .accounts
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: ConversationSplit(botID: bot.id) { Color.clear }
            .environment(model).defaultAppStorage(fixture.defaults))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
            #expect(condition(), sourceLocation: sourceLocation)
        }

        let menu = try tabMenu(at: NSPoint(x: 120, y: 124), in: host)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Rename…"))
        try await until { window.attachedSheet != nil }
        let rename = try #require(window.attachedSheet)
        #expect(alertTexts(in: rename).contains("Rename Task"))
        let field = try #require(rename.firstResponder as? NSTextView)
        #expect(field.string == "Fix the typo")

        // Another task's title fails meanwhile: its notice waits behind the rename.
        model.titleNotice = TaskTitleNotice(botID: bot.id, taskID: fixture.tasks[1].id, kind: .failed("API Error: 429 rate limit"))
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.attachedSheet === rename && window.sheets.count == 1)
        field.selectAll(nil)
        field.insertText("Typo in the README", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        try #require(alertButtons(in: rename).first { $0.title == "Rename" }).performClick(nil)
        try await until { model.task(first)?.summary == "Typo in the README" }

        try await until { window.attachedSheet.map { $0 !== rename } == true }
        let notice = try #require(window.attachedSheet)
        #expect(alertTexts(in: notice).contains("Couldn’t Regenerate the Title"))
        #expect(alertTexts(in: notice).contains("API Error: 429 rate limit"))
        #expect(alertButtons(in: notice).map(\.title).sorted() == ["Cancel", "Try Again"])
        try #require(alertButtons(in: notice).first { $0.title == "Try Again" }).performClick(nil)

        // Quick tasks are off: Try Again asks no account, and offers their settings.
        try await until { model.titleNotice?.kind == .notConfigured && window.attachedSheet.map { $0 !== notice } == true }
        let off = try #require(window.attachedSheet)
        #expect(alertTexts(in: off).contains("Choose a Quick Tasks Profile"))
        #expect(alertButtons(in: off).map(\.title).sorted() == ["Cancel", "Open Quick Tasks Settings"])
        try #require(alertButtons(in: off).first { $0.title == "Open Quick Tasks Settings" }).performClick(nil)
        try await until { window.attachedSheet == nil }
        #expect(model.titleNotice == nil && model.destination == .settings && model.settings.settingsPage == .general)
        #expect(model.titleRuns.isEmpty && model.task(.task(fixture.tasks[1].id, of: bot.id))?.summary == nil)
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

    /// The actual controls at #312's size, then the smallest supported window. Kept in the
    /// isolated native-click test so AppKit's event callbacks cannot stall another test process.
    private func checkColumnControlsAtReportedAndMinimumWidths(_ fixture: TabsFixture) async throws {
        let model = fixture.model, bot = fixture.bot
        model.runStates.removeAll()
        model.show(.home(bot.id))
        fixture.defaults.set(InspectorTab.model.rawValue, forKey: InspectorTab.storageKey)
        fixture.defaults.set(320.0, forKey: ConversationColumnSettings.widthKey)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1571, height: 960),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
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
        func columnOrigin() throws -> NSPoint {
            let scroll = try chatScroll(in: host)
            let frame = scroll.convert(scroll.bounds, to: host)
            return NSPoint(x: frame.minX - (try chatInset(in: host)),
                           y: host.safeAreaInsets.top)
        }
        func click(_ point: NSPoint) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { send(type, at: point, in: host) }
            try await settle(window)
        }
        func collapse() async throws {
            let origin = try columnOrigin(), width = try chatInset(in: host)
            try await click(NSPoint(x: origin.x + width - 20, y: origin.y + 77))
            #expect(fixture.defaults.bool(forKey: ConversationColumnSettings.collapsedKey))
            #expect(abs(try chatInset(in: host) - ConversationColumnLayout.railWidth) <= 1)
        }
        func expand() async throws {
            let origin = try columnOrigin()
            try await click(NSPoint(x: origin.x + 28, y: host.bounds.height - 22))
            #expect(!fixture.defaults.bool(forKey: ConversationColumnSettings.collapsedKey))
        }
        // Use the View menu's production button in a native menu, so its label, enabled state,
        // and action all execute, with the same AppStorage suite as the window.
        func menuCommand(_ title: String, enabled: Bool = true) async throws {
            let menuHost = NSHostingView(rootView: Color.gray.frame(width: 100, height: 40).contentShape(Rectangle())
                .contextMenu { ConversationColumnToggle(model: model) }.defaultAppStorage(fixture.defaults))
            let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
                                      styleMask: [.titled], backing: .buffered, defer: false)
            menuWindow.isReleasedWhenClosed = false
            menuWindow.contentView = menuHost
            menuWindow.orderFront(nil)
            defer { menuWindow.contentView = nil; menuWindow.close(); window.makeKeyAndOrderFront(nil) }
            try await settle(menuWindow)
            let menu = try tabMenu(at: NSPoint(x: 50, y: 20), in: menuHost)
            let item = try #require(menu.item(withTitle: title))
            #expect(item.isEnabled == enabled)
            if enabled {
                menu.performActionForItem(at: menu.index(of: item))
                try await settle(window)
            }
        }

        #expect(abs(window.frame.width - 1571) <= 1)
        #expect(abs(try chatInset(in: host) - 320) <= 1)
        // A changed width is restored by both controls and after recreating the view.
        fixture.defaults.set(280.0, forKey: ConversationColumnSettings.widthKey)
        try await settle(window)
        #expect(fixture.defaults.double(forKey: ConversationColumnSettings.widthKey) == 280)
        #expect(abs(try chatInset(in: host) - 280) <= 1)
        try await collapse()
        host = try await show()
        #expect(abs(try chatInset(in: host) - 56) <= 1)
        try await expand()
        #expect(abs(try chatInset(in: host) - 280) <= 1)
        host = try await show()
        #expect(abs(try chatInset(in: host) - 280) <= 1)

        // Both paths expand at the rail's minimum width; neither needs the window widened first.
        try await menuCommand("Collapse Tasks")
        window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 960), display: true)
        try await settle(window)
        try await expand()
        #expect(abs(try chatInset(in: host) - 280) <= 1)
        try checkChatFits(in: host)
        try await collapse()
        window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 960), display: true)
        try await settle(window)
        try await menuCommand("Expand Tasks")
        #expect(abs(try chatInset(in: host) - 280) <= 1)
        #expect(!fixture.defaults.bool(forKey: ConversationColumnSettings.collapsedKey))
        #expect(fixture.defaults.double(forKey: ConversationColumnSettings.widthKey) == 280)
        #expect(window.frame.width >= window.contentMinSize.width)
        try checkChatFits(in: host)

        // Labels remain selectable and the chat still accepts typing at this width.
        let narrowOrigin = try columnOrigin()
        try await click(NSPoint(x: narrowOrigin.x + 120, y: narrowOrigin.y + 134))
        let selected = try #require(model.openTasks(of: bot.id).first)
        let target = ChatTarget.task(selected.id, of: bot.id)
        #expect(model.tab(of: bot.id) == target)
        let editor = try #require(composerEditors(in: host).first)
        window.makeFirstResponder(editor)
        editor.insertText("A narrow draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(model.drafts[target] == "A narrow draft")

        model.show(.home(fixture.quiet.id))
        try await settle(window)
        try await menuCommand("Collapse Tasks", enabled: false)
    }

    private func composerEditors(in view: NSView) -> [ComposerTextView] {
        ((view as? ComposerTextView).map { [$0] } ?? []) + view.subviews.flatMap(composerEditors)
    }

    /// Find the transcript by its probe, including when a 320-point task column is wider than it.
    private func chatScroll(in host: NSView) throws -> NSScrollView {
        func probe(_ view: NSView) -> ChatScrollProbeView? {
            (view as? ChatScrollProbeView) ?? view.subviews.lazy.compactMap(probe).first
        }
        return try #require(probe(host)?.enclosingScrollView)
    }

    private func checkChatFits(in host: NSView) throws {
        let scroll = try chatScroll(in: host)
        let frame = scroll.convert(scroll.bounds, to: host)
        #expect(frame.width >= 300 && frame.minX >= 0 && frame.maxX <= host.bounds.maxX + 1)
        let editor = try #require(composerEditors(in: host).first)
        let composer = editor.convert(editor.bounds, to: host)
        #expect(composer.width > 100 && composer.minX >= frame.minX && composer.maxX <= frame.maxX + 1)
    }

    /// How far the chat starts from the sidebar's edge: the column's or the rail's width, or
    /// nothing. The detail column runs under the sidebar (which floats over it on macOS 26), and so
    /// does the chat's scroll view when nothing is beside it.
    private func chatInset(in host: NSView) throws -> CGFloat {
        let splits = tabSplitViews(in: host)
        try #require(splits.count == 2)
        let sidebar = try #require(splits[0].arrangedSubviews.first)
        let chat = try chatScroll(in: host)
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

    /// The buttons and the texts of an alert's window.
    private func alertButtons(in window: NSWindow) -> [NSButton] {
        func buttons(_ view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons) }
        return window.contentView.map(buttons) ?? []
    }

    private func alertTexts(in window: NSWindow) -> [String] {
        func texts(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts) }
        return window.contentView.map(texts) ?? []
    }

    /// The same colour, within what antialiasing leaves of a flat fill.
    private func near(_ a: NSColor, _ b: NSColor) -> Bool {
        [a.redComponent - b.redComponent, a.greenComponent - b.greenComponent,
         a.blueComponent - b.blueComponent, a.alphaComponent - b.alphaComponent].allSatisfy { abs($0) < 0.01 }
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

/// A tab as the column draws it, not hovered nor selected.
private struct PlainRow: View {
    let target: ChatTarget
    @FocusState private var focus: ChatTarget?

    var body: some View {
        ConversationRow(target: target, index: 1, selected: false, hovered: false, focus: $focus) { _ in }
    }
}

/// The summaries a test's runner was asked for.
private final class SummaryJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [EvaluationJob] = []

    func add(_ job: EvaluationJob) { lock.withLock { jobs.append(job) } }
    var all: [EvaluationJob] { lock.withLock { jobs } }
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

/// A view's own drawing, as `cacheDisplay` makes it, in sRGB and measured in points from its
/// top-left corner.
@MainActor private struct Drawing {
    let rep: NSBitmapImageRep
    let scale: CGFloat

    init(of view: NSView) throws {
        rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        scale = CGFloat(rep.pixelsWide) / view.bounds.width
    }

    func color(x: CGFloat, y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
    }

    /// The pixels of `rect` that are in the drawing, as rows and columns.
    private func pixels(in rect: CGRect) -> (rows: Range<Int>, columns: Range<Int>) {
        let top = max(0, Int(rect.minY * scale)), left = max(0, Int(rect.minX * scale))
        return (top..<max(top, min(rep.pixelsHigh, Int((rect.maxY * scale).rounded(.up)))),
                left..<max(left, min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up)))))
    }

    /// The smallest rectangle holding every pixel of `rect` whose colour matches, if any does.
    func bounds(in rect: CGRect, where match: (NSColor) -> Bool) -> CGRect? {
        var found: CGRect?
        let (rows, columns) = pixels(in: rect)
        for y in rows {
            for x in columns {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), match(color) else { continue }
                let pixel = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
                found = found.map { $0.union(pixel) } ?? pixel
            }
        }
        return found
    }

    /// Whether `other`, of the same size, draws the same as this in `rect`, within antialiasing.
    func matches(_ other: Drawing, in rect: CGRect) -> Bool {
        guard rep.pixelsWide == other.rep.pixelsWide, rep.pixelsHigh == other.rep.pixelsHigh else { return false }
        let (rows, columns) = pixels(in: rect)
        for y in rows {
            for x in columns {
                guard let a = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = other.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                let apart = [a.redComponent - b.redComponent, a.greenComponent - b.greenComponent,
                             a.blueComponent - b.blueComponent, a.alphaComponent - b.alphaComponent]
                if apart.contains(where: { abs($0) > 0.02 }) { return false }
            }
        }
        return true
    }

    /// The colours of the pixels whose middles are `distances` points from `centre`.
    func colours(around centre: CGPoint, at distances: ClosedRange<CGFloat>) -> [NSColor] {
        let reach = Int((distances.upperBound * scale).rounded(.up)) + 1
        let middleX = Int(centre.x * scale), middleY = Int(centre.y * scale)
        var found: [NSColor] = []
        for y in stride(from: max(0, middleY - reach), through: min(rep.pixelsHigh - 1, middleY + reach), by: 1) {
            for x in stride(from: max(0, middleX - reach), through: min(rep.pixelsWide - 1, middleX + reach), by: 1) {
                let dx = (CGFloat(x) + 0.5) / scale - centre.x, dy = (CGFloat(y) + 0.5) / scale - centre.y
                guard distances.contains((dx * dx + dy * dy).squareRoot()), let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                found.append(colour)
            }
        }
        return found
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

    /// The model BotChu makes on its next launch, from what this one saved.
    func relaunch() -> AppModel {
        AppModel(store: Store(root: root.appendingPathComponent("index")), settings: AppSettings(defaults: defaults),
                 usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests.") })
    }

    func cleanUp() {
        model.runStates.removeAll()
        model.stopAll()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
