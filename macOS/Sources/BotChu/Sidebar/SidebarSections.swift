import SwiftUI
import UniformTypeIdentifiers
import BotChuCore

/// The sections the sidebar and Agents group bots into (`BotSections`): moving a bot into one or
/// dragging it to its place, and renaming, reordering and removing them. Each change saves the
/// bots' order and sections in `index.json`; when that fails, the change stays, unsaved, and the
/// sidebar says so until a save works (`indexFailure`).
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

    /// Puts a bot dragged in the sidebar where it was dropped: in the section `name` names, or in
    /// none with nil, just before its bot `next`, or last in it with nil (#231). A drop that changes
    /// nothing saves nothing.
    func dropBot(_ id: UUID, inSection name: String?, before next: UUID?) {
        let before = botSections
        var layout = before
        layout.move(id, to: name, before: next)
        guard layout != before else { return }
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

/// A bot's row dragged in the sidebar (#231). It carries the bot's id as BotChu's own type, so only
/// the sidebar's bot sections and headings take it, and nothing dragged from elsewhere is taken for a bot.
enum BotDrag {
    /// Declared in the app's Info.plist (`build.sh`).
    static let contentType = UTType(exportedAs: "local.BotChu.bot", conformingTo: .data)

    /// What a bot's row gives a drag.
    static func provider(for id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = BotSections.dragPayload(id)
        // Only BotChu reads it: another app or Finder gets nothing from a dragged bot.
        provider.registerDataRepresentation(forTypeIdentifier: contentType.identifier, visibility: .ownProcess) { load in
            load(payload, nil)
            return nil
        }
        return provider
    }

    /// Reads the bot a drop carries and gives it to `dropped` on the main thread; false, taking
    /// nothing, when the drop doesn't carry one.
    static func load(_ providers: [NSItemProvider], into dropped: @escaping (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(contentType.identifier) }) else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in
            guard let id = BotSections.draggedBot(data) else { return }
            DispatchQueue.main.async { dropped(id) }
        }
        return true
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

/// A section being named in an alert: a new one for a bot to move into, or a section's new name.
/// The sidebar and Agents each keep one, and ask with `ask`.
struct SectionNaming {
    var prompt: SectionPrompt?
    var name = ""

    /// Asks for a name, starting from the section's own for a rename.
    mutating func ask(_ prompt: SectionPrompt) {
        if case .rename(let old) = prompt { name = old } else { name = "" }
        self.prompt = prompt
    }
}

extension View {
    /// Asks for the name `naming` wants in an alert, and makes or renames the section.
    func sectionNamingAlert(_ naming: Binding<SectionNaming>) -> some View {
        modifier(SectionNamingAlert(naming: naming))
    }
}

/// The alert that names a section, wherever it is asked for. A section the sidebar shows collapsed
/// stays collapsed under its new name, and a bot moved into a new section shows in it there.
struct SectionNamingAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var naming: SectionNaming
    @AppStorage(CollapsedSections.storageKey) private var collapsed = CollapsedSections()

    func body(content: Content) -> some View {
        content.alert(naming.prompt?.title ?? "", isPresented: Binding(
            get: { naming.prompt != nil }, set: { if !$0 { naming.prompt = nil } }), presenting: naming.prompt) { prompt in
            TextField("Section name", text: $naming.name)
            Button(prompt.confirm) { commit(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            if let message = prompt.message { Text(message) }
        }
    }

    /// Makes or renames the section the prompt asked for; an empty name changes nothing.
    private func commit(_ prompt: SectionPrompt) {
        let name = naming.name
        guard !name.allSatisfy(\.isWhitespace) else { return }
        switch prompt {
        case .new(let botID):
            model.moveBot(botID, toSection: name)
            let title = model.sections[botID] ?? BotSections.unsectioned
            if collapsed.titles.contains(title) { collapsed.titles.remove(title) }
        case .rename(let old):
            let before = Set(model.botSections.names)
            model.renameSection(old, to: name)
            // A renamed section stays as it was, open or collapsed; merged into another, it is as that one is.
            if collapsed.titles.remove(old) != nil, let new = Set(model.botSections.names).subtracting(before).first {
                collapsed.titles.insert(new)
            }
        }
    }
}

/// A bot's Move to Section choices: Conversations and each section, with the bot's own checked, then
/// New Section….
struct MoveToSectionItems: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    let newSection: () -> Void

    var body: some View {
        // Toggles, not an inline picker, which would add separators of its own around them.
        Toggle(BotSections.unsectioned, isOn: isIn(nil))
        ForEach(model.botSections.names, id: \.self) { name in
            Toggle(name, isOn: isIn(name))
        }
        Divider()
        Button("New Section…", action: newSection)
    }

    /// Checked for the bot's own section; choosing another moves it there.
    private func isIn(_ section: String?) -> Binding<Bool> {
        Binding(get: { model.sections[botID] == section }, set: { if $0 { model.moveBot(botID, toSection: section) } })
    }
}

/// A bot's Move to Section menu, in the sidebar's and Agents' menus for a bot.
struct MoveToSectionMenu: View {
    let botID: UUID
    let newSection: () -> Void

    var body: some View {
        Menu("Move to Section") { MoveToSectionItems(botID: botID, newSection: newSection) }
    }
}

/// A named section's menu, wherever its heading is: rename, move up or down, remove. Removing it
/// returns its bots to Conversations and deletes nothing.
struct SectionMenuItems: View {
    @Environment(AppModel.self) private var model
    @AppStorage(CollapsedSections.storageKey) private var collapsed = CollapsedSections()
    let name: String
    let rename: (String) -> Void

    var body: some View {
        let names = model.botSections.names
        let index = names.firstIndex(of: name) ?? 0
        Button("Rename Section…") { rename(name) }
        Button("Move Section Up") { model.moveSection(name, by: -1) }
            .disabled(index == 0)
        Button("Move Section Down") { model.moveSection(name, by: 1) }
            .disabled(index >= names.count - 1)
        Divider()
        Button("Remove Section") {
            model.removeSection(name)
            collapsed.titles.remove(name)
        }
    }
}

/// A section's heading in the sidebar. A named section's menu renames, reorders and removes it;
/// Conversations has none.
struct SidebarSectionHeader: View {
    let group: BotSections.Group
    let rename: (String) -> Void

    var body: some View {
        if let name = group.name {
            Text(name)
                .contextMenu { SectionMenuItems(name: name, rename: rename) }
                .accessibilityIdentifier("sidebar-section-\(name)")
        } else {
            Text(group.title)
        }
    }
}
