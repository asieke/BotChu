import SwiftUI
import BotChuCore

struct MessageRow: View {
    let message: ChatMessage
    let bot: Bot
    /// The CLI of the conversation's account, whose tool calls these are.
    let kind: AgentKind
    /// The first reply or tool call after the owner's message carries the bot's avatar.
    let startsBotTurn: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty {
                        ForEach(message.images) { image in
                            let url = BotHome(workspace: bot.workspace).imageURL(image)
                            if let preview = NSImage(contentsOf: url) {
                                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 8)).help(image.name)
                                    .accessibilityLabel(image.name)
                                    .onTapGesture { NSWorkspace.shared.open(url) }
                            } else { Label(image.name + " (image unavailable)", systemImage: "photo") }
                        }
                    }
                    if !message.text.isEmpty { Text(message.text).textSelection(.enabled) }
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: Theme.bubbleRadius).fill(Color.accentColor))
            }
            .padding(.top, 6)
        case .assistant:
            BotTurnRow(bot: bot, showsAvatar: startsBotTurn) {
                MarkdownText(text: message.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Theme.replyBackground)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.045))
                    }
            }
        case .tool:
            BotTurnRow(bot: bot, showsAvatar: startsBotTurn) {
                ToolCard(message: message, kind: kind)
            }
        case .receipt:
            ReceiptRow(message: message, botID: bot.id)
        case .error:
            Label {
                Text(message.text).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Color.red.opacity(0.08)))
        case .note:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
    }
}

/// BotChu's word in a bot's Home about one of its tasks, with a way to open the task's tab.
struct ReceiptRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let botID: UUID

    var body: some View {
        let task = message.taskID.flatMap { model.task($0, of: botID) }
        HStack(spacing: 6) {
            Image(systemName: task == nil ? "exclamationmark.triangle" : "checklist")
                .foregroundStyle(task == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(message.text)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let task {
                Button(task.isArchived ? "Reopen" : "Open") {
                    let target = ChatTarget.task(task.id, of: botID)
                    task.isArchived ? model.reopenTask(target) : model.show(target)
                }
                .buttonStyle(.link)
                .help("Show \(task.title)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

/// A row of the bot's turn: its avatar (or the avatar's space) and the content beside it.
struct BotTurnRow<Content: View>: View {
    let bot: Bot
    let showsAvatar: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsAvatar {
                BotAvatar(bot: bot, size: Theme.messageAvatar)
            } else {
                Color.clear.frame(width: Theme.messageAvatar, height: 1)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, showsAvatar ? 6 : 0)
    }
}

struct ToolCard: View {
    let message: ChatMessage
    let kind: AgentKind
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    status
                    Text(message.toolName ?? "Tool")
                        .font(.callout.weight(.medium))
                    Text(firstLine(message.toolInput ?? ""))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if message.displayedToolState(for: kind) == .interrupted {
                        Text("No completion was recorded for this tool call.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let input = message.toolInput, !input.isEmpty {
                        detail(input)
                    }
                    if let output = message.toolOutput, !output.isEmpty {
                        Divider()
                        ScrollView {
                            detail(String(output.prefix(20_000)))
                        }
                        .frame(maxHeight: 260)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Color.primary.opacity(0.07)))
    }

    @ViewBuilder private var status: some View {
        switch message.displayedToolState(for: kind) {
        case .running: ProgressView().controlSize(.mini).frame(width: 14)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary).frame(width: 14)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red).frame(width: 14)
        case .interrupted:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).frame(width: 14)
                .help("No completion was recorded")
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}

struct TypingIndicator: View {
    let bot: Bot
    let showsAvatar: Bool
    @State private var phase = 0.0

    var body: some View {
        BotTurnRow(bot: bot, showsAvatar: showsAvatar) {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(phase - Double(i) * 0.8)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.replyBackground))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
        .accessibilityLabel("Working")
    }
}
