import SwiftUI
import BotChuCore

struct MessageRow: View {
    let message: ChatMessage
    let bot: Bot

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor))
            }
        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                BotAvatar(bot: bot, size: 26)
                MarkdownText(text: message.text)
                Spacer(minLength: 40)
            }
        case .tool:
            ToolCard(message: message)
                .padding(.leading, 36)
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
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        case .note:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        }
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.split(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    static func attributed(_ prose: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: prose, options: options)) ?? AttributedString(prose)
    }
}

struct ToolCard: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
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
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = message.toolInput, !input.isEmpty {
                        detail(input)
                    }
                    if let output = message.toolOutput, !output.isEmpty {
                        Divider()
                        ScrollView {
                            detail(String(output.prefix(20_000)))
                        }
                        .frame(maxHeight: 260)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07)))
    }

    @ViewBuilder private var status: some View {
        switch message.toolState ?? .done {
        case .running: ProgressView().controlSize(.mini).frame(width: 14)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary).frame(width: 14)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red).frame(width: 14)
        }
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
}
