import SwiftUI
import BotChuCore

/// Settings ▸ Telegram: the owner's private Telegram chats, each reaching a bot's Home (see
/// `TelegramBridge`), and the bot token, kept in the Keychain.
struct TelegramSection: View {
    @Environment(AppModel.self) private var model
    @State private var token = Keychain.get(Keychain.telegramAccount) ?? ""
    @State private var savedToken = Keychain.get(Keychain.telegramAccount) ?? ""
    @State private var chatID = ""

    var body: some View {
        @Bindable var settings = model.settings
        let telegram: TelegramBridge = model.telegram
        Section {
            Toggle("Reach bots from Telegram", isOn: $settings.telegramEnabled)
            LabeledContent("Bot token") {
                HStack {
                    SecureField("Bot token", text: $token, prompt: Text("123456789:AA…"))
                        .labelsHidden()
                        .onSubmit(saveToken)
                    Button("Save", action: saveToken)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines) == savedToken)
                    if !savedToken.isEmpty {
                        Button("Remove") {
                            token = ""
                            saveToken()
                        }
                        .help("Delete the token from the Keychain")
                    }
                }
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Text(telegram.summary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                    Circle()
                        .fill(color(for: telegram.state))
                        .frame(width: 8, height: 8)
                }
            }
            ForEach(settings.telegramChats) { chat in
                LabeledContent {
                    HStack {
                        Picker("Bot", selection: bot(of: chat.id)) {
                            Text("No bot").tag(UUID?.none)
                            ForEach(model.bots) { bot in
                                Text(verbatim: "\(bot.emoji) \(bot.name)").tag(UUID?.some(bot.id))
                            }
                            if let id = chat.botID, model.bot(id) == nil {
                                Text("Deleted bot").tag(UUID?.some(id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            settings.telegramChats.removeAll { $0.id == chat.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop letting this chat reach a bot")
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: chat.label.isEmpty ? "Chat \(chat.id)" : chat.label)
                        Text(verbatim: "Chat \(chat.id) · reaches the bot's Home")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(telegram.refused) { refusal in
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Refused \(refusal.name)")
                        Text(verbatim: refusal.isPrivate ? "Chat \(refusal.id)" : "Chat \(refusal.id) · only your private chat can be allowed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if refusal.isPrivate {
                        Button("Allow") { telegram.allow(refusal) }
                    }
                }
            }
            LabeledContent("Chat ID") {
                HStack {
                    TextField("Chat ID", text: $chatID, prompt: Text("123456789"))
                        .labelsHidden()
                        .onSubmit(addChat)
                    Button("Allow Chat", action: addChat)
                        .disabled(newChatID == nil)
                }
            }
        } header: {
            Text("Telegram")
        } footer: {
            HStack(spacing: 4) {
                Text("Your private chat with your own Telegram bot reaches the bot chosen here, in its Home, while BotChu runs; anyone else is ignored. The token is kept in your Keychain.")
                Link("Set up", destination: URL(string: "https://github.com/asieke/BotChu/blob/main/docs/telegram.md")!)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var newChatID: Int64? {
        Int64(chatID.trimmingCharacters(in: .whitespaces)).flatMap { id in
            id > 0 && !model.settings.telegramChats.contains { $0.id == id } ? id : nil
        }
    }

    private func bot(of chat: Int64) -> Binding<UUID?> {
        Binding(get: { model.settings.telegramChats.first { $0.id == chat }?.botID },
                set: { bot in
                    if let i = model.settings.telegramChats.firstIndex(where: { $0.id == chat }) { model.settings.telegramChats[i].botID = bot }
                })
    }

    private func addChat() {
        guard let id = newChatID else { return }
        model.settings.telegramChats.append(TelegramChat(id: id, botID: model.selection ?? model.bots.first?.id))
        chatID = ""
    }

    private func saveToken() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(value, for: Keychain.telegramAccount)
        token = value
        savedToken = value
        model.telegram.restart()
    }

    private func color(for state: TelegramBridge.State) -> Color {
        switch state {
        case .off: .gray.opacity(0.4)
        case .needsToken, .running(.connecting), .running(.retrying): .orange
        case .running(.connected): .green
        case .running(.stopped): .red
        }
    }
}
