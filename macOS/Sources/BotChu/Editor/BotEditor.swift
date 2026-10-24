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
    @State private var confirmPet = false
    /// Asked on Create, when the new bot has an appearance.
    @State private var confirmCreatePet = false
    /// An existing bot's INSTRUCTIONS.md, edited here and saved with the bot. A new bot's
    /// instructions go in `bot.instructions` until it has a folder, which they then move into.
    @State private var instructions: BotDocumentDraft?
    @State private var instructionsError: String?
    private let isNew: Bool

    init(request: EditorRequest) {
        _bot = State(initialValue: request.bot)
        isNew = request.isNew
        if !request.isNew {
            do {
                _instructions = State(initialValue: try BotDocumentDraft(bot: request.bot, document: .instructions))
            } catch {
                _instructionsError = State(initialValue: "Couldn't read \(BotDocument.instructions.rawValue): \(error.localizedDescription)")
            }
        }
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
                    TextEditor(text: instructionsText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                        .disabled(!isNew && instructions == nil)
                        .accessibilityLabel("Edit \(BotDocument.instructions.rawValue)")
                } header: {
                    Text("Instructions")
                } footer: {
                    if let instructionsError {
                        Text(instructionsError).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("The bot's role and job, in Markdown, kept in \(BotDocument.instructions.rawValue) in its folder. Given at the start of every session, with its SOUL.md, MEMORY.md and the shared TEAM.md.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
                    if !isNew {
                        HStack {
                            Button(model.pets[bot.id] == nil ? "Make Pet…" : "Remake Pet…") { confirmPet = true }
                                .disabled((bot.appearance ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          || model.petJobs[bot.id]?.isActive == true)
                                .help("Codex draws a still per state, then OpenRouter turns each into a short looping clip")
                            Spacer()
                        }
                        PetJobStatus(botID: bot.id)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text(isNew
                         ? "With an appearance, you can make the bot's pet when you create it: an animated character that stands in for the emoji and acts out what the bot is doing."
                         : "The pet stands in for the emoji and acts out what the bot is doing. A remake with the same appearance keeps its look.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Account", selection: Binding(get: { bot.accountID }, set: { bot.selectAccount(model.settings.account($0)) })) {
                        ForEach(model.settings.accounts) { account in
                            ProviderMenuLabel(account).tag(account.id)
                        }
                    }
                    LabeledContent("Model") {
                        VStack(alignment: .trailing, spacing: 3) {
                            TextField("Model", text: Binding(get: { bot.model }, set: { bot.selectModel($0) }), prompt: Text(modelPrompt))
                                .labelsHidden()
                            // What the ID stands for, with a version only when it is pinned or reported.
                            Text(modelLabel.title).font(.caption.weight(.medium))
                            Text(modelLabel.detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(modelLabel.detail)
                        }
                    }
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
        .confirmationDialog("Make a pet for \(bot.name)?", isPresented: $confirmPet) {
            Button("Make Pet (\(petCost))") {
                model.setAppearance(bot.appearance ?? "", for: bot.id)
                model.makePet(bot.id)
            }
        } message: {
            Text(petExplanation)
        }
        .confirmationDialog("Make a pet for \(bot.name) too?", isPresented: $confirmCreatePet) {
            Button("Create and Make Pet (\(petCost))") { finish(makingPet: true) }
            Button("Create Without a Pet") { finish(makingPet: false) }
        } message: {
            Text(petExplanation)
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

    private var instructionsText: Binding<String> {
        isNew ? $bot.instructions : Binding(get: { instructions?.text ?? "" }, set: { instructions?.text = $0 })
    }

    private var workspaceProblem: String? {
        model.workspaceProblem(bot.workspace, for: bot.id)
    }

    private var modelLabel: ModelPickerData {
        ModelPickerData(kind: bot.account.kind, model: bot.model, openRouterDefault: model.settings.openRouterModel,
                        catalog: model.modelCatalog.models, resolved: bot.resolvedModel)
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
        if let video = model.pets[bot.id], !isNew {
            PetVideoView(package: video, activity: .idle)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .frame(width: 60, height: 65)
        } else {
            BotAvatar(bot: bot, size: 44)
                .frame(width: 60, height: 65)
        }
    }

    private func save() {
        if isNew, !(bot.appearance ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmCreatePet = true
            return
        }
        finish(makingPet: false)
    }

    private func finish(makingPet: Bool) {
        if isNew {
            model.create(bot)
            if makingPet { model.makePet(bot.id) }
        } else {
            // Saved in the folder it is in now, before the bot moves, so it moves with the bot.
            if var draft = instructions, draft.hasChanges {
                do {
                    try draft.save()
                    instructions = draft
                    bot.instructions = ""
                } catch {
                    instructionsError = "Couldn't save \(BotDocument.instructions.rawValue): \(error.localizedDescription) To reload it here, Cancel and edit the bot again."
                    return
                }
            }
            model.update(bot)
        }
        dismiss()
    }

    private var petCost: String { String(format: "about $%.2f", PetVideo.estimatedCost(model.petModel)) }

    private var petExplanation: String {
        String(format: "%@ draws %d stills of it from its appearance, on your ChatGPT allowance (keeping its pet's look when the appearance hasn't changed). Then OpenRouter turns them into %d short looping clips on %@, for %@ of your OpenRouter credit. It takes about 10 minutes, in the background.",
               model.petAccount(for: bot).name, PetVideo.stills.count, PetVideo.clips.count, model.petModel.name, petCost)
    }
}
