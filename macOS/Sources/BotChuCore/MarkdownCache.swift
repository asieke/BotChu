import Foundation

/// How a reply is drawn: as native Markdown blocks, or, with math or a Mermaid diagram, as an HTML
/// document for the bundled renderers (`RichMarkdown`).
public enum MarkdownRendering: Sendable {
    case blocks([MarkdownBlock])
    case rich(html: String)

    public init(_ source: String) {
        if let html = RichMarkdown.html(source) {
            self = .rich(html: html)
        } else {
            self = .blocks(MarkdownBlock.split(source))
        }
    }
}

/// Replies' parsed Markdown, by their text, so drawing a conversation again (after another bot's,
/// say) doesn't parse every reply in it again on the main thread. It keeps the replies used most
/// recently. A reply being written replaces its previous, shorter version, so a stream doesn't
/// fill it. Thread-safe: conversations are parsed ahead of time in the background (`warm`).
public final class MarkdownCache: @unchecked Sendable {
    public static let shared = MarkdownCache()

    private struct Entry {
        var rendering: MarkdownRendering
        var used: UInt64
    }

    public let capacity: Int
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    /// The text drawn last that wasn't cached, which a growing reply's next version starts with.
    private var newest: String?

    public init(capacity: Int = 3_000) {
        self.capacity = max(4, capacity)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// The reply's parsed Markdown, parsed now (on the caller's thread) when it isn't cached.
    public func rendering(for source: String) -> MarkdownRendering {
        if let hit = cached(source) { return hit }
        let made = MarkdownRendering(source)
        store(made, for: source, replacingPrefix: true)
        return made
    }

    /// The reply's parsed Markdown, when it is cached.
    public func cached(_ source: String) -> MarkdownRendering? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[source] else { return nil }
        clock += 1
        entry.used = clock
        entries[source] = entry
        return entry.rendering
    }

    /// Parses the replies that aren't cached yet, so they're ready when their conversation is
    /// shown. Meant for a background queue.
    public func warm(_ sources: [String]) {
        for source in sources where cached(source) == nil {
            store(MarkdownRendering(source), for: source, replacingPrefix: false)
        }
    }

    private func store(_ rendering: MarkdownRendering, for source: String, replacingPrefix: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if replacingPrefix {
            if let newest, newest != source, source.hasPrefix(newest) { entries[newest] = nil }
            newest = source
        }
        clock += 1
        entries[source] = Entry(rendering: rendering, used: clock)
        guard entries.count > capacity else { return }
        // Keep the three quarters used most recently; sorting only every so often keeps it cheap.
        let kept = entries.sorted { $0.value.used > $1.value.used }.prefix(capacity * 3 / 4)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
