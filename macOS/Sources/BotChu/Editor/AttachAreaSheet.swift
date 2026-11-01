import AppKit
import SwiftUI
import BotChuCore

/// Attach Project Area (#402), from `+` in the Project Areas column: a repository from Projects'
/// list, each with the face of the bot whose area it is, or a folder, a new one by its name in the
/// bot's `areas/` or one chosen in Finder. Attaching opens the area, moving it from another bot
/// when it was theirs. Shown by `AttachAreaPresenter`, each opening with a new form (#438).
struct AttachAreaSheet: View {
    @Environment(AppModel.self) private var model
    let form: AttachAreaForm
    @State private var query = ""
    @State private var selected: String?
    @State private var name = ""
    @FocusState private var focus: Field?

    private enum Field { case search, name }

    var body: some View {
        let repos = AttachAreaRow.filter(form.rows, query: query)
        VStack(alignment: .leading, spacing: 12) {
            Text("Attach Project Area")
                .font(.system(size: 15, weight: .semibold))
            TextField("Search repositories", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .search)
                .accessibilityIdentifier("area-search")
            SheetHeading("Repositories")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(repos) { row in repoRow(row) }
                }
            }
            .frame(height: 224)
            .accessibilityIdentifier("area-repositories")
            SheetHeading("Folder")
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onSubmit(attach)
                    .accessibilityLabel("New folder area of \(form.botName)")
                    .accessibilityIdentifier("area-name")
                Button("Choose Folder…", action: chooseFolder)
                    .accessibilityIdentifier("area-choose-folder")
            }
            HStack {
                Spacer()
                Button("Cancel") { form.close() }
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
        // The sheet takes the keyboard once its first frame shows; the search has it then.
        .onChange(of: form.isKey) { _, key in if key, focus == nil { focus = .search } }
    }

    /// A repository: its name, and the face of the bot whose area it is. One on another computer,
    /// or whose area can't move now, can't be chosen; its tooltip says why.
    private func repoRow(_ row: AttachAreaRow) -> some View {
        let entry = row.entry, problem = row.problem
        let chosen = selected == entry.repo
        return Button {
            selected = entry.repo
            name = ""
            if focus == .name { focus = nil }
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
                if let bot = row.owner.flatMap({ form.owners[$0] }) {
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

    private var canAttach: Bool {
        selected != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func attach() {
        let target: ChatTarget?
        if let selected {
            target = model.attachArea(repo: selected, to: form.botID)
        } else if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target = model.attachArea(folderNamed: name, to: form.botID)
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
        open(model.attachArea(folder: url.path, to: form.botID))
    }

    private func open(_ target: ChatTarget?) {
        guard let target else { NSSound.beep(); return }
        model.show(target)
        form.close()
    }
}

/// What one opening of Attach Project Area shows (#438): for which bot, and its repositories as
/// they were when it opened. Changed only where it differs, so a form prepared ahead isn't laid out
/// again as it opens.
@MainActor @Observable final class AttachAreaForm {
    let id = UUID()
    private(set) var botID = UUID()
    private(set) var botName = "the bot"
    private(set) var rows: [AttachAreaRow] = []
    private(set) var owners: [UUID: Bot] = [:]
    /// Whether its sheet has the keyboard.
    var isKey = false
    @ObservationIgnored var close: () -> Void = {}

    func show(for botID: UUID, in model: AppModel) {
        let name = model.bot(botID)?.name ?? "the bot"
        let rows = model.attachAreaRows(for: botID)
        var owners: [UUID: Bot] = [:]
        for owner in Set(rows.compactMap(\.owner)) { owners[owner] = model.bot(owner) }
        if self.botID != botID { self.botID = botID }
        if botName != name { botName = name }
        if self.rows != rows { self.rows = rows }
        if self.owners != owners { self.owners = owners }
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
