import SwiftUI
import BotChuCore

/// Generation controls for the conversation's existing account. A bot's account changes in Edit
/// Bot, a task's in its status sidebar.
struct ModelMenu: View {
    /// The bot, or the task, whose model this is.
    let settings: any RunSettings
    let disabled: Bool
    let onModel: (String) -> Void
    let onEffort: (ReasoningEffort?) -> Void
    @State private var showsCustomModel = false
    @State private var customModel = ""

    private var kind: AgentKind { settings.account.kind }
    private var options: [ModelOption] { GenerationOptions.models(for: kind) }
    private var efforts: [ReasoningEffort] { GenerationOptions.efforts(for: kind, model: settings.model) }

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(get: { settings.model }, set: onModel)) {
                Text("Default model").tag("")
                ForEach(options) { option in
                    Text(option.name).tag(option.id)
                }
                if !settings.model.isEmpty, !options.contains(where: { $0.id == settings.model }) {
                    Text(settings.model).tag(settings.model)
                }
            }
            .pickerStyle(.inline)
            Button("Custom model…") {
                customModel = settings.model
                showsCustomModel = true
            }
            Divider()
            Picker("Reasoning effort", selection: Binding(get: { settings.reasoningEffort }, set: onEffort)) {
                Text("Default effort").tag(Optional<ReasoningEffort>.none)
                ForEach(efforts, id: \.self) { effort in
                    Text(effort.title).tag(Optional(effort))
                }
            }
            .pickerStyle(.inline)
            .disabled(efforts.isEmpty)
        } label: {
            HStack(spacing: 5) {
                Text(GenerationOptions.name(for: settings.model, kind: kind))
                    .lineLimit(1).truncationMode(.middle)
                if let effort = settings.reasoningEffort {
                    Text(effort.title).foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.callout)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(disabled)
        .help(disabled ? "Model and reasoning can change when this turn ends" : "Model and reasoning effort for the next message")
        .popover(isPresented: $showsCustomModel) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model on \(kind.displayName)").font(.headline)
                TextField("Model ID", text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveCustomModel)
                HStack {
                    Button("Cancel") { showsCustomModel = false }
                    Spacer()
                    Button("Use Model", action: saveCustomModel)
                        .keyboardShortcut(.defaultAction)
                        .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || disabled)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    private func saveCustomModel() {
        let value = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !disabled, !value.isEmpty else { return }
        onModel(value)
        showsCustomModel = false
    }
}
