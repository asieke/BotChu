import SwiftUI

/// A roomy writing area that stays usable while the bot works. Stop and Send are separate actions.
struct Composer<Controls: View>: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    /// "Message Scout", or for a task, "Message Scout about GitChu #48".
    let placeholder: String
    let running: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    @ViewBuilder let controls: Controls

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(2...10)
                .focused(focused)
                .onSubmit(onSend)
                .padding(.horizontal, 4)
                .accessibilityLabel(placeholder)
            HStack(spacing: 8) {
                controls
                if running {
                    button("stop.fill", label: "Stop", help: "Stop (⌘.)", action: onStop)
                }
                button("arrow.up", label: running ? "Queue message" : "Send", enabled: !isEmpty,
                       help: running ? "Queue after this turn (Return; Option-Return for a new line)"
                           : "Send (Return; Option-Return for a new line)", action: onSend)
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

    private func button(_ symbol: String, label: String, enabled: Bool = true, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(enabled ? Color(nsColor: .controlBackgroundColor) : Color.secondary)
                .background(Circle().fill(enabled ? Color.primary : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(help)
    }
}
