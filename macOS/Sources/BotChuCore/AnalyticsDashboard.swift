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
      color-scheme: light;
      --page: #f9f9f7; --surface: #fcfcfb; --text: #0b0b0b; --text-2: #52514e; --muted: #75736d;
      --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11, 11, 11, 0.10); --wash: rgba(11, 11, 11, 0.05);
      --finished: #2a78d6; --failed: #d03b3b; --stopped: #ec835a; --inProgress: #a8a69f;
      --line: #2a78d6; --warn: #fab219; --warn-bg: #fdf3dc; --accent: #2a78d6;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        color-scheme: dark;
        --page: #0d0d0d; --surface: #1a1a19; --text: #f0efec; --text-2: #c3c2b7; --muted: #9a988f;
        --grid: #2c2c2a; --axis: #383835; --border: rgba(255, 255, 255, 0.10); --wash: rgba(255, 255, 255, 0.06);
        --finished: #3987e5; --failed: #d03b3b; --stopped: #ec835a; --inProgress: #6f6d68;
        --line: #3987e5; --warn: #fab219; --warn-bg: #2b2412; --accent: #3987e5;
      }
    }
    :root[data-theme="dark"] {
      color-scheme: dark;
      --page: #0d0d0d; --surface: #1a1a19; --text: #f0efec; --text-2: #c3c2b7; --muted: #9a988f;
      --grid: #2c2c2a; --axis: #383835; --border: rgba(255, 255, 255, 0.10); --wash: rgba(255, 255, 255, 0.06);
      --finished: #3987e5; --failed: #d03b3b; --stopped: #ec835a; --inProgress: #6f6d68;
      --line: #3987e5; --warn: #fab219; --warn-bg: #2b2412; --accent: #3987e5;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--page); color: var(--text); }
    body { font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
    .top, main { max-width: 1180px; margin: 0 auto; padding: 0 16px; }
    .top { padding-top: 24px; padding-bottom: 8px; }
    h1 { font-size: 22px; margin: 0; font-weight: 650; }
    h2 { font-size: 15px; margin: 0 0 4px; font-weight: 600; }
    h3 { font-size: 13px; margin: 16px 0 4px; font-weight: 600; }
    p { margin: 0 0 8px; }
    .sub, .note { color: var(--text-2); font-size: 12.5px; }
    .note { margin: 0 0 12px; }
    .filters { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; padding: 12px 0 16px; }
    .group { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
    .group-label { color: var(--text-2); font-size: 12.5px; margin-right: 2px; }
    button.preset { font: inherit; font-size: 13px; color: var(--text); background: var(--surface); border: 1px solid var(--border);
      border-radius: 6px; padding: 4px 10px; cursor: pointer; }
    button.preset:hover { background: var(--wash); }
    button.preset[aria-pressed="true"] { border-color: var(--accent); box-shadow: inset 0 0 0 1px var(--accent); font-weight: 600; }
    input[type="date"] { font: inherit; font-size: 13px; color: var(--text); background: var(--surface); border: 1px solid var(--border);
      border-radius: 6px; padding: 3px 6px; }
    label.kind { display: inline-flex; align-items: center; gap: 4px; font-size: 13px; }
    .card { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 16px; margin-bottom: 16px; min-width: 0; }
    .callout { background: var(--warn-bg); border: 1px solid var(--border); border-left: 4px solid var(--warn); border-radius: 8px;
      padding: 10px 12px; margin-bottom: 16px; }
    .callout ul { margin: 4px 0 0 18px; padding: 0; }
    .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(165px, 1fr)); gap: 12px; margin-bottom: 16px; }
    .tile { background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; min-width: 0; }
    .tile .label { color: var(--text-2); font-size: 12.5px; }
    .tile .value { font-size: 24px; font-weight: 600; margin-top: 2px; overflow-wrap: anywhere; }
    .tile .value.unavailable { font-size: 17px; color: var(--text-2); font-weight: 500; padding: 5px 0 2px; }
    .tile .detail { color: var(--text-2); font-size: 12px; margin-top: 2px; }
    .grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 440px), 1fr)); gap: 16px; }
    .legend { display: flex; flex-wrap: wrap; gap: 4px 14px; margin: 6px 0 4px; font-size: 12.5px; color: var(--text-2); }
    .legend span { display: inline-flex; align-items: center; gap: 6px; }
    .key { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }
    .key.line { width: 14px; height: 2px; border-radius: 1px; }
    .chart { position: relative; width: 100%; }
    .chart svg { display: block; width: 100%; height: auto; overflow: visible; }
    .chart .axis-text { fill: var(--muted); font-size: 11px; font-variant-numeric: tabular-nums; }
    .chart .grid { stroke: var(--grid); stroke-width: 1; shape-rendering: crispEdges; }
    .chart .base { stroke: var(--axis); stroke-width: 1; shape-rendering: crispEdges; }
    .chart .hit { fill: transparent; cursor: default; }
    .chart .hit:hover, .chart .hit:focus { fill: var(--wash); outline: none; }
    .empty { color: var(--text-2); padding: 28px 8px; text-align: center; }
    .table-wrap { width: 100%; overflow-x: auto; }
    table { border-collapse: collapse; width: 100%; font-size: 13px; }
    th, td { text-align: right; padding: 6px 8px; border-bottom: 1px solid var(--grid); white-space: nowrap; font-variant-numeric: tabular-nums; }
    th { color: var(--text-2); font-weight: 500; font-size: 12px; }
    th:first-child, td:first-child { text-align: left; white-space: normal; min-width: 140px; }
    table.text th, table.text td { text-align: left; }
    td.dim { color: var(--text-2); }
    details summary { cursor: pointer; color: var(--text-2); font-size: 12.5px; margin-top: 8px; }
    .meter { display: inline-block; width: 64px; height: 6px; border-radius: 3px; background: var(--grid); vertical-align: middle; margin-right: 6px; overflow: hidden; }
    .meter > i { display: block; height: 100%; background: var(--accent); border-radius: 3px; }
    .badge { display: inline-block; font-size: 11px; padding: 0 6px; border-radius: 9px; border: 1px solid var(--border); color: var(--text-2); }
    .about dt { font-weight: 600; margin-top: 10px; }
    .about dd { margin: 2px 0 0; color: var(--text-2); }
    .about ul { margin: 4px 0 0 18px; padding: 0; color: var(--text-2); }
    .error { border-left: 4px solid var(--failed); }
    .tooltip { position: fixed; z-index: 10; pointer-events: none; background: var(--surface); color: var(--text); border: 1px solid var(--border);
      border-radius: 8px; padding: 8px 10px; font-size: 12px; box-shadow: 0 4px 16px rgba(0, 0, 0, 0.12); max-width: 260px; }
    .tooltip .t-title { color: var(--text-2); margin-bottom: 4px; }
    .tooltip .t-row { display: flex; align-items: center; gap: 8px; }
    .tooltip .t-row b { font-variant-numeric: tabular-nums; min-width: 28px; }
    .tooltip .t-row .key.line { flex: none; }
    """#

    /// The page's script. Its first part only works numbers out (`BotChuAnalytics`), as
    /// `AnalyticsSummary` does, so it runs without a page too; the rest draws the page with DOM
    /// calls and `textContent`, never markup made from the data.
    public static let script = #"""
    (function (root) {
      "use strict";
      var OUTCOMES = ["finished", "failed", "stopped", "interrupted", "inProgress"];
      var LABELS = { finished: "Finished", failed: "Failed", stopped: "Stopped", interrupted: "Interrupted",
        inProgress: "In progress", skipped: "Skipped" };
      var KINDS = [["home", "Home turns"], ["task", "Task turns"], ["job", "Job runs"], ["subagent", "Sub-agent runs"]];
      /* What the daily chart stacks, bottom up: a job run a quit cut short is charted with the stopped ones. */
      var SERIES = [["finished", "Finished"], ["failed", "Failed"], ["stopped", "Stopped or interrupted"], ["inProgress", "In progress"]];
      function seriesCount(summary, series) {
        return (summary.outcomes[series] || 0) + (series === "stopped" ? summary.outcomes.interrupted || 0 : 0);
      }

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
      function summarize(records, from, through, kinds, include) {
        var summary = { runs: 0, outcomes: {}, skipped: 0, ended: 0, failureRate: null, timed: 0, medianSeconds: null, totalSeconds: 0 };
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

      var api = { days: days, addDays: addDays, median: median, summarize: summarize, formatDuration: formatDuration,
        formatPercent: formatPercent, measureText: measureText };
      root.BotChuAnalytics = api;
      if (typeof document === "undefined") { return; }

      var SVG = "http://www.w3.org/2000/svg";
      var app = document.getElementById("app");
      var tooltip = document.getElementById("tooltip");
      var data = null;

      function el(tag, className, text) {
        var node = document.createElement(tag);
        if (className) { node.className = className; }
        if (text !== undefined && text !== null) { node.textContent = String(text); }
        return node;
      }
      function add(parent) {
        for (var i = 1; i < arguments.length; i++) { if (arguments[i]) { parent.appendChild(arguments[i]); } }
        return parent;
      }
      function svg(tag, attributes) {
        var node = document.createElementNS(SVG, tag);
        Object.keys(attributes || {}).forEach(function (key) {
          /* Colors are the page's variables, which only style takes. */
          if (key === "fill" || key === "stroke") { node.style[key] = attributes[key]; } else { node.setAttribute(key, attributes[key]); }
        });
        return node;
      }
      function color(series) { return "var(--" + series + ")"; }
      /* A swatch in the legend; a short line in a tooltip. */
      function key(series, line) {
        var node = el("span", "key" + (line ? " line" : ""));
        node.style.background = color(series);
        return node;
      }
      function dayLabel(day, withWeekday) {
        var p = day.split("-");
        var date = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2], 12));
        var options = { month: "short", day: "numeric", timeZone: "UTC" };
        if (withWeekday) { options.weekday = "short"; options.year = "numeric"; }
        return date.toLocaleDateString(undefined, options);
      }
      function when(iso) {
        return iso ? new Date(iso).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "—";
      }
      function fail(message) {
        app.textContent = "";
        var card = add(el("section", "card error"), el("h2", null, "The dashboard couldn't be shown"), el("p", null, message),
          el("p", "note", "Choose View ▸ Open Analytics Dashboard in BotChu to make it again."));
        app.appendChild(card);
      }

      try {
        data = JSON.parse(document.getElementById("botchu-analytics-data").textContent);
      } catch (error) {
        fail("Its data couldn't be read.");
        return;
      }
      if (!data || data.version !== 1 || !Array.isArray(data.records)) {
        fail("It was made by another version of BotChu.");
        return;
      }

      var records = data.records, tasks = data.tasks || [];
      var byDay = {};
      records.forEach(function (record) { (byDay[record.day] = byDay[record.day] || []).push(record); });
      var today = data.today;
      var firstDay = today, lastDay = today;
      records.concat(tasks).forEach(function (item) {
        if (item.day < firstDay) { firstDay = item.day; }
        if (item.day > lastDay) { lastDay = item.day; }
      });
      document.getElementById("generated").textContent = "Made " + when(data.generatedAt) + " · days in "
        + data.timeZone + " · read-only: choose View ▸ Open Analytics Dashboard in BotChu for current data";

      var state = { preset: "30", from: addDays(today, -29), through: today, kinds: { home: true, task: true, job: true, subagent: true } };
      function setPreset(preset) {
        state.preset = preset;
        state.through = lastDay > today ? lastDay : today;
        state.from = preset === "all" ? firstDay : addDays(today, -(Number(preset) - 1));
        render();
      }

      /* Tooltip: the same details on hover and keyboard focus. */
      function showTip(target, title, rows) {
        tooltip.textContent = "";
        add(tooltip, el("div", "t-title", title));
        rows.forEach(function (row) {
          var line = el("div", "t-row");
          if (row.series) { add(line, key(row.series, true)); }
          add(line, el("b", null, row.value), el("span", null, row.label));
          tooltip.appendChild(line);
        });
        tooltip.hidden = false;
        var box = target.getBoundingClientRect(), tip = tooltip.getBoundingClientRect();
        var left = Math.min(window.innerWidth - tip.width - 8, Math.max(8, box.left + box.width / 2 - tip.width / 2));
        var top = box.top - tip.height - 8;
        if (top < 8) { top = box.bottom + 8; }
        tooltip.style.left = left + "px";
        tooltip.style.top = top + "px";
      }
      function hideTip() { tooltip.hidden = true; }

      function niceStep(raw) {
        if (raw <= 0) { return 1; }
        var power = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10));
        var steps = [1, 2, 5, 10];
        for (var i = 0; i < steps.length; i++) { if (raw <= steps[i] * power) { return steps[i] * power; } }
        return 10 * power;
      }
      function ticks(max) {
        var step = Math.max(1, niceStep(max / 4));
        var top = Math.max(step, Math.ceil(max / step) * step);
        var out = [];
        for (var v = 0; v <= top + step / 2; v += step) { out.push(v); }
        return out;
      }
      function frame(width, height) {
        return { width: width, height: height, left: 60, right: 12, top: 10, bottom: 26,
          plotWidth: Math.max(10, width - 72), plotHeight: height - 36 };
      }
      function axis(chart, f, values, label) {
        var top = values[values.length - 1] || 1;
        values.forEach(function (value) {
          var y = f.top + f.plotHeight - value / top * f.plotHeight;
          chart.appendChild(svg("line", { "class": value === 0 ? "base" : "grid", x1: f.left, x2: f.left + f.plotWidth, y1: y, y2: y }));
          var text = svg("text", { "class": "axis-text", x: f.left - 6, y: y + 4, "text-anchor": "end" });
          text.textContent = label(value);
          chart.appendChild(text);
        });
        return top;
      }
      function xLabels(chart, f, list, band) {
        var count = Math.min(list.length, Math.max(2, Math.floor(f.plotWidth / 90)));
        var seen = {};
        for (var i = 0; i < count; i++) {
          var index = count === 1 ? 0 : Math.round(i * (list.length - 1) / (count - 1));
          if (seen[index]) { continue; }
          seen[index] = true;
          var x = f.left + index * band + band / 2;
          var text = svg("text", { "class": "axis-text", x: x, y: f.top + f.plotHeight + 17,
            "text-anchor": list.length === 1 ? "middle" : index === 0 ? "start" : index === list.length - 1 ? "end" : "middle" });
          text.textContent = dayLabel(list[index]);
          chart.appendChild(text);
        }
      }
      function barPath(x, y, width, height, radius) {
        var r = Math.min(radius, width / 2, height);
        return "M" + x + "," + (y + height) + "V" + (y + r) + "Q" + x + "," + y + " " + (x + r) + "," + y + "H" + (x + width - r)
          + "Q" + (x + width) + "," + y + " " + (x + width) + "," + (y + r) + "V" + (y + height) + "Z";
      }

      /* Turns and runs a day, stacked by outcome, bottom up. */
      function volumeChart(container, list, perDay) {
        var width = Math.max(320, container.clientWidth || 640);
        var f = frame(width, 240);
        var chart = svg("svg", { viewBox: "0 0 " + width + " " + f.height, role: "img",
          "aria-label": "Turns and runs a day by outcome; the table below has the same numbers" });
        var max = 0;
        list.forEach(function (day) { max = Math.max(max, perDay[day].runs); });
        var top = axis(chart, f, ticks(max), function (v) { return String(v); });
        var band = f.plotWidth / list.length;
        var barWidth = Math.max(1, Math.min(24, band * 0.7));
        list.forEach(function (day, index) {
          var summary = perDay[day];
          var x = f.left + index * band + (band - barWidth) / 2;
          var y = f.top + f.plotHeight;
          var drawn = SERIES.filter(function (series) { return seriesCount(summary, series[0]); });
          drawn.forEach(function (series, position) {
            var height = seriesCount(summary, series[0]) / top * f.plotHeight;
            var gap = position > 0 && height > 3 ? 2 : 0;
            y -= height;
            var shown = Math.max(0.75, height - gap);
            var mark = position === drawn.length - 1
              ? svg("path", { d: barPath(x, y, barWidth, shown, 4) })
              : svg("rect", { x: x, y: y, width: barWidth, height: shown });
            mark.style.fill = color(series[0]);
            chart.appendChild(mark);
          });
          var hit = svg("rect", { "class": "hit", x: f.left + index * band, y: f.top, width: band, height: f.plotHeight, tabindex: "0" });
          var rows = OUTCOMES.filter(function (o) { return summary.outcomes[o]; })
            .map(function (o) { return { series: o === "interrupted" ? "stopped" : o, value: summary.outcomes[o], label: LABELS[o] }; });
          if (summary.skipped) { rows.push({ value: summary.skipped, label: "Skipped job times (not runs)" }); }
          if (!rows.length) { rows.push({ value: "0", label: "turns or runs" }); }
          var show = function () { showTip(hit, dayLabel(day, true), rows); };
          hit.addEventListener("pointerenter", show);
          hit.addEventListener("focus", show);
          hit.addEventListener("pointerleave", hideTip);
          hit.addEventListener("blur", hideTip);
          chart.appendChild(hit);
        });
        xLabels(chart, f, list, band);
        container.appendChild(chart);
      }

      /* The median duration a day, with gaps on days without a known duration (never drawn as zero). */
      function durationChart(container, list, perDay) {
        var width = Math.max(320, container.clientWidth || 640);
        var f = frame(width, 240);
        var chart = svg("svg", { viewBox: "0 0 " + width + " " + f.height, role: "img",
          "aria-label": "Median duration a day; days without a known duration are gaps" });
        var max = 0;
        list.forEach(function (day) { if (perDay[day].medianSeconds !== null) { max = Math.max(max, perDay[day].medianSeconds); } });
        var unit = max < 60 ? 1 : max < 3600 ? 60 : 3600;
        var values = ticks(max / unit).map(function (v) { return v * unit; });
        var top = axis(chart, f, values, function (v) { return v === 0 ? "0" : formatDuration(v); });
        var band = f.plotWidth / list.length;
        var path = "", open = false, points = [];
        list.forEach(function (day, index) {
          var value = perDay[day].medianSeconds;
          if (value === null) { open = false; return; }
          var x = f.left + index * band + band / 2, y = f.top + f.plotHeight - value / top * f.plotHeight;
          path += (open ? "L" : "M") + x.toFixed(1) + "," + y.toFixed(1);
          open = true;
          points.push({ x: x, y: y });
        });
        if (path) {
          chart.appendChild(svg("path", { d: path, fill: "none", stroke: "var(--line)", "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }));
        }
        points.forEach(function (point) {
          chart.appendChild(svg("circle", { cx: point.x, cy: point.y, r: 4, fill: "var(--line)", stroke: "var(--surface)", "stroke-width": 2 }));
        });
        var cross = svg("line", { "class": "grid", x1: 0, x2: 0, y1: f.top, y2: f.top + f.plotHeight, visibility: "hidden" });
        chart.appendChild(cross);
        list.forEach(function (day, index) {
          var summary = perDay[day];
          var hit = svg("rect", { "class": "hit", x: f.left + index * band, y: f.top, width: band, height: f.plotHeight, tabindex: "0" });
          var rows = summary.medianSeconds === null
            ? [{ value: "—", label: summary.ended ? "no known duration" : "nothing ended" }]
            : [{ series: "line", value: formatDuration(summary.medianSeconds), label: "median" },
               { value: summary.timed + " of " + summary.ended, label: "with a known duration" }];
          var show = function () {
            var x = f.left + index * band + band / 2;
            cross.setAttribute("x1", x);
            cross.setAttribute("x2", x);
            cross.setAttribute("visibility", "visible");
            showTip(hit, dayLabel(day, true), rows);
          };
          var hide = function () { cross.setAttribute("visibility", "hidden"); hideTip(); };
          hit.addEventListener("pointerenter", show);
          hit.addEventListener("focus", show);
          hit.addEventListener("pointerleave", hide);
          hit.addEventListener("blur", hide);
          chart.appendChild(hit);
        });
        xLabels(chart, f, list, band);
        container.appendChild(chart);
      }

      function tile(label, value, detail, unavailable) {
        return add(el("div", "tile"), el("div", "label", label), el("div", "value" + (unavailable ? " unavailable" : ""), value),
          detail ? el("div", "detail", detail) : null);
      }
      function table(headers, rows, className) {
        var node = el("table", className);
        var head = el("tr");
        headers.forEach(function (h) { add(head, el("th", null, h)); });
        add(node, add(el("thead"), head));
        var body = el("tbody");
        rows.forEach(function (row) {
          var tr = el("tr");
          row.forEach(function (cell, index) {
            var td = el("td", cell && cell.dim ? "dim" : null);
            if (cell && cell.node) { td.appendChild(cell.node); } else { td.textContent = cell && cell.text !== undefined ? cell.text : String(cell); }
            tr.appendChild(td);
          });
          body.appendChild(tr);
        });
        return add(el("div", "table-wrap"), add(node, body));
      }
      function inRange(item) { return item.day >= state.from && item.day <= state.through; }

      /* One table per breakdown: each bot, account or project in the range, busiest first. */
      function breakdown(title, names, field, none, note) {
        var card = add(el("section", "card"), el("h2", null, title));
        if (note) { add(card, el("p", "note", note)); }
        var keys = {};
        records.forEach(function (r) { if (inRange(r) && state.kinds[r.kind]) { keys[r[field] === undefined || r[field] === null ? "none" : r[field]] = true; } });
        tasks.forEach(function (t) { if (inRange(t)) { keys[t[field] === undefined || t[field] === null ? "none" : t[field]] = true; } });
        var rows = Object.keys(keys).map(function (k) {
          var match = function (item) { return k === "none" ? (item[field] === undefined || item[field] === null) : item[field] === Number(k); };
          var s = summarize(records, state.from, state.through, state.kinds, match);
          var started = tasks.filter(function (t) { return inRange(t) && match(t); }).length;
          var name = k === "none" ? none : field === "account" ? names[Number(k)].name : names[Number(k)];
          return { name: name, none: k === "none", s: s, tasks: started };
        });
        rows.sort(function (a, b) { return b.s.runs - a.s.runs || b.tasks - a.tasks || (a.name < b.name ? -1 : 1); });
        if (!rows.length) {
          add(card, el("p", "empty", "Nothing in this range."));
          return card;
        }
        add(card, table(["", "Turns & runs", "Finished", "Failed", "Stopped", "In progress", "Failure rate", "Median time", "Time at work", "Tasks started"],
          rows.map(function (row) {
            var s = row.s, o = s.outcomes;
            return [{ text: row.name, dim: row.none }, s.runs, o.finished || 0, o.failed || 0, (o.stopped || 0) + (o.interrupted || 0), o.inProgress || 0,
              formatPercent(s.failureRate), s.timed ? formatDuration(s.medianSeconds) : "—", s.timed ? formatDuration(s.totalSeconds) : "—", row.tasks];
          })));
        return card;
      }

      function allowanceCard() {
        var card = add(el("section", "card"), el("h2", null, "Provider allowance"),
          el("p", "note", "Each profile's latest reading, as its provider reported it: not a history, and not split by bot, so it isn't added to the activity above."));
        var allowance = data.allowance || [];
        if (!allowance.length) { return add(card, el("p", "empty", "No allowance readings are saved yet. Providers in BotChu reads them.")); }
        var status = { current: "Current", stale: "Stale", unavailable: "No reading" };
        var rows = [];
        allowance.forEach(function (profile) {
          var read = when(profile.readAt);
          var windows = profile.windows.length ? profile.windows : [null];
          windows.forEach(function (window, index) {
            var used;
            if (!window) { used = { text: "—", dim: true }; }
            else if (window.hasReset) { used = { text: "Reset since", dim: true }; }
            else if (typeof window.usedPercent === "number") {
              var meter = el("span", "meter"), fill = el("i");
              fill.style.width = Math.max(0, Math.min(100, window.usedPercent)) + "%";
              meter.appendChild(fill);
              used = { node: add(el("span"), meter, document.createTextNode(Math.round(window.usedPercent) + "%")) };
            } else { used = { text: "Not reported", dim: true }; }
            rows.push([{ text: index ? "" : profile.account, dim: false }, index ? "" : profile.family, index ? "" : status[profile.status] || profile.status,
              window ? window.title : "—", used, window ? when(window.resetsAt) : "—", index ? "" : read]);
          });
        });
        return add(card, table(["Profile", "Family", "Reading", "Window", "Used", "Resets", "Read"], rows, "text"));
      }

      function aboutCard() {
        var c = data.coverage || {};
        var card = add(el("section", "card about"), el("h2", null, "About these numbers"));
        var list = el("dl");
        function item(term, text) { add(list, el("dt", null, term), el("dd", null, text)); }
        item("Days", "Calendar days in " + data.timeZone + ", this Mac's time zone when the page was made. A turn or run counts on the day it started, with all of its time, even when it ends after midnight; a day with a daylight-saving change is still one day.");
        item("Home and task turns", "From each conversation's saved transcript. A turn starts with a message to the bot (yours, another bot's, Telegram's or an Inbox reply), or when the turn before it ended if the message waited in the queue, and ends with the last thing the bot did. It failed when its last word is an error and was stopped when BotChu's Stopped note ends it; otherwise it finished, which means the CLI ended its turn without an error, not that the work succeeded. A follow-up Claude Code took during a turn starts a turn of its own. Turns count for the account their conversation uses now: transcripts don't record each turn's account.");
        item("Job runs", "From each job's history: from when the run started to when it finished, on the account it recorded. A time the job skipped is listed in the daily tooltips but never counted as a run. The run's task conversation isn't counted again; turns you added to it afterwards are task turns.");
        item("Sub-agent runs", "From each run's record: from its start to its end, for the bot it ran as, on the account it recorded, in the project of the task that delegated it.");
        item("Tasks started", "Tasks made in the range (not job runs), by the repository they work in. A task's latest turn says how it stands, so a failure and then a successful retry leave it finished, while both turns are counted.");
        item("Durations", "Unknown when a time is missing or out of order, or the work is still under way. Unknown durations are left out of medians and totals and never count as zero. The median is the middle known duration (the mean of the two middle ones for an even count). Failure rate is failed ÷ (finished + failed + stopped + interrupted).");
        item("Tokens and cost", "Unavailable: BotChu doesn't record what a turn or run used or cost. Provider allowance is the providers' own latest reading per profile.");
        add(card, list);
        add(card, el("h3", null, "What history exists"));
        var kept = el("ul");
        ["Conversations are kept until their bot is deleted; closed tasks keep theirs. A job run's task goes when its job's history lets the run go.",
          "Each job's history keeps its latest 50 runs and always its last success; deleting a job deletes its history.",
          "Sub-agent runs are kept until Clear Run removes them; one a relaunch interrupted is recorded as stopped.",
          "So older periods may show less than happened."].forEach(function (text) { add(kept, el("li", null, text)); });
        add(card, kept);
        add(card, el("h3", null, "Left out"));
        var out = el("ul");
        ["Messages, briefs, prompts, replies, tool calls and their output, error messages, titles, file paths, commands and credentials: this page holds names of bots, accounts and repositories, and numbers.",
          "Run reviews (" + (c.runReviews || 0) + " records): reviews of the work, not work.",
          "Task summaries, pet drawing and the turn log, which aren't tied to a conversation.",
          "Remote queue bots (" + (c.remoteQueueBots || 0) + "), which run on another computer."].forEach(function (text) { add(out, el("li", null, text)); });
        add(card, out);
        add(card, el("h3", null, "Read"));
        add(card, el("p", "note", (c.bots || 0) + " bots, " + (c.conversations || 0) + " conversations, " + records.length + " turns, runs and skipped job times, " + tasks.length + " tasks"
          + (c.jobRunsFromTasks ? ", " + c.jobRunsFromTasks + " job runs read from their task after their job was deleted" : "") + "."));
        add(card, el("h3", null, "Access"));
        add(card, el("p", "note", "This page is a file in BotChu's data folder that only your macOS user can read. Everything it shows is inside it; it loads nothing from the network, and nothing serves it."));
        return card;
      }

      function render() {
        hideTip();
        app.textContent = "";
        var filters = el("div", "filters");
        var presets = add(el("div", "group"), el("span", "group-label", "Range"));
        [["7", "7 days"], ["30", "30 days"], ["90", "90 days"], ["all", "All"]].forEach(function (p) {
          var button = el("button", "preset", p[1]);
          button.type = "button";
          button.setAttribute("aria-pressed", state.preset === p[0] ? "true" : "false");
          button.addEventListener("click", function () { setPreset(p[0]); });
          presets.appendChild(button);
        });
        var from = el("input"), through = el("input");
        from.type = through.type = "date";
        from.value = state.from;
        through.value = state.through;
        from.setAttribute("aria-label", "From");
        through.setAttribute("aria-label", "Through");
        var dates = add(el("div", "group"), el("span", "group-label", "From"), from, el("span", "group-label", "through"), through);
        function custom() {
          if (!from.value || !through.value) { return; }
          state.preset = "custom";
          state.from = from.value <= through.value ? from.value : through.value;
          state.through = from.value <= through.value ? through.value : from.value;
          render();
        }
        from.addEventListener("change", custom);
        through.addEventListener("change", custom);
        var kinds = add(el("div", "group"), el("span", "group-label", "Include"));
        KINDS.forEach(function (kind) {
          var box = el("input");
          box.type = "checkbox";
          box.checked = !!state.kinds[kind[0]];
          box.addEventListener("change", function () { state.kinds[kind[0]] = box.checked; render(); });
          kinds.appendChild(add(el("label", "kind"), box, document.createTextNode(kind[1])));
        });
        add(app, add(filters, presets, dates, kinds));

        var problems = (data.coverage && data.coverage.problems) || [];
        if (problems.length) {
          var callout = add(el("section", "callout"), el("strong", null, "Not everything could be read"));
          var ul = el("ul");
          problems.forEach(function (p) { add(ul, el("li", null, p)); });
          add(app, add(callout, ul));
        }

        if (!records.length && !tasks.length) {
          add(app, add(el("section", "card"), el("h2", null, "No activity recorded yet"),
            el("p", "note", "Turns, tasks, job runs and sub-agent runs appear here once BotChu has saved some.")));
        } else {
          var total = summarize(records, state.from, state.through, state.kinds);
          var started = tasks.filter(inRange).length;
          var o = total.outcomes;
          var measures = data.measures || [];
          var tokens = measureText(measures.filter(function (m) { return m.metric === "tokens"; })[0]);
          var cost = measureText(measures.filter(function (m) { return m.metric === "cost"; })[0]);
          add(app, add(el("div", "tiles"),
            tile("Turns & runs", total.runs, total.skipped ? total.skipped + " skipped job times not counted" : dayLabel(state.from) + " – " + dayLabel(state.through)),
            tile("Finished", o.finished || 0, "Ended without an error"),
            tile("Failed", o.failed || 0, "Failure rate " + formatPercent(total.failureRate)),
            tile("Stopped", (o.stopped || 0) + (o.interrupted || 0), o.interrupted ? o.interrupted + " job runs cut short by a quit or crash" : "By you, or by a quit"),
            tile("In progress", o.inProgress || 0, "No duration yet"),
            tile("Median time", total.timed ? formatDuration(total.medianSeconds) : "—", total.timed + " of " + total.ended + " with a known duration"),
            tile("Time at work", total.timed ? formatDuration(total.totalSeconds) : "—", "Known durations added up"),
            tile("Tasks started", started, "Job runs not included"),
            tile("Tokens", tokens.value, tokens.detail, tokens.unavailable),
            tile("Cost", cost.value, cost.detail, cost.unavailable)));

          var list = days(state.from, state.through);
          var perDay = {};
          list.forEach(function (day) { perDay[day] = summarize(byDay[day] || [], day, day, state.kinds); });
          var charts = el("div", "grid2");
          var volume = add(el("section", "card"), el("h2", null, "Turns and runs a day"));
          var legend = el("div", "legend");
          SERIES.forEach(function (series) { add(legend, add(el("span"), key(series[0]), document.createTextNode(series[1]))); });
          add(volume, legend);
          var durations = add(el("section", "card"), el("h2", null, "Median duration a day"),
            el("p", "note", "Days without a known duration are gaps, not zero."));
          add(charts, volume, durations);
          add(app, charts);
          var volumeBox = el("div", "chart"), durationBox = el("div", "chart");
          add(volume, volumeBox);
          add(durations, durationBox);
          if (!total.runs && !total.skipped) {
            add(volumeBox, el("p", "empty", "No turns or runs in this range."));
            add(durationBox, el("p", "empty", "No turns or runs in this range."));
          } else {
            volumeChart(volumeBox, list, perDay);
            if (total.timed) { durationChart(durationBox, list, perDay); } else { add(durationBox, el("p", "empty", "No known durations in this range.")); }
            var active = list.filter(function (day) { return perDay[day].runs || perDay[day].skipped; });
            var details = add(el("details"), el("summary", null, "Show as a table (" + active.length + " days with activity)"));
            add(details, table(["Day", "Finished", "Failed", "Stopped", "Interrupted", "In progress", "Skipped", "Median time"],
              active.map(function (day) {
                var s = perDay[day], c = s.outcomes;
                return [dayLabel(day, true), c.finished || 0, c.failed || 0, c.stopped || 0, c.interrupted || 0, c.inProgress || 0, s.skipped,
                  s.timed ? formatDuration(s.medianSeconds) : "—"];
              })));
            add(volume, details);
          }
          add(app, breakdown("By bot", data.bots, "bot", "Unknown bot", "Sub-agent runs count for the bot they ran as."));
          add(app, breakdown("By provider account", data.accounts, "account", "Account not recorded",
            "Job and sub-agent runs on the account they recorded; Home and task turns on the account their conversation uses now."));
          add(app, breakdown("By project", data.projects, "project", "No project (Home and job runs)", "Task turns and tasks by their repository; sub-agent runs by the task that delegated them."));
        }
        add(app, allowanceCard());
        add(app, aboutCard());
      }

      var resizing = null;
      window.addEventListener("resize", function () {
        clearTimeout(resizing);
        resizing = setTimeout(render, 150);
      });
      render();
    })(typeof globalThis !== "undefined" ? globalThis : this);
    """#
}
