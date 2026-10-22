import SwiftUI
import BotChuCore

/// Two visible controls, scoped to this conversation's account. Neither changes its provider.
struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    let settings: any RunSettings
    let disabled: Bool
    let onModel: (String) -> Void
    let onEffort: (ReasoningEffort?) -> Void
    var inInspector = false
    @State private var showsModels = false
    @State private var showsEffort = false

    private var data: ModelPickerData {
        ModelPickerData(kind: settings.account.kind, model: settings.model,
                        openRouterDefault: app.settings.openRouterModel, catalog: app.modelCatalog.models)
    }
    private var efforts: [ReasoningEffort] {
        GenerationOptions.efforts(for: settings.account.kind, model: data.effectiveID)
    }

    var body: some View {
        Group {
            if inInspector {
                InspectorRow("Model") { modelButton }
                InspectorRow("Reasoning", last: true) { effortButton }
            } else {
                HStack(spacing: 6) {
                    modelButton
                    effortButton
                }
            }
        }
        .disabled(disabled)
        .task(id: settings.account.kind) {
            if settings.account.kind == .pi { await app.modelCatalog.load() }
            if DevHooks.dataDir != nil, DevHooks.env["BOTCHU_OPEN"] != nil {
                // Let the review window finish opening/resizing before anchoring its popover.
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                showsModels = DevHooks.env["BOTCHU_OPEN"] == (inInspector ? "inspector-model" : "model")
                showsEffort = DevHooks.env["BOTCHU_OPEN"] == (inInspector ? "inspector-effort" : "effort")
            }
        }
        .onChange(of: disabled) { _, running in
            if running { showsModels = false; showsEffort = false }
        }
        .onChange(of: settings.account.id) { _, _ in
            showsModels = false
            showsEffort = false
        }
    }

    private var modelButton: some View {
        Button { showsModels.toggle() } label: {
            if inInspector {
                InspectorChoiceLabel(title: data.title)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: settings.account.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.violet)
                    Text(data.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    chevron
                }
            }
        }
        .buttonStyle(GenerationButtonStyle(active: showsModels, compact: inInspector))
        .accessibilityLabel("Model: \(data.title)")
        .help(disabled ? "Model can change when this turn ends" : modelHelp)
        .popover(isPresented: $showsModels, arrowEdge: .top) {
            ModelPicker(data: data, accountName: settings.account.name, catalog: app.modelCatalog,
                        disabled: disabled, select: onModel)
        }

    }

    private var effortButton: some View {
        Button { showsEffort.toggle() } label: {
            if inInspector {
                InspectorChoiceLabel(title: efforts.isEmpty ? "Not supported" : settings.reasoningEffort?.title ?? "Auto")
            } else {
                HStack(spacing: 6) {
                    EffortGlyph(effort: settings.reasoningEffort)
                    Text(efforts.isEmpty ? "No effort" : settings.reasoningEffort?.title ?? "Auto")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    chevron
                }
            }
        }
        .buttonStyle(GenerationButtonStyle(active: showsEffort, compact: inInspector))
        .fixedSize()
        .disabled(efforts.isEmpty)
        .accessibilityLabel(efforts.isEmpty ? "Reasoning effort is not supported by this model"
                            : "Reasoning effort: \(settings.reasoningEffort?.title ?? "Automatic")")
        .help(disabled ? "Effort can change when this turn ends" : efforts.isEmpty
              ? "This model does not offer adjustable reasoning effort" : "Choose how much reasoning to use")
        .popover(isPresented: $showsEffort, arrowEdge: .top) {
            EffortPicker(efforts: efforts, selected: settings.reasoningEffort, disabled: disabled, select: onEffort)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Palette.secondaryText)
    }

    private var modelHelp: String {
        let source = settings.model.isEmpty ? (settings.account.kind == .pi ? "Default from Settings" : "Account default") : "Selected model"
        let argument = GenerationOptions.modelArgument(data.effectiveID, kind: settings.account.kind, effort: settings.reasoningEffort)
        return "\(source) · \(argument.isEmpty ? settings.account.name : argument)"
    }
}

private struct GenerationButtonStyle: ButtonStyle {
    var active = false
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.text)
            .padding(.horizontal, compact ? 0 : 10)
            .frame(height: compact ? 28 : 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(compact ? .clear : active ? Palette.violet.opacity(0.12) : Palette.text.opacity(hovered || configuration.isPressed ? 0.09 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(compact ? .clear : active ? Palette.violet.opacity(0.4) : Palette.text.opacity(0.055)))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
    }
}

struct PickerRowStyle: ButtonStyle {
    let selected: Bool
    var highlighted = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.text)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Palette.violet.opacity(0.1)
                : Color.primary.opacity(highlighted || hovered || configuration.isPressed ? 0.055 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(highlighted ? Palette.violet.opacity(0.35) : .clear))
            .onHover { hovered = $0 }
    }
}
