import SwiftUI
import BotChuCore

/// The window: bots on the left, the selected bot's chat in the middle, its status on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showsStatus") private var showsStatus = true
    @State private var hooksStarted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
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

    @ViewBuilder private var detail: some View {
        if let id = model.selection, model.bot(id) != nil {
            ChatView(botID: id)
                .id(id)
                .inspector(isPresented: $showsStatus) {
                    BotInspector(botID: id)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
                }
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
}
