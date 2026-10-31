import Foundation
import BotChuCore

/// Sidebar navigation points at a gallery or a bot, one row per bot (#128); galleries keep the
/// conversation shown, and a bot shows the one of its conversations it showed last.
enum SidebarDestination: Hashable {
    case library(LibraryDestination)
    case bot(UUID)

    var botID: UUID? {
        switch self {
        case .library: nil
        case .bot(let id): id
        }
    }
}

extension AppModel {
    var sidebarSelection: SidebarDestination? {
        if let destination { return .library(destination) }
        return selection.map { .bot($0) }
    }

    func selectSidebar(_ destination: SidebarDestination) {
        switch destination {
        case .library(let library): self.destination = library
        case .bot(let id): show(tab(of: id))
        }
    }

    /// Settings, in the window, on `page`, or the page shown last (#191). Like a gallery, it keeps
    /// the conversation shown, its draft and its turns.
    func openSettings(_ page: SettingsPage? = nil) {
        if let page { settings.settingsPage = page }
        destination = .settings
    }

    /// The bot's Project Areas column (#399): its open areas with their tasks, its other open
    /// tasks, and its hidden areas.
    func areaLayout(of botID: UUID) -> ProjectAreasLayout { ProjectAreasLayout(tasks: tasks[botID, default: []]) }

    /// The bot's conversations in the Project Areas column's order: Home, then its open areas,
    /// each followed by its tasks, then its other open tasks.
    func tabs(of botID: UUID) -> [ChatTarget] {
        [.home(botID)] + areaLayout(of: botID).rows.map { .task($0.id, of: botID) }
    }

    /// How a conversation is doing, as its tab's dot and second line say it (#128): waiting on the
    /// owner while a Needs input delivery it sent isn't answered or Done (#218).
    func tabState(of target: ChatTarget) -> TabState {
        guard let status = status(of: target) else { return .idle(since: nil) }
        let asked = inbox?.awaitingInputDates(target) ?? []
        return TabState(status: status, unread: unread.contains(target), pullRequest: task(target)?.pullRequest, awaitingInput: asked)
    }

    /// What a conversation's tab says.
    func conversationTab(of target: ChatTarget) -> ConversationTab? {
        if let task = task(target) {
            return ConversationTab(task: task, machine: task.isRemote ? machineName(task.hostID, fallback: task.hostName) : nil,
                                   state: tabState(of: target))
        }
        guard target.taskID == nil, let bot = bot(target.botID) else { return nil }
        return .home(account: bot.isRemoteQueue ? "Remote queue · \(remoteQueue.presence)" : bot.account.name, state: tabState(of: target))
    }

    /// The bot's open tasks as its Tasks column lists them, for `botchu-task list --mine` (#262).
    func taskList(of botID: UUID, at now: Date = Date()) -> [TaskListEntry] {
        openTasks(of: botID).compactMap { task in
            conversationTab(of: .task(task.id, of: botID)).map { TaskListEntry(task: task, tab: $0, at: now) }
        }
    }

    /// The bot's row in the bot list: a dot for each open task, and for Home and each open area
    /// while it isn't idle, and what it runs on.
    func botRowSummary(of bot: Bot) -> BotRowSummary {
        SidebarStatusDiagnostics.didDeriveSummary?(bot.id)
        let subtitle = bot.isRemoteQueue ? "\(remoteQueue.presence) · \(remoteQueue.pending) waiting" : runsOn(bot)
        let open = openTasks(of: bot.id)
        func states(_ tasks: [BotTask]) -> [TabState] { tasks.map { tabState(of: .task($0.id, of: bot.id)) } }
        return BotRowSummary(runsOn: subtitle, home: tabState(of: .home(bot.id)), areas: states(open.filter(\.isArea)),
                             tasks: states(open.filter { !$0.isArea }),
                             workingAsSubagent: bot.isSpecialist && delegation.usesBot(bot.id))
    }

    /// What the bot runs on, as its row and the `@` list say it (#324): "Claude Personal · Fable 5.1".
    func runsOn(_ bot: Bot) -> String {
        // Sail's list is the profile's own now, as every profile's (#326).
        BotRowSummary.runsOn(bot, openRouterDefault: settings.openRouterModel, sailDefault: settings.sailModel,
                             native: nativeModels(for: bot))
    }

    /// Shows the bot's conversation at `index` in its tabs (⌘1 for Home, ⌘2 to ⌘9 for its areas and tasks).
    func showTab(at index: Int, of botID: UUID) {
        let tabs = tabs(of: botID)
        guard tabs.indices.contains(index) else { return }
        show(tabs[index])
    }
}

/// Optional counters for the controlled sidebar fixture. Unset during normal use.
@MainActor enum SidebarStatusDiagnostics {
    static var didDeriveSummary: ((UUID) -> Void)?
    static var didEvaluateRow: ((UUID) -> Void)?
    static var didEvaluateList: (() -> Void)?
}
