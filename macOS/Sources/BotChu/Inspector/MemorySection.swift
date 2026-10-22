import SwiftUI
import BotChuCore

struct MemorySection: View {
    @Environment(AppModel.self) private var model
    let botID: UUID

    var body: some View {
        InspectorSection("Memory") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(BotDocument.allCases) { document in
                    Button { model.editDocument(document, for: botID) } label: {
                        InspectorCard(padded: true) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.rawValue)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text(document.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Edit \(document.rawValue) for this bot")
                    .accessibilityLabel("Edit \(document.rawValue)")
                }
            }
        }
    }
}
