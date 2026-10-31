import SwiftUI
import UniformTypeIdentifiers
import BotChuCore

/// The sidebar, with its sections open or collapsed as the owner left them. Only this reads those
/// settings, and hands their values to the list: a view whose body reads an `@AppStorage` value is
/// evaluated again at every UserDefaults write, whatever its key (the status sidebar's toggle, a
/// split view saving its widths), and the list, which updates every row it shows, needn't be (#348).
struct SidebarView: View {
    @AppStorage(CollapsedSections.storageKey) private var collapsed = CollapsedSections()

    var body: some View {
        SidebarList(collapsed: collapsed, collapse: { change in change(&collapsed) })
            .equatable()
    }
}

/// Compared by the setting it shows, not by its action, which is made anew each time and always
/// sets the same setting.
private struct SidebarList: View, Equatable {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Bot?
    @State private var naming = SectionNaming()
    let collapsed: CollapsedSections
    let collapse: ((inout CollapsedSections) -> Void) -> Void

    static func == (a: Self, b: Self) -> Bool { a.collapsed == b.collapsed }

    var body: some View {
        let _ = SidebarStatusDiagnostics.didEvaluateList?()
        List(selection: Binding<SidebarDestination?>(
            get: { model.sidebarSelection },
            set: { value in
                guard let value else { return }
                model.selectSidebar(value)
            })) {
            Section("Workspace") {
                ForEach(LibraryDestination.sidebar, id: \.self) { destination in
                    SidebarWorkspaceRow(destination: destination)
                        .tag(SidebarDestination.library(destination))
                        .accessibilityIdentifier("sidebar-\(destination.rawValue)")
                }
            }
            // The principal bots in no section, under Conversations, then each section the owner
            // made. One row per bot: its Home and areas are the column beside the chat (#128, #402).
            // Specialists aren't listed: Agents lists them, and they are called by @mention.
            let specialists = model.specialists
            ForEach(model.agentSections.groups.filter { !$0.botIDs.isEmpty || specialists.isEmpty }) { group in
                Section(isExpanded: isExpanded(group)) {
                    ForEach(group.botIDs.compactMap(model.bot)) { bot in
                        row(bot)
                            .contextMenu {
                                Button("Edit…") { model.edit(bot.id) }
                                if !bot.isRemoteQueue {
                                Button("New Session") { model.newSession(.home(bot.id)) }
                                    .disabled(model.isRunning(.home(bot.id)))
                                Button("Show Workspace in Finder") { model.revealWorkspace(bot.id) }
                                }
                                Divider()
                                MoveToSectionMenu(botID: bot.id) { naming.ask(.new(botID: bot.id)) }
                                Divider()
                                Button("Delete…", role: .destructive) { pendingDelete = bot }
                            }
                            // Dragged to its place among the bots, in its section or another (#231).
                            .itemProvider { BotDrag.provider(for: bot.id) }
                    }
                    // A bot dropped between these goes before the one below where it lands, or last.
                    .onInsert(of: [BotDrag.contentType]) { index, providers in
                        drop(providers, in: group, at: index)
                    }
                } header: {
                    SidebarSectionHeader(group: group, rename: { naming.ask(.rename($0)) })
                        // Dropped on a heading, collapsed or not, a bot goes last in its section.
                        .onDrop(of: [BotDrag.contentType], isTargeted: nil) { providers in
                            BotDrag.load(providers) { model.dropBot($0, inSection: group.name, before: nil) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        // What is selected from elsewhere (Agents, a new bot or task, ⌃Tab) shows, in its section.
        .onChange(of: model.sidebarSelection) { _, selection in
            guard let id = selection?.botID, model.bot(id)?.isSpecialist == false else { return }
            reveal(model.sections[id] ?? BotSections.unsectioned)
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
        .botDeletionDialog($pendingDelete)
        .sectionNamingAlert($naming)
    }

    private func row(_ bot: Bot) -> some View {
        // Whether it is selected is said here, once for every row: a row that read the selection
        // itself was drawn again, with its status and summary, whenever any bot was selected (#348).
        SidebarBotRow(bot: bot, selected: model.visibleBotID == bot.id)
            .tag(SidebarDestination.bot(bot.id))
            .accessibilityIdentifier("sidebar-bot-\(bot.id)")
            .onAppear { FrameTimings.mark(FrameMarks.sidebarRow) }
    }

    private func isExpanded(_ group: BotSections.Group) -> Binding<Bool> {
        Binding(get: { !collapsed.titles.contains(group.title) }, set: { expanded in
            collapse { if expanded { $0.titles.remove(group.title) } else { $0.titles.insert(group.title) } }
        })
    }

    private func reveal(_ title: String) {
        if collapsed.titles.contains(title) { collapse { $0.titles.remove(title) } }
    }

    /// Puts a bot dropped at `index` among a section's bots, as the sidebar shows them, before the
    /// bot shown there, or last after them. The bot to go before is read now, as the drop lands.
    private func drop(_ providers: [NSItemProvider], in group: BotSections.Group, at index: Int) {
        let shown = group.botIDs.filter { model.bot($0) != nil }
        let next = shown.indices.contains(index) ? shown[index] : nil
        _ = BotDrag.load(providers) { model.dropBot($0, inSection: group.name, before: next) }
    }
}

/// Each row owns its status reads. Activity in one conversation updates its bot's row without
/// evaluating the statuses of the other bots in the sidebar. A Project Area's row dropped on it
/// moves the area to its bot (#402), which it shows by a ring while one is over it.
private struct SidebarBotRow: View {
    @Environment(AppModel.self) private var model
    let bot: Bot
    let selected: Bool
    @State private var targeted = false

    var body: some View {
        let _ = SidebarStatusDiagnostics.didEvaluateRow?(bot.id)
        BotRow(bot: bot, status: model.status(of: bot), summary: model.botRowSummary(of: bot), selected: selected)
            .background {
                if targeted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4)
                }
            }
            .onDrop(of: [AreaDrag.contentType], isTargeted: bot.canOwnTasks ? $targeted : nil) { providers in
                guard bot.canOwnTasks else { return false }
                return AreaDrag.load(providers) { model.dropArea($0, on: bot.id) }
            }
    }
}

private struct SidebarWorkspaceRow: View {
    @Environment(AppModel.self) private var model
    let destination: LibraryDestination

    var body: some View {
        // What isn't Done, read or not (#189); the Dock counts what is unread.
        let count = destination == .inbox ? model.inbox.unfinishedCount : 0
        Label(destination.title, systemImage: destination.symbol)
            .badge(count)
            .accessibilityValue(count > 0 ? "\(count) not done" : "")
    }
}

extension View {
    /// Asks before deleting the bot `pending` holds, saying what goes with it and what is kept.
    func botDeletionDialog(_ pending: Binding<Bot?>) -> some View { modifier(BotDeletionDialog(pending: pending)) }
}

struct BotDeletionDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pending: Bot?

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete \(pending?.name ?? "bot")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { bot in
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

/// A bot's row: its face, its name over what it runs on (#324), and a small dot for each of its
/// open tasks and for Home while it isn't idle (#128), at most eight in two rows of four, the most
/// urgent first, then +N, at its end, centred on the row (#144, #359).
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

/// The small dots at the end of a bot's row, in its tabs' colours, the most urgent first (#218),
/// in rows of four, the first filled first, so eight fit in the height of its two lines (#359).
/// On the selection's accent colour each sits on a disc of the task column's background, as a rail
/// tile's dot does, so it is drawn on the same ground as its tab's and looks the same (#237); on a
/// white disc, dark mode's colours, made for a dark ground, read pale.
struct BotRowDots: View {
    @Environment(\.backgroundProminence) private var prominence
    let summary: BotRowSummary
    private static let columns = 4

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(stride(from: 0, to: summary.dots.count, by: Self.columns)), id: \.self) { start in
                    HStack(spacing: 4) {
                        ForEach(start..<min(start + Self.columns, summary.dots.count), id: \.self) { index in
                            StatusDot(kind: summary.dots[index], size: 6, cutout: prominence == .increased ? Palette.conversationColumn : nil)
                        }
                    }
                }
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
