import SwiftUI

/// The message field, with Send (or Stop while the bot works) inside it.
struct Composer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let botName: String
    let running: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(botName)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .focused(focused)
                .onSubmit(onSend)
                .padding(.vertical, 5)
            if running {
                button("stop.circle.fill", help: "Stop (⌘.)", action: onStop)
                    .foregroundStyle(.secondary)
            } else {
                button("arrow.up.circle.fill", help: "Send (Return; Option-Return for a new line)", action: onSend)
                    .foregroundStyle(isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor))
                    .disabled(isEmpty)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 24))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
