import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

/// Fails every check after the first.
private actor FailAfterFirst {
    private var calls = 0
    func next() -> Bool {
        calls += 1
        return calls > 1
    }
}

extension RenderingTests {
    /// Providers is one table of windows in columns (#148): each profile's model groups, its 5-hour
    /// and Weekly meters beside them, its credits and resets, and the agents set to it. Rows are 56
    /// points, 74 with three groups, in every state: stale with a passed reset, failed, a note, a
    /// missing command, credits and free resets, a long name, in both appearances, from a wide
    /// window down to its narrowest and back. The columns are the widths `ProvidersColumns` gives
    /// the table's width, with Agents taking the rest and going first when it doesn't fit. Weekly
    /// sorts by the highest share; selecting a row shows it in the sidebar; a row's menu refreshes,
    /// copies and changes its command, assigns an agent whose Home is idle to the profile, and
    /// removes an added profile after asking. Codex Dev reports a plan, which line 2 names.
    @Test func providersTableShowsWindowsInColumns() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-providers-\(UUID().uuidString)")
        let domain = "BotChu.ProvidersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        defaults.set("gallery", forKey: "providersLayout") // the choice the gallery used to restore
        let settings = AppSettings(defaults: defaults)
        settings.customAccounts = [Account(id: "custom-long", name: "Claude Research and Long-Form Writing Profile", kind: .claude,
                                           defaultCommand: "botchu-missing-\(UUID().uuidString.prefix(8))", symbol: "terminal")]
        let claudeWork = FailAfterFirst()
        // A Sail profile shows its balance in Credits & resets, with no window to meter.
        settings.customAccounts += [Account(id: "custom-sail", name: "Sail Lab", kind: .sail, defaultCommand: "botchu-sail", symbol: "sailboat")]
        let usage = UsageCache { request, keys in
            // Only the account's own key reaches its check: none for the CLI profiles.
            let expected = request.account.kind == .pi ? UsageKeys(openRouter: "test-openrouter-key") : UsageKeys()
            #expect(keys == expected, "Only fixture credentials reach the injected usage cache")
            let now = Date()
            switch request.account.id {
            case "custom-sail":
                return ProviderUsage(windows: [], readAt: now, balance: UsageBalance(credit: 54.98, spent: 1.98, period: "7d", perDay: 0.28, daysLeft: 194))
            case "google":
                return ProviderUsage(windows: ["Gemini · Weekly", "Gemini · 5-hour", "Claude & GPT · Weekly", "Claude & GPT · 5-hour", "Images · Daily"].enumerated().map {
                    UsageWindow(id: $1, title: $1, usedPercent: Double([22, 4, 97, 100, 61][$0]), resetsAt: now.addingTimeInterval(Double($0 + 1) * 9_000))
                })
            case "codex-work":
                throw UsageFailure("Could not read account usage. Check the CLI’s sign-in and command, then refresh. " + String(repeating: "More detail. ", count: 20))
            case "custom-long": throw UsageFailure("The login shell can’t find this profile’s command.")
            case "claude-work":
                if await claudeWork.next() { throw UsageFailure("Usage check timed out. Try refreshing later.") }
                return ProviderUsage(windows: [UsageWindow(id: "session", title: "5-hour", usedPercent: 2, resetsAt: now.addingTimeInterval(-60)),
                                               UsageWindow(id: "week", title: "Weekly", usedPercent: 7, resetsAt: now.addingTimeInterval(259_200))])
            case "openrouter":
                return ProviderUsage(windows: [], note: "No key spending limit · $1.25 used")
            case "codex-personal":
                return ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 100, resetsAt: now.addingTimeInterval(97_200))],
                                     credits: UsageCredits(available: false), resets: UsageResets(available: 1, expiries: [now.addingTimeInterval(172_800)]))
            case "codex-dev":
                return ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 41, resetsAt: now.addingTimeInterval(259_200))],
                                     credits: UsageCredits(available: true, balance: 65_292.36), resets: UsageResets(available: 2, expiries: [now.addingTimeInterval(86_400)]),
                                     plan: "prolite")
            default: break
            }
            return ProviderUsage(windows: [UsageWindow(id: "session", title: "5-hour", usedPercent: 24, resetsAt: now.addingTimeInterval(7_200)),
                                           UsageWindow(id: "week", title: "Weekly", usedPercent: 83, resetsAt: now.addingTimeInterval(259_200)),
                                           UsageWindow(id: "fable", title: "Fable · Weekly", usedPercent: 20, resetsAt: now.addingTimeInterval(259_200))])
        }
        // Claude Work's reading, then a failed check: the reading stays, with the error.
        let account = try #require(settings.accounts.first { $0.id == "claude-work" })
        let request = UsageRequest(account: account, command: settings.command(for: account), openRouterKeyRevision: settings.usageCredentialRevision)
        _ = await usage.read(request, now: .now.addingTimeInterval(-400))
        let stale = await usage.read(request, for: .manual)
        #expect(stale.reading != nil && stale.error != nil)

        var keyReads = 0
        let app = AppModel(store: Store(root: root.appendingPathComponent("index")), settings: settings, usage: usage,
                           openRouterKey: { keyReads += 1; return "test-openrouter-key" })
        app.sailKey = { nil }
        // Five agents on Codex Personal, more than its column holds, and one on Claude Dev.
        app.bots = ["Danny", "Racoon", "Duck", "Fox", "Owl"].map { Bot(name: $0, emoji: "🦊", accountID: "codex-personal", workspace: root.appendingPathComponent($0).path) }
            + [Bot(name: "Scout", emoji: "🔭", accountID: "claude-dev", workspace: root.appendingPathComponent("scout").path)]
        var host = NSHostingView<AnyView>(rootView: AnyView(ProvidersView().environment(app).defaultAppStorage(defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1908, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        let google = try #require(settings.accounts.firstIndex { $0.id == "google" })

        /// The table, once Google's row has grown to its three groups.
        func loadedTable() async throws -> NSTableView {
            var table: NSTableView?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                window.layoutIfNeeded()
                table = providersTable(in: host)
                if let table, keyReads > 0, (0..<table.numberOfRows).contains(where: { table.rect(ofRow: $0).height > 60 }) { break }
            }
            return try #require(table)
        }

        // The width #148 was filed from, #222's, a regular, a compact table with and without Agents, the narrowest, and back to the widest.
        for (width, appearance) in [(1908.0, NSAppearance.Name.darkAqua), (1882, .aqua), (1300, .aqua), (1000, .darkAqua), (830, .aqua), (600, .darkAqua), (1908, .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: 1100))
            let rows = try await loadedTable()
            #expect(segmentedControls(in: host).isEmpty) // no gallery/list switcher
            #expect(rows.numberOfRows == settings.accounts.count)
            // 56 points a row, with 10 above and below two 18-point lines; Google's three groups, 74.
            for row in 0..<rows.numberOfRows { #expect(rows.rect(ofRow: row).height == (row == google ? 74 : 56), "row \(row) at \(width)") }
            // No sideways scrolling at the narrowest width either.
            let visible = try #require(rows.enclosingScrollView?.contentView.bounds.width)
            #expect(rows.bounds.width <= visible + 1)
            // The columns as wide as the table's size has them, and the rest Agents', or Credits & resets' without it.
            let tableWidth = try #require(rows.enclosingScrollView?.bounds.width)
            let columns = ProvidersColumns(width: tableWidth)
            let shown = rows.tableColumns.filter { !$0.isHidden }
            #expect(shown.map(\.title) == ["Provider", "Models", "5-hour", "Weekly", "Credits & resets"] + (columns.showsAgents ? ["Agents"] : []))
            #expect(columns.showsAgents == (width > 900))
            let widths = Dictionary(uniqueKeysWithValues: shown.map { ($0.title, Double($0.width) + ProvidersColumns.spacing) })
            #expect(widths["Provider"] == columns.provider && widths["Models"] == columns.models)
            #expect(widths["5-hour"] == columns.window && widths["Weekly"] == columns.window)
            if columns.showsAgents { #expect(widths["Credits & resets"] == columns.credits) }
            #expect(abs((widths[columns.showsAgents ? "Agents" : "Credits & resets"] ?? 0) - columns.rest(in: tableWidth)) <= 2)
            try captureProviders(window, name: "providers-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light")")
        }
        #expect(keyReads > 0) // The OpenRouter row uses the stand-in, even with an injected usage cache.

        // In the window, beside the bots, where the selected profile shows in the sidebar.
        app.destination = .providers
        host = NSHostingView(rootView: AnyView(ContentView().environment(app).defaultAppStorage(defaults)))
        window.contentView = host
        window.setContentSize(NSSize(width: 1908, height: 960))

        // Weekly sorts by the highest share used, most first: Codex Personal's 100%, then Google's 97%.
        var rows = try await loadedTable()
        let weekly = try #require(rows.tableColumns.first { $0.title == "Weekly" }?.sortDescriptorPrototype)
        let mostFirst = try #require(weekly.reversedSortDescriptor as? NSSortDescriptor)
        rows.sortDescriptors = [mostFirst]
        try await Task.sleep(for: .milliseconds(300))
        rows = try await loadedTable()
        #expect(rows.rect(ofRow: 1).height == 74)
        #expect(rows.rect(ofRow: google).height == 56)

        // Selecting Codex Personal shows it in the sidebar, beside a narrower table; closing it deselects.
        let fullWidth = rows.bounds.width
        rows.selectRowIndexes([0], byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(600))
        #expect(app.providerSelection == "codex-personal")
        rows = try await loadedTable()
        #expect(rows.bounds.width < fullWidth - 250)
        try captureProviders(window, name: "providers-selected")

        // A row's menu, with its agents: those set to it checked, and one whose Home is running
        // disabled; a running Task leaves its Home free.
        let scout = try #require(app.bots.last)
        let danny = try #require(app.bots.first)
        app.runStates[.home(scout.id)] = RunState()
        app.runStates[.task(UUID(), of: danny.id)] = RunState()
        var menu = try providersMenu(at: rows.rowView(atRow: 0, makeIfNecessary: false), in: host)
        #expect(menu.items.map(\.title) == ["Refresh", "Copy Command", "Change Command…", "", "Assign to Agent"])
        var agents = try #require(menu.item(withTitle: "Assign to Agent")?.submenu)
        #expect(agents.items.map(\.title) == app.bots.map(\.name))
        #expect(agents.items.map(\.state) == app.bots.map { $0.accountID == "codex-personal" ? .on : .off })
        #expect(agents.items.map(\.isEnabled) == app.bots.map { $0.id != scout.id })
        app.runStates.removeAll()
        rows.sortDescriptors = []
        app.providerSelection = nil
        try await Task.sleep(for: .milliseconds(600))
        rows = try await loadedTable()
        let custom = try #require(settings.accounts.firstIndex { $0.id == "custom-long" })
        // Its second line, Command not found, opens what went wrong, with Try Again and Change Command.
        let cell = rows.frameOfCell(atColumn: 0, row: custom)
        let problem = rows.convert(NSPoint(x: cell.minX + 28 + 10 + 30, y: cell.midY + (rows.isFlipped ? 8 : -8)), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: problem, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        try await Task.sleep(for: .milliseconds(600))
        let popover = try #require(NSApp.windows.first { $0.isVisible && String(describing: type(of: $0)).contains("Popover") })
        try captureProviders(popover, name: "providers-command-not-found")
        popover.close()
        try await Task.sleep(for: .milliseconds(300))
        // Assigning Duck moves its Home to the profile: another family, so its model and effort clear.
        menu = try providersMenu(at: rows.rowView(atRow: custom, makeIfNecessary: false), in: host)
        #expect(menu.items.map(\.title) == ["Refresh", "Copy Command", "Change Command…", "", "Assign to Agent", "", "Remove Profile…"])
        agents = try #require(menu.item(withTitle: "Assign to Agent")?.submenu)
        #expect(agents.items.allSatisfy { $0.state == .off && $0.isEnabled })
        let duck = app.bots[2]
        agents.performActionForItem(at: agents.indexOfItem(withTitle: "Duck"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(app.bot(duck.id)?.accountID == "custom-long" && app.bot(duck.id)?.account.kind == .claude)
        #expect(app.bot(duck.id)?.model == "" && app.bot(duck.id)?.reasoningEffort == nil)
        menu = try providersMenu(at: rows.rowView(atRow: custom, makeIfNecessary: false), in: host)
        #expect(menu.item(withTitle: "Assign to Agent")?.submenu?.item(withTitle: "Duck")?.state == .on)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Remove Profile…"))
        try await Task.sleep(for: .milliseconds(500))
        let dialog = try #require(window.attachedSheet)
        try captureProviders(dialog, name: "providers-remove")
        let content = try #require(dialog.contentView)
        try #require(providersButtons(in: content).first { $0.title == "Remove Profile" }).performClick(nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(settings.customAccounts.map(\.id) == ["custom-sail"])
        #expect(try await loadedTable().numberOfRows == settings.accounts.count)
    }

    /// The table opens on what was read before, here or before a relaunch, and checks only once
    /// that is due: in the background after a profile's longer interval, while shown after its own.
    @Test func providersOpenOnSavedReadings() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        let request = UsageRequest(account: Accounts.account(id: "codex-dev"), command: "codex-dev")
        let reading = ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 41)], readAt: .now.addingTimeInterval(-600),
                                    credits: UsageCredits(available: true, balance: 12), resets: UsageResets(available: 1))
        _ = await UsageCache(fetch: { _, _ in reading }, file: file).read(request, now: .now.addingTimeInterval(-600))

        let usage = UsageCache(fetch: { _, _ in ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 50)]) }, file: file)
        let board = ProviderUsageBoard()
        await board.refresh(request, usage: usage, keys: { _ in UsageKeys() }, for: .background)
        #expect(board.states[request]?.reading == reading) // ten minutes old: shown, not checked
        #expect(board.checking.isEmpty)
        await board.refresh(request, usage: usage, keys: { _ in UsageKeys() })
        #expect(board.states[request]?.reading?.windows.first?.usedPercent == 50) // shown, it is due
    }

    /// Meters are 8-point bars, as wide as each table size's layout has them, with a 1.5-point tick
    /// for the share of the window gone by, 2 points past the bar's top and bottom and set off from
    /// the fill and the track by a gap (#222). It stands out over the fill and over the track, in both
    /// appearances, in a selected row and in a stale one; a window without a known length has none.
    @Test func usageMetersMarkTheTimeGoneBy() throws {
        _ = NSApplication.shared
        let now = Date()
        func line(used: Double, period: TimeInterval?) -> UsageLine {
            UsageLine(UsageWindow(id: "w", title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(UsageWindow.week / 2 + 30),
                                  period: period ?? 0), at: now)
        }
        let layouts = [1_882.0, 1_300, 1_000, ProvidersColumns.minimumWidth].map { ProvidersColumns(width: $0).meter }
        #expect(layouts.map(\.bar) == [220, 85, 50, 40])
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for selected in [false, true] {
                for dimmed in [false, true] {
                    for layout in layouts {
                        for used in [62.0, 20, 90] {
                            let state = "\(appearance.rawValue) selected \(selected) dimmed \(dimmed) bar \(layout.bar) used \(used)"
                            let meter = try MeterPixels(line(used: used, period: UsageWindow.week), layout: layout, dimmed: dimmed, selected: selected, appearance: appearance)
                            let tick = meter.barX + layout.bar * meter.elapsed
                            // 8 points high and the layout's width; the tick 12 high, centred on it.
                            let ink = try #require(meter.ink(in: CGRect(x: meter.barX - 3, y: 0, width: layout.bar + 6, height: meter.height)), "\(state)")
                            #expect(abs(ink.width - layout.bar) <= 0.5, "\(state): \(ink)")
                            #expect(abs(ink.height - (UsageMeterLayout.barHeight + 4)) <= 0.5, "\(state): \(ink)")
                            let bar = try #require(meter.ink(in: CGRect(x: meter.barX + 3, y: 0, width: 2, height: meter.height)), "\(state)")
                            #expect(abs(bar.height - UsageMeterLayout.barHeight) <= 0.5 && abs(bar.midY - ink.midY) <= 0.5, "\(state): \(bar)")
                            // The tick past the bar, over it, and a gap on each side through to the row.
                            let above = try #require(meter.color(x: tick, y: bar.minY - 1), "\(state)")
                            #expect(Luminance.contrast(above, meter.background) >= 3, "\(state): tick \(above)")
                            #expect(Luminance.distance(try #require(meter.color(x: tick, y: bar.midY)), above) < 0.1, "\(state): over the bar")
                            #expect(Luminance.distance(try #require(meter.color(x: tick, y: bar.maxY + 1)), above) < 0.1, "\(state)")
                            #expect(meter.color(x: tick, y: bar.minY - 2.5).map { Luminance.distance($0, meter.background) < 0.05 } == true, "\(state): 2 points past")
                            for side in [-1.4, 1.4] {
                                let gap = try #require(meter.color(x: tick + side, y: bar.midY), "\(state)")
                                #expect(Luminance.distance(gap, meter.background) < 0.05, "\(state): gap \(gap)")
                            }
                        }
                    }
                    // No length, no tick: only the bar.
                    let unknown = try MeterPixels(line(used: 62, period: nil), layout: layouts[0], dimmed: dimmed, selected: selected, appearance: appearance)
                    #expect(unknown.line.elapsed == nil)
                    let ink = try #require(unknown.ink(in: CGRect(x: unknown.barX - 3, y: 0, width: layouts[0].bar + 6, height: unknown.height)))
                    #expect(abs(ink.height - UsageMeterLayout.barHeight) <= 0.5, "\(appearance.rawValue) selected \(selected): \(ink)")
                }
            }
        }
    }

    /// The context menu a right click shows in the middle of a row view.
    private func providersMenu(at row: NSView?, in host: NSView) throws -> NSMenu {
        let row = try #require(row)
        let location = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: host.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var view = host.hitTest(host.superview?.convert(location, from: nil) ?? location)
        var menu: NSMenu?
        while let current = view, menu == nil {
            menu = current.menu(for: event)
            view = current.superview
        }
        return try #require(menu)
    }

    private func providersButtons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(providersButtons)
    }

    private func providersTable(in view: NSView) -> NSTableView? {
        (view as? NSTableView).flatMap { $0.tableColumns.contains { $0.title == "Weekly" } ? $0 : nil }
            ?? view.subviews.lazy.compactMap { providersTable(in: $0) }.first
    }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap(segmentedControls)
    }

    private func captureProviders(_ window: NSWindow, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["BOTCHU_TEST_SNAPSHOTS"], let view = window.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        let url = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try image.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
    }
}

/// A Providers meter drawn alone on its row's background, unselected or selected, measured in points
/// from its top-left corner.
@MainActor private struct MeterPixels {
    static let inset = 10.0
    let line: UsageLine
    let rep: NSBitmapImageRep
    let scale: CGFloat
    let height: CGFloat
    let background: NSColor
    var barX: CGFloat { Self.inset }
    var elapsed: CGFloat { CGFloat(line.elapsed ?? 0) }

    init(_ line: UsageLine, layout: UsageMeterLayout, dimmed: Bool, selected: Bool, appearance: NSAppearance.Name) throws {
        self.line = line
        let named = try #require(NSAppearance(named: appearance))
        var row = NSColor.windowBackgroundColor
        if selected { named.performAsCurrentDrawingAppearance { row = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB) ?? row } }
        else { named.performAsCurrentDrawingAppearance { row = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? row } }
        let host = NSHostingView(rootView: UsageMeter(line: line, layout: layout, dimmed: dimmed)
            .environment(\.backgroundProminence, selected ? .increased : .standard)
            .padding(Self.inset).background(Color(nsColor: row)))
        host.appearance = named
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        scale = CGFloat(rep.pixelsWide) / host.bounds.width
        height = host.bounds.height
        background = try #require(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    }

    func color(x: CGFloat, y: CGFloat) -> NSColor? {
        rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
    }

    /// The smallest rectangle holding every pixel of `rect` that isn't the row's background.
    func ink(in rect: CGRect) -> CGRect? {
        var found: CGRect?
        for y in max(0, Int(rect.minY * scale))..<min(rep.pixelsHigh, Int((rect.maxY * scale).rounded(.up))) {
            for x in max(0, Int(rect.minX * scale))..<min(rep.pixelsWide, Int((rect.maxX * scale).rounded(.up))) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), Luminance.distance(color, background) > 0.03 else { continue }
                let pixel = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale)
                found = found.map { $0.union(pixel) } ?? pixel
            }
        }
        return found
    }
}

private enum Luminance {
    static func relative(_ color: NSColor) -> Double {
        func linear(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    }

    /// WCAG's contrast ratio between two opaque colours.
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (relative(a), relative(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// The largest difference of their sRGB components.
    static func distance(_ a: NSColor, _ b: NSColor) -> Double {
        Double(max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent)))
    }
}
