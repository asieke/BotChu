import SwiftUI
import BotChuCore

private enum SidebarDestination: Hashable { case library(LibraryDestination), bot(UUID) }

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Bot?

    var body: some View {
        List(selection: Binding<SidebarDestination?>(
            get: { model.destination.map(SidebarDestination.library) ?? model.selection.map(SidebarDestination.bot) },
            set: { value in
                switch value {
                case .library(let destination): model.destination = destination
                case .bot(let id): model.show(model.tab(of: id))
                case nil: break
                }
            })) {
            Section("Workspace") {
                ForEach(LibraryDestination.allCases, id: \.self) { destination in
                    Label(destination.title, systemImage: destination.symbol).tag(SidebarDestination.library(destination))
                }
            }
            Section("Conversations") {
            ForEach(model.bots) { bot in
                BotRow(bot: bot, status: model.status(of: bot), selected: model.visibleBotID == bot.id,
                       unread: model.visibleBotID == bot.id ? 0 : model.unreadCount(of: bot.id))
                    .tag(SidebarDestination.bot(bot.id))
                    .contextMenu {
                        Button("Edit…") { model.edit(bot.id) }
                        Button("New Task…") { model.newTask(for: bot.id) }
                        Button("New Session") { model.newSession(.home(bot.id)) }
                            .disabled(model.isRunning(.home(bot.id)))
                        Button("Show Workspace in Finder") { model.revealWorkspace(bot.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = bot }
                    }
            }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { model.newBot() } label: {
                    Label("New Bot", systemImage: "plus")
                }
                .help("New Bot (⌘N)")
                Spacer()
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .labelStyle(.iconOnly)
                }
                .help("Settings (⌘,)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "bot")?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { bot in
            Button("Delete", role: .destructive) { model.delete(bot.id) }
        } message: { bot in
            Text("Its conversation and tasks are deleted. Its workspace folder, \(bot.workspace), and its tasks' worktrees are kept.")
        }
    }
}

struct BotRow: View {
    let bot: Bot
    let status: BotStatus
    let selected: Bool
    /// Conversations (Home or tasks) that finished a turn since they were last shown.
    var unread = 0

    private var phase: BotStatus.Phase { status.phase }

    var body: some View {
        HStack(spacing: 10) {
            // Only the selected bot and busy ones move, so a long list stays calm.
            BotAvatar(bot: bot, size: 30, activity: status.activity, animates: selected || status.activity != .idle)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(phase == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if phase.isActive {
                ProgressView().controlSize(.small)
            }
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Color.accentColor))
                    .help(unread == 1 ? "1 conversation has news" : "\(unread) conversations have news")
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        phase == .idle ? bot.account.name : status.label
    }
}
