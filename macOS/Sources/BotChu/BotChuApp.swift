import SwiftUI
import BotChuCore

@main
struct BotChuApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("BotChu", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bot") { model.newBot() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Bot") {
                Button("Edit Bot…") { if let id = model.selection { model.edit(id) } }
                    .keyboardShortcut("e")
                    .disabled(model.selection == nil)
                Button("New Session") { if let id = model.selection { model.newSession(id) } }
                    .keyboardShortcut("k")
                    .disabled(model.selection.map { model.running.contains($0) } ?? true)
                Button("Stop") { if let id = model.selection { model.stop(id) } }
                    .keyboardShortcut(".")
                    .disabled(model.selection.map { !model.running.contains($0) } ?? true)
                Divider()
                Button("Show Workspace in Finder") { if let id = model.selection { model.revealWorkspace(id) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selection == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var hooksStarted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            if let id = model.selection, model.bot(id) != nil {
                ChatView(botID: id)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Bot Selected", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text("Create a bot to start chatting. Each bot runs on one of your agent CLIs, in its own folder.")
                } actions: {
                    Button("New Bot") { model.newBot() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(item: $model.editor) { request in
            BotEditor(request: request)
                .environment(model)
        }
        .task {
            guard !hooksStarted else { return }
            hooksStarted = true
            DevHooks.start(model: model, openSettings: { openSettings() })
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Bot?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.bots) { bot in
                BotRow(bot: bot, running: model.running.contains(bot.id))
                    .tag(bot.id)
                    .contextMenu {
                        Button("Edit…") { model.edit(bot.id) }
                        Button("New Session") { model.newSession(bot.id) }
                            .disabled(model.running.contains(bot.id))
                        Button("Show Workspace in Finder") { model.revealWorkspace(bot.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = bot }
                    }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.bots.isEmpty {
                ContentUnavailableView("No Bots", systemImage: "person.2", description: Text("Click + to create one."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.newBot() } label: {
                    Label("New Bot", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .toolbar {
            ToolbarItem {
                Button { model.newBot() } label: { Label("New Bot", systemImage: "square.and.pencil") }
                    .help("New Bot (⌘N)")
            }
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
    let running: Bool

    var body: some View {
        HStack(spacing: 10) {
            BotAvatar(bot: bot, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .lineLimit(1)
                Text(running ? "Working…" : bot.account.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if running {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }
}

struct BotAvatar: View {
    let bot: Bot
    var size: CGFloat = 30

    var body: some View {
        Text(bot.emoji)
            .font(.system(size: size * 0.55))
            .frame(width: size, height: size)
            .background(Circle().fill(Self.tint(for: bot.name).opacity(0.22)))
    }

    /// A stable color per name, so each bot keeps its own.
    static func tint(for name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint, .red, .yellow]
        let hash = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}
