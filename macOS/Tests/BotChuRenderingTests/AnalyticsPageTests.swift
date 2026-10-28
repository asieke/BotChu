import AppKit
import Foundation
import Testing
import WebKit
import BotChuCore

/// The analytics dashboard (#233) as WebKit shows it, from the file BotChu writes.
extension RenderingTests {
    /// Four Home turns: two yesterday (one failed), one eight days ago and one five months ago.
    static func analyticsSnapshot() -> AnalyticsSnapshot {
        let zone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!
        var builder = AnalyticsBuilder(zone: zone, now: now)
        let bot = Bot(name: "Product Fox", accountID: "claude-personal", workspace: "/tmp/fox")
        builder.bot(bot.id, name: bot.name)
        func turn(_ daysAgo: Double, _ seconds: Double, _ outcome: AnalyticsOutcome) -> AnalyticsTurn {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            return AnalyticsTurn(start: start, end: start.addingTimeInterval(seconds), outcome: outcome)
        }
        builder.add(turns: [turn(150, 10, .finished), turn(8, 120, .finished), turn(1, 60, .finished), turn(1, 30, .failed)], bot: bot, task: nil)
        return builder.snapshot()
    }

    @Test func theAnalyticsPageShowsItsTotalsFiltersByDateAndLoadsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-analytics-page-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let page = try AnalyticsDashboard.write(Self.analyticsSnapshot(), into: root)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        let tiles = """
            const tile = label => [...document.querySelectorAll('.tile')].find(t => t.querySelector('.label').textContent === label);
            const value = label => tile(label)?.querySelector('.value').textContent ?? null;
            """
        func read(_ body: String) async throws -> [String: Any] {
            try await web.callAsyncJavaScript("\(tiles)\n\(body)", in: nil, contentWorld: .page) as? [String: Any] ?? [:]
        }
        try await waitForPage(web, "document.querySelectorAll('.tile').length > 0")

        // The last 30 days, at first.
        let first = try await read("""
            return { runs: value('Turns & runs'), failed: value('Failed'), finished: value('Finished'), tokens: value('Tokens'),
                     error: document.querySelector('.card.error') !== null, pressed: document.querySelector('button.preset[aria-pressed=true]').textContent,
                     bots: [...document.querySelectorAll('td')].some(td => td.textContent === 'Product Fox') };
            """)
        #expect(first["runs"] as? String == "3")
        #expect(first["failed"] as? String == "1")
        #expect(first["finished"] as? String == "2")
        #expect(first["tokens"] as? String == "Unavailable")
        #expect(first["error"] as? Bool == false)
        #expect(first["pressed"] as? String == "30 days")
        #expect(first["bots"] as? Bool == true)

        // A preset, then a custom range of one day.
        let all = try await read("""
            [...document.querySelectorAll('button.preset')].find(b => b.textContent === 'All').click();
            return { runs: value('Turns & runs') };
            """)
        #expect(all["runs"] as? String == "4")
        let week = try await read("""
            [...document.querySelectorAll('button.preset')].find(b => b.textContent === '7 days').click();
            return { runs: value('Turns & runs') };
            """)
        #expect(week["runs"] as? String == "2")
        let day = try await read("""
            const from = document.querySelector('input[aria-label=From]');
            from.value = '2026-10-20';
            from.dispatchEvent(new Event('change'));
            const again = document.querySelector('input[aria-label=Through]');
            again.value = '2026-10-20';
            again.dispatchEvent(new Event('change'));
            return { runs: value('Turns & runs'), failed: value('Failed'), median: value('Median time'),
                     from: document.querySelector('input[aria-label=From]').value, through: document.querySelector('input[aria-label=Through]').value };
            """)
        #expect(day["runs"] as? String == "1")
        #expect(day["failed"] as? String == "0")
        #expect(day["median"] as? String == "2 min")
        #expect(day["from"] as? String == "2026-10-20" && day["through"] as? String == "2026-10-20")
        // A range with nothing in it, and no kind of work included.
        let empty = try await read("""
            const through = document.querySelector('input[aria-label=Through]');
            through.value = '2027-01-31';
            through.dispatchEvent(new Event('change'));
            const from = document.querySelector('input[aria-label=From]');
            from.value = '2027-01-01';
            from.dispatchEvent(new Event('change'));
            return { runs: value('Turns & runs'), empty: [...document.querySelectorAll('.empty')].map(p => p.textContent) };
            """)
        #expect(empty["runs"] as? String == "0")
        #expect((empty["empty"] as? [String])?.contains("No turns or runs in this range.") == true)

        // Its policy refuses every request the page could make.
        let blocked = try await web.callAsyncJavaScript("""
            const refused = new Promise(resolve => document.addEventListener('securitypolicyviolation', e => resolve(e.effectiveDirective), { once: true }));
            fetch('https://example.com/botchu-analytics').catch(() => {});
            return await Promise.race([refused, new Promise(resolve => setTimeout(() => resolve('allowed'), 3000))]);
            """, in: nil, contentWorld: .page) as? String
        #expect(blocked == "connect-src")
    }

    private func waitForPage(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<200 {
            if (try? await web.callAsyncJavaScript("return \(script);", in: nil, contentWorld: .page)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The analytics page didn't render: \(script)")
    }
}
