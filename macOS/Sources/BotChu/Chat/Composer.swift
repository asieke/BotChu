import SwiftUI

/// A roomy writing area above the current account, generation controls and Send/Stop.
struct Composer<Controls: View>: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    let botName: String
    let running: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    @ViewBuilder let controls: Controls

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Message \(botName)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(2...10)
                .focused(focused)
                .onSubmit(onSend)
                .padding(.horizontal, 4)
                .accessibilityLabel("Message \(botName)")
            HStack(spacing: 12) {
                controls
                if running {
                    button("stop.fill", label: "Stop", help: "Stop (⌘.)", action: onStop)
                } else {
                    button("arrow.up", label: "Send", help: "Send (Return; Option-Return for a new line)", action: onSend)
                        .disabled(isEmpty)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(focused.wrappedValue ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.15))
        }
        .shadow(color: .black.opacity(0.05), radius: 12, y: 3)
    }

    private func button(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(isEmpty && !running ? Color.secondary : Color(nsColor: .controlBackgroundColor))
                .background(Circle().fill(isEmpty && !running ? Color.primary.opacity(0.08) : Color.primary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help)
    }
}
