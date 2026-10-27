import SwiftUI
import BotChuCore

/// Settings ▸ General ▸ Quick tasks (#192): the profile and model that name each new task in three
/// or four words. Off until the owner picks a profile; picking one starts on its family's smallest
/// model.
struct QuickTaskSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let account = settings.quickTaskAccountID.map { settings.account($0) }
        Section("Quick tasks") {
            Picker("Profile", selection: profile) {
                Text("Off").tag(String?.none)
                Divider()
                ForEach(QuickTasks.accounts(settings.accounts)) { account in
                    ProviderMenuLabel(account).tag(Optional(account.id))
                }
            }
            .accessibilityIdentifier("settings-quick-tasks-profile")
            if let account {
                Picker("Model", selection: $settings.quickTaskModel) {
                    ForEach(models(for: account), id: \.id) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .accessibilityIdentifier("settings-quick-tasks-model")
                // The profile's own list, as a conversation's picker shows it (#220), checked when it is due.
                .task(id: model.modelCatalogScope(for: account)) {
                    if let scope = model.modelCatalogScope(for: account) { await model.modelCatalog.refresh(scope) }
                }
            }
        }
        .help("Names each new task in three or four words, once, in a fresh session with no tools, on this profile's allowance.")
    }

    /// The profile; choosing one whose family doesn't have the model chosen starts on its smallest.
    private var profile: Binding<String?> {
        Binding(get: { model.settings.quickTaskAccountID }, set: { id in
            let settings = model.settings
            settings.quickTaskAccountID = id
            guard let id else { return }
            let account = settings.account(id)
            if !models(for: account).contains(where: { $0.id == settings.quickTaskModel }) {
                settings.quickTaskModel = QuickTasks.suggestedModel(for: account.kind)
            }
        })
    }

    /// The profile's models (its own list once read, else its family's starters), with the one
    /// chosen when it isn't among them.
    private func models(for account: Account) -> [ModelOption] {
        QuickTasks.models(for: account.kind, catalog: model.modelCatalog.models(for: model.modelCatalogScope(for: account)),
                          chosen: model.settings.quickTaskModel)
    }
}
