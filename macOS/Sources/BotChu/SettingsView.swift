import AppKit
import SwiftUI
import BotChuCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var openRouterKey = Keychain.get(Keychain.openRouterAccount) ?? ""
    @State private var keySaved = false
    @State private var available: [String: Bool] = [:]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Bots folder") {
                    HStack {
                        TextField("Bots folder", text: $settings.botsRoot)
                            .labelsHidden()
                        Button("Choose…") { chooseRoot() }
                    }
                }
            } footer: {
                Text("New bots get a folder here by default. MEMORY.md here is shared by every bot.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(Accounts.all) { account in
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField("Command", text: Binding(
                                get: { settings.commands[account.id] ?? "" },
                                set: { settings.commands[account.id] = $0 }), prompt: Text(account.defaultCommand))
                                .labelsHidden()
                                .font(.system(.body, design: .monospaced))
                                .onSubmit { Task { await check(account) } }
                            Circle()
                                .fill(color(for: available[account.id]))
                                .frame(width: 8, height: 8)
                                .help(available[account.id] == true ? "Found" : available[account.id] == false ? "Not found by the login shell" : "Checking…")
                        }
                    } label: {
                        Label(account.name, systemImage: account.symbol)
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Each account runs its command through your login shell (zsh -l), headless, in the bot's folder, with permission prompts bypassed. Leave a command empty for the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("API key") {
                    HStack {
                        SecureField("API key", text: $openRouterKey, prompt: Text("sk-or-…"))
                            .labelsHidden()
                            .onSubmit(saveKey)
                        Button(keySaved ? "Saved" : "Save", action: saveKey)
                            .disabled(openRouterKey == (Keychain.get(Keychain.openRouterAccount) ?? ""))
                    }
                }
                TextField("Default model", text: $settings.openRouterModel, prompt: Text(CommandBuilder.defaultOpenRouterModel))
            } header: {
                Text("OpenRouter")
            } footer: {
                HStack(spacing: 4) {
                    Text("Used by the OpenRouter account (the Pi agent). The key is kept in your Keychain.")
                    Link("Get a key", destination: URL(string: "https://openrouter.ai/keys")!)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 740)
        .task {
            await withTaskGroup(of: Void.self) { group in
                for account in Accounts.all { group.addTask { await check(account) } }
            }
        }
    }

    private func check(_ account: Account) async {
        let command = await MainActor.run { model.settings.command(for: account) }
        let found = await CommandCheck.isAvailable(command)
        await MainActor.run { available[account.id] = found }
    }

    private func color(for found: Bool?) -> Color {
        switch found {
        case true?: .green
        case false?: .red
        case nil: .gray.opacity(0.4)
        }
    }

    private func saveKey() {
        Keychain.set(openRouterKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.openRouterAccount)
        keySaved = true
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.botsRoot = url.path
        }
    }
}
