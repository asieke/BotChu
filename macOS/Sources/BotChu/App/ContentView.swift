import SwiftUI
import BotChuCore

/// The window: bots on the left, the selected bot's conversations as tabs beside its chat in the
/// middle, and the shown conversation's status on the right.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var hooksStarted = false
    @State private var contentSize = CGSize(width: 1240, height: 800)

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            DetailColumn()
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
        .modifier(NewTaskPresentationModifier())
        .sheet(item: $model.documentEditor) { request in
            BotDocumentEditor(request: request)
                .environment(model)
                .frame(width: contentSize.width * 0.5, height: contentSize.height * 0.5)
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

/// The gallery or conversation shown beside the sidebar: a view of its own, so a switch between
/// conversations redraws only this column.
private struct DetailColumn: View {
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
            let tab = model.tab(of: id)
            // The bot's Home and open tasks as tabs beside the chat, while it has an open task (#128).
            ConversationSplit(botID: id) {
                ChatView(target: tab)
                    .id(tab)
                    // Its history is read when it shows, if it isn't in memory (#109).
                    .onAppear { model.hydrate(tab) }
            }
            .modifier(ChatToolbar())
            .modifier(StatusSidebar {
                Group {
                    if tab.taskID != nil {
                        // A view of its own per task, so nothing it read about one task shows on another.
                        TaskInspector(target: tab)
                            .id(tab)
                    } else {
                        BotInspector(botID: id)
                    }
                }
                // Opens at its widest, and narrows from there.
                .inspectorColumnWidth(min: 280, ideal: 380, max: 380)
            })
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

/// The status sidebar beside the conversation, shown or hidden as the owner chose. Only this reads
/// whether it shows: a view whose body reads an `@AppStorage` value is evaluated again at every
/// UserDefaults write, whatever its key (the toggle itself, a split view saving its widths), so the
/// column around it, which rebuilt the whole conversation each time, reads none (#348).
private struct StatusSidebar<Inspector: View>: ViewModifier {
    @AppStorage("showsStatus") private var showsStatus = true
    @ViewBuilder let inspector: Inspector

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $showsStatus) { inspector }
            .onChange(of: showsStatus) { _, shown in FrameTimings.mark(FrameMarks.inspector(shown: shown)) }
    }
}
