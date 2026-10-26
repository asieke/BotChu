import SwiftUI
import BotChuCore

struct SkillsView: View {
    enum Filter: String, CaseIterable { case all = "All", shared = "Shared", own = "Bot Skills" }

    @Environment(AppModel.self) private var model
    @State private var entries: [SkillEntry] = []
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var creating = false
    /// A skill just made, opened in the editor once New Skill has closed.
    @State private var created: SkillEntry?
    @State private var pendingDelete: SkillEntry?
    @State private var error: String?

    private var matches: [SkillEntry] {
        entries.filter { entry in
            (filter == .all || (filter == .shared) == (entry.bot == nil))
                && (query.isEmpty || [entry.skill.name, entry.skill.description, entry.bot?.name ?? ""].joined(separator: " ")
                    .localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryHeading(title: "Skills", subtitle: "Reusable workflows and tool runbooks your bots read when their work calls for them.",
                           count: entries.count) {
                Button { model.revealSkill(nil) } label: { Label("Shared Folder", systemImage: "folder") }
                    .help("Open the skills every bot shares, in the bots folder")
                Button { creating = true } label: { Label("New Skill", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            HStack {
                LibrarySearch(text: $query, prompt: "Search skills")
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }.padding(.horizontal, 24).padding(.bottom, 16)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12)
            }
            if matches.isEmpty {
                LibraryEmpty(title: entries.isEmpty ? "No skills yet" : "No matching skills",
                             subtitle: entries.isEmpty
                                 ? "Make one with New Skill, or add a folder with a SKILL.md to the shared folder. Bots see each skill's name and description, and read the rest when it fits their work."
                                 : "Try a skill's name, description or bot.",
                             symbol: "wand.and.stars")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16)], spacing: 16) {
                        ForEach(matches) { entry in
                            SkillCard(entry: entry, onDelete: { pendingDelete = entry })
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity).navigationTitle("Skills")
        // Read again when the editor opens or closes, and when bots change, so saved edits show.
        .task(id: model.documentEditor?.id) { reload() }
        .onChange(of: model.bots) { reload() }
        .sheet(isPresented: $creating, onDismiss: {
            reload()
            if let created { model.editSkill(created) }
            created = nil
        }) {
            NewSkillSheet { created = $0 }.environment(model)
        }
        .confirmationDialog("Delete \(pendingDelete?.skill.name ?? "skill")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { entry in
            Button("Move to Trash", role: .destructive) {
                do { try model.deleteSkill(entry); error = nil } catch { self.error = "Couldn't delete \(entry.skill.name): \(error.localizedDescription)" }
                reload()
            }
        } message: { entry in
            Text(entry.bot == nil ? "Its folder goes to the Trash, and no bot is told about it any more." : "Its folder goes to the Trash, and \(entry.bot?.name ?? "its bot") is no longer told about it.")
        }
    }

    private func reload() { entries = model.skillEntries() }
}

private struct SkillCard: View {
    @Environment(AppModel.self) private var model
    let entry: SkillEntry
    let onDelete: () -> Void

    private var skill: Skill { entry.skill }
    /// The bots that keep a shared skill on.
    private var users: [Bot] { model.bots.filter { !$0.isRemoteQueue && $0.usesSharedSkill(skill.slug) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                if let bot = entry.bot {
                    BotAvatar(bot: bot, size: 44)
                } else {
                    LibraryIcon(symbol: "wand.and.stars", color: .purple)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(.system(.headline, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(scope).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(skill.description.isEmpty ? "No description. Add one to its frontmatter so bots know when to use it." : skill.description)
                .font(.callout).foregroundStyle(skill.description.isEmpty ? .tertiary : .secondary)
                .lineLimit(3).frame(height: 54, alignment: .topLeading)
            Divider()
            HStack {
                Text(skill.resourceCount == 0 ? "SKILL.md" : "SKILL.md + \(skill.resourceCount) \(skill.resourceCount == 1 ? "file" : "files")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if entry.bot == nil { botsMenu }
                Button("Edit…") { model.editSkill(entry) }
            }
        }
        .padding(20).libraryCard()
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(count: 2) { model.editSkill(entry) }
        .contextMenu {
            Button("Edit SKILL.md…") { model.editSkill(entry) }
            if entry.bot == nil { botsMenu }
            Button("Show in Finder") { model.revealSkill(entry) }
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityIdentifier("skill-\(skill.id)")
    }

    private var scope: String {
        if let bot = entry.bot { return "\(bot.name)'s own" }
        if users.count == model.bots.filter({ !$0.isRemoteQueue }).count { return "Shared · every bot" }
        return "Shared · \(users.count) of \(model.bots.filter { !$0.isRemoteQueue }.count) bots"
    }

    /// Which bots keep a shared skill on.
    private var botsMenu: some View {
        Menu("Bots") {
            ForEach(model.bots.filter { !$0.isRemoteQueue }) { bot in
                Toggle(isOn: Binding(get: { bot.usesSharedSkill(skill.slug) },
                                     set: { model.setSharedSkill(skill.slug, enabled: $0, for: bot.id) })) {
                    Text("\(bot.emoji) \(bot.name)")
                }
            }
        }
        .fixedSize()
        .help("Choose which bots are told about this skill")
    }
}

/// Names a new skill and where it goes, then opens it in the editor.
struct NewSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreate: (SkillEntry) -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var botID: UUID?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Skill").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("Aside web browsing"))
                TextField("When to use it", text: $description, prompt: Text("Browse live sites with the aside CLI…"), axis: .vertical)
                    .lineLimit(2...4)
                Picker("For", selection: $botID) {
                    Text("Every bot (shared)").tag(UUID?.none)
                    ForEach(model.bots.filter { !$0.isRemoteQueue }) { bot in Text("\(bot.emoji) \(bot.name) only").tag(Optional(bot.id)) }
                }
            }
            .formStyle(.grouped)
            Text("Saved as skills/\(Skills.slug(name))/SKILL.md \(botID == nil ? "in the bots folder" : "in the bot's workspace"). Bots see its name and description at the start of each session, and read the rest when it fits their work.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func create() {
        do {
            onCreate(try model.createSkill(name: name, description: description, for: botID.flatMap(model.bot)))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
