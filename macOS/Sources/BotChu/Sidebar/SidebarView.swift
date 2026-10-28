import SwiftUI
import BotChuCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Bot?
    @State private var naming = SectionNaming()
    @AppStorage(CollapsedSections.storageKey) private var collapsed = CollapsedSections()

    var body: some View {
        List(selection: Binding<SidebarDestination?>(
            get: { model.sidebarSelection },
            set: { value in
                guard let value else { return }
                model.selectSidebar(value)
            })) {
            Section("Workspace") {
                ForEach(LibraryDestination.sidebar, id: \.self) { destination in
                    let count = destination == .inbox ? model.inbox.unfinishedCount : 0
                    // What in the Inbox isn't Done, read or not (#189); the Dock counts what is unread.
                    Label(destination.title, systemImage: destination.symbol)
                        .badge(count)
                        .accessibilityValue(count > 0 ? "\(count) not done" : "")
                        .tag(SidebarDestination.library(destination))
                }
            }
            // The bots in no section, under Conversations, then each section the owner made. One row
            // per bot: its Home and tasks are the tabs beside the chat (#128).
            ForEach(model.botSections.groups) { group in
                Section(isExpanded: isExpanded(group)) {
                    ForEach(group.botIDs.compactMap(model.bot)) { bot in
                        BotRow(bot: bot, status: model.status(of: bot), summary: model.botRowSummary(of: bot),
                               selected: model.visibleBotID == bot.id)
                            .tag(SidebarDestination.bot(bot.id))
                            .accessibilityIdentifier("sidebar-bot-\(bot.id)")
                            .contextMenu {
                                Button("Edit…") { model.edit(bot.id) }
                                if !bot.isRemoteQueue {
                                Button("New Task…") { model.newTask(for: bot.id) }
                                Button("New Session") { model.newSession(.home(bot.id)) }
                                    .disabled(model.isRunning(.home(bot.id)))
                                Button("Show Workspace in Finder") { model.revealWorkspace(bot.id) }
                                }
                                Divider()
                                MoveToSectionMenu(botID: bot.id) { naming.ask(.new(botID: bot.id)) }
                                Divider()
                                Button("Delete…", role: .destructive) { pendingDelete = bot }
                            }
                    }
                } header: {
                    SidebarSectionHeader(group: group, rename: { naming.ask(.rename($0)) })
                }
            }
        }
        .listStyle(.sidebar)
        // What is selected from elsewhere (Agents, a new bot or task, ⌃Tab) shows, in its section.
        .onChange(of: model.sidebarSelection) { _, selection in
            if let id = selection?.botID { reveal(model.sections[id] ?? BotSections.unsectioned) }
        }
        // Above New Bot, while the sidebar's changes aren't saved.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure = model.indexFailure { IndexFailureBanner(failure: failure) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { model.newBot() } label: {
                    Label("New Bot", systemImage: "plus")
                }
                .help("New Bot (⌘N)")
                Spacer()
                SettingsGearButton()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .modifier(SidebarShade())
        .confirmationDialog("Delete \(pendingDelete?.name ?? "bot")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { bot in
            Button("Delete", role: .destructive) { model.delete(bot.id) }
        } message: { bot in
            let jobs = model.jobs.jobs(of: bot.id).count
            if bot.isRemoteQueue {
                Text("Its conversation and waiting remote messages are deleted. Its connection stops.")
            } else {
            Text("Its conversation and tasks are deleted"
                 + (jobs == 0 ? "" : ", and its \(jobs == 1 ? "scheduled job stops and is" : "\(jobs) scheduled jobs stop and are") deleted with them")
                 + ". Its workspace folder, \(bot.workspace), and its tasks' worktrees are kept.")
            }
        }
        .sectionNamingAlert($naming)
    }

    private func isExpanded(_ group: BotSections.Group) -> Binding<Bool> {
        Binding(get: { !collapsed.titles.contains(group.title) }, set: { expanded in
            if expanded { collapsed.titles.remove(group.title) } else { collapsed.titles.insert(group.title) }
        })
    }

    private func reveal(_ title: String) {
        if collapsed.titles.contains(title) { collapsed.titles.remove(title) }
    }
}

/// Says the sidebar's bots, order and sections couldn't be saved in `index.json`, and why, while
/// they aren't: it stays until a save works. Try Again saves them as they are now.
struct IndexFailureBanner: View {
    @Environment(AppModel.self) private var model
    let failure: SaveFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sidebar changes not saved", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Text(failure.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Try Again") { model.saveIndex() }
                .controlSize(.small)
                .accessibilityIdentifier("sidebar-index-retry")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.1)))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-index-failure")
    }
}

/// In dark mode the sidebar's material blends into the chat beside it, so the sidebar takes the
/// status sidebar's darker shade instead, with a hairline along its trailing edge. Light mode keeps
/// the standard sidebar. Both follow appearance changes as they happen.
struct SidebarShade: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            // The split view's sidebar already leaves the list's own background out, so hiding it in
            // both appearances changes nothing there; only the material shows, or the shade over it.
            .scrollContentBackground(.hidden)
            .background(dark ? Palette.sidebar : .clear)
            .overlay(alignment: .trailing) {
                if dark {
                    Rectangle().fill(Palette.hairline)
                        .frame(width: 1)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// A bot's row: its face, its name over what it is doing, and a small dot for each of its
/// conversations that isn't idle (#128), at most four, the most urgent first, then +N, at its end,
/// centred on the row (#144).
struct BotRow: View {
    let bot: Bot
    let status: BotStatus
    let summary: BotRowSummary
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Only the selected bot and busy ones move, so a long list stays calm.
            BotAvatar(bot: bot, size: 30, activity: status.activity, animates: selected || status.activity != .idle)
                .padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(summary.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !summary.dots.isEmpty {
                BotRowDots(summary: summary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The small dots at the end of a bot's row, in its tabs' colours, the most urgent first (#218).
/// On the selection's accent colour each sits on a disc of the task column's background, as a rail
/// tile's dot does, so it is drawn on the same ground as its tab's and looks the same (#237); on a
/// white disc, dark mode's colours, made for a dark ground, read pale.
struct BotRowDots: View {
    @Environment(\.backgroundProminence) private var prominence
    let summary: BotRowSummary

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(summary.dots.enumerated()), id: \.offset) { _, kind in
                StatusDot(kind: kind, size: 6, cutout: prominence == .increased ? Palette.conversationColumn : nil)
            }
            if summary.more > 0 {
                Text("+\(summary.more)")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 2)
        .help(summary.spokenDots)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.spokenDots)
    }
}
