import SwiftUI
import BotChuCore

@main
struct BotChuApp: App {
    @State private var model = AppModel()
    @AppStorage("showsStatus") private var showsStatus = true

    var body: some Scene {
        WindowGroup("BotChu", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bot") { model.newBot() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .sidebar) {
                Button(showsStatus ? "Hide Status" : "Show Status") { showsStatus.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
            CommandMenu("Bot") {
                // The shown conversation, the selected bot's Home or its open task tab, as the menu
                // was drawn; the actions look again when chosen.
                let tab = model.selection.map { model.tab(of: $0) }
                Button("Edit Bot…") { if let id = model.selection { model.edit(id) } }
                    .keyboardShortcut("e")
                    .disabled(model.selection == nil)
                Button("New Task…") { if let id = model.selection { model.newTask(for: id) } }
                    .keyboardShortcut("t")
                    .disabled(model.selection == nil)
                Button("New Session") { if let id = model.selection { model.newSession(model.tab(of: id)) } }
                    .keyboardShortcut("k")
                    .disabled(tab.map { model.isRunning($0) } ?? true)
                Button("Stop") { if let id = model.selection { model.stop(model.tab(of: id)) } }
                    .keyboardShortcut(".")
                    .disabled(tab.map { !model.isRunning($0) } ?? true)
                Divider()
                Button("Show Next Tab") { if let id = model.selection { model.showTab(offset: 1, of: id) } }
                    .keyboardShortcut(.tab, modifiers: .control)
                    .disabled(model.selection.map { model.openTasks(of: $0).isEmpty } ?? true)
                Button("Show Previous Tab") { if let id = model.selection { model.showTab(offset: -1, of: id) } }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(model.selection.map { model.openTasks(of: $0).isEmpty } ?? true)
                Button("Close Task") { if let id = model.selection { model.closeTask(model.tab(of: id)) } }
                    .disabled(tab.map { $0.taskID == nil || model.isRunning($0) } ?? true)
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
