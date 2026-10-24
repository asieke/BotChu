import SwiftUI
import BotChuCore

/// The sections the sidebar groups bots into (`BotSections`): moving a bot into one, and renaming,
/// reordering and removing them. Each change saves the bots' order and sections in `index.json`; when
/// that fails, the change stays, unsaved, and the sidebar says so until a save works (`indexFailure`).
extension AppModel {
    /// The bots as the sidebar groups them.
    var botSections: BotSections { BotSections(order: bots.map(\.id), membership: sections) }

    /// Puts a bot in the section `name` names, last among its bots (a new name starts a section), or
    /// in none with nil.
    func moveBot(_ id: UUID, toSection name: String?) {
        var layout = botSections
        layout.move(id, to: name)
        arrange(layout)
    }

    /// Renames a section; another section's name merges the two. Bots whose folders are missing go
    /// with it, so they come back in it.
    func renameSection(_ name: String, to newName: String) {
        var layout = botSections
        guard let member = layout.groups.first(where: { $0.name == name })?.botIDs.first else { return }
        layout.rename(name, to: newName)
        let renamed = layout.section(of: member)
        for i in missing.indices where BotSections.matches(missing[i].section, section: name) { missing[i].section = renamed }
        arrange(layout)
    }

    /// Removes a section: its bots, also those whose folders are missing, go back to Conversations.
    func removeSection(_ name: String) {
        var layout = botSections
        layout.remove(name)
        for i in missing.indices where BotSections.matches(missing[i].section, section: name) { missing[i].section = nil }
        arrange(layout)
    }

    /// Moves a section up (offset -1) or down (+1) among the sections.
    func moveSection(_ name: String, by offset: Int) {
        var layout = botSections
        layout.moveSection(name, by: offset)
        arrange(layout)
    }

    /// Puts the bots in the order and sections `layout` gives, and saves the index unless `save` is false.
    func arrange(_ layout: BotSections, save: Bool = true) {
        let byID = Dictionary(bots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = layout.order.compactMap { byID[$0] }
        if ordered.map(\.id) != bots.map(\.id) { bots = ordered }
        if sections != layout.membership { sections = layout.membership }
        if save { saveIndex() }
    }
}

/// The sidebar's collapsed sections, by heading, remembered across launches.
struct CollapsedSections: RawRepresentable, Equatable {
    static let storageKey = "sidebar.collapsedSections"
    var titles: Set<String> = []

    init() {}
    init(rawValue: String) { titles = Set(rawValue.split(separator: "\n").map(String.init)) }
    var rawValue: String { titles.sorted().joined(separator: "\n") }
}

/// Naming a section: a new one for a bot to move into, or a section's new name.
enum SectionPrompt: Identifiable, Equatable {
    case new(botID: UUID)
    case rename(String)

    var id: String {
        switch self {
        case .new(let botID): "new-\(botID)"
        case .rename(let name): "rename-\(name)"
        }
    }

    var title: String {
        switch self {
        case .new: "New Section"
        case .rename: "Rename Section"
        }
    }

    var confirm: String {
        switch self {
        case .new: "Create"
        case .rename: "Rename"
        }
    }

    var message: String? {
        switch self {
        case .new: nil
        case .rename: "Another section's name merges the two."
        }
    }
}

/// A bot's Move to Section menu: Conversations and each section, with the bot's own checked, then
/// New Section….
struct MoveToSectionMenu: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let newSection: () -> Void

    var body: some View {
        Menu("Move to Section") {
            // Toggles, not an inline picker, which would add separators of its own around them.
            Toggle(BotSections.unsectioned, isOn: isIn(nil))
            ForEach(model.botSections.names, id: \.self) { name in
                Toggle(name, isOn: isIn(name))
            }
            Divider()
            Button("New Section…", action: newSection)
        }
    }

    /// Checked for the bot's own section; choosing another moves it there.
    private func isIn(_ section: String?) -> Binding<Bool> {
        Binding(get: { model.sections[botID] == section }, set: { if $0 { model.moveBot(botID, toSection: section) } })
    }
}

/// A section's heading in the sidebar. A named section's menu renames, reorders and removes it;
/// Conversations has none.
struct SidebarSectionHeader: View {
    @Environment(AppModel.self) private var model
    let group: BotSections.Group
    let rename: (String) -> Void
    let remove: (String) -> Void

    var body: some View {
        if let name = group.name {
            let names = model.botSections.names
            let index = names.firstIndex(of: name) ?? 0
            Text(name)
                .contextMenu {
                    Button("Rename Section…") { rename(name) }
                    Button("Move Section Up") { model.moveSection(name, by: -1) }
                        .disabled(index == 0)
                    Button("Move Section Down") { model.moveSection(name, by: 1) }
                        .disabled(index >= names.count - 1)
                    Divider()
                    Button("Remove Section") { remove(name) }
                }
                .accessibilityIdentifier("sidebar-section-\(name)")
        } else {
            Text(group.title)
        }
    }
}
