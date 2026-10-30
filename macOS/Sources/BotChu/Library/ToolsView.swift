import AppKit
import SwiftUI
import BotChuCore

/// A row of Tools (#246): an approved tool, an SSH destination, or BotChu's own helpers. Its id is
/// the approved tool's, `ssh:<uuid>` for a destination, or `botchu`.
struct ToolRow: Identifiable, Hashable {
    enum Kind: Hashable {
        case tool(ApprovedTool)
        case destination(SSHDestination)
        case botchu
    }

    enum Status: Hashable {
        case version(String?)
        /// A reading from before a check that failed.
        case stale(String?, Date)
        case checking
        case notChecked
        case failed
        case notInstalled
        /// An executable the owner chose, which BotChu never runs: whether it is still there.
        case present(Bool)
        case target(String?)
        case builtIn
    }

    let id: String
    let kind: Kind
    let name: String
    let title: String
    let status: Status
    /// The skills that use it, by id.
    let skills: [String]
    let enabled: Bool
    /// Whether a turn started now blocks it.
    let blocked: Bool

    static func sshID(_ destination: SSHDestination) -> String { "ssh:" + destination.id.uuidString }

    /// The commands of BotChu's own helpers, which every turn has.
    static let helpers = SubagentHookInstaller.commands

    @MainActor static func groups(board: ToolsBoard, inventory: ToolInventory, matching query: String) -> [(title: String, rows: [ToolRow])] {
        let tools = board.policy.tools.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { tool in
            ToolRow(id: tool.id, kind: .tool(tool), name: tool.name, title: tool.catalog?.title ?? tool.path ?? "",
                    status: status(of: tool, board: board), skills: inventory.skills(declaring: tool), enabled: tool.enabled,
                    blocked: inventory.blocks(tool))
        }
        let destinations = board.policy.destinations.map { destination in
            ToolRow(id: sshID(destination), kind: .destination(destination), name: destination.alias, title: "SSH destination",
                    status: .target(destination.target), skills: [], enabled: destination.included, blocked: false)
        }
        let helpers = [ToolRow(id: "botchu", kind: .botchu, name: "botchu-*", title: "subagent · task · inbox · message · secret · models",
                               status: .builtIn, skills: [], enabled: true, blocked: false)]
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (ToolRow) -> Bool = { query.isEmpty || "\($0.name) \($0.title)".localizedCaseInsensitiveContains(query) }
        return [("Command line", tools), ("SSH destinations", destinations), ("BotChu", helpers)]
            .map { ($0.0, $0.1.filter(matches)) }
            .filter { !$0.1.isEmpty || ($0.0 == "SSH destinations" && query.isEmpty) }
    }

    @MainActor static func status(of tool: ApprovedTool, board: ToolsBoard) -> Status {
        guard let catalog = tool.catalog else {
            return .present(tool.path.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false)
        }
        if board.checking.contains(tool.id) { return .checking }
        if board.locatedAt != nil, board.catalogLocations[catalog.id]?.isEmpty ?? true { return .notInstalled }
        guard let check = board.checks[tool.id] else { return .notChecked }
        if let reading = check.reading {
            return check.failure == nil ? .version(reading.version) : .stale(reading.version, reading.readAt)
        }
        return check.failure == nil ? .notChecked : .failed
    }
}

/// The Tools tab's table: the approved tools, the SSH destinations and BotChu's helpers, each
/// group under its heading, with what each is, its status, the skills and bots using it and its
/// global switch. Narrow, Used by goes first; Bots is read-only.
struct ToolsTable: View {
    @Environment(AppModel.self) private var model
    let groups: [(title: String, rows: [ToolRow])]
    let skillNames: [String: String]
    let entries: [SkillEntry]
    let wide: Bool

    var body: some View {
        let selection = Binding<String?>(get: { model.toolSelection }, set: { model.toolSelection = $0 })
        var visibility = TableColumnCustomization<ToolRow>()
        visibility[visibility: "skills"] = wide ? .visible : .hidden
        return Table(of: ToolRow.self, selection: selection, columnCustomization: .constant(visibility)) {
            TableColumn("Tool") { (row: ToolRow) in ToolNameCell(row: row) }
                .width(min: 150, ideal: wide ? 220 : 180)
            TableColumn("Status") { (row: ToolRow) in ToolStatusCell(row: row) }
                .width(min: 110, ideal: wide ? 170 : 130)
            TableColumn("Used by") { (row: ToolRow) in
                SkillChips(ids: row.skills, names: skillNames) { model.showSkill($0) }
            }
            .width(min: 120)
            .customizationID("skills")
            TableColumn("Bots") { (row: ToolRow) in
                let names = SkillBots.users(of: row.skills, entries: entries, bots: model.bots).map(\.name)
                Text(names.isEmpty ? "—" : names.joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(names.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1).help(names.joined(separator: ", "))
            }
            .width(min: 90, ideal: wide ? 150 : 110)
            TableColumn("On") { (row: ToolRow) in ToolSwitch(row: row).environment(model) }
                .width(44)
        } rows: {
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.rows) { TableRow($0) }
                } header: {
                    HStack(spacing: 6) {
                        Text(group.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.text)
                        Text("\(group.rows.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .id(wide)
        .contextMenu(forSelectionType: String.self) { ids in
            if let row = groups.flatMap(\.rows).first(where: { ids.contains($0.id) }) { ToolMenuItems(row: row) }
        }
    }
}

/// The command over what it is, beside its kind's tile, as Providers' names are laid out; dimmed
/// while it is off.
private struct ToolNameCell: View {
    let row: ToolRow

    var body: some View {
        HStack(spacing: 10) {
            ToolTile(kind: row.kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(row.enabled ? Palette.text : Palette.secondaryText)
                Text(row.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(minHeight: 36, alignment: .leading)
        .padding(.vertical, 6)
        .help(row.title.isEmpty ? row.name : "\(row.name) · \(row.title)")
        .accessibilityIdentifier("tools-row-\(row.id)")
    }
}

/// A row's kind as a tile, as Providers shows a profile's logo: a command, an SSH destination, or
/// BotChu's helpers.
struct ToolTile: View {
    let kind: ToolRow.Kind
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Palette.secondaryText)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Palette.cardEdge))
    }

    private var symbol: String {
        switch kind {
        case .tool: "terminal"
        case .destination: "network"
        case .botchu: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// What BotChu last learned about a row.
struct ToolStatusCell: View {
    let row: ToolRow
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 4) {
            if row.blocked {
                Image(systemName: "nosign")
                Text("Blocked")
            } else {
                content
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .foregroundStyle(row.blocked || !row.enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.text))
    }

    @ViewBuilder private var content: some View {
        switch row.status {
        case .version(let version):
            Image(systemName: "checkmark").foregroundStyle(.secondary)
            Text(version ?? "Installed").monospacedDigit()
        case .stale(let version, let date):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warning)
            Text("\(version ?? "Installed") · \(RelativeDate.text(date))").monospacedDigit().foregroundStyle(warning)
        case .checking:
            ProgressView().controlSize(.mini)
            Text("Checking…").foregroundStyle(.secondary)
        case .notChecked: Text("Not checked").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warning)
            Text("Check failed").foregroundStyle(warning)
        case .notInstalled:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warning)
            Text("Not installed").foregroundStyle(warning)
        case .present(let present):
            if present {
                Image(systemName: "checkmark").foregroundStyle(.secondary)
                Text("Installed")
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warning)
                Text("Missing").foregroundStyle(warning)
            }
        case .target(let target):
            Text(target ?? "—").font(.system(size: 12, design: .monospaced)).truncationMode(.middle)
                .foregroundStyle(target == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        case .builtIn:
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("Built in").foregroundStyle(.secondary)
        }
    }

    private var warning: AnyShapeStyle { prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.warning) }
}

/// A row's switch: a tool's Enabled, a destination's place in agents' instructions, and the
/// helpers', always on.
private struct ToolSwitch: View {
    @Environment(AppModel.self) private var model
    let row: ToolRow

    var body: some View {
        Toggle(isOn: Binding(get: { row.enabled }, set: { set($0) })) { EmptyView() }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(row.kind == .botchu)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(help)
            .accessibilityLabel(help)
    }

    private var help: String {
        switch row.kind {
        case .tool: row.name
        case .destination: "\(row.name) in agents’ instructions"
        case .botchu: "BotChu’s helpers are always on"
        }
    }

    private func set(_ on: Bool) {
        switch row.kind {
        case .tool(let tool): model.tools.change { $0.setEnabled(on, for: tool.id) }
        case .destination(var destination):
            destination.included = on
            model.tools.change { $0.update(destination) }
        case .botchu: break
        }
    }
}

/// Skills as chips, the first two then how many more; each opens its skill.
struct SkillChips: View {
    let ids: [String]
    let names: [String: String]
    let open: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            if ids.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            }
            ForEach(ids.prefix(2), id: \.self) { id in
                Button { open(id) } label: { ToolChip(name: names[id] ?? id) }
                    .buttonStyle(.plain)
                    .help("Show \(names[id] ?? id)")
            }
            if ids.count > 2 {
                Text("+\(ids.count - 2)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(ids.dropFirst(2).map { names[$0] ?? $0 }.joined(separator: ", "))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }
}

/// A command or skill's name in a chip: plain, or with the mark of how a dependency stands.
struct ToolChip: View {
    let name: String
    var dependency: ToolDependency = .enabled

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(RoundedRectangle(cornerRadius: 5).fill(dependency == .notApproved ? Palette.warning.opacity(0.1) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: dependency == .off ? [3, 2] : [])))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name)\(Self.label(dependency).map { ", \($0)" } ?? "")")
    }

    private var symbol: String? {
        switch dependency {
        case .enabled: nil
        case .off: "nosign"
        case .notApproved: "exclamationmark.triangle.fill"
        case .missing: "questionmark"
        }
    }

    private var tint: AnyShapeStyle {
        switch dependency {
        case .enabled: AnyShapeStyle(Palette.text)
        case .notApproved: AnyShapeStyle(Palette.warning)
        case .off, .missing: AnyShapeStyle(Palette.secondaryText)
        }
    }

    private var border: AnyShapeStyle {
        dependency == .notApproved ? AnyShapeStyle(Palette.warning.opacity(0.5)) : AnyShapeStyle(Color.primary.opacity(0.12))
    }

    static func label(_ dependency: ToolDependency) -> String? {
        switch dependency {
        case .enabled: nil
        case .off: "Off"
        case .notApproved: "Not approved"
        case .missing: "Not installed"
        }
    }
}

/// A row's menu, from a right click.
private struct ToolMenuItems: View {
    @Environment(AppModel.self) private var model
    let row: ToolRow

    var body: some View {
        switch row.kind {
        case .tool(let tool):
            Button(tool.enabled ? "Turn Off" : "Turn On") { model.tools.change { $0.setEnabled(!tool.enabled, for: tool.id) } }
            if tool.catalog != nil { Button("Check Again") { Task { await model.tools.check(tool) } } }
            if let path = model.tools.inventory().locations(of: tool).first?.path {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Divider()
            Button("Remove", role: .destructive) { model.removeTool(row) }
        case .destination(var destination):
            Button(destination.included ? "Leave Out of Instructions" : "Include in Instructions") {
                destination.included.toggle()
                model.tools.change { $0.update(destination) }
            }
            Divider()
            Button("Remove", role: .destructive) { model.removeTool(row) }
        case .botchu:
            EmptyView()
        }
    }
}

extension AppModel {
    /// Shows a skill in Skills & Tools' Skills tab.
    func showSkill(_ id: String) {
        skillsTab = .skills
        skillSelection = id
    }

    /// Shows an approved tool in the Tools tab, or Add Tools for one that isn't.
    func showTool(declared name: String) {
        skillsTab = .tools
        if let tool = tools.policy.approved(declared: name) { toolSelection = tool.id } else { addingTools = true }
    }

    /// Removes an approved tool (back among the candidates) or a destination.
    func removeTool(_ row: ToolRow) {
        if toolSelection == row.id { toolSelection = nil }
        switch row.kind {
        case .tool(let tool): tools.change { $0.remove(tool.id) }
        case .destination(let destination): tools.change { $0.removeDestination(destination.id) }
        case .botchu: break
        }
    }
}

/// The Tools tab's heading controls: when This Mac was last looked at, Check Again, whether the
/// policy is enforced. The shared + menu lives in SkillsView.
struct ToolsHeadingActions: View {
    @Environment(AppModel.self) private var model
    let inventory: ToolInventory
    let refresh: () -> Void
    @State private var confirmingEnforce = false

    var body: some View {
        let board = model.tools
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let newest = board.checks.values.map(\.attemptedAt).max() ?? board.locatedAt
            Text(newest.map { "This Mac · checked \(RelativeDate.text($0, now: max(context.date, Date())))" } ?? "This Mac")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        Button(action: refresh) { Label("Check Again", systemImage: "arrow.clockwise") }
            .labelStyle(.iconOnly)
            .help("Look for tools on This Mac and check the approved ones again")
        Toggle(isOn: Binding(get: { board.policy.isEnforced }, set: { on in
            if on { confirmingEnforce = true } else { board.change { $0.enforcedSince = nil } }
        })) {
            Text("Enforce")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help("Block catalog tools that aren’t approved and on, in turns on This Mac")
        .accessibilityIdentifier("tools-enforce")
        .confirmationDialog("Block tools that aren’t on?", isPresented: $confirmingEnforce) {
            Button("Enforce") { board.change { $0.enforcedSince = Date() } }
        } message: {
            Text(Self.enforceMessage(blocked: Self.blockedNames(inventory)))
        }
    }

    /// The installed catalog tools a turn would block once the policy is enforced.
    static func blockedNames(_ inventory: ToolInventory) -> [String] {
        var enforced = inventory.policy
        enforced.enforcedSince = enforced.enforcedSince ?? Date()
        let would = ToolInventory(policy: enforced, catalogLocations: inventory.catalogLocations)
        let paths = Set(would.blockedLocations().map(\.path))
        return ToolCatalog.tools.filter { tool in (inventory.catalogLocations[tool.id] ?? []).contains { paths.contains($0.path) } }.map(\.id)
            + enforced.tools.filter { $0.catalogID == nil && !$0.enabled }.map(\.name)
    }

    static func enforceMessage(blocked: [String]) -> String {
        let list = blocked.isEmpty ? "No installed tool is blocked." : "Blocked from the next turn on This Mac: \(blocked.joined(separator: ", "))."
        return list + " SSH, git and commands outside the catalog stay as they are; turns on hosts aren’t affected. Muse turns can’t start on This Mac while it’s on."
    }
}

/// The selected row in the sidebar: a tool's switch, where it is and what it reported, a
/// destination's fields, or the helpers.
struct ToolInspector: View {
    @Environment(AppModel.self) private var model
    let row: ToolRow
    let skillNames: [String: String]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ToolTile(kind: row.kind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(row.title).font(.system(size: 11)).foregroundStyle(Palette.secondaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button { model.toolSelection = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close tool sidebar")
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 14))
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch row.kind {
                    case .tool(let tool): ToolDetails(tool: tool, row: row, skillNames: skillNames)
                    case .destination(let destination): DestinationDetails(destination: destination).id(destination.id)
                    case .botchu: HelperDetails()
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Palette.text)
        .background(Palette.sidebar)
    }
}

private struct ToolDetails: View {
    @Environment(AppModel.self) private var model
    let tool: ApprovedTool
    let row: ToolRow
    let skillNames: [String: String]
    @State private var removing = false

    var body: some View {
        let board = model.tools
        let location = board.inventory().locations(of: tool).first
        let check = board.checks[tool.id]
        let github = check?.reading?.github
        InspectorSection("Access", preferenceKey: "tool.access") {
            InspectorCard {
                InspectorRow("Enabled") {
                    Toggle(isOn: Binding(get: { tool.enabled }, set: { on in board.change { $0.setEnabled(on, for: tool.id) } })) { EmptyView() }
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                InspectorRow("Bots", value: "Every bot")
                InspectorRow("When off", value: board.policy.isEnforced ? "Blocked on This Mac" : "Left out of instructions", last: true)
            }
        }
        InspectorSection("This Mac", preferenceKey: "tool.mac") {
            InspectorCard {
                InspectorRow("Status") { ToolStatusCell(row: row) }
                InspectorRow("Path") {
                    Text(location?.path ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.pathText)
                        .truncationMode(.middle).textSelection(.enabled).help(location.map { $0.realPath == $0.path ? $0.path : "\($0.path) → \($0.realPath)" } ?? "")
                }
                if let check {
                    InspectorRow("Checked", value: RelativeDate.text(check.attemptedAt), last: github == nil && check.failure == nil)
                }
                if let failure = check?.failure {
                    InspectorRow("Last check", last: github == nil) { Text(failure).foregroundStyle(Palette.warning).help(failure) }
                }
                if let github {
                    InspectorRow("Account", last: true) {
                        switch github.state {
                        case .signedIn: Text(github.login ?? "Signed in")
                        case .failed: Text("\(github.login ?? "Account") · sign-in failed").foregroundStyle(Palette.warning)
                        case .signedOut: Text("Signed out").foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
            }
        }
        if let github, github.state != .signedOut {
            InspectorSection("Reported scopes", preferenceKey: "tool.scopes") {
                InspectorCard(padded: true) {
                    if let scopes = github.scopes {
                        if scopes.isEmpty {
                            Text("None").foregroundStyle(Palette.secondaryText)
                        } else {
                            FlowChips(names: scopes, warning: ["delete_repo", "admin:org", "admin:enterprise"])
                        }
                    } else {
                        Text("Not reported").foregroundStyle(Palette.secondaryText)
                    }
                }
            }
        }
        if !row.skills.isEmpty {
            InspectorSection("Used by", trailing: "\(row.skills.count)", preferenceKey: "tool.skills") {
                InspectorCard(padded: true) {
                    FlowLayout(spacing: 6) {
                        ForEach(row.skills, id: \.self) { id in
                            Button { model.showSkill(id) } label: { ToolChip(name: skillNames[id] ?? id) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        HStack(spacing: 8) {
            if tool.catalog != nil {
                Button { Task { await board.check(tool) } } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .disabled(board.checking.contains(tool.id))
            }
            Button(role: .destructive) { removing = true } label: { Text("Remove…").foregroundStyle(GitHubColors.danger) }
        }
        .buttonStyle(InspectorButtonStyle(fill: true))
        .confirmationDialog("Remove \(tool.name)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { model.removeTool(row) }
        } message: {
            Text(board.policy.isEnforced && tool.catalog != nil ? "It goes back to Add Tools, and turns on This Mac can’t run it." : "It goes back to Add Tools.")
        }
    }
}

/// A destination: whether agents are told about it, that SSH stays unrestricted, and the fields
/// they are told, which the owner fills in.
private struct DestinationDetails: View {
    @Environment(AppModel.self) private var model
    @State var destination: SSHDestination
    @State private var removing = false

    var body: some View {
        let board = model.tools
        InspectorSection("Scope", preferenceKey: "tool.ssh.scope") {
            InspectorCard {
                InspectorRow("In instructions") {
                    Toggle(isOn: Binding(get: { destination.included }, set: { destination.included = $0; save() })) { EmptyView() }
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                InspectorRow("Bots", value: "Every bot")
                InspectorRow("SSH access", value: "Not restricted", last: true)
            }
        }
        InspectorSection("Destination", preferenceKey: "tool.ssh.destination") {
            InspectorCard {
                field("User", text: $destination.user, prompt: "deploy")
                field("Host", text: $destination.host, prompt: "host or address")
                field("Identity", text: $destination.identityFile, prompt: "~/.ssh/key", monospaced: true)
                field("Note", text: $destination.note, prompt: "What it’s for", last: true)
            }
        }
        Button(role: .destructive) { removing = true } label: { Text("Remove…").foregroundStyle(GitHubColors.danger) }
            .buttonStyle(InspectorButtonStyle(fill: true))
            .confirmationDialog("Remove \(destination.alias)?", isPresented: $removing) {
                Button("Remove", role: .destructive) {
                    model.removeTool(ToolRow(id: ToolRow.sshID(destination), kind: .destination(destination), name: destination.alias, title: "",
                                             status: .target(nil), skills: [], enabled: false, blocked: false))
                }
            } message: {
                Text("Agents are no longer told about it.")
            }
            .onChange(of: board.policy.destinations) {
                if let saved = board.policy.destinations.first(where: { $0.id == destination.id }), saved.included != destination.included {
                    destination.included = saved.included
                }
            }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, monospaced: Bool = false, last: Bool = false) -> some View {
        InspectorRow(label, last: last) {
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .multilineTextAlignment(.trailing)
                .onSubmit(save)
                .onChange(of: text.wrappedValue) { save() }
        }
    }

    private func save() {
        model.tools.change { $0.update(destination) }
    }
}

private struct HelperDetails: View {
    var body: some View {
        InspectorSection("Access", preferenceKey: "tool.helpers.access") {
            InspectorCard {
                InspectorRow("Enabled") { Image(systemName: "lock.fill").foregroundStyle(Palette.secondaryText) }
                InspectorRow("Bots", value: "Every bot", last: true)
            }
        }
        InspectorSection("Commands", preferenceKey: "tool.helpers.commands") {
            InspectorCard(padded: true) {
                FlowChips(names: ToolRow.helpers, warning: [])
            }
        }
    }
}

/// Names as chips that wrap, those in `warning` in the warning colour.
struct FlowChips: View {
    let names: [String]
    let warning: Set<String>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in ToolChip(name: name, dependency: warning.contains(name) ? .notApproved : .enabled) }
        }
    }
}

/// Add Tools: the catalog tools found on This Mac and the commands skills use, none of them
/// approved until the owner checks them and presses Approve; an executable the owner chooses; an
/// SSH destination by its alias. Ignored candidates stay apart until restored.
struct AddToolsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let candidates: [ToolCandidate]
    let ignored: [ToolCandidate]
    let skillNames: [String: String]
    @State private var chosen: Set<String> = []
    /// Executables picked with Choose Executable…, until approved.
    @State private var picked: [ToolCandidate] = []
    @State private var showsIgnored = false
    @State private var addingDestination = false
    @State private var problem: String?

    private var rows: [ToolCandidate] { picked.filter { pick in !candidates.contains { $0.id == pick.id } } + candidates }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Tools").font(.title2.weight(.semibold)).padding(20)
            if rows.isEmpty {
                LibraryEmpty(title: "Nothing new found", subtitle: "", symbol: "checkmark.circle").frame(height: 180)
            } else {
                Table(rows) {
                    TableColumn("") { (candidate: ToolCandidate) in
                        Toggle(isOn: Binding(get: { chosen.contains(candidate.id) }, set: { on in
                            if on { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) }
                        })) { EmptyView() }
                        .toggleStyle(.checkbox).labelsHidden()
                        .accessibilityLabel("Approve \(candidate.name)")
                    }
                    .width(22)
                    TableColumn("Tool") { (candidate: ToolCandidate) in
                        HStack(spacing: 10) {
                            ToolTile(kind: .tool(ApprovedTool(id: candidate.id, name: candidate.name)), size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.name).font(.system(size: 13, weight: .semibold))
                                if !candidate.title.isEmpty { Text(candidate.title).font(.system(size: 11)).foregroundStyle(.secondary) }
                            }
                        }
                        .lineLimit(1)
                        .frame(minHeight: 36, alignment: .leading)
                        .padding(.vertical, 6)
                    }
                    .width(min: 150, ideal: 190)
                    TableColumn("Path") { (candidate: ToolCandidate) in
                        Text(candidate.path ?? "—").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(candidate.path ?? "")
                    }
                    TableColumn("Found") { (candidate: ToolCandidate) in found(candidate) }
                        .width(min: 120, ideal: 160)
                    TableColumn("") { (candidate: ToolCandidate) in
                        Button("Ignore") {
                            chosen.remove(candidate.id)
                            picked.removeAll { $0.id == candidate.id }
                            if candidates.contains(where: { $0.id == candidate.id }) { model.tools.change { $0.ignore(candidate.id) } }
                        }
                        .buttonStyle(.borderless).font(.system(size: 12))
                    }
                    .width(56)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 320)
            }
            if !ignored.isEmpty {
                DisclosureGroup(isExpanded: $showsIgnored) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ignored) { candidate in
                            HStack {
                                Text(candidate.name).font(.system(size: 12, design: .monospaced))
                                Text(candidate.path ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Restore") { model.tools.change { $0.restore(candidate.id) } }.buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Ignored \(ignored.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.top, 10)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red).padding(.horizontal, 20).padding(.top, 10)
            }
            HStack {
                Button("Choose Executable…", action: chooseExecutable)
                Button("Add SSH Destination…") { addingDestination = true }
                    .popover(isPresented: $addingDestination, arrowEdge: .top) {
                        AddSSHDestinationSheet(onAdd: { dismiss() }).environment(model)
                    }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Approve" : "Approve \(chosen.count)", action: approve)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 720)
        .frame(minHeight: 460)
    }

    @ViewBuilder private func found(_ candidate: ToolCandidate) -> some View {
        HStack(spacing: 4) {
            if candidate.skills.isEmpty {
                Text(picked.contains(where: { $0.id == candidate.id }) ? "Chosen" : "On This Mac").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("In skill").font(.system(size: 12)).foregroundStyle(.secondary)
                ToolChip(name: skillNames[candidate.skills[0]] ?? candidate.skills[0])
                if candidate.skills.count > 1 { Text("+\(candidate.skills.count - 1)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .lineLimit(1)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if let issue = ToolInventory.problem(choosing: path) { problem = issue; return }
        guard let candidate = model.tools.inventory().candidate(choosing: path) else { return }
        guard model.tools.policy.approved(candidate.id) == nil else { problem = "\(candidate.name) is already approved."; return }
        problem = nil
        if !rows.contains(where: { $0.id == candidate.id }) { picked.insert(candidate, at: 0) }
        chosen.insert(candidate.id)
    }

    private func approve() {
        let approving = rows.filter { chosen.contains($0.id) }
        model.tools.approve(approving)
        if let last = approving.last { model.toolSelection = last.id }
        dismiss()
    }
}

/// The same destination form opens directly from + or from Approve Tools.
struct AddSSHDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onAdd: () -> Void = {}
    @State private var alias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add SSH Destination").font(.title2.weight(.semibold))
            TextField("Alias", text: $alias, prompt: Text("sshwork"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(addDestination)
            if !alias.isEmpty, let problem = model.tools.policy.problem(addingDestination: alias) {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: addDestination)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(model.tools.policy.problem(addingDestination: alias) != nil)
            }
        }
        .padding(20).frame(width: 320)
    }

    private func addDestination() {
        guard model.tools.policy.problem(addingDestination: alias) == nil else { return }
        var added: SSHDestination?
        model.tools.change { added = $0.addDestination(alias) }
        if let added {
            model.skillsTab = .tools
            model.toolSelection = ToolRow.sshID(added)
            dismiss()
            onAdd()
        }
    }
}
