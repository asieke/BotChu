import SwiftUI
import BotChuCore

/// Pending text stays close to the composer, separate from messages already sent to the bot.
struct QueuedMessages: View {
    let queue: MessageQueue
    let running: Bool
    let preparing: Bool
    /// The CLI takes follow-ups during a turn, at its next tool call (Claude Code on This Mac).
    let midTurn: Bool
    let resume: () -> Void
    let edit: (UUID) -> Void
    let remove: (UUID) -> Void

    private var explanation: String {
        if queue.isPaused { return "Paused · send when you’re ready" }
        if midTurn { return running ? "Will reach the bot at its next tool call" : "Sending…" }
        if preparing { return "Will send after the first turn" }
        return running ? "Will send when this turn ends" : "Sending…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("\(queue.messages.count) queued", systemImage: "text.bubble")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if queue.isPaused || !running {
                    Button("Send next", action: resume)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .help("Resume sending queued messages in order.")
                }
            }
            Text(explanation).font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(queue.messages) { message in
                        HStack(alignment: .top, spacing: 8) {
                            Text(message.text + (message.images.isEmpty ? "" : "\n📎 \(message.images.count) image(s)"))
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(message.text)
                            if queue.isInFlight(message.id) {
                                // Already written to the CLI, which takes it at its next tool call.
                                Text("Sent").font(.system(size: 11)).foregroundStyle(.secondary)
                                    .help("Sent to the bot, which reads it at its next tool call")
                            } else {
                                Button { edit(message.id) } label: { Image(systemName: "pencil") }
                                    .help("Move this message back to the composer")
                                    .accessibilityLabel("Edit queued message")
                                Button { remove(message.id) } label: { Image(systemName: "xmark") }
                                    .help("Remove this queued message")
                                    .accessibilityLabel("Remove queued message")
                            }
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
