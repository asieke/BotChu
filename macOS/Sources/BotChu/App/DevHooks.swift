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
/// - `BOTCHU_OPEN`: open `editor` (a new bot), `task` (New Task), `memory`, `soul`, or `settings` at launch.
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
///   in memory (`DemoActivity`), to review the chat's activity cards without a real turn.
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
/// - `BOTCHU_OPEN=report`: open Report a Bug or Feature; `BOTCHU_REPORT`, with `BOTCHU_DATA_DIR`: open it
///   with this report and file it, with the stand-in `gh`.
/// - `BOTCHU_JOBS=sample`: with `BOTCHU_DATA_DIR`, give the bots sample scheduled jobs with a history
///   of every kind of run (`sampleJobs`), and run no job, so nothing starts a CLI. `BOTCHU_OPEN=jobs`
///   opens Jobs, `job-editor` the editor for a new job, `job-edit` the editor for the job titled
///   `BOTCHU_JOB` (else the first), and `job-history` the first job's history.
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

    /// What takes a report's screenshot: the window itself, except in a throwaway run with
    /// `BOTCHU_SCREENSHOT_FAIL`, which can't take one, to show the report without it.
    static var windowCapture: WindowCapture.Capture {
        guard dataDir != nil, env["BOTCHU_SCREENSHOT_FAIL"] != nil else { return WindowCapture.screen }
        return { _ in throw ImageDelivery.Failure("The window isn't on screen.") }
    }

    static var usageFetch: UsageCache.Fetch? {
        guard dataDir != nil, let fixture = env["BOTCHU_USAGE"],
              ["sample", "stale", "expired", "unavailable", "mixed"].contains(fixture) else { return nil }
        let started = Date()
        return { request, _ in
            if fixture == "unavailable" { throw UsageFailure("Check the account’s sign-in, then refresh.") }
            let now = Date()
            if fixture == "mixed", let reading = try mixedUsage(request.account, now: now, started: started) { return reading }
            let readAt = now.addingTimeInterval(fixture == "stale" ? -7_200 : 0)
            switch request.account.kind {
            case .pi:
                // A key with a weekly spending limit.
                return ProviderUsage(windows: [UsageWindow(id: "key", title: "Key allowance", usedPercent: 26.4,
                    resetsAt: now.addingTimeInterval(fixture == "expired" ? -60 : 302_400), detail: "$18.40 of $25.00 left")], readAt: readAt)
            case .codex:
                // Codex says whether the account has usage credits and free resets.
                return ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 41, resetsAt: now.addingTimeInterval(fixture == "expired" ? -60 : 388_800))],
                                     readAt: readAt, credits: UsageCredits(available: true, balance: 65_292.36),
                                     resets: UsageResets(available: 2, expiries: [now.addingTimeInterval(432_000), now.addingTimeInterval(1_123_200)]))
            default:
                return ProviderUsage(windows: [
                    UsageWindow(id: "session", title: "5-hour", usedPercent: 24,
                                resetsAt: now.addingTimeInterval(fixture == "expired" ? -60 : 7_200)),
                    UsageWindow(id: "week", title: "Weekly", usedPercent: 83, resetsAt: now.addingTimeInterval(259_200)),
                ], readAt: readAt)
            }
        }
    }

    /// `BOTCHU_USAGE=mixed`: Antigravity with more windows than a row shows, Muse stale, Pi's key
    /// without a limit, Codex Personal with no credits and one free reset, Codex Work unavailable,
    /// and Claude Work whose first reading is followed by a failed check (`start` makes it); the
    /// others get the sample.
    nonisolated private static func mixedUsage(_ account: Account, now: Date, started: Date) throws -> ProviderUsage? {
        switch account.id {
        case "codex-personal":
            return ProviderUsage(windows: [UsageWindow(id: "week", title: "Weekly", usedPercent: 100, resetsAt: now.addingTimeInterval(97_200))],
                                 readAt: now, credits: UsageCredits(available: false, balance: 0),
                                 resets: UsageResets(available: 1, expiries: [now.addingTimeInterval(259_200)]))
        case "google":
            return ProviderUsage(windows: ["Gemini · Weekly", "Gemini · 5-hour", "Claude & GPT · Weekly", "Claude & GPT · 5-hour", "Images · Daily"].enumerated().map {
                UsageWindow(id: $1, title: $1, usedPercent: Double([22, 4, 97, 0, 61][$0]), resetsAt: now.addingTimeInterval(Double($0 + 1) * 9_000))
            }, readAt: now)
        case "muse":
            return ProviderUsage(windows: [UsageWindow(id: "window", title: "5-hour", usedPercent: 5, resetsAt: now.addingTimeInterval(3_600)),
                                           UsageWindow(id: "weekly", title: "Weekly", usedPercent: 34, resetsAt: now.addingTimeInterval(172_800))],
                                 readAt: now.addingTimeInterval(-7_200))
        case "openrouter": return ProviderUsage(windows: [], note: "No key spending limit · $1.25 used", readAt: now)
        case "codex-work": throw UsageFailure("Could not read account usage. Check the CLI’s sign-in and command, then refresh.")
        case "claude-work" where now.timeIntervalSince(started) > 2: throw UsageFailure("Usage check timed out. Try refreshing later.")
        default: return nil
        }
    }

    static func start(model: AppModel, openSettings: () -> Void) {
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
        if dataDir != nil, env["BOTCHU_JOBS"] == "sample" { sampleJobs(model: model) }
        switch env["BOTCHU_OPEN"] {
        case "inbox", "projects", "agents", "providers", "skills", "jobs":
            model.destination = env["BOTCHU_OPEN"].flatMap(LibraryDestination.init(rawValue:))
            if let item = env["BOTCHU_INBOX_ITEM"].flatMap(UUID.init(uuidString:)) { model.inbox.selected = item }
            if let repo = env["BOTCHU_PROJECT"] {
                model.selectProject(repo, tab: env["BOTCHU_PROJECT_TAB"].flatMap(ProjectSelection.Tab.init(rawValue:)) ?? .overview,
                                    item: env["BOTCHU_PROJECT_ITEM"].flatMap(Int.init))
            }
        case "editor": model.newBot()
        case "job-editor", "job-model", "job-effort": model.jobs.newJob(for: model.selection)
        case "job-edit":
            if let job = model.jobs.jobs.first(where: { $0.title == env["BOTCHU_JOB"] }) ?? model.jobs.jobs.first { model.jobs.edit(job.id) }
        case "job-history": if let job = model.jobs.jobs.first { model.jobs.showHistory(job.id) }
        case "task": if let id = model.selection { model.newTask(for: id) }
        case "memory": if let id = model.selection { model.editDocument(.memory, for: id) }
        case "soul": if let id = model.selection { model.editDocument(.soul, for: id) }
        case "settings": openSettings()
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
            let target = PetVideo.folder(for: BotHome(workspace: bot.workspace))
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
            let home = BotHome(workspace: bot.workspace)
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

    /// The sidebar's rows as `sidebar.png`; the sidebar's material isn't in the window's picture.
    static func snapshotSidebar(model: AppModel, into dir: URL) {
        let rows = VStack(alignment: .leading, spacing: 4) {
            Text("Workspace").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 6)
            ForEach(LibraryDestination.allCases, id: \.self) { destination in
                HStack {
                    Label(destination.title, systemImage: destination.symbol)
                    Spacer()
                    // The Inbox's unread count, as the sidebar's badge shows it.
                    if destination == .inbox, model.inbox.unreadCount > 0 {
                        Text("\(model.inbox.unreadCount)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(model.destination == destination ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
            }
            // Each section's heading, and its bots unless it is collapsed (as the sidebar keeps it).
            let collapsed = CollapsedSections(rawValue: UserDefaults.standard.string(forKey: CollapsedSections.storageKey) ?? "")
            ForEach(model.botSections.groups) { group in
                Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 6)
                if !collapsed.titles.contains(group.title) {
                    ForEach(group.botIDs.compactMap(model.bot)) { bot in
                        BotRow(bot: bot, status: model.status(of: bot), summary: model.botRowSummary(of: bot),
                               selected: model.visibleBotID == bot.id)
                            .padding(.horizontal, 6)
                            .background(model.visibleBotID == bot.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
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
