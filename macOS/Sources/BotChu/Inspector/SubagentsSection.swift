import AppKit
import SwiftUI
import BotChuCore

/// The Sub-agents tab (#194): a compact row for each run a conversation started, with the runs it
/// delegated to beneath it. Trees that ended without a failure fold into Finished at once; a row
/// opens that run's details in place of the list, and Back comes back to where the list was.
struct SubagentsInspectorContent: View {
    let target: ChatTarget
    var includeBotTasksOverview = false
    /// Where the tab is, for tests to drive; else its own.
    var state: SubagentTabState?
    /// The checkout whose worktrees its rows and Worktrees read (#405, #431): an area's or a task's.
    var checkout: String?

    var body: some View {
        // One per conversation: Home's inspector stays as the bot changes, and where one bot's tab
        // was shouldn't carry over to the next.
        SubagentsTab(target: target, includesTasks: includeBotTasksOverview, state: state, checkout: checkout).id(target)
    }
}

/// Where a conversation's Sub-agents tab is, and what its reader opened, folded and asked to stop.
@MainActor @Observable
final class SubagentTabState {
    let target: ChatTarget
    var navigation = SubagentNavigation()
    /// Parents the reader opened or folded, and those that started open; the rest start folded.
    var opened: [UUID: Bool] = [:]
    /// Finished, in each list (Home's own and each of its tasks'): folded until the reader opens it.
    var showsFinished: [ChatTarget: Bool] = [:]
    /// Runs asked to stop, until their process exits.
    var stopping: Set<UUID> = []
    /// The row Back came back to, tinted for a moment.
    var highlighted: UUID?
    var focusRequest: SubagentAnchor?
    /// Each run's transcript: open or folded, and the first item shown.
    var transcriptOpen: [UUID: Bool] = [:]
    var transcriptStart: [UUID: Int] = [:]
    var toolsOpen: Set<UUID> = []
    var briefsOpen: Set<UUID> = []
    /// Sections the reader folded: Tasks, a run's Sub-agents, Handoff…
    var folded: Set<String> = []
    /// Where each row and block is in the visible part of the scroll view.
    @ObservationIgnored var frames: [SubagentAnchor: CGRect] = [:]
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var scroll: ScrollViewProxy?
    @ObservationIgnored var area: InspectorScrollArea?
    @ObservationIgnored var reduceMotion = false
    /// The conversation's checkout's worktrees, when it has one: where each run works (#431).
    @ObservationIgnored var worktrees: WorktreeMonitor?
    @ObservationIgnored private var highlightToken = 0

    init(target: ChatTarget) { self.target = target }

    /// The list the tab shows when no details are: the conversation's, or one of Home's tasks'.
    var scope: ChatTarget {
        if case .task(let id)? = navigation.path.last(where: { if case .task = $0 { true } else { false } }) {
            return .task(id, of: target.botID)
        }
        return target
    }

    func overview(_ scope: ChatTarget) -> SubagentOverview {
        SubagentOverview(runs: model?.delegation.records[scope] ?? [])
    }

    var isShowingRun: Bool {
        if case .run? = navigation.top { return true }
        return false
    }

    /// Whether a section is open: each starts open, and stays as the reader leaves it.
    func section(_ key: String) -> Binding<Bool> {
        Binding(get: { !self.folded.contains(key) }, set: { if $0 { self.folded.remove(key) } else { self.folded.insert(key) } })
    }

    func isStopping(_ run: SubagentRun) -> Bool { run.phase.isActive && stopping.contains(run.id) }

    /// Where a run works, with its worktree's changes and pull request as last read.
    func workplace(of run: SubagentRun) -> SubagentWorkplace? {
        SubagentWorkplace.of(run, rows: worktrees?.rows ?? [], pullRequests: worktrees?.pullRequests ?? [:])
    }

    func stop(_ id: UUID) {
        stopping.insert(id)
        model?.delegation.stop(id)
    }

    /// Where the reader is: the topmost block whole in view, outside `excluded`, and how far down it is.
    func place(opened: UUID? = nil, excluding excluded: (SubagentAnchor) -> Bool = { _ in false }) -> SubagentNavigation.Mark {
        let height = area?.viewport.height ?? 0
        let top = frames.filter { $0.value.minY >= -0.5 && $0.value.minY < height && !excluded($0.key) }
            .min { $0.value.minY < $1.value.minY }
        guard let top, height > 0 else { return SubagentNavigation.Mark(opened: opened) }
        // A unit point lines up the same point of the block and of the view.
        let room = height - top.value.height
        let fraction = room > 0 ? min(1, max(0, Double(top.value.minY / room))) : 0
        return SubagentNavigation.Mark(opened: opened, anchor: top.key, fraction: fraction)
    }

    /// Opens a row's details or a task's list, remembering where the reader was.
    func push(_ route: SubagentNavigation.Route, opened: UUID?) {
        let overview = overview(scope)
        let mark = place(opened: opened) { anchor in
            guard let opened, case .run(let id) = anchor else { return false }
            return overview.isInTree(id, of: overview.root(of: opened) ?? opened)
        }
        navigation.push(route, from: mark)
        scrollToTop()
    }

    /// The chat's Open: that run's details, nested or finished, from wherever the tab was.
    func open(_ id: UUID) {
        navigation.open(id, from: navigation.path.isEmpty ? place() : nil)
        scrollToTop()
    }

    func back() {
        guard !navigation.path.isEmpty else { return }
        let mark = navigation.back()
        // A run that ended meanwhile moved into Finished: open it to show the row.
        if !isShowingRun, let opened = mark?.opened, overview(scope).isFinished(opened) {
            showsFinished[scope] = true
        }
        DispatchQueue.main.async { [self] in
            restore(mark)
            guard let opened = mark?.opened else { return }
            // Then only as far as it takes to bring the row whole into view.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                let height = area?.viewport.height ?? 0
                if let frame = frames[.run(opened)], frame.minY < 0 || frame.maxY > height {
                    scroll?.scrollTo(SubagentAnchor.run(opened))
                } else if frames[.run(opened)] == nil {
                    scroll?.scrollTo(SubagentAnchor.run(opened))
                }
                focusRequest = .run(opened)
                highlight(opened)
            }
        }
    }

    func restore(_ mark: SubagentNavigation.Mark?) {
        if let anchor = mark?.anchor {
            scroll?.scrollTo(anchor, anchor: UnitPoint(x: 0, y: mark?.fraction ?? 0))
        } else {
            scroll?.scrollTo(SubagentAnchor.block("top"), anchor: .top)
        }
    }

    /// Keeps the block on top where it was while what's above it changes (a run moving into
    /// Finished, a result appearing above the transcript). Nothing moves while the view is at the top.
    func keepPlace(excluding excluded: @escaping (SubagentAnchor) -> Bool = { _ in false }) {
        if let top = frames[.block("top")], top.minY >= -0.5 { return }
        let mark = place(excluding: excluded)
        guard mark.anchor != nil else { return }
        DispatchQueue.main.async { [self] in restore(mark) }
    }

    private func scrollToTop() {
        DispatchQueue.main.async { [self] in
            scroll?.scrollTo(SubagentAnchor.block("top"), anchor: .top)
            focusRequest = .block("top")
        }
    }

    private func highlight(_ id: UUID) {
        highlightToken += 1
        let token = highlightToken
        highlighted = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            guard highlightToken == token else { return }
            if reduceMotion { highlighted = nil } else { withAnimation(.easeOut(duration: 0.4)) { highlighted = nil } }
        }
    }
}

private struct SubagentsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inspectorScroll) private var scroll
    @Environment(\.inspectorArea) private var area
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: ChatTarget
    let includesTasks: Bool
    @State private var tab: SubagentTabState
    @State private var owner = UUID()
    @FocusState private var focus: SubagentAnchor?

    init(target: ChatTarget, includesTasks: Bool, state: SubagentTabState?, checkout: String? = nil) {
        self.target = target
        self.includesTasks = includesTasks
        let tab = state ?? SubagentTabState(target: target)
        if let checkout, tab.worktrees?.checkout != checkout { tab.worktrees = WorktreeMonitor.of(checkout) }
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch tab.navigation.top {
            case nil:
                SubagentList(scope: target, includesTasks: includesTasks, tab: tab, focus: $focus)
                if let monitor = tab.worktrees { WorktreesSection(target: target, monitor: monitor) }
            case .task(let id):
                SubagentList(scope: .task(id, of: target.botID), includesTasks: false, tab: tab, focus: $focus)
            case .run(let id):
                SubagentDetail(runID: id, tab: tab, focus: $focus)
            }
            if let error = model.delegation.error {
                Text(error).font(.caption).foregroundStyle(failureRed).textSelection(.enabled)
            }
        }
        .frame(minWidth: 0, idealWidth: 240, maxWidth: .infinity, alignment: .leading)
        // Read whatever shows, list or details, so rows say where runs work while Worktrees is hidden.
        .background { if let monitor = tab.worktrees { WorktreeRefresh(target: target, monitor: monitor) } }
        .accessibilityIdentifier("subagents-inspector")
        .onExitCommand { tab.back() }
        .onAppear {
            tab.model = model
            tab.scroll = scroll
            tab.area = area
            tab.reduceMotion = reduceMotion
        }
        .onChange(of: reduceMotion) { _, reduce in tab.reduceMotion = reduce }
        .onChange(of: tab.navigation.path.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { area?.unpin(owner: owner) } else { area?.pin(SubagentBar(tab: tab).environment(model), owner: owner) }
        }
        .onDisappear { area?.unpin(owner: owner) }
        .onChange(of: tab.focusRequest) { _, request in
            guard let request else { return }
            focus = request
            tab.focusRequest = nil
        }
        // The chat's Open on a sub-agent card: that run's details, wherever it is in the tree.
        .onChange(of: SubagentFocus.shared.ticket, initial: true) { _, _ in
            tab.model = model
            tab.scroll = scroll
            tab.area = area
            guard let id = SubagentFocus.shared.take(from: model.delegation.records[target] ?? []) else { return }
            tab.open(id)
        }
    }
}

// MARK: The list

private struct SubagentList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scope: ChatTarget
    let includesTasks: Bool
    let tab: SubagentTabState
    var focus: FocusState<SubagentAnchor?>.Binding

    var body: some View {
        let runs = model.delegation.records[scope] ?? []
        let overview = SubagentOverview(runs: runs)
        let tasks = includesTasks ? (model.tasks[scope.botID] ?? []).filter { !(model.delegation.records[.task($0.id, of: scope.botID)] ?? []).isEmpty } : []
        VStack(alignment: .leading, spacing: 14) {
            if runs.isEmpty && tasks.isEmpty {
                Text("No sub-agents").font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
            }
            ForEach(overview.visible) { group in
                SubagentGroup(group: group, caption: !group.isUnderWay, overview: overview, scope: scope, tab: tab, focus: focus)
            }
            if !overview.finished.isEmpty {
                SubagentDisclosure("Finished", trailing: "\(overview.finishedCount)", expanded: Binding(
                    get: { tab.showsFinished[scope] ?? false }, set: { tab.showsFinished[scope] = $0 })) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(overview.finished) { group in
                            SubagentGroup(group: group, caption: true, overview: overview, scope: scope, tab: tab, focus: focus)
                        }
                    }
                }
                .id(SubagentAnchor.block("finished"))
                .modifier(Placed(anchor: .block("finished"), tab: tab))
            }
            if !tasks.isEmpty {
                SubagentDisclosure("Tasks", expanded: tab.section("tasks")) {
                    InspectorCard {
                        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                            SubagentTaskRow(task: task, botID: scope.botID, first: index == 0, tab: tab)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            Color.clear.frame(height: 1).id(SubagentAnchor.block("top")).modifier(Placed(anchor: .block("top"), tab: tab))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: overview.finished.map(\.id))
        // A tree moving into Finished above the reader leaves the rest where it was.
        .onChange(of: overview.visible.flatMap(\.roots).map(\.id)) { old, new in
            let moved = Set(old).subtracting(new)
            guard !moved.isEmpty else { return }
            tab.keepPlace { anchor in
                guard case .run(let id) = anchor else { return false }
                return moved.contains { overview.isInTree(id, of: $0) }
            }
        }
    }
}

/// The runs one turn started: under a caption, unless it's the turn under way, in one card.
private struct SubagentGroup: View {
    let group: SubagentOverview.Group
    let caption: Bool
    let overview: SubagentOverview
    let scope: ChatTarget
    let tab: SubagentTabState
    var focus: FocusState<SubagentAnchor?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if caption {
                Text(SubagentOverview.caption(group))
                    .font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 4)
            }
            InspectorCard {
                ForEach(Array(group.roots.enumerated()), id: \.element.id) { index, run in
                    SubagentBranch(run: run, depth: 0, first: index == 0, ancestry: [], overview: overview, scope: scope, tab: tab, focus: focus)
                }
            }
        }
    }
}

/// A run's row and, while it's open, the runs it delegated to beneath it.
private struct SubagentBranch: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let depth: Int
    let first: Bool
    let ancestry: Set<UUID>
    let overview: SubagentOverview
    let scope: ChatTarget
    let tab: SubagentTabState
    var focus: FocusState<SubagentAnchor?>.Binding

    var body: some View {
        let children = model.delegation.children(of: run.id, in: scope)
        let failed = overview.failedBelow(run.id)
        // Parents with work under way or a failure below start open; the reader's choice sticks.
        let startsOpen = run.phase.isActive || children.contains { $0.phase.isActive } || failed > 0
        let open = Binding(get: { tab.opened[run.id] ?? startsOpen }, set: { tab.opened[run.id] = $0 })
        VStack(alignment: .leading, spacing: 0) {
            SubagentRow(run: run, depth: depth, first: first, hasChildren: !children.isEmpty, open: open,
                        failedBelow: failed, tab: tab, focus: focus) {
                tab.push(.run(run.id), opened: run.id)
            }
            if open.wrappedValue, !ancestry.contains(run.id) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        SubagentBranch(run: child, depth: depth + 1, first: false, ancestry: ancestry.union([run.id]),
                                       overview: overview, scope: scope, tab: tab, focus: focus)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // A hairline under the parent's chevron.
                    Rectangle().fill(Palette.hairline).frame(width: 1)
                        .padding(.leading, 4 + 18 * CGFloat(depth) + 7)
                }
            }
        }
        .onAppear {
            if tab.opened[run.id] == nil, startsOpen, !children.isEmpty { tab.opened[run.id] = true }
        }
        .onChange(of: startsOpen && !children.isEmpty) { _, opens in
            if opens, tab.opened[run.id] == nil { tab.opened[run.id] = true }
        }
    }
}

/// A run in a list: its title, its bot, and its state in a word and a time. It never expands into
/// details; it opens them.
private struct SubagentRow: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let depth: Int
    let first: Bool
    let hasChildren: Bool
    @Binding var open: Bool
    let failedBelow: Int
    let tab: SubagentTabState
    var focus: FocusState<SubagentAnchor?>.Binding
    let action: () -> Void
    @State private var textWidth: CGFloat = 300

    var body: some View {
        let _ = SubagentDiagnostics.didEvaluateRow?(run.id)
        let state = SubagentRowState(run, activity: model.delegation.states[run.id]?.activity, stopping: tab.isStopping(run))
        let place = tab.workplace(of: run)
        HStack(alignment: .top, spacing: 0) {
            Button { open.toggle() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondaryText)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)
            .accessibilityHidden(!hasChildren)
            .accessibilityLabel(open ? "Fold \(run.title)" : "Show what \(run.title) delegated")
            HStack(alignment: .top, spacing: 0) {
                SubagentStateSymbol(kind: state.kind)
                    .frame(width: 16, height: 16)
                    .padding(.leading, 6)
                    .padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    SubagentMetaLine(run: run, state: state, failedBelow: open ? 0 : failedBelow, width: textWidth)
                    if let place { SubagentWorkplaceLine(place: place, run: run).padding(.top, 1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        }
        .padding(.vertical, 7)
        .padding(.trailing, 10)
        .padding(.leading, 4 + 18 * CGFloat(depth))
        .frame(minHeight: 44, alignment: .top)
        .background {
            if tab.highlighted == run.id { RoundedRectangle(cornerRadius: 9).fill(Palette.violet.opacity(0.16)).padding(1) }
        }
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(Palette.rowDivider).frame(height: 1).padding(.leading, 48 + 18 * CGFloat(depth))
            }
        }
        .overlay {
            if focus.wrappedValue == .run(run.id) {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.violet, lineWidth: 2).padding(1).allowsHitTesting(false)
            }
        }
        .focusable()
        .focused(focus, equals: .run(run.id))
        .focusEffectDisabled()
        .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow]) { press in
            switch press.key {
            case .rightArrow where hasChildren: open = true
            case .leftArrow where hasChildren: open = false
            case .return, .space: action()
            default: return .ignored
            }
            return .handled
        }
        .id(SubagentAnchor.run(run.id))
        .modifier(Placed(anchor: .run(run.id), tab: tab))
        .help("\(run.title)\n\(run.targetBotName) · \(state.word)")
        .contextMenu { SubagentMenu(run: run, tab: tab, open: action) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.title), \(run.targetBotName), \(state.word)" + (failedBelow > 0 && !open ? ", \(failedBelow) failed" : "")
                            + (place.map { ", \(SubagentWorkplaceLine.spoken($0))" } ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityIdentifier("subagent-\(run.id.uuidString)")
    }
}

/// The row's second line. At narrow widths it gives way in a fixed order: the bot's name truncates,
/// then goes, then its avatar, and at last the time goes under the word; both stay whole.
private struct SubagentMetaLine: View {
    let run: SubagentRun
    let state: SubagentRowState
    let failedBelow: Int
    let width: CGFloat

    var body: some View {
        Group {
            if width >= 250 {
                HStack(spacing: 5) {
                    SubagentAvatar(run: run, size: 14)
                    Text(run.targetBotName).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                    Text("·")
                    word.fixedSize()
                    Spacer(minLength: 6)
                    SubagentTime(state: state)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        SubagentAvatar(run: run, size: 14)
                        word.fixedSize()
                        Spacer(minLength: 6)
                        SubagentTime(state: state)
                    }
                    HStack(spacing: 5) {
                        word.fixedSize()
                        Spacer(minLength: 6)
                        SubagentTime(state: state)
                    }
                    // Deep rows at the narrowest widths, past an hour: the time goes under the word.
                    VStack(alignment: .leading, spacing: 1) {
                        word
                        SubagentTime(state: state)
                    }
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.secondaryText)
    }

    private var word: some View {
        HStack(spacing: 0) {
            Text(state.word).foregroundStyle(state.kind == .failed ? failureRed : Palette.secondaryText)
            if failedBelow > 0 {
                Text(" · \(failedBelow) failed").foregroundStyle(failureRed)
            }
        }
        .lineLimit(1)
    }
}

private struct SubagentAvatar: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let size: CGFloat

    var body: some View {
        BotAvatar(bot: model.bot(run.targetBotID) ?? Bot(id: run.targetBotID, name: run.targetBotName, emoji: run.targetBotEmoji,
                                                          workspace: run.targetBotWorkspace, appearance: run.targetBotAppearance),
                  size: size)
    }
}

/// How long a run has taken: ticking while under way (`m:ss`), its duration once ended (`9m 51s`).
private struct SubagentTime: View {
    let state: SubagentRowState

    var body: some View {
        Group {
            if let ended = state.ended {
                Text(ActivityStyle.duration(ended.timeIntervalSince(state.since)) ?? "0s")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(BotStatus.formatElapsed(from: state.since, to: max(timeline.date, Date())))
                }
            }
        }
        .monospacedDigit()
        .fixedSize()
    }
}

private struct SubagentStateSymbol: View {
    let kind: SubagentRowState.Kind

    var body: some View {
        switch kind {
        case .running: ActivitySpinner(size: 13, tint: Palette.violet)
        case .stopping: Image(systemName: "rays").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondaryText)
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(failureRed)
        default: Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Palette.secondaryText)
        }
    }

    private var symbol: String {
        switch kind {
        case .queued: "clock"
        case .preparing: "circle.dashed"
        case .stopped: "stop.circle"
        case .interrupted: "pause.circle"
        case .paused: "hourglass"
        default: "checkmark.circle"
        }
    }
}

private struct SubagentMenu: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let tab: SubagentTabState
    let open: () -> Void

    var body: some View {
        Button("Open", action: open)
        if let handoff = run.handoffOutput, !handoff.isEmpty, !run.phase.isActive {
            Button("Copy Handoff") { copyToPasteboard(handoff) }
        }
        if run.phase == .failed, let error = run.errorMessage, !error.isEmpty {
            Button("Copy Error") { copyToPasteboard(error) }
        }
        Button("Copy Brief") { copyToPasteboard(run.brief) }
        Divider()
        if run.phase.isActive {
            Button(tab.isStopping(run) ? "Stopping…" : "Stop") { tab.stop(run.id) }.disabled(tab.isStopping(run))
        } else {
            if run.isResumable {
                Button("Resume") { model.delegation.resumeByOwner(run.id) }.disabled(model.delegation.isResuming(run.id))
            }
            Button("Clear Run") { model.delegation.clear(run.id) }
                .disabled(model.delegation.children(of: run.id).contains { $0.phase.isActive })
        }
    }
}

/// Resume for a run that can be relaunched (#368): with its brief, session and worktree. Why the
/// last Resume didn't relaunch it shows beside it until the next.
private struct SubagentResumeRow: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun

    var body: some View {
        if run.isResumable {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SubagentResumeButton(run: run)
                if let problem = model.delegation.resumeProblems[run.id] {
                    Text(problem).font(.system(size: 12)).foregroundStyle(failureRed).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SubagentResumeButton: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun

    var body: some View {
        let resuming = model.delegation.isResuming(run.id)
        Button { model.delegation.resumeByOwner(run.id) } label: {
            Label(resuming ? "Resuming…" : "Resume", systemImage: "play.fill")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.button))
                .foregroundStyle(Palette.buttonText)
                .opacity(resuming ? 0.55 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resuming)
        .accessibilityIdentifier("subagent-resume-\(run.id.uuidString)")
    }
}

/// System red (`ActivityStyle.failure`), as fixed colors: the sidebar's vibrancy draws
/// `Color.red` in black. Light uses its higher-contrast shade, readable at 11.5 pt on white.
private let failureRed = Palette.dynamic(0xD70015, 0xFF453A)

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// One of Home's tasks with runs of its own: whether one is under way or failed, and its list.
private struct SubagentTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: BotTask
    let botID: UUID
    let first: Bool
    let tab: SubagentTabState

    var body: some View {
        let runs = model.delegation.records[.task(task.id, of: botID)] ?? []
        Button { tab.push(.task(task.id), opened: nil) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 12)).foregroundStyle(Palette.secondaryText).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    if !task.repo.isEmpty {
                        Text(task.repo).font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if runs.contains(where: { $0.phase.isActive }) {
                    ActivitySpinner(size: 12, tint: Palette.violet)
                } else if runs.contains(where: { $0.phase == .failed }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(failureRed).accessibilityLabel("Failed")
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondaryText)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 10))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Palette.rowDivider).frame(height: 1).padding(.leading, 36) }
        }
    }
}

// MARK: The details

/// What Back says and Stop: pinned above the details as they scroll.
private struct SubagentBar: View {
    @Environment(AppModel.self) private var model
    let tab: SubagentTabState

    var body: some View {
        HStack(spacing: 8) {
            Button { tab.back() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(destination).lineLimit(1)
                }
                .font(.system(size: 12.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondaryText)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to \(destination) (⌘[)")
            .accessibilityLabel("Back to \(destination)")
            Spacer(minLength: 8)
            if case .run(let id)? = tab.navigation.top, let run = model.delegation.run(id), run.phase.isActive {
                let stopping = tab.isStopping(run)
                Button { tab.stop(id) } label: {
                    Label(stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.button))
                        .foregroundStyle(Palette.buttonText)
                        .opacity(stopping ? 0.55 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(stopping)
                .help("Stop this sub-agent and the runs it delegated to")
            }
        }
        .frame(minHeight: 26)
        .onExitCommand { tab.back() }
    }

    private var destination: String {
        let path = tab.navigation.path
        guard path.count > 1 else { return "Sub-agents" }
        switch path[path.count - 2] {
        case .run(let id): return model.delegation.run(id)?.title ?? "Sub-agent"
        case .task(let id): return model.task(.task(id, of: tab.target.botID))?.title ?? "Task"
        }
    }
}

private struct SubagentDetail: View {
    @Environment(AppModel.self) private var model
    let runID: UUID
    let tab: SubagentTabState
    var focus: FocusState<SubagentAnchor?>.Binding

    var body: some View {
        if let run = model.delegation.run(runID) {
            SubagentDetailContent(run: run, tab: tab, focus: focus)
        } else {
            // Cleared meanwhile: back to where the reader came from.
            Color.clear.frame(height: 0).onAppear { tab.navigation.prune { route in
                if case .run(let id) = route { return model.delegation.run(id) != nil }
                return true
            } }
        }
    }
}

private struct SubagentDetailContent: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let tab: SubagentTabState
    var focus: FocusState<SubagentAnchor?>.Binding

    var body: some View {
        let _ = SubagentDiagnostics.didEvaluateDetails?(run.id)
        let state = SubagentRowState(run, activity: model.delegation.states[run.id]?.activity, stopping: tab.isStopping(run))
        let children = model.delegation.children(of: run.id)
        // The transcript is read by what shows it, so a run streaming redraws those alone.
        VStack(alignment: .leading, spacing: 18) {
            SubagentCard(run: run, state: state, caller: run.parentSubagentID.flatMap { model.delegation.run($0) }
                            .flatMap { tab.navigation.path.dropLast().last == .run($0.id) ? nil : $0 },
                         place: tab.workplace(of: run), focus: focus)
                .id(SubagentAnchor.block("top"))
                .modifier(Placed(anchor: .block("top"), tab: tab))
            if !run.phase.isActive {
                SubagentResult(run: run)
                    .modifier(Placed(anchor: .block("result"), tab: tab))
            }
            if !children.isEmpty {
                SubagentDisclosure("Sub-agents", trailing: "\(children.count)", expanded: tab.section("sub-agents")) {
                    InspectorCard {
                        ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                            SubagentDetailBranch(run: child, depth: 0, first: index == 0, tab: tab, focus: focus)
                        }
                    }
                }
                .id(SubagentAnchor.block("sub-agents"))
                .modifier(Placed(anchor: .block("sub-agents"), tab: tab))
            }
            SubagentTranscript(run: run, tab: tab)
                .id(SubagentAnchor.block("transcript"))
                .modifier(Placed(anchor: .block("transcript"), tab: tab))
            SubagentBrief(run: run, tab: tab)
                .modifier(Placed(anchor: .block("brief"), tab: tab))
            SubagentRunFacts(run: run)
                .modifier(Placed(anchor: .block("run"), tab: tab))
        }
        // The result appears above what the reader was reading without moving it.
        .onChange(of: run.phase) { tab.keepPlace() }
    }
}

/// The details' head (#430): the run's bot acting out what it does, its title, its state and time,
/// what it is doing now, and where it works. Where Escape is heard once the details show.
private struct SubagentCard: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let state: SubagentRowState
    /// The run that delegated it, when Back doesn't lead there already.
    let caller: SubagentRun?
    let place: SubagentWorkplace?
    var focus: FocusState<SubagentAnchor?>.Binding

    static let face: CGFloat = 96

    var body: some View {
        let tint = state.kind == .failed ? failureRed : Palette.secondaryText
        InspectorCard(padded: true) {
            VStack(alignment: .leading, spacing: 10) {
                if let caller {
                    Text(caller.title).font(.system(size: 11.5)).foregroundStyle(Palette.secondaryText).lineLimit(1)
                }
                HStack(alignment: .center, spacing: 12) {
                    BotFace(bot: model.bot(run.targetBotID) ?? Bot(id: run.targetBotID, name: run.targetBotName, emoji: run.targetBotEmoji,
                                                                  workspace: run.targetBotWorkspace, appearance: run.targetBotAppearance),
                            activity: state.activity, animates: true)
                        .frame(width: Self.face, height: Self.face)
                        .background(Palette.violet.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(run.targetBotName).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            // The pet shows it working. A spinner here as well slowed typing in the
                            // message box eightfold while the details were open (journey 12).
                            if state.kind != .running { SubagentStateSymbol(kind: state.kind).frame(width: 16, height: 16) }
                            Text(state.word).foregroundStyle(tint).lineLimit(1)
                        }
                        SubagentTime(state: state).foregroundStyle(tint)
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                    Spacer(minLength: 0)
                }
                Text(run.title).font(.system(size: 15, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if run.phase == .running { SubagentLiveAction(run: run) }
                if let place { SubagentWorkplaceLine(place: place, run: run, opens: true) }
            }
        }
        .focusable()
        .focused(focus, equals: .block("top"))
        .focusEffectDisabled()
    }
}

/// What a running run is doing now, from its transcript, read here alone so it streams without
/// redrawing the rest of the details.
private struct SubagentLiveAction: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun

    var body: some View {
        let action = SubagentRowState.liveAction(model.delegation.threads[run.id] ?? [], root: run.worktree ?? run.workingDirectory)
        // One line in a fixed frame: a new action never resizes the card and the details below it.
        Text(action ?? "")
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
            .help(action ?? "")
            .accessibilityHidden(action == nil)
    }
}

/// Where a run works: its branch or worktree's folder, a dot when it has changes, and its pull
/// request. In the details, the pull request opens on GitHub.
private struct SubagentWorkplaceLine: View {
    @Environment(AppModel.self) private var model
    let place: SubagentWorkplace
    let run: SubagentRun
    var opens = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .medium))
            Text(place.name).lineLimit(1).truncationMode(.middle)
            if place.isDirty {
                Circle().fill(Palette.warning).frame(width: 6, height: 6).accessibilityLabel("Changed")
            }
            Spacer(minLength: 4)
            if let number = place.pullRequest {
                let pill = PullRequestPill(number: number, state: place.pullRequestState)
                if opens {
                    Button { open(number) } label: { pill }
                        .buttonStyle(.plain)
                        .help("Open pull request #\(number)")
                        .accessibilityIdentifier("subagent-pull-request")
                } else {
                    pill
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.secondaryText)
        .help(run.worktree ?? place.name)
    }

    static func spoken(_ place: SubagentWorkplace) -> String {
        [place.name, place.isDirty ? "changed" : nil, place.pullRequest.map { "pull request \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }

    private func open(_ number: Int) {
        let conversation = run.rootTaskID.map { ChatTarget.task($0, of: run.rootBotID) } ?? .home(run.rootBotID)
        if let repo = model.task(conversation)?.repo, !repo.isEmpty, let url = URL(string: "https://github.com/\(repo)/pull/\(number)") {
            NSWorkspace.shared.open(url)
            return
        }
        // Elsewhere, its own folder's GitHub repository knows it.
        let folder = run.worktree ?? run.workingDirectory
        Task { _ = await Machine.thisMac.run(["gh", "pr", "view", "\(number)", "--web"], in: folder) }
    }
}

/// A child in the details' Sub-agents: every one, whatever its state, opening its own details.
private struct SubagentDetailBranch: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let depth: Int
    let first: Bool
    let tab: SubagentTabState
    var focus: FocusState<SubagentAnchor?>.Binding

    var body: some View {
        let children = model.delegation.children(of: run.id)
        let failed = children.reduce(0) { $0 + ($1.phase == .failed ? 1 : 0) }
        let startsOpen = run.phase.isActive || failed > 0 || children.contains { $0.phase.isActive }
        let open = Binding(get: { tab.opened[run.id] ?? startsOpen }, set: { tab.opened[run.id] = $0 })
        VStack(alignment: .leading, spacing: 0) {
            SubagentRow(run: run, depth: depth, first: first, hasChildren: !children.isEmpty, open: open,
                        failedBelow: failed, tab: tab, focus: focus) {
                tab.push(.run(run.id), opened: run.id)
            }
            if open.wrappedValue, depth < SubagentLimits.maxDepth {
                ForEach(children) { child in
                    SubagentDetailBranch(run: child, depth: depth + 1, first: false, tab: tab, focus: focus)
                }
            }
        }
    }
}

/// What a run came to, first once it has ended: its handoff, its error or why it stopped.
private struct SubagentResult: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { result }
    }

    @ViewBuilder private var result: some View {
        switch run.phase {
        case .completed:
            let handoff = run.handoffOutput ?? ""
            if handoff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SubagentDisclosure("Handoff", expanded: $expanded) {
                    SubagentText(text: "No handoff text", secondary: true)
                }
            } else {
                SubagentDisclosure("Handoff", copy: handoff, expanded: $expanded) { SubagentText(text: handoff) }
            }
        case .failed:
            let error = run.errorMessage ?? "Failed without a message."
            SubagentDisclosure("Error", copy: error, expanded: $expanded) { SubagentText(text: error, mono: true) }
            SubagentResumeRow(run: run)
            lastReply
        case .stopped:
            if let reason = SubagentRowState.stopReason(run) {
                SubagentDisclosure(run.isInterrupted ? "Interrupted" : "Stopped", expanded: $expanded) { SubagentText(text: reason) }
            }
            SubagentResumeRow(run: run)
            lastReply
        case .queued, .preparing, .running:
            EmptyView()
        }
    }

    @ViewBuilder private var lastReply: some View {
        if let reply = model.delegation.threads[run.id]?.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text {
            SubagentLastReply(text: reply)
        }
    }
}

private struct SubagentLastReply: View {
    let text: String
    @State private var expanded = true

    var body: some View {
        SubagentDisclosure("Last reply", copy: text, expanded: $expanded) { SubagentText(text: text) }
    }
}

private struct SubagentText: View {
    let text: String
    var mono = false
    var secondary = false

    var body: some View {
        InspectorCard(padded: true) {
            Text(text)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(secondary ? Palette.secondaryText : Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The run's transcript: open while it's under way, folded once it has ended (then as the reader
/// leaves it), showing its last items as they come (`SubagentTranscriptList`), with the earlier
/// ones a click away; once shown, those stay where they are.
private struct SubagentTranscript: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inspectorArea) private var area
    let run: SubagentRun
    let tab: SubagentTabState

    var body: some View {
        let live = model.delegation.live(run.id)
        // Through `threads`, which reads a finished run's transcript in when it shows.
        let messages = live.browsing == nil ? model.delegation.threads[run.id] ?? [] : live.displayMessages
        let list = SubagentTranscriptList(messages, kind: run.account.kind)
        let items = list.items
        let start = list.start(pinned: tab.transcriptStart[run.id])
        SubagentDisclosure("Transcript", trailing: items.isEmpty ? nil : "\(items.count)", expanded: Binding(
            get: { tab.transcriptOpen[run.id] ?? run.phase.isActive }, set: { tab.transcriptOpen[run.id] = $0 })) {
            InspectorCard {
                if items.isEmpty {
                    Text(run.phase.isActive ? "Nothing yet" : "Nothing recorded")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondaryText).padding(10)
                }
                if start > 0 || live.displayStart > 0 {
                    let earlier = min(start + live.displayStart, 100)
                    Button("Show \(earlier) earlier") { showEarlier(earlier, before: items.count - start, from: start) }
                        .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(Palette.accent)
                        .padding(EdgeInsets(top: 8, leading: 10, bottom: 4, trailing: 10))
                }
                ForEach(items[start...]) { message in
                    SubagentTranscriptItem(message: message, run: run, tab: tab)
                        .id(SubagentAnchor.block("message-" + message.id.uuidString))
                        .modifier(Placed(anchor: .block("message-" + message.id.uuidString), tab: tab))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(InspectorScrollArea.space)) } action: { frame in
                            if message.id == items.last?.id { loadLater(near: frame, first: items[start].id) }
                        }
                }
            }
        }
        .onAppear {
            // Earlier items the reader asked for are held still again.
            if tab.transcriptStart[run.id] != nil { live.pinDisplay() }
            if tab.transcriptOpen[run.id] == nil { tab.transcriptOpen[run.id] = run.phase.isActive }
        }
        .onDisappear { model.delegation.live(run.id).showLatest() }
        .onChange(of: live.hasLaterPage) { _, later in
            guard later, start < items.count, let id = items.last?.id, let frame = tab.frames[.block("message-" + id.uuidString)] else { return }
            loadLater(near: frame, first: items[start].id)
        }
    }

    /// Shows `earlier` items before the `shown` ones, from then on held still while the run goes on,
    /// or reads them in from its file when the ones in memory are all shown.
    private func showEarlier(_ earlier: Int, before shown: Int, from start: Int) {
        let live = model.delegation.live(run.id)
        guard start > 0 else {
            model.delegation.pageEarlier(run.id) { tab.transcriptStart[run.id] = 0 }
            return
        }
        live.pinDisplay()
        tab.transcriptStart[run.id] = SubagentTranscriptList.start(showing: earlier, before: shown,
                                                                   in: SubagentTranscriptList(live.displayMessages, kind: run.account.kind))
    }

    /// Adds what came later below, the `first` item shown staying first (unless the page has
    /// moved past it).
    private func loadLater(near frame: CGRect, first: UUID) {
        guard frame.maxY > 0, frame.minY < (area?.viewport.height ?? 0) + 100,
              model.delegation.live(run.id).hasLaterPage else { return }
        model.delegation.pageLater(run.id) {
            let items = SubagentTranscriptList(model.delegation.live(run.id).displayMessages, kind: run.account.kind).items
            tab.transcriptStart[run.id] = items.firstIndex { $0.id == first } ?? 0
            tab.keepPlace()
        }
    }
}

private struct SubagentTranscriptItem: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let run: SubagentRun
    let tab: SubagentTabState

    var body: some View {
        let _ = SubagentDiagnostics.didEvaluateTranscriptItem?(message.id)
        if message.role == .tool {
            let activity = ToolActivity.describe(message, root: run.workingDirectory)
            let delegated = activity.runIDs.compactMap { id in model.delegation.children(of: run.id).first { $0.id == id } }
            if !delegated.isEmpty {
                ForEach(delegated) { child in
                    Button { tab.push(.run(child.id), opened: nil) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch").foregroundStyle(Palette.violet).frame(width: 16)
                            Text(child.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            SubagentStateSymbol(kind: SubagentRowState(child).kind)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(child.title)")
                }
            } else {
                tool(activity)
            }
        } else {
            Text(message.text)
                .font(.system(size: 12.5))
                .foregroundStyle(message.role == .error ? failureRed : Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private func tool(_ activity: ToolActivity) -> some View {
        let open = tab.toolsOpen.contains(message.id)
        let state = message.displayedToolState(for: run.account.kind)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { tab.toolsOpen.remove(message.id) } else { tab.toolsOpen.insert(message.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.glyph(activity.intent)).foregroundStyle(Palette.secondaryText).frame(width: 16)
                    Text(message.toolName ?? "Tool").fontWeight(.semibold).lineLimit(1).fixedSize()
                    Text([activity.title, activity.subtitle].filter { !$0.isEmpty }.joined(separator: " "))
                        .foregroundStyle(Palette.secondaryText).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if state == .running {
                        ActivitySpinner(size: 10, tint: Palette.violet)
                    } else if state == .failed {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(failureRed)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Palette.secondaryText)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(activity.command ?? message.toolInput ?? "")
            if open {
                ToolDetail(message: message, kind: run.account.kind).padding(10)
            }
        }
    }

    static func glyph(_ intent: ToolIntent) -> String {
        switch intent {
        case .read: "doc"
        case .list: "folder"
        case .search: "magnifyingglass"
        case .fetch: "globe"
        case .inspect: "eye"
        case .command: "apple.terminal"
        case .edit: "pencil"
        case .subagent: "arrow.triangle.branch"
        case .plan: "checklist"
        case .question: "questionmark.bubble"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// What the run was asked, and by whom.
private struct SubagentBrief: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    let tab: SubagentTabState
    @State private var expanded = true

    var body: some View {
        let all = tab.briefsOpen.contains(run.id)
        SubagentDisclosure("Brief", copy: run.brief, expanded: $expanded) {
            InspectorCard(padded: true) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text("From").foregroundStyle(Palette.secondaryText)
                        caller
                    }
                    .font(.system(size: 12))
                    Text(run.brief).font(.system(size: 12.5)).textSelection(.enabled)
                        .lineLimit(all ? nil : 8)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !all, run.brief.count > 400 || run.brief.split(separator: "\n", omittingEmptySubsequences: false).count > 8 {
                        Button("Show all") { tab.briefsOpen.insert(run.id) }
                            .buttonStyle(.link).font(.system(size: 12)).foregroundStyle(Palette.accent)
                    }
                }
            }
        }
    }

    @ViewBuilder private var caller: some View {
        if let parent = run.parentSubagentID.flatMap({ model.delegation.run($0) }) {
            Button {
                if tab.navigation.path.dropLast().last == .run(parent.id) { tab.back() } else { tab.push(.run(parent.id), opened: nil) }
            } label: {
                HStack(spacing: 4) {
                    SubagentAvatar(run: parent, size: 16)
                    Text(parent.targetBotName).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .help("Open \(parent.title)")
        } else if let bot = model.bot(run.rootBotID) {
            BotAvatar(bot: bot, size: 16)
            Text(bot.name).lineLimit(1)
        }
    }
}

/// Where and how the run ran.
private struct SubagentRunFacts: View {
    @Environment(AppModel.self) private var model
    let run: SubagentRun
    @State private var expanded = true

    var body: some View {
        let label = ModelPickerData(kind: run.account.kind, model: run.model, openRouterDefault: model.settings.openRouterModel,
                                    sailDefault: model.settings.sailModel, native: model.nativeModels(for: run),
                                    resolved: run.resolvedModel, providerID: run.providerID)
        SubagentDisclosure("Run", expanded: $expanded) {
            InspectorCard {
                SubagentFact("Account") {
                    ProviderLabel(title: run.account.name, kind: run.account.kind, size: 12)
                }
                SubagentFact("Runtime") { Text(run.account.kind.displayName) }
                if let provider = run.modelProvider { SubagentFact("Provider") { Text(provider.name) } }
                SubagentFact("Model") { Text(label.title).help(label.detail) }
                SubagentFact("Workspace") {
                    Text(run.workspaceMode == .sharedCallerWorkspace ? "Shared workspace" : "\(run.targetBotName)'s workspace")
                }
                SubagentFact("Folder", stacked: true) {
                    Text(run.workingDirectory).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SubagentFact("Started") { Text(run.startedAt.map(Self.when) ?? "—") }
                SubagentFact("Ended", last: true) { Text(run.phase.isActive ? "—" : (run.finishedAt.map(Self.when) ?? "—")) }
            }
        }
    }

    static func when(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }
}

/// A key and its value, side by side, or the key above the value where they don't fit.
private struct SubagentFact<Value: View>: View {
    let key: String
    var stacked = false
    var last = false
    @ViewBuilder let value: Value

    init(_ key: String, stacked: Bool = false, last: Bool = false, @ViewBuilder value: () -> Value) {
        self.key = key
        self.stacked = stacked
        self.last = last
        self.value = value()
    }

    var body: some View {
        Group {
            if stacked {
                above
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(key).foregroundStyle(Palette.secondaryText)
                        Spacer(minLength: 8)
                        value.lineLimit(1).fixedSize()
                    }
                    above
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
    }

    private var above: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key).foregroundStyle(Palette.secondaryText)
            value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Shared pieces

/// A titled group like `InspectorSection`, whose folding belongs to the tab rather than to every
/// conversation, with Copy beside the title where it applies.
private struct SubagentDisclosure<Content: View>: View {
    let title: String
    var trailing: String?
    var copy: String?
    @Binding var expanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, trailing: String? = nil, copy: String? = nil, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.copy = copy
        _expanded = expanded
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                Spacer()
                if let trailing, copy == nil { Text(trailing).font(.system(size: 11)).monospacedDigit() }
            }
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 4)
        }
        .disclosureGroupStyle(InspectorDisclosureStyle())
        .overlay(alignment: .topTrailing) {
            if let copy {
                Button {
                    copyToPasteboard(copy)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondaryText)
                .help("Copy the \(title.lowercased())")
                .padding(.trailing, 4)
            }
        }
    }
}

/// Records where a row or block is in the visible part of the inspector's scroll view, so Back and
/// changes above the reader can keep it in place.
private struct Placed: ViewModifier {
    let anchor: SubagentAnchor
    let tab: SubagentTabState

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(InspectorScrollArea.space)) } action: { tab.frames[anchor] = $0 }
            .onDisappear { tab.frames[anchor] = nil }
    }
}

/// For tests: which runs' rows and details, and which transcript items, are evaluated (#361).
@MainActor enum SubagentDiagnostics {
    static var didEvaluateRow: ((UUID) -> Void)?
    static var didEvaluateDetails: ((UUID) -> Void)?
    static var didEvaluateTranscriptItem: ((UUID) -> Void)?
}

extension SubagentPhase {
    var displayName: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .running: "Working"
        case .completed: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}
