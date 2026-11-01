import SwiftUI
import BotChuCore

/// The window: bots on the left, the selected bot's conversations as tabs beside its chat in the
/// middle, and the shown conversation's status on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hooksStarted = false
    @State private var sidebar = WindowSidebar()

    var body: some View {
        @Bindable var model = model
        // A native split (#437). Its hosts keep their own safe areas, so the toolbar's inset applies
        // once, in each column, and the sidebar runs under the title bar as it did.
        NativeWindowColumns(model: model, sidebar: sidebar, reduceMotion: reduceMotion)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar {
            ToolbarItem(placement: .navigation) { SidebarToggle(sidebar: sidebar) }
        }
        // The columns publish their minimum widths, including the composer's current controls.
        // A fixed window minimum would miss changes to the inspector or model options.
        .frame(minHeight: 520)
        .background { DocumentEditorPresentation() }
        .overlay { SwitcherLayer() }
        .sheet(item: $model.editor) { request in
            BotEditor(request: request)
                .environment(model)
        }
        .sheet(item: $model.issueReport) { request in
            ReportIssueSheet(request: request)
                .environment(model)
        }
        .sheet(item: $model.newIssue) { request in
            NewIssueSheet(request: request)
                .environment(model)
        }
        .sheet(item: Binding(get: { model.jobs.editor }, set: { model.jobs.editor = $0 })) { request in
            JobEditor(request: request)
                .environment(model)
        }
        .sheet(item: Binding(get: { model.jobs.history }, set: { model.jobs.history = $0 })) { request in
            JobHistorySheet(request: request)
                .environment(model)
        }
        .onAppear { FrameTimings.mark(FrameMarks.window) }
        .task {
            guard !hooksStarted else { return }
            hooksStarted = true
            DevHooks.start(model: model)
        }
    }
}

/// Only the document sheet needs the window's current dimensions. Observing them here keeps a
/// live resize from invalidating the window's SwiftUI at every intermediate size.
private struct DocumentEditorPresentation: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            Color.clear
                .sheet(item: $model.documentEditor) { request in
                    BotDocumentEditor(request: request)
                        .environment(model)
                        .frame(width: geometry.size.width * 0.5, height: geometry.size.height * 0.5)
                }
        }
    }
}

/// The gallery or conversation shown beside the sidebar, the native split's detail (#437): a view
/// of its own, so a switch between conversations redraws only this column. Its host bridges its
/// title and toolbar items into the window's toolbar.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            // Report a Bug or Feature, at the toolbar's trailing end on every screen, so a bug can be
            // reported wherever it shows: in the glass that floats over the content (macOS 26 and
            // later), beside a conversation's own buttons, it never covers the composer, the sidebar
            // or the status sidebar, at any window width. It is declared on this column, which stays
            // as conversations change: declared on the window's split view, it was made anew at every
            // switch, and every toolbar button blinked out and faded back in.
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ReportIssueButton() }
            }
    }

    @ViewBuilder private var content: some View {
        if let destination = model.destination {
            switch destination {
            case .inbox: InboxView().onAppear { FrameTimings.mark(FrameMarks.page("inbox")) }
            case .projects: ProjectsView()
            case .agents: AgentsView()
            case .providers: ProvidersView()
            case .skills: SkillsView()
            case .jobs: JobsView()
            case .settings: SettingsView().onAppear { FrameTimings.mark(FrameMarks.page("settings")) }
            }
        } else if let id = model.selection, model.bot(id) != nil {
            NativeConversationColumns()
                .navigationTitle(model.bot(id).map { ConversationTab.windowTitle(bot: $0, task: model.task(model.tab(of: id))) } ?? "")
                .modifier(ChatToolbar())
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
