import Foundation

/// Parses replies' Markdown off the main thread, a few at a time across every conversation (#106).
/// Each client, a view showing one reply, has at most one parse under way and one revision
/// waiting: a newer revision replaces the one waiting before any work is done on it, so a reply
/// streamed in many small deltas is parsed only as often as the worker keeps up, and its last
/// revision always is. A parse under way finishes; its result still goes to its client, which
/// shows it only if nothing newer is shown (`MarkdownPreparation`). Results go into the cache,
/// each in place of its reply's previous, shorter version, whose unchanged blocks it reuses.
public final class MarkdownWorker: @unchecked Sendable {
    public static let shared = MarkdownWorker()

    public struct Statistics: Equatable, Sendable {
        /// Revisions asked for.
        public var requested = 0
        /// Revisions found parsed already, so not parsed again.
        public var hits = 0
        /// Parses started and finished.
        public var started = 0
        public var completed = 0
        /// Revisions a newer one replaced before they started.
        public var superseded = 0
        /// Revisions dropped before they started as their client went.
        public var cancelled = 0
        /// The most parses under way at once.
        public var peak = 0
    }

    /// How many replies are parsed at once, across every conversation.
    public let limit: Int
    private let cache: MarkdownCache
    private let parse: @Sendable (String) -> MarkdownRendering
    private let queue = DispatchQueue(label: "local.BotChu.markdown", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var clients: [UUID: Client] = [:]
    /// Clients with a revision waiting and none under way, in the order they asked.
    private var waiting: [UUID] = []
    private var running = 0
    private var held = 0
    private var counts = Statistics()

    private struct Request {
        let source: String
        let deliver: @Sendable (MarkdownRendering) -> Void
    }

    private struct Client {
        var pending: Request?
        var busy = false
    }

    public init(cache: MarkdownCache = .shared, limit: Int = 2,
                parse: @escaping @Sendable (String) -> MarkdownRendering = { MarkdownRendering($0) }) {
        self.cache = cache
        self.limit = max(1, limit)
        self.parse = parse
    }

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    /// The bytes of text waiting or being parsed: at most one revision of each client waiting and
    /// `limit` under way.
    public var heldBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// Parses `source` for `client` and gives the result to `deliver`, on the worker's thread. A
    /// revision of the same client still waiting is dropped.
    public func prepare(_ source: String, for client: UUID, deliver: @escaping @Sendable (MarkdownRendering) -> Void) {
        lock.lock()
        counts.requested += 1
        var state = clients[client] ?? Client()
        if let dropped = state.pending {
            counts.superseded += 1
            held -= dropped.source.utf8.count
        } else if !state.busy {
            waiting.append(client)
        }
        state.pending = Request(source: source, deliver: deliver)
        held += source.utf8.count
        clients[client] = state
        let jobs = next()
        lock.unlock()
        jobs.forEach(start)
    }

    /// Forgets a client whose view has gone, with the revision it had waiting.
    public func cancel(_ client: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = clients.removeValue(forKey: client) else { return }
        if let dropped = state.pending {
            counts.cancelled += 1
            held -= dropped.source.utf8.count
        }
        waiting.removeAll { $0 == client }
    }

    private struct Job {
        let client: UUID
        let request: Request
    }

    /// The waiting revisions that can start now. Called with the lock held.
    private func next() -> [Job] {
        var jobs: [Job] = []
        while running < limit, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard var state = clients[id], let request = state.pending else { continue }
            state.pending = nil
            state.busy = true
            clients[id] = state
            running += 1
            counts.peak = max(counts.peak, running)
            jobs.append(Job(client: id, request: request))
        }
        return jobs
    }

    private func start(_ job: Job) {
        queue.async { [self] in
            let source = job.request.source
            let rendering: MarkdownRendering
            if let hit = cache.cached(source) {
                rendering = hit
                count { $0.hits += 1 }
            } else {
                count { $0.started += 1 }
                let parsed = parse(source)
                rendering = cache.earlierVersion(of: source).map { parsed.reusing($0.rendering) } ?? parsed
                cache.store(rendering, for: source)
                count { $0.completed += 1 }
            }
            job.request.deliver(rendering)
            lock.lock()
            running -= 1
            held -= source.utf8.count
            if var state = clients[job.client] {
                state.busy = false
                if state.pending != nil { waiting.append(job.client) }
                clients[job.client] = state
            }
            let jobs = next()
            lock.unlock()
            jobs.forEach(start)
        }
    }

    private func count(_ change: (inout Statistics) -> Void) {
        lock.lock()
        change(&counts)
        lock.unlock()
    }
}

/// One reply as a view shows it while it is written: what to show for its text now, without
/// parsing it on the main thread, and the revisions to have `MarkdownWorker` prepare. It shows the
/// newest rendering it has whose text the reply still starts with; a revision never replaces a
/// newer one, so a slow parse of an old revision can't show after a newer one, nor a rendering of
/// other text after the view is given it. A short reply shown for the first time unparsed is
/// parsed in place, as that takes under about 4 ms and saves it flashing as plain text.
@MainActor public final class MarkdownPreparation {
    /// What to show: a rendering, and text it doesn't cover yet, shown as it is.
    public struct Display: Equatable {
        public var rendering: MarkdownRendering?
        public var pending: String?
    }

    /// The longest reply parsed in place when shown for the first time unparsed.
    public static let inlineLimit = 4_096
    /// From this length, a reply's parse takes long enough (about 1 ms a KB) that the text
    /// written since its last rendering shows as it is meanwhile.
    public static let tailLimit = 16_384

    public let id = UUID()
    private let worker: MarkdownWorker
    private let cache: MarkdownCache
    /// The rendering shown, and the text it is of.
    public private(set) var source: String?
    public private(set) var rendering: MarkdownRendering?
    private var requested: String?
    private var revision = 0
    private var shownRevision = 0
    /// Renderings the worker gave this view that it showed.
    public private(set) var published = 0
    /// Called when the worker's rendering is shown, to draw the view again.
    public var onPublish: (() -> Void)?

    public init(worker: MarkdownWorker = .shared, cache: MarkdownCache = .shared) {
        self.worker = worker
        self.cache = cache
    }

    deinit {
        worker.cancel(id)
    }

    /// What to show for `text` now.
    public func display(for text: String) -> Display {
        if let rendering, let source {
            if source == text { return Display(rendering: rendering) }
            if text.extends(source) {
                guard text.utf8.count >= Self.tailLimit else { return Display(rendering: rendering) }
                let tail = String(decoding: text.utf8.dropFirst(source.utf8.count), as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                return Display(rendering: rendering, pending: tail.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tail)
            }
        }
        if let hit = cache.cached(text) { return adopt(hit, of: text) }
        if text.utf8.count <= Self.inlineLimit { return adopt(cache.rendering(for: text), of: text) }
        // A reply being written, shown again: from its last rendering.
        if let earlier = cache.earlierVersion(of: text) {
            _ = adopt(earlier.rendering, of: earlier.source)
            return display(for: text)
        }
        return Display(pending: text)
    }

    /// Has the worker prepare `text`, unless it is shown or asked for already.
    public func update(_ text: String) {
        guard source != text, requested != text else { return }
        requested = text
        revision += 1
        let revision = revision
        worker.prepare(text, for: id) { [weak self] rendering in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publish(rendering, of: text, revision: revision) }
            }
        }
    }

    /// Shows a rendering found or made in place, which is newer than any the worker is preparing.
    private func adopt(_ found: MarkdownRendering, of text: String) -> Display {
        revision += 1
        shownRevision = revision
        requested = nil
        source = text
        rendering = found
        return Display(rendering: found)
    }

    private func publish(_ prepared: MarkdownRendering, of text: String, revision: Int) {
        guard revision > shownRevision else { return }
        shownRevision = revision
        source = text
        rendering = prepared
        published += 1
        onPublish?()
    }
}
