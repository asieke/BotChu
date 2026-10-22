import AppKit
import SwiftUI
import BotChuCore

struct BotEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bot: Bot
    /// The workspace last filled in from the name; once the field differs, the person chose it.
    @State private var autoWorkspace = ""
    @State private var confirmDelete = false
    private let isNew: Bool

    init(request: EditorRequest) {
        _bot = State(initialValue: request.bot)
        isNew = request.isNew
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "New Bot" : "Edit \(bot.name)")
                .font(.headline)
                .padding(.top, 16)
            Form {
                Section {
                    HStack(spacing: 12) {
                        TextField("Emoji", text: $bot.emoji)
                            .labelsHidden()
                            .multilineTextAlignment(.center)
                            .font(.system(size: 22))
                            .frame(width: 52)
                        TextField("Name", text: $bot.name, prompt: Text("Required"))
                    }
                    TextField("Title", text: $bot.title, prompt: Text("What it's for, in one line"))
                }
                Section {
                    TextEditor(text: $bot.instructions)
                        .font(.body)
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Private to the bot. Given at the start of every session, with its MEMORY.md.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Account", selection: $bot.accountID) {
                        ForEach(Accounts.all) { account in
                            Label(account.name, systemImage: account.symbol).tag(account.id)
                        }
                    }
                    TextField("Model", text: $bot.model, prompt: Text(modelPrompt))
                    LabeledContent("Workspace") {
                        HStack {
                            TextField("Workspace", text: $bot.workspace, prompt: Text("~/BotChu/…"))
                                .labelsHidden()
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                } header: {
                    Text("Runs on")
                } footer: {
                    if let problem = workspaceProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("BotChu keeps the bot's history and logs in .botchu/ inside this folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete Bot…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Bot" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bot.name.trimmingCharacters(in: .whitespaces).isEmpty || workspaceProblem != nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .onChange(of: bot.name) {
            guard isNew, bot.workspace == autoWorkspace else { return }
            autoWorkspace = bot.name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : model.defaultWorkspace(for: bot.name)
            bot.workspace = autoWorkspace
        }
        .confirmationDialog("Delete \(bot.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.delete(bot.id)
                dismiss()
            }
        } message: {
            Text("Its conversation is deleted. Its workspace folder is kept.")
        }
    }

    private var workspaceProblem: String? {
        model.workspaceProblem(bot.workspace, for: bot.id)
    }

    private var modelPrompt: String {
        bot.account.kind == .pi ? "\(model.settings.openRouterModel) (OpenRouter id)" : "CLI default"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            bot.workspace = url.path
        }
    }

    private func save() {
        if isNew {
            model.create(bot)
        } else {
            model.update(bot)
        }
        dismiss()
    }
}
