import SwiftUI
import BotChuCore

/// The window: bots and their tasks on the left, the selected conversation in the middle,
/// and its status on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showsStatus") private var showsStatus = true
    @State private var hooksStarted = false
    @State private var contentSize = CGSize(width: 1240, height: 800)

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
        }
        // No minimum width of our own: the window's narrowest is what the columns need, which grows
        // with the sidebar's and the status's widths (the split view counts the sidebar twice). A
        // window narrower than that, which a fixed minimum allowed, lays out forever and AppKit aborts.
        .frame(minHeight: 520)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { contentSize = geometry.size }
                    .onChange(of: geometry.size) { _, size in contentSize = size }
            }
        }
        .sheet(item: $model.editor) { request in
            BotEditor(request: request)
                .environment(model)
        }
        .sheet(item: $model.taskSheet) { request in
            NewTaskSheet(botID: request.botID, initialRepo: request.repo, initialWork: request.work, initialPurpose: request.purpose,
                         initialBrief: request.brief)
                .environment(model)
        }
        .sheet(item: $model.documentEditor) { request in
            BotDocumentEditor(request: request)
                .frame(width: contentSize.width * 0.5, height: contentSize.height * 0.5)
        }
        .sheet(item: $model.issueReport) { request in
            ReportIssueSheet(request: request)
                .environment(model)
        }
        // Report a Bug or Feature, at the toolbar's trailing end on every screen, so a bug can be
        // reported wherever it shows: in the glass that floats over the content (macOS 26 and
        // later), beside a conversation's own buttons, it never covers the composer, the sidebar or
        // the status sidebar, at any window width.
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ReportIssueButton() }
        }
        .task {
            guard !hooksStarted else { return }
            hooksStarted = true
            DevHooks.start(model: model, openSettings: { openSettings() })
        }
    }

    @ViewBuilder private var detail: some View {
        if let destination = model.destination {
            switch destination {
            case .projects: ProjectsView()
            case .agents: AgentsView()
            case .providers: ProvidersView()
            }
        } else if let id = model.selection, model.bot(id) != nil {
            let tab = model.tab(of: id)
            VStack(spacing: 0) {
                ChatView(target: tab)
                    .id(tab)
            }
            .inspector(isPresented: $showsStatus) {
                Group {
                    if tab.taskID != nil {
                        // A view of its own per task, so nothing it read about one task shows on another.
                        TaskInspector(target: tab)
                            .id(tab)
                    } else {
                        BotInspector(botID: id)
                    }
                }
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
