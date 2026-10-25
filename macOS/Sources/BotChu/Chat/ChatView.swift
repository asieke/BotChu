import SwiftUI
import BotChuCore

/// One conversation: a bot's Home, or one of its tasks. Its messages show as activity items:
/// replies, exploration folded into groups, and commands, edits and sub-agents as cards
/// (`ActivityTranscript`), regrouped only where a turn writes as it streams in. The newest items
/// show at first, earlier ones on request (and, in a long conversation opened anew, once they're
/// grouped). Only the rows near the visible part are laid out, however much of the history is
/// open (`TranscriptViewport`). A reader at the bottom follows new content; one reading earlier
/// content keeps their place, by the row they're reading, while it arrives.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChatDensity.storageKey) private var density: ChatDensity = .detailed
    @Environment(\.composerTakesFocus) private var composerTakesFocus
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
            let epoch = model.conversation(target).epoch
            let items = transcript.items(for: messages, root: task?.folder ?? bot.workspace, epoch: epoch)
            let start = transcript.start(of: items)
            let cards = transcript.cards(runs: model.delegation.records[target] ?? [])
            let kind = current.account.kind
            let density = density, transcript = transcript
            let plan = transcript.plan(items, from: start,
                                       inputs: .init(width: 0, density: density.layoutValue, dark: colorScheme == .dark, epoch: epoch),
                                       pinned: following) { index, item in
                Self.style(of: item, at: index, count: items.count, density: density, turnRunning: turnRunning, transcript: transcript, cards: cards)
            }
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(spacing: 0) {
                                if start > 0 {
                                    Button {
                                        // The rows shown stay put as earlier ones go in above them.
                                        transcript.showEarlier(items: items)
                                    } label: {
                                        Label("Show \(min(start, TranscriptModel.page)) earlier", systemImage: "arrow.up")
                                            .font(.callout)
                                    }
                                    .buttonStyle(.link)
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, 4)
                                    .help("\(start) earlier \(start == 1 ? "item" : "items") in this conversation")
                                } else if transcript.isLoadingEarlier || !model.conversation(target).isLoaded {
                                    ProgressView().controlSize(.small)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .accessibilityLabel("Loading earlier messages")
                                } else if let task {
                                    TaskIntro(bot: bot, task: task, machine: task.isRemote ? model.machineName(task.hostID, fallback: task.hostName) : nil)
                                } else {
                                    BotIntro(bot: bot)
                                }
                            }
                            .padding(.bottom, 12)
                            // Where the rows start: it tells the transcript where the reader is.
                            ChatScrollProbe(transcript: transcript)
                            Color.clear.frame(height: plan.above)
                            ForEach(plan.rows) { row in
                                let item = items[row.index]
                                TranscriptRow(row: row, item: item, bot: bot, kind: kind,
                                              startsBotTurn: !(row.index > 0 && items[row.index - 1].isBotTurn),
                                              density: density, live: turnRunning && row.index == items.count - 1,
                                              open: transcript.isOpen(item.id, default: false),
                                              runs: cards.runs(for: item), after: cards.unplaced(after: item.id))
                                    .equatable()
                            }
                            Color.clear.frame(height: plan.below)
                            if model.runStates[target]?.preparing == true {
                                PreparingRow(bot: bot, place: task.flatMap { $0.isRemote ? model.machineName($0.hostID, fallback: $0.hostName) : nil })
                                    .padding(.bottom, 12)
                            } else if running, messages.last?.role != .assistant, !(items.last.map { Self.showsProgress($0) } ?? false) {
                                TypingIndicator(bot: bot, showsAvatar: !(items.last?.isBotTurn ?? false))
                                    .padding(.bottom, 12)
                            }
                            // The chat's bottom margin, so scrolling to it lands at the very end, where
                            // the chat opens, rather than the margin short of it.
                            Color.clear.frame(height: 21).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .frame(maxWidth: Theme.chatWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .followsNewestMessage(following)
                    .tracksFollowing($following) { proxy.scrollTo("bottom", anchor: .bottom) }
                    // Opening a conversation shows its newest message, also when the first layout
                    // didn't land there.
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
                    // A card the reader opens stays where they clicked it, growing downward.
                    .onChange(of: transcript.overrides) { old, new in
                        if new.count(where: { $0.value }) > old.count(where: { $0.value }) { following = false }
                    }
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
                    if let unsaved = model.unsavedMemory[target.botID], unsaved > 0 {
                        UnsavedMemory(count: unsaved) { model.retryMemory(for: target) }
                    }
                    if let queue = model.messageQueues[target], !queue.pending.isEmpty {
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
                         references: Binding(get: { model.draftReferences[target] ?? [] },
                                             set: { model.draftReferences[target] = $0.isEmpty ? nil : $0 }),
                         mentions: model.mentionSources(for: target),
                         placeholder: Self.placeholder(bot: bot, task: task),
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
            // The tab beside the chat says which conversation it is (#128).
            .navigationTitle(bot.name)
            // Not while the tabs beside the chat have keyboard focus, so ↑ and ↓ go on moving between them.
            .onAppear { if composerTakesFocus { composerFocused = true } }
            // Opening the conversation again starts from its newest items.
            .onDisappear { transcript.windowStart = nil }
            // Notes left waiting by an earlier launch.
            .task(id: target.botID) { model.refreshUnsavedMemory(of: target.botID) }
        }
    }

    private func send() {
        let draft = model.drafts[target] ?? ""
        let images = model.draftImages[target] ?? []
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        let references = model.draftReferences[target] ?? []
        let target = target, model = model
        // The message shows queued at once; should the queue not save, it comes back to the draft.
        if model.send(draft, to: target, images: images, references: references, accepted: { accepted in
            if !accepted { model.returnToDraft(draft, references: references, images: images, in: target) }
        }) {
            model.drafts[target] = nil
            model.draftReferences[target] = nil
            model.draftImages[target] = nil
            model.attachmentErrors[target] = nil
            // Sending takes the reader to their message and what follows it.
            following = true
        }
    }

    /// "Message 10x Engineer Bot about #113": a task's issue or pull request, else its repository.
    static func placeholder(bot: Bot, task: BotTask?) -> String {
        guard let task else { return "Message \(bot.name)" }
        return "Message \(bot.name) about " + (task.work.map { "#\($0.number)" } ?? task.repoName)
    }

    /// How an item is laid out, and what else its height depends on: an exploration group as one
    /// card (folded, or live), opened as a row per entry, or in Raw a card per call.
    static func style(of item: ActivityItem, at index: Int, count: Int, density: ChatDensity, turnRunning: Bool,
                      transcript: TranscriptModel, cards: SubagentCards) -> TranscriptViewport.Style {
        switch item {
        case .exploration(let group):
            if density == .raw { return .init(split: .calls) }
            if turnRunning, index == count - 1, group.isOpen { return .init(split: .whole, extra: 1) }
            return .init(split: transcript.isOpen(group.id, default: false) ? .opened : .whole)
        case .tool(let tool):
            var hasher = Hasher()
            hasher.combine(transcript.isOpen(tool.id, default: false))
            if tool.activity.delegation != nil {
                for run in cards.runs(for: item) { hasher.combine(run.id); hasher.combine(run.phase) }
            }
            for run in cards.unplaced(after: tool.id) { hasher.combine(run.id); hasher.combine(run.phase) }
            return .init(split: .whole, extra: hasher.finalize())
        case .message:
            return .init(split: .whole)
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

/// The chat's toolbar buttons. They go on the chat column, which stays as conversations change,
/// not on `ChatView`, which is made anew for each: toolbar items made anew on every switch had
/// AppKit rebuild and lay out the toolbar each time, a third of the switch. Nothing in them
/// depends on the conversation shown, so a switch leaves the toolbar as it is.
struct ChatToolbar: ViewModifier {
    @Environment(AppModel.self) private var model
    @AppStorage("showsStatus") private var showsStatus = true
    @AppStorage(ChatDensity.storageKey) private var density: ChatDensity = .detailed

    func body(content: Content) -> some View {
        content.toolbar {
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
                // Once the bot has a task, New Task is the + in the tasks' column (#128).
                if let id = model.visibleBotID, model.openTasks(of: id).isEmpty {
                    Button { model.newTask(for: id) } label: {
                        Label("New Task", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .help("Start a task for this bot in a repository (⌘T)")
                }
                Button { showsStatus.toggle() } label: {
                    Label(showsStatus ? "Hide Status" : "Show Status", systemImage: "sidebar.right")
                }
                .help("Show or hide the status sidebar (⌥⌘I)")
            }
        }
    }
}

/// One row the chat lays out (`TranscriptViewport.Row`): a whole item, or a part of an opened
/// exploration group (its header, an entry, its foot) or of a group in Raw (a call). It reports its
/// height as laid out, which the transcript keeps for when it goes out of view, and counts itself
/// while it is there.
struct TranscriptRow: View, Equatable {
    @Environment(TranscriptModel.self) private var transcript
    let row: TranscriptViewport.Row
    let item: ActivityItem
    let bot: Bot
    let kind: AgentKind
    let startsBotTurn: Bool
    let density: ChatDensity
    let live: Bool
    let open: Bool
    let runs: [SubagentRun]
    let after: [SubagentRun]

    /// Where it is among the rows doesn't change what it shows.
    static func == (a: Self, b: Self) -> Bool {
        a.row.id == b.row.id && a.row.signature == b.row.signature && a.row.split == b.row.split && a.row.parts == b.row.parts
            && a.item == b.item && a.bot == b.bot && a.kind == b.kind && a.startsBotTurn == b.startsBotTurn && a.density == b.density
            && a.live == b.live && a.open == b.open && a.runs == b.runs && a.after == b.after
    }

    var body: some View {
        let id = row.id, signature = row.signature, transcript = transcript
        content
            .padding(.bottom, row.gap)
            .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { height in
                transcript.measured(id, signature: signature, height: height)
            }
            .onAppear { transcript.rowAppeared() }
            .onDisappear { transcript.rowDisappeared() }
    }

    @ViewBuilder private var content: some View {
        switch (item, row.split) {
        case (.exploration(let group), .opened):
            if row.part == 0 {
                BotTurnRow(bot: bot, showsAvatar: startsBotTurn) {
                    ExplorationHead(group: group, density: density).equatable()
                }
            } else if row.part <= group.entries.count {
                let entry = group.entries[row.part - 1]
                BotTurnRow(bot: bot, showsAvatar: false) {
                    ExplorationEntrySlice(entry: entry, calls: group.calls(of: entry), kind: kind, last: row.part == group.entries.count)
                }
            } else {
                BotTurnRow(bot: bot, showsAvatar: false) {
                    ExplorationFoot(group: group).equatable()
                }
            }
        case (.exploration(let group), .calls) where row.part < group.calls.count:
            BotTurnRow(bot: bot, showsAvatar: startsBotTurn && row.part == 0) {
                ToolCard(message: group.calls[row.part], kind: kind)
            }
        default:
            ActivityRow(item: item, bot: bot, kind: kind, startsBotTurn: startsBotTurn, density: density, live: live, open: open,
                        runs: runs, after: after).equatable()
        }
    }
}

/// One item of the chat as one row: a message, a folded or live exploration group, or a
/// standalone call's card, at the density chosen (`ChatDensity`); in Raw, a call's card with its
/// arguments. Opened groups, and groups in Raw, are a row a part (`TranscriptRow`).
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
                ExplorationCard(group: group, live: live && group.isOpen, density: density, kind: kind).equatable()
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

/// The top of a task's chat: the bot, where the task is (its repository, issue or pull request,
/// and host), and what it is about as its headline (#128).
struct TaskIntro: View {
    let bot: Bot
    let task: BotTask
    /// The host it works on; nil on this Mac.
    let machine: String?

    var body: some View {
        VStack(spacing: 4) {
            BotAvatar(bot: bot, size: 40)
                .padding(.bottom, 6)
            HStack(spacing: 4) {
                Text(task.repo)
                if let work = task.work {
                    Text("·")
                    Link("\(work.isPullRequest ? "Pull request" : "Issue") #\(work.number)", destination: work.url)
                        .help("Open the \(work.isPullRequest ? "pull request" : "issue") on GitHub")
                }
                if let review = task.review {
                    Text("·")
                    Label(review == .comment ? "Review, posted on GitHub" : "Review", systemImage: "eye")
                }
                if let machine {
                    Text("·")
                    Label("on \(machine)", systemImage: "network")
                        .help("Works on \(machine) over SSH, with \(bot.name)'s context from this Mac")
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(ConversationTab.subject(of: task))
                .font(.system(size: 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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
    /// that grows, or a window that resizes, leaves it as it was, and while they follow,
    /// `keepAtBottom` takes them back to the newest content after any such change (a reply's web
    /// view or an image that grows after the first layout). Before macOS 15 the chat always follows.
    @ViewBuilder func tracksFollowing(_ following: Binding<Bool>, keepAtBottom: @escaping () -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: ChatScrollPosition.self) { geometry in
                ChatScrollPosition(content: geometry.contentSize.height, viewport: geometry.containerSize.height,
                                   below: geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { old, new in
                // While the window lays out, the scroll view briefly reports no height at all.
                guard new.viewport > 120 else { return }
                if abs(old.content - new.content) >= 0.5 || abs(old.viewport - new.viewport) >= 0.5 {
                    if following.wrappedValue, new.below > 1 { keepAtBottom() }
                    return
                }
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
