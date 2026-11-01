import Foundation
import BotChuCore

/// Project Areas (#399): each a `BotTask` with an `area`, kept with its bot's tasks and opened as
/// one, whose turns run in the repository's main checkout or the area's folder. A repository has
/// at most one area, of one bot; attaching it to another bot moves it there.
extension AppModel {
    /// The bot's areas, hidden ones too, in the order it took them on.
    func areas(of botID: UUID) -> [BotTask] { Areas.areas(in: tasks[botID, default: []]) }

    /// The bot whose area the repository is, hidden or not, and that area; nil when it has none.
    func areaOwner(repo: String) -> (botID: UUID, area: BotTask)? {
        Areas.owner(of: repo, among: bots.map { ($0.id, tasks[$0.id, default: []]) })
    }

    /// Each repository's area, hidden or not, by its `owner/name` lowercased: whose it is.
    func areaOwners() -> [String: UUID] {
        var owners: [String: UUID] = [:]
        for bot in bots {
            for area in areas(of: bot.id) where area.area?.kind == .repo && owners[area.repo.lowercased()] == nil {
                owners[area.repo.lowercased()] = bot.id
            }
        }
        return owners
    }

    /// Attach Project Area's repositories for the bot, as it opens (#438): each with the bot whose
    /// area it is, and why it can't be chosen now. One on another computer can't, nor one whose
    /// area can't move to the bot now.
    func attachAreaRows(for botID: UUID) -> [AttachAreaRow] {
        let owners = areaOwners()
        return projectCatalog.map { entry in
            let owner = owners[entry.repo.lowercased()]
            let problem: String?
            if entry.location.hostID != nil {
                problem = "\(entry.name) is on \(entry.workplace); a Project Area works on this Mac."
            } else if let owner, owner != botID, let area = areaOwner(repo: entry.repo) {
                problem = areaMoveProblem(.task(area.area.id, of: owner), to: botID)
            } else {
                problem = nil
            }
            return AttachAreaRow(entry: entry, owner: owner, problem: problem)
        }
    }

    /// The bots an area's menu and a drag can move it to: those who can own one, but its own.
    func areaMoveTargets(of target: ChatTarget) -> [Bot] { bots.filter { $0.canOwnTasks && $0.id != target.botID } }

    /// Moves the area a row dragged onto a bot in the sidebar carries to that bot; false when it
    /// can't move there now.
    @discardableResult
    func dropArea(_ dragged: (botID: UUID, areaID: UUID), on botID: UUID) -> Bool {
        let target = ChatTarget.task(dragged.areaID, of: dragged.botID)
        guard task(target)?.isArea == true, areaMoveProblem(target, to: botID) == nil else { return false }
        return moveArea(target, to: botID) != nil
    }

    /// Gives the bot the repository's area: its own (shown again when hidden, and opened when
    /// `revealing`), the one another bot has (moved to it), or a new one in the repository's main
    /// checkout on this Mac (`checkout`, else where it is located). Nil when the bot can't own it,
    /// the repository is located on a host, or the area can't move now.
    @discardableResult
    func attachArea(repo: String, to botID: UUID, checkout: String? = nil, revealing: Bool = true) -> ChatTarget? {
        guard let bot = bot(botID), bot.canOwnTasks, !repo.isEmpty else { return nil }
        if let owner = areaOwner(repo: repo) {
            let found = ChatTarget.task(owner.area.id, of: owner.botID)
            guard let target = owner.botID == botID ? found : moveArea(found, to: botID) else { return nil }
            if task(target)?.isArchived == true { unhideArea(target, revealing: revealing) }
            return target
        }
        let location = location(of: repo)
        guard location.hostID == nil else { return nil }
        return addArea(BotTask(repoArea: repo, checkout: checkout ?? location.path, for: bot), to: botID)
    }

    /// Gives the bot a new folder area called `name`, in `<workspace>/areas/<slug>`, made now.
    @discardableResult
    func attachArea(folderNamed name: String, to botID: UUID) -> ChatTarget? {
        guard let bot = bot(botID), bot.canOwnTasks else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let taken = Set(bots.flatMap { areas(of: $0.id) }.filter { $0.area?.kind == .folder }.map(\.checkout))
        let folder = Areas.folder(named: name, workspace: bot.workspace, taken: taken)
        guard (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil else { return nil }
        return addArea(BotTask(folderArea: name, folder: folder, for: bot), to: botID)
    }

    /// Gives the bot a folder area on a folder that exists, named after it.
    @discardableResult
    func attachArea(folder: String, to botID: UUID) -> ChatTarget? {
        guard let bot = bot(botID), bot.canOwnTasks else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        let path = URL(fileURLWithPath: folder).standardizedFileURL.path
        return addArea(BotTask(folderArea: (path as NSString).lastPathComponent, folder: path, for: bot), to: botID)
    }

    /// Records a new area of the bot. Nothing is sent: its conversation starts with the owner's
    /// first message.
    private func addArea(_ area: BotTask, to botID: UUID) -> ChatTarget {
        let target = ChatTarget.task(area.id, of: botID)
        tasks[botID, default: []].append(area)
        conversation(target).start()
        saveTask(area, of: botID)
        return target
    }

    /// Why the area can't move to the bot now; nil when it can (`Areas.moveProblem`).
    func areaMoveProblem(_ target: ChatTarget, to botID: UUID) -> String? {
        guard let area = task(target), let source = bot(target.botID), let destination = bot(botID) else { return "The area or bot is gone." }
        return Areas.moveProblem(area, from: source, to: destination, running: isRunning(target),
                                 activeSubagents: delegation.activeCount(target))
    }

    /// Moves the area to another bot (#399 decision 3), while nothing runs in it: its folder
    /// (record, transcript, queue and sub-agent runs) goes to that bot's `.botchu/tasks/`, it takes
    /// that bot's run settings and starts a fresh CLI session on its transcript. Returns where it
    /// is now, or nil when it couldn't move.
    @discardableResult
    func moveArea(_ target: ChatTarget, to botID: UUID) -> ChatTarget? {
        guard areaMoveProblem(target, to: botID) == nil, let area = task(target),
              let source = bot(target.botID), let destination = bot(botID) else { return nil }
        let moved = Areas.moved(area, to: destination)
        let from = BotHome(workspace: source.persistencePath), to = BotHome(workspace: destination.persistencePath)
        let moving = ChatTarget.task(area.id, of: botID)
        // After what is being written in its folder: its runs', its conversation's and its record's.
        delegation.settleRuns(of: target)
        do {
            try storage.sync(from.conversationLane(task: area.id), label: "move area") {
                try storage.sync(from.taskLane(area.id), label: "move area") {
                    try Areas.move(moved, from: from, to: to, botID: botID)
                }
            }
        } catch {
            return nil
        }
        let draft = conversations[target]?.draft ?? "", references = conversations[target]?.draftReferences ?? []
        let shown = openTask[target.botID] == area.id
        unread.remove(target)
        tasks[target.botID]?.removeAll { $0.id == area.id }
        dropConversation(target)
        savedDrafts.save(nil, for: DraftStore.Key(bot: target.botID, task: area.id), storage: storage)
        if shown { openTask[target.botID] = nil }
        tasks[botID, default: []].append(moved)
        delegation.moveRuns(from: target, to: moving)
        if to.hasQueueFiles(task: area.id) {
            recover(moving, load: false)
        } else {
            conversation(moving).history = .clean
            readDigest(moving)
        }
        if !draft.isEmpty {
            drafts[moving] = draft
            draftReferences[moving] = references
        }
        if shown, visibleBotID == target.botID { show(moving) }
        return moving
    }

    /// Hides the area (#399 decision 4), as a task closes: its record and conversation stay.
    func hideArea(_ target: ChatTarget) {
        guard task(target)?.isArea == true else { return }
        closeTask(target)
    }

    /// Shows a hidden area again, and opens it when `revealing`.
    func unhideArea(_ target: ChatTarget, revealing: Bool = true) {
        guard let area = task(target), area.isArea, area.isArchived else { return }
        reopenTask(target, show: revealing)
    }

    /// Gives each open task's repository on this Mac that has no area yet one, under the first bot
    /// in sidebar order with an open task there (`Areas.migrations`). Run at every launch; a second
    /// run makes nothing.
    func migrateAreas() {
        for (botID, area) in Areas.migrations(bots.map { ($0, tasks[$0.id, default: []]) }) {
            tasks[botID, default: []].append(area)
            conversation(.task(area.id, of: botID)).start()
            saveTask(area, of: botID)
        }
    }
}
