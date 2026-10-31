import AppKit
import SwiftUI
import BotChuCore

/// Attach Project Area (#402), from `+` in the Project Areas column: a repository from Projects'
/// list, each with the face of the bot whose area it is, or a folder, a new one by its name in the
/// bot's `areas/` or one chosen in Finder. Attaching opens the area, moving it from another bot
/// when it was theirs.
struct AttachAreaSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let botID: UUID
    @State private var query = ""
    @State private var selected: String?
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let botName = model.bot(botID)?.name ?? "the bot"
        let owners = model.areaOwners()
        let repos = filtered(model.projectCatalog)
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach Project Area")
                .font(.system(size: 15, weight: .semibold))
            TextField("Search repositories", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("area-search")
            SheetHeading("Repositories")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(repos) { entry in
                        repoRow(entry, owner: owners[entry.repo.lowercased()])
                    }
                }
            }
            .frame(height: 224)
            .accessibilityIdentifier("area-repositories")
            SheetHeading("Folder")
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(attach)
                    .accessibilityLabel("New folder area of \(botName)")
                    .accessibilityIdentifier("area-name")
                Button("Choose Folder…", action: chooseFolder)
                    .accessibilityIdentifier("area-choose-folder")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Attach", action: attach)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAttach)
                    .accessibilityIdentifier("area-attach")
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: name) { _, typed in
            if !typed.trimmingCharacters(in: .whitespaces).isEmpty { selected = nil }
        }
        .onAppear { FrameTimings.mark(FrameMarks.attachArea) }
    }

    private func filtered(_ catalog: [ProjectCatalogEntry]) -> [ProjectCatalogEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return catalog.filter { entry in
            let text = (entry.name + " " + entry.repo).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// A repository: its name, and the face of the bot whose area it is. One on another computer,
    /// or whose area can't move now, can't be chosen; its tooltip says why.
    private func repoRow(_ entry: ProjectCatalogEntry, owner: UUID?) -> some View {
        let problem = problem(for: entry, owner: owner)
        let chosen = selected == entry.repo
        return Button {
            selected = entry.repo
            name = ""
            nameFocused = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "diamond")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 16)
                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let bot = owner.flatMap(model.bot) {
                    BotAvatar(bot: bot, size: 18, animates: false)
                        .help(bot.name)
                        .accessibilityLabel(bot.name)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .foregroundStyle(chosen ? Color.white : Palette.text)
            .background {
                if chosen { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(problem != nil)
        .opacity(problem == nil ? 1 : 0.45)
        .help(problem ?? entry.repo)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if problem == nil { selected = entry.repo; attach() } })
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("area-repo-\(entry.repo)")
    }

    private func problem(for entry: ProjectCatalogEntry, owner: UUID?) -> String? {
        if entry.location.hostID != nil { return "\(entry.name) is on \(entry.workplace); a Project Area works on this Mac." }
        guard let owner, owner != botID, let area = model.areaOwner(repo: entry.repo) else { return nil }
        return model.areaMoveProblem(.task(area.area.id, of: owner), to: botID)
    }

    private var canAttach: Bool {
        selected != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func attach() {
        let target: ChatTarget?
        if let selected {
            target = model.attachArea(repo: selected, to: botID)
        } else if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target = model.attachArea(folderNamed: name, to: botID)
        } else {
            return
        }
        open(target)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(model.attachArea(folder: url.path, to: botID))
    }

    private func open(_ target: ChatTarget?) {
        guard let target else { NSSound.beep(); return }
        dismiss()
        model.show(target)
    }
}

/// A small capitalised heading in the sheet.
private struct SheetHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.66)
            .textCase(.uppercase)
            .foregroundStyle(Palette.secondaryText)
            .padding(.top, 2)
    }
}
