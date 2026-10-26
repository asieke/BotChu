import SwiftUI
import BotChuCore

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let bot: Bot
    /// The CLI of the conversation's account, whose tool calls these are.
    let kind: AgentKind
    /// The first reply or tool call after the owner's message carries the bot's avatar.
    let startsBotTurn: Bool

    /// The owner's text, with the agents and projects chosen in it from `@` and `#` in semibold.
    static func withMentions(_ message: ChatMessage) -> AttributedString {
        var text = AttributedString(message.text)
        for reference in MessageReference.standing(message.mentions, in: message.text) {
            if let range = Range(reference.range, in: text) { text[range].font = .body.weight(.semibold) }
        }
        return text
    }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
            if let delivery = message.delivery { InboxReplyLine(delivery: delivery) }
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty {
                        ForEach(message.images) { image in
                            let url = BotHome(workspace: bot.persistencePath).imageURL(image)
                            if let preview = NSImage(contentsOf: url) {
                                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 8)).help(image.name)
                                    .accessibilityLabel(image.name)
                                    .onTapGesture { NSWorkspace.shared.open(url) }
                            } else { Label(image.name + " (image unavailable)", systemImage: "photo") }
                        }
                    }
                    if !message.text.isEmpty { Text(Self.withMentions(message)).textSelection(.enabled) }
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: Theme.bubbleRadius).fill(Color.accentColor))
            }
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
        case .note where message.delivery != nil:
            BotTurnRow(bot: bot, showsAvatar: false) { DeliveryCard(id: message.delivery!, fallback: message.text) }
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
        if let link = message.jobRun {
            jobReceipt(link)
        } else {
            taskReceipt
        }
    }

    /// A scheduled job's finding or failure, with its run to open.
    private func jobReceipt(_ link: JobRunLink) -> some View {
        let job = model.jobs.job(link.job)
        let failed = job?.runs.first { $0.id == link.run }.map { $0.outcome == .failed || $0.outcome == .interrupted } ?? false
        return HStack(spacing: 6) {
            Image(systemName: failed ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(message.text)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if job != nil {
                Button("Open Run") { model.jobs.open(run: link.run, of: link.job) }
                    .buttonStyle(.link)
                    .help("Open this run's task, or the job's history for a run from before runs were tasks")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var taskReceipt: some View {
        // A task this conversation handed to another bot is that bot's.
        let owner = message.taskBotID ?? botID
        let task = message.taskID.flatMap { model.task($0, of: owner) }
        return HStack(spacing: 6) {
            Image(systemName: task == nil ? "exclamationmark.triangle" : "checklist")
                .foregroundStyle(task == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            Text(message.text)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let task {
                Button(task.isArchived ? "Reopen" : "Open") {
                    let target = ChatTarget.task(task.id, of: owner)
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

/// One tool call as it was before grouping, and as Raw density shows every call: its name and
/// input, opening to its arguments and output.
struct ToolCard: View {
    /// In a chat, which keeps it opened while its row is gone out of view; elsewhere, nil.
    @Environment(TranscriptModel.self) private var transcript: TranscriptModel?
    let message: ChatMessage
    let kind: AgentKind
    @State private var opened = false

    private var expanded: Bool { transcript?.isExpanded(message.id) ?? opened }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if let transcript { transcript.toggleExpanded(message.id) } else { opened.toggle() }
                }
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
                ToolDetail(message: message, kind: kind)
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

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}

/// While a turn works and nothing of its reply shows yet: three dots rising and brightening in a
/// wave, drawn from the clock.
struct TypingIndicator: View {
    let bot: Bot
    let showsAvatar: Bool

    var body: some View {
        BotTurnRow(bot: bot, showsAvatar: showsAvatar) {
            TimelineView(.animation(minimumInterval: 1 / 60)) { context in
                TypingDots(date: context.date)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.replyBackground))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }
}

/// The dots at one moment: each rises and brightens in turn, then all three rest before the next
/// wave. With Reduce Motion they only brighten, in place.
struct TypingDots: View {
    let date: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let period: TimeInterval = 1.3

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { dot in
                let lift = Self.lift(dot: dot, at: date)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * lift)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.15 * lift)
                    .offset(y: reduceMotion ? 0 : -3 * lift)
            }
        }
    }

    /// How far a dot is through its rise, 0 at rest and 1 at the top: a smooth bump over the
    /// first half of its turn, each dot starting a little after the one before it.
    static func lift(dot: Int, at date: Date) -> Double {
        var phase = (date.timeIntervalSinceReferenceDate / period - Double(dot) * 0.15).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        guard phase < 0.5 else { return 0 }
        return (1 - cos(2 * .pi * phase / 0.5)) / 2
    }
}
