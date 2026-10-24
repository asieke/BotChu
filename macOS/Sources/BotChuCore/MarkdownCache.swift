import Foundation

/// How a reply is drawn: as native Markdown blocks, or, with math or a Mermaid diagram, as an HTML
/// document for the bundled renderers (`RichMarkdown`).
public enum MarkdownRendering: Equatable, Sendable {
    case blocks([MarkdownBlock])
    case rich(html: String)

    public init(_ source: String) {
        self = RichMarkdown.rendering(source)
    }

    /// The same rendering, with the blocks it shares with `earlier`, the reply's previous version,
    /// taken from that: a reply being written changes only its last blocks, and SwiftUI lays out
    /// again only the blocks that aren't the very ones it drew (for a 1,500-block reply, about 15 ms
    /// rather than 170).
    public func reusing(_ earlier: MarkdownRendering) -> MarkdownRendering {
        guard case .blocks(let blocks) = self, case .blocks(let old) = earlier else { return self }
        return .blocks(MarkdownBlock.reusing(old, in: blocks))
    }

    /// Roughly the memory it takes, from measurements of 128 KB replies (macOS 27): parsed blocks
    /// keep about 50 bytes per byte of prose (code takes about 30), and HTML a little over twice
    /// its own length.
    public func estimatedBytes(source: Int) -> Int {
        switch self {
        case .blocks: 48 * source
        case .rich(let html): 2 * html.utf8.count
        }
    }
}

/// Replies' parsed Markdown, by their text, so drawing a conversation again (after another bot's,
/// say) doesn't parse every reply in it again. It keeps the replies used most recently within
/// `budget` bytes, counting their text and their parsed form (`estimatedBytes`), and lets go of
/// all of them under memory pressure; the replies' text stays in their conversations. A reply being
/// written replaces its previous, shorter version, so a stream doesn't fill it, also with several
/// written at once. Thread-safe:
/// conversations are parsed ahead of time in the background (`warm`), and replies being written
/// on `MarkdownWorker`.
public final class MarkdownCache: @unchecked Sendable {
    public static let shared: MarkdownCache = {
        let cache = MarkdownCache()
        cache.releasesUnderMemoryPressure()
        return cache
    }()

    /// 64 MB: about 900 replies of 1.5 KB, or ten of 128 KB.
    public static let defaultBudget = 64 << 20

    private struct Entry {
        var rendering: MarkdownRendering
        var bytes: Int
        var used: UInt64
    }

    public let budget: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var total = 0
    private var clock: UInt64 = 0
    /// The replies parsed most recently as they were drawn or written, newest first: a longer
    /// version of one replaces it, and a reply shown again while it's written starts from it.
    private var growing: [String] = []
    static let growingLimit = 16
    private var pressure: DispatchSourceMemoryPressure?

    public init(budget: Int = MarkdownCache.defaultBudget) {
        self.budget = max(1, budget)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// What the cached replies take, their text and parsed form, in estimated bytes.
    public var bytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }

    /// The reply's parsed Markdown, parsed now (on the caller's thread) when it isn't cached.
    public func rendering(for source: String) -> MarkdownRendering {
        if let hit = cached(source) { return hit }
        let made = MarkdownRendering(source)
        store(made, for: source)
        return made
    }

    /// The reply's parsed Markdown, when it is cached.
    public func cached(_ source: String) -> MarkdownRendering? {
        lock.lock()
        defer { lock.unlock() }
        return touch(source)
    }

    /// The newest earlier version of a reply being written, and its parsed Markdown, when one is
    /// cached.
    public func earlierVersion(of source: String) -> (source: String, rendering: MarkdownRendering)? {
        lock.lock()
        defer { lock.unlock() }
        guard let earlier = growing.first(where: { $0 != source && source.extends($0) }),
              let rendering = touch(earlier) else { return nil }
        return (earlier, rendering)
    }

    /// Parses the replies that aren't cached yet, so they're ready when their conversation is
    /// shown. Meant for a background queue.
    public func warm(_ sources: [String]) {
        for source in sources where cached(source) == nil {
            let made = MarkdownRendering(source)
            lock.lock()
            insert(made, for: source)
            lock.unlock()
        }
    }

    /// Keeps a reply parsed as it is drawn or written, in place of its previous, shorter version.
    public func store(_ rendering: MarkdownRendering, for source: String) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = growing.first(where: { $0 != source && source.extends($0) }) { remove(previous) }
        growing.removeAll { $0 == source }
        growing.insert(source, at: 0)
        if growing.count > Self.growingLimit { growing.removeLast() }
        insert(rendering, for: source)
    }

    /// Lets go of every parsed reply, as memory pressure does.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        total = 0
        growing.removeAll()
    }

    /// Empties the cache whenever macOS reports memory pressure.
    public func releasesUnderMemoryPressure() {
        lock.lock()
        defer { lock.unlock() }
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.removeAll() }
        source.activate()
        pressure = source
    }

    private func touch(_ source: String) -> MarkdownRendering? {
        guard var entry = entries[source] else { return nil }
        clock += 1
        entry.used = clock
        entries[source] = entry
        return entry.rendering
    }

    private func remove(_ source: String) {
        guard let entry = entries.removeValue(forKey: source) else { return }
        total -= entry.bytes
        growing.removeAll { $0 == source }
    }

    private func insert(_ rendering: MarkdownRendering, for source: String) {
        let size = source.utf8.count
        let bytes = size + rendering.estimatedBytes(source: size)
        if let old = entries.removeValue(forKey: source) { total -= old.bytes }
        clock += 1
        entries[source] = Entry(rendering: rendering, bytes: bytes, used: clock)
        total += bytes
        guard total > budget else { return }
        // Keep the most recent within three quarters of the budget; sorting only every so often
        // keeps it cheap. The reply just kept stays, even alone over the budget, as it's in use.
        var kept = 0
        var full = false
        for (key, entry) in entries.sorted(by: { $0.value.used > $1.value.used }) {
            full = full || (key != source && kept + entry.bytes > budget * 3 / 4)
            if full { remove(key) } else { kept += entry.bytes }
        }
    }
}

extension String {
    /// It starts with all of `prefix`, compared byte for byte (`hasPrefix` compares characters,
    /// which is slower for a long reply).
    public func extends(_ prefix: String) -> Bool {
        let length = prefix.utf8.count
        guard length > 0 else { return true }
        guard utf8.count >= length else { return false }
        var text = self, prefix = prefix
        return text.withUTF8 { bytes in prefix.withUTF8 { start in memcmp(bytes.baseAddress!, start.baseAddress!, length) == 0 } }
    }
}
