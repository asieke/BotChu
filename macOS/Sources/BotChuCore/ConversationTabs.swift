import Foundation

/// How a conversation, a bot's Home or one of its tasks, is doing, as its tab's dot and second line
/// say it (#128): from its status, whether a turn finished since it was last shown (`unread`), and
/// its task's pull request.
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

    /// What the dot shows.
    public enum Kind: Equatable, Sendable {
        case idle, preparing, starting, working, news, failed

        /// A turn is under way, or about to start.
        public var isActive: Bool { self == .preparing || self == .starting || self == .working }

        /// Whether a change from `old` to this is a turn ending, when the dot pops once.
        public func endsTurn(from old: Kind) -> Bool { old.isActive && !isActive }
    }

    public init(status: BotStatus, unread: Bool, pullRequest: Int? = nil) {
        switch status.phase {
        case .preparing: self = .preparing
        case .starting: self = .starting(since: status.runStartedAt)
        case .working: self = .working(status.activity, since: status.runStartedAt)
        case .failed: self = .failed(at: status.lastActivity)
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
        }
    }

    /// The time on the right of the second line: a running turn's elapsed time (4:12), which ticks
    /// each second, else how long ago it was last active, finished or failed (2m, 1h, 1d).
    public func time(at now: Date) -> String? {
        switch self {
        case .preparing: nil
        case .starting(let since), .working(_, let since): since.map { BotStatus.formatElapsed(from: $0, to: now) }
        case .idle(let at), .news(_, let at), .failed(let at): at.map { Self.ago(now.timeIntervalSince($0)) }
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
        case .idle(let at), .news(_, let at), .failed(let at):
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
/// and its issue's number ("BotChu #113"), or Home; on the second what it is doing, with a time, or
/// while idle what it is about.
public struct ConversationTab: Equatable, Sendable {
    public var isHome: Bool
    /// "Home", or the task's repository, by its name without its owner.
    public var name: String
    /// The task's issue or pull request; nil for Home and a task from a brief.
    public var number: Int?
    public var isReview: Bool
    /// The host the task works on; nil on this Mac, and for Home.
    public var machine: String?
    /// What the task is about: its issue's or pull request's title, else its brief. Home's account.
    public var subject: String
    public var state: TabState
    /// The tooltip's parts before the shortcut: `owner/name`, `Issue #105`, `This Mac`.
    var about: [String]

    public static func home(account: String, state: TabState) -> ConversationTab {
        ConversationTab(isHome: true, name: "Home", number: nil, isReview: false, machine: nil, subject: account, state: state, about: ["Home"])
    }

    /// A task's tab; `machine` is the host it works on, nil on this Mac.
    public init(task: BotTask, machine: String?, state: TabState) {
        isHome = false
        name = task.repoName
        number = task.work?.number
        isReview = task.review != nil
        self.machine = machine
        subject = Self.subject(of: task)
        self.state = state
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
    /// whose issue isn't looked up yet names it: "Issue #113".
    public static func subject(of task: BotTask) -> String {
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

    /// "#113", after the repository's name on the first line.
    public var numberText: String? { number.map { "#\($0)" } }

    /// The first line as one string: "BotChu #113", "Home".
    public var title: String { [name, numberText].compactMap { $0 }.joined(separator: " ") }

    /// The second line's left side: what it is doing, or while idle what it is about (Home: its
    /// account).
    public var detail: String { state.text ?? subject }

    /// What VoiceOver reads for the tab: its title (and host), what it is about, what it is doing,
    /// and its time.
    public func spoken(at now: Date) -> String {
        let name = (isReview ? "Review of " : "") + title + (machine.map { " on \($0)" } ?? "")
        return [name, subject, state.text, state.spokenTime(at: now)].compactMap { $0 }.joined(separator: ", ")
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

/// A bot's row in the bot list (#128): a small dot for each of its conversations that isn't idle,
/// and a subtitle that says what it is doing.
public struct BotRowSummary: Equatable, Sendable {
    /// The most dots a row shows; the rest are counted (+N).
    public static let dotLimit = 4

    /// The dots, in tab order: Home, then the open tasks.
    public var dots: [TabState.Kind]
    /// How many more conversations aren't idle.
    public var more: Int
    /// "Working on #113", "2 tasks running", "Thinking…" while only Home works, "4 tasks", or the account.
    public var subtitle: String
    /// What the dots say, for VoiceOver and the tooltip: "2 working, 1 finished".
    public var spokenDots: String

    public init(account: String, home: TabState, tasks: [(task: BotTask, state: TabState)]) {
        let busy = ([home] + tasks.map(\.state)).map(\.kind).filter { $0 != .idle }
        dots = Array(busy.prefix(Self.dotLimit))
        more = max(0, busy.count - Self.dotLimit)
        let running = tasks.filter { $0.state.kind.isActive }
        if running.count == 1, let task = running.first?.task {
            subtitle = "Working on " + (task.work.map { "#\($0.number)" } ?? task.repoName)
        } else if running.count > 1 {
            subtitle = "\(running.count) tasks running"
        } else if home.kind.isActive, let text = home.text {
            subtitle = text
        } else if !tasks.isEmpty {
            subtitle = "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
        } else {
            subtitle = account
        }
        let names: [(TabState.Kind, String)] = [(.preparing, "preparing"), (.starting, "starting"), (.working, "working"),
                                                         (.news, "finished"), (.failed, "failed")]
        spokenDots = names.compactMap { kind, name in
            let n = busy.filter { $0 == kind }.count
            return n == 0 ? nil : "\(n) \(name)"
        }.joined(separator: ", ")
    }
}

/// Where the conversation column goes (#128): 240 points beside the chat, which the owner can
/// narrow to 200 or widen to 320, or a 56-point rail of tiles, by the owner's choice or by itself
/// while the chat beside the column would be too narrow to read.
public enum ConversationColumnLayout {
    public static let width: Double = 240
    public static let widths: ClosedRange<Double> = 200...320
    public static let railWidth: Double = 56
    /// Below this, the chat's text is too narrow to read beside the column, and it shows the rail.
    public static let minimumReadable: Double = 600
    /// The widest the chat's text grows, and its margin on each side (`Theme.chatWidth`, `ChatView`).
    public static let chatWidth: Double = 760
    public static let chatMargin: Double = 24

    /// How wide the chat's text is, with `column` points of `available` taken by the column.
    public static func readableWidth(available: Double, column: Double) -> Double {
        min(chatWidth, available - column - 2 * chatMargin)
    }

    /// Whether the rail shows: the owner collapsed the column, or the chat beside it would be
    /// narrower than `minimumReadable`. It depends only on the space for both, which the rail
    /// doesn't change, so the column comes back as soon as the window widens enough.
    public static func showsRail(available: Double, column: Double, collapsed: Bool) -> Bool {
        collapsed || readableWidth(available: available, column: clamped(column)) < minimumReadable
    }

    /// A width the owner dragged the column's edge to, within `widths`.
    public static func clamped(_ width: Double) -> Double {
        min(widths.upperBound, max(widths.lowerBound, width))
    }
}
