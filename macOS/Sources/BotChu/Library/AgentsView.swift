import SwiftUI
import BotChuCore

/// The agents, grouped under the sidebar's sections (`BotSections`), with Conversations for those in
/// none. Sections are made, renamed, reordered and removed here with the sidebar's own menus and
/// `AppModel` operations, so the two always show the same sections, saved in `index.json`.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = DevHooks.agentsSearch
    @State private var naming = SectionNaming()

    var body: some View {
        let groups = Self.groups(in: model, matching: query)
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Agents", subtitle: "Choose who you work with. Each bot keeps its own memory and personality.", count: model.bots.count) {
                Button { model.newBot() } label: { Label("New Agent", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            LibrarySearch(text: $query, prompt: "Search agents and sections").padding(.horizontal, 24).padding(.bottom, 16)
            // Section changes made here that couldn't be saved, as the sidebar says too.
            if let failure = model.indexFailure { IndexFailureBanner(failure: failure).padding(.horizontal, 14).padding(.bottom, 16) }
            if model.bots.isEmpty {
                LibraryEmpty(title: "Create your first agent", subtitle: "Give a bot a name, a role, and a provider to get started.", symbol: "person.2")
            } else if groups.allSatisfy(\.botIDs.isEmpty) {
                LibraryEmpty(title: "No matching agents", subtitle: "No agent or section matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.", symbol: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.botIDs.compactMap(model.bot)) { bot in
                                    AgentCard(bot: bot) { naming.ask(.new(botID: bot.id)) }
                                }
                            } header: {
                                AgentSectionHeading(group: group) { naming.ask(.rename($0)) }
                                    .padding(.top, group.id == groups.first?.id ? 0 : 16)
                            }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .sectionNamingAlert($naming)
        .background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Agents")
    }

    /// The headings and agents a search finds, in the sidebar's order: agents by name, title or
    /// account, within their sections, and sections, Conversations among them, by name.
    static func groups(in model: AppModel, matching query: String) -> [BotSections.Group] {
        model.botSections.groups(matching: query) { id in
            model.bot(id).map { [$0.name, $0.title, $0.account.name].joined(separator: " ") } ?? ""
        }
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
            Text(group.title).font(.title3.weight(.semibold))
            Text("\(group.botIDs.count)").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
            if let name = group.name {
                Menu { SectionMenuItems(name: name, rename: rename) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Rename, move or remove \(name)")
                    .accessibilityLabel("\(name) section actions")
            } else {
                Text("Not in a section").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// An agent's card: its avatar and activity, name, title and account, then its counts and actions.
/// Move to Section is the sidebar's menu for the bot.
struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let newSection: () -> Void

    var body: some View {
        let status = model.status(of: bot)
        let tasks = model.openTasks(of: bot.id).count
        let jobs = model.jobs.jobs(of: bot.id).count
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                BotAvatar(bot: bot, size: 56, activity: status.activity, animates: model.isBusy(bot.id))
                Spacer()
                Text(status.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(bot.name).font(.title3.weight(.semibold))
                Text(bot.title.isEmpty ? "Ready for your next idea." : bot.title).font(.callout).foregroundStyle(.secondary).lineLimit(2).frame(height: 36, alignment: .topLeading)
                if bot.isRemoteQueue { Text("Remote queue · \(model.remoteQueue.presence)").font(.caption).foregroundStyle(.secondary) }
                else { ProviderLabel(bot.account).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                if !bot.isRemoteQueue {
                Text(tasks == 1 ? "1 task" : "\(tasks) tasks").font(.caption).foregroundStyle(.secondary)
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Button(jobs == 1 ? "1 job" : "\(jobs) jobs") { jobs == 0 ? model.jobs.newJob(for: bot.id) : model.showJobs(for: bot.id) }
                    .buttonStyle(.link).font(.caption)
                    .help(jobs == 0 ? "New Job… for \(bot.name)" : "Show \(bot.name)'s jobs in Jobs")
                }
                Spacer()
                Menu { MoveToSectionItems(botID: bot.id, newSection: newSection) } label: { Image(systemName: "folder") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Move to Section")
                    .accessibilityLabel("Move \(bot.name) to Section")
                Button("Edit…") { model.edit(bot.id) }
                Button("Open Chat") { model.show(model.tab(of: bot.id)) }
            }
        }
        .padding(20).libraryCard()
        .contextMenu {
            Button("Open Chat") { model.show(model.tab(of: bot.id)) }
            Button("Edit…") { model.edit(bot.id) }
            Divider()
            if !bot.isRemoteQueue {
            Button("New Job…") { model.jobs.newJob(for: bot.id) }
            Button("Show Jobs") { model.showJobs(for: bot.id) }
            }
            Divider()
            MoveToSectionMenu(botID: bot.id, newSection: newSection)
        }
        .accessibilityIdentifier("agents-card-\(bot.id)")
    }
}
