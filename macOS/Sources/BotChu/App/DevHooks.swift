import AppKit
import SwiftUI
import WebKit
import BotChuCore

/// Environment variables for checking the app without touching real data or needing screen-recording
/// permission (see `macOS/ui-review.sh`):
/// - `BOTCHU_DATA_DIR`: keep the bot index and bot folders under this folder instead, with settings in
///   their own `defaults` domain (`local.BotChu.dev`), so a throwaway run never changes the real ones.
/// - `BOTCHU_SNAPSHOT`: write a PNG of each window into this folder every second, and of the sidebar's
///   rows (`sidebar.png`), which the window's picture leaves out.
/// - `BOTCHU_OPEN`: open `editor` (a new bot), `task` (New Task), `memory`, `soul`, or `settings` at launch;
///   `BOTCHU_SETTINGS=<page>` (`general`, `accounts`, `github`, `hosts`, `run-reviews`, `pets`,
///   `openrouter`, `telegram`, `remote-queue`) opens Settings on that page, else on the one shown last.
/// - `BOTCHU_APPEARANCE`: use `light` or `dark` for an isolated visual review.
/// - `BOTCHU_OPEN=model|effort|inspector-model|inspector-effort`: open a generation picker;
///   `job-model|job-effort` opens a new job's editor with its picker open.
/// - `BOTCHU_INSPECTOR=activity|model|session|memory`: select an inspector area on throwaway data.
/// - `BOTCHU_DEFAULT_MODEL`: an OpenRouter default for a throwaway run only.
/// - `BOTCHU_WINDOW=compact`: review the main window at its minimum width, on throwaway data;
///   `BOTCHU_WINDOW=<width>x<height>` (such as `1908x960`) at that frame size, as a report gives it;
///   `wide`, 1,700 points wide, where a bot's tasks show as a column beside its chat.
/// - `BOTCHU_USAGE`: `sample`, `stale`, `expired`, or `unavailable` allowance for an isolated review;
///   `mixed` gives each kind of profile a different state (`mixedUsage`).
/// - `BOTCHU_CONNECTORS`: `sample` connectors for every profile check, `stale` (a check that fails
///   after the first), or `unavailable` (one that always fails), for an isolated review.
/// - `BOTCHU_OPEN=tools`: open Skills & Tools on Tools; `add-tools` with Add Tools open. `BOTCHU_TOOL`
///   selects a tool by its row's id (`catalog:gh`, `ssh:<alias>`, `botchu`), and `BOTCHU_SKILL`, with
///   `BOTCHU_OPEN=skills`, a skill by its name. Seed `tools.json` in `BOTCHU_DATA_DIR` for a policy.
/// - `BOTCHU_PROVIDER`: with `BOTCHU_OPEN=providers`, select this profile (an account id), showing
///   it in the sidebar.
/// - `BOTCHU_PROFILE`: with `BOTCHU_DATA_DIR`, CLI profiles to add, from `name|family|command`
///   (`family` as in `AgentKind`), several separated by `;`.
/// - `BOTCHU_SEND`: send this message to the selected bot's shown conversation at launch (its Home,
///   or the tab `BOTCHU_TAB` shows).
/// - `BOTCHU_TASK`: start a task for the selected bot at launch from `repo|task|host`, as New Task does
///   (`repo` is `owner/name` or a checkout's folder in the repositories folder, `host` an optional
///   host's nickname, where the checkout is in its repositories folder; a real turn).
/// - `BOTCHU_TAB`: show the selected bot's tab with this number at launch (0 is Home, 1 its first task).
/// - `BOTCHU_DRAFT`: with `BOTCHU_DATA_DIR`, put this draft in the shown conversation's message box at
///   launch (`\n` starts a new line), to review how the box grows and scrolls.
/// - `BOTCHU_TYPE`: with `BOTCHU_DATA_DIR`, type this into the shown conversation's message box a moment
///   after launch, a character at a time as the keyboard does, so `@` and `#` completion opens;
///   `{down}`, `{up}`, `{tab}`, `{return}` and `{escape}` press those keys.
/// - `BOTCHU_DEMO=activity`: with `BOTCHU_DATA_DIR`, make the shown conversation a long agent run
///   in memory (`DemoActivity`), to review the chat's activity cards without a real turn;
///   `BOTCHU_SUBAGENT=<title>` opens the details of its sub-agent whose title starts with it.
/// - `BOTCHU_SUBAGENT=<title>` without a demo: with `BOTCHU_DATA_DIR`, open the details of the saved
///   sub-agent run whose title starts with it once it is read in; `BOTCHU_RESUME=<seconds>` then
///   presses its Resume that long after (#368), to review an interrupted run and its relaunch.
/// - `BOTCHU_DEMO=tasks`: with `BOTCHU_DATA_DIR`, give the selected bot six more open tasks in memory,
///   one in each state (`DemoTabs`), to review its tabs beside the chat without real turns.
/// - `BOTCHU_DENSITY`: with `BOTCHU_DATA_DIR`, the chat density (`compact`, `detailed` or `raw`).
/// - `BOTCHU_HOST`: with `BOTCHU_DATA_DIR`, the hosts in Settings ▸ Hosts, from
///   `nickname|ssh destination|repositories folder|machine name|account=command,…`, several
///   separated by `;`.
/// - `BOTCHU_SSH`: with `BOTCHU_DATA_DIR`, the program BotChu runs as `ssh` (a stand-in that runs the
///   command here lets a review exercise tasks on a host without one).
/// - `BOTCHU_TASK_REPO`: with `BOTCHU_OPEN=task`, the repository (`owner/name`) New Task chooses.
/// - `BOTCHU_PROJECT`: with `BOTCHU_OPEN=projects`, the repository (`owner/name`) its sidebar shows;
///   `BOTCHU_PROJECT_TAB` (`overview`, `issues` or `pulls`) and `BOTCHU_PROJECT_ITEM` (a number) open
///   a tab and an issue or pull request there.
/// - `BOTCHU_CREATE`: create a bot at launch from `name|account id|instructions`, as the editor does.
/// - `BOTCHU_SECTION`: with `BOTCHU_DATA_DIR`, move the selected bot into the sidebar section of this
///   name at launch, as Move to Section does.
/// - `BOTCHU_SEARCH`: with `BOTCHU_DATA_DIR`, the search Agents opens with.
/// - `BOTCHU_PET`: give the selected bot this pet folder at launch (`video.json`, `stills/`, `clips/`).
/// - `BOTCHU_DRAW_PET`: give the selected bot this appearance and make its pet at launch (a real Codex
///   run, then real clips on OpenRouter, which cost OpenRouter credit).
/// - `BOTCHU_REPORT_GH`: with `BOTCHU_DATA_DIR`, the program BotChu runs as `gh` to file reports (Report
///   a Bug or Feature). A throwaway run without one files nothing, so a review never creates a real issue.
/// - `BOTCHU_OPEN=new-issue`: open Projects and New Issue (#245), for `BOTCHU_PROJECT` when given;
///   `BOTCHU_FILINGS=sample`, with `BOTCHU_DATA_DIR`: show a filing in each state in Projects' header.
/// - `BOTCHU_OPEN=report`: open Report a Bug or Feature; `BOTCHU_REPORT`, with `BOTCHU_DATA_DIR`: open it
///   with this report and file it, with the stand-in `gh`.
/// - `BOTCHU_JOBS=sample`: with `BOTCHU_DATA_DIR`, give the bots sample scheduled jobs with a history
///   of every kind of run (`sampleJobs`), and run no job, so nothing starts a CLI. `BOTCHU_OPEN=jobs`
///   opens Jobs, `job-editor` the editor for a new job, `job-edit` the editor for the job titled
///   `BOTCHU_JOB` (else the first), and `job-history` the first job's history.
/// - `BOTCHU_TIMINGS`: append frame marks, and the main thread's long busy stretches, to this file for
///   the journeys harness (`FrameTimings`).
@MainActor
enum DevHooks {
    static let env = ProcessInfo.processInfo.environment

    static var dataDir: URL? {
        env["BOTCHU_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Whether scheduled jobs run: not in a throwaway run with sample jobs, which are only to look at.
    static var runsJobs: Bool { !(dataDir != nil && env["BOTCHU_JOBS"] == "sample") }

    static var inspectorTab: InspectorTab? {
        guard dataDir != nil else { return nil }
        if ["inspector-model", "inspector-effort"].contains(env["BOTCHU_OPEN"] ?? "") { return .model }
        return env["BOTCHU_INSPECTOR"].flatMap(InspectorTab.init(rawValue:))
    }

    /// The search Agents opens with on throwaway data (`BOTCHU_SEARCH`).
    static var agentsSearch: String {
        dataDir == nil ? "" : env["BOTCHU_SEARCH"] ?? ""
    }

    /// The hosts a throwaway run starts with (`BOTCHU_HOST`).
    static var hosts: [SSHHost] {
        guard dataDir != nil, let spec = env["BOTCHU_HOST"] else { return [] }
        return spec.split(separator: ";").compactMap { entry in
            let parts = entry.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            let commands = parts.count > 4 ? Dictionary(parts[4].split(separator: ",").compactMap { pair -> (String, String)? in
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return kv.count == 2 ? (kv[0], kv[1]) : nil
            }, uniquingKeysWith: { $1 }) : nil
            return SSHHost(nickname: parts[0], destination: parts[1], machine: parts.count > 3 ? parts[3] : SSHHost.machineName(destination: parts[1]),
                           reposFolder: parts.count > 2 ? parts[2] : "~/apps", commands: commands)
        }
    }

    /// Settings a throwaway run needs before the model loads: the stand-in `ssh` (`BOTCHU_SSH`).
    static func configure() {
        if dataDir != nil, let ssh = env["BOTCHU_SSH"] { Machine.ssh = ssh }
    }

    /// What files reports: gh, except in a throwaway run, which files with the stand-in `gh` it was
    /// given (`BOTCHU_REPORT_GH`) or not at all.
    static var issueFiler: IssueFiler {
        guard dataDir != nil else { return IssueFiler() }
        if let gh = env["BOTCHU_REPORT_GH"], !gh.isEmpty { return IssueFiler(gh: gh) }
        return IssueFiler { _, _, _ in
            .failed("This copy of BotChu runs on throwaway data and files no issues; macOS/ui-review.sh gives it a stand-in gh.")
        }
    }

    /// What files New Issue's issues (#245): gh, or in a throwaway run the stand-in `gh` it was given
    /// (`BOTCHU_REPORT_GH`), or nothing.
    static var issueCreate: IssueDraft.Create {
        guard dataDir != nil else { return { repo, title, body, images in await IssueFiler.create(gh: "gh", repository: repo, title: title, body: body, images: images) } }
        if let gh = env["BOTCHU_REPORT_GH"], !gh.isEmpty {
            return { repo, title, body, images in await IssueFiler.create(gh: gh, repository: repo, title: title, body: body, images: images) }
        }
        return { _, _, _, _ in
            .failed("This copy of BotChu runs on throwaway data and files no issues; macOS/ui-review.sh gives it a stand-in gh.")
        }
    }

    /// What takes a report's screenshot: the window itself, except in a throwaway run with
    /// `BOTCHU_SCREENSHOT_FAIL`, which can't take one, to show the report without it.
    static var windowCapture: WindowCapture.Capture {
        guard dataDir != nil, env["BOTCHU_SCREENSHOT_FAIL"] != nil else { return WindowCapture.screen }
        return { _ in throw ImageDelivery.Failure("The window isn't on screen.") }
    }

    /// `BOTCHU_CODEX_MODELS`: `sample`, a Codex profile's list as its `model/list` gave it on 2026-10-27
    /// (#220), a Muse profile's on 2026-10-28 (#248), and Claude Code's, Antigravity's and a Sail
    /// list (#326), after a second; `unavailable`, a check that times out.
    static var modelLists: (@Sendable (ModelCatalogScope) async throws -> [ModelOption])? {
        guard dataDir != nil, let fixture = env["BOTCHU_CODEX_MODELS"], ["sample", "unavailable"].contains(fixture) else { return nil }
        return { scope in
            try await Task.sleep(for: .seconds(1))
            if fixture == "unavailable" { throw ModelListFailure("\(scope.kind.displayName) didn’t list its models within 20 seconds.") }
            if scope.kind == .muse { return GenerationOptions.models(for: .muse) }
            if scope.kind == .claude || scope.kind == .antigravity { return GenerationOptions.models(for: scope.kind) }
            if scope.kind == .sail {
                return [ModelOption(id: "moonshotai/kimi-k3", name: "Kimi K3", efforts: [], effortsKnown: false, contextLength: 262_144),
                        ModelOption(id: "zai/glm-5.2", name: "GLM 5.2", efforts: [], effortsKnown: false, contextLength: 200_000)]
            }
            if scope.kind == .pi {
                return [ModelOption(id: "muse-spark-1.1", name: "Muse Spark 1.1", efforts: [.off, .minimal, .low, .medium, .high], providerID: "meta"),
                        ModelOption(id: "kimi-k3", name: "Kimi K3", efforts: [.off, .minimal, .low, .medium, .high], providerID: "radius")]
            }
            let all: [ReasoningEffort] = [.low, .medium, .high, .xhigh, .max, .ultra]
            return [("gpt-6.1-sol", "GPT-6.1-Sol"), ("gpt-6-astra", "GPT-6-Astra"), ("gpt-6.1-terra", "GPT-6.1 Terra"), ("gpt-6-sol", "GPT-6-Sol"),
                    ("gpt-6-luna", "GPT-6-Luna"), ("gpt-5.6-sol", "GPT-5.6-Sol"), ("gpt-5.6-terra", "GPT-5.6-Terra"), ("gpt-5.6-luna", "GPT-5.6-Luna")]
                .map { ModelOption(id: $0.0, name: $0.1, efforts: $0.0.hasSuffix("luna") ? Array(all.dropLast()) : all) }
        }
    }

    /// `BOTCHU_CONNECTORS`, as the mock's states: connected services, ones needing sign-in, failed or
    /// off, Computer Use configured, and the provider's own entries.
    static var connectorCheck: (@Sendable (AgentKind, String, String) async throws -> ConnectorReport)? {
        guard dataDir != nil, let fixture = env["BOTCHU_CONNECTORS"], ["sample", "stale", "unavailable"].contains(fixture) else { return nil }
        let checks = UsageChecks()
        return { kind, _, _ in
            let count = await checks.next(kind.rawValue)
            if fixture == "unavailable" || (fixture == "stale" && count > 1) {
                throw ConnectorFailure("\(kind.displayName) didn’t answer within 20 seconds.")
            }
            let service: Connector.Origin = kind == .codex ? .codexApp : .claudeAI
            let services: [(String, Connector.State)] = [
                ("GitHub", .connected), ("Gmail", .connected), ("Google Drive", .connected), ("Linear", .connected), ("Notion", .connected),
                ("Google Calendar", .needsAuth), ("Figma", .off),
            ]
            var connectors = services.map { Connector(name: $0.0, state: $0.1, origin: service, toolCount: $0.1 == .connected ? 6 : nil,
                                                      id: kind == .codex ? "connector_\($0.0.lowercased())" : "claude.ai \($0.0)") }
            connectors += [
                Connector(name: "Slack", state: .needsAuth, origin: .mcpServer, id: "slack"),
                Connector(name: "Postgres", state: .failed, origin: .mcpServer, id: "postgres"),
                Connector(name: "Computer Use", state: .configured, origin: .mcpServer, toolCount: 0, id: "computer-use"),
                Connector(name: "link", state: .connected, origin: .mcpServer, toolCount: 4, id: "link"),
                Connector(name: "node_repl", state: .connected, origin: .mcpServer, toolCount: 4, id: "node_repl"),
            ]
            if kind == .codex {
                connectors += [Connector(name: "Pets", state: .connected, origin: .codexApp, id: "connector_openai_chatgpt_pets"),
                               Connector(name: "Hotline", state: .connected, origin: .codexApp, id: "connector_openai_hotline")]
            }
            return ConnectorReport(connectors: connectors,
                                   at: Date().addingTimeInterval(fixture == "stale" ? -7_200 : -180))
        }
    }

    static var usageFetch: UsageCache.Fetch? {
        guard dataDir != nil, let fixture = env["BOTCHU_USAGE"],
              ["sample", "stale", "expired", "unavailable", "mixed"].contains(fixture) else { return nil }
        let checks = UsageChecks()
        return { request, _ in
            if fixture == "unavailable" { throw UsageFailure("Check the account’s sign-in, then refresh.") }
            let now = Date()
            if fixture == "mixed", let reading = try await mixedUsage(request.account, now: now, check: await checks.next(request.account.id)) { return reading }
            var reading = sampleUsage(request.account, now: now)
            if fixture == "stale" { reading.readAt = now.addingTimeInterval(-7_200) }
            if fixture == "expired" { reading.windows = reading.windows.map { var window = $0; window.resetsAt = now.addingTimeInterval(-60); return window } }
            return reading
        }
    }

    /// `BOTCHU_USAGE=sample`, as Providers' mock draws its main state: Claude's 5-hour, Weekly and
    /// Fable's week; Codex's week with credits (Codex Personal none) and two free resets;
    /// Antigravity's four windows; Muse read 12 minutes ago; Pi's key with a daily spending limit.
    /// An added profile gets its family's.
    nonisolated private static func sampleUsage(_ account: Account, now: Date) -> ProviderUsage {
        func at(_ days: Double, _ hours: Double, _ minutes: Double) -> Date { now.addingTimeInterval(days * 86_400 + hours * 3_600 + minutes * 60) }
        func claude(_ session: Double, _ week: Double, _ fable: Double, session sessionReset: Date, week weekReset: Date) -> ProviderUsage {
            ProviderUsage(windows: [UsageWindow(id: "session", title: "5-hour", usedPercent: session, resetsAt: sessionReset),
                                    UsageWindow(id: "week", title: "Weekly", usedPercent: week, resetsAt: weekReset),
                                    UsageWindow(id: "week-fable", title: "Fable · Weekly", usedPercent: fable, resetsAt: weekReset)], readAt: now)
        }
        func codex(_ week: Double, credits: Double?, resets weekReset: Date) -> ProviderUsage {
            ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: week, resetsAt: weekReset)], readAt: now,
                          credits: UsageCredits(available: credits != nil, balance: credits ?? 0),
                          resets: UsageResets(available: 2, expiries: [at(4, 8, 35), at(12, 12, 8)]))
        }
        switch account.id {
        case "claude-dev": return claude(4, 34, 7, session: at(0, 3, 58), week: at(1, 2, 48))
        case "claude-work": return claude(2, 7, 0, session: at(0, 1, 28), week: at(1, 16, 48))
        case "codex-personal": return codex(9, credits: nil, resets: at(6, 19, 44))
        case "codex-work": return codex(0, credits: 60_891, resets: at(6, 22, 58))
        default: break
        }
        switch account.kind {
        case .claude: return claude(0, 66, 20, session: at(0, 4, 28), week: at(1, 10, 48))
        case .codex: return codex(0, credits: 65_292.36, resets: at(6, 22, 58))
        case .antigravity:
            return ProviderUsage(windows: [UsageWindow(id: "gw", title: "Gemini · Weekly", usedPercent: 1, resetsAt: at(6, 10, 37)),
                                           UsageWindow(id: "g5", title: "Gemini · 5-hour", usedPercent: 0, resetsAt: at(0, 4, 58)),
                                           UsageWindow(id: "cw", title: "Claude & GPT · Weekly", usedPercent: 52, resetsAt: at(4, 12, 17)),
                                           UsageWindow(id: "c5", title: "Claude & GPT · 5-hour", usedPercent: 0, resetsAt: at(0, 4, 58))], readAt: now)
        case .muse:
            return ProviderUsage(windows: [UsageWindow(id: "window", title: "5-hour", usedPercent: 1, resetsAt: at(0, 1, 58)),
                                           UsageWindow(id: "weekly", title: "Weekly", usedPercent: 41, resetsAt: at(0, 13, 48))],
                                 readAt: now.addingTimeInterval(-720))
        case .pi:
            return ProviderUsage(windows: [UsageWindow(id: "key", title: "Key allowance", usedPercent: 0.04, resetsAt: at(0, 13, 48),
                                                       detail: "$24.99 of $25.00 left")], readAt: now)
        case .sail:
            // As its Usage API reports it: a balance and what is spending it, no window of a limit.
            return ProviderUsage(windows: [], readAt: now,
                                 balance: UsageBalance(credit: 54.98, spent: 1.98, period: "7d", perDay: 0.28, daysLeft: 194))
        }
    }

    /// `BOTCHU_USAGE=mixed`, the mock's problems: Claude Work read two hours ago, its 5-hour window
    /// reset since, then a failed check (`start` makes it); Codex Personal's week used up, with no
    /// credits and one free reset that expires in two days; Codex Work unavailable; Antigravity
    /// nearly used up, with a daily window; Muse still checking; Pi's key without a limit; and an
    /// added profile (`BOTCHU_PROFILE`) whose command isn't found. The others get the sample.
    nonisolated private static func mixedUsage(_ account: Account, now: Date, check: Int) async throws -> ProviderUsage? {
        func at(_ days: Double, _ hours: Double, _ minutes: Double) -> Date { now.addingTimeInterval(days * 86_400 + hours * 3_600 + minutes * 60) }
        switch account.id {
        case "claude-work" where check > 1: throw UsageFailure("Usage check timed out. Try refreshing later.")
        case "claude-work":
            return ProviderUsage(windows: [UsageWindow(id: "session", title: "5-hour", usedPercent: 2, resetsAt: at(0, 0, -32)),
                                           UsageWindow(id: "week", title: "Weekly", usedPercent: 7, resetsAt: at(1, 16, 48)),
                                           UsageWindow(id: "week-fable", title: "Fable · Weekly", usedPercent: 0, resetsAt: at(1, 16, 48))],
                                 readAt: now.addingTimeInterval(-7_200))
        case "codex-personal":
            return ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 100, resetsAt: at(1, 3, 16))],
                                 readAt: now, credits: UsageCredits(available: false, balance: 0),
                                 resets: UsageResets(available: 1, expiries: [at(2, 0, 0)]))
        case "google":
            return ProviderUsage(windows: [UsageWindow(id: "gw", title: "Gemini · Weekly", usedPercent: 22, resetsAt: at(6, 10, 37)),
                                           UsageWindow(id: "g5", title: "Gemini · 5-hour", usedPercent: 4, resetsAt: at(0, 2, 40)),
                                           UsageWindow(id: "cw", title: "Claude & GPT · Weekly", usedPercent: 97, resetsAt: at(4, 12, 17)),
                                           UsageWindow(id: "c5", title: "Claude & GPT · 5-hour", usedPercent: 100, resetsAt: at(0, 2, 58)),
                                           UsageWindow(id: "id", title: "Images · Daily", usedPercent: 61, resetsAt: at(0, 12, 48))], readAt: now)
        case "muse":
            // Still checking with its brief request.
            try await Task.sleep(for: .seconds(3_600))
            return nil
        case "openrouter": return ProviderUsage(windows: [], note: "No key spending limit · $1.25 used", readAt: now)
        case "codex-work": throw UsageFailure("Could not read account usage. Check the CLI’s sign-in and command, then refresh.")
        case let id where id.hasPrefix("custom-"): throw UsageFailure("The login shell can’t find this profile’s command.")
        default: return nil
        }
    }

    /// How many times each profile has been checked in a fixture run (`mixedUsage`).
    private actor UsageChecks {
        private var counts: [String: Int] = [:]
        func next(_ id: String) -> Int {
            counts[id, default: 0] += 1
            return counts[id]!
        }
    }

    static func start(model: AppModel) {
        if dataDir != nil, let profiles = env["BOTCHU_PROFILE"] {
            model.settings.customAccounts = profiles.split(separator: ";").enumerated().compactMap { index, profile in
                let parts = profile.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3, let kind = AgentKind(rawValue: parts[1]) else { return nil }
                return Account(id: "custom-review-\(index)", name: parts[0], kind: kind, defaultCommand: parts[2], symbol: "terminal")
            }
        }
        if dataDir != nil, env["BOTCHU_USAGE"] == "mixed", let account = model.settings.accounts.first(where: { $0.id == "claude-work" }) {
            // A check after Claude Work's first reading, which fails, so the reading shows stale with the error.
            let request = model.usageRequest(for: account)
            Task {
                try? await Task.sleep(for: .seconds(3))
                _ = await model.usage.read(request, for: .manual, now: .now.addingTimeInterval(31))
                await model.usageBoard.sync(request, usage: model.usage)
            }
        }
        if dataDir != nil, env["BOTCHU_WINDOW"] == "compact" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { return }
                // SwiftUI establishes the split view's actual minimum after the first layout.
                window.setContentSize(NSSize(width: max(820, window.contentMinSize.width),
                                             height: max(600, window.contentMinSize.height)))
            }
        }
        if dataDir != nil, env["BOTCHU_WINDOW"] == "wide" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.windows.first(where: { $0.styleMask.contains(.titled) })?.setContentSize(NSSize(width: 1700, height: 920))
            }
        }
        if dataDir != nil, let size = env["BOTCHU_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) else { return }
                let visible = window.screen?.visibleFrame ?? .infinite
                let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size[1], width: size[0], height: size[1])
                // On screen, so the window isn't moved back and resized there.
                window.setFrame(frame.offsetBy(dx: min(0, visible.maxX - frame.maxX), dy: max(0, visible.minY - frame.minY)), display: true)
            }
        }
        if dataDir != nil, let density = env["BOTCHU_DENSITY"].flatMap(ChatDensity.init(rawValue:)) {
            // Registered, not saved: review copies share the installed app's preferences.
            UserDefaults.standard.register(defaults: [ChatDensity.storageKey: density.rawValue])
        }
        if dataDir != nil, let appearance = env["BOTCHU_APPEARANCE"], ["light", "dark"].contains(appearance) {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let dir = env["BOTCHU_SNAPSHOT"] {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let url = URL(fileURLWithPath: dir, isDirectory: true)
                    snapshot(into: url)
                    snapshotSidebar(model: model, into: url)
                }
            }
        }
        FrameTimings.watchSidebar()
        FrameTimings.watchBusy()
        if dataDir != nil, env["BOTCHU_JOBS"] == "sample" { sampleJobs(model: model) }
        if dataDir != nil, env["BOTCHU_FILINGS"] == "sample", let bot = model.issueWriters.first { sampleFilings(model: model, bot: bot) }
        switch env["BOTCHU_OPEN"] {
        case "inbox", "projects", "agents", "providers", "skills", "jobs":
            model.destination = env["BOTCHU_OPEN"].flatMap(LibraryDestination.init(rawValue:))
            if let account = env["BOTCHU_PROVIDER"] { model.providerSelection = account }
            if let name = env["BOTCHU_SKILL"] { model.skillSelection = model.skillEntries().first { $0.skill.name == name }?.id }
            if let item = env["BOTCHU_INBOX_ITEM"].flatMap(UUID.init(uuidString:)) { model.inbox.selected = item }
            if let repo = env["BOTCHU_PROJECT"] {
                model.selectProject(repo, tab: env["BOTCHU_PROJECT_TAB"].flatMap(ProjectSelection.Tab.init(rawValue:)) ?? .overview,
                                    item: env["BOTCHU_PROJECT_ITEM"].flatMap(Int.init))
            }
        case "tools", "add-tools":
            model.destination = .skills
            model.skillsTab = .tools
            model.addingTools = env["BOTCHU_OPEN"] == "add-tools"
            model.toolSelection = env["BOTCHU_TOOL"].map { tool in
                tool.hasPrefix("ssh:") ? model.tools.policy.destinations.first { "ssh:" + $0.alias == tool }.map { ToolRow.sshID($0) } ?? tool : tool
            }
        case "new-issue":
            model.destination = .projects
            if let repo = env["BOTCHU_PROJECT"] { model.selectProject(repo) }
            model.startNewIssue()
        case "editor": model.newBot()
        case "job-editor", "job-model", "job-effort": model.jobs.newJob(for: model.selection)
        case "job-edit":
            if let job = model.jobs.jobs.first(where: { $0.title == env["BOTCHU_JOB"] }) ?? model.jobs.jobs.first { model.jobs.edit(job.id) }
        case "job-history": if let job = model.jobs.jobs.first { model.jobs.showHistory(job.id) }
        case "task": if let id = model.selection { model.newTask(for: id) }
        case "memory": if let id = model.selection { model.editDocument(.memory, for: id) }
        case "soul": if let id = model.selection { model.editDocument(.soul, for: id) }
        case "settings": model.openSettings(env["BOTCHU_SETTINGS"].flatMap(SettingsPage.init(rawValue:)))
        default: break
        }
        if dataDir != nil, let name = env["BOTCHU_SECTION"], let id = model.selection {
            model.moveBot(id, toSection: name)
        }
        if let spec = env["BOTCHU_CREATE"] {
            let parts = spec.split(separator: "|", maxSplits: 2).map(String.init)
            var bot = Bot(name: parts[0], workspace: model.defaultWorkspace(for: parts[0]))
            if parts.count > 1 { bot.accountID = parts[1] }
            if parts.count > 2 { bot.instructions = parts[2] }
            model.create(bot)
        }
        if let folder = env["BOTCHU_PET"], let id = model.selection, let bot = model.bot(id) {
            let target = PetVideo.folder(for: BotHome(workspace: bot.persistencePath))
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath), to: target)
            model.reloadPet(id)
        }
        if let appearance = env["BOTCHU_DRAW_PET"], let id = model.selection {
            model.setAppearance(appearance, for: id)
            model.makePet(id)
        }
        // Before BOTCHU_TAB, which may show one of its tasks.
        if dataDir != nil, env["BOTCHU_DEMO"] == "tasks", let id = model.selection {
            DemoTabs.install(in: model, botID: id)
        }
        if let tab = env["BOTCHU_TAB"].flatMap(Int.init), tab > 0, let id = model.selection {
            model.showTab(offset: tab, of: id)
        }
        if dataDir != nil, env["BOTCHU_DEMO"] == "activity", let id = model.selection {
            DemoActivity.install(in: model, target: model.tab(of: id))
        }
        if dataDir != nil, env["BOTCHU_DEMO"] == nil, let title = env["BOTCHU_SUBAGENT"] {
            let delay = env["BOTCHU_RESUME"].flatMap(Double.init)
            Task { @MainActor [weak model] in
                for _ in 0..<80 {
                    guard let model else { return }
                    if let run = model.delegation.all.first(where: { $0.title.hasPrefix(title) && !$0.phase.isActive }) {
                        SubagentFocus.shared.focus(run.id)
                        if let delay {
                            try? await Task.sleep(for: .seconds(delay))
                            model.delegation.resumeByOwner(run.id)
                        }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
        if dataDir != nil, let draft = env["BOTCHU_DRAFT"], let id = model.selection {
            model.drafts[model.tab(of: id)] = draft.replacingOccurrences(of: "\\n", with: "\n")
        }
        if dataDir != nil, let typed = env["BOTCHU_TYPE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { type(typed) }
        }
        if let text = env["BOTCHU_SEND"], let id = model.selection {
            model.send(text, to: model.tab(of: id))
        }
        if let spec = env["BOTCHU_TASK"], let id = model.selection, let bot = model.bot(id) {
            let parts = spec.split(separator: "|", maxSplits: 2).map(String.init)
            let host = parts.count > 2 ? model.settings.hosts.first { $0.nickname == parts[2] } : nil
            // A checkout here (the throwaway repository), or a GitHub repository cloned where it works.
            let checkout = Repositories.find(parts[0], in: model.checkouts())
            let repo = checkout?.repo ?? parts[0]
            let name = TaskNaming.repoName(repo)
            let folder = host.map { ($0.reposFolder as NSString).appendingPathComponent(name) }
                ?? checkout?.path ?? (model.settings.expandedReposRoot as NSString).appendingPathComponent(name)
            let task = BotTask(for: bot, repo: repo, checkout: folder, work: nil,
                               brief: parts.count > 1 ? parts[1] : "Look around and say what this repository is.", host: host)
            model.startTask(task, for: id, show: true)
        }
        // Last, so the report's app state has what the hooks above showed.
        let report = dataDir == nil ? nil : env["BOTCHU_REPORT"]
        if env["BOTCHU_OPEN"] == "report" || report != nil {
            // Once the window shows what the hooks above opened, for its screenshot.
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard let request = await model.openReport(text: report ?? ""), report != nil else { return }
                await request.submit(with: model.issueFiler)
            }
        }
    }

    /// New Issue's filings in Projects' header, one in each state (`BOTCHU_FILINGS=sample`); none runs.
    static func sampleFilings(model: AppModel, bot: Bot) {
        func filing(_ state: IssueFiling.State) -> IssueFiling {
            var filing = IssueFiling(repo: "asieke/BotChu", botID: bot.id, botName: bot.name, accountID: bot.accountID, model: "",
                                     request: "Press I in Projects to file an issue", images: [])
            filing.state = state
            return filing
        }
        model.issueFilings = [filing(.writing), filing(.filed(URL(string: "https://github.com/asieke/BotChu/issues/246"), title: "Press I in Projects to file a new issue with a bot")),
                              filing(.failed("gh couldn't create the issue:\nHTTP 401: Bad credentials (https://api.github.com/graphql)"))]
    }

    /// Types `text` into the message box that has focus (`BOTCHU_TYPE`).
    static func type(_ text: String) {
        guard let editor = NSApp.windows.lazy.compactMap({ $0.firstResponder as? ComposerTextView }).first else { return }
        let keys: [String: (code: UInt16, characters: String)] = ["down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "tab": (48, "\t"),
                                                                   "return": (36, "\r"), "escape": (53, "\u{1B}")]
        var rest = Substring(text.replacingOccurrences(of: "\\n", with: "\n"))
        while let character = rest.first {
            if character == "{", let end = rest.firstIndex(of: "}"), let key = keys[String(rest[rest.index(after: rest.startIndex)..<end])],
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: editor.window?.windowNumber ?? 0,
                                            context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                                            isARepeat: false, keyCode: key.code) {
                editor.keyDown(with: event)
                rest = rest[rest.index(after: end)...]
            } else {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
                rest = rest.dropFirst()
            }
        }
    }

    /// Sample jobs for a review (`BOTCHU_JOBS=sample`): for the first bot a weekday triage with a
    /// history of every kind of run, its latest a task beside the chat (#146) and an older one with a
    /// transcript, and a paused job; for the second, a job
    /// every 90 minutes that is waiting; and Home's receipt for the triage's last finding. Saved in
    /// the throwaway bots' folders; none ever runs.
    static func sampleJobs(model: AppModel) {
        guard let first = model.bots.first else { return }
        let now = Date()
        let zone = TimeZone.current.identifier
        func run(_ outcome: JobOutcome, hoursAgo: Double, trigger: JobTrigger = .scheduled, quiet: Bool = false, summary: String) -> JobRun {
            let at = now.addingTimeInterval(-hoursAgo * 3600)
            var run = JobRun(trigger: trigger, scheduledFor: trigger == .manual ? nil : at.addingTimeInterval(trigger == .catchUp ? -5 * 3600 : 0),
                             timeZone: zone, reservedAt: at, outcome: outcome, summary: summary)
            run.startedAt = outcome == .skipped ? nil : at
            run.finishedAt = outcome.isActive ? nil : at.addingTimeInterval(140)
            run.quiet = quiet
            run.accountID = first.accountID
            run.accountName = first.account.name
            return run
        }
        var triage = Job(botID: first.id, title: "Morning issue triage",
                         prompt: "Look at the issues opened since yesterday in my repositories, label them, and tell me which need me.",
                         schedule: JobSchedule(kind: .weekdays, hour: 9, minute: 0, timeZone: zone), createdAt: now.addingTimeInterval(-9 * 86_400))
        triage.handledThrough = now.addingTimeInterval(-3600)
        triage.runs = [
            run(.succeeded, hoursAgo: 120, summary: "Two new bugs need you: #12 (crash on launch) and #15 (login loop). Labelled four others."),
            run(.skipped, hoursAgo: 96, summary: "Missed while BotChu was closed or the Mac asleep; this job skips missed runs."),
            run(.succeeded, hoursAgo: 72, quiet: true, summary: "Checked 6 issues."),
            run(.interrupted, hoursAgo: 50, summary: "BotChu quit or stopped during this run. It may have done part of its work, so it isn't run again."),
            run(.failed, hoursAgo: 48, summary: "API Error: 429 rate limit exceeded — \(first.account.name) is out of allowance for now; it runs again at its next time, or Run Now once it resets."),
            run(.succeeded, hoursAgo: 25, trigger: .catchUp, summary: "Caught up on the weekend: #18 needs a decision on the API shape."),
            run(.succeeded, hoursAgo: 1, summary: "One new issue needs you: #21 asks for SSH hosts in Settings."),
        ]
        func transcript(on bot: Bot) -> [ChatMessage] {
            [ChatMessage(role: .note, text: "Started on \(bot.account.name)"),
             ChatMessage(role: .tool, toolID: "1", toolName: "Bash", toolInput: "gh issue list --state open --limit 20", toolState: .done),
             ChatMessage(role: .assistant, text: "**One new issue needs you:** #21 asks for SSH hosts in Settings.\n\n- #19 and #20 are labelled `bug` and assigned.\n- #22 is a duplicate of #14; I closed it with a link.")]
        }
        // Its latest run is a task beside the first bot's chat (#146), its conversation the run's.
        if let i = triage.runs.indices.last, let startedAt = triage.runs[i].startedAt {
            let task = JobTasks.task(for: first, job: triage, run: triage.runs[i], startedAt: startedAt)
            triage.runs[i].taskID = task.id
            if let target = model.startJobTask(task, for: first.id) {
                var messages = transcript(on: first)
                messages.insert(ChatMessage(role: .user, text: triage.prompt), at: 1)
                model.conversation(target).replace(messages)
                model.saveThread(target)
            }
        }
        var weekly = Job(botID: first.id, title: "Friday release notes", prompt: "Draft release notes from this week's merged pull requests.",
                         schedule: JobSchedule(kind: .days, hour: 16, minute: 30, days: [6], timeZone: zone), enabled: false,
                         createdAt: now.addingTimeInterval(-30 * 86_400))
        weekly.pauseReason = "Paused after 3 failed runs in a row. Fix what failed, then Resume."
        weekly.runs = [run(.failed, hoursAgo: 170, summary: "Invalid API key · Please run /login — Sign in to \(first.account.name) in Terminal, then Run Now.")]
        // On a CLI profile that is gone, so its runs are on its agent's.
        weekly.runsOn = JobRunsOn(accountID: "custom-review-gone", accountProfile: Account(id: "custom-review-gone", name: "Codex Research", kind: .codex,
                                  defaultCommand: "codex-research", symbol: "terminal"), model: "gpt-6-luna", reasoningEffort: .high)
        var jobs = [triage, weekly]
        if model.bots.count > 1 {
            let second = model.bots[1]
            var check = Job(botID: second.id, title: "Check the deploy", prompt: "Check that the site responds and the last deploy succeeded.",
                            schedule: JobSchedule(kind: .interval, every: 90, unit: .minutes, anchor: now.addingTimeInterval(-6 * 3600), timeZone: zone),
                            createdAt: now.addingTimeInterval(-86_400), runsOn: JobRunsOn(accountID: "claude-work", model: "sonnet", reasoningEffort: .low))
            check.handledThrough = now.addingTimeInterval(-600)
            var waiting = JobRun(trigger: .scheduled, scheduledFor: now.addingTimeInterval(-600), timeZone: zone, reservedAt: now.addingTimeInterval(-600))
            waiting.outcome = .waiting
            check.runs = [run(.succeeded, hoursAgo: 2, quiet: true, summary: "Site up; last deploy succeeded."), waiting]
            jobs.append(check)
        }
        for job in jobs {
            guard let bot = model.bot(job.botID) else { continue }
            let home = BotHome(workspace: bot.persistencePath)
            try? home.save(job)
            if let last = job.runs.last(where: { $0.outcome == .succeeded && !$0.quiet && $0.taskID == nil }) {
                try? home.saveJobThread(transcript(on: bot), job: job.id, run: last.id)
            }
        }
        model.jobs.addSamples(jobs)
        // Home's receipt for the triage's last finding, with Open Run.
        if let last = triage.runs.last {
            model.postJobReceipt(JobReceipt.text(job: triage, run: last), job: triage.id, run: last.id, to: first.id)
        }
    }

    private static func snapshotRow(_ bot: Bot, model: AppModel) -> some View {
        BotRow(bot: bot, status: model.status(of: bot), summary: model.botRowSummary(of: bot),
               selected: model.visibleBotID == bot.id)
            .padding(.horizontal, 6)
            .background(model.visibleBotID == bot.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The sidebar's rows as `sidebar.png`; the sidebar's material isn't in the window's picture.
    static func snapshotSidebar(model: AppModel, into dir: URL) {
        let rows = VStack(alignment: .leading, spacing: 4) {
            Text("Workspace").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 6)
            ForEach(LibraryDestination.sidebar, id: \.self) { destination in
                HStack {
                    Label(destination.title, systemImage: destination.symbol)
                    Spacer()
                    // What in the Inbox isn't Done, as the sidebar's badge shows it.
                    if destination == .inbox, model.inbox.unfinishedCount > 0 {
                        Text("\(model.inbox.unfinishedCount)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(model.destination == destination ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            // Each section's heading, and its bots unless it is collapsed (as the sidebar keeps it).
            let collapsed = CollapsedSections(rawValue: UserDefaults.standard.string(forKey: CollapsedSections.storageKey) ?? "")
            let specialists = model.specialists
            ForEach(model.agentSections.groups.filter { !$0.botIDs.isEmpty || specialists.isEmpty }) { group in
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 6)
                if !collapsed.titles.contains(group.title) {
                    ForEach(group.botIDs.compactMap(model.bot)) { bot in snapshotRow(bot, model: model) }
                }
            }
            // Specialists last, collapsed with its busy dots unless opened (#250).
            if !specialists.isEmpty {
                let expanded = UserDefaults.standard.bool(forKey: "sidebar.specialistsExpanded")
                let summary = BotRowSummary(merging: specialists.map { ($0.name, model.botRowSummary(of: $0)) })
                HStack {
                    Text("Specialists").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if !expanded, !summary.dots.isEmpty { BotRowDots(summary: summary) }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                if expanded { ForEach(specialists) { bot in snapshotRow(bot, model: model) } }
            }
            // What sits above New Bot while the sidebar's changes aren't saved.
            if let failure = model.indexFailure { IndexFailureBanner(failure: failure).padding(.horizontal, -10) }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        // The sidebar's own dark shade; in light mode the window's background stands in for its material.
        .modifier(SidebarShade())
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(model)
        // Native progress indicators and buttons cannot be drawn by ImageRenderer. Host the
        // rows offscreen so sidebar snapshots include their real AppKit controls as well.
        let host = NSHostingView(rootView: rows)
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("sidebar.png"))
    }

    /// Each visible window as `<n>-<title>.png`, drawn by the app itself.
    /// Video layers aren't in a view's cached drawing, so each pet's current frame (and where it
    /// shows, in `root`'s coordinates) is collected to be drawn over the picture, and its player's
    /// state is written to `pets.txt`.
    static func petVideoFrames(in root: NSView) -> [(CGImage, CGRect)] {
        var frames: [(CGImage, CGRect)] = []
        var players: [String] = []
        func visit(_ view: NSView) {
            if let pet = view as? PetVideoLayerView {
                let rect = pet.convert(pet.bounds, to: root)
                players.append(pet.debugState + String(format: " at %.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height))
                if let image = pet.currentFrame() { frames.append((image, rect)) }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        if let dir = env["BOTCHU_SNAPSHOT"] {
            try? (players.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: dir).appendingPathComponent("pets.txt"),
                                                               atomically: true, encoding: .utf8)
        }
        return frames
    }

    /// The window's picture with the pets' frames drawn in their circles.
    /// Each delivered page's latest picture (`OfflinePage`): `cacheDisplay` can't draw a web view,
    /// which renders in another process, so its picture is asked for at one snapshot and drawn in at
    /// the next. (Only those: the chat's own web views are drawn as they are, and not all shown.)
    @MainActor private static var webPictures: [ObjectIdentifier: CGImage] = [:]

    /// The delivered pages' pictures in `root`, where they show.
    static func webViewFrames(in root: NSView) -> [(CGImage, CGRect)] {
        var found: [(CGImage, CGRect)] = []
        func walk(_ view: NSView) {
            if let web = view as? OfflinePage.WebView {
                let id = ObjectIdentifier(web), visible = web.visibleRect
                guard !visible.isEmpty, !web.isHiddenOrHasHiddenAncestor else { return }
                let configuration = WKSnapshotConfiguration()
                configuration.rect = visible
                web.takeSnapshot(with: configuration) { image, _ in
                    if let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { webPictures[id] = picture }
                }
                if let picture = webPictures[id] { found.append((picture, web.convert(visible, to: root))) }
                return
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    static func composite(_ rep: NSBitmapImageRep, root: NSView) -> Data? {
        let frames = petVideoFrames(in: root)
        let pages = webViewFrames(in: root)
        guard let base = rep.cgImage else { return nil }
        if frames.isEmpty && pages.isEmpty { return rep.representation(using: .png, properties: [:]) }
        let width = base.width, height = base.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / root.bounds.width
        for (image, rect) in pages {
            let y = root.isFlipped ? root.bounds.height - rect.maxY : rect.minY
            context.draw(image, in: CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale))
        }
        for (image, rect) in frames {
            let y = root.isFlipped ? root.bounds.height - rect.maxY : rect.minY
            let target = CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale)
            context.saveGState()
            context.addEllipse(in: target)
            context.clip()
            context.draw(image, in: target)
            context.restoreGState()
        }
        guard let combined = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: combined).representation(using: .png, properties: [:])
    }

    static func snapshot(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window" : window.title.replacingOccurrences(of: "/", with: "-")
            try? composite(rep, root: view)?.write(to: dir.appendingPathComponent("\(n)-\(name).png"))
        }
    }
}

/// Frame marks for the journeys harness (#323, `FrameMarks`): with `BOTCHU_TIMINGS=<file>`, each
/// named change is appended to that file with the time its frame was committed, taken after every
/// other observer of the run loop pass that made the change, Core Animation's commit included.
/// Without the variable nothing is recorded or observed.
@MainActor enum FrameTimings {
    private static let file: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment[FrameMarks.environmentKey], !path.isEmpty else { return nil }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }()
    private static var pending: [String] = []
    private static var observer: CFRunLoopObserver?
    private static var sidebarWatch: [NSObjectProtocol] = []
    private static var busyObservers: [CFRunLoopObserver] = []
    /// When the main thread last woke, until it waits again.
    private static var woke: UInt64 = 0

    static func mark(_ name: @autoclosure () -> String) {
        guard file != nil else { return }
        let name = name()
        if !pending.contains(name) { pending.append(name) }
        guard observer == nil else { return }
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                      true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { flush() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func flush() {
        guard !pending.isEmpty, let file else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let lines = pending.map { FrameMarks.line($0, at: now) }.joined()
        pending.removeAll()
        try? file.write(contentsOf: Data(lines.utf8))
    }

    /// Writes each stretch the main thread is busy for `FrameMarks.busyThreshold` or more without
    /// letting a frame be committed: from waking until it is about to wait again, after every other
    /// observer of that pass, Core Animation's commit included (`FrameMarks.busy`).
    static func watchBusy() {
        guard file != nil, busyObservers.isEmpty else { return }
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { woke = DispatchTime.now().uptimeNanoseconds }
        }
        let wait = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                guard woke > 0, let file else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let milliseconds = Double(now - woke) / 1_000_000
                woke = 0
                guard milliseconds >= FrameMarks.busyThreshold else { return }
                try? file.write(contentsOf: Data(FrameMarks.line(FrameMarks.busy(milliseconds: milliseconds), at: now).utf8))
            }
        }
        busyObservers = [wake, wait].compactMap { $0 }
        for observer in busyObservers { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    /// Marks the sidebar starting to hide or show, once the main window's split view is there: the
    /// first resize of its subviews that narrows or widens the part of the sidebar in view. Also
    /// marks the window's content laid out at a new size (`FrameMarks.windowResized`).
    static func watchSidebar(attempt: Int = 0) {
        guard let file, sidebarWatch.isEmpty else { return }
        func splitViews(in view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splitViews)
        }
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.titled) && $0.contentView != nil }),
              let split = splitViews(in: window.contentView!).first, let sidebar = split.arrangedSubviews.first else {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { watchSidebar(attempt: attempt + 1) } }
            return
        }
        let watch = SidebarWatch(split: split, sidebar: sidebar)
        sidebarWatch = [NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: nil) { _ in
            MainActor.assumeIsolated { watch.resized() }
        }, NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: nil) { _ in
            MainActor.assumeIsolated { mark(FrameMarks.windowResized) }
        }]
        try? file.write(contentsOf: Data("# sidebar: \(type(of: split)), \(Int(watch.last)) pt in view\n".utf8))
    }

    /// How much of the sidebar was in view at its split view's last resize.
    @MainActor private final class SidebarWatch {
        let split: NSSplitView
        let sidebar: NSView
        var last: CGFloat
        var shown: Bool

        init(split: NSSplitView, sidebar: NSView) {
            self.split = split
            self.sidebar = sidebar
            last = Self.inView(sidebar, of: split)
            shown = last > 1
        }

        /// A collapsed sidebar keeps its frame, hidden.
        static func inView(_ sidebar: NSView, of split: NSSplitView) -> CGFloat {
            sidebar.isHidden || split.isSubviewCollapsed(sidebar) ? 0 : sidebar.frame.intersection(split.bounds).width
        }

        func resized() {
            let width = Self.inView(sidebar, of: split)
            defer { last = width }
            if shown, width < last { shown = false; FrameTimings.mark(FrameMarks.sidebar(shown: false)) }
            else if !shown, width > last { shown = true; FrameTimings.mark(FrameMarks.sidebar(shown: true)) }
        }
    }
}
