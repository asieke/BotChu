import AppKit
import SwiftUI
import BotChuCore

/// Selecting a reply's text across its lines and blocks (#156). SwiftUI selects text one `Text` at a
/// time, and a reply draws each heading, paragraph, list item, cell and code block as a `Text` of
/// its own, so a selection couldn't leave the one it began in. Instead, the reply's texts take no
/// clicks, and a surface behind them (`ReplyTextSurface`) takes the mouse wherever no control does,
/// finds the place under it from where SwiftUI laid each text out, and shows the selection there.
/// A reply has a surface for its own blocks, one for each chunk laid out apart, and one inside each
/// code block and table, which scroll sideways; they share the reply's selection
/// (`ReplySelectionController`), which copies as `ReplyText` says.
///
/// A surface learns its texts' layouts one of two ways. Over a reply's own blocks it reads them all
/// from SwiftUI (`Text.LayoutKey`), which lays each text out again whenever the reply changes:
/// cheap for the at most 255 blocks there, but not for the chunks of a long reply, which would all
/// be laid out again for each delta (about 17 ms for 128 KB). So in a chunk each text gives its
/// layout as it is drawn (`ReplyPieceRenderer`), and its frame as it moves; texts drawn that way
/// keep more memory (about 200 MB more in the chat benchmark had every reply done it), hence only
/// in chunks. Before macOS 15, which has no text renderers, chunks read their layouts too.
extension View {
    /// Lets the reply text drawn in this view be selected, but for the text of surfaces within it.
    func selectableReplyText() -> some View {
        modifier(SelectableReplyText())
    }
}

extension Text {
    /// This text as the piece `key` of its reply, selected with the rest of the reply rather than
    /// on its own.
    func replyPiece(_ key: ReplyText.Key) -> some View {
        customAttribute(ReplyPieceTag(key: key)).modifier(ReplyPiece(key: key))
    }
}

extension EnvironmentValues {
    /// The selection of the reply being drawn.
    @Entry var replySelection: ReplySelectionController?
    /// The text drawn here is a chunk of a long reply, laid out apart (`MarkdownText`).
    @Entry var inReplyChunk = false
    /// Where the texts drawn as they give their layouts keep them, for the surface behind them.
    @Entry fileprivate var replyPieces: ReplyPieces?
}

/// Whether the texts drawn here give their layouts as they are drawn.
private func givesLayouts(inChunk: Bool) -> Bool {
    guard #available(macOS 15, *) else { return false }
    return inChunk
}

private struct SelectableReplyText: ViewModifier {
    @Environment(\.inReplyChunk) private var inChunk
    @State private var pieces = ReplyPieces()

    func body(content: Content) -> some View {
        if givesLayouts(inChunk: inChunk) {
            content
                .coordinateSpace(.named(pieces.space))
                .environment(\.replyPieces, pieces)
                .background(ReplySurface(source: .given(pieces)))
                // Nothing for a reader above (the reply's own, beyond the chunk's hosting view)
                // to have SwiftUI lay these texts out again for.
                .preference(key: Text.LayoutKey.self, value: [])
        } else {
            content
                .backgroundPreferenceValue(Text.LayoutKey.self) { layouts in
                    GeometryReader { proxy in
                        ReplySurface(source: .read(layouts.compactMap { anchored in
                            guard let key = anchored.layout.first?.first?[ReplyPieceTag.self]?.key else { return nil }
                            return ReplyTextSurface.Piece(key: key, layout: anchored.layout, origin: proxy[anchored.origin])
                        }))
                    }
                }
                .transformPreference(Text.LayoutKey.self) { $0 = [] }
        }
    }
}

private struct ReplyPiece: ViewModifier {
    let key: ReplyText.Key
    @Environment(\.inReplyChunk) private var inChunk
    @Environment(\.replyPieces) private var pieces

    func body(content: Content) -> some View {
        if givesLayouts(inChunk: inChunk), #available(macOS 15, *), let pieces {
            let space = pieces.space
            content
                .textRenderer(ReplyPieceRenderer(key: key, pieces: pieces))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { pieces.place(key, at: $0) }
                .onDisappear { pieces.remove(key) }
                .allowsHitTesting(false)
        } else {
            content.allowsHitTesting(false)
        }
    }
}

/// Which piece of its reply a text is, carried in the text so its layout can be told apart among
/// those SwiftUI gives.
struct ReplyPieceTag: TextAttribute {
    let key: ReplyText.Key
}

/// Draws a reply's text as SwiftUI would, keeping the layout it draws for the surface behind it.
@available(macOS 15, *)
private struct ReplyPieceRenderer: TextRenderer {
    let key: ReplyText.Key
    let pieces: ReplyPieces

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // SwiftUI draws on the main thread; a layout drawn elsewhere just isn't selectable.
        if Thread.isMainThread { MainActor.assumeIsolated { pieces.lay(key, layout) } }
        for line in layout { context.draw(line) }
    }
}

/// The texts in a chunk, each as it was last drawn and placed: how it was laid out, and where it
/// is in the surface behind it.
@MainActor final class ReplyPieces {
    weak var surface: ReplyTextSurface?
    private(set) var layouts: [ReplyText.Key: Text.Layout] = [:]
    private(set) var frames: [ReplyText.Key: CGRect] = [:]

    /// The surface's coordinate space, under a name of its own: surfaces are within one another.
    nonisolated var space: ObjectIdentifier { ObjectIdentifier(self) }

    var placed: [ReplyTextSurface.Piece] {
        frames.compactMap { key, frame in layouts[key].map { ReplyTextSurface.Piece(key: key, layout: $0, origin: frame.origin) } }
    }

    fileprivate func lay(_ key: ReplyText.Key, _ layout: Text.Layout) {
        layouts[key] = layout
        surface?.changed(key)
    }

    fileprivate func place(_ key: ReplyText.Key, at frame: CGRect) {
        frames[key] = frame
        surface?.changed(key)
    }

    fileprivate func remove(_ key: ReplyText.Key) {
        layouts[key] = nil
        frames[key] = nil
        surface?.changed(key)
    }
}

private struct ReplySurface: NSViewRepresentable {
    let source: ReplyTextSurface.Source

    func makeNSView(context: Context) -> ReplyTextSurface { ReplyTextSurface() }

    func updateNSView(_ surface: ReplyTextSurface, context: Context) {
        surface.controller = context.environment.replySelection
        surface.openURL = context.environment.openURL
        surface.source = source
    }

    static func dismantleNSView(_ surface: ReplyTextSurface, coordinator: ()) {
        surface.controller = nil
    }
}

/// A reply's selection, shared by the surfaces its text is drawn over. One reply in the app has a
/// selection at a time: selecting in another clears it. The text it selects in is the reply as it
/// is shown, made only when a selection needs it, and a selection stays within it as the reply is
/// written.
@MainActor final class ReplySelectionController {
    private static weak var current: ReplySelectionController?
    private let surfaces = NSHashTable<ReplyTextSurface>.weakObjects()
    private var blocks: [MarkdownBlock] = []
    private var pending: String?
    private var stored: ReplySelection?
    /// What the mouse selected where it went down, and by what, for a drag to extend.
    private var initial: ReplySelection?
    private var granularity = ReplyText.Granularity.character
    private var dragged = false
    private var made: ReplyText? {
        didSet {
            guard let made else { return }
            stored = stored.flatMap(made.clamped)
            initial = initial.flatMap(made.clamped)
        }
    }

    var text: ReplyText {
        if let made { return made }
        let text = ReplyText(blocks: blocks, pending: pending)
        made = text
        return text
    }

    var selection: ReplySelection? {
        _ = text
        return stored
    }

    var hasSelection: Bool { !(selection?.isEmpty ?? true) }

    /// Whether anything is selected or being selected, without making the text, as a reply being
    /// written is shown again for each delta.
    var isSelecting: Bool { stored.map { !$0.isEmpty } ?? false || initial != nil }

    /// Selected text is drawn in the accent colour while its window is key and one of its
    /// surfaces takes the keyboard, and in grey otherwise, as text views draw it.
    var isActive: Bool {
        surfaces.allObjects.contains { $0.window?.isKeyWindow == true && $0.window?.firstResponder === $0 }
    }

    /// What the reply shows now. A reply being written is shown again for each delta, mostly
    /// with the same blocks (the very same array) and more text written since.
    func show(_ blocks: [MarkdownBlock], pending: String?) {
        let same = blocks.count == self.blocks.count
            && blocks.withUnsafeBufferPointer { new in self.blocks.withUnsafeBufferPointer { $0.baseAddress == new.baseAddress } }
        guard !same || pending != self.pending else { return }
        self.blocks = blocks
        self.pending = pending
        made = same ? made?.replacingPending(pending) : nil
    }

    func add(_ surface: ReplyTextSurface) { surfaces.add(surface) }
    func remove(_ surface: ReplyTextSurface) { surfaces.remove(surface) }

    func mouseDown(at point: NSPoint, clicks: Int, extending: Bool) {
        claim()
        dragged = false
        guard let hit = hit(at: point) else {
            clear()
            return
        }
        if extending, let selection = stored {
            // From the end of the selection away from the click.
            let anchor = hit.position < selection.start ? selection.end : selection.start
            granularity = .character
            initial = ReplySelection(anchor: anchor, focus: anchor)
            stored = ReplySelection(anchor: anchor, focus: hit.position)
        } else {
            granularity = clicks >= 3 ? .paragraph : clicks == 2 ? .word : .character
            let unit = granularity == .character ? ReplySelection(anchor: hit.position, focus: hit.position)
                : text.unit(granularity, at: hit.character ?? hit.position)
            initial = unit
            stored = unit
        }
        redraw()
    }

    func mouseDragged(to point: NSPoint) {
        guard let initial, let hit = hit(at: point) else { return }
        dragged = true
        stored = text.extending(initial, to: hit.position, by: granularity)
        redraw()
    }

    /// Ends a click or drag: a click on a link, that selected nothing, gives the link to open.
    func mouseUp(at point: NSPoint) -> URL? {
        defer { initial = nil }
        guard initial != nil, !dragged, granularity == .character, !hasSelection,
              let character = hit(at: point)?.character else { return nil }
        return text.link(at: character)
    }

    func copy() {
        guard let selection, !selection.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string(in: selection), forType: .string)
    }

    func selectAll() {
        claim()
        stored = text.whole
        redraw()
    }

    func clear() {
        stored = nil
        initial = nil
        redraw()
    }

    func redraw() {
        for surface in surfaces.allObjects { surface.needsDisplay = true }
    }

    private func claim() {
        guard Self.current !== self else { return }
        Self.current?.clear()
        Self.current = self
    }

    /// What is under a point in the window, among all the reply's surfaces.
    private func hit(at point: NSPoint) -> TextLines.Hit? {
        let text = self.text
        var placed: [TextLines.Placed] = []
        var sources: [(surface: ReplyTextSurface, piece: ReplyTextSurface.Piece)] = []
        for surface in surfaces.allObjects where surface.window != nil {
            for piece in surface.pieces {
                guard let index = text.index(of: piece.key), let bounds = surface.bounds(of: piece) else { continue }
                // In the window's coordinates, y turned to go down, as the pieces' own do.
                let origin = surface.convert(piece.origin, to: nil)
                placed.append(TextLines.Placed(piece: index, bounds: bounds, x: origin.x, y: -origin.y))
                sources.append((surface, piece))
            }
        }
        let order = placed.indices.sorted { placed[$0].piece < placed[$1].piece }
        return TextLines.hit(atX: point.x, y: -point.y, in: order.map { placed[$0] }) { index in
            let source = sources[order[index]]
            return source.surface.lines(of: source.piece, text: text.pieces[placed[order[index]].piece].text)
        }
    }

    /// Where piece `index` draws in the window, for tests.
    func frame(ofPiece index: Int) -> NSRect? {
        let key = text.pieces[index].key
        for surface in surfaces.allObjects {
            guard let piece = surface.pieces.first(where: { $0.key == key }), let bounds = surface.bounds(of: piece) else { continue }
            let local = NSRect(x: piece.origin.x + bounds.minX, y: piece.origin.y + bounds.minY,
                               width: bounds.maxX - bounds.minX, height: bounds.maxY - bounds.minY)
            return surface.convert(local, to: nil)
        }
        return nil
    }

    /// Just inside the left edge of the glyph that starts at `position`, halfway down its line, in
    /// the window, for tests.
    func point(at position: ReplyPosition) -> NSPoint? {
        let piece = text.pieces[position.piece]
        for surface in surfaces.allObjects {
            guard let shown = surface.pieces.first(where: { $0.key == piece.key }) else { continue }
            for line in surface.lines(of: shown, text: piece.text).lines {
                guard let glyph = line.glyphs.first(where: { $0.start == position.offset }) else { continue }
                return surface.convert(NSPoint(x: shown.origin.x + glyph.minX + min(1, (glyph.maxX - glyph.minX) / 4),
                                               y: shown.origin.y + (line.minY + line.maxY) / 2), to: nil)
            }
        }
        return nil
    }
}

/// Where a reply's text is selected, behind the texts SwiftUI draws over it: it takes the mouse
/// where no control does, and shows the selection of the pieces over it. The selection is one shape
/// in a layer of its own, and the surface draws nothing itself: it spans its blocks, thousands of
/// points down a long reply, and drawing would keep a bitmap that size, made again as it grows.
final class ReplyTextSurface: NSView, NSMenuItemValidation {
    struct Piece {
        let key: ReplyText.Key
        let layout: Text.Layout
        /// Where the text's layout starts, in the surface.
        let origin: CGPoint
    }

    weak var controller: ReplySelectionController? {
        didSet {
            guard controller !== oldValue else { return }
            oldValue?.remove(self)
            controller?.add(self)
        }
    }
    var openURL: OpenURLAction?

    /// Where its texts' layouts come from: read from SwiftUI all at once, or given by each text as
    /// it is drawn.
    enum Source {
        case read([Piece])
        case given(ReplyPieces)
    }

    var source: Source = .read([]) {
        didSet {
            switch (oldValue, source) {
            case (.given(let old), .given(let new)) where old === new:
                return
            case (.given(let old), _):
                old.surface = nil
            default:
                break
            }
            if case .given(let pieces) = source { pieces.surface = self }
            laid.removeAll(keepingCapacity: true)
            if controller?.isSelecting == true { needsDisplay = true }
        }
    }

    /// The texts over it that have been laid out and placed.
    var pieces: [Piece] {
        switch source {
        case .read(let pieces): pieces
        case .given(let pieces): pieces.placed
        }
    }

    /// A text over it was drawn again, moved or went.
    func changed(_ key: ReplyText.Key) {
        laid[key] = nil
        if controller?.isSelecting == true { needsDisplay = true }
    }
    /// The pieces' lines and bounds, read from their layouts when first needed.
    private var laid: [ReplyText.Key: (lines: TextLines?, bounds: TextLines.Rect?)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    private let highlight = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.actions = ["path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(highlight)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var acceptsFirstResponder: Bool { controller != nil }
    /// Focused by a click, not by Tab.
    override var canBecomeKeyView: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where piece `piece` draws around its origin, read from its lines alone, not its glyphs.
    func bounds(of piece: Piece) -> TextLines.Rect? {
        if let known = laid[piece.key]?.bounds { return known }
        var rect: TextLines.Rect?
        for line in piece.layout {
            let bounds = line.typographicBounds
            let lineRect = TextLines.Rect(minX: bounds.origin.x, minY: bounds.origin.y - bounds.ascent,
                                          maxX: bounds.origin.x + bounds.width, maxY: bounds.origin.y + bounds.descent + bounds.leading)
            rect = rect.map { TextLines.Rect(minX: min($0.minX, lineRect.minX), minY: min($0.minY, lineRect.minY),
                                             maxX: max($0.maxX, lineRect.maxX), maxY: max($0.maxY, lineRect.maxY)) } ?? lineRect
        }
        laid[piece.key, default: (nil, nil)].bounds = rect
        return rect
    }

    func lines(of piece: Piece, text: String) -> TextLines {
        if let known = laid[piece.key]?.lines { return known }
        let lines = TextLines(lines: piece.layout.map { line in
            let bounds = line.typographicBounds
            return TextLines.Laid(minY: bounds.origin.y - bounds.ascent, maxY: bounds.origin.y + bounds.descent + bounds.leading,
                                  glyphs: line.flatMap { run in
                                      run.compactMap { slice in
                                          slice.characterIndices.first.map { index in
                                              let glyph = slice.typographicBounds
                                              return (glyph.origin.x, glyph.origin.x + glyph.width, Self.offset(index))
                                          }
                                      }
                                  })
        }, text: text)
        laid[piece.key, default: (nil, nil)].lines = lines
        return lines
    }

    /// A layout's character index as a number: UTF-16 offsets from the start of its paragraph.
    /// SwiftUI keeps the number to itself, in a frozen struct holding only it, so its layout is an
    /// `Int`'s.
    private static func offset(_ index: Text.Layout.CharacterIndex) -> Int {
        unsafeBitCast(index, to: Int.self)
    }

    /// The selection's shape, in the surface's layer, nil when none of it is here.
    var selectionShape: CGPath? { highlight.path }

    override func updateLayer() {
        let path = CGMutablePath()
        if let controller, controller.isSelecting, let selection = controller.selection, !selection.isEmpty {
            let text = controller.text
            for piece in pieces {
                guard let index = text.index(of: piece.key), let range = text.range(of: index, in: selection) else { continue }
                for rect in lines(of: piece, text: text.pieces[index].text).rects(for: range) {
                    path.addRect(convertToLayer(NSRect(x: piece.origin.x + rect.minX, y: piece.origin.y + rect.minY,
                                                       width: rect.maxX - rect.minX, height: rect.maxY - rect.minY)))
                }
            }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                highlight.fillColor = (controller.isActive ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).cgColor
            }
        }
        highlight.frame = layer?.bounds ?? .zero
        highlight.path = path.isEmpty ? nil : path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
        super.mouseMoved(with: event)
    }

    /// An I-beam over the reply's text, and a pointing hand over a link in it.
    func cursor(at point: CGPoint) -> NSCursor {
        guard let controller else { return .arrow }
        for piece in pieces {
            guard let bounds = bounds(of: piece), bounds.minX <= point.x - piece.origin.x, point.x - piece.origin.x < bounds.maxX,
                  bounds.minY <= point.y - piece.origin.y, point.y - piece.origin.y < bounds.maxY else { continue }
            let text = controller.text
            guard let index = text.index(of: piece.key), !text.pieces[index].links.isEmpty else { return .iBeam }
            let lines = lines(of: piece, text: text.pieces[index].text)
            let x = point.x - piece.origin.x, y = point.y - piece.origin.y
            if let line = lines.lines.firstIndex(where: { $0.minY <= y && y < $0.maxY }), let glyph = lines.glyph(atX: x, line: line),
               text.link(at: ReplyPosition(piece: index, offset: glyph.start)) != nil {
                return .pointingHand
            }
            return .iBeam
        }
        return .arrow
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller else { return super.mouseDown(with: event) }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        controller.mouseDown(at: event.locationInWindow, clicks: event.clickCount, extending: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else { return super.mouseDragged(with: event) }
        controller.mouseDragged(to: event.locationInWindow)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return super.mouseUp(with: event) }
        if let url = controller.mouseUp(at: event.locationInWindow) { openURL?(url) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard controller != nil else { return super.menu(for: event) }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    @objc func copy(_ sender: Any?) { controller?.copy() }

    override func selectAll(_ sender: Any?) { controller?.selectAll() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): controller?.hasSelection ?? false
        case #selector(selectAll(_:)): controller != nil
        default: true
        }
    }

    override func becomeFirstResponder() -> Bool {
        controller?.redraw()
        return true
    }

    override func resignFirstResponder() -> Bool {
        controller?.redraw()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.controller?.isSelecting == true { self?.needsDisplay = true }
                }
            })
        }
    }
}
