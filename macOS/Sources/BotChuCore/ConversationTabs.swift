import Foundation

/// How a conversation, a bot's Home or one of its tasks, is doing, as its tab's dot and second line
/// say it (#128): from its status, whether a turn finished since it was last shown (`unread`), its
/// task's pull request, and the Needs input deliveries it waits on the owner for (#218). The most
/// urgent wins: needs input, then failed or stopped, then a turn under way, then a finished turn
/// not yet seen, then idle.
public enum TabState: Equatable, Sendable {
    /// Nothing under way; `since` is its last activity.
    case idle(since: Date?)
    /// BotChu is making the task's worktree, before its turn starts.
    case preparing
    /// A turn started, and its CLI has printed nothing yet.
    case starting(since: Date?)
    case working(BotActivity, since: Date?)
    /// A turn finished since the conversation was last shown, with the task's pull request.
    case news(pullRequest: Int?, at: Date?)
    /// The last turn failed. It stays so until the next turn starts, whether it was looked at or not.
    case failed(at: Date?)
    /// The owner stopped the last turn. Like a failure, it stays so until the next turn starts.
    case stopped(at: Date?)
    /// It sent the owner Needs input deliveries (`requests`, the newest `at`) that aren't answered
    /// or Done; reading them doesn't count (`InboxState.awaitingInput`).
    case needsInput(requests: Int, at: Date?)

    /// What the dot shows.
    public enum Kind: Equatable, Sendable {
        case idle, preparing, starting, working, news, failed, stopped, needsInput

        /// A turn is under way, or about to start.
        public var isActive: Bool { self == .preparing || self == .starting || self == .working }

        /// How much it asks for the owner's attention: the bot list's dots show the most urgent first.
        public var urgency: Int {
            switch self {
            case .needsInput: 4
            case .failed, .stopped: 3
            case .preparing, .starting, .working: 2
            case .news: 1
            case .idle: 0
            }
        }

        /// The state in a word or two, for the dots' tooltip and VoiceOver (`count` of them).
        public func name(count: Int) -> String {
            switch self {
            case .idle: "idle"
            case .preparing: "preparing"
            case .starting: "starting"
            case .working: "working"
            case .news: "finished"
            case .failed: "failed"
            case .stopped: "stopped"
            case .needsInput: count == 1 ? "needs input" : "need input"
            }
        }

        /// Whether a change from `old` to this is a turn ending, when the dot pops once.
        public func endsTurn(from old: Kind) -> Bool { old.isActive && !isActive }
    }

    /// `awaitingInput` holds when each of its unresolved Needs input deliveries was sent.
    public init(status: BotStatus, unread: Bool, pullRequest: Int? = nil, awaitingInput: [Date] = []) {
        if !awaitingInput.isEmpty {
            self = .needsInput(requests: awaitingInput.count, at: awaitingInput.max())
            return
        }
        switch status.phase {
        case .preparing: self = .preparing
        case .starting: self = .starting(since: status.runStartedAt)
        case .working: self = .working(status.activity, since: status.runStartedAt)
        case .failed: self = .failed(at: status.lastActivity)
        case .stopped: self = .stopped(at: status.lastActivity)
        case .idle: self = unread ? .news(pullRequest: pullRequest, at: status.lastActivity) : .idle(since: status.lastActivity)
        }
    }

    public var kind: Kind {
        switch self {
        case .idle: .idle
        case .preparing: .preparing
        case .starting: .starting
        case .working: .working
        case .news: .news
        case .failed: .failed
        case .stopped: .stopped
        case .needsInput: .needsInput
        }
    }

    /// The state in words; nil while idle, when the tab names only where it is.
    public var text: String? {
        switch self {
        case .idle: nil
        case .preparing: "Making the worktree…"
        case .starting: "Starting…"
        case .working(let activity, _): activity.doing
        case .news(let pullRequest, _): pullRequest.map { "Finished · PR #\($0)" } ?? "Finished"
        case .failed: "Turn failed"
        case .stopped: "Stopped"
        case .needsInput(let requests, _): requests == 1 ? "Needs input" : "\(requests) requests need input"
        }
    }

    /// The time on the right of the second line: a running turn's elapsed time (4:12), which ticks
    /// each second, else how long ago it was last active, finished or failed (2m, 1h, 1d).
    public func time(at now: Date) -> String? {
        switch self {
        case .preparing: nil
        case .starting(let since), .working(_, let since): since.map { BotStatus.formatElapsed(from: $0, to: now) }
        case .idle(let at), .news(_, let at), .failed(let at), .stopped(let at), .needsInput(_, let at):
            at.map { Self.ago(now.timeIntervalSince($0)) }
        }
    }

    /// When the running turn started, else when it was last active, finished or failed: what `time` counts from.
    public var since: Date? {
        switch self {
        case .preparing: nil
        case .starting(let since), .working(_, let since): since
        case .idle(let at), .news(_, let at), .failed(let at), .stopped(let at), .needsInput(_, let at): at
        }
    }

    /// The time as VoiceOver reads it: "4 minutes 12 seconds", "2 minutes ago".
    public func spokenTime(at now: Date) -> String? {
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        switch self {
        case .preparing: return nil
        case .starting(let since), .working(_, let since):
            guard let since else { return nil }
            let total = max(0, Int(now.timeIntervalSince(since)))
            let parts = [(total / 3600, "hour"), (total % 3600 / 60, "minute"), (total % 60, "second")]
                .filter { $0.0 > 0 }.map { unit($0.0, $0.1) }
            return parts.isEmpty ? unit(0, "second") : parts.joined(separator: " ")
        case .idle(let at), .news(_, let at), .failed(let at), .stopped(let at), .needsInput(_, let at):
            guard let at else { return nil }
            let seconds = max(0, Int(now.timeIntervalSince(at)))
            if seconds < 60 { return "just now" }
            let (n, name) = seconds < 3600 ? (seconds / 60, "minute") : seconds < 86_400 ? (seconds / 3600, "hour") : (seconds / 86_400, "day")
            return unit(n, name) + " ago"
        }
    }

    /// How long ago, as short as a tab has room for: now, 2m, 1h, 1d.
    public static func ago(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "now" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3600)h" }
        return "\(total / 86_400)d"
    }
}

/// What a conversation's tab says (#128): on its first, prominent line the repository it works in
/// and its issue's number ("BotChu #113"), its job for a job's run, or Home. Home's second line says
/// what it is doing, with a time, or while idle its account. A task's has three (#192): what it is
/// about, in its saved summary's words when it has one, then what it is doing, with a time.
public struct ConversationTab: Equatable, Sendable {
    public var isHome: Bool
    /// "Home", the task's repository, by its name without its owner, or a job's run's job (#146).
    public var name: String
    /// The task's issue or pull request; nil for Home and a task from a brief.
    public var number: Int?
    public var isReview: Bool
    /// A run of one of the bot's scheduled jobs (#146).
    public var isJob: Bool = false
    /// A Project Area's kind (#399): a repository's or a folder's lasting conversation; nil for
    /// Home and a task.
    public var area: AreaInfo.Kind?
    /// The host the task works on; nil on this Mac, and for Home.
    public var machine: String?
    /// What the task is about: its issue's or pull request's title, else its brief. Home's account.
    public var subject: String
    /// The task's saved label of three or four words (`BotTask.summary`); nil for Home and a task
    /// without one.
    public var summary: String?
    public var state: TabState
    /// The tooltip's parts before the shortcut: `owner/name`, `Issue #105`, `This Mac`.
    var about: [String]

    public static func home(account: String, state: TabState) -> ConversationTab {
        ConversationTab(isHome: true, name: "Home", number: nil, isReview: false, machine: nil, subject: account, state: state, about: ["Home"])
    }

    /// A task's tab; `machine` is the host it works on, nil on this Mac. A job's run names its job,
    /// and is about the time it was for.
    public init(task: BotTask, machine: String?, state: TabState) {
        isHome = false
        name = task.jobRun?.jobTitle ?? task.repoName
        number = task.work?.number
        isReview = task.review != nil
        isJob = task.jobRun != nil
        self.machine = machine
        subject = Self.subject(of: task)
        summary = task.summary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        self.state = state
        if let origin = task.jobRun {
            self.about = ["Job “\(origin.jobTitle)”", machine ?? "This Mac"]
            return
        }
        if let info = task.area {
            area = info.kind
            name = info.name
            subject = info.kind == .repo ? task.repo : Self.abbreviated(task.checkout)
            self.about = [subject, machine ?? "This Mac"]
            return
        }
        var about = [task.repo]
        if let work = task.work {
            about.append((work.isPullRequest ? "Pull request #" : "Issue #") + "\(work.number)" + (isReview ? " review" : ""))
        }
        about.append(machine ?? "This Mac")
        self.about = about
    }

    init(isHome: Bool, name: String, number: Int?, isReview: Bool, machine: String?, subject: String, state: TabState, about: [String]) {
        self.isHome = isHome
        self.name = name
        self.number = number
        self.isReview = isReview
        self.machine = machine
        self.subject = subject
        self.state = state
        self.about = about
    }

    /// The issue's or pull request's title; else the brief's words, from the task's title
    /// ("GitChu · Speed up the sync"), or its whole first line when the title is the one BotChu
    /// gave it (it has more room than the title's 28 characters); else the task's title. A task
    /// whose issue isn't looked up yet names it: "Issue #113". A job's run: the time it was for.
    public static func subject(of task: BotTask) -> String {
        if let origin = task.jobRun { return JobTasks.when(origin) }
        if let work = task.work {
            if !work.title.isEmpty { return work.title }
            return task.title == TaskNaming.title(repo: task.repo, work: work, brief: task.brief, review: task.review != nil)
                ? (work.isPullRequest ? "Pull request #" : "Issue #") + "\(work.number)" : task.title
        }
        if task.title == TaskNaming.title(repo: task.repo, work: nil, brief: task.brief) {
            let line = TaskNaming.shortened(task.brief, limit: .max)
            if !line.isEmpty { return line }
        }
        let prefix = task.repoName + " · "
        return task.title.hasPrefix(prefix) ? String(task.title.dropFirst(prefix.count)) : task.title
    }

    /// A folder as the owner reads it: `~/…` inside their home folder.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// "#113", after the repository's name on the first line.
    public var numberText: String? { number.map { "#\($0)" } }

    /// The first line as one string: "BotChu #113", "Home".
    public var title: String { [name, numberText].compactMap { $0 }.joined(separator: " ") }

    /// The second line's left side: what it is doing, or while idle what it is about (Home: its
    /// account).
    public var detail: String { state.text ?? subject }

    /// A task's second line: its summary, else what it is about.
    public var label: String { summary ?? subject }

    /// The last line's left side: a task's state, "Idle" when nothing is under way; Home's `detail`.
    public var status: String { isHome ? detail : state.text ?? "Idle" }

    /// What VoiceOver reads for the tab: its title (and host), what it is about, what it is doing,
    /// and its time.
    public func spoken(at now: Date) -> String {
        let name = (isReview ? "Review of " : isJob ? "Run of job " : "") + title + (machine.map { " on \($0)" } ?? "")
        return [name, summary, subject, isHome ? state.text : status, state.spokenTime(at: now)].compactMap { $0 }.joined(separator: ", ")
    }

    /// A rail tile's tooltip: the first line (and its host), a task's label, then its status, time
    /// and shortcut; Home's what it is doing while it works.
    public func railHelp(at now: Date, shortcut: String?) -> String {
        let first = title + (machine.map { " · \($0)" } ?? "")
        let about = isHome ? [] : [label]
        let last = [status, state.time(at: now), shortcut].compactMap { $0 }.joined(separator: " · ")
        return ([first] + about + [last]).joined(separator: "\n")
    }

    /// The tooltip: what a task is about, then `owner/name · Issue #105 · This Mac · ⌘2`; Home's
    /// is `Home · ⌘1`.
    public func help(shortcut: String?) -> String {
        let place = (about + [shortcut].compactMap { $0 }).joined(separator: " · ")
        return isHome ? place : subject + "\n" + place
    }

    /// ⌘1 shows Home and ⌘2 to ⌘9 the first eight tasks: the shortcut of the tab at `index` among
    /// Home and the open tasks, in their order.
    public static func shortcut(forTab index: Int) -> String? {
        (0..<9).contains(index) ? "⌘\(index + 1)" : nil
    }
}

/// A bot's row in the bot list (#128, #324): a small dot for each of its open tasks, an idle one's
/// a ring, and for Home while it isn't idle, the most urgent first (#218); and a subtitle that says
/// what it runs on, whatever it is doing.
public struct BotRowSummary: Equatable, Sendable {
    /// The most dots a row shows, two rows of four (#359); the rest are counted (+N).
    public static let dotLimit = 8

    /// The dots, most urgent first (`TabState.Kind.urgency`), and in tab order (Home, then the open
    /// tasks) among equals, so the ones a full row leaves out are the least urgent.
    public var dots: [TabState.Kind]
    /// How many more there are.
    public var more: Int
    /// What the bot runs on (`runsOn`): "Claude Personal · Fable 5.1".
    public var subtitle: String
    /// What the dots say, for VoiceOver and the tooltip: "1 needs input, 2 working, 3 idle".
    public var spokenDots: String

    /// Delegated work is an aggregate dot, independent of Home and tasks: a specialist can be
    /// called without running either conversation. It stays while any call is active (#389).
    /// The open Project Areas (#399), which stay, have a dot as Home has, while they aren't idle;
    /// `tasks` are the other open tasks, each with a dot.
    public init(runsOn: String, home: TabState, areas: [TabState] = [], tasks: [TabState], workingAsSubagent: Bool = false) {
        var kinds = ([home] + areas).map(\.kind).filter { $0 != .idle } + tasks.map(\.kind)
        if workingAsSubagent { kinds.append(.working) }
        let shown = kinds.enumerated()
            .sorted { ($0.element.urgency, -$0.offset) > ($1.element.urgency, -$1.offset) }
            .map(\.element)
        dots = Array(shown.prefix(Self.dotLimit))
        more = max(0, shown.count - Self.dotLimit)
        subtitle = runsOn
        let order: [TabState.Kind] = [.needsInput, .failed, .stopped, .preparing, .starting, .working, .news, .idle]
        spokenDots = order.compactMap { kind in
            let n = shown.filter { $0 == kind }.count
            return n == 0 ? nil : "\(n) \(kind.name(count: n))"
        }.joined(separator: ", ")
    }

    /// Several bots' rows as one collapsed heading shows them, such as Specialists' in the sidebar
    /// (#250): their dots together, most urgent first and in the rows' order among equals, at most
    /// `dotLimit`, then +N for the rest; spoken as each bot's own dots, by name.
    public init(merging rows: [(name: String, summary: BotRowSummary)]) {
        let busy = rows.flatMap(\.summary.dots).enumerated()
            .sorted { ($0.element.urgency, -$0.offset) > ($1.element.urgency, -$1.offset) }
            .map(\.element)
        dots = Array(busy.prefix(Self.dotLimit))
        more = max(0, busy.count - Self.dotLimit) + rows.map(\.summary.more).reduce(0, +)
        subtitle = ""
        spokenDots = rows.filter { !$0.summary.dots.isEmpty }.map { "\($0.name): \($0.summary.spokenDots)" }.joined(separator: "; ")
    }
}

extension BotRowSummary {
    /// What a bot runs on, as its row and the `@` list say it (#324): its account, then its model
    /// (`modelName`), "Claude Personal · Fable 5.1".
    public static func runsOn(_ settings: any RunSettings, openRouterDefault: String = "", sailDefault: String = "",
                              catalog: [CatalogModel] = [], native: [ModelOption]? = nil) -> String {
        settings.account.name + " · " + modelName(of: settings, openRouterDefault: openRouterDefault, sailDefault: sailDefault,
                                                  catalog: catalog, native: native)
    }

    /// The model the next turn runs, as the picker names it (`ModelPickerData`) but short: without
    /// the family its account implies (Claude Fable 5.1 is Fable 5.1 on Claude Code) or what follows
    /// the name (· default, · latest), and "default" for the account's own until its CLI reports
    /// which model that is. `catalog` is Sail's list; `native` the profile's own (#220).
    public static func modelName(of settings: any RunSettings, openRouterDefault: String = "", sailDefault: String = "",
                                 catalog: [CatalogModel] = [], native: [ModelOption]? = nil) -> String {
        let kind = settings.account.kind
        let selected = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = GenerationOptions.effectiveModel(selected, kind: kind, openRouterDefault: openRouterDefault,
                                                         sailDefault: sailDefault, providerID: settings.providerID)
        let resolved = effective == selected ? settings.resolvedModel.flatMap { $0.isEmpty ? nil : $0 } : nil
        let listed = kind == .sail ? catalog : []
        let title: String
        if effective.isEmpty {
            guard let resolved else { return "default" }
            title = listed.first { $0.id == resolved }?.title ?? GenerationOptions.fullName(resolved, kind: kind, catalog: native)
        } else if let model = listed.first(where: { $0.id == effective }) {
            title = model.title
        } else if kind == .pi, let model = native?.first(where: { $0.id == effective }) {
            title = model.name
        } else {
            title = GenerationOptions.label(for: effective, kind: kind, resolved: resolved, catalog: native).title
        }
        let name = title.components(separatedBy: " · ")[0]
        let family = (kind.displayName.split(separator: " ").first.map(String.init) ?? "") + " "
        return name.hasPrefix(family) && name.count > family.count ? String(name.dropFirst(family.count)) : name
    }
}

/// The Project Areas column's rows (#399), after Home: the bot's open areas in the order it took
/// them on, each followed, indented, by its open tasks in that repository (from before areas),
/// then its other open tasks and job runs as they were opened; its hidden areas are listed apart.
public struct ProjectAreasLayout: Equatable, Sendable {
    public struct Row: Equatable, Hashable, Sendable {
        public var id: UUID
        public var isArea: Bool
        /// A task under its repository's area.
        public var nested: Bool
    }

    public var rows: [Row]
    /// The hidden areas, in the order they were taken on.
    public var hidden: [UUID]

    /// `tasks` are all the bot's, open, closed and areas.
    public init(tasks: [BotTask]) {
        let areas = Areas.areas(in: tasks)
        var others = tasks.filter { !$0.isArea && !$0.isArchived }
        var rows: [Row] = []
        for area in areas where !area.isArchived {
            rows.append(Row(id: area.id, isArea: true, nested: false))
            guard area.area?.kind == .repo, !area.repo.isEmpty else { continue }
            let mine = others.filter { $0.jobRun == nil && $0.repo.caseInsensitiveCompare(area.repo) == .orderedSame }
            rows += mine.map { Row(id: $0.id, isArea: false, nested: true) }
            others.removeAll { task in mine.contains { $0.id == task.id } }
        }
        rows += others.map { Row(id: $0.id, isArea: false, nested: false) }
        self.rows = rows
        hidden = areas.filter(\.isArchived).map(\.id)
    }
}

/// Where the conversation column goes (#128): 240 points beside the chat, which the owner can
/// narrow to 200 or widen to 320, or a 56-point rail of tiles by the owner's choice.
public enum ConversationColumnLayout {
    public static let width: Double = 240
    public static let widths: ClosedRange<Double> = 200...320
    public static let railWidth: Double = 56

    /// A width the owner dragged the column's edge to, within `widths`.
    public static func clamped(_ width: Double) -> Double {
        min(widths.upperBound, max(widths.lowerBound, width))
    }
}
