import AppKit
import SwiftUI
import BotChuCore

/// The conversation column's colours (#128).
extension Palette {
    /// Its own quiet tone, between the bot list and the chat.
    static let conversationColumn = dynamic(0xF6F5F3, 0x18181B)
    /// An idle conversation's ring.
    static let idleRing = dynamic(0xB8B8BE, 0x5E5E66)
    /// An unread delivery in the Inbox's list.
    static let news = Color(nsColor: .systemBlue)
    /// A conversation waiting on the owner's answer to a Needs input delivery (#218).
    static let needsInput = dynamic(0xD97706, 0xFF9F0A)
    /// A turn that finished well since the conversation was last shown (#218).
    static let finished = dynamic(0x2F9E44, 0x32D74B)
    /// The window's background, which the selected tab and tile take, lifted off the column.
    static let chat = Color(nsColor: .windowBackgroundColor)
}

/// Where the Project Areas column's width is kept.
enum ProjectAreasColumnSettings {
    static let widthKey = "projectAreasColumn.width"
}

extension EnvironmentValues {
    /// Whether a chat's message box takes keyboard focus as it shows: not while the tabs beside it
    /// have it, so ↑ and ↓ go on moving between them.
    @Entry var composerTakesFocus = true
}

/// A conversation's state as a dot (#128, #218): a faint ring while idle, a violet ring while
/// preparing or starting, violet while working, an orange diamond while it waits on the owner's
/// input, a red dot when its last turn failed and a red square when the owner stopped it, and green
/// when a turn finished well since it was last shown. It holds still; when a turn ends it
/// crossfades to its new state and pops once. With Reduce Motion it only crossfades.
struct StatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: TabState.Kind
    var size: CGFloat = 8
    /// Cuts the dot out of what is behind it, with a ring of this colour (a bot row's dots).
    var cutout: Color?
    @State private var pops = 0

    var body: some View {
        let line: CGFloat = size >= 8 ? 1.5 : 1.25
        ZStack {
            switch kind {
            case .idle: Circle().strokeBorder(Palette.idleRing, lineWidth: line)
            case .preparing, .starting: Circle().strokeBorder(Palette.violet, lineWidth: line)
            case .working: Circle().fill(Palette.violet)
            case .news: Circle().fill(Palette.finished)
            case .failed: Circle().fill(StatusLook.error.dot)
            case .stopped: RoundedRectangle(cornerRadius: size * 0.2).fill(StatusLook.stopped.dot).padding(size * 0.08)
            case .needsInput:
                // A square on its corner, as wide as the other dots.
                RoundedRectangle(cornerRadius: size * 0.12).fill(Palette.needsInput)
                    .frame(width: size * 0.78, height: size * 0.78)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(width: size, height: size)
        .background { if let cutout { Circle().fill(cutout).padding(-2) } }
        .animation(.easeInOut(duration: 0.18), value: kind)
        .keyframeAnimator(initialValue: 1.0, trigger: pops) { dot, scale in
            dot.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(0.6, duration: 0.08)
                CubicKeyframe(1.6, duration: 0.14)
                SpringKeyframe(1, duration: 0.14, spring: .bouncy)
            }
        }
        .onChange(of: kind) { old, new in
            if new.endsTurn(from: old), !reduceMotion { pops += 1 }
        }
        .accessibilityHidden(true)
    }
}

/// The bot's conversations beside its chat: the Project Areas column (#399, #402), always shown.
/// A view of its own beside the chat, kept as conversations change; only the chat is made anew
/// for each.
struct ConversationSplit<Chat: View>: View {
    @Environment(AppModel.self) private var model
    /// The row with keyboard focus, if one has it.
    @FocusState private var focus: ChatTarget?
    let botID: UUID
    @ViewBuilder let chat: Chat

    var body: some View {
        HStack(spacing: 0) {
            ProjectAreasColumnHost(botID: botID, focus: $focus)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in move(press.key == .upArrow ? -1 : 1) }
            chat
                .environment(\.composerTakesFocus, focus == nil)
        }
        .modifier(TaskTitlePrompts(botID: botID))
    }

    /// ↑ and ↓ move between the rows while one has focus, without wrapping around.
    private func move(_ offset: Int) -> KeyPress.Result {
        let tabs = model.tabs(of: botID)
        guard focus != nil, let index = tabs.firstIndex(of: model.tab(of: botID)), tabs.indices.contains(index + offset) else { return .ignored }
        model.show(tabs[index + offset])
        focus = tabs[index + offset]
        return .handled
    }
}

/// Reads the owner's column width itself, not the split around the chat: a view whose body reads
/// an `@AppStorage` value is evaluated again at every UserDefaults write, whatever its key (#348).
private struct ProjectAreasColumnHost: View {
    @AppStorage(ProjectAreasColumnSettings.widthKey) private var width = ConversationColumnLayout.width
    let botID: UUID
    let focus: FocusState<ChatTarget?>.Binding

    var body: some View {
        // Compared by what it shows, not by its action, which is made anew each time and always sets
        // the same setting: evaluated again at a write, this leaves its rows alone (#348).
        ProjectAreasColumn(botID: botID, width: ConversationColumnLayout.clamped(width), focus: focus,
                           resize: { width = ConversationColumnLayout.clamped($0) })
            .equatable()
    }
}

extension ProjectAreasColumn: Equatable {
    static func == (a: Self, b: Self) -> Bool { a.botID == b.botID && a.width == b.width }
}

/// The column (#402): its heading with `+` to attach an area, Home pinned, then the bot's open
/// areas in the order it took them on, each with its tasks indented under it, then its other open
/// tasks and job runs, which scroll; at its foot, while it has hidden areas, a row that lists them.
/// The rows are inset `rowInset` from both of its edges, as the selected one's card shows (#144).
/// Its trailing edge resizes it.
struct ProjectAreasColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    let width: CGFloat
    let focus: FocusState<ChatTarget?>.Binding
    let resize: (CGFloat) -> Void
    @State private var hovered: ChatTarget?
    @State private var dragStart: CGFloat?
    @State private var showsHidden = false
    /// Attach Project Area's sheet in this window (#438).
    @State private var attach = AttachAreaPresenter()

    /// How far a row is from the column's edges, on both sides.
    static let rowInset: CGFloat = 8

    var body: some View {
        let layout = model.areaLayout(of: botID)
        let shown = model.tab(of: botID)
        VStack(alignment: .leading, spacing: 0) {
            heading
            row(.home(botID), index: 0, shown: shown)
                .padding(.horizontal, Self.rowInset)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, item in
                        row(.task(item.id, of: botID), index: index + 1, nested: item.nested, shown: shown)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .padding(.top, 1)
                .padding(.bottom, 8)
                .padding(.horizontal, Self.rowInset)
                .animation(reduceMotion ? .easeInOut(duration: 0.16) : .easeOut(duration: 0.2), value: layout.rows)
            }
            .scrollIndicators(.never)
            if !layout.hidden.isEmpty { hiddenAreas(layout.hidden) }
        }
        // Keep the owner's width and the labels readable. The window's minimum includes the
        // column, as it includes the chat and the other sidebars (#312).
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Palette.conversationColumn
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .trailing) { resizeHandle }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project Areas of \(model.bot(botID)?.name ?? "the bot")")
        .accessibilityIdentifier("conversation-column")
        .background { AttachAreaAnchor(presenter: attach, botID: botID) }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Text("Project Areas")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer(minLength: 0)
            // A specialist, or the remote queue, has no areas: only its Home.
            if model.bot(botID)?.canOwnTasks == true {
                ColumnButton(symbol: "plus", help: "Attach Project Area") { attach.present(botID: botID) }
                    .accessibilityIdentifier("conversation-new-task")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .frame(height: 40)
        .accessibilityElement(children: .contain)
    }

    private func row(_ target: ChatTarget, index: Int?, nested: Bool = false, hidden: Bool = false, shown: ChatTarget) -> some View {
        AreaColumnRow(target: target, index: index, nested: nested, hidden: hidden, selected: shown == target,
                      hovered: hovered == target, focus: focus) { hovered = $0 ? target : (hovered == target ? nil : hovered) }
    }

    /// "2 hidden", which opens the hidden areas' rows under it; pressing one shows it again.
    private func hiddenAreas(_ ids: [UUID]) -> some View {
        let shown = model.tab(of: botID)
        return VStack(alignment: .leading, spacing: 1) {
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.bottom, 4).accessibilityHidden(true)
            Button { showsHidden.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showsHidden ? 90 : 0))
                        .frame(width: 16)
                    Text("\(ids.count) hidden")
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.secondaryText)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Self.rowInset)
            .accessibilityLabel("\(ids.count) hidden")
            .accessibilityValue(showsHidden ? "shown" : "")
            .accessibilityIdentifier("conversation-hidden")
            if showsHidden {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(ids, id: \.self) { id in row(.task(id, of: botID), index: nil, hidden: true, shown: shown) }
                    }
                    .padding(.horizontal, Self.rowInset)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: CGFloat(min(ids.count, 6)) * 31)
            }
        }
        .padding(.bottom, 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsHidden)
    }

    /// The column's trailing edge: dragging it sets the column's width, from 200 to 320 points.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .offset(x: 3)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? width
                    dragStart = start
                    resize(start + drag.translation.width)
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityHidden(true)
    }
}

/// One row of the column, on one line: a mark for what it is (Home's house, a repository's
/// diamond, a folder, a job's clock, a review's eye; none for a task under its area), its name,
/// and its state's dot while it isn't idle. On hover an area shows its menu's button, and a task
/// that runs nothing its close button. An area's row drags onto a bot in the sidebar to move it.
struct AreaColumnRow: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    /// Its place among Home and the rows, for its shortcut; nil for a hidden area.
    let index: Int?
    let nested: Bool
    /// A hidden area's, under "n hidden": pressing it shows the area again.
    let hidden: Bool
    let selected: Bool
    let hovered: Bool
    /// Which row has keyboard focus, which it shows with a violet edge.
    let focus: FocusState<ChatTarget?>.Binding
    let hover: (Bool) -> Void

    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        if let tab = model.conversationTab(of: target) {
            let isArea = tab.area != nil
            let accessory = hovered && !hidden && (isArea || (!tab.isHome && !model.isRunning(target)))
            Button { if hidden { model.unhideArea(target) } else { model.show(target) } } label: {
                HStack(spacing: 8) {
                    if !nested {
                        mark(tab)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.secondaryText)
                            .frame(width: 16)
                    }
                    title(tab)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if tab.state.kind != .idle {
                        StatusDot(kind: tab.state.kind)
                            .opacity(accessory ? 0 : 1)
                    }
                }
                .padding(.vertical, 6)
                .padding(.leading, nested ? 32 : 8)
                .padding(.trailing, 8)
                .frame(minHeight: 30)
                .foregroundStyle(selected ? Palette.text : hidden ? Palette.secondaryText : Palette.pathText)
                .background { background }
                .contentShape(Self.shape)
            }
            .buttonStyle(.plain)
            .focusable(!hidden)
            .focused(focus, equals: target)
            .focusEffectDisabled()
            .overlay(alignment: .trailing) {
                if accessory {
                    Group {
                        if isArea { AreaMenuButton(target: target, title: tab.title) }
                        else { CloseTabButton(target: target, title: tab.title) }
                    }
                    .padding(.trailing, 6)
                }
            }
            .onHover(perform: hover)
            .help(tab.help(shortcut: index.flatMap(ConversationTab.shortcut(forTab:))))
            .contextMenu {
                if hidden {
                    Button("Show") { model.unhideArea(target) }
                } else if isArea {
                    AreaMenu(target: target)
                } else if let task = model.task(target) {
                    TaskMenu(target: target, task: task)
                } else {
                    Button("New Session") { model.newSession(target) }
                        .disabled(model.isRunning(target))
                }
            }
            .modifier(AreaDragSource(target: isArea && !hidden ? target : nil))
            .accessibilityLabel((hidden ? "Hidden, " : "") + tab.spoken(at: .now))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(target.taskID.map { "conversation-tab-\($0)" } ?? "conversation-tab-home")
            .onAppear { if let id = target.taskID { FrameTimings.mark(FrameMarks.tab(id)) } }
        }
    }

    @ViewBuilder private func mark(_ tab: ConversationTab) -> some View {
        switch tab.area {
        case .repo: Image(systemName: "diamond")
        case .folder: Image(systemName: "folder")
        case nil:
            if tab.isHome { Image(systemName: "house") }
            else if tab.isJob { Image(systemName: "clock.arrow.circlepath") }
            else if tab.isReview { Image(systemName: "eye") }
            else { Image(systemName: "checklist") }
        }
    }

    /// An area's or Home's name; a task's repository and number, then its branch (else what it is
    /// about), quieter, and smaller under its area.
    private func title(_ tab: ConversationTab) -> Text {
        let weight: Font.Weight = selected ? .semibold : .regular
        guard tab.area == nil, !tab.isHome else { return Text(tab.name).font(.system(size: 13, weight: weight)) }
        let branch = model.task(target)?.branch ?? ""
        let detail = branch.isEmpty || tab.isJob ? tab.label : branch
        var text = Text(tab.name)
        if let number = tab.numberText { text = text + Text(" " + number).monospacedDigit() }
        if let machine = tab.machine { text = text + Text(" · " + machine) }
        text = text + Text(" · " + detail).foregroundStyle(Palette.secondaryText)
        return text.font(.system(size: nested ? 11.5 : 12.5, weight: weight))
    }

    @ViewBuilder private var background: some View {
        let focused = focus.wrappedValue == target
        if selected {
            // A card with its edge all round: the chat's real background isn't the window's in dark
            // mode, so a row left open to it showed a seam (#144).
            Self.shape.fill(Palette.chat)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                .overlay { Self.shape.strokeBorder(focused ? Palette.violet : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 0.5) }
        } else if hovered || focused {
            Self.shape.fill(Color.primary.opacity(0.045))
                .overlay { if focused { Self.shape.strokeBorder(Palette.violet, lineWidth: 2) } }
        }
    }
}

/// An area's row gives a drag that a bot's row in the sidebar takes, to move the area there.
private struct AreaDragSource: ViewModifier {
    let target: ChatTarget?

    func body(content: Content) -> some View {
        if let target, let id = target.taskID {
            content.onDrag { AreaDrag.provider(botID: target.botID, areaID: id) }
        } else {
            content
        }
    }
}

/// An area's menu (#402), in its row's context menu and its hover button: Move to another bot,
/// Hide, its folder in Finder and Terminal, and New Session.
struct AreaMenu: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget

    var body: some View {
        Menu("Move to") {
            ForEach(model.areaMoveTargets(of: target)) { bot in
                Button(bot.name) { model.moveArea(target, to: bot.id) }
                    .disabled(model.areaMoveProblem(target, to: bot.id) != nil)
            }
        }
        Button("Hide") { model.hideArea(target) }
            .disabled(model.isRunning(target))
        Divider()
        Button("Reveal in Finder") { model.revealWorktree(target) }
        Button("Open in Terminal") { model.openWorktreeInTerminal(target) }
        Divider()
        Button("New Session") { model.newSession(target) }
            .disabled(model.isRunning(target))
    }
}

/// In an area's dot's place on hover: its menu.
private struct AreaMenuButton: View {
    let target: ChatTarget
    let title: String

    var body: some View {
        Menu { AreaMenu(target: target) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Palette.secondaryText)
        .accessibilityLabel("Actions for \(title)")
    }
}

/// In a task tab's dot's place on hover: closes the task (Home's status lists it to reopen).
private struct CloseTabButton: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let title: String
    @State private var hovering = false

    var body: some View {
        Button { model.closeTask(target) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Palette.text : Palette.secondaryText)
        .onHover { hovering = $0 }
        .help("Close the task; reopen it from Home’s status")
        .accessibilityLabel("Close \(title)")
        .accessibilityIdentifier("conversation-close-\(target.taskID?.uuidString ?? "")")
    }
}

/// A 24-point borderless button in the column's heading.
private struct ColumnButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Palette.text : Palette.secondaryText)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A task's menu, in its tab and its tile: its issue or pull request (a job's run: the run in its
/// job's history), branch, folder and Terminal, then Rename… and Regenerate Title (#236), then New
/// Session and Close Task.
struct TaskMenu: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let task: BotTask

    var body: some View {
        if let origin = task.jobRun {
            Button("Show Run in Job History") { model.jobs.showHistory(origin.jobID, run: origin.runID) }
                .disabled(model.jobs.job(origin.jobID) == nil)
        }
        if let work = task.work {
            Link("Open \(work.isPullRequest ? "Pull Request" : "Issue") #\(work.number)", destination: work.url)
        }
        if let number = task.pullRequest, let url = task.pullRequestURL, task.work?.isPullRequest != true {
            Link("Open Pull Request #\(number)", destination: url)
        }
        if !task.branch.isEmpty {
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.branch, forType: .string)
            }
        }
        if !task.isRemote {
            Button("Show Task Folder in Finder") { model.revealWorktree(target) }
                .disabled(task.folder == nil)
        }
        Button("Open Task in Terminal") { model.openWorktreeInTerminal(target) }
            .disabled(task.folder == nil)
        Divider()
        TaskTitleItems(target: target)
        Divider()
        Button("New Session") { model.newSession(target) }
            .disabled(model.isRunning(target))
        Button("Close Task") { model.closeTask(target) }
            .disabled(model.isRunning(target))
    }
}
