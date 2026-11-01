import SwiftUI
import BotChuCore

/// ⌘K's switcher (#428): agents, specialists and projects in one search, each opening where it
/// lives. Matching and ranking are `SwitcherIndex`'s.
extension AppModel {
    /// What the switcher searches, read as it opens: every bot, the Projects catalog and the areas
    /// not hidden.
    var switcherIndex: SwitcherIndex {
        let roster = bots.map(BotRosterEntry.init)
        let areas = zip(bots, roster).flatMap { bot, entry in areas(of: bot.id).filter { !$0.isArchived }.map { (bot: entry, area: $0) } }
        return SwitcherIndex(bots: roster, catalog: projectCatalog, areas: areas)
    }

    /// Opens a result and closes the switcher: an agent's conversation, as its sidebar row does; a
    /// specialist, which has no Home, selected in Agents; a project's area, or its page in Projects
    /// when it has none or its area is hidden.
    func open(_ item: SwitcherItem) {
        switcherShown = false
        switch item.place {
        case .bot(let id):
            guard let bot = bot(id) else { return }
            if bot.isSpecialist {
                destination = .agents
                highlightedAgent = id
            } else {
                selectSidebar(.bot(id))
            }
        case .repo(let repo):
            if let owner = areaOwner(repo: repo), !owner.area.isArchived {
                show(.task(owner.area.id, of: owner.botID))
            } else {
                destination = .projects
                selectProject(repo)
            }
        case .area(let botID, let taskID):
            show(.task(taskID, of: botID))
        }
    }
}

/// Over the window, the switcher while it shows. Only this view reads whether it does, so opening
/// it redraws nothing else.
struct SwitcherLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.switcherShown {
            SwitcherHost(palette: SwitcherPalette(model: model, index: model.switcherIndex))
        }
    }
}

/// The palette in a hosting view of its own: typing in it lays out only the palette, not the
/// window's SwiftUI and every focusable view in it (a key took about 16 ms in the window's).
/// Closing it gives the focus back to the view that had it, when that view is still shown.
private struct SwitcherHost: NSViewRepresentable {
    let palette: SwitcherPalette

    final class Coordinator {
        weak var previous: NSResponder?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSHostingView<SwitcherPalette> {
        context.coordinator.previous = NSApp.keyWindow?.firstResponder
        let view = NSHostingView(rootView: palette)
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<SwitcherPalette>, context: Context) {}

    static func dismantleNSView(_ view: NSHostingView<SwitcherPalette>, coordinator: Coordinator) {
        guard let window = view.window else { return }
        if let previous = coordinator.previous as? NSView, previous.window === window, !previous.isDescendant(of: view) {
            window.makeFirstResponder(previous)
        } else if (window.firstResponder as? NSView)?.isDescendant(of: view) == true {
            window.makeFirstResponder(nil)
        }
    }
}

private struct SwitcherPalette: View {
    let model: AppModel
    let index: SwitcherIndex
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool

    private static let rowHeight: CGFloat = 40
    private static let listHeight: CGFloat = 360

    var body: some View {
        let results = index.results(matching: query)
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.08)
                    .contentShape(Rectangle())
                    .onTapGesture { model.switcherShown = false }
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    field(results)
                    if !results.isEmpty {
                        Divider()
                        list(results)
                    }
                }
                .frame(width: 560)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .padding(.top, max(24, geometry.size.height * 0.16))
            }
        }
        // Esc closes it wherever the focus is.
        .background { Button("") { model.switcherShown = false }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true) }
        .onAppear {
            focused = true
            FrameTimings.mark(FrameMarks.switcher)
        }
        // The field takes the focus once it is in the window: on appearing, it may not be yet.
        .task {
            await Task.yield()
            focused = true
        }
        .onChange(of: query) {
            highlight = 0
            FrameTimings.mark(FrameMarks.switcherResults)
        }
    }

    private func field(_ results: [SwitcherItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search agents and projects", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($focused)
                .onSubmit { if results.indices.contains(highlight) { model.open(results[highlight]) } }
                .onKeyPress(.downArrow) { highlight = SwitcherHighlight.moved(highlight, by: 1, count: results.count); return .handled }
                .onKeyPress(.upArrow) { highlight = SwitcherHighlight.moved(highlight, by: -1, count: results.count); return .handled }
                .onKeyPress(.escape) { model.switcherShown = false; return .handled }
                .onExitCommand { model.switcherShown = false }
                .accessibilityIdentifier("switcher-field")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func list(_ results: [SwitcherItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { offset, item in
                        row(item, highlighted: offset == highlight)
                            .id(item.id)
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(results.count) * Self.rowHeight + 12, Self.listHeight))
            .onChange(of: highlight) { _, row in
                if results.indices.contains(row) { proxy.scrollTo(results[row].id) }
            }
        }
    }

    private func row(_ item: SwitcherItem, highlighted: Bool) -> some View {
        Button { model.open(item) } label: {
            HStack(spacing: 10) {
                Group {
                    if item.kind == .project {
                        Image(systemName: Self.symbol(item)).font(.system(size: 15))
                    } else {
                        Text(item.emoji).font(.system(size: 20))
                    }
                }
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(.system(size: 11)).opacity(0.7).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(item.kind.label)
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.75)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.primary.opacity(0.08), in: Capsule())
            }
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), \(item.kind.label)")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
        .accessibilityIdentifier("switcher-result")
    }

    private static func symbol(_ item: SwitcherItem) -> String {
        if case .area = item.place { return "folder" }
        return "book.closed"
    }
}
