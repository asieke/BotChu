import SwiftUI
import BotChuCore

/// A delivery in the chat of the conversation that sent it: that it went to the Inbox and when,
/// its title, what came with it, and Show in Inbox.
struct DeliveryCard: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    /// The note's text, for a delivery that is gone.
    let fallback: String

    var body: some View {
        if let delivery = model.inbox.delivery(id) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                    Text("Delivered to your Inbox").font(.system(size: 12, weight: .semibold))
                    Text("· " + delivery.sentAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                    Spacer(minLength: 8)
                    Button("Show in Inbox") { model.showDelivery(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.violet)
                        .accessibilityIdentifier("delivery-show-\(id)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 7) {
                    Text(delivery.title)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    FlowRow(spacing: 6) {
                        ForEach(delivery.files, id: \.name) { file in
                            Chip(symbol: DeliveryFileLook.symbol(file.kind), text: file.name)
                        }
                        if !delivery.pullRequests.isEmpty {
                            Chip(symbol: "arrow.triangle.pull", text: DeliveryFileLook.numbers(delivery.pullRequests))
                        }
                        if !delivery.issues.isEmpty {
                            Chip(symbol: "smallcircle.filled.circle", text: DeliveryFileLook.numbers(delivery.issues))
                        }
                        ForEach(delivery.credits, id: \.botID) { credit in
                            Chip(symbol: "person.2", text: "with \(credit.name)")
                        }
                        if let question = delivery.question {
                            Label("Asked: \(question.text)", systemImage: "questionmark.circle")
                                .labelStyle(TightLabel())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.needs)
                                .frame(height: 20)
                        }
                    }
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("delivery-card-\(id)")
        } else {
            Text(fallback)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Above a reply sent from the Inbox: which delivery it answers.
struct InboxReplyLine: View {
    @Environment(AppModel.self) private var model
    let delivery: UUID

    var body: some View {
        let title = model.inbox.delivery(delivery)?.title
        Button { if title != nil { model.showDelivery(delivery) } } label: {
            Label("Reply from your Inbox" + (title.map { " · \($0)" } ?? ""), systemImage: "tray")
                .labelStyle(TightLabel())
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inbox-reply-line")
    }
}
