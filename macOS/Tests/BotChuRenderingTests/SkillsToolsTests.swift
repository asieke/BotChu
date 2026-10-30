import AppKit
import SwiftUI
import Vision
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
            return Shell.Result(status: 0, output: arguments.contains("auth") ? #"{"hosts":{"github.com":[]}}"# : "gh version 2.1.0 (2026-10-01)")
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
            let skillsAdd = try #require(skillViews(NSPopUpButton.self, in: host).first)
            #expect(skillViews(NSPopUpButton.self, in: host).count == 1)
            let skillsAddFrame = host.convert(skillsAdd.bounds, from: skillsAdd)
            #expect(!skillViews(NSButton.self, in: host).contains { ["New Skill", "Add Tools…"].contains($0.title) })

            app.skillsTab = .tools
            // Three group headings and their rows: gh, sshwork, and the helpers.
            let tools = try await table(with: "On", rows: 6)
            #expect(tools.numberOfRows == 6)
            #expect(tools.tableColumns.filter { !$0.isHidden }.map(\.title) == ["Tool", "Status"] + (wide ? ["Used by"] : []) + ["Bots", "On"], "\(width)")
            #expect(tools.bounds.width <= (tools.enclosingScrollView?.contentView.bounds.width ?? 0) + 1)
            let toolsAdd = try #require(skillViews(NSPopUpButton.self, in: host).first)
            #expect(skillViews(NSPopUpButton.self, in: host).count == 1)
            let toolsAddFrame = host.convert(toolsAdd.bounds, from: toolsAdd)
            #expect(abs(toolsAddFrame.midX - skillsAddFrame.midX) < 1)
            #expect(abs(toolsAddFrame.midY - skillsAddFrame.midY) < 1)

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

        // Materialize the heading's shared actions as a context menu: native popup tracking stops
        // SwiftPM's event loop. Both tabs use these exact items, including their candidates badge.
        var newSkill = false, newDestination = false
        let menuHost = NSHostingView(rootView: Color.clear.frame(width: 100, height: 100).contentShape(Rectangle())
            .contextMenu { SkillsAddMenuItems(candidates: 1, newSkill: { newSkill = true }, addDestination: { newDestination = true }) }
            .environment(app))
        let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        menuWindow.isReleasedWhenClosed = false
        menuWindow.contentView = menuHost
        menuWindow.makeKeyAndOrderFront(nil)
        defer { menuWindow.contentView = nil; menuWindow.close() }
        try await Task.sleep(for: .milliseconds(250))

        // Both tabs open the existing approval sheet, with Choose Executable kept inside it.
        app.skillSelection = nil
        for tab in [SkillsTab.skills, .tools] {
            app.skillsTab = tab
            try await Task.sleep(for: .milliseconds(250))
            let menu = try skillMenu(in: menuHost)
            #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["New Skill…", "Approve Tools…", "Add SSH Destination…", "Shared Folder"])
            #expect(menu.item(withTitle: "Approve Tools…")?.badge?.stringValue == "1")
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "New Skill…"))
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Add SSH Destination…"))
            #expect(newSkill && newDestination)
            newSkill = false; newDestination = false
            menu.performActionForItem(at: menu.indexOfItem(withTitle: "Approve Tools…"))
            try await Task.sleep(for: .milliseconds(250))
            let sheet = try #require(window.attachedSheet)
            let content = try #require(sheet.contentView)
            #expect(content.bounds.width == 720 && libraryTable(in: content, column: "Tool") != nil)
            skillKey("\u{1B}", code: 53, in: sheet)
            try await Task.sleep(for: .milliseconds(250))
            #expect(!app.addingTools && window.attachedSheet == nil)
        }

        // Add SSH Destination opens the alias form directly, then selects the new Tools row.
        app.skillsTab = .skills
        host.rootView = AnyView(SkillTestSheet(content: AddSSHDestinationSheet()).environment(app))
        try await Task.sleep(for: .milliseconds(250))
        let sheet = try #require(window.attachedSheet)
        let content = try #require(sheet.contentView)
        #expect(content.bounds.width == 320 && libraryTable(in: content, column: "Tool") == nil)
        let alias = try #require(skillViews(NSTextField.self, in: content).first { $0.isEditable })
        alias.stringValue = "sshresearch"
        alias.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: alias))
        try await Task.sleep(for: .milliseconds(100))
        try clickSkillCreate(in: sheet)
        try await Task.sleep(for: .milliseconds(250))
        let destination = try #require(app.tools.policy.destinations.first { $0.alias == "sshresearch" })
        #expect(window.attachedSheet == nil && app.skillsTab == .tools && app.toolSelection == ToolRow.sshID(destination))
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
            return Shell.Result(status: 1, output: "")
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

    /// New Skill sends through the real Home queue, on a stand-in command that cannot write skills.
    /// The actual sheet enforces its required fields and excludes remote bots, even for shared skills.
    @Test func newSkillAsksTheChosenBotsHomeToWriteThePrivateOrSharedFile() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-new-skill-\(UUID().uuidString)")
        let domain = "BotChu.NewSkillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        let settings = AppSettings(defaults: defaults)
        settings.botsRoot = root.appendingPathComponent("BOTS").path
        settings.commands["codex-dev"] = "/usr/bin/true"
        var analyst = Bot(name: "Data Analyst", emoji: "📊", accountID: "codex-dev", workspace: root.appendingPathComponent("BOTS/data-analyst").path)
        analyst.role = .specialist
        var remote = Bot(name: "Remote Bot", workspace: root.appendingPathComponent("remote").path)
        remote.kind = .remoteQueue
        let home = BotHome(workspace: analyst.workspace)
        try home.save(analyst)
        let app = AppModel(store: Store(root: root.appendingPathComponent("index")), settings: settings,
                           usage: UsageCache { _, _ in throw UsageFailure("No allowance in tests") }, openRouterKey: { nil })
        app.bots = [analyst, remote]
        app.tools.locate = { _ in ([:], [:]) }
        let target = ChatTarget.home(analyst.id)
        defer { app.stopAll() }
        let host = NSHostingView(rootView: AnyView(Color.clear))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }

        #expect(app.skillWriters.map(\.id) == [analyst.id], "Local specialists can write; remote bots cannot")
        app.destination = .skills
        host.rootView = AnyView(SkillTestSheet(content: NewSkillSheet()).environment(app))
        try await Task.sleep(for: .milliseconds(300))
        let unchosen = try #require(window.attachedSheet)
        let unchosenContent = try #require(unchosen.contentView)
        let unchosenName = try #require(skillViews(NSTextField.self, in: unchosenContent).first { $0.isEditable })
        unchosenName.stringValue = "Kalshi markets"
        unchosenName.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: unchosenName))
        try await Task.sleep(for: .milliseconds(100))
        try clickSkillCreate(in: unchosen)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.attachedSheet != nil && app.destination == .skills && app.thread(target).isEmpty, "A name alone is not enough")
        skillKey("\u{1B}", code: 53, in: unchosen)
        try await Task.sleep(for: .milliseconds(250))

        for shared in [false, true] {
            app.destination = .skills
            app.skillsTab = shared ? .tools : .skills
            // A remembered task must be replaced by Home when Create is pressed.
            app.openTask[analyst.id] = UUID()
            host.rootView = AnyView(SkillTestSheet(content: NewSkillSheet(botID: analyst.id)).environment(app).defaultAppStorage(defaults).id(shared))
            try await Task.sleep(for: .milliseconds(300))
            let sheet = try #require(window.attachedSheet)
            let content = try #require(sheet.contentView)
            let labels = try await skillText(in: content)
            for label in ["Name", "What it does", "Bot", "Share with every bot", "File", "Data Analyst"] {
                #expect(labels.contains { $0.contains(label) }, "\(label) in \(labels)")
            }
            try clickSkillCreate(in: sheet)
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.attachedSheet != nil && app.destination == .skills, "A bot alone is not enough")
            let name = try #require(skillViews(NSTextField.self, in: content).first { $0.isEditable })
            name.stringValue = " \n"
            name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
            try await Task.sleep(for: .milliseconds(100))
            try clickSkillCreate(in: sheet)
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.attachedSheet != nil && app.destination == .skills, "A bot alone is not enough")
            name.stringValue = "Kalshi markets"
            name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
            let description = try #require(skillViews(NSTextField.self, in: content).filter { $0.isEditable }.dropFirst().first)
            description.stringValue = "Inspect markets."
            description.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: description))
            if shared {
                let toggle = try #require(skillViews(NSSwitch.self, in: content).first)
                toggle.state = .on
                if let action = toggle.action { NSApp.sendAction(action, to: toggle.target, from: toggle) }
            }
            try await Task.sleep(for: .milliseconds(100))
            try clickSkillCreate(in: sheet)
            for _ in 0..<200 {
                if window.attachedSheet == nil, !app.isRunning(target), app.thread(target).filter({ $0.role == .user }).count == (shared ? 2 : 1) { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(window.attachedSheet == nil)
            #expect(app.destination == nil && app.selection == analyst.id && app.openTask[analyst.id] == nil)
            #expect(app.tab(of: analyst.id) == target)
            let message = try #require(app.thread(target).last { $0.role == .user })
            let folder = shared ? app.sharedSkillsFolder : Skills.folder(of: analyst)
            #expect(message.text.contains(folder.path + "/kalshi-markets/SKILL.md"))
            #expect(message.text.contains("What it does: Inspect markets."))
            #expect(message.text.contains("name: kalshi-markets") && message.text.contains("description") && message.text.contains("steps"))
            #expect(app.documentEditor == nil)
            #expect(!FileManager.default.fileExists(atPath: Skills.folder(of: analyst).path))
            #expect(!FileManager.default.fileExists(atPath: app.sharedSkillsFolder.path))
            await app.storage.settle()
        }
        #expect(!app.askToWriteSkill(name: "Remote", description: "", for: remote.id, shared: true))
        #expect(!app.askToWriteSkill(name: " \n", description: "", for: analyst.id, shared: false))
        #expect(!app.askToWriteSkill(name: "Missing", description: "", for: UUID(), shared: false))
    }

    private func skillMenu(in host: NSView) throws -> NSMenu {
        let point = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        let location = host.convert(point, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: host.window?.windowNumber ?? 0, context: nil,
                                                   eventNumber: 0, clickCount: 1, pressure: 1))
        var view = host.hitTest(point)
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        throw CocoaError(.coderValueNotFound)
    }

    private func skillViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { skillViews(type, in: $0) }
    }

    /// SwiftUI draws sheet buttons itself, so use their position in the trailing footer.
    private func clickSkillCreate(in window: NSWindow) throws {
        let content = try #require(window.contentView)
        try clickSkill(at: NSPoint(x: content.bounds.maxX - 50, y: content.isFlipped ? content.bounds.maxY - 32 : 32), in: content)
    }

    private func clickSkill(at point: NSPoint, in content: NSView) throws {
        let window = try #require(content.window)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: content.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func skillKey(_ text: String, code: UInt16, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: text,
                                     charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    private func skillText(in view: NSView) async throws -> [String] {
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let pixels = try #require(image.cgImage)
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: pixels).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    private func segmented(in view: NSView) -> [NSSegmentedControl] {
        ((view as? NSSegmentedControl).map { [$0] } ?? []) + view.subviews.flatMap(segmented)
    }
}

private struct SkillTestSheet<Content: View>: View {
    let content: Content
    @State private var presented = true
    var body: some View { Color.clear.sheet(isPresented: $presented) { content } }
}

/// The paths a test's stand-in probe ran.
private actor ProbeRuns {
    private(set) var paths: [String] = []
    func add(_ path: String) { paths.append(path) }
}
