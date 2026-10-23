import SwiftUI
import BotChuCore

/// One conversation: a bot's Home, or one of its tasks. Its messages show as activity items:
/// replies, exploration folded into groups, and commands, edits and sub-agents as cards
/// (`ActivityTranscript`), regrouped only at the tail as a turn streams in. The newest items show
/// at first, earlier ones on request. A reader at the bottom follows new content; one reading
/// earlier content keeps their place while it arrives.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showsStatus") private var showsStatus = true
    @AppStorage(ChatDensity.storageKey) private var density: ChatDensity = .detailed
    let target: ChatTarget
    @State private var composerFocused = false
    @State private var transcript: TranscriptModel
    /// The reader is at the newest content, and the chat keeps them there.
    @State private var following = true

    init(target: ChatTarget) {
        self.target = target
        _transcript = State(initialValue: TranscriptCache.model(for: target))
    }

    var body: some View {
        if let bot = model.bot(target.botID), let current = model.runSettings(of: target) {
            let task = model.task(target)
            let messages = model.thread(target)
            let running = model.isRunning(target)
            // Its own turn, not only sub-agents it started, keeps its newest group live.
            let turnRunning = model.runStates[target] != nil
            let items = transcript.items(for: messages, root: task?.folder ?? bot.workspace)
            let start = transcript.start(of: items)
            let shown = Array(items[start...])
            let cards = SubagentCards(items: items, runs: model.delegation.records[target] ?? [])
            let kind = current.account.kind
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if start > 0 {
                                Button {
                                    let first = shown.first?.id
                                    transcript.showEarlier(items: items)
                                    DispatchQueue.main.async { if let first { proxy.scrollTo(first, anchor: .top) } }
                                } label: {
                                    Label("Show \(min(start, TranscriptModel.page)) earlier", systemImage: "arrow.up")
                                        .font(.callout)
                                }
                                .buttonStyle(.link)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 4)
                                .help("\(start) earlier \(start == 1 ? "item" : "items") in this conversation")
                            } else if let task {
                                TaskIntro(bot: bot, task: task, machine: task.isRemote ? model.machineName(task.hostID, fallback: task.hostName) : nil)
                            } else {
                                BotIntro(bot: bot)
                            }
                            ForEach(Array(shown.enumerated()), id: \.element.id) { offset, item in
                                let previous = offset > 0 ? shown[offset - 1] : start > 0 ? items[start - 1] : nil
                                ActivityRow(item: item, bot: bot, kind: kind, startsBotTurn: !(previous?.isBotTurn ?? false),
                                            density: density, live: turnRunning && offset == shown.count - 1,
                                            open: transcript.isOpen(item.id, default: false),
                                            runs: cards.runs(for: item), after: cards.unplaced(after: item.id))
                                    .equatable()
                                    .id(item.id)
                            }
                            if model.runStates[target]?.preparing == true {
                                PreparingRow(bot: bot, place: task.flatMap { $0.isRemote ? model.machineName($0.hostID, fallback: $0.hostName) : nil })
                            } else if running, messages.last?.role != .assistant, !(shown.last.map { Self.showsProgress($0) } ?? false) {
                                TypingIndicator(bot: bot, showsAvatar: !(shown.last?.isBotTurn ?? false))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: Theme.chatWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .followsNewestMessage(following)
                    .tracksFollowing($following)
                    // A reply streams in by growing its text in place, so the follow watches the last
                    // message, not the count, and keeps up with every delta.
                    .onChange(of: messages.last) { if following { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: following) { _, now in
                        transcript.follow(now, items: items)
                        if now { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .overlay(alignment: .bottom) {
                        if !following {
                            Button {
                                following = true
                                proxy.scrollTo("bottom", anchor: .bottom)
                            } label: {
                                Label(running ? "Follow Live" : "Jump to Latest", systemImage: "arrow.down")
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(.regularMaterial))
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 10)
                            .help("Scroll to the newest messages and follow them")
                        }
                    }
                }
                VStack(spacing: 8) {
                    if let queue = model.messageQueues[target], !queue.messages.isEmpty {
                        QueuedMessages(queue: queue, running: running, preparing: model.runStates[target]?.preparing == true,
                            midTurn: model.takesFollowUpsMidTurn(target),
                            resume: { model.resumeQueuedMessages(to: target) },
                            edit: { model.editQueuedMessage($0, in: target); composerFocused = true },
                            remove: { model.removeQueuedMessage($0, from: target) })
                    }
                    Composer(draft: Binding(get: { model.drafts[target] ?? "" }, set: { model.drafts[target] = $0 }),
                         focused: $composerFocused,
                         images: model.draftImages[target] ?? [],
                         imageURL: { model.imageURL($0, for: target) },
                         onRemoveImage: { id in model.draftImages[target]?.removeAll { $0.id == id } },
                         onAddImages: { model.addImages($0, to: target) },
                         onPasteImages: { model.pasteImages($0, to: target) },
                         attachmentError: model.attachmentErrors[target],
                         placeholder: task.map { "Message \(bot.name) about \($0.title)" } ?? "Message \(bot.name)",
                         running: running, midTurn: model.takesFollowUpsMidTurn(target), onSend: send, onStop: { model.stop(target) }) {
                        ModelMenu(settings: current, disabled: running,
                                  onModel: { model.setModel($0, for: target) },
                                  onEffort: { model.setReasoningEffort($0, for: target) })
                            .layoutPriority(1)
                            .id(target)
                        Spacer(minLength: 0)
                        ProviderLabel(current.account, size: 12)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .help(task == nil ? "Current account. Change it in Edit Bot." : "This task's account. Change it in the status sidebar.")
                    }
                }
                .id(target)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(maxWidth: Theme.chatWidth)
                .frame(maxWidth: .infinity)
            }
            .environment(transcript)
            // Keep room for the model, effort and send controls when the columns are narrowed.
            .frame(minWidth: 300)
            .navigationTitle(bot.name)
            .navigationSubtitle(task?.title ?? "")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("Chat Density", selection: $density) {
                            ForEach(ChatDensity.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Chat Density", systemImage: density.symbol)
                    }
                    .help("How much tool work the chat shows: Compact (headers), Detailed (files and errors) or Raw (every call)")
                    Button { model.newTask(for: bot.id) } label: {
                        Label("New Task", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("Start a task for \(bot.name) in a repository (⌘T)")
                    Button { showsStatus.toggle() } label: {
                        Label(showsStatus ? "Hide Status" : "Show Status", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the status sidebar (⌥⌘I)")
                }
            }
            .onAppear { composerFocused = true }
            // Opening the conversation again starts from its newest items.
            .onDisappear { transcript.windowStart = nil }
        }
    }

    private func send() {
        let text = (model.drafts[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let images = model.draftImages[target] ?? []
        guard !text.isEmpty || !images.isEmpty else { return }
        if model.send(text, to: target, images: images) {
            model.drafts[target] = nil
            model.draftImages[target] = nil
            model.attachmentErrors[target] = nil
            // Sending takes the reader to their message and what follows it.
            following = true
        }
    }

    /// The last item already shows the turn at work: a live group or a running call.
    static func showsProgress(_ item: ActivityItem) -> Bool {
        switch item {
        case .exploration(let group): group.isOpen
        case .tool(let tool): tool.state == .running
        case .message: false
        }
    }
}

/// One row of the chat: a message, an exploration group, or a standalone call's card, at the
/// density chosen (`ChatDensity`); in Raw, every call as its own card with its arguments.
struct ActivityRow: View, Equatable {
    let item: ActivityItem
    let bot: Bot
    let kind: AgentKind
    let startsBotTurn: Bool
    let density: ChatDensity
    /// The conversation's turn is running and this is its newest item.
    let live: Bool
    /// Opened by a click (or by default).
    let open: Bool
    /// The delegated runs this call started, or for a `wait`, those it waits for.
    let runs: [SubagentRun]
    /// Runs no call accounts for, which began after this item.
    let after: [SubagentRun]

    var body: some View {
        switch item {
        case .message(let message):
            MessageRow(message: message, bot: bot, kind: kind, startsBotTurn: startsBotTurn).equatable()
        case .exploration(let group):
            BotTurnRow(bot: bot, showsAvatar: startsBotTurn) {
                if density == .raw {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.calls) { call in ToolCard(message: call.message, kind: kind) }
                    }
                } else {
                    ExplorationCard(group: group, live: live && group.isOpen, density: density, open: open, kind: kind).equatable()
                }
            }
        case .tool(let tool):
            BotTurnRow(bot: bot, showsAvatar: startsBotTurn) {
                VStack(alignment: .leading, spacing: 8) {
                    if density == .raw {
                        ToolCard(message: tool.message, kind: kind)
                    } else {
                        card(for: tool)
                    }
                    ForEach(after) { run in SubagentChatCard(run: run) }
                }
            }
        }
    }

    @ViewBuilder private func card(for tool: ToolCallItem) -> some View {
        switch tool.activity.intent {
        case .command:
            CommandCard(item: tool, density: density, open: open, kind: kind).equatable()
        case .edit:
            EditCard(item: tool, open: open, kind: kind).equatable()
        case .subagent:
            if let delegation = tool.activity.delegation {
                if delegation.isLaunch, !runs.isEmpty {
                    ForEach(runs) { run in SubagentChatCard(run: run) }
                } else if !delegation.isLaunch {
                    WaitRow(item: tool, runs: runs, open: open, kind: kind).equatable()
                } else {
                    // No run came of it (yet): the call itself, with its output.
                    CommandCard(item: tool, density: density, open: open, kind: kind).equatable()
                }
            } else {
                NativeSubagentCard(item: tool, open: open, kind: kind).equatable()
            }
        default:
            CompactToolCard(item: tool, open: open, kind: kind).equatable()
        }
    }
}

/// Which delegated runs show where: each with the `botchu-subagent` call that started it, and any
/// the calls don't account for after the item that came before them.
struct SubagentCards {
    private var placed: [UUID: [SubagentRun]] = [:]
    private var leftover: [UUID: [SubagentRun]] = [:]
    private var all: [UUID: SubagentRun] = [:]

    init(items: [ActivityItem], runs: [SubagentRun], now: Date = Date()) {
        let top = runs.filter { $0.parentSubagentID == nil }
        guard !top.isEmpty else { return }
        all = Dictionary(top.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var launches: [SubagentPlacement.Launch] = []
        for item in items {
            guard case .tool(let tool) = item, let delegation = tool.activity.delegation, delegation.isLaunch else { continue }
            let finished = tool.state == .running ? nil : tool.message.date.addingTimeInterval(tool.message.toolDuration ?? 1)
            launches.append(.init(messageID: tool.id, started: tool.message.date, finished: finished,
                                  printedIDs: tool.activity.runIDs, launches: delegation.launches))
        }
        let assigned = SubagentPlacement.assign(launches: launches, runs: top.map {
            .init(id: $0.id, createdAt: $0.createdAt, title: $0.title, agent: $0.targetBotName)
        }, now: now)
        for (message, ids) in assigned { placed[message] = ids.compactMap { all[$0] } }
        let claimed = Set(assigned.values.flatMap { $0 })
        let unclaimed = top.filter { !claimed.contains($0.id) }
        if !unclaimed.isEmpty {
            let anchors = SubagentPlacement.anchors(for: unclaimed.map { .init(id: $0.id, createdAt: $0.createdAt, title: $0.title, agent: $0.targetBotName) },
                                                    items: items.map { ($0.id, $0.date) })
            for (item, ids) in anchors { leftover[item] = ids.compactMap { all[$0] } }
        }
    }

    func unplaced(after item: UUID) -> [SubagentRun] { leftover[item] ?? [] }

    /// The runs a call started; for a `wait`, those it names in its output, or while it waits,
    /// those still running.
    func runs(for item: ActivityItem) -> [SubagentRun] {
        guard case .tool(let tool) = item, let delegation = tool.activity.delegation else { return [] }
        if delegation.isLaunch { return placed[tool.id] ?? [] }
        let named = tool.activity.runIDs.compactMap { all[$0] }
        if !named.isEmpty || tool.state != .running { return named }
        return all.values.filter { $0.phase.isActive }.sorted { $0.createdAt < $1.createdAt }
    }
}

/// The top of every chat: who the bot is.
struct BotIntro: View {
    let bot: Bot

    var body: some View {
        VStack(spacing: 6) {
            BotAvatar(bot: bot, size: 56)
            Text(bot.name).font(.title2.weight(.semibold))
            if !bot.title.isEmpty {
                Text(bot.title).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

/// The top of a task's chat: the bot, and what and where the task is.
struct TaskIntro: View {
    let bot: Bot
    let task: BotTask
    /// The host it works on; nil on this Mac.
    let machine: String?

    var body: some View {
        VStack(spacing: 6) {
            BotAvatar(bot: bot, size: 44)
            Text(task.title).font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 4) {
                Text(task.repo)
                if let machine {
                    Text("·")
                    Label("on \(machine)", systemImage: "network")
                        .help("Works on \(machine) over SSH, with \(bot.name)'s context from this Mac")
                }
                if let work = task.work, !work.isPullRequest {
                    Text("·")
                    Link(work.title.isEmpty ? "#\(work.number)" : "#\(work.number) \(work.title)", destination: work.url)
                        .lineLimit(1)
                        .help("Open the issue on GitHub")
                }
            }
            .foregroundStyle(.secondary)
            if task.review != nil {
                Label(task.review == .comment ? "Review, posted on GitHub" : "Review, here only", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

/// While BotChu makes a task's worktree, before its first turn, or on a host, connects there.
struct PreparingRow: View {
    let bot: Bot
    /// The host the task works on; nil on this Mac.
    let place: String?

    var body: some View {
        BotTurnRow(bot: bot, showsAvatar: true) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(place.map { "Connecting to \($0)…" } ?? "Preparing the task's workspace…").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.replyBackground))
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Opens a chat at its newest message and, while the reader follows it, keeps it there as
    /// content grows; otherwise growing content leaves the reader's place alone. On macOS 15 and
    /// later a chat shorter than the window starts at the top rather than sinking to the bottom.
    @ViewBuilder func followsNewestMessage(_ following: Bool = true) -> some View {
        if #available(macOS 15, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(following ? .bottom : .top, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            defaultScrollAnchor(.bottom)
        }
    }

    /// Whether the reader is at the newest content. Only their own scrolling changes it: content
    /// that grows, or a window that resizes, leaves it as it was. Before macOS 15 the chat always
    /// follows.
    @ViewBuilder func tracksFollowing(_ following: Binding<Bool>) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: ChatScrollPosition.self) { geometry in
                ChatScrollPosition(content: geometry.contentSize.height, viewport: geometry.containerSize.height,
                                   below: geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { old, new in
                // While the window lays out, the scroll view briefly reports no height at all.
                guard new.viewport > 120, abs(old.content - new.content) < 0.5, abs(old.viewport - new.viewport) < 0.5 else { return }
                let atBottom = new.below < 40
                if following.wrappedValue != atBottom { following.wrappedValue = atBottom }
            }
        } else {
            self
        }
    }
}

struct ChatScrollPosition: Equatable {
    var content: CGFloat
    var viewport: CGFloat
    /// How far the content goes on below what's visible.
    var below: CGFloat
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
