import SwiftUI
import BotChuCore

/// Pending text stays close to the composer, separate from messages already sent to the bot.
struct QueuedMessages: View {
    let queue: MessageQueue
    let running: Bool
    let preparing: Bool
    let sendNow: () -> Void
    let edit: (UUID) -> Void
    let remove: (UUID) -> Void

    private var explanation: String {
        if queue.isInterrupting { return "Waiting for the current run to stop…" }
        if queue.isPaused { return "Paused · send when you’re ready" }
        if preparing { return "Will send after the first turn" }
        return "Will send after this turn"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("\(queue.messages.count) queued", systemImage: "text.bubble")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button(running ? "Send now" : "Send next", action: sendNow)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .disabled(preparing || queue.isInterrupting)
                    .help(running ? "Interrupt this turn, then send the oldest queued message in the same session."
                        : "Resume sending queued messages in order.")
            }
            Text(explanation).font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queue.messages) { message in
                        HStack(alignment: .top, spacing: 8) {
                            Text(message.text)
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(message.text)
                            Button { edit(message.id) } label: { Image(systemName: "pencil") }
                                .help("Move this message back to the composer")
                                .accessibilityLabel("Edit queued message")
                            Button { remove(message.id) } label: { Image(systemName: "xmark") }
                                .help("Remove this queued message")
                                .accessibilityLabel("Remove queued message")
                        }
                        .buttonStyle(.plain)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            .frame(height: CGFloat(min(queue.messages.count, 3)) * 48)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pending messages")
    }
}
