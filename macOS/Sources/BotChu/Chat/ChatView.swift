import SwiftUI
import BotChuCore

/// One conversation: a bot's Home, or one of its tasks.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showsStatus") private var showsStatus = true
    let target: ChatTarget
    @FocusState private var composerFocused: Bool

    var body: some View {
        if let bot = model.bot(target.botID), let current = model.runSettings(of: target) {
            let task = model.task(target)
            let messages = model.thread(target)
            let running = model.isRunning(target)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Eager, not lazy: threads are short, and a lazy stack blanks and jumps while
                        // replies stream in.
                        VStack(alignment: .leading, spacing: 12) {
                            if let task {
                                TaskIntro(bot: bot, task: task, machine: task.isRemote ? model.machineName(task.hostID, fallback: task.hostName) : nil)
                            } else {
                                BotIntro(bot: bot)
                            }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                MessageRow(message: message, bot: bot, kind: current.account.kind,
                                           startsBotTurn: !Self.isBotTurn(messages[safe: index - 1]))
                            }
                            if model.runStates[target]?.preparing == true {
                                PreparingRow(bot: bot, place: task.flatMap { $0.isRemote ? model.machineName($0.hostID, fallback: $0.hostName) : nil })
                            } else if running, messages.last?.role != .assistant {
                                TypingIndicator(bot: bot, showsAvatar: !Self.isBotTurn(messages.last))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: Theme.chatWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .followsNewestMessage()
                    // The chat follows its newest message. Watch the last message, not the count: a
                    // reply streams in by growing its text in place, which is a content change and not
                    // a new message, and the follow has to keep up with every delta.
                    .onChange(of: messages.last) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                VStack(spacing: 8) {
                    if let queue = model.messageQueues[target], !queue.messages.isEmpty {
                        QueuedMessages(queue: queue, running: running, preparing: model.runStates[target]?.preparing == true,
                            resume: { model.resumeQueuedMessages(to: target) },
                            edit: { model.editQueuedMessage($0, in: target); composerFocused = true },
                            remove: { model.removeQueuedMessage($0, from: target) })
                    }
                    Composer(draft: Binding(get: { model.drafts[target] ?? "" }, set: { model.drafts[target] = $0 }),
                         focused: $composerFocused,
                         placeholder: task.map { "Message \(bot.name) about \($0.title)" } ?? "Message \(bot.name)",
                         running: running, onSend: send, onStop: { model.stop(target) }) {
                        ModelMenu(settings: current, disabled: running,
                                  onModel: { model.setModel($0, for: target) },
                                  onEffort: { model.setReasoningEffort($0, for: target) })
                            .layoutPriority(1)
                            .id(target)
                        Spacer(minLength: 0)
                        Text(current.account.name)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .help(task == nil ? "Current account. Change it in Edit Bot." : "This task's account. Change it in the status sidebar.")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(maxWidth: Theme.chatWidth)
                .frame(maxWidth: .infinity)
            }
            // Keep room for the model, effort and send controls when the columns are narrowed.
            .frame(minWidth: 300)
            .navigationTitle(bot.name)
            .navigationSubtitle(task?.title ?? "")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
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
        }
    }

    private func send() {
        let text = (model.drafts[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if model.send(text, to: target) { model.drafts[target] = nil }
    }

    /// Replies and tool calls belong to the bot's turn; its avatar shows once at the turn's start.
    static func isBotTurn(_ message: ChatMessage?) -> Bool {
        message?.role == .assistant || message?.role == .tool
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
    /// Opens a chat at its newest message and keeps it there as a reply grows. On macOS 15 and later
    /// a chat shorter than the window starts at the top rather than sinking to the bottom.
    @ViewBuilder func followsNewestMessage() -> some View {
        if #available(macOS 15, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else {
            defaultScrollAnchor(.bottom)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
