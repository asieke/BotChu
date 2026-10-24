import SwiftUI
import BotChuCore

/// A reply's Markdown, parsed once per text (`MarkdownCache`): drawing a conversation again, or a
/// reply that didn't change, doesn't parse it again. A reply being written is parsed off the main
/// thread (`MarkdownPreparation`): it shows its latest rendering meanwhile and, once it is long,
/// the text written since as it is. The rendering keeps its place in the view as it is replaced,
/// so a rich reply keeps its web view.
struct MarkdownText: View {
    let text: String
    @State private var preparation = PreparedMarkdown()

    var body: some View {
        let _ = preparation.revision
        let display = preparation.core.display(for: text)
        VStack(alignment: .leading, spacing: 10) {
            switch display.rendering {
            case .rich(let html):
                RichMarkdownText(html: html)
            case .blocks(let blocks):
                MarkdownBlocks(blocks: blocks)
                    .textSelection(.enabled)
            case nil:
                EmptyView()
            }
            if let pending = display.pending {
                Text(pending)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: text, initial: true) { preparation.core.update(text) }
    }
}

/// A `MarkdownText`'s preparation, drawn again each time the worker's rendering is shown.
@MainActor @Observable private final class PreparedMarkdown {
    @ObservationIgnored let core = MarkdownPreparation()
    private(set) var revision = 0

    init() {
        core.onPublish = { [weak self] in self?.revision += 1 }
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    var spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .header(let level):
            inline(block.text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .paragraph, .tableCell:
            inline(block.text)
        case .codeBlock(let language):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language?.isEmpty == false ? language! : "Code")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(block.text.characters), forType: .string)
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain).help("Copy code")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                ScrollView(.horizontal) {
                    Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        case .orderedList, .unorderedList:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(block.children) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker(for: item))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        MarkdownBlocks(blocks: item.children, spacing: 6)
                    }
                }
            }
        case .blockQuote:
            MarkdownBlocks(blocks: block.children)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)).frame(width: 3)
                }
        case .table(let columns):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(block.children) { row in
                        GridRow {
                            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                                let cell = row.children.first { $0.kind == .tableCell(columnIndex: index) }
                                // Each cell fills its whole row, so its rule and the header's fill line up
                                // with the row's tallest cell, also beside an empty or inline-code cell.
                                inline(cell?.text ?? AttributedString())
                                    .fontWeight(row.kind == .tableHeaderRow ? .semibold : .regular)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(column.alignment))
                                    .background(row.kind == .tableHeaderRow ? Color.primary.opacity(0.06) : .clear)
                                    .overlay(alignment: .bottom) {
                                        if row.id != block.children.last?.id { Divider() }
                                    }
                                    .gridColumnAlignment(horizontalAlignment(column.alignment))
                            }
                        }
                    }
                }
                // At its ideal size both ways: cells don't wrap, and filling a row never makes it taller.
                .fixedSize()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
            }
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        default:
            MarkdownBlocks(blocks: block.children)
        }
    }

    private func inline(_ text: AttributedString) -> some View {
        var styled = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(.callout, design: .monospaced)
            styled[run.range].backgroundColor = Color.primary.opacity(0.06)
        }
        return Text(styled).fixedSize(horizontal: false, vertical: true)
    }

    private func marker(for item: MarkdownBlock) -> String {
        if block.kind == .orderedList, case .listItem(let ordinal) = item.kind { return "\(ordinal)." }
        return "•"
    }

    private func horizontalAlignment(_ value: PresentationIntent.TableColumn.Alignment) -> HorizontalAlignment {
        switch value {
        case .right: .trailing
        case .center: .center
        default: .leading
        }
    }

    private func alignment(_ value: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch value {
        case .right: .topTrailing
        case .center: .top
        default: .topLeading
        }
    }
}
