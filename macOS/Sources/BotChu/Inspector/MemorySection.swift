import SwiftUI
import BotChuCore

struct MemorySection: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        InspectorSection("Memory") {
            Text(BotContext.memoryOverview)
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(BotDocument.allCases) { document in
                    DocumentCard(name: document.rawValue, summary: document.summary,
                                 help: document == .memory
                                     ? "Edit MEMORY.md for this bot: stable preferences, confirmed facts, reusable lessons and durable decisions"
                                     : "Edit \(document.rawValue) for this bot") {
                        model.editDocument(document, for: botID)
                    }
                }
                // The playbook every session opens with is the bots folder's: the same file for every
                // bot (also in Settings). The shared MEMORY.md stays in Settings, so the MEMORY.md
                // here is only ever this bot's.
                DocumentCard(name: SharedDocument.team.rawValue, summary: SharedDocument.team.summary,
                             help: "Edit \(SharedDocument.team.rawValue), the playbook every bot follows, in the bots folder") {
                    model.editSharedDocument(.team)
                }
            }
        }
        SkillsSection(botID: botID)
    }
}

/// The bot's skills: its own, and the shared ones, each of which can be turned off for it.
private struct SkillsSection: View {
    @Environment(AppModel.self) private var model
    let botID: UUID
    @State private var entries: [SkillEntry] = []

    var body: some View {
        if let bot = model.bot(botID) {
            // Shared skills one of the bot's own takes the place of are left out, as sessions leave them out.
            let own = entries.filter { $0.bot?.id == botID }
            let shared = entries.filter { $0.bot == nil && !own.map(\.skill.slug).contains($0.skill.slug) }
            let active = own.count + shared.filter { bot.usesSharedSkill($0.skill.slug) }.count
            InspectorSection("Skills", trailing: entries.isEmpty ? nil : "\(active) on") {
                Text("Runbooks this bot reads when its work calls for them: each session gets their names and descriptions only.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                if !own.isEmpty || !shared.isEmpty {
                    InspectorCard {
                        let rows = own + shared
                        ForEach(rows) { entry in
                            SkillRow(entry: entry, last: entry.id == rows.last?.id,
                                     enabled: entry.bot != nil || bot.usesSharedSkill(entry.skill.slug),
                                     toggle: entry.bot != nil ? nil : { model.setSharedSkill(entry.skill.slug, enabled: $0, for: botID) },
                                     edit: { model.editSkill(entry) })
                        }
                    }
                }
                Button { model.destination = .skills } label: {
                    Label(entries.isEmpty ? "Add Skills" : "Manage Skills", systemImage: "wand.and.stars")
                }
                .buttonStyle(InspectorButtonStyle(fill: true))
            }
            // Read again when the editor opens or closes, and when the bot changes.
            .task(id: model.documentEditor?.id) { reload() }
            .onChange(of: bot) { reload() }
        }
    }

    private func reload() {
        entries = model.skillEntries(of: botID)
    }
}

/// A skill on a line of its card: its name and description, which open it, and for a shared one a
/// switch that turns it on or off for this bot.
private struct SkillRow: View {
    let entry: SkillEntry
    let last: Bool
    let enabled: Bool
    let toggle: ((Bool) -> Void)?
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.skill.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Text(entry.bot == nil ? entry.skill.description : "Own · \(entry.skill.description)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .help("Edit \(entry.skill.name)'s SKILL.md")
            if let toggle {
                Toggle("", isOn: Binding(get: { enabled }, set: toggle))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(enabled ? "Turn \(entry.skill.name) off for this bot" : "Turn \(entry.skill.name) on for this bot")
                    .accessibilityLabel("Use \(entry.skill.name)")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Palette.rowDivider).frame(height: 1) }
        }
    }
}

/// A Markdown file's card, which opens it in the editor.
private struct DocumentCard: View {
    let name: String
    let summary: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            InspectorCard(padded: true) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("Edit \(name)")
    }
}
