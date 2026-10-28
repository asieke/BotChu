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

/// Where the column's choices are kept: collapsed to the rail, and its width.
enum ConversationColumnSettings {
    static let collapsedKey = "conversationColumn.collapsed"
    static let widthKey = "conversationColumn.width"
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
    /// Cuts the dot out of what is behind it, with a ring of this colour (a rail tile's corner).
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

/// The bot's conversations as tabs beside its chat (#128): Home, then its open tasks, in a column,
/// or a rail of tiles when the owner collapsed it or the chat beside it would be too narrow to
/// read. Nothing while the bot has no open task, so its chat is as it was. A view of its own
/// beside the chat, kept as conversations change; only the chat is made anew for each.
struct ConversationSplit<Chat: View>: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ConversationColumnSettings.collapsedKey) private var collapsed = false
    @AppStorage(ConversationColumnSettings.widthKey) private var width = ConversationColumnLayout.width
    /// The width of the column and the chat together, which the column doesn't change.
    @State private var available: CGFloat?
    /// The tab with keyboard focus, if one has it.
    @FocusState private var focus: ChatTarget?
    let botID: UUID
    @ViewBuilder let chat: Chat

    var body: some View {
        HStack(spacing: 0) {
            if !model.openTasks(of: botID).isEmpty {
                let column = ConversationColumnLayout.clamped(width)
                Group {
                    if ConversationColumnLayout.showsRail(available: available ?? .infinity, column: column, collapsed: collapsed) {
                        ConversationRail(botID: botID, canExpand: collapsed, focus: $focus) { collapsed = false }
                    } else {
                        ConversationColumn(botID: botID, width: column, focus: $focus, resize: { width = ConversationColumnLayout.clamped($0) }) {
                            collapsed = true
                        }
                    }
                }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in move(press.key == .upArrow ? -1 : 1) }
            }
            chat
                .environment(\.composerTakesFocus, focus == nil)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .modifier(TaskTitlePrompts(botID: botID))
    }

    /// ↑ and ↓ move between the tabs while one has focus, without wrapping around.
    private func move(_ offset: Int) -> KeyPress.Result {
        let tabs = model.tabs(of: botID)
        guard focus != nil, let index = tabs.firstIndex(of: model.tab(of: botID)), tabs.indices.contains(index + offset) else { return .ignored }
        model.show(tabs[index + offset])
        focus = tabs[index + offset]
        return .handled
    }
}

/// The column: Home pinned at the top, then a heading with the tasks' count, New Task and
/// collapse, then the open tasks, which scroll. The rows are inset `rowInset` from both of its
/// edges, as the selected one's card shows (#144). Its trailing edge resizes it.
struct ConversationColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let botID: UUID
    let width: CGFloat
    let focus: FocusState<ChatTarget?>.Binding
    let resize: (CGFloat) -> Void
    let collapse: () -> Void
    @State private var hovered: ChatTarget?
    @State private var dragStart: CGFloat?

    /// How far a row is from the column's edges, on both sides.
    static let rowInset: CGFloat = 8

    var body: some View {
        let tasks = model.openTasks(of: botID).map { ChatTarget.task($0.id, of: botID) }
        let shown = model.tab(of: botID)
        VStack(alignment: .leading, spacing: 0) {
            ConversationRow(target: .home(botID), index: 0, selected: shown == .home(botID), hovered: hovered == .home(botID),
                            focus: focus) { hovered = $0 ? .home(botID) : (hovered == .home(botID) ? nil : hovered) }
                .padding(.top, 8)
                .padding(.horizontal, Self.rowInset)
            HStack(spacing: 6) {
                Text("Tasks")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.66)
                    .textCase(.uppercase)
                Text("\(tasks.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                Spacer(minLength: 0)
                ColumnButton(symbol: "plus", help: "New Task (⌘T)") { model.newTask(for: botID) }
                    .accessibilityIdentifier("conversation-new-task")
                ColumnButton(symbol: "chevron.left.2", help: "Collapse Tasks", action: collapse)
                    .accessibilityIdentifier("conversation-collapse")
            }
            .foregroundStyle(Palette.secondaryText)
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .frame(height: 36)
            .accessibilityElement(children: .contain)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(tasks.enumerated()), id: \.element) { index, target in
                        ConversationRow(target: target, index: index + 1, selected: shown == target, hovered: hovered == target,
                                        focus: focus) { hovered = $0 ? target : (hovered == target ? nil : hovered) }
                            .overlay(alignment: .top) {
                                // Between rows, inset to the text, hidden beside the selected and hovered ones.
                                let above = index > 0 ? tasks[index - 1] : nil
                                if let above, ![above, target].contains(shown), ![above, target].contains(where: { $0 == hovered }) {
                                    Rectangle().fill(Palette.rowDivider)
                                        .frame(height: 1)
                                        .padding(.leading, 32)
                                        .padding(.trailing, ConversationRow.padding.trailing)
                                        .offset(y: -1)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                .padding(.horizontal, Self.rowInset)
                .animation(reduceMotion ? .easeInOut(duration: 0.16) : .easeOut(duration: 0.2), value: tasks)
            }
            .scrollIndicators(.never)
        }
        // No wider a minimum than the rail's, so the window's narrowest stays the same whether the
        // column or the rail shows (it becomes the rail well before it would be squeezed).
        .frame(minWidth: ConversationColumnLayout.railWidth, idealWidth: width, maxWidth: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Palette.conversationColumn
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .trailing) { resizeHandle }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversations of \(model.bot(botID)?.name ?? "the bot")")
        .accessibilityIdentifier("conversation-column")
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

/// One tab of the column: a status dot (a close button in its place on hover, while no turn runs),
/// the repository and issue number, then for a task what it is about (its summary, #192), then what
/// it is doing and a time; Home's account, or what it is doing.
struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    /// Its place among Home and the open tasks, for its shortcut.
    let index: Int
    let selected: Bool
    let hovered: Bool
    /// Which tab has keyboard focus, which it shows with a violet edge.
    let focus: FocusState<ChatTarget?>.Binding
    let hover: (Bool) -> Void

    private static let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    /// Between the row's edges and its dot and texts: the time ends as far from the column's
    /// trailing edge as the dot starts from its leading one.
    static let padding = EdgeInsets(top: 9, leading: 8, bottom: 10, trailing: 8)

    var body: some View {
        if let tab = model.conversationTab(of: target) {
            let closable = target.taskID != nil && !model.isRunning(target)
            Button { model.show(target) } label: {
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(kind: tab.state.kind)
                        .frame(width: 16, height: 16)
                        .opacity(closable && hovered ? 0 : 1)
                    VStack(alignment: .leading, spacing: 3) {
                        ConversationTitle(tab: tab, selected: selected)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !tab.isHome {
                            Text(tab.label)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        ConversationDetail(tab: tab)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Self.padding)
                .foregroundStyle(selected ? Palette.text : Palette.pathText)
                .background { background }
                .contentShape(Self.shape)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused(focus, equals: target)
            .focusEffectDisabled()
            .overlay(alignment: .topLeading) {
                if closable && hovered {
                    CloseTabButton(target: target, title: tab.title)
                        .padding(.top, Self.padding.top)
                        .padding(.leading, Self.padding.leading)
                }
            }
            .onHover(perform: hover)
            .help(tab.help(shortcut: ConversationTab.shortcut(forTab: index)))
            .contextMenu {
                if let task = model.task(target) {
                    TaskMenu(target: target, task: task)
                } else {
                    Button("New Session") { model.newSession(target) }
                        .disabled(model.isRunning(target))
                }
            }
            .accessibilityLabel(tab.spoken(at: .now))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(target.taskID.map { "conversation-tab-\($0)" } ?? "conversation-tab-home")
        }
    }

    @ViewBuilder private var background: some View {
        let focused = focus.wrappedValue == target
        if selected {
            // A card with its edge all round, as the rail's selected tile is: the chat's real
            // background isn't the window's in dark mode, so a tab left open to it showed a seam (#144).
            Self.shape.fill(Palette.chat)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                .overlay { Self.shape.strokeBorder(focused ? Palette.violet : Color.primary.opacity(0.08), lineWidth: focused ? 2 : 0.5) }
        } else if hovered || focused {
            Self.shape.fill(Color.primary.opacity(0.045))
                .overlay { if focused { Self.shape.strokeBorder(Palette.violet, lineWidth: 2) } }
        }
    }
}

/// A tab's first, prominent line: a review's eye or a job's clock, the repository it works in (a
/// job's run: its job), then its issue's number (and its host) in the secondary colour.
struct ConversationTitle: View {
    let tab: ConversationTab
    let selected: Bool

    var body: some View {
        text.font(.system(size: 13, weight: selected ? .semibold : .medium))
    }

    private var text: Text {
        var text = Text("")
        if tab.isReview || tab.isJob {
            text = text + Text(Image(systemName: tab.isJob ? "clock.arrow.circlepath" : "eye")).foregroundStyle(Palette.secondaryText) + Text(" ")
        }
        text = text + Text(tab.name)
        if let number = tab.numberText {
            text = text + Text(" " + number).foregroundStyle(Palette.secondaryText).fontWeight(.medium).monospacedDigit()
        }
        if let machine = tab.machine {
            text = text + Text(" · " + machine).foregroundStyle(Palette.secondaryText).fontWeight(.regular)
        }
        return text
    }
}

/// A tab's last line: what it is doing (while idle, Home's account or "Idle") on the left, which
/// shortens first, and its time on the right, in tabular digits, never cut off. A running turn's
/// time ticks each second.
struct ConversationDetail: View {
    let tab: ConversationTab

    var body: some View {
        if tab.state.kind == .starting || tab.state.kind == .working {
            TimelineView(.periodic(from: .now, by: 1)) { context in line(now: context.date) }
        } else {
            TimelineView(.everyMinute) { context in line(now: context.date) }
        }
    }

    private func line(now: Date) -> some View {
        HStack(spacing: 6) {
            what
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let time = tab.state.time(at: now) {
                Text(time)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondaryText)
    }

    private var what: Text {
        switch tab.state {
        case .failed, .stopped: Text(tab.status).foregroundStyle(StatusLook.error.dot)
        case .needsInput: Text(tab.status).foregroundStyle(Palette.warning)
        case .news(let pullRequest?, _):
            Text("Finished · ") + Text("PR #\(pullRequest)").foregroundStyle(Palette.pathText).fontWeight(.medium)
        default: Text(tab.status)
        }
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

/// A 24-point borderless button in the column's heading or at the rail's foot.
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

/// The column collapsed: a 56-point rail of tiles, a house for Home, then each task's number (a
/// checklist for a brief), then New Task, with expand at the foot. A tile that isn't idle shows its
/// dot in its corner; hovering one shows its tab's two lines.
struct ConversationRail: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    /// The owner collapsed it; otherwise the window is too narrow for the column.
    let canExpand: Bool
    let focus: FocusState<ChatTarget?>.Binding
    let expand: () -> Void

    var body: some View {
        let tasks = model.openTasks(of: botID).map { ChatTarget.task($0.id, of: botID) }
        let shown = model.tab(of: botID)
        VStack(spacing: 4) {
            RailTile(target: .home(botID), index: 0, selected: shown == .home(botID), focus: focus)
            Rectangle().fill(Palette.hairline)
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(tasks.enumerated()), id: \.element) { index, target in
                        RailTile(target: target, index: index + 1, selected: shown == target, focus: focus)
                    }
                    Button { model.newTask(for: botID) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 40, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryText)
                    .help("New Task (⌘T)")
                    .accessibilityLabel("New Task")
                    .accessibilityIdentifier("conversation-new-task")
                }
            }
            .scrollIndicators(.never)
            ColumnButton(symbol: "chevron.right.2",
                         help: canExpand ? "Expand Tasks" : "Widen the window to show the tasks’ column", action: expand)
                .disabled(!canExpand)
                .accessibilityIdentifier("conversation-expand")
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: ConversationColumnLayout.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Palette.conversationColumn
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.hairline).frame(width: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversations of \(model.bot(botID)?.name ?? "the bot")")
        .accessibilityIdentifier("conversation-rail")
    }
}

/// A 40-point tile of the rail.
private struct RailTile: View {
    @Environment(AppModel.self) private var model
    let target: ChatTarget
    let index: Int
    let selected: Bool
    let focus: FocusState<ChatTarget?>.Binding
    @State private var hovering = false

    private static let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        if let tab = model.conversationTab(of: target) {
            Button { model.show(target) } label: {
                Group {
                    if tab.isHome {
                        Image(systemName: "house").font(.system(size: 14))
                    } else if tab.isJob {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 14))
                    } else if let number = tab.numberText {
                        Text(number).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    } else {
                        Image(systemName: "checklist").font(.system(size: 14))
                    }
                }
                .frame(width: 40, height: 40)
                .foregroundStyle(selected ? Palette.text : Palette.pathText)
                .background {
                    if selected {
                        Self.shape.fill(Palette.chat)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            .overlay { Self.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
                    } else if hovering {
                        Self.shape.fill(Color.primary.opacity(0.045))
                    }
                }
                .overlay {
                    if focus.wrappedValue == target { Self.shape.strokeBorder(Palette.violet, lineWidth: 2) }
                }
                .overlay(alignment: .topTrailing) {
                    if tab.state.kind != .idle {
                        StatusDot(kind: tab.state.kind, cutout: Palette.conversationColumn).padding(2)
                    }
                }
                .contentShape(Self.shape)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused(focus, equals: target)
            .focusEffectDisabled()
            .onHover { hovering = $0 }
            .help(tab.railHelp(at: .now, shortcut: ConversationTab.shortcut(forTab: index)))
            .contextMenu {
                if let task = model.task(target) { TaskMenu(target: target, task: task) }
            }
            .accessibilityLabel(tab.spoken(at: .now))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(target.taskID.map { "conversation-tile-\($0)" } ?? "conversation-tile-home")
        }
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
