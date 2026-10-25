import Foundation
import Testing
@testable import BotChuCore

/// A parse that waits until the test lets it go, and records what it was given.
final class ParseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var given: [String] = []

    func parse(_ source: String) -> MarkdownRendering {
        lock.lock()
        given.append(source)
        lock.unlock()
        semaphore.wait()
        return MarkdownRendering(source)
    }

    func release(_ count: Int = 1) {
        for _ in 0..<count { semaphore.signal() }
    }

    var sources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return given
    }
}

/// What a worker delivered, in order.
final class Deliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(source: String, rendering: MarkdownRendering)] = []

    func add(_ source: String, _ rendering: MarkdownRendering) {
        lock.lock()
        items.append((source, rendering))
        lock.unlock()
    }

    var all: [(source: String, rendering: MarkdownRendering)] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Waits up to five seconds for `condition`.
func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
}

/// A reply parsed off the main actor, which other suites' timing tests share.
func parsed(_ source: String) async -> MarkdownRendering {
    await Task.detached { MarkdownRendering(source) }.value
}

/// Prose of about `bytes` bytes: bold, inline code and a link in each paragraph.
func prose(_ bytes: Int) -> String {
    let paragraph = "A **measured** answer has `code`, a [link](https://example.test), and explanation.\n\n"
    return String(repeating: paragraph, count: max(1, bytes / paragraph.utf8.count))
}

@Suite struct MarkdownWorkerTests {
    /// #106: a 128 KB reply given 100 deltas while its first parse runs is parsed twice: the
    /// deltas between replace one another before any work is done on them, and the last settles.
    @Test func rapidDeltasAreCoalescedAndTheLastSettles() async throws {
        let gate = ParseGate()
        let worker = MarkdownWorker(cache: MarkdownCache(), limit: 2, parse: { gate.parse($0) })
        let deliveries = Deliveries()
        let client = UUID()
        var text = prose(131_072)
        let first = text + " delta 0"
        for index in 0..<100 {
            text += " delta \(index)"
            let source = text
            worker.prepare(source, for: client) { deliveries.add(source, $0) }
        }
        try await eventually { gate.sources.count == 1 }
        // At most one parse under way and one revision waiting.
        #expect(worker.statistics.superseded == 98)
        #expect(worker.heldBytes == first.utf8.count + text.utf8.count)
        gate.release()
        try await eventually { gate.sources.count == 2 }
        gate.release()
        try await eventually { deliveries.all.count == 2 }
        let stats = worker.statistics
        #expect(stats.requested == 100 && stats.started == 2 && stats.completed == 2)
        #expect(stats.superseded == 98 && stats.peak == 1)
        #expect(deliveries.all.map(\.source) == [first, text])
        #expect(deliveries.all.last?.rendering == MarkdownRendering(text))
        try await eventually { worker.heldBytes == 0 }
        #expect(worker.heldBytes == 0)
    }

    /// Replies of several conversations share the worker's limit, each with one parse at a time.
    @Test func clientsShareTheLimitWithOneParseEach() async throws {
        let gate = ParseGate()
        let worker = MarkdownWorker(cache: MarkdownCache(), limit: 2, parse: { gate.parse($0) })
        let deliveries = Deliveries()
        let clients = (0..<6).map { _ in UUID() }
        for (index, client) in clients.enumerated() {
            worker.prepare("Reply \(index)", for: client) { deliveries.add("Reply \(index)", $0) }
        }
        // The first client's next revision waits for its first, behind the others.
        worker.prepare("Reply 0, longer", for: clients[0]) { deliveries.add("Reply 0, longer", $0) }
        try await eventually { gate.sources.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(Set(gate.sources) == ["Reply 0", "Reply 1"])
        // One parse at a time, so the order parses start in is the worker's, not the dispatch queue's.
        for started in 3...7 {
            gate.release()
            try await eventually { gate.sources.count == started }
        }
        gate.release(2)
        try await eventually { deliveries.all.count == 7 }
        #expect(worker.statistics.peak == 2)
        #expect(gate.sources.last == "Reply 0, longer")
        #expect(Set(gate.sources) == Set((0..<6).map { "Reply \($0)" } + ["Reply 0, longer"]))
    }

    /// A view that goes takes its waiting revision with it; the parse under way still finishes.
    @Test func cancellingDropsTheWaitingRevision() async throws {
        let gate = ParseGate()
        let worker = MarkdownWorker(cache: MarkdownCache(), limit: 1, parse: { gate.parse($0) })
        let deliveries = Deliveries()
        let client = UUID()
        worker.prepare("First", for: client) { deliveries.add("First", $0) }
        worker.prepare("First and more", for: client) { deliveries.add("First and more", $0) }
        try await eventually { gate.sources.count == 1 }
        worker.cancel(client)
        gate.release(2)
        try await eventually { deliveries.all.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(deliveries.all.map(\.source) == ["First"])
        #expect(worker.statistics.cancelled == 1 && worker.statistics.started == 1)
        #expect(worker.heldBytes == 0)
    }

    @Test func aParsedReplyIsDeliveredWithoutParsingAgain() async throws {
        let cache = MarkdownCache()
        _ = cache.rendering(for: "Already **parsed**.")
        let worker = MarkdownWorker(cache: cache, limit: 2) { _ in
            Issue.record("A cached reply is parsed again")
            return .blocks([])
        }
        let deliveries = Deliveries()
        worker.prepare("Already **parsed**.", for: UUID()) { deliveries.add("", $0) }
        try await eventually { deliveries.all.count == 1 }
        #expect(worker.statistics.hits == 1 && worker.statistics.started == 0)
        #expect(deliveries.all.first?.rendering == MarkdownRendering("Already **parsed**."))
    }
}

@MainActor @Suite struct MarkdownPreparationTests {
    /// A short reply shown for the first time is parsed in place; a longer revision of it shows
    /// the last rendering until the worker's is ready, never parsing on the caller's thread.
    @Test func revisionsAreParsedByTheWorkerWhileTheLastRenderingShows() async throws {
        let cache = MarkdownCache()
        let preparation = MarkdownPreparation(worker: MarkdownWorker(cache: cache), cache: cache)
        let short = "## Plan\n\nFirst **step**."
        var first = MarkdownPreparation.Display()
        #expect(MarkdownParses.counting { first = preparation.display(for: short) } == 1)
        #expect(first.rendering == MarkdownRendering(short))
        let long = short + "\n\n" + prose(8_000)
        let full = await parsed(long)
        var shown = MarkdownPreparation.Display()
        #expect(MarkdownParses.counting {
            shown = preparation.display(for: long)
            preparation.update(long)
        } == 0)
        #expect(shown == MarkdownPreparation.Display(rendering: MarkdownRendering(short)))
        try await eventually { preparation.published == 1 }
        #expect(preparation.display(for: long) == MarkdownPreparation.Display(rendering: full))
    }

    /// Once a reply is long, the text written since its last rendering shows as it is.
    @Test func aLongReplyShowsTheTextWrittenSinceItsLastRendering() async throws {
        let gate = ParseGate()
        let cache = MarkdownCache()
        let preparation = MarkdownPreparation(worker: MarkdownWorker(cache: cache, parse: { gate.parse($0) }), cache: cache)
        let start = prose(MarkdownPreparation.tailLimit + 100)
        preparation.update(start)
        #expect(preparation.display(for: start) == MarkdownPreparation.Display(pending: start))
        gate.release()
        try await eventually { preparation.published == 1 }
        let longer = start + "\n\nThe **next** paragraph"
        let shown = await parsed(start)
        #expect(preparation.display(for: longer) == MarkdownPreparation.Display(rendering: shown, pending: "The **next** paragraph"))
    }

    /// A slow parse of an earlier revision never replaces what is shown since: neither a newer
    /// revision nor other text the view was given (an edited history, another conversation).
    @Test func aSlowEarlierRevisionNeverReplacesANewerOne() async throws {
        let gate = ParseGate()
        let cache = MarkdownCache()
        let preparation = MarkdownPreparation(worker: MarkdownWorker(cache: cache, parse: { gate.parse($0) }), cache: cache)
        let streamed = prose(6_000)
        preparation.update(streamed)
        try await eventually { gate.sources.count == 1 }
        // Other text is shown meanwhile, parsed already.
        let other = "A different reply, **parsed** already."
        _ = cache.rendering(for: other)
        #expect(preparation.display(for: other).rendering == MarkdownRendering(other))
        preparation.update(other)
        gate.release()
        try await eventually { cache.cached(streamed) != nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(preparation.published == 0)
        #expect(preparation.display(for: other).rendering == MarkdownRendering(other))
        // And the streamed reply's rendering never shows for text that doesn't continue it.
        let edited = "Edited: " + streamed
        let streamedRendering = await parsed(streamed)
        #expect(preparation.display(for: edited).rendering != streamedRendering)
    }

    /// #106: the final text and formatting match a full parse, through incomplete fences, escaped
    /// dollars, inline and display math, tables, links and a diagram.
    @Test func theFinalRevisionMatchesAFullParse() async throws {
        let final = #"""
        Costs are \$5 and $10; the variable is `$HOME`.

        ```sh
        echo "$HOME/$PATH"
        ```

        Inline $x_1^2$ and display:

        $$\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$$

        | Item | Value |
        | --- | ---: |
        | $p_1$ | [link](https://example.test) |

        ```mermaid
        flowchart LR
          A[Start] --> B[Done]
        ```
        """# + "\n\n" + prose(20_000)
        let cache = MarkdownCache()
        let preparation = MarkdownPreparation(worker: MarkdownWorker(cache: cache), cache: cache)
        let full = await parsed(final)
        var text = ""
        var parsedHere = 0
        var start = final.startIndex
        while start < final.endIndex {
            let end = final.index(start, offsetBy: 97, limitedBy: final.endIndex) ?? final.endIndex
            text += final[start..<end]
            start = end
            parsedHere += MarkdownParses.counting {
                _ = preparation.display(for: text)
                preparation.update(text)
            }
            await Task.yield()
        }
        try await eventually { preparation.display(for: final).rendering == full }
        #expect(preparation.display(for: final) == MarkdownPreparation.Display(rendering: full))
        guard case .rich(let html) = full else {
            Issue.record("The reply has math and a diagram")
            return
        }
        #expect(html.contains(#"data-tex="x_1^2""#) && html.contains("class=\"diagram-block\"") && html.contains("<table>"))
        #expect(html.contains("$HOME/$PATH") && html.contains("<code>$HOME</code>") && html.contains("$5"))
        // Only its first, short revision was parsed in place.
        #expect(parsedHere == 1)
    }

    /// A reply being written that is shown again starts from its last rendering, not plain text.
    @Test func aReplyShownAgainWhileWrittenStartsFromItsLastRendering() async throws {
        let cache = MarkdownCache()
        let earlier = prose(MarkdownPreparation.tailLimit + 50)
        let rendering = await parsed(earlier)
        cache.store(rendering, for: earlier)
        let preparation = MarkdownPreparation(worker: MarkdownWorker(cache: cache), cache: cache)
        let now = earlier + "\n\nMore"
        #expect(preparation.display(for: now) == MarkdownPreparation.Display(rendering: rendering, pending: "More"))
    }
}

@Suite struct MarkdownReuseTests {
    /// The two values hold the very same storage, not only equal text.
    private func same(_ a: MarkdownBlock, _ b: MarkdownBlock) -> Bool {
        withUnsafeBytes(of: a.text) { left in withUnsafeBytes(of: b.text) { right in left.elementsEqual(right) } }
            && a.children.count == b.children.count && zip(a.children, b.children).allSatisfy { same($0, $1) }
    }

    /// A new revision keeps its previous version's blocks where they didn't change, also the
    /// finished items of a list that gained one, and is still equal to its own full parse.
    @Test func aRevisionReusesTheBlocksItDidntChange() throws {
        let earlierText = "## Plan\n\nFirst **step**.\n\n- one\n- two\n\nLast"
        let laterText = earlierText + " words\n\n- three"
        let earlier = MarkdownRendering(earlierText), parsed = MarkdownRendering(laterText)
        let reused = parsed.reusing(earlier)
        #expect(reused == parsed)
        guard case .blocks(let old) = earlier, case .blocks(let new) = reused, case .blocks(let fresh) = parsed else {
            Issue.record("Plain replies are native blocks")
            return
        }
        #expect(same(new[0], old[0]) && same(new[1], old[1]) && same(new[2], old[2]))
        #expect(!same(fresh[0], old[0]))
        #expect(new[3] != old[3])
        // A list that gains an item keeps the items it had.
        let list = MarkdownRendering("Steps:\n\n- one\n- two")
        guard case .blocks(let before) = list, case .blocks(let after) = MarkdownRendering("Steps:\n\n- one\n- two\n- three").reusing(list) else { return }
        #expect(after[1] != before[1] && after[1].children.count == 3)
        #expect(same(after[1].children[0], before[1].children[0]) && same(after[1].children[1], before[1].children[1]))
        // A rich reply, or one that was rich, is left as it is.
        let rich = MarkdownRendering("Now $x^2$")
        #expect(rich.reusing(earlier) == rich && parsed.reusing(rich) == parsed)
    }
}

@Suite struct MarkdownBudgetTests {
    /// #106: ten distinct 128 KB replies, each streamed in revisions, keep only their last
    /// version, within the app's budget; more evict the oldest, and memory pressure lets go of all.
    @Test func streamedRepliesStayWithinTheBudget() async throws {
        let cache = MarkdownCache()
        let worker = MarkdownWorker(cache: cache, limit: 2) { _ in .blocks([]) }
        var replies: [String] = []
        func stream(_ reply: Int) async throws {
            let deliveries = Deliveries()
            let client = UUID()
            let full = "Reply \(reply)\n\n" + prose(131_072)
            for end in stride(from: 16_384, through: full.utf8.count, by: 16_384) + [full.utf8.count] {
                let source = String(decoding: full.utf8.prefix(end), as: UTF8.self)
                worker.prepare(source, for: client) { deliveries.add(source, $0) }
            }
            try await eventually { deliveries.all.last?.source == full }
            replies.append(full)
        }
        for reply in 0..<10 { try await stream(reply) }
        let each = replies[0].utf8.count * 49
        #expect(cache.count == 10)
        #expect(cache.bytes == 10 * each)
        #expect(cache.bytes <= MarkdownCache.defaultBudget)
        #expect(replies.allSatisfy { cache.cached($0) != nil })
        try await stream(10)
        #expect(cache.bytes <= MarkdownCache.defaultBudget)
        #expect(cache.cached(replies[10]) != nil && cache.cached(replies[0]) == nil)
        cache.removeAll()
        #expect(cache.bytes == 0 && cache.count == 0)
    }

    @Test func aRichReplyCountsItsHTML() {
        let cache = MarkdownCache()
        let source = "Euler: $e^{i\\pi} + 1 = 0$"
        guard case .rich(let html) = cache.rendering(for: source) else {
            Issue.record("A reply with math is drawn in WebKit")
            return
        }
        #expect(cache.bytes == source.utf8.count + 2 * html.utf8.count)
    }
}

@Suite struct MarkdownParsingTests {
    /// #106: ordinary shell fences with `$HOME`, currency, the word Mermaid without a diagram and
    /// an incomplete streaming fence are parsed once, as native blocks.
    @Test func repliesWithoutMathAreParsedOnce() {
        let sources = [
            "Run this:\n\n```sh\nexport PATH=\"$HOME/bin:$PATH\"\necho $HOME\n```\n\nThen restart.",
            "It costs $5, or $10 with tax.",
            "Mermaid can draw this, but here is a plain list:\n\n- one\n- two",
            "Streaming:\n\n```bash\nfor f in $FILES; do\n  echo \"$f\"\n",
        ]
        for source in sources {
            var rendering: MarkdownRendering?
            #expect(MarkdownParses.counting { rendering = MarkdownRendering(source) } == 1)
            #expect(rendering == .blocks(MarkdownBlock.split(source)))
        }
    }

    /// Hundreds of expressions are each put back once, in order, wherever they are.
    @Test func manyExpressionsArePutBackInOrder() throws {
        let rows = (0..<300).map { "| $x_{\($0)}$ | **$y_{\($0)}$** |" }.joined(separator: "\n")
        let source = "Values $a_0$ to $a_{299}$:\n\n| X | Y |\n| --- | --- |\n" + rows + "\n\n" + (0..<300).map { "Step $z_{\($0)}$ done." }.joined(separator: "\n\n")
        let html = try #require(RichMarkdown.html(source))
        #expect(!html.contains("BCHUMATH"))
        var cursor = html.startIndex
        for index in 0..<300 {
            let range = try #require(html.range(of: "data-tex=\"z_{\(index)}\"", range: cursor..<html.endIndex))
            cursor = range.upperBound
        }
        #expect(html.components(separatedBy: "class=\"tex\"").count - 1 == 2 + 600 + 300)
        #expect(html.contains("<strong><span class=\"tex\" data-display=\"false\" data-tex=\"y_{299}\">"))
    }

    /// Text that looks like a token, but isn't one, stays as it is.
    @Test func tokenLookalikesStayLiteral() throws {
        let html = try #require(RichMarkdown.html("BCHUMATH7END, BCHUMATHX99END and BCHUMATHXX END with $q_1$"))
        #expect(html.contains("BCHUMATH7END, BCHUMATHX99END and BCHUMATHXX END with <span"))
    }

    @Test func shapesCountFencesAndRichCandidates() {
        for text in ["", "plain", "```swift\nx\n```", "``````", "a ``` b ```` c", "price $5", "\\(x\\)", "\\[x\\]", "A MerMaid diagram", "no math here\\"] {
            let shape = MarkdownShape(text)
            #expect(shape.bytes == text.utf8.count)
            #expect(shape.fences == text.components(separatedBy: "```").count - 1)
            let rich = text.contains("$") || text.contains("\\(") || text.contains("\\[") || text.localizedCaseInsensitiveContains("mermaid")
            #expect(shape.mayBeRich == rich, "\(text)")
        }
    }
}
