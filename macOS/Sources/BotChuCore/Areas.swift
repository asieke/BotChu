import Foundation

/// What makes a task a Project Area (#399): a bot's one lasting conversation about a repository
/// (`repo`, run in its main checkout) or a folder (`folder`), kept like any task in the bot's
/// `.botchu/tasks/<id>/`. A repository has at most one area, of one bot (`Areas.owner`).
public struct AreaInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case repo, folder }

    public var kind: Kind
    /// What it is called: the repository's name, or the folder's.
    public var name: String
    /// When its bot took it on (attached, migrated or moved to it); its bot's areas are listed in
    /// this order. Nil reads as the task's `createdAt`.
    public var attachedAt: Date?

    public init(kind: Kind, name: String, attachedAt: Date? = Date()) {
        self.kind = kind
        self.name = name
        self.attachedAt = attachedAt
    }
}

extension BotTask {
    /// A repository's area for `bot`, on the bot's run settings, in the repository's main checkout
    /// on this Mac.
    public init(repoArea repo: String, checkout: String, for bot: Bot, at date: Date = Date()) {
        self.init(area: AreaInfo(kind: .repo, name: TaskNaming.repoName(repo), attachedAt: date),
                  repo: repo, checkout: checkout, for: bot, at: date)
    }

    /// A folder's area for `bot`, named `name`, run in `folder`.
    public init(folderArea name: String, folder: String, for bot: Bot, at date: Date = Date()) {
        self.init(area: AreaInfo(kind: .folder, name: name, attachedAt: date), repo: "", checkout: folder, for: bot, at: date)
    }

    private init(area: AreaInfo, repo: String, checkout: String, for bot: Bot, at date: Date) {
        self.init(for: bot, repo: repo, checkout: checkout, work: nil, brief: "", title: TaskNaming.title(area: area))
        self.folder = checkout
        self.createdAt = date
        self.area = area
    }
}

extension TaskNaming {
    /// An area's title is its name.
    public static func title(area: AreaInfo) -> String { area.name }
}

/// The rules of Project Areas, apart from the app: listing, the one owner of a repository, folder
/// names, moving an area to another bot, and the launch migration of open tasks.
public enum Areas {
    /// A bot's folder areas are made in `<workspace>/areas/<slug>`.
    public static let folderName = "areas"

    /// What an area's row gives a drag onto a bot in the sidebar (#402): its bot's id and its own.
    public static func dragPayload(botID: UUID, areaID: UUID) -> Data { Data("\(botID.uuidString)/\(areaID.uuidString)".utf8) }

    /// The bot and area a dragged row carries; nil for anything else.
    public static func draggedArea(_ payload: Data?) -> (botID: UUID, areaID: UUID)? {
        guard let payload, payload.count == 73, let text = String(data: payload, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bot = UUID(uuidString: String(parts[0])), let area = UUID(uuidString: String(parts[1])) else { return nil }
        return (bot, area)
    }

    /// The bot's areas, hidden ones too, in the order it took them on.
    public static func areas(in tasks: [BotTask]) -> [BotTask] {
        tasks.filter(\.isArea).sorted { order($0) < order($1) }
    }

    private static func order(_ area: BotTask) -> (Date, Date, String) {
        (area.area?.attachedAt ?? area.createdAt, area.createdAt, area.id.uuidString)
    }

    /// The bot whose area the repository is, hidden or not, and that area; nil when it has none.
    /// Bots are asked in `bots`' order, so a repository that somehow has two belongs to the first.
    public static func owner(of repo: String, among bots: [(botID: UUID, tasks: [BotTask])]) -> (botID: UUID, area: BotTask)? {
        guard !repo.isEmpty else { return nil }
        for (botID, tasks) in bots {
            if let area = tasks.first(where: { $0.area?.kind == .repo && $0.repo.caseInsensitiveCompare(repo) == .orderedSame }) {
                return (botID, area)
            }
        }
        return nil
    }

    /// A folder name for an area called `name`: up to five plain lowercase words joined by
    /// hyphens, at most 40 characters, or "area" when it has none.
    public static func slug(_ name: String) -> String {
        let words = name.folding(options: .diacriticInsensitive, locale: nil).lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
        var slug = ""
        for word in words where slug.count + (slug.isEmpty ? 0 : 1) + word.count <= 40 {
            slug += (slug.isEmpty ? "" : "-") + word
        }
        return slug.isEmpty ? "area" : slug
    }

    /// Where a new folder area called `name` goes in the bot's workspace: `areas/<slug>`, or
    /// `areas/<slug>-<n>` when another area already works in that folder (`taken`).
    public static func folder(named name: String, workspace: String, taken: Set<String>) -> String {
        let root = (workspace as NSString).appendingPathComponent(folderName)
        let base = (root as NSString).appendingPathComponent(slug(name))
        var path = base, n = 2
        while taken.contains(path) {
            path = "\(base)-\(n)"
            n += 1
        }
        return path
    }

    /// Why the area can't move from `source` to `destination` now, in the words its owner sees; nil
    /// when it can. It moves only while nothing runs in it: no turn, and no sub-agent run.
    public static func moveProblem(_ area: BotTask, from source: Bot, to destination: Bot, running: Bool, activeSubagents: Int) -> String? {
        guard area.isArea else { return "Only a Project Area can move to another bot." }
        guard source.id != destination.id else { return "\(area.title) is already \(destination.name)'s." }
        if let problem = destination.taskOwnershipProblem { return problem }
        if area.isRemote { return "An area on another computer can't move." }
        if running { return "\(area.title) is busy. Move it once its turn ends." }
        if activeSubagents > 0 { return "\(area.title) has sub-agents at work. Move it once they finish." }
        return nil
    }

    /// The area as `bot`'s: on its account, model, effort and speed, taken on now, and with no CLI
    /// session, so its next turn starts a fresh one on its transcript (which the move keeps).
    public static func moved(_ area: BotTask, to bot: Bot, at date: Date = Date()) -> BotTask {
        var moved = area
        moved.accountID = bot.accountID
        moved.accountProfile = bot.accountProfile
        moved.model = bot.model
        moved.providerID = bot.providerID
        moved.reasoningEffort = bot.reasoningEffort
        moved.sailCompletionWindow = bot.sailCompletionWindow
        moved.fastMode = bot.fastMode
        moved.sessionID = nil
        moved.sessionAccountID = nil
        moved.sessionScope = nil
        moved.reportedModel = nil
        moved.area?.attachedAt = date
        return moved
    }

    /// Moves the area's folder (its record, transcript, queue and sub-agent runs) from `source`'s
    /// `.botchu/tasks/` to `destination`'s, marks its runs as the new bot's (`botID`), and saves the
    /// record given (`Areas.moved`) there. On a failure after the folder moved, it goes back.
    public static func move(_ area: BotTask, from source: BotHome, to destination: BotHome, botID: UUID) throws {
        try BotHome.moveTask(area.id, from: source, to: destination)
        do {
            for var run in destination.loadSubagents(taskID: area.id) where run.rootBotID != botID {
                run.rootBotID = botID
                try destination.saveSubagent(run)
            }
            try destination.save(area)
        } catch {
            try? BotHome.moveTask(area.id, from: destination, to: source)
            throw error
        }
    }

    /// The areas a launch makes (#399 decision 10): for each bot that can own tasks, in `bots`'
    /// order, each open task on this Mac in a repository (not a job's run or a review) whose
    /// repository has no area yet gives that bot one, in the task's checkout. Running it again
    /// with what it made makes nothing.
    public static func migrations(_ bots: [(bot: Bot, tasks: [BotTask])], at date: Date = Date()) -> [(botID: UUID, area: BotTask)] {
        var owned = Set(bots.flatMap { $0.tasks.filter { $0.area?.kind == .repo }.map { $0.repo.lowercased() } })
        var made: [(botID: UUID, area: BotTask)] = []
        for (bot, tasks) in bots where bot.canOwnTasks {
            for task in tasks where !task.isArchived && !task.isArea && task.jobRun == nil && task.review == nil
                && !task.isRemote && !task.repo.isEmpty && !task.checkout.isEmpty {
                guard owned.insert(task.repo.lowercased()).inserted else { continue }
                // A second apart (saved dates keep whole seconds), so they list in the order made.
                let area = BotTask(repoArea: task.repo, checkout: task.checkout, for: bot,
                                   at: date.addingTimeInterval(Double(made.count)))
                made.append((bot.id, area))
            }
        }
        return made
    }
}

/// What the lead-bot pill atop an area's conversation names (#403): its owner, the area and the
/// folder its turns run in, `~`-abbreviated.
public struct AreaHeading: Hashable, Sendable {
    public var botName: String
    public var areaName: String
    public var path: String

    /// Nil for Home, a task or a job's run, which keep their intros.
    public init?(bot: Bot, task: BotTask?, home: String = NSHomeDirectory()) {
        guard let task, let area = task.area else { return nil }
        botName = bot.name
        areaName = area.name
        path = Self.abbreviated(task.checkout, home: home)
    }

    /// `path` with the home folder written `~`.
    public static func abbreviated(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

extension ConversationTab {
    /// The composer's placeholder: "Message GitChu" in an area; "Message 10x Engineer Bot about
    /// #113" in a task (its issue or pull request, else its repository; a job's run: its job).
    public static func placeholder(bot: Bot, task: BotTask?) -> String {
        guard let task else { return "Message \(bot.name)" }
        if let area = task.area { return "Message \(area.name)" }
        return "Message \(bot.name) about " + (task.work.map { "#\($0.number)" } ?? task.jobRun?.jobTitle ?? task.repoName)
    }

    /// The window's title: the area's name while an area is shown, else the bot's.
    public static func windowTitle(bot: Bot, task: BotTask?) -> String { task?.area?.name ?? bot.name }
}
