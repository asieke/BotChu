import SwiftUI
import BotChuCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showsStatus") private var showsStatus = true
    let botID: UUID
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        if let bot = model.bot(botID) {
            let messages = model.thread(botID)
            let running = model.isRunning(botID)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Eager, not lazy: threads are short, and a lazy stack blanks and jumps while
                        // replies stream in.
                        VStack(alignment: .leading, spacing: 12) {
                            BotIntro(bot: bot)
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                MessageRow(message: message, bot: bot,
                                           startsBotTurn: !Self.isBotTurn(messages[safe: index - 1]))
                            }
                            if running, messages.last?.role != .assistant {
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
                    .onChange(of: messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Composer(draft: $draft, focused: $composerFocused, botName: bot.name, running: running,
                         onSend: send, onStop: { model.stop(botID) }) {
                    Label(bot.account.name, systemImage: "terminal")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help("Current account. Change it in Edit Bot.")
                    Spacer(minLength: 0)
                    ModelMenu(bot: bot, disabled: running,
                              onModel: { model.setModel($0, for: botID) },
                              onEffort: { model.setReasoningEffort($0, for: botID) })
                        .layoutPriority(1)
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .frame(maxWidth: Theme.chatWidth)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(bot.name)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showsStatus.toggle() } label: {
                        Label(showsStatus ? "Hide Status" : "Show Status", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the bot's status (⌥⌘I)")
                }
            }
            .onAppear { composerFocused = true }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isRunning(botID) else { return }
        draft = ""
        model.send(text, to: botID)
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
