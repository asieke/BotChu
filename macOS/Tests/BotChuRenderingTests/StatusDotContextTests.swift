import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// #237: exercise the native sidebar List, not a manually injected background prominence.
    /// The same model drives its real 6pt dots and the column/rail's 8pt dots, including changes
    /// made after mounting. Quiet test windows use AppKit's native row emphasis and Reduce Motion:
    /// a background test process cannot take key-window focus, and hidden keyframes can stop mid-pop.
    /// In an AppKit application loop, BOTCHU_SHOW_TEST_WINDOWS=1 also checks real focus changes
    /// and the normal completion animation (SwiftPM's background helper has no application loop).
    @Test func statusDotsKeepTheirColoursInNativeSelectedRows() async throws {
        _ = NSApplication.shared
        let liveFocus = NSApp.isRunning && ProcessInfo.processInfo.environment["BOTCHU_SHOW_TEST_WINDOWS"] == "1"
        let activeApp = NSWorkspace.shared.frontmostApplication
        let oldPolicy = NSApp.activationPolicy()
        if liveFocus {
            NSApp.setActivationPolicy(.regular)
        }
        defer {
            if liveFocus {
                NSApp.setActivationPolicy(oldPolicy)
                activeApp?.activate(options: [])
            }
        }
        let fixture = try StatusContextFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let target = fixture.targets[0]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 556, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        for w in [window, other] { w.isReleasedWhenClosed = false }
        defer { window.contentView = nil; window.close(); other.close() }
        let sidebar = NSHostingView(rootView: SidebarView().environment(model).defaultAppStorage(fixture.defaults)
            .environment(\._accessibilityReduceMotion, !liveFocus))
        let columns = NSHostingView(rootView: StatusContextColumns(botID: fixture.bot.id).environment(model)
            .environment(\._accessibilityReduceMotion, !liveFocus))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 556, height: 640))
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 640)
        columns.frame = NSRect(x: 260, y: 0, width: 296, height: 640)
        container.addSubview(sidebar)
        container.addSubview(columns)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        if liveFocus {
            NSApp.activate()
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
        for _ in 0..<200 where model.inbox.delivery(fixture.question.id) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.inbox.delivery(fixture.question.id) != nil)
        try await statusContextSettle(window)
        let table = try #require(statusContextTable(in: sidebar))
        window.makeFirstResponder(table)
        let oldAppearance = NSApp.appearance
        defer { NSApp.appearance = oldAppearance }
        let kinds: [TabState.Kind] = [.preparing, .starting, .working, .news, .failed, .stopped, .needsInput, .idle]
        var comparisons = 0
        var emphasizedSelections = 0
        var largestColourDifference: CGFloat = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            NSApp.appearance = window.appearance
            for kind in kinds {
                fixture.set(kind, on: target)
                for selected in [false, true] {
                    model.show(.home(selected ? fixture.bot.id : fixture.quiet.id))
                    for focused in [true, false] {
                        if focused { window.makeKeyAndOrderFront(nil) } else { other.makeKeyAndOrderFront(nil) }
                        try await statusContextSettle(window)
                        if liveFocus { #expect(window.isKeyWindow == focused) }
                        let index = table.numberOfRows - 2
                        #expect((table.selectedRow == index) == selected)
                        let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: false))
                        let nativeRow = try #require(table.rowView(atRow: index, makeIfNecessary: false))
                        if !liveFocus {
                            nativeRow.isEmphasized = focused
                            try await statusContextSettle(window)
                        }
                        let row = try StatusContextDrawing(cell)
                        let tabs = try StatusContextDrawing(columns)
                        let label = "\(appearance.rawValue)-\(kind)-selected-\(selected)-focused-\(focused)"
                        try row.save(label + "-sidebar")
                        try tabs.save(label + "-tabs")
                        let rowRegion = CGRect(x: cell.bounds.width - 24, y: 0, width: 24, height: cell.bounds.height)
                        let columnRegion = CGRect(x: 16, y: 90, width: 16, height: 70)
                        let railRegion = CGRect(x: 276, y: 60, width: 14, height: 24)
                        if kind == .idle {
                            #expect(model.botRowSummary(of: fixture.bot).dots.isEmpty)
                            #expect(row.dots(in: rowRegion).isEmpty, "\(label): idle omitted from sidebar")
                            #expect(tabs.dots(in: railRegion).isEmpty, "\(label): idle omitted from rail")
                            continue
                        }
                        #expect(model.botRowSummary(of: fixture.bot).dots == [kind])
                        let expected = StatusContextDrawing.hue(for: kind)
                        let sidebarDot = try row.dot(in: rowRegion, hue: expected, label: label + " sidebar")
                        let columnDot = try tabs.dot(in: columnRegion, hue: expected, label: label + " column")
                        let railDot = try tabs.dot(in: railRegion, hue: expected, label: label + " rail")
                        if selected, nativeRow.isEmphasized {
                            emphasizedSelections += 1
                            let ground = try #require(tabs.colour(at: CGPoint(x: 2, y: 20)))
                            for x in [sidebarDot.bounds.minX - 0.75, sidebarDot.bounds.maxX + 0.75] {
                                let beside = try #require(row.colour(at: CGPoint(x: x, y: sidebarDot.bounds.midY)))
                                #expect(beside.distance(to: ground) < 0.025,
                                        "\(label): selected dot's ground \(beside), column's \(ground)")
                            }
                        }
                        if !liveFocus { #expect(abs(sidebarDot.bounds.width - 6) <= 1, "\(label): \(sidebarDot.bounds)") }
                        for dot in [columnDot, railDot] {
                            if liveFocus {
                                // A normal completion pop can be captured above its resting size.
                                // Its relative size stays the same across the 6pt and 8pt surfaces.
                                #expect(abs(sidebarDot.bounds.width / 6 - dot.bounds.width / 8) < 0.3,
                                        "\(label): sidebar \(sidebarDot.bounds), tab \(dot.bounds)")
                            } else {
                                #expect(abs(dot.bounds.width - 8) <= 1, "\(label): \(dot.bounds)")
                            }
                            let difference = sidebarDot.colour.distance(to: dot.colour)
                            comparisons += 1
                            largestColourDifference = max(largestColourDifference, difference)
                            #expect(difference < 0.025,
                                    "\(label): sidebar \(sidebarDot.colour), tab \(dot.colour)")
                        }
                        // Hollow rings remain hollow at their actual size; filled states keep their hue.
                        let hollow = kind == .preparing || kind == .starting
                        for (drawing, dot) in [(row, sidebarDot), (tabs, columnDot), (tabs, railDot)] {
                            let centre = try #require(drawing.colour(at: CGPoint(x: dot.bounds.midX, y: dot.bounds.midY)))
                            #expect((centre.distance(to: dot.colour) > 0.1) == hollow, "\(label): ring/fill at \(dot.bounds)")
                        }
                    }
                }
            }
        }
        #expect(comparisons == 112 && emphasizedSelections >= 14)
        print("Status dots: \(comparisons) native sidebar/column/rail colour comparisons, \(emphasizedSelections) emphasized selections, largest RGB-channel difference \(largestColourDifference), live focus \(liveFocus)")

        // Mixed Home/task states, urgency, the four-dot cap, then resolution and read transitions.
        // All three surfaces above remain mounted throughout these changes.
        let home = ChatTarget.home(fixture.bot.id), tasks = fixture.targets
        model.show(tasks[4])
        fixture.set(.news, on: home)
        fixture.set(.needsInput, on: tasks[0])
        model.runStates[tasks[0]] = RunState(hasOutput: true, activity: .coding)
        for (target, kind) in zip(tasks.dropFirst(), [TabState.Kind.failed, .stopped, .preparing, .starting, .working]) {
            fixture.set(kind, on: target)
        }
        func checkMixed(_ label: String, expected: [TabState.Kind], more: Int) async throws {
            try await statusContextSettle(window)
            let summary = model.botRowSummary(of: fixture.bot)
            #expect(summary.dots == expected && summary.more == more)
            let cell = try #require(table.view(atColumn: 0, row: table.numberOfRows - 2, makeIfNecessary: false))
            let row = try StatusContextDrawing(cell), tabs = try StatusContextDrawing(columns)
            let dots = row.dots(in: CGRect(x: cell.bounds.width - 80, y: 0, width: 80, height: cell.bounds.height))
                .sorted { $0.bounds.minX < $1.bounds.minX }
            let columnDots = tabs.dots(in: CGRect(x: 16, y: 0, width: 16, height: 600)).sorted { $0.bounds.minY < $1.bounds.minY }
            let railDots = tabs.dots(in: CGRect(x: 276, y: 0, width: 14, height: 600)).sorted { $0.bounds.minY < $1.bounds.minY }
            let busy = model.tabs(of: fixture.bot.id).map { model.tabState(of: $0).kind }.filter { $0 != .idle }
            try #require(dots.count == expected.count, "\(label): sidebar dots \(dots.map(\.bounds))")
            try #require(columnDots.count == busy.count && railDots.count == busy.count, "\(label): column \(columnDots.count), rail \(railDots.count), states \(busy)")
            for (dot, kind) in zip(dots, expected) {
                let index = try #require(busy.firstIndex(of: kind))
                #expect(StatusContextDrawing.hue(for: kind).contains(dot.colour.hueComponent * 360), "\(label): \(kind)")
                #expect(dot.colour.distance(to: columnDots[index].colour) < 0.025 && dot.colour.distance(to: railDots[index].colour) < 0.025)
            }
        }
        try await checkMixed("seven busy", expected: [.needsInput, .failed, .stopped, .preparing], more: 3)
        model.inbox.setDone(fixture.question.id, true)
        try await checkMixed("request resolved", expected: [.failed, .stopped, .working, .preparing], more: 3)
        fixture.set(.idle, on: tasks[1])
        fixture.set(.news, on: tasks[2])
        model.show(home)
        try await checkMixed("Home read", expected: [.working, .preparing, .starting, .working], more: 1)
        model.show(tasks[2])
        try await checkMixed("completion read", expected: [.working, .preparing, .starting, .working], more: 0)
    }
}

private struct StatusContextColumns: View {
    let botID: UUID
    @FocusState private var focus: ChatTarget?
    var body: some View {
        HStack(spacing: 0) {
            ConversationColumn(botID: botID, width: 240, focus: $focus, resize: { _ in }, collapse: {})
            ConversationRail(botID: botID, canExpand: true, focus: $focus, expand: {})
        }
    }
}

@MainActor private func statusContextSettle(_ window: NSWindow) async throws {
    // Includes the longest terminal-state pop (0.36s) in the visible reproduction.
    let steps = NSApp.isRunning && ProcessInfo.processInfo.environment["BOTCHU_SHOW_TEST_WINDOWS"] == "1" ? 12 : 6
    for _ in 0..<steps {
        window.updateConstraintsIfNeeded()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
    }
}

@MainActor private func statusContextTable(in view: NSView) -> NSTableView? {
    (view as? NSTableView) ?? view.subviews.lazy.compactMap(statusContextTable).first
}

@MainActor private struct StatusContextDrawing {
    let bitmap: NSBitmapImageRep
    let scale: CGFloat
    init(_ view: NSView) throws {
        bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
    }
    struct Pixel {
        let point: CGPoint
        let colour: NSColor
    }
    struct Dot {
        let bounds: CGRect
        let colour: NSColor
    }
    func colour(at point: CGPoint) -> NSColor? {
        bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }
    func colouredPixels(in rect: CGRect) -> [Pixel] {
        var result: [Pixel] = []
        for y in max(0, Int(rect.minY * scale))..<min(bitmap.pixelsHigh, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(bitmap.pixelsWide, Int(rect.maxX * scale)) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5,
                      c.saturationComponent > 0.25 else { continue }
                result.append(Pixel(point: CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale), colour: c))
            }
        }
        return result
    }
    static func hue(for kind: TabState.Kind) -> ClosedRange<CGFloat> {
        switch kind {
        case .preparing, .starting, .working: 240...290
        case .news: 90...160
        case .needsInput: 22...50
        default: 0...15
        }
    }
    func dot(in rect: CGRect, hue: ClosedRange<CGFloat>, label: String) throws -> Dot {
        let matching = dots(in: rect).filter { hue.contains($0.colour.hueComponent * 360) }
        try #require(matching.count == 1, "\(label): \(matching.count) dots in \(rect)")
        return matching[0]
    }
    private func makeDot(_ pixels: [Pixel]) -> Dot {
        let xs = pixels.map { $0.point.x }, ys = pixels.map { $0.point.y }
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -0.5 / scale, dy: -0.5 / scale)
        // The most frequent pixel is the flat fill, rather than an antialiased edge.
        let colours = Dictionary(grouping: pixels.map(\.colour), by: Self.colourKey)
        let colour = colours.max { $0.value.count < $1.value.count }!.value[0]
        return Dot(bounds: bounds, colour: colour)
    }
    private static func colourKey(_ colour: NSColor) -> [Int] {
        [colour.redComponent, colour.greenComponent, colour.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    /// Connected patches distinguish dots from the native selection background and text glyphs.
    func dots(in rect: CGRect) -> [Dot] {
        let pixels = colouredPixels(in: rect)
        let width = bitmap.pixelsWide
        var remaining = Dictionary(uniqueKeysWithValues: pixels.map {
            (Int($0.point.y * scale) * width + Int($0.point.x * scale), $0)
        })
        var result: [Dot] = []
        while let start = remaining.keys.first {
            var stack = [start], patch: [Pixel] = []
            while let index = stack.popLast() {
                guard let pixel = remaining.removeValue(forKey: index) else { continue }
                patch.append(pixel)
                stack += [index - 1, index + 1, index - width, index + width].filter { remaining[$0] != nil }
            }
            let dot = makeDot(patch)
            if (3...16).contains(dot.bounds.width), (3...16).contains(dot.bounds.height) { result.append(dot) }
        }
        return result
    }
    func save(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
}

private extension NSColor {
    func distance(to other: NSColor) -> CGFloat {
        max(abs(redComponent - other.redComponent), abs(greenComponent - other.greenComponent), abs(blueComponent - other.blueComponent))
    }
}

@MainActor private final class StatusContextFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-status-context-\(UUID())")
    let domain = "BotChu.StatusContext.\(UUID())"
    let defaults: UserDefaults
    let bot: Bot
    let quiet: Bot
    let model: AppModel
    let targets: [ChatTarget]
    let question: Delivery
    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        bot = Bot(name: "Status", emoji: "⚪", workspace: root.appendingPathComponent("bot").path)
        quiet = Bot(name: "Quiet", emoji: "⚪", workspace: root.appendingPathComponent("quiet").path)
        let checkout = root.path, botID = bot.id
        let tasks = (1...6).map { BotTask(repo: "fixture/status", checkout: checkout, brief: "Task \($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
        targets = tasks.map { .task($0.id, of: botID) }
        let home = BotHome(workspace: bot.workspace)
        try home.save(bot)
        for task in tasks { try home.save(task) }
        try BotHome(workspace: quiet.workspace).save(quiet)
        question = Delivery(botID: bot.id, taskID: tasks[0].id, title: "Choose", question: .init(text: "Which?", choices: ["One", "Two"]), purpose: .needsInput)
        try InboxFolder(home: home).save(question, contents: [:])
        let store = Store(root: root.appendingPathComponent("index"))
        try store.saveIndex([.init(id: bot.id, workspace: bot.workspace), .init(id: quiet.id, workspace: quiet.workspace)])
        model = AppModel(store: store, settings: AppSettings(defaults: defaults), usage: UsageCache { _, _ in throw UsageFailure("No usage in tests") })
    }
    func set(_ kind: TabState.Kind, on target: ChatTarget) {
        if target == targets[0] { model.inbox.setDone(question.id, kind != .needsInput) }
        model.runStates[target] = nil
        model.unread.remove(target)
        let message = ChatMessage(role: kind == .failed ? .error : .assistant, text: "Finished")
        var messages = [ChatMessage(role: .user, text: "Go"), message]
        if kind == .stopped { messages.append(.stopNote(byOwner: true)) }
        model.conversation(target).replace(messages)
        switch kind {
        case .preparing: model.runStates[target] = RunState(preparing: true)
        case .starting: model.runStates[target] = RunState()
        case .working: model.runStates[target] = RunState(hasOutput: true, activity: .coding)
        case .news: model.unread.insert(target)
        default: break
        }
    }
    func cleanUp() {
        model.runStates.removeAll()
        model.stopAll()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
