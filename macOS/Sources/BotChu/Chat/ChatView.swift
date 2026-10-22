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
                    // Opens at the newest message and stays pinned there as a reply grows.
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Composer(draft: $draft, focused: $composerFocused, botName: bot.name, running: running,
                         onSend: send, onStop: { model.stop(botID) })
            }
            .navigationTitle(bot.name)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    AccountMenu(bot: bot, disabled: running) { model.setAccount($0, for: botID) }
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

/// The account a bot runs on, as a toolbar menu that switches it.
struct AccountMenu: View {
    let bot: Bot
    let disabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            Picker("Account", selection: Binding(get: { bot.accountID }, set: onSelect)) {
                ForEach(Accounts.all) { account in
                    Label(account.name, systemImage: account.symbol).tag(account.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(bot.account.name, systemImage: bot.account.symbol)
                .labelStyle(.titleAndIcon)
        }
        .help(disabled ? "The account can change once this turn ends" : "The account this bot runs on")
        .disabled(disabled)
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

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
