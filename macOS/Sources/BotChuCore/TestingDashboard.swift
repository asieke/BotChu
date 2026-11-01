import Foundation

/// One release in the Testing dashboard (#434): a version Alex deployed, as `scripts/release-record.py`
/// writes it into `testing/releases.json`: the full suite's step timings when it ran, the journeys'
/// medians against their budgets, and the CHANGELOG lines it brought.
public struct TestingRelease: Codable, Equatable, Sendable {
    public struct Suite: Codable, Equatable, Sendable {
        public struct Step: Codable, Equatable, Sendable {
            public var step: String
            public var seconds: Double
        }

        public var seconds: Double
        public var steps: [Step]
    }

    public struct Journeys: Codable, Equatable, Sendable {
        public struct Step: Codable, Equatable, Sendable {
            public var journey: Int
            public var step: String
            public var median: Double
            public var budget: Double
            public var passed: Bool
        }

        public var recordedAt: String?
        public var seconds: Double?
        public var machine: String?
        public var load: [Double]?
        public var steps: [Step]
    }

    public var version: String
    public var commit: String
    public var date: String
    public var suite: Suite?
    public var journeys: Journeys?
    public var changes: [String]
}

/// The Testing dashboard as one page for the browser on this Mac, published as `AnalyticsDashboard`
/// is: `testing/dashboard.html` in BotChu's data folder, owner-only, loading nothing, made again from
/// `testing/releases.json` beside it each time it opens, so a recorded release shows without a code change.
public enum TestingDashboard {
    public static let folderName = "testing"
    public static let fileName = "dashboard.html"
    public static let releasesName = "releases.json"

    public struct Failure: Error, Equatable, Sendable {
        public var message: String
    }

    struct File: Codable {
        var releases: [TestingRelease]
    }

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    public static func releasesURL(in root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(releasesName)
    }

    /// The recorded releases, oldest first as recorded; none before the first is recorded.
    public static func releases(in root: URL) throws -> [TestingRelease] {
        let file = releasesURL(in: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: file)).releases
    }

    /// Reads the releases and writes the page, off the main thread.
    public static func publish(root: URL) -> Result<URL, Failure> {
        let releases: [TestingRelease]
        do {
            releases = try self.releases(in: root)
        } catch {
            return .failure(Failure(message: "BotChu couldn't read \(folderName)/\(releasesName) in its data folder: \(error.localizedDescription)"))
        }
        do {
            return .success(try write(releases, into: root))
        } catch {
            return .failure(Failure(message: "BotChu couldn't save the dashboard in its data folder: \(error.localizedDescription)"))
        }
    }

    /// Writes the page, replacing the last one, in a folder (0700) and file (0600) only this user reads.
    @discardableResult
    public static func write(_ releases: [TestingRelease], into root: URL) throws -> URL {
        let file = url(in: root)
        let folder = file.deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try Data(html(for: releases).utf8).write(to: file, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// The page, with the releases as JSON in a data block the script reads, escaped as the analytics page's.
    public static func html(for releases: [TestingRelease]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(File(releases: releases))
        return template.replacingOccurrences(of: dataMarker, with: AnalyticsDashboard.embedded(json))
    }

    static let dataMarker = "/*BOTCHU_TESTING_DATA*/"

    static var template: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(AnalyticsDashboard.contentSecurityPolicy)">
        <meta name="referrer" content="no-referrer">
        <title>BotChu Testing</title>
        <style>\(style)</style>
        </head>
        <body>
        <main class="wrap">
        <header><h1>BotChu Testing</h1></header>
        <div id="app"></div>
        </main>
        <script type="application/json" id="botchu-testing-data">\(dataMarker)</script>
        <script>\(script)</script>
        </body>
        </html>

        """
    }

    static let style = #"""
    :root {
      color-scheme: light dark;
      --page: light-dark(#f9f9f7, #0d0d0d);
      --surface: light-dark(#fcfcfb, #1a1a19);
      --text: light-dark(#0b0b0b, #f0efec);
      --text-2: light-dark(#52514e, #c3c2b7);
      --muted: light-dark(#75736d, #9a988f);
      --grid: light-dark(#e1e0d9, #2c2c2a);
      --border: light-dark(rgba(11, 11, 11, 0.10), rgba(255, 255, 255, 0.10));
      --wash: light-dark(rgba(11, 11, 11, 0.05), rgba(255, 255, 255, 0.06));
      --accent: light-dark(#2a78d6, #3987e5);
      --good: light-dark(#006300, #0ca30c);
      --bad: light-dark(#b42f2f, #e66767);
      --warn: light-dark(#c98500, #eda100);
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--page); color: var(--text); }
    body { font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
    .wrap { max-width: 1080px; margin: 0 auto; padding: 0 16px 40px; }
    header { padding: 24px 0 8px; }
    h1 { font-size: 22px; margin: 0; font-weight: 650; }
    h2 { font-size: 20px; margin: 0; font-weight: 650; }
    h3 { font-size: 13px; margin: 0 0 6px; font-weight: 600; color: var(--text-2); }
    .release { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 16px 18px; margin-top: 16px; }
    .title { display: flex; align-items: baseline; gap: 12px; flex-wrap: wrap; }
    .meta { color: var(--text-2); font-size: 12.5px; font-variant-numeric: tabular-nums; }
    code { font: 12px ui-monospace, "SF Mono", Menlo, monospace; background: var(--wash); border-radius: 4px; padding: 0 4px; }
    .kpis { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; margin: 14px 0; }
    .tile { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; }
    .tile .l { color: var(--text-2); font-size: 12.5px; }
    .tile .v { font-size: 22px; font-weight: 600; font-variant-numeric: tabular-nums; }
    .tile .d { font-size: 12px; color: var(--text-2); font-variant-numeric: tabular-nums; }
    .good { color: var(--good); } .bad { color: var(--bad); }
    .cols { display: grid; grid-template-columns: minmax(0, 3fr) minmax(0, 2fr); gap: 20px; }
    table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
    td, th { padding: 3px 6px; border-bottom: 1px solid var(--grid); white-space: nowrap; font-variant-numeric: tabular-nums; text-align: right; }
    th { color: var(--text-2); font-weight: 500; font-size: 11.5px; }
    td.name, th.name { text-align: left; white-space: normal; }
    td.n { color: var(--muted); width: 1.5em; }
    td.bar { width: 34%; }
    .track { position: relative; height: 8px; border-radius: 4px; background: var(--wash); }
    .fill { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 4px; background: var(--accent); }
    .fill.over { background: var(--warn); }
    .fill.failed { background: var(--bad); }
    .budget { position: absolute; top: -3px; bottom: -3px; width: 2px; background: var(--text-2); }
    .steps { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 14px; }
    .steps span { font-size: 12px; border: 1px solid var(--border); border-radius: 12px; padding: 1px 9px; color: var(--text-2); font-variant-numeric: tabular-nums; }
    .steps b { font-weight: 500; color: var(--text); }
    ul { margin: 0; padding-left: 18px; } li { margin: 0 0 6px; font-size: 13px; }
    .empty { color: var(--muted); margin-top: 16px; }
    @media (max-width: 760px) { .cols, .kpis { grid-template-columns: 1fr; } }
    """#

    /// Releases newest first; each against the release before it. Text goes in as text nodes only.
    static let script = #"""
    (() => {
      const data = JSON.parse(document.getElementById('botchu-testing-data').textContent);
      const app = document.getElementById('app');
      const el = (tag, cls, text) => {
        const node = document.createElement(tag);
        if (cls) node.className = cls;
        if (text !== undefined) node.textContent = text;
        return node;
      };
      const duration = s => s == null ? '—' : s < 60 ? `${Math.round(s)} s` : `${Math.floor(s / 60)} min ${String(Math.round(s % 60)).padStart(2, '0')} s`;
      const ms = v => v < 100 ? v.toFixed(1) : Math.round(v).toString();
      const key = step => `${step.journey} ${step.step}`;
      const delta = (now, before, unit) => {
        const node = el('div', 'd');
        if (now == null || before == null || before === 0) return node;
        const change = (now - before) / before * 100;
        node.textContent = `${change > 0 ? '+' : ''}${change.toFixed(0)}% vs ${unit}`;
        if (Math.abs(change) >= 5) node.classList.add(change > 0 ? 'bad' : 'good');
        return node;
      };
      const tile = (label, value, d) => {
        const node = el('div', 'tile');
        node.append(el('div', 'l', label), el('div', 'v', value), d || el('div', 'd'));
        return node;
      };
      // `code` spans in a CHANGELOG line, as text nodes.
      const line = text => {
        const item = el('li');
        text.split('`').forEach((part, i) => item.append(i % 2 ? el('code', null, part) : document.createTextNode(part)));
        return item;
      };
      const releases = (data.releases || []).slice().reverse();
      if (!releases.length) { app.append(el('p', 'empty', 'No releases recorded')); return; }
      releases.forEach((release, index) => {
        const before = releases[index + 1];
        const card = el('section', 'release');
        const title = el('div', 'title');
        title.append(el('h2', null, release.version), el('code', null, release.commit),
          el('span', 'meta', new Date(release.date).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })));
        card.append(title);

        const steps = release.journeys ? release.journeys.steps : [];
        const passed = steps.filter(s => s.passed).length;
        const earlier = new Map((before && before.journeys ? before.journeys.steps : []).map(s => [key(s), s.median]));
        const shared = steps.filter(s => earlier.has(key(s)));
        const sum = list => list.reduce((a, b) => a + b, 0);
        const kpis = el('div', 'kpis');
        kpis.append(
          tile('Full suite', duration(release.suite && release.suite.seconds),
            delta(release.suite && release.suite.seconds, before && before.suite && before.suite.seconds, before && before.version)),
          tile('Journeys run', duration(release.journeys && release.journeys.seconds),
            delta(release.journeys && release.journeys.seconds, before && before.journeys && before.journeys.seconds, before && before.version)),
          tile('Steps within budget', steps.length ? `${passed} / ${steps.length}` : '—',
            shared.length ? delta(sum(shared.map(s => s.median)), sum(shared.map(s => earlier.get(key(s)))), `${before.version} medians`) : null));
        card.append(kpis);

        if (release.suite && release.suite.steps.length) {
          const list = el('div', 'steps');
          release.suite.steps.forEach(s => {
            const chip = el('span', null, `${s.step} `);
            chip.append(el('b', null, duration(s.seconds)));
            list.append(chip);
          });
          card.append(list);
        }

        const cols = el('div', 'cols');
        const left = el('div');
        if (steps.length) {
          left.append(el('h3', null, 'Journeys'));
          const table = el('table');
          const head = el('tr');
          [['', ''], ['Step', 'name'], ['', 'bar'], ['Median ms', ''], ['Budget', ''], [before ? `vs ${before.version}` : '', '']]
            .forEach(([text, cls]) => head.append(el('th', cls, text)));
          table.append(head);
          steps.forEach(s => {
            const row = el('tr');
            const bar = el('td', 'bar');
            const track = el('div', 'track');
            // The bar's scale runs to 1.5 times the budget, so the budget mark sits two thirds along. Over its
            // budget a step can still pass, held to its ratchet (docs/testing.md); failing is another colour.
            const fill = el('div', !s.passed ? 'fill failed' : s.median > s.budget ? 'fill over' : 'fill');
            fill.style.width = `${Math.min(s.median / s.budget, 1.5) / 1.5 * 100}%`;
            const mark = el('div', 'budget');
            mark.style.left = `${100 / 1.5}%`;
            track.append(fill, mark);
            bar.append(track);
            const was = earlier.get(key(s));
            const change = was ? (s.median - was) / was * 100 : null;
            const vs = el('td', change == null ? '' : change >= 10 ? 'bad' : change <= -10 ? 'good' : '',
              change == null ? '' : `${change > 0 ? '+' : ''}${change.toFixed(0)}%`);
            row.append(el('td', 'n', String(s.journey)), el('td', 'name', s.step), bar,
              el('td', s.passed ? '' : 'bad', ms(s.median)), el('td', null, ms(s.budget)), vs);
            table.append(row);
          });
          left.append(table);
        }
        const right = el('div');
        if (release.changes.length) {
          right.append(el('h3', null, 'Changes'));
          const list = el('ul');
          release.changes.forEach(text => list.append(line(text)));
          right.append(list);
        }
        cols.append(left, right);
        card.append(cols);
        app.append(card);
      });
    })();
    """#
}
