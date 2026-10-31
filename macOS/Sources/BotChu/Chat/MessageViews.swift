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
        case .user where message.heartbeat != nil:
            // BotChu's words, not the owner's: a line like its notes, with the full message on hover.
            Label(Heartbeat.label(number: message.heartbeat!), systemImage: "heart.text.square")
                .labelStyle(TightLabel())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .help(message.text)
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
            if let delivery = message.delivery { InboxReplyLine(delivery: delivery) }
            if let link = message.fromAgent { AgentMessageLine(link: link) }
            if !message.documents.isEmpty { MessageFiles(files: message.documents, bot: bot, alignment: .trailing) }
            if !message.text.isEmpty || !message.images.isEmpty {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty {
                        ForEach(message.images) { image in
                            let url = BotHome(workspace: bot.persistencePath).imageURL(image)
                            if ImageThumbnails.shared.pixelSize(of: url) != nil {
                                ThumbnailImage(url: url, pixels: ImageThumbnails.preview, label: image.name).frame(maxWidth: 320, maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 8)).help(image.name)
                                    .onTapGesture { NSWorkspace.shared.open(url) }
                            } else { Label(image.name + " (image unavailable)", systemImage: "photo") }
                        }
                    }
                    if !message.text.isEmpty { Text(Self.withMentions(message)).textSelection(.enabled) }
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    // Another bot's words aren't the owner's: they keep the reply's colors.
                    .foregroundStyle(message.fromAgent == nil ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .background(RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                        .fill(message.fromAgent == nil ? Color.accentColor : Theme.replyBackground))
                    .overlay {
                        if message.fromAgent != nil {
                            RoundedRectangle(cornerRadius: Theme.bubbleRadius).strokeBorder(Color.primary.opacity(0.08))
                        }
                    }
            }
            }
            }
            .padding(.top, 6)
        case .assistant:
            BotTurnRow(bot: bot, showsAvatar: startsBotTurn) {
                VStack(alignment: .leading, spacing: 8) {
                    if !message.text.isEmpty || message.documents.isEmpty {
                        MarkdownText(text: message.text, fitsText: true)
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
                    if !message.documents.isEmpty { MessageFiles(files: message.documents, bot: bot, alignment: .leading) }
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

/// Over a message between bots: the bot it is from (or whose reply it is), opening that bot's side.
struct AgentMessageLine: View {
    @Environment(AppModel.self) private var model
    let link: AgentLink

    var body: some View {
        let target = link.taskID.map { ChatTarget.task($0, of: link.botID) } ?? .home(link.botID)
        let title = link.messageID == nil ? "From \(link.name)" : link.failed == true ? "\(link.name) couldn't answer" : "\(link.name) replied"
        Button { if model.bot(link.botID) != nil { model.show(target) } } label: {
            Label(title, systemImage: link.messageID == nil ? "arrow.down.left" : "arrowshape.turn.up.left")
                .labelStyle(TightLabel())
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(link.messageID == nil ? "Open the conversation it came from" : "Open \(link.name)")
    }
}

/// A message's documents, each opening in its app, an image as its picture.
struct MessageFiles: View {
    let files: [FileAttachment]
    let bot: Bot
    let alignment: HorizontalAlignment

    var body: some View {
        let home = BotHome(workspace: bot.persistencePath)
        VStack(alignment: alignment, spacing: 6) {
            ForEach(files) { file in
                let url = home.fileURL(file)
                if file.type?.hasPrefix("image/") == true, ImageThumbnails.shared.pixelSize(of: url) != nil {
                    ThumbnailImage(url: url, pixels: ImageThumbnails.preview, label: file.name).frame(maxWidth: 320, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { NSWorkspace.shared.open(url) }
                        .fileActions(url)
                        .help(file.name)
                } else {
                    MessageFileCard(file: file, url: url)
                }
            }
        }
    }
}

/// A document's icon, name and size; it opens in its app and drags out as itself.
struct MessageFileCard: View {
    let file: FileAttachment
    let url: URL

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(exists ? ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file) : "Unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.replyBackground))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .fileActions(url)
        .help(file.name)
        .accessibilityLabel("Open \(file.name)")
    }
}

extension View {
    /// Drags out as the file, with Open and Show in Finder on a right click.
    func fileActions(_ url: URL) -> some View {
        onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .contextMenu {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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

extension EnvironmentValues {
    /// In a Project Area's chat, the area's own bot: another bot's turn there (a cameo, #406) shows
    /// its name with its avatar. Nil elsewhere.
    @Entry var areaBotID: UUID?
}

/// A row of the bot's turn: its avatar (or the avatar's space) and the content beside it; in an
/// area, another bot's turn also starts with its name.
struct BotTurnRow<Content: View>: View {
    @Environment(\.areaBotID) private var areaBotID
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
            VStack(alignment: .leading, spacing: 4) {
                if showsAvatar, let areaBotID, areaBotID != bot.id {
                    Text(bot.name)
                        .font(.callout.weight(.semibold))
                        .accessibilityIdentifier("cameo-speaker")
                }
                content
            }
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

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { dot in
                let lift = TypingWave.lift(dot: dot, at: date)
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * lift)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.15 * lift)
                    .offset(y: reduceMotion ? 0 : -3 * lift)
            }
        }
    }
}
