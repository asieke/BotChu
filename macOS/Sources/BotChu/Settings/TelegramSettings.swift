import SwiftUI
import BotChuCore

/// Settings ▸ Telegram: the owner's private Telegram chats, each reaching a bot's Home (see
/// `TelegramBridge`), and the bot token, kept in the Keychain. The token typed stays in Settings'
/// drafts while its pages change.
struct TelegramSection: View {
    @Environment(AppModel.self) private var model
    @Binding var token: SettingsKeyDraft
    @State private var chatID = ""

    var body: some View {
        @Bindable var settings = model.settings
        let telegram: TelegramBridge = model.telegram
        Section {
            Toggle("Reach bots from Telegram", isOn: $settings.telegramEnabled)
                .help("Your private chat with your own Telegram bot reaches the bot chosen here, in its Home, while BotChu runs, or another bot it chooses with @; anyone else is ignored.")
            LabeledContent("Bot token") {
                HStack {
                    SecureField("Bot token", text: Binding(get: { token.text ?? "" }, set: { token.text = $0 }), prompt: Text("123456789:AA…"))
                        .labelsHidden()
                        .settingsField()
                        .onSubmit(saveToken)
                        .help("Kept in your Keychain")
                    Button("Save", action: saveToken)
                        .disabled(!token.isUnsaved)
                        .buttonStyle(.borderedProminentIf(token.isUnsaved))
                    if !token.saved.isEmpty {
                        Button("Remove") {
                            token.text = ""
                            saveToken()
                        }
                        .help("Delete the token from the Keychain")
                    }
                }
            }
            LabeledContent("Status") {
                Label {
                    Text(telegram.summary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } icon: {
                    Image(systemName: symbol(for: telegram.state)).foregroundStyle(color(for: telegram.state))
                }
            }
        }
        Section("Chats") {
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
                        .help("The bot this chat reaches, in its Home, or another bot it chooses with @")
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
                        if !chat.label.isEmpty {
                            Text(verbatim: "Chat \(chat.id)")
                                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(telegram.refused) { refusal in
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Refused \(refusal.name)")
                        Text(verbatim: "Chat \(refusal.id)")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if refusal.isPrivate {
                        Button("Allow") { telegram.allow(refusal) }
                    } else {
                        Text("Group")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            .help("Only your private chat can be allowed")
                    }
                }
            }
            LabeledContent("Chat ID") {
                HStack {
                    TextField("Chat ID", text: $chatID, prompt: Text("123456789"))
                        .labelsHidden()
                        .settingsField()
                        .onSubmit(addChat)
                    Button("Allow Chat", action: addChat)
                        .disabled(newChatID == nil)
                }
            }
        }
        .onAppear { token.seed(saved: model.telegram.readToken()) }
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
        guard token.isUnsaved else { return }
        Keychain.set(token.save(), for: Keychain.telegramAccount)
        model.telegram.restart()
    }

    private func symbol(for state: TelegramBridge.State) -> String {
        switch state {
        case .off: "minus.circle"
        case .needsToken, .running(.connecting), .running(.retrying): "exclamationmark.triangle.fill"
        case .running(.connected): "checkmark.circle.fill"
        case .running(.stopped): "xmark.octagon.fill"
        }
    }

    private func color(for state: TelegramBridge.State) -> Color {
        switch state {
        case .off: .secondary
        case .needsToken, .running(.connecting), .running(.retrying): Palette.warning
        case .running(.connected): .green
        case .running(.stopped): .red
        }
    }
}
