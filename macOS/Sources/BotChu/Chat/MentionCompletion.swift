import AppKit
import SwiftUI
import BotChuCore

/// The saved Projects catalog as `#` completion describes it.
struct MentionCatalogState: Equatable {
    /// The GitHub account it belongs to.
    var login: String?
    /// Whether a catalog is saved (or was read) for that account.
    var loaded = false
    var syncing = false
    var syncedAt: Date?
    /// Why the last sync failed.
    var error: String?
}

/// What a conversation's message box completes `@` and `#` from, all of it local: the configured agents
/// and the saved Projects catalog, read when the list opens, never waiting on GitHub.
struct MentionSources {
    /// The agents `@` offers, in the sidebar's order.
    var agents: @MainActor () -> [BotRosterEntry]
    /// The projects `#` offers: the whole saved catalog, whatever Projects' search and filter show.
    var projects: @MainActor () -> [ProjectCatalogEntry]
    var catalog: @MainActor () -> MentionCatalogState
    /// The conversation's own repository (a task's), which `#` offers first.
    var favoredRepo: String?
    var status: @MainActor (MessageReference) -> ReferenceStatus
    /// Syncs the Projects catalog now.
    var loadProjects: @MainActor () -> Void
    /// Shows Agents, where agents are made.
    var openAgents: @MainActor () -> Void

    /// The mentions of `references` that point at nothing now, one per agent or project.
    @MainActor func unresolved(_ references: [MessageReference]) -> [(reference: MessageReference, status: ReferenceStatus)] {
        var seen = Set<String>()
        return references.compactMap { reference in
            guard seen.insert(reference.statusKey).inserted else { return nil }
            let status = status(reference)
            return status.isResolved ? nil : (reference, status)
        }
    }
}

enum MentionSuggestion: Identifiable, Equatable {
    case agent(BotRosterEntry, detail: String)
    case project(ProjectCatalogEntry)

    var id: String {
        switch self {
        case .agent(let agent, _): "agent:" + agent.id.uuidString
        case .project(let project): "project:" + project.repo.lowercased()
        }
    }

    var title: String {
        switch self {
        case .agent(let agent, _): agent.name
        case .project(let project): project.name
        }
    }

    /// What an agent runs on (and its ID, beside a namesake), a project's `owner/name`.
    var subtitle: String {
        switch self {
        case .agent(_, let detail): detail
        case .project(let project): project.repo
        }
    }

    var accessibilityLabel: String { subtitle.isEmpty ? title : "\(title), \(subtitle)" }

    func reference(login: String?) -> MessageReference {
        switch self {
        case .agent(let agent, _): .agent(agent)
        case .project(let project): .project(project, login: login)
        }
    }
}

/// `@` and `#` completion in one message box. Typing a trigger opens a short list of agents or
/// projects matching what follows it (`MentionQuery`, `MentionDirectory`); Up and Down choose, Return or
/// Tab inserts the chosen one, a click inserts it, Escape closes the list and leaves the draft alone.
/// Only typing opens it: pasted text, a draft restored or a caret moved into old text don't.
@MainActor @Observable
final class MentionCompleter {
    struct Popup: Equatable {
        var query: MentionQuery
        /// The best matches, at most `MentionCompleter.shown`.
        var suggestions: [MentionSuggestion]
        var total: Int
        var selected: Int?
        /// Where the trigger's left edge is, from the editor's left.
        var anchor: CGFloat
        /// Where the trigger's line ends, from the editor's top.
        var line: CGFloat = 0
        /// The editor's width.
        var width: CGFloat
        /// For projects, the saved catalog's state.
        var catalog: MentionCatalogState?
        /// Whether `@` has any agent to offer.
        var hasAgents = true
    }

    static let shown = 6

    private(set) var popup: Popup?
    @ObservationIgnored var sources: MentionSources?
    @ObservationIgnored weak var editor: ComposerTextView?
    /// What the open list matches against, read when it opened.
    @ObservationIgnored private var directory: (kind: MessageReference.Kind, value: MentionDirectory, agents: [BotRosterEntry])?
    /// The trigger of a query the owner closed with Escape, which stays closed while it is edited.
    @ObservationIgnored private var dismissed: Int?

    var isOpen: Bool { popup != nil }

    /// After the text or the caret changed: follows the query the caret is in, closing when there is
    /// none. Only `typed` text opens the list.
    func update(typed: Bool) {
        guard let editor, sources != nil, !editor.hasMarkedText() else { return }
        let selection = editor.selectedRange()
        guard selection.length == 0,
              let query = MentionQuery.at(selection.location, in: editor.string, outside: editor.mentionReferences.map(\.range)) else {
            dismissed = nil
            close()
            return
        }
        if let dismissed {
            guard dismissed != query.range.location else { close(); return }
            self.dismissed = nil
        }
        guard popup != nil || typed else { return }
        show(query, keeping: popup?.query.kind == query.kind ? popup?.selectedSuggestion?.id : nil)
    }

    /// The saved catalog changed (a sync finished): the open project list matches against it now,
    /// keeping its selection.
    func catalogChanged() {
        guard let popup, popup.query.kind == .project else { return }
        directory = nil
        show(popup.query, keeping: popup.selectedSuggestion?.id, announces: false)
    }

    func move(_ delta: Int) {
        guard var popup, !popup.suggestions.isEmpty else { return }
        let count = popup.suggestions.count
        popup.selected = ((popup.selected ?? (delta > 0 ? -1 : count)) + delta + count) % count
        self.popup = popup
        if let suggestion = popup.selectedSuggestion, let index = popup.selected {
            announce("\(suggestion.accessibilityLabel), \(index + 1) of \(count)")
        }
    }

    /// Puts the suggestion's label where the query is, linked to its agent or project.
    func accept(_ index: Int) {
        guard let popup, let editor, popup.suggestions.indices.contains(index) else { return }
        let reference = popup.suggestions[index].reference(login: popup.catalog?.login ?? sources?.catalog().login)
        let (replacement, caret) = MentionInsertion.make(label: reference.label, replacing: popup.query.range, in: editor.string)
        close()
        editor.insertMention(reference, replacing: popup.query.range, with: replacement, caret: caret)
        announce("Inserted \(reference.label)")
    }

    /// Escape: closes the list, leaving the query as ordinary text.
    func dismiss() {
        dismissed = popup?.query.range.location
        close()
    }

    func close() {
        if popup != nil { popup = nil }
        directory = nil
    }

    func loadProjects() { sources?.loadProjects() }
    func openAgents() { sources?.openAgents() }

    /// The keys the open list takes: Up, Down, Return and Tab with a suggestion chosen, Escape. Never
    /// while an input method is composing, and never Return with nothing chosen, which sends as before.
    func handle(_ event: NSEvent) -> Bool {
        guard let popup, editor?.hasMarkedText() == false else { return false }
        let plain = event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        switch event.keyCode {
        case 125 where plain && !popup.suggestions.isEmpty: move(1)
        case 126 where plain && !popup.suggestions.isEmpty: move(-1)
        case 36, 76, 48:
            guard plain, let selected = popup.selected else { return false }
            accept(selected)
        case 53: dismiss()
        default: return false
        }
        return true
    }

    private func show(_ query: MentionQuery, keeping id: String?, announces: Bool = true) {
        guard let editor, let sources else { return }
        let directory = directory(for: query.kind, sources: sources)
        let matches: [MentionSuggestion] = switch query.kind {
        case .agent: directory.value.agents(matching: query.text).map { .agent($0, detail: "") }
        case .project: directory.value.projects(matching: query.text).map { .project($0) }
        }
        guard query.showsList(matches: matches.count) else { close(); return }
        let suggestions = matches.prefix(Self.shown).map { suggestion -> MentionSuggestion in
            guard case .agent(let agent, _) = suggestion else { return suggestion }
            return .agent(agent, detail: MentionDirectory.detail(of: agent, among: directory.agents))
        }
        let opened = popup == nil || popup?.query.range.location != query.range.location || popup?.query.kind != query.kind
        let selected = id.flatMap { id in suggestions.firstIndex { $0.id == id } } ?? (suggestions.isEmpty ? nil : 0)
        let next = Popup(query: query, suggestions: suggestions, total: matches.count, selected: selected,
                         anchor: editor.mentionX(at: query.range.location), line: editor.mentionLineBottom(at: query.range.location),
                         width: editor.bounds.width,
                         catalog: query.kind == .project ? sources.catalog() : nil, hasAgents: !directory.agents.isEmpty)
        if popup != next { popup = next }
        guard announces, opened || popup?.total != matches.count else { return }
        let kind = query.kind == .agent ? "agent" : "project"
        announce(suggestions.isEmpty ? "No \(kind) suggestions"
                 : "\(matches.count) \(kind) suggestion\(matches.count == 1 ? "" : "s"), \(suggestions[selected ?? 0].accessibilityLabel) selected")
    }

    private func directory(for kind: MessageReference.Kind, sources: MentionSources) -> (kind: MessageReference.Kind, value: MentionDirectory, agents: [BotRosterEntry]) {
        if let directory, directory.kind == kind { return directory }
        let made: (kind: MessageReference.Kind, value: MentionDirectory, agents: [BotRosterEntry])
        switch kind {
        case .agent:
            let agents = sources.agents()
            made = (kind, MentionDirectory(agents: agents), agents)
        case .project:
            made = (kind, MentionDirectory(projects: sources.projects(), favoring: sources.favoredRepo), [])
        }
        directory = made
        return made
    }

    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let editor else { return }
        NSAccessibility.post(element: editor, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

extension MentionCompleter.Popup {
    var selectedSuggestion: MentionSuggestion? { selected.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil } }
}

/// The list `@` and `#` open just above the message box, below the trigger, over the chat rather than
/// in the composer's layout: the box never moves or resizes for it, and it never covers the draft.
/// It goes on the box, whose editor is `inset` from its edges.
struct MentionPopupView: View {
    let completer: MentionCompleter
    var inset: CGFloat = 0

    var body: some View {
        if let popup = completer.popup {
            let box = popup.width + 2 * inset
            let width = min(320, box)
            // A point just above the box, which the list's bottom left corner sits on, so it grows
            // upward from there, under the trigger as far as the box's width allows.
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: .bottomLeading) {
                    MentionList(popup: popup, completer: completer)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .offset(x: max(0, min(inset + popup.anchor - 10, box - width)), y: -8)
        }
    }
}

/// Where a sheet's text is, for the list its `@` and `#` open: a Form clips what its rows overlay,
/// so the sheet draws the list over all of itself (`mentionPopups()`).
struct MentionPopupAnchor {
    let completer: MentionCompleter
    let editor: Anchor<CGRect>
}

struct MentionPopupAnchorKey: PreferenceKey {
    static var defaultValue: MentionPopupAnchor? { nil }
    static func reduce(value: inout MentionPopupAnchor?, nextValue: () -> MentionPopupAnchor?) { value = value ?? nextValue() }
}

extension View {
    /// Draws the `@` and `#` list of the `DraftEditor` in the view over all of it, where nothing
    /// clips it: just above the text as the message box's is, or when it doesn't fit there, just
    /// below the line being typed, kept inside the view.
    func mentionPopups() -> some View {
        overlayPreferenceValue(MentionPopupAnchorKey.self) { anchor in
            if let anchor {
                GeometryReader { proxy in
                    SheetMentionPopup(completer: anchor.completer, editor: proxy[anchor.editor], bottom: proxy.size.height)
                }
            }
        }
    }
}

private struct SheetMentionPopup: View {
    let completer: MentionCompleter
    let editor: CGRect
    let bottom: CGFloat
    @State private var height: CGFloat = 0

    var body: some View {
        if let popup = completer.popup {
            let width = min(320, popup.width)
            let above = editor.minY - 8 >= height
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: above ? .bottomLeading : .topLeading) {
                    MentionList(popup: popup, completer: completer)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                }
                .offset(x: editor.minX + max(0, min(popup.anchor - 10, popup.width - width)),
                        y: above ? editor.minY - 8 : max(0, min(editor.minY + popup.line + 4, bottom - height - 4)))
        }
    }
}

private struct MentionList: View {
    let popup: MentionCompleter.Popup
    let completer: MentionCompleter
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(popup.query.kind == .agent ? "Agents" : "Projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .accessibilityAddTraits(.isHeader)
            if popup.suggestions.isEmpty {
                empty
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 30)
            } else {
                ForEach(Array(popup.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    MentionRow(suggestion: suggestion, selected: index == popup.selected)
                        .onTapGesture { completer.accept(index) }
                        .accessibilityAction { completer.accept(index) }
                }
                if popup.total > popup.suggestions.count {
                    Text("+\(popup.total - popup.suggestions.count) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                }
            }
            if let catalog = popup.catalog, catalog.loaded { freshness(catalog) }
        }
        // As wide with no match as with some, so the list doesn't jump as the query changes.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        // A sync that finishes while the list is open: it matches against the new catalog, keeping its selection.
        .onChange(of: model?.mentionCatalog) { completer.catalogChanged() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(popup.query.kind == .agent ? "Agent suggestions" : "Project suggestions")
    }

    @ViewBuilder private var empty: some View {
        switch popup.query.kind {
        case .agent:
            if popup.hasAgents {
                Text("No agents match “\(popup.query.text)”").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("No other agents yet").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Open Agents") { completer.openAgents() }
                }
            }
        case .project:
            if let catalog = popup.catalog, !catalog.loaded {
                HStack(spacing: 6) {
                    if catalog.syncing {
                        ProgressView().controlSize(.small)
                        Text("Loading your projects…").foregroundStyle(.secondary)
                    } else {
                        Text(catalog.error == nil ? "Your projects aren’t loaded yet" : "Couldn’t load your projects")
                            .foregroundStyle(.secondary)
                            .help(catalog.error ?? "")
                        Spacer(minLength: 8)
                        Button("Load Projects") { completer.loadProjects() }
                    }
                }
            } else {
                Text("No projects match “\(popup.query.text)”").foregroundStyle(.secondary)
            }
        }
    }

    /// How fresh the saved catalog is, unobtrusively, with Refresh.
    private func freshness(_ catalog: MentionCatalogState) -> some View {
        HStack(spacing: 4) {
            if catalog.syncing {
                ProgressView().controlSize(.mini)
                Text("Syncing projects…")
            } else if let error = catalog.error {
                Image(systemName: "exclamationmark.triangle")
                Text("Couldn’t sync projects").help(error)
            } else if let syncedAt = catalog.syncedAt {
                Text("Projects synced \(syncedAt.formatted(.relative(presentation: .named)))")
            }
            Spacer(minLength: 4)
            Button { completer.loadProjects() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(catalog.syncing)
            .help("Refresh Projects")
            .accessibilityLabel("Refresh Projects")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }
}

private struct MentionRow: View {
    let suggestion: MentionSuggestion
    let selected: Bool
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(suggestion.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(suggestion.accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        switch suggestion {
        case .agent(let agent, _):
            if let model, let bot = model.bot(agent.id) {
                BotAvatar(bot: bot, size: 22)
            } else {
                Text(agent.emoji).font(.system(size: 13))
            }
        case .project:
            Image(systemName: "book.closed")
                .foregroundStyle(selected ? Color.white : Color.secondary)
        }
    }
}

/// Says which of the draft's mentions point at nothing now (a deleted agent, a project the catalog
/// doesn't list), never pointing them anywhere else, with Unlink, which keeps their text without the
/// link, and, for projects, Refresh Projects.
struct MentionProblems: View {
    let problems: [String]
    let projects: Bool
    let refresh: () -> Void
    let unlink: () -> Void

    /// For a draft's `unresolved` mentions: Unlink takes them out of its `references`.
    init(_ unresolved: [(reference: MessageReference, status: ReferenceStatus)], sources: MentionSources,
         references: Binding<[MessageReference]>) {
        let keys = Set(unresolved.map(\.reference.statusKey))
        problems = unresolved.compactMap { $0.status.problem($0.reference) }
        projects = unresolved.contains { $0.reference.kind == .project }
        refresh = { sources.loadProjects() }
        unlink = { references.wrappedValue.removeAll { keys.contains($0.statusKey) } }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(problems.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(problems.joined(separator: "\n"))
            Spacer(minLength: 4)
            if projects { Button("Refresh Projects", action: refresh) }
            Button("Unlink", action: unlink).help("Keep the text without linking it to anything")
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
    }
}
