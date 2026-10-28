import SwiftUI
import BotChuCore

/// The model and effort, and Codex's Fast switch where `onFast` is given, scoped to this
/// conversation's (or job's) account. None changes its provider.
struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    let settings: any RunSettings
    let disabled: Bool
    let onModel: (String) -> Void
    let onEffort: (ReasoningEffort?) -> Void
    var onFast: ((Bool) -> Void)? = nil
    var inInspector = false
    /// As rows of a form, such as the job editor's.
    var inForm = false
    /// One of the two, as a cell of the Agents table (#250): a plain value whose chevron shows while
    /// its row is hovered, in space kept for it. An effort the model doesn't take is a dash.
    var tableCell: TableCell?
    var rowHovered = false
    /// The effort as its glyph only, in a narrow table.
    var compact = false
    enum TableCell { case model, effort }
    @State private var showsModels = false
    @State private var showsEffort = false

    /// The profile on this Mac whose own list the picker shows (#220), if it lists one.
    private var scope: ModelCatalogScope? { app.modelCatalogScope(for: settings) }
    private var data: ModelPickerData {
        ModelPickerData(kind: settings.account.kind, model: settings.model, openRouterDefault: app.settings.openRouterModel,
                        sailDefault: app.settings.sailModel, catalog: app.modelCatalog.models(for: settings.account.kind),
                        native: app.modelCatalog.models(for: scope), resolved: settings.resolvedModel)
    }
    private var efforts: [ReasoningEffort] {
        GenerationOptions.efforts(for: settings.account.kind, model: data.effectiveID, catalog: app.modelCatalog.models(for: scope))
    }

    /// Whether the Fast switch shows: a Codex model with the Fast tier (#249).
    private var offersFast: Bool {
        onFast != nil && GenerationOptions.offersFast(for: settings.account.kind, model: data.effectiveID,
                                                      catalog: app.modelCatalog.models(for: scope))
    }
    private var fast: Bool { settings.fastMode == true }

    var body: some View {
        Group {
            if let tableCell {
                switch tableCell {
                case .model: modelButton
                case .effort:
                    if efforts.isEmpty {
                        Text("—").foregroundStyle(.tertiary).padding(.leading, 6)
                            .accessibilityLabel("Reasoning effort is not supported by this model")
                    } else {
                        effortButton
                    }
                }
            } else if inInspector {
                InspectorRow("Model") { modelButton }
                InspectorRow("Reasoning", last: !offersFast) { effortButton }
                if offersFast {
                    InspectorRow("Fast", last: true) {
                        Toggle("Fast", isOn: Binding(get: { fast }, set: { onFast?($0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                            .help(fastHelp)
                    }
                }
            } else if inForm {
                LabeledContent("Model") { modelButton }
                LabeledContent("Reasoning") { effortButton }
            } else {
                HStack(spacing: 6) {
                    modelButton
                    effortButton
                    if offersFast { fastButton }
                }
            }
        }
        .disabled(disabled)
        .task(id: settings.account.kind) {
            if settings.account.kind == .pi { await app.modelCatalog.load() }
            if DevHooks.dataDir != nil, DevHooks.env["BOTCHU_OPEN"] != nil, tableCell == nil {
                // Let the review window finish opening/resizing before anchoring its popover.
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                let place = inInspector ? "inspector-" : inForm ? "job-" : ""
                showsModels = DevHooks.env["BOTCHU_OPEN"] == place + "model"
                showsEffort = DevHooks.env["BOTCHU_OPEN"] == place + "effort"
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
            if inForm {
                FormChoiceLabel(title: data.title)
            } else if tableCell != nil {
                HStack(spacing: 4) {
                    Text(data.title).lineLimit(1).truncationMode(.middle)
                    tableChevron(active: showsModels)
                }
            } else if inInspector {
                InspectorChoiceLabel(title: data.title)
            } else {
                HStack(spacing: 7) {
                    ProviderLogo(kind: settings.account.kind, size: 14)
                    Text(data.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    chevron
                }
            }
        }
        .buttonStyle(GenerationButtonStyle(active: showsModels, compact: inInspector, form: inForm, table: tableCell != nil))
        .accessibilityLabel("Model: \(data.title)")
        .help(disabled ? "Model can change when this turn ends" : modelHelp)
        .popover(isPresented: $showsModels, arrowEdge: .top) {
            ModelPicker(data: data, accountName: settings.account.name, catalog: app.modelCatalog,
                        disabled: disabled, select: onModel, scope: scope, sailKey: app.sailKey)
        }

    }

    private var effortButton: some View {
        Button { showsEffort.toggle() } label: {
            if inForm {
                FormChoiceLabel(title: efforts.isEmpty ? "Not supported" : settings.reasoningEffort?.title ?? "Auto")
            } else if tableCell != nil {
                HStack(spacing: 6) {
                    EffortGlyph(effort: settings.reasoningEffort)
                    if !compact { Text(settings.reasoningEffort?.title ?? "Auto").lineLimit(1) }
                    tableChevron(active: showsEffort)
                }
            } else if inInspector {
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
        .buttonStyle(GenerationButtonStyle(active: showsEffort, compact: inInspector, form: inForm, table: tableCell != nil))
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

    /// A lightning bolt, filled and tinted while Fast is on.
    private var fastButton: some View {
        Button { onFast?(!fast) } label: {
            Image(systemName: fast ? "bolt.fill" : "bolt")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(fast ? Palette.violet : Palette.secondaryText)
                .frame(width: 12)
        }
        .buttonStyle(GenerationButtonStyle(active: fast))
        .fixedSize()
        .accessibilityLabel("Fast mode")
        .accessibilityValue(fast ? "On" : "Off")
        .accessibilityAddTraits(fast ? .isSelected : [])
        .help(fastHelp)
    }

    private var fastHelp: String {
        disabled ? "Fast can change when this turn ends"
            : fast ? "Fast is on: quicker replies that use more of the allowance" : "Turn on Fast: quicker replies that use more of the allowance"
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Palette.secondaryText)
    }

    private func tableChevron(active: Bool) -> some View {
        TableChevron(symbol: "chevron.down", shown: rowHovered || active)
    }

    private var modelHelp: String {
        let argument = GenerationOptions.modelArgument(data.effectiveID, kind: settings.account.kind, effort: settings.reasoningEffort)
        return argument == data.effectiveID ? data.detail : "\(data.detail) · runs as \(argument)"
    }
}

/// A value with the up and down chevrons of a form's own pop-up buttons, as the job editor's other rows have.
private struct FormChoiceLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Palette.text.opacity(0.1)))
        }
        .padding(.trailing, 4)
        .contentShape(Rectangle())
    }
}

/// A table cell's chevron (#250): shown while its row is hovered or its control is open, and kept
/// in place while hidden, so the value beside it never moves.
struct TableChevron: View {
    let symbol: String
    let shown: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Palette.secondaryText)
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: shown)
            .accessibilityHidden(true)
    }
}

struct GenerationButtonStyle: ButtonStyle {
    var active = false
    var compact = false
    var form = false
    /// As a value in a table's cell (#250): plain at rest, a light fill while hovered, and the
    /// violet of an open control while its popover shows.
    var table = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        if table {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Palette.violet.opacity(0.12) : Color.primary.opacity(hovered || configuration.isPressed ? 0.07 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Palette.violet.opacity(0.4) : .clear))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        } else if form {
            configuration.label
                .foregroundStyle(Palette.text)
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
        } else {
            pill(configuration)
        }
    }

    private func pill(_ configuration: Configuration) -> some View {
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
