import SwiftUI
import BotChuCore

/// A reply's Markdown, parsed once per text (`MarkdownCache`): drawing a conversation again, or a
/// reply that didn't change, doesn't parse it again. A reply being written is parsed off the main
/// thread (`MarkdownPreparation`): it shows its latest rendering meanwhile and, once it is long,
/// the text written since as it is. The rendering keeps its place in the view as it is replaced,
/// so a rich reply keeps its web view. Its text is selected across its blocks (`ReplySelection`).
struct MarkdownText: View {
    let text: String
    @State private var preparation = PreparedMarkdown()
    @State private var selection = ReplySelectionController()
    /// How many times a long reply's chunk was laid out, for tests.
    @MainActor static var chunkLayouts = 0

    var body: some View {
        let _ = preparation.revision
        let display = preparation.core.display(for: text)
        let blocks = if case .blocks(let blocks) = display.rendering { blocks } else { [MarkdownBlock]() }
        let _ = selection.show(blocks, pending: display.pending)
        ReplyStack(spacing: 10) {
            switch display.rendering {
            case .rich(let html):
                RichMarkdownText(html: html)
            case .blocks(let blocks) where blocks.count >= SeparateBlocks.threshold:
                // Chunks that are written, each laid out apart, then the one being written.
                let settled = (blocks.count - 1) / SeparateBlocks.chunk * SeparateBlocks.chunk
                ForEach(Array(stride(from: 0, to: settled, by: SeparateBlocks.chunk)), id: \.self) { start in
                    SeparateBlocks(blocks: Array(blocks[start..<start + SeparateBlocks.chunk]))
                }
                MarkdownBlocks(blocks: Array(blocks[settled...]))
            case .blocks(let blocks):
                MarkdownBlocks(blocks: blocks)
            case nil:
                EmptyView()
            }
            if let pending = display.pending {
                Text(pending)
                    .replyPiece(ReplyText.Key(path: [blocks.count], part: .pending))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .selectableReplyText()
        .environment(\.replySelection, selection)
        .onChange(of: text, initial: true) { preparation.core.update(text) }
    }
}

/// A reply's parts, one under another, as a leading-aligned `VStack` lays them out, but asked for
/// its ideal size (as the window asks its content, whenever a reply changes), it answers with the
/// width it was last laid out at. A `VStack` measures its parts at the width of its widest line
/// instead, which grows with the line being written, so every revision of a long reply laid each
/// of its chunks out again at a width it is never shown at (about 80 ms for 128 KB).
private struct ReplyStack: Layout {
    var spacing: CGFloat

    struct Cache {
        var width: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    // The width it was laid out at holds while its parts change.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? cache.width
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            height += size.height + (index > 0 ? spacing : 0)
            widest = max(widest, size.width)
        }
        return CGSize(width: width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        cache.width = bounds.width
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + spacing
        }
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

/// A long reply's blocks, a chunk of them in a hosting view of its own, measured once for each
/// width: the chat's layout passes, for a key press, a delta or another row, see one view for each
/// chunk rather than every block and its selectable text (beside a reply of 1,500 blocks, about
/// 0.1 ms rather than 7). A chunk is laid out again only when its blocks, the appearance or the font
/// change; as a reply is written, its revisions keep the blocks they don't change (`reusing`), so
/// comparing them takes microseconds.
private struct SeparateBlocks: NSViewRepresentable {
    /// From about 20 KB of prose; shorter replies cost little to lay out with the rest.
    static let threshold = 256
    static let chunk = 128
    let blocks: [MarkdownBlock]

    final class Coordinator {
        var controller: NSHostingController<AnyView>?
        var shown: Shown?
        var heights: [CGFloat: CGFloat] = [:]
    }

    struct Shown: Equatable {
        let blocks: [MarkdownBlock]
        let colorScheme: ColorScheme
        let font: Font?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let controller = NSHostingController(rootView: content(context))
        controller.sizingOptions = []
        context.coordinator.controller = controller
        context.coordinator.shown = shown(context)
        return controller.view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let shown = shown(context)
        guard shown != context.coordinator.shown else { return }
        context.coordinator.shown = shown
        context.coordinator.heights.removeAll()
        context.coordinator.controller?.rootView = content(context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let controller = context.coordinator.controller else { return nil }
        if let height = context.coordinator.heights[width] { return CGSize(width: width, height: height) }
        MarkdownText.chunkLayouts += 1
        let height = ceil(controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        // A few widths, as a window being resized goes through many.
        if context.coordinator.heights.count >= 8 { context.coordinator.heights.removeAll() }
        context.coordinator.heights[width] = height
        return CGSize(width: width, height: height)
    }

    private func shown(_ context: Context) -> Shown {
        Shown(blocks: blocks, colorScheme: context.environment.colorScheme, font: context.environment.font)
    }

    private func content(_ context: Context) -> AnyView {
        // The chunk's mark inside the environment it is given, which holds every value.
        AnyView(MarkdownBlocks(blocks: blocks).selectableReplyText()
            .environment(\.inReplyChunk, true).environment(\.self, context.environment))
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
            inline(block.text, ReplyText.Key(path: block.path, part: .text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .paragraph, .tableCell:
            inline(block.text, ReplyText.Key(path: block.path, part: .text))
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
                    Text(block.code)
                        .replyPiece(ReplyText.Key(path: block.path, part: .code))
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                        .selectableReplyText()
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
        case .orderedList, .unorderedList:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(block.children) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(block.marker(for: item))
                            .replyPiece(ReplyText.Key(path: item.path, part: .marker))
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
                                inline(cell?.text ?? AttributedString(), ReplyText.Key(path: row.path, part: .cell(index)))
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
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                .selectableReplyText()
            }
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        default:
            MarkdownBlocks(blocks: block.children)
        }
    }

    /// Inline Markdown as the reply's piece `key`.
    private func inline(_ text: AttributedString, _ key: ReplyText.Key) -> some View {
        var styled = text
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(.callout, design: .monospaced)
            styled[run.range].backgroundColor = Color.primary.opacity(0.06)
        }
        return Text(styled).replyPiece(key).fixedSize(horizontal: false, vertical: true)
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
