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
    /// A Codex pet chosen for a bot that isn't created yet; copied in on Create.
    @State private var pendingPet: URL?
    @State private var petError: String?
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
                    HStack(alignment: .top, spacing: 12) {
                        petPreview
                        TextEditor(text: Binding(get: { bot.appearance ?? "" },
                                                 set: { bot.appearance = $0.isEmpty ? nil : $0 }))
                            .font(.body)
                            .frame(minHeight: 64)
                            .scrollContentBackground(.hidden)
                            .overlay(alignment: .topLeading) {
                                if (bot.appearance ?? "").isEmpty {
                                    Text("Describe how this bot looks: a small brass robot with a lantern head…")
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    HStack {
                        Button("Import Codex Pet…", action: choosePet)
                            .help("Use a pet made in Codex: a folder with pet.json and its spritesheet, such as ~/.codex/pets/<name>")
                        Spacer()
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    if let petError {
                        Text(petError).font(.caption).foregroundStyle(.red)
                    } else if let pendingPet {
                        Text("\(pendingPet.lastPathComponent) is added when you create the bot.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("The bot's pet stands in for its emoji, and shows what it is doing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("Account", selection: Binding(get: { bot.accountID }, set: { bot.selectAccount($0) })) {
                        ForEach(Accounts.all) { account in
                            Label(account.name, systemImage: account.symbol).tag(account.id)
                        }
                    }
                    TextField("Model", text: Binding(get: { bot.model }, set: { bot.selectModel($0) }), prompt: Text(modelPrompt))
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
        .frame(width: 520, height: 680)
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

    @ViewBuilder private var petPreview: some View {
        if let sheet = model.petSheets[bot.id], !isNew {
            PetSpriteView(sheet: sheet, activity: .idle)
                .frame(width: 60, height: 65)
        } else {
            BotAvatar(bot: bot, size: 44)
                .frame(width: 60, height: 65)
        }
    }

    private func choosePet() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Pet"
        panel.message = "Choose a Codex pet folder, with pet.json and its spritesheet."
        let pets = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/pets")
        if FileManager.default.fileExists(atPath: pets) { panel.directoryURL = URL(fileURLWithPath: pets, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        petError = nil
        guard PetPackage.load(from: url) != nil else {
            petError = "\(url.lastPathComponent) isn't a Codex pet: it needs pet.json and the spritesheet it names."
            return
        }
        if isNew {
            pendingPet = url
        } else {
            do {
                try model.importPet(from: url, for: bot.id)
            } catch {
                petError = error.localizedDescription
            }
        }
    }

    private func save() {
        if isNew {
            model.create(bot)
            if let pendingPet { try? model.importPet(from: pendingPet, for: bot.id) }
        } else {
            model.update(bot)
        }
        dismiss()
    }
}
