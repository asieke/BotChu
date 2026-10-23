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
