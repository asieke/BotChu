import SwiftUI
import BotChuCore

/// A delivery being read: where it is about and who sent it, its note, what came with it as cards,
/// the exchange under it, and a composer that replies into the conversation that sent it, with its
/// question's choices above it.
struct InboxReader: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery
    @State private var composerFocused = false

    /// The reading column's widest, as the chat's.
    static let column: CGFloat = 800

    var body: some View {
        let target = model.inbox.target(of: delivery)
        let exchange = InboxReply.exchange(for: delivery.id, in: model.thread(target))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if !delivery.note.isEmpty {
                        MarkdownText(text: delivery.note)
                            .padding(.top, 16)
                    }
                    DeliveryCards(delivery: delivery)
                        .padding(.top, 6)
                    InboxThread(delivery: delivery, exchange: exchange)
                    Color.clear.frame(height: 24).id("end")
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: exchange.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
            // Opened for a new answer: at the exchange's end.
            .task(id: delivery.id) {
                try? await Task.sleep(for: .milliseconds(150))
                guard model.inbox.openedAsNews.remove(delivery.id) != nil,
                      !InboxReply.exchange(for: delivery.id, in: model.thread(target)).isEmpty else { return }
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { dock(target: target) }
        // The conversation's history holds the exchange: read it if it isn't in memory.
        .onAppear { model.hydrate(target) }
        .accessibilityIdentifier("inbox-reader")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let context = context {
                Text(context)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            Text(delivery.title)
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 5)
                .padding(.bottom, 14)
            HStack(spacing: 12) {
                SenderAvatars(delivery: delivery, size: 38, cutout: Palette.chat)
                VStack(alignment: .leading, spacing: 2) {
                    senderLine
                        .font(.system(size: 13))
                    HStack(spacing: 5) {
                        let origin = InboxOrigin(model: model, delivery: delivery)
                        Image(systemName: origin.symbol).font(.system(size: 10))
                        Text(origin.name)
                        Text("·")
                        Text(InboxTime.long(delivery.updatedAt))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                }
            }
        }
    }

    /// "Product Fox with Research Assistant".
    private var senderLine: Text {
        var line = Text(model.bot(delivery.botID)?.name ?? "Bot").fontWeight(.semibold)
        let credits = delivery.credits.map(\.name)
        if !credits.isEmpty {
            line = line + Text(" with ").foregroundStyle(Palette.secondaryText)
                + Text(ListFormatter.localizedString(byJoining: credits)).fontWeight(.semibold)
        }
        return line
    }

    /// The repository and what in it: a task's, else the first link's.
    private var context: String? {
        if let task = delivery.taskID.flatMap({ model.task($0, of: delivery.botID) }), task.jobRun == nil {
            return task.repo + (task.work.map { " · #\($0.number)" } ?? task.pullRequest.map { " · #\($0)" } ?? "")
        }
        guard let first = delivery.links.first else { return nil }
        let numbers = delivery.links.filter { $0.repo == first.repo }.map { "#\($0.number)" }
        return first.repo + " · " + numbers.prefix(4).joined(separator: ", ")
    }

    // MARK: Dock

    private func dock(target: ChatTarget) -> some View {
        VStack(spacing: 10) {
            if let question = delivery.question, model.inbox.state.needsAnswer(delivery) {
                QuestionBar(question: question) { choice in _ = model.inbox.reply(choice, to: delivery.id) }
            }
            let sender = model.bot(delivery.botID)?.name ?? "the bot"
            let origin = InboxOrigin(model: model, delivery: delivery)
            Composer(draft: Binding(get: { model.inbox.drafts[delivery.id] ?? "" }, set: { model.inbox.drafts[delivery.id] = $0 }),
                     focused: $composerFocused, addsImages: false, placeholder: "Reply to \(sender)", running: false,
                     onSend: send, onStop: {}) {
                Spacer(minLength: 0)
                Label(origin.name, systemImage: origin.symbol)
                    .labelStyle(TightLabel())
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .accessibilityLabel("To \(origin.name)")
            }
        }
        .frame(maxWidth: Self.column)
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func send() {
        let id = delivery.id, inbox = model.inbox!
        let draft = inbox.drafts[id] ?? ""
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Should the queue not save it, it comes back to the box.
        if inbox.reply(draft, to: id, accepted: { accepted in
            if !accepted { inbox.drafts[id] = draft + (inbox.drafts[id].map { $0.isEmpty ? "" : "\n\n" + $0 } ?? "") }
        }) {
            inbox.drafts[id] = nil
        }
    }
}

/// The bot's question, answered in one click: each choice is sent as the reply, word for word.
private struct QuestionBar: View {
    let question: Delivery.Question
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text(question.text).font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "questionmark.circle").foregroundStyle(Palette.needs)
            }
            if !question.choices.isEmpty {
                FlowRow(spacing: 8) {
                    ForEach(question.choices, id: \.self) { choice in
                        Button { choose(choice) } label: {
                            Text(choice)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(Capsule().fill(Palette.card))
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("inbox-choice-\(choice)")
                    }
                }
                .padding(.leading, 23)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.needsBackground))
    }
}

/// Views in a row, wrapping onto more rows as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// The exchange under a delivery: the owner's replies as the chat's bubbles, the bot's answers as
/// its replies, what waits in the queue, and the bot at work on it.
private struct InboxThread: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery
    let exchange: [ChatMessage]

    var body: some View {
        let target = model.inbox.target(of: delivery)
        let origin = InboxOrigin(model: model, delivery: delivery)
        let bot = model.bot(delivery.botID)
        let queued = (model.messageQueues[target]?.pending ?? []).filter { $0.delivery == delivery.id }
        let answering = model.isRunning(target) && model.thread(target).last(where: { $0.role == .user })?.delivery == delivery.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(exchange) { message in
                switch message.role {
                case .user:
                    OwnerReply(text: message.text, meta: "Sent to \(origin.name) · \(message.date.formatted(date: .omitted, time: .shortened))",
                               symbol: origin.symbol)
                case .error:
                    Label(message.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.top, 14)
                default:
                    if let bot { BotAnswer(bot: bot, text: message.text, date: message.date) }
                }
            }
            ForEach(queued) { message in
                OwnerReply(text: message.text, meta: model.isRunning(target) ? "Queued for \(origin.name)" : "Sending to \(origin.name)",
                           symbol: "clock")
            }
            if answering, let bot {
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 28, activity: .thinking, animates: true)
                    Text(bot.name).font(.system(size: 13, weight: .semibold))
                    + Text(" · " + (model.status(of: target)?.activity.doing ?? "Working…")).foregroundStyle(Palette.secondaryText)
                    Spacer(minLength: 0)
                    ProgressView().controlSize(.small)
                }
                .font(.system(size: 13))
                .padding(.top, 18)
                .accessibilityIdentifier("inbox-working")
            }
        }
    }
}

private struct OwnerReply: View {
    let text: String
    let meta: String
    let symbol: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.system(size: 13.5))
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor))
            Label(meta, systemImage: symbol)
                .labelStyle(TightLabel())
                .font(.system(size: 11))
                .foregroundStyle(Palette.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 120)
        .padding(.top, 16)
    }
}

private struct BotAnswer: View {
    let bot: Bot
    let text: String
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BotAvatar(bot: bot, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bot.name).font(.system(size: 13, weight: .semibold))
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(height: 28)
                MarkdownText(text: text)
            }
        }
        .padding(.top, 18)
    }
}
