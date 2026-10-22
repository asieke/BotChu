import SwiftUI
import BotChuCore

/// Generation controls for the bot's existing account. Account selection lives in Edit Bot.
struct ModelMenu: View {
    let bot: Bot
    let disabled: Bool
    let onModel: (String) -> Void
    let onEffort: (ReasoningEffort?) -> Void
    @State private var showsCustomModel = false
    @State private var customModel = ""

    private var options: [ModelOption] { GenerationOptions.models(for: bot.account.kind) }
    private var efforts: [ReasoningEffort] { GenerationOptions.efforts(for: bot.account.kind, model: bot.model) }

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(get: { bot.model }, set: onModel)) {
                Text("Default model").tag("")
                ForEach(options) { option in
                    Text(option.name).tag(option.id)
                }
                if !bot.model.isEmpty, !options.contains(where: { $0.id == bot.model }) {
                    Text(bot.model).tag(bot.model)
                }
            }
            .pickerStyle(.inline)
            Button("Custom model…") {
                customModel = bot.model
                showsCustomModel = true
            }
            Divider()
            Picker("Reasoning effort", selection: Binding(get: { bot.reasoningEffort }, set: onEffort)) {
                Text("Default effort").tag(Optional<ReasoningEffort>.none)
                ForEach(efforts, id: \.self) { effort in
                    Text(effort.title).tag(Optional(effort))
                }
            }
            .pickerStyle(.inline)
            .disabled(efforts.isEmpty)
        } label: {
            HStack(spacing: 5) {
                Text(GenerationOptions.name(for: bot.model, kind: bot.account.kind))
                    .lineLimit(1).truncationMode(.middle)
                if let effort = bot.reasoningEffort {
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
                Text("Model on \(bot.account.kind.displayName)").font(.headline)
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
