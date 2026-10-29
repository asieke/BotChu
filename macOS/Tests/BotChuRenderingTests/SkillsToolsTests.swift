import AppKit
import SwiftUI
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    /// Skills & Tools (#246) is two tabs of native tables, as Providers is one: Skills, with the
    /// tools each skill uses, and Tools, with the approved tools, the SSH destinations and
    /// BotChu's helpers in groups. In both appearances, wide and narrow (where Files and Used by go
    /// first), selecting a row opens its sidebar beside a narrower table. A skill's declared tool
    /// opens that tool, or Add Tools when it isn't approved; a tool's skill opens that skill. Only
    /// an approved catalog tool is checked, and nothing is approved or enforced by opening the page.
    @Test func skillsAndToolsAreNativeTablesThatLinkToEachOther() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-skills-tools-\(UUID().uuidString)")
        let domain = "BotChu.SkillsToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        let scout = Bot(name: "Scout", emoji: "🔭", accountID: "claude-dev", workspace: root.appendingPathComponent("scout").path)
        let skill = root.appendingPathComponent("scout/skills/deploy-check")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: deploy-check\ndescription: Check a deploy.\ncli-tools: [gh, vercel, jq]\n---\nUse vercel and docker.\n"
            .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let index = root.appendingPathComponent("index")
        var policy = ToolPolicy(tools: [ApprovedTool(id: ApprovedTool.catalogID("gh"), name: "gh")])
        policy.addDestination("sshwork")
        try policy.save(in: index)

        let app = AppModel(store: Store(root: index), settings: settings, openRouterKey: { nil })
        app.bots = [scout]
        app.destination = .skills
        app.tools.locate = { _ in
            (["gh": [ToolLocation(path: "/stand-in/gh", realPath: "/stand-in/gh")], "vercel": [ToolLocation(path: "/stand-in/vercel", realPath: "/stand-in/vercel")]], [:])
        }
        let runs = ProbeRuns()
        app.tools.probe = ToolProbe { path, arguments, _ in
            await runs.add(path)
            return ToolProbe.Output(status: 0, output: arguments.contains("auth") ? #"{"hosts":{"github.com":[]}}"# : "gh version 2.1.0 (2026-10-01)")
        }
        let host = NSHostingView<AnyView>(rootView: AnyView(SkillsView().environment(app).defaultAppStorage(defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        /// The table whose columns include `column`, once it has `rows` rows.
        func table(with column: String, rows: Int) async throws -> NSTableView {
            var found: NSTableView?
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(100))
                window.layoutIfNeeded()
                found = libraryTable(in: host, column: column)
                if let found, found.numberOfRows >= rows { break }
            }
            return try #require(found)
        }

        for (width, appearance) in [(1300.0, NSAppearance.Name.aqua), (640, .darkAqua), (1300, .darkAqua), (640, .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: 900))
            let wide = width >= 720

            app.skillsTab = .skills
            let skills = try await table(with: "Bots", rows: 1)
            #expect(skills.numberOfRows == 1)
            #expect(skills.tableColumns.filter { !$0.isHidden }.map(\.title) == ["Skill", "Bots", "Uses"] + (wide ? ["Files"] : []), "\(width)")
            let tabs = try #require(segmented(in: host).first)
            #expect((0..<tabs.segmentCount).map { tabs.label(forSegment: $0) } == ["Skills 1", "Tools 3"])

            app.skillsTab = .tools
            // Three group headings and their rows: gh, sshwork, and the helpers.
            let tools = try await table(with: "On", rows: 6)
            #expect(tools.numberOfRows == 6)
            #expect(tools.tableColumns.filter { !$0.isHidden }.map(\.title) == ["Tool", "Status"] + (wide ? ["Used by"] : []) + ["Bots", "On"], "\(width)")
            #expect(tools.bounds.width <= (tools.enclosingScrollView?.contentView.bounds.width ?? 0) + 1)

            // Selecting gh opens its sidebar beside a narrower table, where there is room for both;
            // closing it deselects.
            let fullWidth = tools.bounds.width
            app.toolSelection = ApprovedTool.catalogID("gh")
            try await Task.sleep(for: .milliseconds(600))
            window.layoutIfNeeded()
            let selected = try await table(with: "On", rows: 6)
            #expect(selected.selectedRow == 1)
            if wide { #expect(selected.bounds.width < fullWidth - 200, "\(width)") }
            app.toolSelection = nil
            try await Task.sleep(for: .milliseconds(400))
        }

        // A declared tool that isn't approved opens Add Tools; one that is opens its row; a tool's
        // skill opens the skill.
        app.showTool(declared: "vercel")
        #expect(app.skillsTab == .tools && app.addingTools && app.toolSelection == nil)
        app.addingTools = false
        app.showTool(declared: "gh")
        #expect(app.toolSelection == ApprovedTool.catalogID("gh"))
        let entry = try #require(app.skillEntries().first)
        app.showSkill(entry.id)
        #expect(app.skillsTab == .skills && app.skillSelection == entry.id)

        // Only the approved catalog tool was run, and the page approved and enforced nothing.
        #expect(Set(await runs.paths) == ["/stand-in/gh"])
        #expect(app.tools.policy.tools.map(\.id) == [ApprovedTool.catalogID("gh")])
        #expect(!app.tools.policy.isEnforced)
        #expect(app.tools.inventory(declarations: [("deploy-check", entry.skill.usedTools(in: app.tools.inventory()))]).candidates().open.map(\.name) == ["vercel"])
    }

    @Test func inferredSkillToolsApproveInlineAndListTheirActiveBots() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inferred-tools-\(UUID().uuidString)")
        let domain = "BotChu.InferredToolsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("bots").path
        let analyst = Bot(name: "Data Analyst", emoji: "📊", accountID: "claude-dev", workspace: root.appendingPathComponent("analyst").path)
        let turtle = Bot(name: "Hedge Fund Turtle", emoji: "🐢", accountID: "claude-dev", workspace: root.appendingPathComponent("turtle").path)
        let app = AppModel(store: Store(root: root.appendingPathComponent("index")), settings: settings, openRouterKey: { nil })
        app.bots = [analyst, turtle]
        let source = "---\nname: kalshi-cli\ndescription: Inspect markets.\n---\n```sh\nkalshi markets\n```\n"
        for (bot, slug, text) in [(analyst, "kalshi-cli", source), (turtle, "kalshi-backtest", "Use `~/.local/bin/kalshi`.")] {
            let directory = Skills.folder(of: bot).appendingPathComponent(slug)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: directory.appendingPathComponent(Skills.fileName), atomically: true, encoding: .utf8)
        }
        app.tools.locate = { commands in
            #expect(commands.contains("kalshi") && commands.contains("~/.local/bin/kalshi"))
            return ([:], ["kalshi": ToolLocation(path: "/stand-in/kalshi", realPath: "/stand-in/kalshi")])
        }
        app.tools.probe = ToolProbe { _, _, _ in
            Issue.record("Approving a custom tool must not run it")
            return ToolProbe.Output(status: 1, output: "")
        }
        let entries = app.skillEntries()
        await app.tools.refresh(declaring: entries.flatMap { $0.skill.toolCommands })
        let declarations = entries.map { (skill: $0.id, tools: $0.skill.usedTools(in: app.tools.inventory())) }
        let inventory = app.tools.inventory(declarations: declarations)
        #expect(declarations.map(\.tools) == [["kalshi"], ["kalshi"]])
        #expect(inventory.dependency("kalshi") == .notApproved)
        #expect(app.tools.policy.tools.isEmpty)

        // Click the actual sidebar row's inline button at its trailing edge, without opening Add Tools.
        let host = NSHostingView(rootView: SkillToolRow(name: "kalshi", inventory: inventory, remove: {})
            .environment(app).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let point = host.convert(NSPoint(x: host.bounds.maxX - 35, y: host.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        let approved = try #require(app.tools.policy.approved(declared: "kalshi"))
        let saved = try ToolPolicy.load(from: root.appendingPathComponent("index"))
        #expect(saved.approved(approved.id)?.enabled == true)
        #expect(!app.addingTools && !app.tools.policy.isEnforced)
        let rows = ToolRow.groups(board: app.tools, inventory: app.tools.inventory(declarations: declarations), matching: "kalshi").flatMap(\.rows)
        let row = try #require(rows.first)
        #expect(row.skills == entries.map(\.id))
        #expect(SkillBots.users(of: row.skills, entries: entries, bots: app.bots).map(\.name) == ["Data Analyst", "Hedge Fund Turtle"])
        let file = Skills.folder(of: analyst).appendingPathComponent("kalshi-cli/SKILL.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == source)

        // Shared skills count only while on, and a private skill with the same slug replaces one.
        let shared = Skill(slug: "kalshi-cli", text: source, scope: .shared, url: root.appendingPathComponent("shared/SKILL.md"))
        let sharedEntries = entries + [SkillEntry(skill: shared, bot: nil)]
        #expect(SkillBots.users(of: [shared.id], entries: sharedEntries, bots: app.bots).map(\.id) == [turtle.id])
        var disabled = turtle
        disabled.setSharedSkill(shared.slug, enabled: false)
        #expect(SkillBots.users(of: [shared.id], entries: sharedEntries, bots: [analyst, disabled]).isEmpty)
        // Disabled shared skills do not disable a bot's private skill; multiple using skills deduplicate the bot.
        #expect(SkillBots.users(of: row.skills + [shared.id], entries: sharedEntries, bots: [analyst, disabled]).map(\.id) == [analyst.id, turtle.id])
    }

    private func libraryTable(in view: NSView, column: String) -> NSTableView? {
        (view as? NSTableView).flatMap { $0.tableColumns.contains { $0.title == column } ? $0 : nil }
            ?? view.subviews.lazy.compactMap { self.libraryTable(in: $0, column: column) }.first
    }

    private func segmented(in view: NSView) -> [NSSegmentedControl] {
        ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap(segmented)
    }
}

/// The paths a test's stand-in probe ran.
private actor ProbeRuns {
    private(set) var paths: [String] = []
    func add(_ path: String) { paths.append(path) }
}
