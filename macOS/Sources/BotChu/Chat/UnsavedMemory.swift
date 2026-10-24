import SwiftUI

/// Notes the bot asked to remember that BotChu couldn't save yet, above the composer, with Retry.
/// BotChu also tries them again after each turn.
struct UnsavedMemory: View {
    let count: Int
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(count == 1 ? "1 note not saved to memory yet" : "\(count) notes not saved to memory yet",
                  systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .help("Save the waiting notes now. BotChu also tries again after each turn.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unsaved memory")
    }
}
