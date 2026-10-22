import SwiftUI
import BotChuCore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        if let bot = model.bot(botID) {
            let messages = model.thread(botID)
            let running = model.running.contains(botID)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            BotIntro(bot: bot)
                            ForEach(messages) { message in
                                MessageRow(message: message, bot: bot)
                                    .id(message.id)
                            }
                            if running, messages.last?.role != .assistant {
                                TypingIndicator()
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: running) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Divider()
                Composer(draft: $draft, focused: $composerFocused, botName: bot.name, running: running,
                         onSend: send, onStop: { model.stop(botID) })
            }
            .background(.background)
            .navigationTitle(bot.name)
            .navigationSubtitle(bot.title.isEmpty ? bot.account.name : bot.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("Account", selection: Binding(get: { bot.accountID }, set: { model.setAccount($0, for: botID) })) {
                            ForEach(Accounts.all) { account in
                                Label(account.name, systemImage: account.symbol).tag(account.id)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(bot.account.name, systemImage: bot.account.symbol)
                            .labelStyle(.titleAndIcon)
                    }
                    .help("The account this bot runs on")
                    .disabled(running)

                    Button { model.newSession(botID) } label: { Label("New Session", systemImage: "arrow.counterclockwise") }
                        .help("Start the next message in a fresh session (⌘K)")
                        .disabled(running)
                    Button { model.revealWorkspace(botID) } label: { Label("Workspace", systemImage: "folder") }
                        .help("Show the workspace in Finder")
                    Button { model.edit(botID) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                        .help("Edit the bot (⌘E)")
                }
            }
            .onAppear { composerFocused = true }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.running.contains(botID) else { return }
        draft = ""
        model.send(text, to: botID)
    }
}

struct BotIntro: View {
    let bot: Bot

    var body: some View {
        VStack(spacing: 8) {
            BotAvatar(bot: bot, size: 56)
            Text(bot.name).font(.title2.weight(.semibold))
            if !bot.title.isEmpty {
                Text(bot.title).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text((bot.workspace as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(bot.workspace)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let botName: String
    let running: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message \(botName)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused(focused)
                .onSubmit(onSend)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
            if running {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Stop (⌘.)")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Return; Option-Return for a new line)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }
}

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(0.3 + 0.7 * max(0, sin(phase - Double(i) * 0.8)))
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
        .accessibilityLabel("Working")
    }
}
