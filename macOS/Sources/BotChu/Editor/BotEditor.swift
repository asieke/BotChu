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
    /// How many scheduled jobs saving an agent as a specialist pauses, asked about before it saves (#250).
    @State private var pausingJobs: Int?
    /// New Bot's Generate animated pet, off until the owner turns it on (#232).
    @State private var makesPet = false
    /// An existing bot's INSTRUCTIONS.md, edited here and saved with the bot. A new bot's
    /// instructions go in `bot.instructions` until it has a folder, which they then move into.
    @State private var instructions: BotDocumentDraft?
    @State private var instructionsError: String?
    private let isNew: Bool
    /// The bot as the sheet opened, so leaving for Settings never drops edits made since.
    private let original: Bot

    init(request: EditorRequest) {
        _bot = State(initialValue: request.bot)
        original = request.bot
        isNew = request.isNew
        if !request.isNew && !request.bot.isRemoteQueue {
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
                    if isNew {
                        Picker("Kind", selection: Binding(get: { bot.kind ?? .localCLI }, set: { bot.kind = $0 })) {
                            Text("Local CLI").tag(Bot.Kind.localCLI)
                            Text("Remote queue").tag(Bot.Kind.remoteQueue)
                        }
                    }
                    // An agent owns tasks and jobs; a specialist is only called as a sub-agent (#250).
                    if !bot.isRemoteQueue {
                        Picker("Role", selection: $bot.role) {
                            Text("Agent").tag(Bot.Role.agent)
                            Text("Specialist").tag(Bot.Role.specialist)
                        }
                        .pickerStyle(.segmented)
                    }
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
                if !bot.isRemoteQueue {
                Section {
                    TextEditor(text: instructionsText)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                        .disabled(!isNew && instructions == nil)
                        .accessibilityLabel("Edit \(BotDocument.instructions.rawValue)")
                } header: {
                    HStack {
                        Text("Instructions")
                        Spacer()
                        Text(BotDocument.instructions.rawValue)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let instructionsError {
                        Text(instructionsError).font(.caption).foregroundStyle(.red)
                    }
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
                                    Text("Describe your pet character (e.g. a small brass robot with a lantern head)…")
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityLabel("Pet description")
                    }
                    if isNew {
                        // Off until turned on: a pet costs OpenRouter credit, at the estimate for the
                        // model chosen in Settings ▸ Pets.
                        Toggle("Generate animated pet on create (\(petCost))", isOn: $makesPet)
                            .disabled(!hasAppearance)
                            .help(petExplanation)
                    } else {
                        HStack {
                            Button(model.pets[bot.id] == nil ? "Make Pet…" : "Remake Pet…") { confirmPet = true }
                                .disabled(!hasAppearance || model.petJobs[bot.id]?.isActive == true)
                                .help("Codex draws a still per state, then OpenRouter turns each into a short looping clip")
                            Spacer()
                        }
                        PetJobStatus(botID: bot.id)
                    }
                } header: {
                    Text("Animated Pet")
                }
                if !bot.isRemoteQueue {
                Section {
                    Picker("Account", selection: Binding(get: { bot.accountID }, set: { bot.selectAccount(model.settings.account($0)) })) {
                        ForEach(model.settings.accounts) { account in
                            ProviderMenuLabel(account).tag(account.id)
                        }
                    }
                    LabeledContent("Runtime", value: bot.account.kind.displayName)
                    ModelMenu(settings: bot, disabled: false,
                              onModel: { bot.selectModel($0, catalog: model.nativeModels(for: bot)) },
                              onEffort: { bot.reasoningEffort = $0 },
                              onProvider: model.isRunning(.home(bot.id)) ? nil : { bot.selectProvider($0) }, inForm: true)
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
                    }
                }
                } else {
                    Section {
                        // Where its connection is set, as a status and the way there (#232).
                        LabeledContent("Connection") {
                            HStack {
                                Text(model.settings.remoteQueueEnabled ? "Configured" : "Not configured")
                                    .foregroundStyle(.secondary)
                                // Settings is behind the sheet, which closes to show it: only with nothing to lose.
                                Button("Open Remote Queue Settings…") {
                                    dismiss()
                                    model.openSettings(.remoteQueue)
                                }
                                .disabled(isNew || bot != original)
                                .help(isNew ? "Create the bot first" : bot != original ? "Save or cancel your changes first" : "")
                            }
                        }
                        if let problem = workspaceProblem { Text(problem).foregroundStyle(.red) }
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
            guard isNew, !bot.isRemoteQueue, bot.workspace == autoWorkspace else { return }
            autoWorkspace = bot.name.trimmingCharacters(in: .whitespaces).isEmpty ? "" : model.defaultWorkspace(for: bot.name)
            bot.workspace = autoWorkspace
        }
        .alert("Make \(bot.name) a Specialist?", isPresented: Binding(get: { pausingJobs != nil }, set: { if !$0 { pausingJobs = nil } }),
               presenting: pausingJobs) { _ in
            Button("Make Specialist") { finish(makingPet: false) }
            Button("Cancel", role: .cancel) {}
        } message: { count in
            Text("Its \(count == 1 ? "scheduled job pauses" : "\(count) scheduled jobs pause") until it's an Agent again.")
        }
        .confirmationDialog("Make a pet for \(bot.name)?", isPresented: $confirmPet) {
            Button("Make Pet (\(petCost))") {
                model.setAppearance(bot.appearance ?? "", for: bot.id)
                model.makePet(bot.id)
            }
        } message: {
            Text(petExplanation)
        }
        .confirmationDialog("Delete \(bot.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.delete(bot.id)
                dismiss()
            }
        } message: {
            Text(bot.isRemoteQueue ? "Its conversation and waiting remote messages are deleted. Its connection stops." : "Its conversation is deleted. Its workspace folder is kept.")
        }
    }

    private var instructionsText: Binding<String> {
        isNew ? $bot.instructions : Binding(get: { instructions?.text ?? "" }, set: { instructions?.text = $0 })
    }

    private var workspaceProblem: String? {
        if bot.isRemoteQueue {
            return model.bots.contains { $0.isRemoteQueue && $0.id != bot.id } ? "Only one remote queue bot is supported." : nil
        }
        return model.workspaceProblem(bot.workspace, for: bot.id)
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

    private var hasAppearance: Bool { !(bot.appearance ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func save() {
        // An agent made a specialist pauses its jobs: asked first, when it has any on.
        if !isNew, bot.isSpecialist, original.canOwnTasks {
            let jobs = model.jobsPausedBySpecialistSwitch(of: bot.id).count
            if jobs > 0 {
                pausingJobs = jobs
                return
            }
        }
        finish(makingPet: isNew && PetVideo.makesPetOnCreate(optedIn: makesPet, appearance: bot.appearance))
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

    private var petCost: String { PetVideo.costLabel(model.petModel) }

    private var petExplanation: String {
        String(format: "%@ draws %d stills of it from its appearance, on your ChatGPT allowance (keeping its pet's look when the appearance hasn't changed). Then OpenRouter turns them into %d short looping clips on %@, for %@ of your OpenRouter credit. It takes about 10 minutes, in the background.",
               model.petAccount(for: bot).name, PetVideo.stills.count, PetVideo.clips.count, model.petModel.name, petCost)
    }
}
