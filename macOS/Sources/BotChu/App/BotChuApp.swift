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
                .frame(minWidth: 820, minHeight: 520)
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
                Button("Edit Bot…") { if let id = model.selection { model.edit(id) } }
                    .keyboardShortcut("e")
                    .disabled(model.selection == nil)
                Button("New Session") { if let id = model.selection { model.newSession(id) } }
                    .keyboardShortcut("k")
                    .disabled(model.selection.map { model.isRunning($0) } ?? true)
                Button("Stop") { if let id = model.selection { model.stop(id) } }
                    .keyboardShortcut(".")
                    .disabled(model.selection.map { !model.isRunning($0) } ?? true)
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
