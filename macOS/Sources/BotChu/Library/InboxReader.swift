import SwiftUI
import BotChuCore

/// A delivery being read: what it asks of the owner, where it is about and who sent it, its note, what came with it as cards,
/// and a composer that replies into the conversation that sent it, with its question's choices above
/// it. What the bot does with a reply shows in that conversation, which opens once the reply is in
/// its queue.
struct InboxReader: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery
    @State private var focusedDelivery: UUID?

    private var composerFocused: Binding<Bool> {
        Binding(get: { focusedDelivery == delivery.id }, set: { focusedDelivery = $0 ? delivery.id : nil })
    }

    /// The reading column's widest, as the chat's.
    static let column: CGFloat = 800

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if !delivery.note.isEmpty {
                        MarkdownText(text: delivery.note)
                            .padding(.top, 16)
                    }
                    DeliveryCards(delivery: delivery)
                        .padding(.top, 6)
                    Color.clear.frame(height: 24)
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 26)
                .frame(maxWidth: .infinity)
                // Reset the reading contents, including their top inset, but retain the reply editor.
                .id(delivery.id)
            }
            .onChange(of: delivery.id) { _, id in scroll.scrollTo(id, anchor: .top) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .accessibilityIdentifier("inbox-reader")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PurposeLabel(delivery: delivery)
                if let context = context {
                    Text(context)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
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

    private var dock: some View {
        VStack(spacing: 10) {
            if let question = delivery.question {
                QuestionBar(delivery: delivery, question: question)
            }
            DeliverySendFailure(delivery: delivery)
            let sender = model.bot(delivery.botID)?.name ?? "the bot"
            let origin = InboxOrigin(model: model, delivery: delivery)
            Composer(draft: Binding(get: { model.inbox.drafts[delivery.id] ?? "" }, set: { model.inbox.drafts[delivery.id] = $0 }),
                     focused: composerFocused, draftID: delivery.id, addsImages: false, placeholder: "Reply to \(sender)", running: false,
                     onSend: { model.inbox.reply(model.inbox.drafts[delivery.id] ?? "", to: delivery.id) }, onStop: {}) {
                Spacer(minLength: 0)
                Label(origin.name, systemImage: origin.symbol)
                    .labelStyle(TightLabel())
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .accessibilityLabel("To \(origin.name)")
            }
            // One reply at a time: the box waits while the queue takes it.
            .disabled(model.inbox.sending.contains(delivery.id))
        }
        .frame(maxWidth: Self.column)
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The bot's question, with its choices until the owner answers it (the reader's ⌘1 to ⌘9 send them),
/// then when it was answered.
private struct QuestionBar: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery
    let question: Delivery.Question

    var body: some View {
        let answered = model.inbox.state.isAnswered(delivery) ? model.inbox.state[delivery.id].repliedAt : nil
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label {
                    Text(question.text).font(.system(size: 13, weight: .semibold))
                } icon: {
                    Image(systemName: answered == nil ? "questionmark.circle" : "checkmark.circle")
                        .foregroundStyle(answered == nil ? Palette.needs : Palette.secondaryText)
                }
                Spacer(minLength: 0)
                if let answered {
                    Text("Answered \(answered.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityIdentifier("inbox-answered")
                }
            }
            if answered == nil, !question.choices.isEmpty {
                DeliveryChoices(delivery: delivery, shortcuts: true)
                    .padding(.leading, 23)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(answered == nil ? Palette.needsBackground : Palette.card))
    }
}

/// A question's choices, each sent as the reply word for word in one click, the bot's recommended one
/// filled; none while a reply to the delivery is being taken. With `shortcuts`, ⌘1 to ⌘9 send the
/// first nine.
struct DeliveryChoices: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery
    var shortcuts = false
    var compact = false

    var body: some View {
        let sending = model.inbox.sending.contains(delivery.id)
        let choices = Array((delivery.question?.choices ?? []).enumerated())
        FlowRow(spacing: compact ? 6 : 8) {
            ForEach(choices, id: \.offset) { index, choice in
                let recommended = choice == delivery.question?.recommended
                Button { model.inbox.reply(choice, to: delivery.id) } label: {
                    Text(choice)
                        .font(.system(size: compact ? 12 : 13, weight: recommended ? .semibold : .medium))
                        .foregroundStyle(recommended ? Color.white : Color.primary)
                        .padding(.horizontal, compact ? 11 : 14)
                        .frame(height: compact ? 26 : 30)
                        .background(Capsule().fill(recommended ? Palette.needs : compact ? Palette.needsBackground : Palette.card))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(compact ? 0 : 0.05), radius: 1, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(ChoiceShortcut(index: shortcuts && index < 9 ? index : nil))
                .accessibilityLabel(recommended ? "\(choice), recommended" : choice)
                .accessibilityIdentifier("\(compact ? "delivery" : "inbox")-choice-\(choice)")
            }
        }
        .disabled(sending)
        .opacity(sending ? 0.5 : 1)
    }
}

/// ⌘ and the choice's number.
private struct ChoiceShortcut: ViewModifier {
    let index: Int?

    func body(content: Content) -> some View {
        if let index {
            content.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        } else {
            content
        }
    }
}

/// A reply the conversation's queue didn't take, with Try Again, which sends it again.
struct DeliverySendFailure: View {
    @Environment(AppModel.self) private var model
    let delivery: Delivery

    var body: some View {
        if let text = model.inbox.failed[delivery.id] {
            HStack(spacing: 8) {
                Label("Couldn't send to \(InboxOrigin(model: model, delivery: delivery).name)", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(TightLabel())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Try Again") { model.inbox.reply(text, to: delivery.id) }
                    .controlSize(.small)
                    .disabled(model.inbox.sending.contains(delivery.id))
                    .accessibilityIdentifier("delivery-retry-\(delivery.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
