import SwiftUI
import BotChuCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Bot?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.bots) { bot in
                BotRow(bot: bot, phase: model.status(of: bot).phase)
                    .tag(bot.id)
                    .contextMenu {
                        Button("Edit…") { model.edit(bot.id) }
                        Button("New Session") { model.newSession(bot.id) }
                            .disabled(model.isRunning(bot.id))
                        Button("Show Workspace in Finder") { model.revealWorkspace(bot.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = bot }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.bots.isEmpty {
                ContentUnavailableView("No Bots", systemImage: "person.2", description: Text("Create one below."))
            }
        }
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
            Text("Its conversation is deleted. Its workspace folder, \(bot.workspace), is kept.")
        }
    }
}

struct BotRow: View {
    let bot: Bot
    let phase: BotStatus.Phase

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(bot: bot, size: 30)
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
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        phase == .idle ? bot.account.name : phase.label
    }
}
