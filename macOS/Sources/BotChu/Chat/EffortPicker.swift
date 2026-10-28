import SwiftUI
import BotChuCore

struct EffortPicker: View {
    @Environment(\.dismiss) private var dismiss
    let efforts: [ReasoningEffort]
    let selected: ReasoningEffort?
    let disabled: Bool
    let select: (ReasoningEffort?) -> Void
    @FocusState private var focused: String?

    private var keys: [String] { ["auto"] + efforts.map(\.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reasoning effort").font(.system(size: 15, weight: .semibold))
                .padding(16)
            VStack(spacing: 2) {
                row(nil)
                ForEach(efforts, id: \.self) { row($0) }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .frame(width: 310)
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
        .foregroundStyle(Palette.text)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = selected?.rawValue ?? "auto" }
        .onExitCommand { dismiss() }
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { key in
            if key.key == .return {
                choose(focused.flatMap(ReasoningEffort.init(rawValue:)))
            } else {
                let index = keys.firstIndex(of: focused ?? "auto") ?? 0
                focused = keys[min(keys.count - 1, max(0, index + (key.key == .downArrow ? 1 : -1)))]
            }
            return .handled
        }
    }

    private func row(_ effort: ReasoningEffort?) -> some View {
        Button {
            choose(effort)
        } label: {
            HStack(spacing: 12) {
                EffortGlyph(effort: effort).frame(width: 24)
                // The level's name and its bars say it (#232); Auto names what it falls back to.
                Text(effort?.title ?? "Auto (Account default)").font(.system(size: 13, weight: .medium))
                Spacer()
                if effort == selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.violet)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(PickerRowStyle(selected: effort == selected, highlighted: focused == (effort?.rawValue ?? "auto")))
        .focusable()
        .focusEffectDisabled()
        .focused($focused, equals: effort?.rawValue ?? "auto")
        .accessibilityAddTraits(effort == selected ? .isSelected : [])
    }

    private func choose(_ effort: ReasoningEffort?) {
        guard !disabled else { return }
        select(effort)
        dismiss()
    }
}

struct EffortGlyph: View {
    let effort: ReasoningEffort?

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(effort == nil ? Color.secondary.opacity(0.55) : index < level ? Palette.violet : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private var level: Int {
        switch effort {
        case nil, .off, .some(.none): 0
        case .minimal, .low: 1
        case .medium: 2
        case .high: 3
        case .xhigh, .max, .ultra: 4
        }
    }
}
