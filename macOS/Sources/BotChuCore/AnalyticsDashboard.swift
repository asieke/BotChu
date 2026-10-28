import Foundation

/// The analytics dashboard as one page for the browser on this Mac (#233): a file with its data,
/// style and script inside it, loading nothing (its content security policy allows no network
/// request at all), written into BotChu's own data folder where only this macOS user can read it.
/// Nothing serves it, so there is no port and no remote access. Its date range, kinds and breakdowns
/// are worked out in the page from the snapshot's records, as `AnalyticsSummary` works them out.
public enum AnalyticsDashboard {
    /// `analytics/dashboard.html` in BotChu's data folder (`~/Library/Application Support/BotChu`).
    public static let folderName = "analytics"
    public static let fileName = "dashboard.html"

    public struct Failure: Error, Equatable, Sendable {
        public var message: String

        public init(message: String) {
            self.message = message
        }
    }

    public static func url(in root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Reads the records (`Analytics.collect`) and writes the page, off the main thread.
    public static func publish(_ input: AnalyticsInput) -> Result<URL, Failure> {
        do {
            return .success(try write(Analytics.collect(input), into: input.root))
        } catch {
            return .failure(Failure(message: "BotChu couldn't save the dashboard in its data folder: \(error.localizedDescription)"))
        }
    }

    /// Writes the page, replacing the last one: its folder is readable only by this user (0700),
    /// before the file is written into it, and so is the file (0600).
    @discardableResult
    public static func write(_ snapshot: AnalyticsSnapshot, into root: URL) throws -> URL {
        let file = url(in: root)
        let folder = file.deletingLastPathComponent()
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try Data(html(for: snapshot).utf8).write(to: file, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// The page, with the snapshot as JSON in a data block the script reads. Every `<`, `>` and `&`
    /// in it is escaped (`<`), so no name in it can end the block or start markup.
    public static func html(for snapshot: AnalyticsSnapshot) throws -> String {
        template.replacingOccurrences(of: dataMarker, with: embedded(try snapshot.encoded()))
    }

    /// JSON that stays JSON inside a `<script>` block.
    static func embedded(_ json: Data) -> String {
        String(decoding: json, as: UTF8.self)
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static let dataMarker = "/*BOTCHU_ANALYTICS_DATA*/"

    /// No request of any kind, no forms or base URL: only the page's own style and script.
    public static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; "
        + "base-uri 'none'; form-action 'none'"

    static var template: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="referrer" content="no-referrer">
        <title>BotChu Analytics</title>
        <style>\(style)</style>
        </head>
        <body>
        <header class="top">
          <div>
            <h1>BotChu Analytics</h1>
            <p class="sub" id="generated"></p>
          </div>
        </header>
        <main id="app"></main>
        <div class="tooltip" id="tooltip" role="status" hidden></div>
        <script type="application/json" id="botchu-analytics-data">\(dataMarker)</script>
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
      --axis: light-dark(#c3c2b7, #383835);
      --border: light-dark(rgba(11, 11, 11, 0.10), rgba(255, 255, 255, 0.10));
      --wash: light-dark(rgba(11, 11, 11, 0.05), rgba(255, 255, 255, 0.06));
      --accent: light-dark(#2a78d6, #3987e5);
      --s1: light-dark(#2a78d6, #3987e5);
      --s2: light-dark(#eb6834, #d95926);
      --s3: light-dark(#1baf7a, #199e70);
      --s4: light-dark(#eda100, #c98500);
      --s5: light-dark(#e87ba4, #d55181);
      --s6: #008300;
      --s7: light-dark(#6250d6, #9085e9);
      --other: light-dark(#a8a69f, #6f6d68);
      --finished: light-dark(#2a78d6, #3987e5);
      --failed: #d03b3b;
      --stopped: #ec835a;
      --inprogress: light-dark(#a8a69f, #6f6d68);
      --warn: #fab219;
      --t-in: light-dark(#75736d, #8f8d86);
      --t-cr: light-dark(#c8c6bd, #4a4945);
      --t-cw: light-dark(#a09e96, #6a6863);
      --t-out: light-dark(#3a3936, #d8d6cf);
      --good: light-dark(#006300, #0ca30c);
      --bad: light-dark(#b42f2f, #e66767);
    }
    :root[data-theme="light"] { color-scheme: light; }
    :root[data-theme="dark"] { color-scheme: dark; }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html, body { margin: 0; background: var(--page); color: var(--text); }
    body { font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
    .wrap { max-width: 1180px; margin: 0 auto; padding: 0 16px 32px; }
    header.top { display: flex; align-items: baseline; gap: 12px; padding: 24px 0 4px; }
    h1 { font-size: 22px; margin: 0; font-weight: 650; }
    h2 { font-size: 15px; margin: 0; font-weight: 600; }
    .made { color: var(--text-2); font-size: 12.5px; }
    button, select { font: inherit; font-size: 13px; color: var(--text); }
    .bar { position: sticky; top: 0; z-index: 5; background: var(--page); padding: 10px 0; display: grid; gap: 8px; }
    .row { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
    .spacer { flex: 1; }
    .seg { display: inline-flex; border: 1px solid var(--border); border-radius: 7px; background: var(--surface); padding: 2px; }
    .seg button { border: 0; background: none; border-radius: 5px; padding: 3px 10px; cursor: pointer; }
    .seg button:hover { background: var(--wash); }
    .seg button[aria-pressed="true"] { background: var(--text); color: var(--surface); font-weight: 600; }
    .dates { color: var(--text-2); font-size: 13px; font-variant-numeric: tabular-nums; }
    .pv { display: inline-flex; align-items: center; gap: 6px; font-size: 12.5px; color: var(--text-2); background: none; border: 0; padding: 2px 4px; }
    button.pv { cursor: pointer; border-radius: 5px; }
    button.pv:hover { background: var(--wash); }
    .sw { display: inline-block; width: 12px; height: 12px; border-radius: 3px; flex: none; }
    .act { background: var(--c); }
    .est { background: repeating-linear-gradient(-45deg, var(--c) 0 3.5px, color-mix(in srgb, var(--c) 66%, var(--surface)) 3.5px 5px); }
    .unp { border: 1.5px dashed var(--muted); }
    select.add { appearance: none; width: 84px; border: 1px dashed var(--axis); background: var(--surface); border-radius: 13px; padding: 3px 12px; cursor: pointer; color: var(--text-2); }
    select.add:hover { border-color: var(--muted); color: var(--text); }
    .chip { display: inline-flex; align-items: center; gap: 6px; background: color-mix(in srgb, var(--accent) 12%, var(--surface)); border: 1px solid color-mix(in srgb, var(--accent) 35%, transparent);
      border-radius: 13px; padding: 2px 3px 2px 10px; font-size: 13px; }
    .chip b { font-weight: 500; color: var(--text-2); }
    .chip button { border: 0; background: none; width: 20px; height: 20px; border-radius: 10px; cursor: pointer; color: var(--text-2); padding: 0; line-height: 20px; }
    .chip button:hover { background: var(--wash); color: var(--text); }
    .clear { border: 0; background: none; color: var(--accent); cursor: pointer; padding: 3px 6px; }
    .card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; min-width: 0; }
    .head { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; min-height: 26px; }
    .head .tot { margin-left: auto; font-size: 15px; font-weight: 600; font-variant-numeric: tabular-nums; }
    .head select, .ctl select { border: 1px solid var(--border); background: var(--surface); border-radius: 6px; padding: 2px 6px; }
    .ctl { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: var(--text-2); }
    section { margin-top: 16px; }
    .kpis { display: grid; grid-template-columns: 1.35fr repeat(5, minmax(0, 1fr)); gap: 12px; }
    .tile { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; min-width: 0; }
    .tile.go { font: inherit; color: inherit; text-align: left; cursor: pointer; display: flex; flex-direction: column; justify-content: flex-start; }
    .tile.go:hover { background: color-mix(in srgb, var(--text) 3%, var(--surface)); }
    .tile.go[aria-pressed="true"] { border-color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); }
    .tile .l { color: var(--text-2); font-size: 12.5px; }
    .tile .v { font-size: 24px; font-weight: 600; margin-top: 2px; white-space: nowrap; }
    .tile .d { color: var(--text-2); font-size: 12px; margin-top: 4px; font-variant-numeric: tabular-nums; }
    .up-bad, .down-bad { color: var(--bad); } .up-good, .down-good { color: var(--good); }
    .split { display: flex; gap: 2px; height: 8px; margin-top: 8px; }
    .split i { display: block; border-radius: 2px; min-width: 3px; }
    .grid2 { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 16px; margin-top: 16px; }
    .legend { display: flex; flex-wrap: wrap; gap: 4px 14px; font-size: 12.5px; color: var(--text-2); margin-bottom: 6px; }
    .legend span { display: inline-flex; align-items: center; gap: 6px; }
    .legend em { font-style: normal; color: var(--text); font-variant-numeric: tabular-nums; }
    .chart svg { display: block; width: 100%; overflow: visible; }
    .axis { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
    .gl { stroke: var(--grid); shape-rendering: crispEdges; } .base { stroke: var(--axis); shape-rendering: crispEdges; }
    .hit { fill: transparent; } .hit:hover { fill: var(--wash); }
    .mix { display: flex; gap: 2px; height: 14px; margin: 4px 0 12px; }
    .mix i { border-radius: 2px; min-width: 2px; }
    table { border-collapse: collapse; width: 100%; font-size: 13px; }
    th, td { text-align: right; padding: 6px 8px; border-bottom: 1px solid var(--grid); white-space: nowrap; font-variant-numeric: tabular-nums; }
    th { color: var(--text-2); font-weight: 500; font-size: 12px; }
    th:first-child, td:first-child { text-align: left; }
    .mixt td { padding: 5px 0; } .mixt td:first-child { display: flex; align-items: center; gap: 8px; }
    .mixt td.sub { padding-left: 20px; color: var(--text-2); }
    .mixt td.pc { color: var(--text-2); width: 52px; }
    th button { font-size: 12px; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; font-weight: 500; }
    th[aria-sort] button { color: var(--text); font-weight: 600; }
    th[aria-sort="descending"] button::after { content: " ↓"; } th[aria-sort="ascending"] button::after { content: " ↑"; }
    #ex tbody tr { cursor: pointer; } #ex tbody tr:hover { background: var(--wash); }
    #ex tr.child td:first-child { padding-left: 54px; color: var(--text-2); }
    #ex td:first-child { min-width: 210px; }
    .nm { display: inline-flex; align-items: center; gap: 8px; }
    .dot { width: 10px; height: 10px; border-radius: 5px; flex: none; }
    .tw { width: 20px; height: 20px; border: 0; background: none; cursor: pointer; color: var(--muted); border-radius: 4px; padding: 0; transition: transform .15s; }
    .tw:hover { background: var(--wash); color: var(--text); }
    .tw[aria-expanded="true"] { transform: rotate(90deg); }
    .tw.ph { visibility: hidden; }
    tfoot td { font-weight: 600; border-bottom: 0; border-top: 1px solid var(--axis); }
    .share { display: flex; align-items: center; gap: 8px; justify-content: flex-end; }
    .track { width: 120px; height: 8px; display: flex; gap: 0; background: var(--wash); border-radius: 2px; overflow: hidden; }
    .track i { display: block; height: 100%; }
    .na { color: var(--muted); }
    .ins { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
    .in { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; display: grid; grid-template-rows: auto auto 1fr auto; gap: 4px; min-width: 0; }
    .in .t { display: flex; gap: 8px; font-weight: 600; font-size: 13.5px; }
    .in .rk { color: var(--muted); font-weight: 500; font-variant-numeric: tabular-nums; }
    .in .n { font-size: 22px; font-weight: 600; }
    .in .n small { font-size: 13px; font-weight: 500; color: var(--text-2); margin-left: 4px; }
    .in .f { color: var(--text-2); font-size: 12.5px; font-variant-numeric: tabular-nums; }
    .in .go { justify-self: start; margin-top: 6px; border: 1px solid var(--border); background: var(--surface); border-radius: 6px; padding: 3px 10px; cursor: pointer; }
    .in .go:hover { background: var(--wash); }
    .in .go[aria-pressed="true"] { border-color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); font-weight: 600; }
    .meter { display: inline-block; width: 72px; height: 6px; border-radius: 3px; background: var(--grid); vertical-align: middle; margin-right: 6px; overflow: hidden; }
    .meter i { display: block; height: 100%; background: var(--accent); border-radius: 3px; }
    .meter.hot i { background: var(--warn); }
    .badge { display: inline-block; font-size: 11px; padding: 0 6px; border-radius: 9px; border: 1px solid var(--border); color: var(--text-2); margin-left: 6px; }
    details.about { margin-top: 16px; }
    details.about summary { cursor: pointer; color: var(--text-2); font-size: 13px; }
    details.about dl { margin: 8px 0 0; } .about dt { font-weight: 600; margin-top: 8px; font-size: 13px; } .about dd { margin: 2px 0 0; color: var(--text-2); font-size: 13px; }
    .tip { position: fixed; z-index: 10; pointer-events: none; background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
      box-shadow: 0 4px 16px rgba(0, 0, 0, .12); padding: 8px 10px; font-size: 12.5px; min-width: 180px; }
    .tip .r { display: flex; align-items: center; gap: 6px; } .tip .r em { margin-left: auto; padding-left: 16px; font-style: normal; font-variant-numeric: tabular-nums; }
    .tip b { display: block; margin-bottom: 4px; }
    @media (prefers-reduced-motion: reduce) { .tw { transition: none; } }
    @media (max-width: 1000px) { .kpis { grid-template-columns: repeat(3, minmax(0, 1fr)); } .grid2, .ins { grid-template-columns: minmax(0, 1fr); } }

    .top, main { max-width:1180px; margin:auto; padding-left:16px; padding-right:16px; }
    header.top { padding-left:16px; padding-right:16px; }
    main { padding-bottom:32px; }
    .sub { color:var(--text-2); font-size:12.5px; margin:4px 0; }
    input[type=date] { font:inherit; color:var(--text); background:var(--surface); border:1px solid var(--border); border-radius:6px; padding:3px 5px; }
    .table-wrap { overflow-x:auto; }
    .empty { padding:28px 8px; text-align:center; color:var(--text-2); }
    .callout { padding:10px 12px; border:1px solid var(--border); border-left:4px solid var(--warn); border-radius:8px; }
    .callout ul { margin:4px 0; padding-left:20px; }
    .row-filter { background:none; border:0; color:inherit; text-align:left; cursor:pointer; padding:0; }
    .child .row-filter { color:var(--text-2); }
    .cache-row { display:flex; align-items:center; gap:8px; padding:5px 0; font-size:13px; }
    h3 { font-size:13px; margin:16px 0 6px; }
    .impact { font-size:13px; font-weight:600; color:var(--accent); }
    .allowance-windows { display:flex; flex-direction:column; gap:5px; }
    .allowance-window { white-space:nowrap; }
    .in .f { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .in .go:disabled { opacity:.5; cursor:default; }
    button:focus-visible, select:focus-visible, .hit:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
    """#

    /// The page's script. Its first part only works numbers out (`BotChuAnalytics`), as
    /// `AnalyticsSummary` does, so it runs without a page too; the rest draws the page with DOM
    /// calls and `textContent`, never markup made from the data.
    public static let script = #"""
    (function (root) {
      "use strict";
      var LABELS = { finished: "Finished", failed: "Failed", stopped: "Stopped", interrupted: "Interrupted",
        inProgress: "In progress", skipped: "Skipped" };
      var KINDS = [["home", "Home turns"], ["task", "Task turns"], ["job", "Job runs"], ["subagent", "Sub-agent runs"]];
      function pad(n) { return (n < 10 ? "0" : "") + n; }
      function dayNumber(day) { var p = day.split("-"); return Math.round(Date.UTC(+p[0], +p[1] - 1, +p[2]) / 86400000); }
      function dayString(n) { var d = new Date(n * 86400000); return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate()); }
      function addDays(day, n) { return dayString(dayNumber(day) + n); }
      function days(from, through) {
        var out = [];
        for (var n = dayNumber(from), last = dayNumber(through); n <= last && out.length < 100000; n++) { out.push(dayString(n)); }
        return out;
      }
      function median(values) {
        if (!values.length) { return null; }
        var sorted = values.slice().sort(function (a, b) { return a - b; });
        var middle = Math.floor(sorted.length / 2);
        return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
      }
      function ended(outcome) { return outcome !== "inProgress" && outcome !== "skipped"; }

      /* The same numbers as AnalyticsSummary in BotChuCore: skipped job times aren't runs, and an
         unknown duration is left out of the median and the total, never counted as zero. */
      function summarize(records, from, through, kinds, include, tasks) {
        var summary = { runs: 0, outcomes: {}, skipped: 0, ended: 0, failureRate: null, timed: 0, medianSeconds: null, totalSeconds: 0 };
        var selected = records.filter(function (r) { return r.day >= from && r.day <= through && kinds[r.kind] && (!include || include(r)) && r.outcome !== "skipped"; });
        function sum(values) {
          var known = values.filter(function (v) { return typeof v === "number" && isFinite(v) && v >= 0; });
          if (!known.length) { return null; }
          var total = known.reduce(function (a, b) { return a + b; }, 0);
          return isFinite(total) ? total : null;
        }
        function costs(rows) { return sum(rows.map(function (r) { return r.cost; })); }
        summary.tokens = {};
        ["uncachedInput", "cacheRead", "cacheWrite", "cacheWrite1h", "output", "reasoning"].forEach(function (key) {
          summary.tokens[key] = sum(selected.map(function (r) { return (r.tokens || {})[key]; }));
        });
        var allInput = sum([summary.tokens.uncachedInput, summary.tokens.cacheRead, summary.tokens.cacheWrite]);
        summary.cacheHitRate = typeof summary.tokens.cacheRead === "number" && allInput > 0 ? summary.tokens.cacheRead / allInput : null;
        summary.actualCost = costs(selected.filter(function (r) { return r.costProvenance === "actual"; }));
        summary.estimatedCost = costs(selected.filter(function (r) { return r.costProvenance === "estimated"; }));
        summary.cost = sum([summary.actualCost, summary.estimatedCost]);
        summary.unpriced = selected.filter(function (r) { return r.costProvenance === "unpriced"; }).length;
        summary.unavailable = selected.filter(function (r) { return !r.costProvenance || r.costProvenance === "unavailable"; }).length;
        summary.costProvenance = summary.estimatedCost !== null ? "estimated" : summary.actualCost !== null ? "actual" : summary.unpriced ? "unpriced" : "unavailable";
        summary.wastedCost = costs(selected.filter(function (r) { return ["failed", "stopped", "interrupted"].indexOf(r.outcome) >= 0; }));
        var represented = {}, finished = {};
        selected.forEach(function (r) { if ((r.kind === "task" || r.kind === "subagent") && r.taskID) { represented[r.taskID] = true; } });
        (tasks || []).forEach(function (t) { if (t.id && t.latest === "finished" && represented[t.id]) { finished[t.id] = true; } });
        summary.finishedTasks = Object.keys(finished).length;
        var taskSpend = costs(selected.filter(function (r) { return finished[r.taskID] && (r.kind === "task" || r.kind === "subagent"); }));
        summary.costPerFinishedTask = summary.finishedTasks && taskSpend !== null ? taskSpend / summary.finishedTasks : null;
        var durations = [];
        records.forEach(function (record) {
          if (record.day < from || record.day > through || !kinds[record.kind] || (include && !include(record))) { return; }
          if (record.outcome === "skipped") { summary.skipped += 1; return; }
          summary.runs += 1;
          summary.outcomes[record.outcome] = (summary.outcomes[record.outcome] || 0) + 1;
          if (!ended(record.outcome)) { return; }
          summary.ended += 1;
          if (typeof record.seconds === "number") { durations.push(record.seconds); }
        });
        summary.failureRate = summary.ended ? (summary.outcomes.failed || 0) / summary.ended : null;
        summary.timed = durations.length;
        summary.medianSeconds = median(durations);
        summary.totalSeconds = durations.reduce(function (a, b) { return a + b; }, 0);
        return summary;
      }

      function formatDuration(seconds) {
        if (seconds === null || seconds === undefined) { return "Unknown"; }
        if (seconds < 60) { return Math.round(seconds) + " s"; }
        var minutes = Math.round(seconds / 60);
        if (minutes < 60) { return minutes + " min"; }
        var hours = Math.floor(minutes / 60), rest = minutes % 60;
        if (hours < 24) { return hours + " h" + (rest ? " " + rest + " min" : ""); }
        var whole = Math.floor(hours / 24), left = hours % 24;
        return whole + " d" + (left ? " " + left + " h" : "");
      }
      function formatPercent(rate) { return rate === null || rate === undefined ? "—" : (Math.round(rate * 1000) / 10) + "%"; }

      /* A token count or cost, saying how far it can be trusted: missing is "Unavailable", never 0, and
         an estimate is marked as one. */
      function measureText(measure) {
        if (!measure || measure.provenance === "unavailable" || typeof measure.value !== "number") {
          return { value: "Unavailable", detail: "Not recorded", unavailable: true };
        }
        var value = measure.metric === "cost" ? "$" + measure.value.toFixed(2) : Math.round(measure.value).toLocaleString("en-US");
        return measure.provenance === "estimated"
          ? { value: "≈ " + value, detail: "Estimated", unavailable: false }
          : { value: value, detail: "Reported by the provider", unavailable: false };
      }

      // Pure explorer calculations are shared by the DOM and JavaScriptCore tests.
      var ALL_KINDS = { home: true, task: true, job: true, subagent: true };
      var DIMENSIONS = {
        bot: "Bot",
        project: "Project",
        model: "Model",
        provider: "Provider",
        account: "Account",
        kind: "Kind",
        outcome: "Outcome"
      };
      function money(value, estimated) {
        var measure = measureText({metric: "cost", value: value, provenance: estimated ? "estimated" : "actual"});
        return measure.unavailable ? "—" : measure.value.replace("≈ ", "≈");
      }
      function compact(value) {
        return typeof value !== "number"
          ? "—"
          : value >= 1e6
            ? (value / 1e6).toFixed(1) + "M"
            : value >= 10000
              ? Math.round(value / 1000) + "K"
              : value.toLocaleString("en-US");
      }
      function createExplorer(snapshot) {
        var records = snapshot.records || [],
          prices = snapshot.prices || [],
          dimensions = {},
          taskMap = {},
          resolved = new Map(), recordIndex = new Map(), selectionSets = new WeakMap();
        records.forEach(function(r,index) { recordIndex.set(r,index); });
        (snapshot.tasks || []).forEach(function (t) {
          if (t.id) taskMap[t.id] = t;
        });
        function resolve(raw, r) {
          if (!raw) return null;
          var cacheKey = JSON.stringify([raw, r.provider, r.providerID]);
          if (resolved.has(cacheKey)) return resolved.get(cacheKey);
          var sources =
            r.provider === "pi"
              ? [r.providerID || "unknown"]
              : r.provider === "sail"
                ? ["sail"]
                : ["anthropic", "openai", "google"];
          var candidates = [raw.trim()],
            normalized = candidates[0];
          while (true) {
            var next = normalized
              .replace(/\[1m\]$/, "")
              .replace(
                /-(?:none|minimal|low|medium|high|xhigh|max|ultra|thinking(?:-(?:\d+|low|medium|high))?)$/,
                ""
              )
              .replace(/-\d{8}$/, "");
            if (next === normalized) break;
            candidates.push(next);
            normalized = next;
          }
          for (var candidate of candidates)
            for (var source of sources) {
              var ids =
                source === "openrouter" || source === "sail"
                  ? [candidate, candidate.replace(new RegExp("^" + source + "/"), "")]
                  : [candidate, candidate.split("/").pop()];
              var found = prices.find(function (p) {
                return p.source === source && ids.indexOf(p.model) >= 0;
              });
              if (found) {
                resolved.set(cacheKey, found);
                return found;
              }
            }
          resolved.set(cacheKey, null);
          return null;
        }
        function dimension(r, k) {
          if (k === "provider") {
            if (r.provider === "pi") return "pi:" + (r.providerID || "unknown");
            if (r.provider) return r.provider;
            var family = (snapshot.accounts[r.account] || {}).family;
            return ({"Claude Code": "claude", Codex: "codex", Antigravity: "antigravity", Muse: "muse", Sail: "sail", Pi: "pi:unknown", OpenRouter: "pi:openrouter"})[family] || family || "unknown";
          }
          if (k === "model")
            return (
              r.model ||
              ((r.models || []).length === 1
                ? r.models[0].model
                : (r.models || []).length > 1
                  ? "mixed"
                  : "unknown")
            );
          return r[k] == null ? "unknown" : String(r[k]);
        }
        function label(k, v) {
          if (k === "bot") return snapshot.bots[v] || "Unknown bot";
          if (k === "project") return snapshot.projects[v] || "No project";
          if (k === "account") return (snapshot.accounts[v] || {}).name || "Account not recorded";
          if (k === "model") {
            if (v === "unknown" || v === "mixed") return v === "mixed" ? "Multiple models" : "Model not recorded";
            var record = records.find(function (r) {
                return dimension(r, "model") === v;
              }),
              price = (record && resolve(v, record)) || prices.find(function(p) { return p.model === v; });
            // Display names are metadata; matching one never makes an unknown backend priceable.
            // An unknown ID stays recognizable, without presenting it as a priced model.
            return price
              ? price.displayName
              : v
                  .replace(/^.*\//, "")
                  .replace(/[-_]/g, " ")
                  .replace(/\b\w/g, function (c) {
                    return c.toUpperCase();
                  });
          }
          if (k === "kind")
            return (KINDS.find(function (x) {
              return x[0] === v;
            }) || [v, v])[1];
          if (k === "outcome") return LABELS[v] || v;
          if (k === "provider" && v.indexOf("pi:") === 0) {
            var backend = v.slice(3);
            return ({openrouter: "OpenRouter", anthropic: "Anthropic", openai: "OpenAI", google: "Google", unknown: "Pi · unknown provider"})[backend] || backend.replace(/\b\w/g, function(c) { return c.toUpperCase(); });
          }
          if (k === "provider")
            return (
              {
                claude: "Claude Code",
                codex: "Codex",
                antigravity: "Antigravity",
                pi: "Pi",
                muse: "Muse",
                sail: "Sail",
                unknown: "Unknown provider"
              }[v] || v
            );
          if (k === "taskID") {
            var t = taskMap[v];
            return t
              ? (snapshot.projects[t.project] || "Task") +
                  (t.workNumber ? " #" + t.workNumber : " · " + v.slice(0, 8))
              : "Task " + v.slice(0, 8);
          }
          return v;
        }
        Object.keys(DIMENSIONS).forEach(function (k) {
          var ordered =
            k === "bot"
              ? snapshot.bots.map(function (_, i) {
                  return String(i);
                })
              : k === "account"
                ? snapshot.accounts.map(function (_, i) {
                    return String(i);
                  })
                : k === "project"
                  ? snapshot.projects.map(function (_, i) {
                      return String(i);
                    })
                  : [];
          var extra = Array.from(
            new Set(
              records.map(function (r) {
                return dimension(r, k);
              })
            )
          )
            .filter(function (v) {
              return ordered.indexOf(v) < 0;
            })
            .sort();
          dimensions[k] = ordered.concat(extra);
        });
        function color(k, v) {
          if (k === "outcome") return "var(--" + (v === "interrupted" ? "stopped" : v.toLowerCase()) + ")";
          if (
            v === "unknown" ||
            (k === "model" &&
              !records.some(function (r) {
                return dimension(r, k) === v && resolve(v, r);
              }))
          )
            return "var(--other)";
          var index = dimensions[k].indexOf(v);
          return "var(--" + (index >= 0 && index < 7 ? "s" + (index + 1) : "other") + ")";
        }
        function matches(r, filters) {
          var by = {};
          filters.forEach(function (f) {
            (by[f.k] || (by[f.k] = [])).push(f);
          });
          return Object.keys(by).every(function (k) {
            return by[k].some(function (f) {
              if (k === "records") {
                  if (!selectionSets.has(f)) selectionSets.set(f,new Set(f.ids));
                  return selectionSets.get(f).has(recordIndex.get(r));
                }
              if (k === "price") return (r.costProvenance || "unavailable") === f.v;
              if (k === "taskID") return r.taskID === f.v;
              return dimension(r, k) === f.v;
            });
          });
        }
        function range(from, through) {
          return records.filter(function (r) {
            return r.day >= from && r.day <= through && r.outcome !== "skipped";
          });
        }
        function aggregate(rows) {
          var a = summarize(rows, "0000-01-01", "9999-12-31", ALL_KINDS, null, snapshot.tasks);
          var buckets = ["uncachedInput", "cacheRead", "cacheWrite", "output"]
            .map(function (k) {
              return a.tokens[k];
            })
            .filter(function (v) {
              return v != null;
            });
          a.totalTokens = buckets.length
            ? buckets.reduce(function (a, b) {
                return a + b;
              }, 0)
            : null;
          return a;
        }
        function priceAt(tokens, price) {
          if (
            !price ||
            !tokens ||
            !Object.keys(tokens).some(function (k) {
              return (
                ["uncachedInput", "cacheRead", "cacheWrite", "cacheWrite1h", "output", "reasoning"].indexOf(k) >=
                  0 && typeof tokens[k] === "number"
              );
            })
          )
            return null;
          var input = tokens.uncachedInput || 0,
            read = tokens.cacheRead || 0,
            hour = tokens.cacheWrite1h || 0;
          var write = tokens.cacheWrite == null ? hour : tokens.cacheWrite,
            output = tokens.output == null ? tokens.reasoning || 0 : tokens.output;
          if (
            [input, read, hour, write, output].some(function (n) {
              return n < 0;
            }) ||
            hour > write ||
            (tokens.reasoning || 0) > output
          )
            return null;
          var rates = price.rates;
          (price.tiers || []).forEach(function (t) {
            if (input + read + write > t.aboveInput) rates = t.rates;
          });
          var pairs = [
              [input, rates.input],
              [read, rates.cacheRead],
              [write - hour, rates.cacheWrite],
              [hour, rates.cacheWrite1h == null ? 2 * rates.input : rates.cacheWrite1h],
              [output, rates.output]
            ],
            total = 0;
          for (var pair of pairs) {
            if (pair[0] > 0 && pair[1] == null) return null;
            total += pair[0] ? (pair[0] * pair[1]) / 1e6 : 0;
          }
          return isFinite(total) ? total : null;
        }
        // Explicit product families, never an ordering inferred from the dollar price.
        function nextModel(p) {
          var model = p.model,
            next = model.replace(/claude-opus/, "claude-sonnet");
          if (next === model) next = model.replace(/gpt-6-astra/, "gpt-6-sol");
          if (next === model) next = model.replace(/gemini-([\d.]+)-pro/, "gemini-$1-flash");
          return next === model
            ? null
            : prices.find(function (x) {
                return x.source === p.source && x.model === next;
              }) || null;
        }
        function comparison(r, mode, target) {
          if (!r.canReprice || r.cost == null || !(r.models || []).length) return null;
          var now = 0,
            alternative = 0;
          for (var usage of r.models) {
            var p = resolve(usage.model, r),
              q = mode === "swap" && p ? nextModel(p) : p;
            if (!p || !q) return null;
            var changed = Object.assign({}, usage);
            if (mode === "cache") {
              if (usage.uncachedInput == null || usage.cacheRead == null) return null;
              var move = Math.min(
                usage.uncachedInput,
                Math.max(
                  0,
                  target *
                    (usage.uncachedInput + usage.cacheRead + (usage.cacheWrite || usage.cacheWrite1h || 0)) -
                    usage.cacheRead
                )
              );
              changed.uncachedInput -= move;
              changed.cacheRead += move;
            }
            var current = priceAt(usage, p),
              alt = priceAt(changed, q);
            if (current == null || alt == null) return null;
            now += current;
            alternative += alt;
          }
          return Math.max(0, now - alternative);
        }
        function metric(rows, spec) {
          if (spec.mode === "spend") return aggregate(rows).cost;
          if (spec.mode === "fanout") {
            var parent = aggregate(
              rows.filter(function (r) {
                return r.kind === "task";
              })
            ).cost;
            var child = aggregate(
              rows.filter(function (r) {
                return r.kind === "subagent";
              })
            ).cost;
            return parent == null || child == null ? null : Math.max(0, child - parent);
          }
          var values = rows
            .map(function (r) {
              return comparison(r, spec.mode, spec.target);
            })
            .filter(function (v) {
              return v != null;
            });
          return values.length
            ? values.reduce(function (a, b) {
                return a + b;
              }, 0)
            : null;
        }
        function insights(from, through) {
          var rows = range(from, through),
            cards = [];
          function card(id, title, selected, mode, unit, fact, target) {
            var spec = { mode: mode, target: target },
              value = metric(selected, spec);
            cards.push({
              id: id,
              title: title,
              filters: [
                {
                  k: "records",
                  v: id,
                  ids: selected.map(function (r) {
                    return recordIndex.get(r);
                  }),
                  label: title
                }
              ],
              spec: spec,
              value: value,
              estimated: mode !== "spend" || aggregate(selected).costProvenance === "estimated",
              unit: unit,
              fact: fact
            });
          }
          var retried = rows.filter(function (r) {
            return (
              r.taskID &&
              ["failed", "stopped", "interrupted"].indexOf(r.outcome) >= 0 &&
              r.startedAt &&
              records.some(function (next) {
                return (
                  next.taskID === r.taskID &&
                  next.kind !== "subagent" &&
                  next.startedAt &&
                  next.startedAt > r.startedAt &&
                  next.day <= through
                );
              })
            );
          });
          card(
            "retry",
            "Retried turns & runs",
            retried,
            "spend",
            "redone",
            retried.length + " failed or stopped turns & runs"
          );
          var bots = dimensions.bot
            .map(function (b) {
              var own = rows.filter(function (r) {
                  return dimension(r, "bot") === b;
                }),
                others = aggregate(
                  rows.filter(function (r) {
                    return dimension(r, "bot") !== b;
                  })
                ).cacheHitRate;
              var selected = own.filter(function (r) {
                return others != null && comparison(r, "cache", others) != null;
              });
              return {
                bot: b,
                rows: selected,
                target: others,
                impact: metric(selected, { mode: "cache", target: others }),
                rate: aggregate(own).cacheHitRate
              };
            })
            .sort(function (a, b) {
              return (b.impact || 0) - (a.impact || 0);
            });
          var low = bots[0];
          card(
            "cache",
            low ? label("bot", low.bot) + " · low cache hit" : "Low cache hit by bot",
            low ? low.rows : [],
            "cache",
            "potential savings",
            low ? formatPercent(low.rate) + " hit · others " + formatPercent(low.target) : "No comparable usage",
            low && low.target
          );
          var grouped = Object.keys(taskMap).map(function (id) {
            var selected = rows.filter(function (r) {
              return r.taskID === id && ["task", "subagent"].indexOf(r.kind) >= 0;
            });
            return {
              id: id,
              rows: selected,
              spend: aggregate(selected).cost,
              gap: metric(selected, { mode: "fanout" })
            };
          });
          var fan = grouped
            .filter(function (t) {
              return (
                t.gap > 0 &&
                t.rows.every(function (r) {
                  return r.cost != null;
                })
              );
            })
            .sort(function (a, b) {
              return b.gap - a.gap;
            })[0];
          card(
            "fanout",
            "Sub-agents outspent their task",
            fan ? fan.rows : [],
            "fanout",
            "over the parent",
            fan ? label("taskID", fan.id) : "No fully priced fan-out"
          );
          var finished = grouped
            .filter(function (t) {
              return taskMap[t.id].latest === "finished" && t.spend != null;
            })
            .sort(function (a, b) {
              return b.spend - a.spend;
            })[0];
          card(
            "finished",
            "Costliest finished task",
            finished ? finished.rows : [],
            "spend",
            "spent",
            finished ? label("taskID", finished.id) : "No finished task spend"
          );
          var eligible = rows.filter(function (r) {
            return comparison(r, "swap") != null;
          });
          var short = eligible.filter(function (r) {
            return r.tokens.output != null && r.tokens.output < 2000 &&
              r.models.every(function(usage) { return typeof usage.output === "number"; });
          });
          card(
            "short",
            "Top models under 2K output",
            short,
            "swap",
            "potential savings",
            short.length + " turns & runs · next model in family"
          );
          var jobs = eligible.filter(function (r) {
            return r.kind === "job";
          });
          card(
            "jobs",
            "Job runs on top models",
            jobs,
            "swap",
            "potential savings",
            jobs.length + " job runs · next model in family"
          );
          return cards.sort(function (a, b) {
            return (b.value == null ? -1 : b.value) - (a.value == null ? -1 : a.value);
          });
        }
        function groups(rows, k, sortKey, direction) {
          return dimensions[k]
            .map(function (v) {
              var selected = rows.filter(function (r) {
                return dimension(r, k) === v;
              });
              return { value: v, label: label(k, v), rows: selected, summary: aggregate(selected) };
            })
            .filter(function (g) {
              return g.rows.length;
            })
            .sort(function (a, b) {
              function value(g) {
                return sortKey === "name"
                  ? g.label
                  : sortKey === "finished"
                    ? g.summary.outcomes.finished || 0
                    : sortKey === "share"
                      ? g.summary.cost
                      : g.summary[sortKey];
              }
              var av = value(a),
                bv = value(b);
              return av == null
                ? bv == null
                  ? 0
                  : 1
                : bv == null
                  ? -1
                  : (typeof av === "string" ? av.localeCompare(bv) : av - bv) * direction;
            });
        }
        return {
          records: records,
          dimensions: dimensions,
          dimension: dimension,
          label: label,
          color: color,
          matches: matches,
          range: range,
          aggregate: aggregate,
          priceAt: priceAt,
          resolve: resolve,
          comparison: comparison,
          metric: metric,
          insights: insights,
          groups: groups
        };
      }
      var api = {
        days: days,
        addDays: addDays,
        median: median,
        summarize: summarize,
        formatDuration: formatDuration,
        formatPercent: formatPercent,
        measureText: measureText,
        createExplorer: createExplorer,
        money: money
      };
      root.BotChuAnalytics = api;
      if (typeof document === "undefined") return;
      function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) n.className = cls;
        if (text != null) n.textContent = String(text);
        return n;
      }
      function add(parent) {
        for (var i = 1; i < arguments.length; i++) if (arguments[i]) parent.appendChild(arguments[i]);
        return parent;
      }
      function button(text, action, cls) {
        var b = el("button", cls, text);
        b.type = "button";
        b.onclick = action;
        return b;
      }
      function svg(tag, attrs) {
        var n = document.createElementNS("http://www.w3.org/2000/svg", tag);
        Object.keys(attrs || {}).forEach(function (k) {
          n.setAttribute(k, attrs[k]);
        });
        return n;
      }
      var app = document.getElementById("app"),
        tooltip = document.getElementById("tooltip"),
        data;
      try {
        data = JSON.parse(document.getElementById("botchu-analytics-data").textContent);
      } catch (error) {
        app.textContent = "Its data couldn't be read.";
        return;
      }
      if (!data || data.version !== 2 || !Array.isArray(data.records)) {
        add(app, el("section", "card error", "It was made by another version of BotChu."));
        return;
      }
      var E = createExplorer(data),
        S = {
          from: addDays(data.today, -29),
          through: data.today,
          preset: "30",
          filters: [],
          stack: "model",
          g1: "bot",
          g2: "model",
          sort: "cost",
          direction: -1,
          open: new Set(),
          insight: null
        };
      var query = new URLSearchParams(location.search),
        theme = query.get("theme");
      if (theme === "dark" || theme === "light") document.documentElement.dataset.theme = theme;
      document.getElementById("generated").textContent =
        "Made " + new Date(data.generatedAt).toLocaleString() + " · days in " + data.timeZone;
      tooltip.className = "tip";
      function selected() {
        return E.range(S.from, S.through).filter(function (r) {
          return E.matches(r, S.filters);
        });
      }
      function same(filters) {
        return (
          filters.length === S.filters.length &&
          filters.every(function (f) {
            return S.filters.some(function (g) {
              return f.k === g.k && f.v === g.v;
            });
          })
        );
      }
      function addFilters(filters) {
        filters.forEach(function (f) {
          if (
            !S.filters.some(function (g) {
              return f.k === g.k && f.v === g.v;
            })
          )
            S.filters.push(f);
        });
        render();
      }
      function selectCard(card) {
        if (same(card.filters)) {
          S.filters = [];
          S.insight = null;
        } else {
          S.filters = card.filters.slice();
          S.insight = card;
        }
        render();
      }
      function swatch(color, provenance) {
        var n = el("i", "sw " + (provenance === "unpriced" ? "unp" : provenance === "estimated" ? "est" : "act"));
        n.style.setProperty("--c", color);
        return n;
      }
      function select(options, value, action, label) {
        var n = el("select");
        n.setAttribute("aria-label", label);
        options.forEach(function (o) {
          var x = el("option", null, o[1]);
          x.value = o[0];
          n.appendChild(x);
        });
        n.value = value;
        n.onchange = function () {
          action(n.value);
        };
        return n;
      }
      function table(headers, rows) {
        var t = el("table"),
          head = el("tr");
        headers.forEach(function (h) {
          add(head, el("th", null, h));
        });
        add(t, add(el("thead"), head));
        var b = el("tbody");
        rows.forEach(function (row) {
          var tr = el("tr");
          row.forEach(function (v) {
            add(tr, v && v.nodeType ? add(el("td"), v) : el("td", null, v));
          });
          add(b, tr);
        });
        return add(el("div", "table-wrap"), add(t, b));
      }
      function spend(a) {
        return money(a.cost, a.costProvenance === "estimated");
      }
      function split(a, total, color, cls) {
        var bar = el("span", cls || "split");
        [
          ["actualCost", "act"],
          ["estimatedCost", "est"]
        ].forEach(function (p) {
          if (a[p[0]] > 0) {
            var n = el("i", p[1]);
            n.style.setProperty("--c", color);
            if (cls === "track") n.style.width = (total ? (100 * a[p[0]]) / total : 0) + "%";
            else n.style.flex = a[p[0]];
            add(bar, n);
          }
        });
        return bar;
      }
      function clearRangeSelection() {
        S.insight = null;
        S.filters = S.filters.filter(function(f) { return f.k !== "records"; });
      }
      function toolbar(rows) {
        var bar = el("div", "bar"),
          row = el("div", "row"),
          seg = el("div", "seg");
        [
          ["7", "7 days"],
          ["30", "30 days"],
          ["90", "90 days"],
          ["all", "All"]
        ].forEach(function (p) {
          var b = button(
            p[1],
            function () {
              S.preset = p[0];
              S.through = data.today;
              S.from =
                p[0] === "all"
                  ? data.records.reduce(function (d, r) {
                      return r.day < d ? r.day : d;
                    }, data.today)
                  : addDays(data.today, 1 - Number(p[0]));
              clearRangeSelection();
              render();
            },
            "preset"
          );
          b.setAttribute("aria-pressed", String(S.preset === p[0]));
          add(seg, b);
        });
        add(row, seg);
        ["From", "Through"].forEach(function (label) {
          var input = el("input");
          input.type = "date";
          input.value = label === "From" ? S.from : S.through;
          input.setAttribute("aria-label", label);
          input.onchange = function () {
            if (!input.value) return;
            S[label === "From" ? "from" : "through"] = input.value;
            if (S.from > S.through) {
              var old = S.from;
              S.from = S.through;
              S.through = old;
            }
            S.preset = "custom";
            clearRangeSelection();
            render();
          };
          add(row, add(el("label", "dates", label + " "), input));
        });
        add(
          row,
          el("span", "spacer"),
          add(el("span", "pv"), swatch("var(--text-2)", "actual"), el("span", null, "Actual")),
          add(el("span", "pv"), swatch("var(--text-2)", "estimated"), el("span", null, "Estimated"))
        );
        ["unpriced", "unavailable"].forEach(function(provenance) {
          var count = rows.filter(function(r) { return (r.costProvenance || "unavailable") === provenance; }).length;
          var label = provenance === "unpriced" ? "Unpriced" : "Unavailable";
          add(row, add(button("", function() { addFilters([{k: "price", v: provenance}]); }, "pv"),
            swatch("var(--other)", "unpriced"), el("span", null, "— " + label + " · " + count)));
        });
        var chips = el("div", "row");
        S.filters.forEach(function (f, index) {
          var name =
            f.label ||
            (DIMENSIONS[f.k]
              ? DIMENSIONS[f.k] + " " + E.label(f.k, f.v)
              : f.k === "price"
                ? f.v === "unpriced" ? "Unpriced" : "Unavailable"
                : E.label(f.k, f.v));
          var chip = el("span", "chip", name);
          var remove = button("×", function () {
            S.filters.splice(index, 1);
            if (f.k === "records") S.insight = null;
            render();
          });
          remove.setAttribute("aria-label", "Remove " + name);
          add(chips, add(chip, remove));
        });
        var picker = el("select", "add");
        picker.setAttribute("aria-label", "Add filter");
        add(picker, el("option", null, "+ Filter"));
        Object.keys(DIMENSIONS).forEach(function (k) {
          var group = el("optgroup");
          group.label = DIMENSIONS[k];
          E.dimensions[k].forEach(function (v) {
            var o = el("option", null, E.label(k, v));
            o.value = JSON.stringify({ k: k, v: v });
            add(group, o);
          });
          add(picker, group);
        });
        picker.onchange = function () {
          if (picker.selectedIndex > 0) addFilters([JSON.parse(picker.value)]);
        };
        add(chips, picker);
        if (S.filters.length >= 2)
          add(
            chips,
            button(
              "Clear all",
              function () {
                S.filters = [];
                S.insight = null;
                render();
              },
              "clear"
            )
          );
        if (S.insight)
          add(
            chips,
            el(
              "span",
              "impact",
              S.insight.title +
                " · filtered impact: " +
                money(E.metric(rows, S.insight.spec), S.insight.estimated) +
                " " +
                S.insight.unit
            )
          );
        return add(bar, row, chips);
      }
      function kpis(rows) {
        var a = E.aggregate(rows),
          w = E.aggregate(
            rows.filter(function (r) {
              return ["failed", "stopped", "interrupted"].indexOf(r.outcome) >= 0;
            })
          ),
          tiles = el("section", "kpis");
        var length = dayNumber(S.through) - dayNumber(S.from) + 1,
          prior = E.aggregate(
            E.range(addDays(S.from, -length), addDays(S.from, -1)).filter(function (r) {
              return E.matches(r, S.filters);
            })
          );
        function delta(now, before, good, points) {
          if (now == null || before == null || before === 0) return el("span", "na", "—");
          var change = points ? (now - before) * 100 : (now / before - 1) * 100;
          return el(
            "span",
            (change >= 0 ? "up" : "down") + "-" + (change >= 0 === good ? "good" : "bad"),
            (change >= 0 ? "▲ " : "▼ ") +
              Math.abs(change).toFixed(points ? 1 : 0) +
              (points ? " pts" : "%") +
              " vs prior " +
              length +
              "d"
          );
        }
        function tile(label, value, detail, action) {
          var n = action ? button("", action, "tile go") : el("div", "tile");
          add(n, el("div", "l label", label), el("div", "v value", value));
          if (detail)
            add(n, detail.nodeType ? add(el("div", "d detail"), detail) : el("div", "d detail", detail));
          add(tiles, n);
          return n;
        }
        var cost = tile(
          "Spend",
          spend(a),
          (a.actualCost == null ? "—" : money(a.actualCost)) +
            " actual · " +
            (a.estimatedCost == null ? "—" : money(a.estimatedCost, true)) +
            " est."
        );
        add(cost, split(a, a.cost, "var(--text-2)"));
        if (a.unpriced) add(cost, el("div", "d", a.unpriced + " unpriced"));
        if (a.unavailable) add(cost, el("div", "d", a.unavailable + " unavailable"));
        tile("Tokens", compact(a.totalTokens), delta(a.totalTokens, prior.totalTokens, false, false));
        tile(
          "Cache hit rate",
          formatPercent(a.cacheHitRate),
          delta(a.cacheHitRate, prior.cacheHitRate, true, true)
        );
        tile(
          "Per finished task",
          money(a.costPerFinishedTask, a.costProvenance === "estimated"),
          a.finishedTasks + " tasks finished"
        );
        var wf = [
          { k: "outcome", v: "failed" },
          { k: "outcome", v: "stopped" },
          { k: "outcome", v: "interrupted" }
        ];
        var waste = tile(
          "Wasted spend",
          spend(w),
          (a.outcomes.failed || 0) +
            " failed · " +
            ((a.outcomes.stopped || 0) + (a.outcomes.interrupted || 0)) +
            " stopped",
          function () {
            if (
              wf.every(function (f) {
                return S.filters.some(function (g) {
                  return f.k === g.k && f.v === g.v;
                });
              })
            ) {
              S.filters = S.filters.filter(function (f) {
                return (
                  f.k !== "outcome" ||
                  !wf.some(function (w) {
                    return w.v === f.v;
                  })
                );
              });
              render();
            } else {
              S.filters = S.filters.filter(function(f) { return f.k !== "outcome"; });
              addFilters(wf);
            }
          }
        );
        waste.setAttribute(
          "aria-pressed",
          String(
            wf.every(function (f) {
              return S.filters.some(function (g) {
                return f.k === g.k && f.v === g.v;
              });
            })
          )
        );
        tile(
          "Turns & runs",
          a.runs,
          (a.outcomes.finished || 0) + " finished · " + formatPercent(a.failureRate) + " failure rate"
        );
        return tiles;
      }
      function chart(rows) {
        var card = el("section", "card"),
          head = add(
            el("div", "head"),
            el("h2", null, "Spend a day by"),
            select(
              Object.keys(DIMENSIONS).map(function (k) {
                return [k, DIMENSIONS[k].toLowerCase()];
              }),
              S.stack,
              function (v) {
                S.stack = v;
                render();
              },
              "Stack spend by"
            )
          );
        add(card, head);
        var legend = el("div", "legend"),
          groups = E.groups(rows, S.stack, "cost", -1);
        groups.forEach(function (g) {
          add(
            legend,
            add(
              el("span"),
              swatch(E.color(S.stack, g.value), g.summary.costProvenance),
              el("span", null, g.label),
              el("em", null, spend(g.summary))
            )
          );
        });
        add(card, legend);
        if (!rows.length) return add(card, el("p", "empty", "No turns or runs in this range."));
        var list = days(S.from, S.through),
          by = list.map(function (day) {
            var rs = rows.filter(function (r) {
              return r.day === day;
            });
            return { day: day, rows: rs, a: E.aggregate(rs) };
          }),
          W = 740,
          H = 316,
          L = 54,
          T = 8,
          B = 26,
          ih = H - T - B,
          iw = W - L - 4;
        var max = Math.max.apply(
            null,
            [0].concat(
              by.map(function (d) {
                return d.a.cost || 0;
              })
            )
          ),
          positiveMax = max > 0 ? max : 1,
          power = Math.pow(10, Math.floor(Math.log10(positiveMax))),
          top = Math.ceil(positiveMax / power) * power,
          tickPrecision = top < 1 ? Math.min(8, 2 - Math.floor(Math.log10(top))) : top < 4 ? 2 : 0;
        var box = el("div", "chart"),
          root = svg("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Spend a day" }),
          defs = svg("defs"),
          pattern = svg("pattern", {
            id: "est",
            width: 5,
            height: 5,
            patternUnits: "userSpaceOnUse",
            patternTransform: "rotate(45)"
          });
        add(
          pattern,
          svg("rect", { width: 5, height: 5, fill: "white" }),
          svg("rect", { width: 1.5, height: 5, fill: "black", "fill-opacity": 0.34 })
        );
        var mask = svg("mask", {
          id: "estimated-mask",
          maskUnits: "userSpaceOnUse",
          x: 0,
          y: 0,
          width: W,
          height: H
        });
        add(mask, svg("rect", { width: W, height: H, fill: "url(#est)" }));
        add(defs, pattern, mask);
        add(root, defs);
        for (var i = 0; i <= 4; i++) {
          var y = T + ih - (ih * i) / 4;
          add(root, svg("line", { x1: L, x2: W - 4, y1: y, y2: y, class: i ? "gl" : "base" }));
          var text = svg("text", { x: L - 7, y: y + 4, "text-anchor": "end", class: "axis" });
          text.textContent = "$" + ((top * i) / 4).toFixed(tickPrecision);
          add(root, text);
        }
        var band = iw / list.length,
          width = Math.max(0.5, Math.min(24, band * 0.65)),
          ordered = E.dimensions[S.stack];
        by.forEach(function (d, index) {
          var x = L + band * index + (band - width) / 2,
            y = T + ih,
            segments = [];
          ordered.forEach(function (v) {
            var a = E.aggregate(
              d.rows.filter(function (r) {
                return E.dimension(r, S.stack) === v;
              })
            );
            if (a.actualCost > 0) segments.push({ v: v, c: a.actualCost, est: false });
            if (a.estimatedCost > 0) segments.push({ v: v, c: a.estimatedCost, est: true });
          });
          segments.forEach(function (s, ix) {
            var h = (s.c / top) * ih,
              gap = ix && segments[ix - 1].v !== s.v ? Math.min(2, h / 2) : 0;
            y -= h;
            var rect = svg("rect", {
              x: x,
              y: y,
              width: width,
              height: Math.max(0, h - gap),
              rx: ix === segments.length - 1 ? 3 : 0,
              fill: E.color(S.stack, s.v)
            });
            if (s.est) rect.setAttribute("mask", "url(#estimated-mask)");
            add(root, rect);
          });
          if (index === list.length - 1 || index % Math.max(1, Math.ceil(list.length / 6)) === 0) {
            var label = svg("text", { x: x + width / 2, y: H - 6, "text-anchor": "middle", class: "axis" });
            label.textContent = d.day.slice(5);
            add(root, label);
          }
          var hit = svg("rect", {
            x: L + index * band,
            y: T,
            width: band,
            height: ih,
            class: "hit",
            tabindex: 0,
            "aria-label": d.day + " " + spend(d.a)
          });
          function show() {
            tooltip.textContent = "";
            add(tooltip, el("b", null, d.day + " · " + spend(d.a)));
            E.groups(d.rows, S.stack, "cost", -1).forEach(function (g) {
              add(
                tooltip,
                add(
                  el("div", "r"),
                  swatch(E.color(S.stack, g.value), g.summary.costProvenance),
                  el("span", null, g.label),
                  el("em", null, spend(g.summary))
                )
              );
            });
            tooltip.hidden = false;
            var rect = hit.getBoundingClientRect();
            tooltip.style.left = Math.max(8, Math.min(innerWidth - tooltip.offsetWidth - 8, rect.left)) + "px";
            tooltip.style.top = Math.max(8, rect.top - tooltip.offsetHeight - 8) + "px";
          }
          hit.onmouseenter = hit.onfocus = show;
          hit.onmouseleave = hit.onblur = function () {
            tooltip.hidden = true;
          };
          add(root, hit);
        });
        add(card, add(box, root));
        var details = add(el("details"), el("summary", null, "Show as a table"));
        add(
          details,
          table(
            ["Day", "Turns & runs", "Spend", "Unpriced", "Unavailable"],
            by
              .filter(function (d) {
                return d.rows.length;
              })
              .map(function (d) {
                return [d.day, d.a.runs, spend(d.a), d.a.unpriced, d.a.unavailable];
              })
          )
        );
        return add(card, details);
      }
      function tokensCard(rows) {
        var a = E.aggregate(rows),
          card = add(
            el("section", "card"),
            add(el("div", "head"), el("h2", null, "Token mix"), el("span", "tot", compact(a.totalTokens)))
          ),
          mix = el("div", "mix");
        var parts = [
          ["Input", "uncachedInput", "in"],
          ["Cache read", "cacheRead", "cr"],
          ["Cache write", "cacheWrite", "cw"],
          ["Output", "output", "out"]
        ];
        parts.forEach(function (p) {
          if (a.tokens[p[1]] > 0) {
            var n = el("i");
            n.style.flex = a.tokens[p[1]];
            n.style.background = "var(--t-" + p[2] + ")";
            n.title = p[0];
            add(mix, n);
          }
        });
        add(
          card,
          mix,
          table(
            ["", "Tokens", "Share"],
            parts
              .map(function (p) {
                return [
                  add(el("span", "row"), swatch("var(--t-" + p[2] + ")", "actual"), el("span", null, p[0])),
                  compact(a.tokens[p[1]]),
                  formatPercent(a.totalTokens && a.tokens[p[1]] != null ? a.tokens[p[1]] / a.totalTokens : null)
                ];
              })
              .concat([
                [
                  "Reasoning (in output)",
                  compact(a.tokens.reasoning),
                  formatPercent(
                    a.totalTokens && a.tokens.reasoning != null ? a.tokens.reasoning / a.totalTokens : null
                  )
                ]
              ])
          ),
          el("h3", null, "Cache hit by bot")
        );
        E.groups(rows, "bot", "cacheHitRate", -1).forEach(function (g) {
          var meter = el("span", "meter"),
            fill = el("i");
          fill.style.width = 100 * (g.summary.cacheHitRate || 0) + "%";
          fill.style.background = E.color("bot", g.value);
          add(
            card,
            add(
              el("div", "cache-row"),
              swatch(E.color("bot", g.value), "actual"),
              el("span", "spacer", g.label),
              add(meter, fill),
              el("span", null, formatPercent(g.summary.cacheHitRate))
            )
          );
        });
        return card;
      }
      function insights() {
        var section = add(el("section"), add(el("div", "head"), el("h2", null, "Efficiency"))),
          grid = el("div", "ins");
        E.insights(S.from, S.through).forEach(function (c, index) {
          var n = add(
            el("div", "in"),
            add(el("div", "t"), el("span", "rk", index + 1), el("span", null, c.title)),
            add(el("div", "n"), document.createTextNode(money(c.value, c.estimated)), el("small", null, c.unit)),
            el("div", "f", c.fact)
          );
          var b = button(
            same(c.filters) ? "Filtered ✓" : "Filter to these",
            function () {
              selectCard(c);
            },
            "go"
          );
          b.setAttribute("aria-pressed", String(same(c.filters)));
          b.title = S.filters.length && !same(c.filters) ? "Filter to these records (replaces current filters)" : "Filter to these records";
          b.setAttribute("aria-label", b.title + ": " + c.title);
          b.disabled = !c.filters[0].ids.length;
          add(grid, add(n, b));
        });
        return add(section, grid);
      }
      var COLS = [
        ["name", "Name"],
        ["runs", "Turns & runs"],
        ["finished", "Finished"],
        ["failureRate", "Failure rate"],
        ["totalTokens", "Tokens"],
        ["cacheHitRate", "Cache hit"],
        ["cost", "Spend"],
        ["costPerFinishedTask", "Per finished task"],
        ["medianSeconds", "Median time"],
        ["share", "Share of spend"]
      ];
      function breakdown(rows) {
        var choices = Object.keys(DIMENSIONS).filter(function (k) {
            return k !== "outcome";
          }),
          card = el("section", "card"),
          head = add(el("div", "head"), el("h2", null, "Breakdown")),
          controls = add(
            el("div", "ctl"),
            document.createTextNode("Group by "),
            select(
              choices.map(function (k) {
                return [k, DIMENSIONS[k].toLowerCase()];
              }),
              S.g1,
              function (v) {
                S.g1 = v;
                if (S.g1 === S.g2) S.g2 = "";
                S.open.clear();
                render();
              },
              "Group by"
            ),
            document.createTextNode(" then "),
            select(
              [["", "—"]].concat(
                choices
                  .filter(function (k) {
                    return k !== S.g1;
                  })
                  .map(function (k) {
                    return [k, DIMENSIONS[k].toLowerCase()];
                  })
              ),
              S.g2,
              function (v) {
                S.g2 = v;
                render();
              },
              "Then group by"
            )
          );
        add(card, add(head, controls));
        var t = el("table");
        t.id = "ex";
        var tr = el("tr");
        COLS.forEach(function (c) {
          var th = add(
            el("th"),
            button(c[1], function () {
              S.direction = S.sort === c[0] ? -S.direction : c[0] === "name" ? 1 : -1;
              S.sort = c[0];
              render();
            })
          );
          if (S.sort === c[0]) th.setAttribute("aria-sort", S.direction < 0 ? "descending" : "ascending");
          add(tr, th);
        });
        add(t, add(el("thead"), tr));
        var body = el("tbody"),
          total = E.aggregate(rows);
        function cells(tr, a, color) {
          [
            a.runs,
            a.outcomes.finished || 0,
            formatPercent(a.failureRate),
            compact(a.totalTokens),
            formatPercent(a.cacheHitRate),
            spend(a),
            money(a.costPerFinishedTask, a.costProvenance === "estimated"),
            a.medianSeconds == null ? "—" : formatDuration(a.medianSeconds)
          ].forEach(function (v) {
            add(tr, el("td", null, v));
          });
          var share = el("span", "share");
          if (a.cost != null) add(share, split(a, total.cost, color, "track"));
          else add(share, swatch("var(--other)", "unpriced"));
          add(
            share,
            el("span", null, formatPercent(a.cost != null && total.cost > 0 ? a.cost / total.cost : null))
          );
          add(tr, add(el("td"), share));
        }
        function row(g, parent) {
          var child = parent != null,
            k = child ? S.g2 : S.g1,
            tr = el("tr", child ? "child" : null),
            name = el("td"),
            filters = child
              ? [
                  { k: S.g1, v: parent },
                  { k: S.g2, v: g.value }
                ]
              : [{ k: S.g1, v: g.value }],
            title = button(
              g.label,
              function () {
                addFilters(filters);
              },
              "row-filter"
            );
          if (k === "model") tr.title = g.value;
          if (!child) {
            var tw = button(
              "▸",
              function () {
                S.open.has(g.value) ? S.open.delete(g.value) : S.open.add(g.value);
                render();
              },
              "tw" + (S.g2 ? "" : " ph")
            );
            tw.setAttribute("aria-expanded", String(S.open.has(g.value)));
            tw.setAttribute("aria-label", "Expand " + g.label);
            add(name, add(el("span", "nm"), tw, swatch(E.color(k, g.value), g.summary.costProvenance), title));
          } else add(name, title);
          add(tr, name);
          cells(tr, g.summary, child ? "var(--muted)" : E.color(k, g.value));
          tr.onclick = function (e) {
            if (!e.target.closest("button")) addFilters(filters);
          };
          add(body, tr);
        }
        E.groups(rows, S.g1, S.sort, S.direction).forEach(function (g) {
          row(g);
          if (S.g2 && S.open.has(g.value))
            E.groups(g.rows, S.g2, S.sort, S.direction).forEach(function (c) {
              row(c, g.value);
            });
        });
        var foot = add(el("tr"), el("td", null, "Total"));
        cells(foot, total, "var(--text-2)");
        add(t, body, add(el("tfoot"), foot));
        return add(card, add(el("div", "table-wrap"), t));
      }
      function allowance(rows) {
        var card = add(el("section", "card"), el("h2", null, "Provider allowance")),
          profiles = data.allowance || [];
        // Allowance is a current account reading; narrow it to the accounts represented by chips.
        if (S.filters.length) {
          var names = new Set(
            rows.map(function (r) {
              return (data.accounts[r.account] || {}).name;
            })
          );
          profiles = profiles.filter(function (p) {
            return names.has(p.account);
          });
        }
        function windows(profile, test) {
          var box = el("span", "allowance-windows"),
            found = profile.windows.filter(function (w) {
              return test.test(w.title);
            });
          if (!found.length) return el("span", null, "—");
          found.forEach(function (w) {
            var n = el("span", "allowance-window"),
              value = w.hasReset ? "Reset since" : w.usedPercent == null ? "—" : Math.round(w.usedPercent) + "%";
            if (w.usedPercent != null && !w.hasReset) {
              var meter = el("span", "meter" + (w.usedPercent >= 80 ? " hot" : "")),
                fill = el("i");
              fill.style.width = Math.min(100, Math.max(0, w.usedPercent)) + "%";
              add(n, add(meter, fill));
            }
            add(n, el("span", null, (w.usedPercent >= 80 && !w.hasReset ? "⚠ " : "") + value));
            n.title = w.title + (w.resetsAt ? " · resets " + new Date(w.resetsAt).toLocaleString() : "");
            add(box, n);
          });
          return box;
        }
        if (!profiles.length) return add(card, el("p", "empty", "No allowance readings for these accounts."));
        return add(
          card,
          table(
            ["Profile", "5-hour", "Weekly", "Other windows"],
            profiles.map(function (p) {
              var name = el("span", null, p.account);
              if (p.status !== "current")
                add(name, el("span", "badge", p.status === "stale" ? "Stale" : "No reading"));
              return [name, windows(p, /5.hour/i), windows(p, /week/i), windows(p, /^(?!.*(?:5.hour|week)).*$/i)];
            })
          )
        );
      }
      function about() {
        var details = add(el("details", "card about"), el("summary", null, "About these numbers")),
          dl = el("dl");
        [
          [
            "Spend",
            "Actual is provider-reported billing. Estimated uses list prices dated " +
              data.priceSnapshotDate +
              ". Missing prices show —; known subtotals can coexist with unpriced runs. Subscription charges and allowances are separate."
          ],
          [
            "Tokens",
            "Input, cache reads, cache writes and output are disjoint. Reasoning is included in output; one-hour writes are included in cache writes. Missing counts stay unknown. Cache hit = cache read ÷ all input."
          ],
          [
            "Work",
            "Finished means the turn ended without an error. Per finished task includes its recorded turns and sub-agents in this range. Wasted spend covers failed, stopped and interrupted runs. Skipped jobs are excluded."
          ],
          [
            "Efficiency",
            "Cards use the date range, independent of chips. Retried means the same task ran again later. Savings reprice complete token buckets at list prices: Opus → Sonnet, GPT-6 Astra → GPT-6 Sol, Gemini Pro → Flash in the same version. Cache savings use other bots’ cache rate. Unknown comparisons remain —."
          ],
          [
            "Days & history",
            "Calendar days in " +
              data.timeZone +
              " are assigned by start time. Durations omit unknown times. Older records may be missing after deletion or history retention; task outcomes are their latest saved state."
          ],
          [
            "Access",
            "This private local file loads nothing. It contains names and aggregate usage, never messages, prompts, replies, tool output or credentials. Provider allowance is the latest saved account reading."
          ]
        ].forEach(function (pair) {
          add(dl, el("dt", null, pair[0]), el("dd", null, pair[1]));
        });
        return add(details, dl);
      }
      function render() {
        tooltip.hidden = true;
        app.textContent = "";
        var rows = selected();
        add(app, toolbar(rows));
        var problems = (data.coverage && data.coverage.problems) || [];
        if (problems.length) {
          var callout = add(el("section", "callout"), el("strong", null, "Not everything could be read")),
            list = el("ul");
          problems.forEach(function (p) {
            add(list, el("li", null, p));
          });
          add(app, add(callout, list));
        }
        if (!data.records.length) add(app, el("h2", "empty", "No activity recorded yet"));
        add(
          app,
          kpis(rows),
          add(el("div", "grid2"), chart(rows), tokensCard(rows)),
          insights(),
          breakdown(rows),
          allowance(rows),
          about()
        );
      }
      render();
    })(typeof globalThis !== "undefined" ? globalThis : this);
    """#
}
