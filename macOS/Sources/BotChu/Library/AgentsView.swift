import SwiftUI
import BotChuCore

/// The agents, a table for each of the sidebar's sections (`BotSections`), with Conversations for
/// those in none, then the specialists' table (#250). Sections are made, renamed, reordered and
/// removed here with the sidebar's own menus and `AppModel` operations, so the two always show the
/// same sections, saved in `index.json`. A bot's account, model and effort change in its row.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = DevHooks.agentsSearch
    @State private var naming = SectionNaming()
    @State private var pendingDelete: Bot?
    @State private var width: CGFloat = 1000

    var body: some View {
        let groups = Self.groups(in: model, matching: query).filter { !$0.botIDs.isEmpty }
        let specialists = Self.specialists(in: model, matching: query)
        let columns = AgentColumns(width: width)
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Agents", count: model.bots.filter { !$0.isSpecialist }.count) {
                Button { model.newBot() } label: { Label("New Agent", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            LibrarySearch(text: $query, prompt: "Search agents and sections").padding(.horizontal, 24).padding(.bottom, 16)
            // Section changes made here that couldn't be saved, as the sidebar says too.
            if let failure = model.indexFailure { IndexFailureBanner(failure: failure).padding(.horizontal, 14).padding(.bottom, 16) }
            if model.bots.isEmpty {
                LibraryEmpty(title: "Create your first agent", subtitle: "Give a bot a name, a role, and a provider to get started.", symbol: "person.2")
            } else if groups.isEmpty && specialists.isEmpty {
                LibraryEmpty(title: "No matching agents", subtitle: "No agent or section matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.", symbol: "magnifyingglass")
            } else {
                // Tables of rows rather than SwiftUI's Table, which scrolls by itself: these share
                // one scroll and their columns' widths.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(groups) { group in
                            AgentTable(bots: group.botIDs.compactMap(model.bot), columns: columns, counts: true,
                                       newSection: { naming.ask(.new(botID: $0)) }, delete: { pendingDelete = $0 }) {
                                AgentSectionHeading(group: group) { naming.ask(.rename($0)) }
                            }
                        }
                        // Specialists last, with New Specialist, also before there are any.
                        if !specialists.isEmpty || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                if !groups.isEmpty { Divider().padding(.bottom, 24) }
                                AgentTable(bots: specialists, columns: columns, counts: false,
                                           newSection: { _ in }, delete: { pendingDelete = $0 }) {
                                    SpecialistsHeading(count: specialists.count)
                                }
                            }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sectionNamingAlert($naming)
        .botDeletionDialog($pendingDelete)
        .background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Agents")
    }

    /// The headings and agents a search finds, in the sidebar's order: agents by name, title or
    /// account, within their sections, and sections, Conversations among them, by name. Specialists
    /// are in none of them (`specialists(in:matching:)`).
    static func groups(in model: AppModel, matching query: String) -> [BotSections.Group] {
        model.agentSections.groups(matching: query) { id in
            model.bot(id).map(searchText) ?? ""
        }
    }

    /// The specialists a search finds, in sidebar order: all of them when it names their heading,
    /// else those whose name, title or account has it, as an agent is found.
    static func specialists(in model: AppModel, matching query: String) -> [Bot] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !"Specialists".localizedCaseInsensitiveContains(query) else { return model.specialists }
        return model.specialists.filter { searchText($0).localizedCaseInsensitiveContains(query) }
    }

    private static func searchText(_ bot: Bot) -> String { [bot.name, bot.title, bot.account.name].joined(separator: " ") }
}

/// The Agents tables' columns at the gallery's width (#250). Each table lays its heading and rows
/// out with the same widths, so their columns line up down the page. Narrower, Tasks · Jobs goes
/// first and the status moves into the name's cell (under 980), then the account shows only its
/// mark (under 780), then the effort only its glyph (under 680).
struct AgentColumns: Equatable {
    var width: CGFloat

    static let gap: CGFloat = 12
    static let inset: CGFloat = 10
    static let pet: CGFloat = 56
    static let counts: CGFloat = 72
    static let actions: CGFloat = 52
    static let status: CGFloat = 84

    var showsCounts: Bool { width >= 980 }
    var statusInName: Bool { width < 980 }
    var accountMarkOnly: Bool { width < 780 }
    var effortGlyphOnly: Bool { width < 680 }
    var account: CGFloat { accountMarkOnly ? 40 : 164 }
    var model: CGFloat { accountMarkOnly ? 176 : 184 }
    var effort: CGFloat { effortGlyphOnly ? 40 : accountMarkOnly ? 108 : 112 }
}

/// A heading line and its table of bots. The column labels sit on the heading's line, so there is
/// no header row; the rows are in a card, with hairlines between them from past the pets.
struct AgentTable<Heading: View>: View {
    let bots: [Bot]
    let columns: AgentColumns
    /// Whether the table has Tasks · Jobs: agents do, specialists own neither.
    let counts: Bool
    let newSection: (UUID) -> Void
    let delete: (Bot) -> Void
    @ViewBuilder var heading: () -> Heading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: AgentColumns.gap) {
                heading().frame(maxWidth: .infinity, alignment: .leading)
                if !columns.statusInName { label("Status", width: AgentColumns.status) }
                // Its marks say what it is where the column is too narrow for its label.
                label(columns.accountMarkOnly ? "" : "Account", width: columns.account, inset: 6)
                label("Model", width: columns.model, inset: 6)
                label("Effort", width: columns.effort, inset: 6)
                if columns.showsCounts { label(counts ? "Tasks · Jobs" : "", width: AgentColumns.counts) }
                Color.clear.frame(width: AgentColumns.actions, height: 1)
            }
            .padding(.horizontal, AgentColumns.inset)
            if !bots.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                        AgentTableRow(bot: bot, columns: columns, newSection: { newSection(bot.id) }, delete: { delete(bot) })
                        if index < bots.count - 1 {
                            Divider().padding(.leading, AgentColumns.inset + AgentColumns.pet + AgentColumns.gap)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            }
        }
    }

    /// A column's label, from where its values' text starts (`inset` into a control's padding).
    private func label(_ title: String, width: CGFloat, inset: CGFloat = 0) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, inset)
            .frame(width: width, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A heading in Agents: the section's name and how many agents it shows. A named section has the
/// sidebar heading's menu, as a button and on a right click; Conversations, the agents in no section,
/// has none.
struct AgentSectionHeading: View {
    let group: BotSections.Group
    let rename: (String) -> Void

    var body: some View {
        if let name = group.name {
            heading
                .contextMenu { SectionMenuItems(name: name, rename: rename) }
                .accessibilityIdentifier("agents-section-\(name)")
        } else {
            heading
                .accessibilityIdentifier("agents-section-\(group.title)")
        }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Text(group.title).font(.title3.weight(.semibold)).lineLimit(1)
            AgentCount(count: group.botIDs.count)
            if let name = group.name {
                Menu { SectionMenuItems(name: name, rename: rename) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Rename, move or remove \(name)")
                    .accessibilityLabel("\(name) section actions")
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The specialists' heading (#250): larger than a section's, with New Specialist beside it.
struct SpecialistsHeading: View {
    @Environment(AppModel.self) private var model
    let count: Int

    var body: some View {
        // Its button keeps only its plus where the name's column is too narrow for its title.
        ViewThatFits(in: .horizontal) {
            heading(titled: true)
            heading(titled: false)
        }
        .accessibilityIdentifier("agents-section-Specialists")
    }

    private func heading(titled: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Specialists").font(.title2.bold()).lineLimit(1).fixedSize()
            AgentCount(count: count)
            Button { model.newBot(role: .specialist) } label: {
                Label("New Specialist", systemImage: "plus").labelStyle(TitledLabel(titled: titled))
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .help("New Specialist")
            .padding(.leading, 4)
            Spacer(minLength: 0)
        }
    }
}

/// A label with its title, or its icon only.
private struct TitledLabel: LabelStyle {
    let titled: Bool

    func makeBody(configuration: Configuration) -> some View {
        if titled { Label(configuration) } else { configuration.icon }
    }
}

/// How many bots a heading shows, in a capsule.
private struct AgentCount: View {
    let count: Int

    var body: some View {
        Text("\(count)").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
    }
}

/// A bot's row: its pet, name and title, what it is doing, its account, model and effort, which
/// change here as in Edit Bot (also while a turn runs, from its next turn), an agent's open tasks
/// and jobs, then Open Chat and its menu. A double click opens its chat. The remote queue bot has
/// no account, model or effort of its own here.
struct AgentTableRow: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let columns: AgentColumns
    let newSection: () -> Void
    let delete: () -> Void
    @State private var hovered = false

    var body: some View {
        let status = model.status(of: bot)
        let busy = status.phase.isActive || model.isBusy(bot.id)
        let doing = busy ? (status.activity == .thinking ? "Thinking…" : "Working") : "Idle"
        HStack(spacing: AgentColumns.gap) {
            HStack(spacing: 12) {
                BotAvatar(bot: bot, size: AgentColumns.pet, activity: status.activity, animates: busy)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(bot.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if columns.statusInName && busy { BusyDot() }
                    }
                    // Narrow, what it is doing stands in for its title while it works, as its sidebar row's does.
                    let line = columns.statusInName && busy ? doing : bot.title
                    if !line.isEmpty {
                        Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !columns.statusInName {
                HStack(spacing: 6) {
                    if busy { BusyDot() }
                    Text(doing).font(.system(size: 12)).foregroundStyle(busy ? Palette.text : Palette.secondaryText).lineLimit(1)
                }
                .frame(width: AgentColumns.status, alignment: .leading)
            }
            account.frame(width: columns.account, alignment: .leading)
            if bot.isRemoteQueue {
                dash.frame(width: columns.model, alignment: .leading)
                dash.frame(width: columns.effort, alignment: .leading)
            } else {
                ModelMenu(settings: bot, disabled: false, onModel: { model.setModel($0, ofBot: bot.id) },
                          onEffort: { model.setReasoningEffort($0, ofBot: bot.id) },
                          onProvider: { model.setProvider($0, ofBot: bot.id) }, tableCell: .model, rowHovered: hovered)
                    .frame(width: columns.model, alignment: .leading)
                ModelMenu(settings: bot, disabled: false, onModel: { model.setModel($0, ofBot: bot.id) },
                          onEffort: { model.setReasoningEffort($0, ofBot: bot.id) },
                          onProvider: { model.setProvider($0, ofBot: bot.id) }, tableCell: .effort, rowHovered: hovered,
                          compact: columns.effortGlyphOnly)
                    .frame(width: columns.effort, alignment: .leading)
            }
            if columns.showsCounts { counts.frame(width: AgentColumns.counts, alignment: .leading) }
            HStack(spacing: 4) {
                Button { model.show(model.tab(of: bot.id)) } label: { Image(systemName: "bubble.left") }
                    .buttonStyle(.borderless)
                    .help("Open Chat")
                    .accessibilityLabel("Open \(bot.name)'s chat")
                Menu { AgentMenuItems(bot: bot, newSection: newSection, delete: delete) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(bot.name) actions")
            }
            .foregroundStyle(.secondary)
            .frame(width: AgentColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, AgentColumns.inset)
        .frame(height: AgentColumns.pet + 12)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2) { model.show(model.tab(of: bot.id)) }
        .contextMenu { AgentMenuItems(bot: bot, newSection: newSection, delete: delete) }
        .accessibilityIdentifier("agents-row-\(bot.id)")
    }

    /// Its account, chosen in place: a plain name until its row is hovered. A change resets the
    /// model and effort as Edit Bot does (`RunSettings.selectAccount`).
    @ViewBuilder private var account: some View {
        if bot.isRemoteQueue {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                if !columns.accountMarkOnly { Text("Remote queue").lineLimit(1) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .help("Remote queue · \(model.remoteQueue.presence)")
        } else {
            Menu {
                Picker("Account", selection: Binding(get: { bot.accountID }, set: { model.setAccount($0, ofBot: bot.id) })) {
                    ForEach(model.settings.accounts) { account in ProviderMenuLabel(account).tag(account.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    ProviderLogo(kind: bot.account.kind, size: 13)
                    if !columns.accountMarkOnly { Text(bot.account.name).lineLimit(1) }
                    TableChevron(symbol: "chevron.up.chevron.down", shown: hovered)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(GenerationButtonStyle(table: true))
            .help(bot.account.name)
            .accessibilityLabel("Account: \(bot.account.name)")
        }
    }

    @ViewBuilder private var counts: some View {
        if let counts = Self.counts(of: bot, in: model) {
            Text(counts).font(.system(size: 12)).monospacedDigit().foregroundStyle(bot.isRemoteQueue ? .tertiary : .secondary)
        } else {
            // A specialist's cell is blank, and keeps its width so the columns line up.
            Color.clear.frame(height: 1)
        }
    }

    /// What Tasks · Jobs says for a bot: an agent's open tasks and its jobs, a dash for the remote
    /// queue bot, and nothing for a specialist, which owns neither (#250).
    static func counts(of bot: Bot, in model: AppModel) -> String? {
        if bot.isRemoteQueue { return "—" }
        guard bot.canOwnTasks else { return nil }
        return "\(model.openTasks(of: bot.id).count) · \(model.jobs.jobs(of: bot.id).count)"
    }

    private var dash: some View {
        Text("—").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 6)
    }
}

/// The violet dot of a bot that is working.
private struct BusyDot: View {
    var body: some View {
        Circle().fill(Palette.violet).frame(width: 6, height: 6).accessibilityHidden(true)
    }
}

/// A bot's menu in Agents, from its ⋯ and on a right click. A specialist starts no tasks or jobs
/// and is in no section (#250); Move to Section is the sidebar's.
struct AgentMenuItems: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let newSection: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("Open Chat") { model.show(model.tab(of: bot.id)) }
        Button("Edit…") { model.edit(bot.id) }
        if bot.canOwnTasks {
            Divider()
            Button("New Task…") { model.newTask(for: bot.id) }
            Button("New Job…") { model.jobs.newJob(for: bot.id) }
            Button("Show Jobs") { model.showJobs(for: bot.id) }
        }
        Divider()
        if !bot.isSpecialist { MoveToSectionMenu(botID: bot.id, newSection: newSection) }
        if !bot.isRemoteQueue { Button("Show Workspace in Finder") { model.revealWorkspace(bot.id) } }
        Divider()
        Button("Delete…", role: .destructive, action: delete)
    }
}
