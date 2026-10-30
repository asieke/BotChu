import SwiftUI
import BotChuCore

@main
struct BotChuApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("BotChu", id: "main") {
            ContentView()
                .environment(model)
                .inboxNotifications(model)
                // The saved Projects catalog shows at once; this syncs it with GitHub behind it.
                .task { await model.loadProjects() }
        }
        .defaultSize(width: 1240, height: 800)
        .commands { BotChuCommands(model: model) }
    }
}

/// The menu bar's commands. They read the settings and the model they show themselves: what the App
/// reads draws its whole window again when it changes, and a setting it read did on every save to
/// UserDefaults, such as a Projects column's width on each frame of the sidebar's slide (#188).
/// The settings shown are read by their own items: the commands that read them were all made
/// again, and the menu bar with them, at every UserDefaults write, whatever its key (#348).
private struct BotChuCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // Settings is a page of the window (#191), not a window of its own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Bot") { model.newBot() }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            Button("Show Inbox") { model.destination = .inbox }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            StatusMenuButton()
            ChatDensityMenuPicker()
            // The column of a bot's tabs beside its chat, or its rail (#128).
            ConversationColumnToggle(model: model)
        }
        // A page in the browser on this Mac, made from what BotChu has recorded (#233).
        CommandGroup(after: .toolbar) {
            Button("Open Analytics Dashboard") { model.openAnalyticsDashboard() }
        }
        CommandMenu("Bot") {
            // The shown conversation, the selected bot's Home or its open task tab, as the menu
            // was drawn; the actions look again when chosen.
            let tab = model.visibleBotID.map { model.tab(of: $0) }
            let remote = model.visibleBotID.flatMap(model.bot)?.isRemoteQueue == true
            let ownsTasks = model.visibleBotID.flatMap(model.bot)?.canOwnTasks == true
            Button("Edit Bot…") { if let id = model.visibleBotID { model.edit(id) } }
                .keyboardShortcut("e")
                .disabled(model.visibleBotID == nil)
            Button("New Task…") { if let id = model.visibleBotID { model.newTask(for: id) } }
                .keyboardShortcut("t")
                .disabled(!ownsTasks)
            Button("New Session") { if let id = model.visibleBotID { model.newSession(model.tab(of: id)) } }
                .keyboardShortcut("k")
                .disabled(remote || (tab.map { model.isRunning($0) } ?? true))
            Button("Stop") { if let id = model.visibleBotID { model.stop(model.tab(of: id)) } }
                .keyboardShortcut(".")
                .disabled(remote || (tab.map { !model.isRunning($0) } ?? true))
            Divider()
            Button("Show Next Tab") { if let id = model.visibleBotID { model.showTab(offset: 1, of: id) } }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(model.visibleBotID.map { model.openTasks(of: $0).isEmpty } ?? true)
            Button("Show Previous Tab") { if let id = model.visibleBotID { model.showTab(offset: -1, of: id) } }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model.visibleBotID.map { model.openTasks(of: $0).isEmpty } ?? true)
            // ⌘1 shows Home and ⌘2 to ⌘9 the first eight tasks, also from a gallery (#128).
            if let id = model.selection {
                ForEach(Array(model.tabs(of: id).prefix(9).enumerated()), id: \.element) { index, target in
                    Button(model.task(target)?.title ?? "Show Home") { model.showTab(at: index, of: id) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            Button("Close Task") { if let id = model.visibleBotID { model.closeTask(model.tab(of: id)) } }
                .disabled(tab.map { $0.taskID == nil || model.isRunning($0) } ?? true)
            Divider()
            Button("Show Workspace in Finder") { if let id = model.visibleBotID { model.revealWorkspace(id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.visibleBotID == nil || remote)
        }
        CommandGroup(after: .help) {
            Button("Report a Bug or Feature…") { model.reportIssue() }
                .disabled(!model.canReportIssue)
        }
    }
}

private struct StatusMenuButton: View {
    @AppStorage("showsStatus") private var showsStatus = true

    var body: some View {
        Button(showsStatus ? "Hide Status" : "Show Status") { showsStatus.toggle() }
            .keyboardShortcut("i", modifiers: [.command, .option])
    }
}

private struct ChatDensityMenuPicker: View {
    @AppStorage(ChatDensity.storageKey) private var chatDensity: ChatDensity = .detailed

    var body: some View {
        Picker("Chat Density", selection: $chatDensity) {
            ForEach(ChatDensity.allCases) { Text($0.title).tag($0) }
        }
    }
}
