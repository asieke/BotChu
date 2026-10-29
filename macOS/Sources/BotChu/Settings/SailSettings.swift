import SwiftUI
import BotChuCore

/// Settings ▸ Sail: the Sail Research key, kept in the Keychain apart from OpenRouter's, and the
/// model the Sail account runs when a conversation doesn't choose one. Sail lists the models the
/// key can use; conversations choose their own completion window.
struct SailSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var key: SettingsKeyDraft
    @State private var saved = false
    @State private var models: [CatalogModel] = []
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            LabeledContent("API key") {
                HStack {
                    SecureField("API key", text: Binding(get: { key.text ?? "" }, set: { key.text = $0; saved = false }), prompt: Text("Sail API key"))
                        .labelsHidden()
                        .settingsField()
                        .onSubmit(save)
                        .help("Kept in your Keychain")
                    Button(saved ? "Saved" : "Save", action: save)
                        .disabled(!key.isUnsaved)
                        .buttonStyle(.borderedProminentIf(key.isUnsaved))
                }
            }
            LabeledContent("Default model") {
                HStack {
                    TextField("Default model", text: $settings.sailModel, prompt: Text("Model ID"))
                        .labelsHidden()
                        .settingsField()
                    if models.isEmpty {
                        Button(loading ? "Loading…" : "Load Models", action: loadModels)
                            .disabled(loading || key.saved.isEmpty)
                    } else {
                        Menu("Choose") {
                            ForEach(models) { entry in
                                Button(entry.id) { settings.sailModel = entry.id }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            .help("Used by the Sail account. Choose ASAP, Balanced, or Flex in each conversation.")
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { key.seed(saved: model.sailKey()) }
    }

    private func save() {
        guard key.isUnsaved else { return }
        Keychain.set(key.save(), for: Keychain.sailAccount)
        models = []
        problem = nil
        saved = true
        // A new key is a new account's balance: nothing read with the old one is shown as it.
        model.settings.sailUsageCredentialRevision += 1
    }

    /// Asks Sail which models the saved key can use.
    private func loadModels() {
        let savedKey = key.saved
        guard !savedKey.isEmpty, !loading else { return }
        loading = true
        problem = nil
        Task {
            do {
                models = try await SailClient(key: savedKey).models()
            } catch {
                problem = (error as? SailFailure)?.message ?? "Sail didn’t list its models: \(error.localizedDescription)"
            }
            loading = false
        }
    }
}
