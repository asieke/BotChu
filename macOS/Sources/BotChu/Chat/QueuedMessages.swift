import SwiftUI
import BotChuCore

/// Pending text stays close to the composer, separate from messages already sent to the bot.
struct QueuedMessages: View {
    let queue: MessageQueue
    let running: Bool
    let preparing: Bool
    /// The CLI takes follow-ups during a turn, once its current step ends (Claude Code on This Mac).
    let midTurn: Bool
    /// A turn of the CLI runs, which Interrupt & send can stop for the next message.
    let canInterrupt: Bool
    let resume: () -> Void
    let edit: (UUID) -> Void
    let remove: (UUID) -> Void
    let interrupt: () -> Void

    private var explanation: String {
        if queue.isInterrupting { return "Stopping this turn to send the next message…" }
        if queue.isPaused { return "Paused · send when you’re ready" }
        if midTurn { return running ? "Reaches the bot when its current step ends" : "Sending…" }
        if preparing { return "Will send after the first turn" }
        return running ? "Will send when this turn ends" : "Sending…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("\(queue.pending.count) queued", systemImage: "text.bubble")
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
                    ForEach(queue.pending) { message in
                        HStack(alignment: .top, spacing: 8) {
                            Text(message.text + (message.images.isEmpty ? "" : "\n📎 \(message.images.count) image(s)"))
                                .font(.system(size: 12))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(message.text)
                            if queue.isInFlight(message.id) {
                                // Written to the CLI, which hasn't added it to the conversation yet.
                                Text("Not read yet").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                            }
                            if running, canInterrupt, queue.interruptible?.id == message.id {
                                Button("Interrupt & send", action: interrupt)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .fixedSize()
                                    .help("Stop this turn and its sub-agents, then send this message")
                            }
                            if !queue.isInFlight(message.id) {
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
            .frame(height: CGFloat(min(queue.pending.count, 3)) * 48)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pending messages")
    }
}
