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
    /// Providers is one table, whatever layout was saved before, and its rows stay under 100
    /// points in every state: more windows than a row shows, a failure with and without a last
    /// reading, a note, credits and free resets, a long name, in both appearances, from a wide
    /// window down to its narrowest and back. Its columns are the widths `ProvidersColumns` gives
    /// the table's width, whatever width it had before, with the allowance taking the rest.
    @Test func providersTableRowsStayCompact() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-providers-\(UUID().uuidString)")
        let domain = "BotChu.ProvidersTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        defaults.set("gallery", forKey: "providersLayout") // the choice the gallery used to restore
        let settings = AppSettings(defaults: defaults)
        settings.customAccounts = [Account(id: "custom-long", name: "Claude Research and Long-Form Writing Profile", kind: .claude,
                                           defaultCommand: "~/.local/bin/claude-research-and-long-form-writing", symbol: "terminal")]
        let claudeWork = FailAfterFirst()
        let usage = UsageCache { request, key in
            let usesExpectedKey = key == (request.account.kind == .pi ? "test-openrouter-key" : nil)
            #expect(usesExpectedKey)
            let now = Date()
            switch request.account.id {
            case "google":
                return ProviderUsage(windows: (0..<6).map {
                    UsageWindow(id: "\($0)", title: "Window \($0) · Weekly", usedPercent: Double($0 * 19), resetsAt: now.addingTimeInterval(Double($0 + 1) * 3_600))
                })
            case "codex-work":
                throw UsageFailure("Could not read account usage. Check the CLI’s sign-in and command, then refresh. " + String(repeating: "More detail. ", count: 20))
            case "claude-work":
                if await claudeWork.next() { throw UsageFailure("Usage check timed out. Try refreshing later.") }
            case "openrouter":
                return ProviderUsage(windows: [], note: "No key spending limit · $1.25 used")
            case "codex-dev":
                return ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 41, resetsAt: now.addingTimeInterval(259_200))],
                                     credits: UsageCredits(available: true, balance: 65_292.36), resets: UsageResets(available: 2, expiries: [now.addingTimeInterval(86_400)]))
            default: break
            }
            return ProviderUsage(windows: [UsageWindow(id: "session", title: "5-hour", usedPercent: 24, resetsAt: now.addingTimeInterval(7_200)),
                                           UsageWindow(id: "week", title: "Weekly", usedPercent: 83, resetsAt: now.addingTimeInterval(259_200))])
        }
        // Claude Work's reading, then a failed check: the reading stays, with the error.
        let account = try #require(settings.accounts.first { $0.id == "claude-work" })
        let request = UsageRequest(account: account, command: settings.command(for: account), credentialRevision: settings.usageCredentialRevision)
        _ = await usage.read(request, now: .now.addingTimeInterval(-400))
        let stale = await usage.read(request, manual: true)
        #expect(stale.reading != nil && stale.error != nil)

        var keyReads = 0
        let app = AppModel(store: Store(root: root.appendingPathComponent("index")), settings: settings, usage: usage,
                           openRouterKey: { keyReads += 1; return "test-openrouter-key" })
        let host = NSHostingView(rootView: ProvidersView().environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1908, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        // The width #134 was filed from, the default window's, the narrowest, and back to the widest.
        for (width, appearance) in [(1908.0, NSAppearance.Name.darkAqua), (1000, .aqua), (600, .darkAqua), (1908, .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: 1100))
            var table: NSTableView?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                window.layoutIfNeeded()
                table = providersTable(in: host)
                // Loaded once Google's row has grown to its windows.
                if let table, keyReads > 0, (0..<table.numberOfRows).contains(where: { table.rect(ofRow: $0).height > 60 }) { break }
            }
            let rows = try #require(table)
            #expect(segmentedControls(in: host).isEmpty) // no gallery/list switcher
            #expect(rows.numberOfRows == settings.accounts.count)
            #expect((0..<rows.numberOfRows).contains { rows.rect(ofRow: $0).height > 60 })
            for row in 0..<rows.numberOfRows { #expect(rows.rect(ofRow: row).height <= 100) }
            // No sideways scrolling at the narrowest width either.
            let visible = try #require(rows.enclosingScrollView?.contentView.bounds.width)
            #expect(rows.bounds.width <= visible + 1)
            // The other columns as wide as the table's size has them, and the allowance the rest.
            let table = try #require(rows.enclosingScrollView?.bounds.width)
            let columns = ProvidersColumns(width: table)
            let widths = Dictionary(uniqueKeysWithValues: rows.tableColumns.map { ($0.title, Double($0.width)) })
            #expect(widths["Provider"] == columns.provider && widths["Command"] == columns.command && widths["Updated"] == columns.updated)
            #expect(abs((widths["Allowance"] ?? 0) - columns.allowance(in: table)) <= 2)
            if width > 1_800 { #expect((widths["Allowance"] ?? 0) > table / 2) }
            try captureProviders(window, name: "providers-\(Int(width))-\(appearance == .darkAqua ? "dark" : "light")")
        }
        #expect(keyReads > 0) // The OpenRouter row uses the stand-in, even with an injected usage cache.
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
        await board.refresh(request, usage: usage, openRouterKey: { nil }, background: true)
        #expect(board.states[request]?.reading == reading) // ten minutes old: shown, not checked
        #expect(board.checking.isEmpty)
        await board.refresh(request, usage: usage, openRouterKey: { nil })
        #expect(board.states[request]?.reading?.windows.first?.usedPercent == 50) // shown, it is due
    }

    private func providersTable(in view: NSView) -> NSTableView? {
        (view as? NSTableView) ?? view.subviews.lazy.compactMap { providersTable(in: $0) }.first
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
