import SwiftUI
import BotChuCore

/// Skills & Tools (#246): the skills, and the command-line tools agents have on This Mac, as two
/// tabs of native tables with the selection in a sidebar, as Providers has. A skill links to the
/// tools its code uses (overridden by `cli-tools:`), and each tool to the skills that use it.
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [SkillEntry] = []
    @State private var skillQuery = ""
    @State private var toolQuery = ""
    @State private var creating = false
    @State private var addingDestination = false
    @State private var pendingDelete: SkillEntry?
    @State private var error: String?
    @State private var sortOrder = [KeyPathComparator(\SkillEntry.skill.name, comparator: .localizedStandard)]
    @State private var width = 1000.0

    private var matches: [SkillEntry] {
        entries.filter { entry in
            skillQuery.isEmpty || [entry.skill.name, entry.skill.description, entry.bot?.name ?? "", entry.skill.usedTools(in: model.tools.inventory()).joined(separator: " ")]
                .joined(separator: " ").localizedCaseInsensitiveContains(skillQuery)
        }
    }

    private var declarations: [(skill: String, tools: [String])] { entries.map { ($0.id, $0.skill.usedTools(in: model.tools.inventory())) } }
    private var toolCommands: [String] { Array(Set(entries.flatMap { $0.skill.toolCommands })).sorted() }
    private var skillNames: [String: String] { Dictionary(entries.map { ($0.id, $0.skill.name) }, uniquingKeysWith: { first, _ in first }) }

    var body: some View {
        let inventory = model.tools.inventory(declarations: declarations)
        let candidates = inventory.candidates()
        let toolGroups = ToolRow.groups(board: model.tools, inventory: inventory, matching: toolQuery)
        let toolCount = model.tools.policy.tools.count + model.tools.policy.destinations.count + 1
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Skills & Tools") {
                if model.skillsTab == .tools {
                    ToolsHeadingActions(inventory: inventory, refresh: { Task { await refreshTools(force: true) } })
                }
                Menu {
                    SkillsAddMenuItems(candidates: candidates.open.count, newSkill: { creating = true },
                                       addDestination: { addingDestination = true })
                } label: {
                    Label("Add a skill or tool", systemImage: "plus").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("skills-tools-add")
            }
            HStack(spacing: 12) {
                Picker("Show", selection: Binding(get: { model.skillsTab }, set: { model.skillsTab = $0 })) {
                    Text("Skills \(entries.count)").tag(SkillsTab.skills)
                    Text("Tools \(toolCount)").tag(SkillsTab.tools)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("skills-tabs")
                if model.skillsTab == .skills {
                    LibrarySearch(text: $skillQuery, prompt: "Search skills")
                } else {
                    LibrarySearch(text: $toolQuery, prompt: "Search tools")
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
            ForEach([error, model.tools.unreadable, model.tools.saveFailure].compactMap { $0 }, id: \.self) { message in
                Text(message).font(.caption).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if model.skillsTab == .skills {
                if matches.isEmpty {
                    LibraryEmpty(title: entries.isEmpty ? "No skills yet" : "No matching skills",
                                 subtitle: entries.isEmpty
                                     ? "Make one with New Skill, or add a folder with a SKILL.md to the shared folder. Bots see each skill's name and description, and read the rest when it fits their work."
                                     : "Try a skill's name, description, bot or tool.",
                                 symbol: "wand.and.stars")
                } else {
                    SkillsTable(entries: matches.sorted(using: sortOrder), inventory: inventory, sortOrder: $sortOrder, wide: width >= 720,
                                delete: { pendingDelete = $0 })
                }
            } else if toolGroups.isEmpty {
                LibraryEmpty(title: "No matching tools", subtitle: "Try a command or what it is.", symbol: "terminal")
            } else {
                ToolsTable(groups: toolGroups, skillNames: skillNames, entries: entries, wide: width >= 720)
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width = $0 }
        .background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Skills & Tools")
        // Read again when the editor opens or closes, and when bots change, so saved edits show.
        .task(id: model.documentEditor?.id) { reload() }
        .onChange(of: model.bots) { reload() }
        // Where tools are, looked for (never run) when the page opens and skills change; then the
        // approved catalog tools' checks, when due.
        .task(id: toolCommands) { await refreshTools(force: false) }
        .inspector(isPresented: inspectorShown) {
            Group {
                if model.skillsTab == .skills, let entry = entries.first(where: { $0.id == model.skillSelection }) {
                    SkillInspector(entry: entry, inventory: inventory, delete: { pendingDelete = entry }, changed: reload)
                } else if model.skillsTab == .tools, let row = toolGroups.flatMap(\.rows).first(where: { $0.id == model.toolSelection })
                            ?? ToolRow.groups(board: model.tools, inventory: inventory, matching: "").flatMap(\.rows).first(where: { $0.id == model.toolSelection }) {
                    ToolInspector(row: row, skillNames: skillNames).id(row.id)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 320, max: 480)
        }
        .sheet(isPresented: $creating) {
            NewSkillSheet().environment(model)
        }
        .sheet(isPresented: Binding(get: { model.addingTools }, set: { model.addingTools = $0 })) {
            AddToolsSheet(candidates: candidates.open, ignored: candidates.ignored, skillNames: skillNames).environment(model)
        }
        .sheet(isPresented: $addingDestination) {
            AddSSHDestinationSheet().environment(model)
        }
        .confirmationDialog("Delete \(pendingDelete?.skill.name ?? "skill")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button("Move to Trash", role: .destructive) {
                do { try model.deleteSkill(entry); error = nil } catch { self.error = "Couldn't delete \(entry.skill.name): \(error.localizedDescription)" }
                if model.skillSelection == entry.id { model.skillSelection = nil }
                reload()
            }
        } message: { entry in
            Text(entry.bot == nil ? "Its folder goes to the Trash, and no bot is told about it any more." : "Its folder goes to the Trash, and \(entry.bot?.name ?? "its bot") is no longer told about it.")
        }
    }

    /// The selected skill's or tool's sidebar; closing it deselects.
    private var inspectorShown: Binding<Bool> {
        Binding(get: { model.skillsTab == .skills ? model.skillSelection != nil : model.toolSelection != nil },
                set: { if !$0 { if model.skillsTab == .skills { model.skillSelection = nil } else { model.toolSelection = nil } } })
    }

    private func reload() { entries = model.skillEntries() }

    private func refreshTools(force: Bool) async {
        await model.tools.refresh(declaring: toolCommands)
        await model.tools.checkAll(force: force)
    }
}

/// The heading's additions are the same on either tab.
struct SkillsAddMenuItems: View {
    @Environment(AppModel.self) private var model
    let candidates: Int
    let newSkill: () -> Void
    let addDestination: () -> Void

    var body: some View {
        Button("New Skill…", systemImage: "wand.and.stars", action: newSkill)
        Button("Approve Tools…", systemImage: "terminal") { model.addingTools = true }
            .badge(candidates)
        Button("Add SSH Destination…", systemImage: "network", action: addDestination)
        Divider()
        Button("Shared Folder", systemImage: "folder") { model.revealSkill(nil) }
    }
}

/// The skills, one row each: its name over its description, which bots have it, the tools it
/// uses and how each stands, and its files. Double-click edits; Bots and Delete are in its menu
/// and sidebar, as the gallery's cards had them.
private struct SkillsTable: View {
    @Environment(AppModel.self) private var model
    let entries: [SkillEntry]
    let inventory: ToolInventory
    @Binding var sortOrder: [KeyPathComparator<SkillEntry>]
    let wide: Bool
    let delete: (SkillEntry) -> Void

    var body: some View {
        let selection = Binding<String?>(get: { model.skillSelection }, set: { model.skillSelection = $0 })
        var visibility = TableColumnCustomization<SkillEntry>()
        visibility[visibility: "files"] = wide ? .visible : .hidden
        return Table(entries, selection: selection, sortOrder: $sortOrder, columnCustomization: .constant(visibility)) {
            TableColumn("Skill", value: \SkillEntry.skill.name, comparator: .localizedStandard) { (entry: SkillEntry) in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.skill.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(entry.skill.description.isEmpty ? "No description" : entry.skill.description)
                        .font(.system(size: 11)).foregroundStyle(entry.skill.description.isEmpty ? .tertiary : .secondary).lineLimit(1)
                }
                .frame(minHeight: 36, alignment: .leading)
                .padding(.vertical, 6)
                .help(entry.skill.description)
                .accessibilityIdentifier("skill-\(entry.skill.id)")
            }
            .width(min: 180, ideal: 320)
            TableColumn("Bots") { (entry: SkillEntry) in SkillBotsCell(entry: entry).environment(model) }
                .width(min: 90, ideal: 140)
            TableColumn("Uses") { (entry: SkillEntry) in
                SkillToolChips(tools: entry.skill.usedTools(in: inventory), inventory: inventory).environment(model)
            }
            .width(min: 100, ideal: 180)
            TableColumn("Files") { (entry: SkillEntry) in
                Text("\(entry.skill.resourceCount + 1)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(44)
            .customizationID("files")
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .id(wide)
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) { SkillMenuItems(entry: entry, delete: { delete(entry) }) }
        } primaryAction: { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) { model.editSkill(entry) }
        }
    }
}

/// Which bots have a skill: a bot's own, or how many keep a shared one on.
private struct SkillBotsCell: View {
    @Environment(AppModel.self) private var model
    let entry: SkillEntry

    var body: some View {
        HStack(spacing: 6) {
            if let bot = entry.bot { BotAvatar(bot: bot, size: 18) }
            Text(SkillBots.scope(of: entry, in: model)).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

enum SkillBots {
    /// Bots with at least one of these skills active. Use the same resolution as sessions:
    /// private skills replace shared skills with the same slug; remote queues have no local skills.
    static func users(of ids: [String], entries: [SkillEntry], bots: [Bot]) -> [Bot] {
        let ids = Set(ids)
        let shared = entries.filter { $0.bot == nil }.map(\.skill)
        let own = Dictionary(grouping: entries.filter { $0.bot != nil }, by: { $0.bot!.id })
        return bots.filter { bot in
            !bot.isRemoteQueue && Skills.active(for: bot, shared: shared, own: (own[bot.id] ?? []).map(\.skill))
                .contains { ids.contains($0.id) }
        }
    }

    /// The bots that keep a shared skill on.
    @MainActor static func users(of skill: Skill, in model: AppModel) -> [Bot] {
        model.bots.filter { !$0.isRemoteQueue && $0.usesSharedSkill(skill.slug) }
    }

    @MainActor static func scope(of entry: SkillEntry, in model: AppModel) -> String {
        if let bot = entry.bot { return "\(bot.name)’s own" }
        let all = model.bots.filter { !$0.isRemoteQueue }.count
        let users = users(of: entry.skill, in: model).count
        return users == all ? "Every bot" : "\(users) of \(all)"
    }
}

/// A skill's used tools as chips that say how each stands; each opens its tool, or Add Tools.
private struct SkillToolChips: View {
    @Environment(AppModel.self) private var model
    let tools: [String]
    let inventory: ToolInventory

    var body: some View {
        HStack(spacing: 4) {
            if tools.isEmpty { Text("—").foregroundStyle(.tertiary) }
            ForEach(tools.prefix(3), id: \.self) { name in
                let dependency = inventory.dependency(name)
                Button { model.showTool(declared: name) } label: { ToolChip(name: name, dependency: dependency) }
                    .buttonStyle(.plain)
                    .help([name, ToolChip.label(dependency)].compactMap { $0 }.joined(separator: " · "))
            }
            if tools.count > 3 {
                Text("+\(tools.count - 3)").font(.system(size: 11)).foregroundStyle(.secondary).help(tools.dropFirst(3).joined(separator: ", "))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

/// A skill's menu, from a right click, as its card had.
private struct SkillMenuItems: View {
    @Environment(AppModel.self) private var model
    let entry: SkillEntry
    let delete: () -> Void

    var body: some View {
        Button("Edit SKILL.md…") { model.editSkill(entry) }
        if entry.bot == nil { SkillBotsMenu(skill: entry.skill) }
        Button("Show in Finder") { model.revealSkill(entry) }
        Divider()
        Button("Delete…", role: .destructive, action: delete)
    }
}

/// Which bots keep a shared skill on.
private struct SkillBotsMenu: View {
    @Environment(AppModel.self) private var model
    let skill: Skill

    var body: some View {
        Menu("Bots") {
            ForEach(model.bots.filter { !$0.isRemoteQueue }) { bot in
                Toggle(isOn: Binding(get: { bot.usesSharedSkill(skill.slug) },
                                     set: { model.setSharedSkill(skill.slug, enabled: $0, for: bot.id) })) {
                    Text("\(bot.emoji) \(bot.name)")
                }
            }
        }
    }
}

/// The selected skill in the sidebar: its description, bots, used tools and how each stands,
/// and its files, with Edit and the rest of its card's actions.
private struct SkillInspector: View {
    @Environment(AppModel.self) private var model
    let entry: SkillEntry
    let inventory: ToolInventory
    let delete: () -> Void
    /// After its declared tools were saved.
    let changed: () -> Void
    @State private var declaring = ""
    @State private var problem: String?

    private var skill: Skill { entry.skill }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let bot = entry.bot {
                    BotAvatar(bot: bot, size: 34)
                } else {
                    Image(systemName: "folder").font(.system(size: 15)).frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.cardEdge))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(entry.bot.map { "\($0.name)’s own" } ?? "Shared").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: 4)
                Button { model.skillSelection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close skill sidebar")
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 14))
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    InspectorSection("Description", preferenceKey: "skill.description") {
                        InspectorCard(padded: true) {
                            Text(skill.description.isEmpty ? "No description" : skill.description)
                                .font(.system(size: 12))
                                .foregroundStyle(skill.description.isEmpty ? Palette.secondaryText : Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    bots
                    tools
                    InspectorSection("Files", preferenceKey: "skill.files") {
                        InspectorCard {
                            InspectorRow("Folder") {
                                Text("\(Skills.folderName)/\(skill.slug)/").font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Palette.pathText).truncationMode(.middle).help(skill.folder.path)
                            }
                            InspectorRow("Files", value: skill.resourceCount == 0 ? "SKILL.md" : "SKILL.md + \(skill.resourceCount)", last: true)
                        }
                    }
                    VStack(spacing: 8) {
                        Button("Edit…") { model.editSkill(entry) }
                        Button("Show in Finder") { model.revealSkill(entry) }
                        Button(role: .destructive, action: delete) { Text("Delete…").foregroundStyle(GitHubColors.danger) }
                    }
                    .buttonStyle(InspectorButtonStyle(fill: true))
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.text)
        .background(Palette.sidebar)
    }

    @ViewBuilder private var bots: some View {
        if entry.bot == nil {
            let all = model.bots.filter { !$0.isRemoteQueue }
            InspectorSection("Bots", trailing: SkillBots.scope(of: entry, in: model), preferenceKey: "skill.bots") {
                InspectorCard {
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, bot in
                        InspectorRow(bot.name, last: index == all.count - 1) {
                            Toggle(isOn: Binding(get: { bot.usesSharedSkill(skill.slug) },
                                                 set: { model.setSharedSkill(skill.slug, enabled: $0, for: bot.id) })) { EmptyView() }
                                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                .accessibilityLabel("\(skill.name) for \(bot.name)")
                        }
                    }
                }
            }
        }
    }

    private var tools: some View {
        let used = skill.usedTools(in: inventory)
        return InspectorSection("Uses", trailing: used.isEmpty ? nil : "\(used.count)", preferenceKey: "skill.tools") {
            InspectorCard {
                // Each opens its tool, or Add Tools for one not approved, as Providers' agent rows open their agent.
                ForEach(used, id: \.self) { name in
                    SkillToolRow(name: name, inventory: inventory, remove: { setTools(used.filter { $0 != name }) })
                }
                HStack(spacing: 8) {
                    TextField("Declare a tool", text: $declaring, prompt: Text("Declare a tool"))
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .onSubmit(declare)
                    Button { declare() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .disabled(!Skills.isToolName(declaring.trimmingCharacters(in: .whitespaces)))
                        .accessibilityLabel("Declare tool")
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    private func declare() {
        let name = declaring.trimmingCharacters(in: .whitespaces)
        guard Skills.isToolName(name) else { return }
        let used = skill.usedTools(in: inventory)
        if !used.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { setTools(used + [name]) }
        declaring = ""
    }

    /// Writes the skill's `cli-tools:`, leaving the rest of its file as it is.
    private func setTools(_ tools: [String]) {
        do {
            let text = try String(contentsOf: skill.url, encoding: .utf8)
            try Skills.settingDeclaredTools(tools, in: text).write(to: skill.url, atomically: true, encoding: .utf8)
            problem = nil
            changed()
        } catch {
            problem = "Couldn’t save \(Skills.fileName): \(error.localizedDescription)"
        }
    }
}

/// One used tool in a skill's sidebar. Approval is a separate action from opening the tool,
/// and only editing the list writes the skill's explicit override.
struct SkillToolRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let inventory: ToolInventory
    let remove: () -> Void

    var body: some View {
        let dependency = inventory.dependency(name)
        HStack(spacing: 8) {
            Button { model.showTool(declared: name) } label: {
                HStack(spacing: 8) {
                    ToolChip(name: name, dependency: dependency)
                    Spacer(minLength: 4)
                    state(dependency).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let candidate = inventory.candidate(for: name) {
                Button("Approve") { model.tools.approve([candidate]) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("approve-skill-tool-\(name)")
            } else {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondaryText)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        .contextMenu { Button("Remove from Skill", action: remove) }
        .accessibilityIdentifier("skill-tool-\(name)")
    }

    @ViewBuilder private func state(_ dependency: ToolDependency) -> some View {
        switch dependency {
        case .enabled: Label("Enabled", systemImage: "checkmark").foregroundStyle(Palette.secondaryText)
        case .off: Label("Off", systemImage: "nosign").foregroundStyle(Palette.secondaryText)
        case .notApproved: Label("Not approved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
        case .missing: Label("Not installed", systemImage: "questionmark").foregroundStyle(Palette.secondaryText)
        }
    }
}

/// Asks a local bot to write a skill in its Home, without creating a template first.
struct NewSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var botID: UUID?
    @State private var shared = false

    init(botID: UUID? = nil) { _botID = State(initialValue: botID) }

    private var bots: [Bot] { model.skillWriters }
    private var bot: Bot? { bots.first { $0.id == botID } }
    private var file: String {
        let folder = shared ? model.sharedSkillsFolder : bot.map(Skills.folder(of:))
        return folder.map { Skills.file(named: name, in: $0).path } ?? "skills/\(Skills.slug(name))/SKILL.md"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Skill").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("Aside web browsing"))
                TextField("What it does", text: $description, prompt: Text("Browse live sites with the aside CLI…"), axis: .vertical)
                    .lineLimit(2...4)
                Picker("Bot", selection: $botID) {
                    Text("Choose a bot").tag(UUID?.none)
                    ForEach(bots) { bot in Text("\(bot.emoji) \(bot.name)").tag(Optional(bot.id)) }
                }
                Toggle("Share with every bot", isOn: $shared)
                LabeledContent("File") {
                    Text(verbatim: file)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bot == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func create() {
        if let bot, model.askToWriteSkill(name: name, description: description, for: bot.id, shared: shared) {
            dismiss()
        }
    }
}
