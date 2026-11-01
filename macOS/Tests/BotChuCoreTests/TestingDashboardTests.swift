import Foundation
import Testing
@testable import BotChuCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// The Testing dashboard (#434): `testing/releases.json` as `scripts/release-record.py` writes it, published
/// into an owner-only page beside it that embeds it safely, and the page's script drawing each release.
@Suite struct TestingDashboardTests {
    /// Two releases as the script writes them: the first without a suite run, the second with one.
    static let recorded = #"""
    {
      "releases": [
        {"version": "1.0.0", "commit": "d88b4bf", "date": "2026-11-01T01:53:46Z", "suite": null,
         "journeys": {"recordedAt": "2026-11-01T01:53:46Z", "seconds": 223, "machine": "Mac16,5", "load": [4.25, 5.53, 5.32],
           "steps": [{"journey": 1, "step": "launch", "median": 648.5, "budget": 1000.0, "passed": true},
                     {"journey": 3, "step": "switch bot", "median": 60.8, "budget": 50.0, "passed": false}]},
         "changes": ["Project Areas as data: `BotTask.area` (#410)", "</script><script>alert(1)</script> & more (#999)"]},
        {"version": "1.1.0", "commit": "abc1234", "date": "2026-11-02T10:00:00Z",
         "suite": {"seconds": 812, "steps": [{"step": "core tests", "seconds": 95}]},
         "journeys": {"recordedAt": "2026-11-02T09:50:00Z", "seconds": 201, "machine": null, "load": null,
           "steps": [{"journey": 3, "step": "switch bot", "median": 40.0, "budget": 50.0, "passed": true}]},
         "changes": ["Cmd+K switcher (#428)"]}
      ]
    }
    """#

    static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-testing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func record(_ json: String, in root: URL) throws {
        let file = TestingDashboard.releasesURL(in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }

    @Test func publishingReadsTheRecordedReleasesIntoAnOwnerOnlyPage() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.record(Self.recorded, in: root)
        let page = try TestingDashboard.publish(root: root).get()
        #expect(page == TestingDashboard.url(in: root) && page.path.hasSuffix("/testing/dashboard.html"))
        func permissions(_ url: URL) throws -> Int {
            try #require((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        }
        #expect(try permissions(page) == 0o600 && permissions(page.deletingLastPathComponent()) == 0o700)

        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(html.contains(AnalyticsDashboard.contentSecurityPolicy))
        // A change line can't end the data block; the block decodes back to what was recorded.
        #expect(!html.contains("</script><script>alert"))
        let start = try #require(html.range(of: #"id="botchu-testing-data">"#)?.upperBound)
        let end = try #require(html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound)
        let embedded = try JSONDecoder().decode(TestingDashboard.File.self, from: Data(html[start..<end].utf8)).releases
        #expect(embedded == (try TestingDashboard.releases(in: root)))
        #expect(embedded.map(\.version) == ["1.0.0", "1.1.0"] && embedded[0].suite == nil && embedded[1].suite?.seconds == 812)
        #expect(embedded[0].journeys?.steps.map(\.median) == [648.5, 60.8])
    }

    @Test func noReleasesYetMakeAPageAndADamagedFileSaysWhy() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try TestingDashboard.releases(in: root).isEmpty)
        #expect(throws: Never.self) { try TestingDashboard.publish(root: root).get() }

        try Self.record("{\"releases\": [{\"version\": 1}]}", in: root)
        guard case .failure(let failure) = TestingDashboard.publish(root: root) else {
            Issue.record("A damaged releases.json was published")
            return
        }
        #expect(failure.message.hasPrefix("BotChu couldn't read testing/releases.json"))
    }

    #if canImport(JavaScriptCore)
    /// The page's script, on a small stand-in for the DOM: releases newest first, each with its tiles,
    /// suite steps, journeys against their budgets and the release before, and its change lines as text.
    @Test func thePagesScriptDrawsEachReleaseNewestFirst() throws {
        let releases = try JSONDecoder().decode(TestingDashboard.File.self, from: Data(Self.recorded.utf8)).releases
        let json = String(decoding: try JSONEncoder().encode(TestingDashboard.File(releases: releases)), as: UTF8.self)
        let context: JSContext = JSContext()
        context.evaluateScript(#"""
        function Node(tag, text) { this.tag = tag; this.children = []; this.className = ''; this.style = {}; this.text = text || '';
          const node = this; this.classList = { add(name) { node.className += ' ' + name; } }; }
        Node.prototype.append = function (...nodes) { this.children.push(...nodes); };
        Object.defineProperty(Node.prototype, 'textContent', { get() { return this.text + this.children.map(c => c.textContent).join(''); },
          set(value) { this.text = String(value); } });
        const app = new Node('div');
        var document = {
          getElementById(id) { return id === 'app' ? app : { textContent: data }; },
          createElement(tag) { return new Node(tag); },
          createTextNode(text) { return new Node('#text', text); },
        };
        function find(node, test, found = []) { if (test(node)) found.push(node); node.children.forEach(c => find(c, test, found)); return found; }
        """#)
        context.setObject(json, forKeyedSubscript: "data" as NSString)
        context.evaluateScript(TestingDashboard.script)
        #expect(context.exception == nil, "\(String(describing: context.exception))")
        func evaluate(_ script: String) -> String { context.evaluateScript(script)?.toString() ?? "" }
        #expect(evaluate("find(app, n => n.tag === 'h2').map(n => n.textContent).join()") == "1.1.0,1.0.0")
        #expect(evaluate("find(app, n => n.className === 'tile').map(n => n.textContent).join('|')")
            == "Full suite13 min 32 s|Journeys run3 min 21 s-10% vs 1.0.0|Steps within budget1 / 1-34% vs 1.0.0 medians"
            + "|Full suite—|Journeys run3 min 43 s|Steps within budget1 / 2")
        #expect(evaluate("find(app, n => n.tag === 'tr').slice(1, 2).map(n => n.textContent).join()") == "3switch bot40.050.0-34%")
        // A failed step's bar and number show it; the budget mark sits at two thirds of the scale.
        #expect(evaluate("find(app, n => n.className === 'fill failed').length") == "1")
        #expect(evaluate("find(app, n => n.className === 'bad' && n.tag === 'td' && n.textContent === '60.8').length") == "1")
        #expect(evaluate("find(app, n => n.className === 'budget')[0].style.left").hasPrefix("66.66"))
        #expect(evaluate("find(app, n => n.tag === 'code' && n.textContent === 'BotTask.area').length") == "1")
        #expect(evaluate("find(app, n => n.tag === 'li').map(n => n.textContent).join('|')")
            == "Cmd+K switcher (#428)|Project Areas as data: BotTask.area (#410)|</script><script>alert(1)</script> & more (#999)")

        context.setObject("{\"releases\": []}", forKeyedSubscript: "data" as NSString)
        context.evaluateScript("app.children = []")
        context.evaluateScript(TestingDashboard.script)
        #expect(evaluate("app.textContent") == "No releases recorded")
    }
    #endif
}
