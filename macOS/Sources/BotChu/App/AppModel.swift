import AppKit
import Foundation
import Observation
import BotChuCore

struct EditorRequest: Identifiable {
    let id = UUID()
    var bot: Bot
    var isNew: Bool
}

/// The New Task sheet, open for a bot.
struct TaskSheetRequest: Identifiable {
    let id = UUID()
    var botID: UUID
    var repo: String?
    /// An open issue or pull request there to choose, and what to do with a pull request.
    var work: BotTask.Work?
    var purpose: NewTaskSheet.Purpose = .work
}

/// A Markdown file open in the in-app editor: one of a bot's (`BotDocument`) or one every bot
/// shares (`SharedDocument`, from Settings).
struct DocumentEditorRequest: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let url: URL
    let seed: String
    /// Shown over an empty draft, saying what the file is for.
    let placeholder: String

    init(bot: Bot, document: BotDocument) {
        name = document.rawValue
        subtitle = "\(bot.name) · \(document.summary)"
        url = document.url(for: bot)
        seed = document.seed(for: bot)
        placeholder = document == .instructions
            ? "\(bot.name)'s role and job, in Markdown: what it works on, with whom, and how it hands work on."
            : ""
    }

    init(shared document: SharedDocument, botsRoot: String) {
        name = document.rawValue
        subtitle = "Every bot · \(document.summary)"
        url = document.url(botsRoot: botsRoot)
        seed = document.seed
        placeholder = document == .team
            ? "The process every bot follows, in Markdown: its stages, handoffs, who calls whom with botchu-subagent, and when work is done. Left out of every bot's context while empty."
            : ""
    }
}

/// A conversation in the window: a bot's own (its Home), or one of its tasks.
struct ChatTarget: Hashable {
    var botID: UUID
    /// Nil for the bot's Home.
    var taskID: UUID?

    static func home(_ botID: UUID) -> ChatTarget { ChatTarget(botID: botID, taskID: nil) }
    static func task(_ taskID: UUID, of botID: UUID) -> ChatTarget { ChatTarget(botID: botID, taskID: taskID) }
}

enum LibraryDestination: String, CaseIterable {
    case projects, agents, providers
    var title: String { rawValue.capitalized }
    var symbol: String { switch self { case .projects: "square.grid.2x2"; case .agents: "person.2"; case .providers: "terminal" } }
}

@MainActor @Observable
final class AppModel {
    var bots: [Bot] = [] { didSet { try? delegation?.refreshRoster() } }
    var delegation: SubagentRuntime!
    /// Each bot's tasks, open and closed, oldest first.
    var tasks: [UUID: [BotTask]] = [:]
    /// Every conversation: each bot's Home, and each task.
    var threads: [ChatTarget: [ChatMessage]] = [:]
    /// Turns in progress, by conversation.
    var runStates: [ChatTarget: RunState] = [:]
    /// Nil shows the remembered conversation; galleries never discard that conversation.
    var destination: LibraryDestination?
    var visibleBotID: UUID? { destination == nil ? selection : nil }
    var selection: UUID? {
        didSet {
            guard destination == nil, let selection, selection != oldValue else { return }
            react(.greeting, for: tab(of: selection), seconds: 5)
            unread.remove(tab(of: selection))
        }
    }
    /// The task tab shown for each bot; none shows its Home.
    var openTask: [UUID: UUID] = [:]
    /// Conversations whose turn ended while they weren't shown.
    var unread: Set<ChatTarget> = []
    /// What is typed in each conversation's message box and not sent yet.
    var drafts: [ChatTarget: String] = [:]
    /// Unsent follow-ups and short pet reactions belong to one conversation, not the whole bot.
    var messageQueues: [ChatTarget: MessageQueue] = [:]
    var reactions: [ChatTarget: BotActivity] = [:]
    @ObservationIgnored private var reactionTickets: [ChatTarget: UUID] = [:]
    /// Pets, by bot; a bot without one shows its emoji (see `Pets.swift`).
    var pets: [UUID: PetVideoPackage] = [:]
    var petJobs: [UUID: PetJob] = [:]
    @ObservationIgnored var petRuns: [UUID: AgentRun] = [:]
    @ObservationIgnored var petTasks: [UUID: Task<Void, Never>] = [:]
    var editor: EditorRequest?
    var taskSheet: TaskSheetRequest?
    var documentEditor: DocumentEditorRequest?
    let settings: AppSettings
    let usage: UsageCache
    let modelCatalog = ModelCatalog()

    private let store: Store
    /// Index entries whose folders don't hold their bot right now; kept so the bot returns with it.
    @ObservationIgnored private var missing: [Store.Entry] = []
    @ObservationIgnored private var delegationSessions: [ChatTarget: Set<String>] = [:]
    @ObservationIgnored private var runs: [ChatTarget: AgentRun] = [:]
    /// What each running CLI that takes input mid-turn has been given and has taken back.
    @ObservationIgnored private var inputs: [ChatTarget: (kind: AgentKind, ledger: InputLedger)] = [:]
    /// BotChu is quitting: the turns it stops weren't stopped by the owner, so queues stay unpaused.
    @ObservationIgnored private var terminating = false
    /// While a bot's Home turn runs, BotChu looks for the tasks it asks for (`.botchu/dispatch/`).
    @ObservationIgnored private var dispatchTimers: [UUID: Timer] = [:]
    /// Bots whose dispatch requests are being started.
    @ObservationIgnored private var dispatching: Set<UUID> = []
    /// Worktrees being made, by task: one at a time, so a message sent meanwhile waits for it.
    @ObservationIgnored private var makings: [ChatTarget: Task<TaskWorktree.Failure?, Never>] = [:]
    /// The turn waiting for its task's worktree, by task; Stop withdraws it.
    @ObservationIgnored private var waiting: [ChatTarget: UUID] = [:]
    /// The last git work queued in each checkout: worktrees are made one at a time per repository,
    /// since git locks its refs and config.
    @ObservationIgnored private var checkoutWork: [String: Task<Void, Never>] = [:]
    /// The owner's GitHub repositories, which tasks start from, once read (`loadRepositories`).
    var repositories: [GitHubLookup.Repo]?
    var repositoriesError: String?
    var repositoriesLoading = false
    @ObservationIgnored var repositoriesTask: Task<Void, Never>?
    var projectRecords: [String: ProjectRecord] = [:]
    var projectErrors: [String: String] = [:]
    var projectsLoading = false
    /// The open pull requests and issues across the repositories, once read (`loadOpenWork`).
    var openItems: [GitHubLookup.OpenItem]?
    var openItemsError: String?
    var openItemsLoading = false
    @ObservationIgnored var openItemsReadAt: Date?
    let openWorkLookup: @Sendable ([String]) async -> Result<GitHubLookup.OpenWork, TaskWorktree.Failure>
    var githubConnection: ProjectGitHub.Connection?
    var githubChecking = false
    let projectGitHub: ProjectGitHub
    @ObservationIgnored var repositoriesReadAt: Date?
    /// PROJECT.md's `local:` deploy targets, by repository, once read.
    @ObservationIgnored var deployTargetCache: [String: [(machine: String, path: String)]] = [:]

    init(store: Store? = nil, settings: AppSettings? = nil, usage: UsageCache? = nil, projectGitHub: ProjectGitHub = ProjectGitHub(),
         openWorkLookup: @escaping @Sendable ([String]) async -> Result<GitHubLookup.OpenWork, TaskWorktree.Failure> = { await GitHubLookup.openWork(repos: $0) }) {
        self.projectGitHub = projectGitHub
        self.openWorkLookup = openWorkLookup
        DevHooks.configure()
        self.store = store ?? DevHooks.dataDir.map { Store(root: $0) } ?? .applicationSupport
        self.settings = settings ?? AppSettings()
        self.usage = usage ?? DevHooks.usageFetch.map { UsageCache(fetch: $0) } ?? UsageCache()
        self.store.migrateIfNeeded()
        let loaded = self.store.loadBots()
        bots = loaded.bots
        missing = loaded.missing
        for bot in bots {
            threads[.home(bot.id)] = self.store.loadThread(for: bot)
            let home = BotHome(workspace: bot.workspace)
            messageQueues[.home(bot.id)] = MessageQueue(saved: home.loadQueuedMessages(), delivered: thread(.home(bot.id)),
                                                        paused: home.loadQueuePaused())
            tasks[bot.id] = home.loadTasks()
            for task in tasks[bot.id] ?? [] where !task.isArchived {
                let target = ChatTarget.task(task.id, of: bot.id)
                threads[target] = home.loadThread(task: task.id)
                messageQueues[target] = MessageQueue(saved: home.loadQueuedMessages(task: task.id), delivered: thread(target),
                                                     paused: home.loadQueuePaused(task: task.id))
            }
            reloadPet(bot.id)
        }
        delegation = SubagentRuntime(model: self, root: (store != nil || DevHooks.dataDir != nil)
            ? self.store.root.appendingPathComponent("subagents") : SubagentIPC.defaultRoot)
        selection = bots.first?.id
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        // Requests left while BotChu wasn't running.
        for bot in bots { takeDispatches(for: bot.id) }
        // Follow-ups left queued when BotChu quit go out on their own, unless Stop or a failure
        // paused them; once the window is up, so a turn's first output has somewhere to go.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for target in Array(self.messageQueues.keys) { self.sendNextQueued(to: target) }
        }
    }

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }
    func task(_ id: UUID, of botID: UUID) -> BotTask? { tasks[botID]?.first { $0.id == id } }
    func task(_ target: ChatTarget) -> BotTask? { target.taskID.flatMap { task($0, of: target.botID) } }
    func openTasks(of botID: UUID) -> [BotTask] { tasks[botID, default: []].filter { !$0.isArchived } }
    func closedTasks(of botID: UUID) -> [BotTask] { tasks[botID, default: []].filter(\.isArchived) }
    func thread(_ target: ChatTarget) -> [ChatMessage] { threads[target] ?? [] }
    func isRunning(_ target: ChatTarget) -> Bool { runStates[target] != nil || (delegation?.activeCount(target) ?? 0) > 0 }
    /// Whether any of the bot's conversations has a turn under way.
    func isBusy(_ botID: UUID) -> Bool { runStates.keys.contains { $0.botID == botID } || delegation.usesBot(botID) }

    /// What a conversation runs on: its task's settings, or its bot's.
    func runSettings(of target: ChatTarget) -> (any RunSettings)? {
        task(target) ?? (target.taskID == nil ? bot(target.botID) : nil)
    }

    /// The conversation shown for a bot: its open task tab, else its Home.
    func tab(of botID: UUID) -> ChatTarget {
        if let taskID = openTask[botID], let task = task(taskID, of: botID), !task.isArchived { return .task(taskID, of: botID) }
        return .home(botID)
    }

    func show(_ target: ChatTarget) {
        let wasHidden = destination != nil
        destination = nil
        if wasHidden, selection == target.botID { react(.greeting, for: target, seconds: 5) }
        openTask[target.botID] = target.taskID
        unread.remove(target)
        if selection != target.botID { selection = target.botID }
    }

    /// Shows the tab `offset` places after the shown one (before, when negative), wrapping around.
    func showTab(offset: Int, of botID: UUID) {
        let tabs = [ChatTarget.home(botID)] + openTasks(of: botID).map { .task($0.id, of: botID) }
        guard let index = tabs.firstIndex(of: tab(of: botID)), tabs.count > 1 else { return }
        show(tabs[(index + offset % tabs.count + tabs.count) % tabs.count])
    }

    /// One conversation's status.
    func status(of target: ChatTarget) -> BotStatus? {
        if let task = task(target) { return BotStatus.make(task: task, messages: thread(target), run: runStates[target], reaction: reactions[target]) }
        guard target.taskID == nil, let bot = bot(target.botID) else { return nil }
        return BotStatus.make(bot: bot, messages: thread(target), run: runStates[target], reaction: reactions[target])
    }

    /// The bot as a whole, for its list row only. Profile cards always use status(of: ChatTarget).
    func status(of bot: Bot) -> BotStatus {
        let home = BotStatus.make(bot: bot, messages: thread(.home(bot.id)), run: runStates[.home(bot.id)], reaction: reactions[.home(bot.id)])
        let working = openTasks(of: bot.id).compactMap { task in runStates[.task(task.id, of: bot.id)].map { (title: task.title, run: $0) } }
        return home.working(on: working)
    }

    /// How many of the bot's conversations finished a turn while they weren't shown.
    func unreadCount(of botID: UUID) -> Int { unread.filter { $0.botID == botID }.count }

    // MARK: Bots

    func newBot() {
        let bot = Bot(name: "", workspace: "")
        editor = EditorRequest(bot: bot, isNew: true)
    }

    func edit(_ id: UUID) {
        guard let bot = bot(id) else { return }
        editor = EditorRequest(bot: bot, isNew: false)
    }

    func editDocument(_ document: BotDocument, for id: UUID) {
        guard let bot = bot(id) else { return }
        documentEditor = DocumentEditorRequest(bot: bot, document: document)
    }

    /// Why a bot can't use `path` as its workspace, or nil when it can.
    func workspaceProblem(_ path: String, for id: UUID) -> String? {
        if let bot = bot(id), isBusy(id),
           URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL != URL(fileURLWithPath: bot.workspace).standardizedFileURL {
            return "Finish or stop this bot's turns before moving its workspace."
        }
        return Workspace.problem(with: path, for: id, among: bots, botsRoot: settings.expandedBotsRoot)
    }

    /// The default workspace for a new bot named `name`: its slug under the bots folder, numbered
    /// when another bot already uses that folder.
    func defaultWorkspace(for name: String) -> String {
        let base = (settings.expandedBotsRoot as NSString).appendingPathComponent(Bot.slug(name))
        var path = base
        var n = 2
        while bots.contains(where: { $0.workspace == path }) {
            path = "\(base)-\(n)"
            n += 1
        }
        return path
    }

    func create(_ draft: Bot) {
        var bot = draft
        bot.name = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if bot.workspace.trimmingCharacters(in: .whitespaces).isEmpty { bot.workspace = defaultWorkspace(for: bot.name) }
        bot.workspace = (bot.workspace as NSString).expandingTildeInPath
        if bot.emoji.isEmpty { bot.emoji = "🤖" }
        bots.append(bot)
        threads[.home(bot.id)] = []
        tasks[bot.id] = []
        save(bot)
        destination = nil
        selection = bot.id
        prepareWorkspace(bot)
        send(BotContext.introPrompt, to: .home(bot.id), visible: false)
    }

    func update(_ edited: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == edited.id }) else { return }
        var bot = edited
        bot.workspace = (bot.workspace as NSString).expandingTildeInPath
        if bot.emoji.isEmpty { bot.emoji = "🤖" }
        if let problem = workspaceProblem(bot.workspace, for: bot.id) {
            append(ChatMessage(role: .error, text: problem), to: .home(bot.id))
            return
        }
        if bot.workspace != bots[i].workspace {
            // The bot's history, logs and tasks move with it.
            do {
                try BotHome(workspace: bots[i].workspace).move(toWorkspace: bot.workspace)
            } catch {
                append(ChatMessage(role: .error, text: "Couldn't move this bot's history to \(bot.workspace): \(error.localizedDescription)"), to: .home(bot.id))
                return
            }
        }
        let moved = bot.workspace != bots[i].workspace
        bots[i] = bot
        save(bot)
        prepareWorkspace(bot)
        if moved { reloadPet(bot.id) }
    }

    func setModel(_ selected: String, for target: ChatTarget) {
        guard !isRunning(target) else { return }
        change(target) { $0.selectModel(selected) }
    }

    func setReasoningEffort(_ effort: ReasoningEffort?, for target: ChatTarget) {
        guard !isRunning(target), let current = runSettings(of: target) else { return }
        let effective = GenerationOptions.effectiveModel(current.model, kind: current.account.kind, openRouterDefault: settings.openRouterModel)
        if let effort, !GenerationOptions.efforts(for: current.account.kind, model: effective).contains(effort) { return }
        change(target) { $0.reasoningEffort = effort }
    }

    /// Changes this Home or task conversation's account; its next message starts a session there.
    func setAccount(_ accountID: String, for target: ChatTarget) {
        guard !isRunning(target) else { return }
        let account = settings.account(accountID)
        change(target) { $0.selectAccount(account) }
    }

    func delete(_ id: UUID) {
        delegation.stopBot(id)
        for (target, run) in runs where target.botID == id { run.stop() }
        petRuns[id]?.stop()
        petTasks.removeValue(forKey: id)?.cancel()
        dispatchTimers.removeValue(forKey: id)?.invalidate()
        if let bot = bot(id) { BotHome(workspace: bot.workspace).trash() }
        bots.removeAll { $0.id == id }
        tasks[id] = nil
        threads = threads.filter { $0.key.botID != id }
        runStates = runStates.filter { $0.key.botID != id }
        waiting = waiting.filter { $0.key.botID != id }
        unread = unread.filter { $0.botID != id }
        drafts = drafts.filter { $0.key.botID != id }
        openTask[id] = nil
        pets[id] = nil
        petJobs[id] = nil
        messageQueues = messageQueues.filter { $0.key.botID != id }
        reactions = reactions.filter { $0.key.botID != id }
        reactionTickets = reactionTickets.filter { $0.key.botID != id }
        saveIndex()
        if selection == id { selection = bots.first?.id }
    }

    /// Starts the conversation's next turn in a fresh CLI session (with the identity, memory and recap again).
    func newSession(_ target: ChatTarget) {
        guard !isRunning(target), runSettings(of: target) != nil else { return }
        change(target) {
            $0.sessionID = nil
            $0.sessionAccountID = nil
        }
        append(ChatMessage(role: .note, text: "New session"), to: target)
        saveThread(target)
    }

    func revealWorkspace(_ id: UUID) {
        guard let bot = bot(id) else { return }
        prepareWorkspace(bot)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bot.workspace)])
    }

    /// Opens the bot's `.botchu` folder (its settings, thread, tasks and logs) in Finder.
    func revealHistory(_ id: UUID) {
        guard let bot = bot(id) else { return }
        let home = BotHome(workspace: bot.workspace)
        try? FileManager.default.createDirectory(at: home.logsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(home.url)
    }

    // MARK: Tasks

    func newTask(for botID: UUID, repo: String? = nil, work: BotTask.Work? = nil, purpose: NewTaskSheet.Purpose = .work) {
        guard bot(botID) != nil else { return }
        taskSheet = TaskSheetRequest(botID: botID, repo: repo, work: work, purpose: work?.isPullRequest == true ? purpose : .work)
    }

    /// Records a task, opens its tab (when `show`), says so in its bot's Home, then makes its
    /// worktree and sends its first message.
    func startTask(_ task: BotTask, for botID: UUID, show: Bool) {
        guard bot(botID) != nil else { return }
        let target = ChatTarget.task(task.id, of: botID)
        tasks[botID, default: []].append(task)
        threads[target] = []
        saveTask(task, of: botID)
        postReceipt(TaskReceipt.started(task), task: task.id, for: botID)
        if show { self.show(target) }
        send(task.opening, to: target)
    }

    /// Closes a task's tab. Its record, conversation and worktree stay, and it can be opened again;
    /// a review's worktree, a temporary one, goes (unless it has changes), and opening it again
    /// makes a new one at the pull request's head.
    func closeTask(_ target: ChatTarget) {
        guard target.taskID != nil, !isRunning(target), delegation.activeCount(target) == 0, let i = taskIndex(target) else { return }
        tasks[target.botID]?[i].archivedAt = Date()
        let task = tasks[target.botID]![i]
        saveTask(task, of: target.botID)
        unread.remove(target)
        if openTask[target.botID] == target.taskID { openTask[target.botID] = nil }
        if task.review != nil, let folder = task.folder, case .success(let machine) = machine(of: task) {
            Task {
                guard await TaskWorktree.remove(folder, checkout: task.checkout, on: machine).ok, let i = taskIndex(target) else { return }
                tasks[target.botID]?[i].folder = nil
                saveTask(tasks[target.botID]![i], of: target.botID)
            }
        }
    }

    func reopenTask(_ target: ChatTarget) {
        guard let i = taskIndex(target), let bot = bot(target.botID) else { return }
        tasks[target.botID]?[i].archivedAt = nil
        saveTask(tasks[target.botID]![i], of: target.botID)
        if threads[target] == nil, let id = target.taskID {
            threads[target] = BotHome(workspace: bot.workspace).loadThread(task: id)
            let home = BotHome(workspace: bot.workspace)
            messageQueues[target] = MessageQueue(saved: home.loadQueuedMessages(task: id), delivered: thread(target),
                                                 paused: home.loadQueuePaused(task: id))
        }
        show(target)
        sendNextQueued(to: target)
    }

    func revealWorktree(_ target: ChatTarget) {
        guard let task = task(target), !task.isRemote, let folder = task.folder, FileManager.default.fileExists(atPath: folder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    /// Opens the worktree in Terminal: the folder here, or an SSH session into it on its host.
    func openWorktreeInTerminal(_ target: ChatTarget) {
        guard let task = task(target), let folder = task.folder,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        if let command = sshCommand(for: task) {
            // Terminal runs a .command file in a new window.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-\(task.id.uuidString.prefix(8)).command")
            try? "#!/bin/sh\nrm -f \"$0\"\nexec \(command)\n".write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else if FileManager.default.fileExists(atPath: folder) {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// The command that opens a shell in a remote task's worktree, as Terminal would run it.
    func sshCommand(for task: BotTask) -> String? {
        guard let folder = task.folder, let host = settings.host(task.hostID) else { return nil }
        return "ssh -t \(Shell.quote(host.destination)) \(Shell.quote("cd \(Machine.remotePath(folder)) && exec \"${SHELL:-/bin/sh}\" -l"))"
    }

    /// The checkouts tasks can start from, in the repositories folder.
    func checkouts() -> [RepoCheckout] {
        Repositories.scan(root: settings.expandedReposRoot)
    }

    /// Starts the tasks a bot asked for from its Home: the requests in its `.botchu/dispatch/`.
    func takeDispatches(for botID: UUID) {
        guard let bot = bot(botID), !dispatching.contains(botID), BotHome(workspace: bot.workspace).hasDispatches() else { return }
        dispatching.insert(botID)
        let root = settings.expandedReposRoot
        Task {
            // Off the main thread: the first look into ~/Desktop or ~/Documents waits on macOS's question.
            let checkouts = await Task.detached { Repositories.scan(root: root) }.value
            await loadRepositories()
            if let bot = self.bot(botID) {
                for request in BotHome(workspace: bot.workspace).peekDispatches() {
                    await startTask(requestedIn: request.file, data: request.data, checkouts: checkouts, for: botID)
                }
            }
            dispatching.remove(botID)
        }
    }

    /// Starts the task one request asks for, where its repository lives (or on the machine it
    /// names), or says in Home why it can't. The request is taken just before its task is recorded,
    /// so it is never lost in between, nor taken twice.
    private func startTask(requestedIn file: URL, data: Data, checkouts: [RepoCheckout], for botID: UUID) async {
        let name = "dispatch/\(file.lastPathComponent)"
        do {
            let wanted = try TaskRequest.parse(data)
            let found = try repository(named: wanted.repo, checkouts: checkouts).get()
            var location: RepoLocation
            if let checkout = found.checkout {
                location = RepoLocation(path: checkout.path)
            } else if let machine = wanted.machine {
                let host = try host(named: machine).get()
                location = RepoLocation(hostID: host?.id, path: await folder(of: found.repo, on: host?.id))
            } else {
                location = await self.location(of: found.repo)
            }
            if location.hostID == nil { location.path = (location.path as NSString).expandingTildeInPath }
            let work = wanted.issue.map { BotTask.Work(number: $0, isPullRequest: false, repo: found.repo) }
                ?? wanted.pullRequest.map { BotTask.Work(number: $0, isPullRequest: true, repo: found.repo) }
            // A pull request's task works on the pull request's own branch (or its head, for a review).
            let branch = work?.isPullRequest == true ? "" : wanted.branch ?? ""
            if let other = taskAlreadyWorking(on: found.repo, hostID: location.hostID, work: work, review: wanted.review, branch: branch) {
                throw TaskRequest.Problem(message: "“\(other.title)” already works on it; send it a message instead")
            }
            guard let bot = bot(botID), BotHome(workspace: bot.workspace).take(dispatch: file) else { return }
            let task = BotTask(for: bot, repo: found.repo, checkout: location.path, work: work, brief: wanted.task, branch: branch,
                               title: wanted.title, origin: .home, host: settings.host(location.hostID), review: wanted.review)
            startTask(task, for: botID, show: false)
        } catch {
            guard let bot = bot(botID), BotHome(workspace: bot.workspace).take(dispatch: file) else { return }
            let reason = (error as? TaskRequest.Problem)?.message ?? error.localizedDescription
            postReceipt(TaskReceipt.couldNotStart(name, reason: reason), task: nil, for: botID)
        }
    }

    /// Looks for requests every two seconds while the bot's Home turn runs, and once more after.
    private func watchDispatches(for botID: UUID, while running: Bool) {
        dispatchTimers.removeValue(forKey: botID)?.invalidate()
        if running {
            dispatchTimers[botID] = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.takeDispatches(for: botID) }
            }
        } else {
            takeDispatches(for: botID)
            // A file written just before the turn ended waits until it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.takeDispatches(for: botID) }
        }
    }

    /// Adds a receipt to the bot's Home thread. A newer word on the task the last receipt is about
    /// replaces it, so a task that keeps working doesn't fill Home.
    private func postReceipt(_ text: String, task taskID: UUID?, for botID: UUID) {
        let home = ChatTarget.home(botID)
        let receipt = ChatMessage(role: .receipt, text: text, taskID: taskID)
        let messages = thread(home)
        if let taskID, let last = messages.last, last.role == .receipt, last.taskID == taskID {
            threads[home]?[messages.count - 1] = receipt
        } else {
            append(receipt, to: home)
        }
        saveThread(home)
    }

    /// The task updates for a Home turn: a report on each task the thread has receipts about since
    /// the owner's last message that reached the CLI (one that got an answer), and each request
    /// BotChu couldn't start. Updates a turn that never ran carried are told again.
    private func taskUpdates(for botID: UUID, in history: [ChatMessage]) -> String? {
        var since = 0
        var answered = false
        for i in history.indices.reversed() {
            if history[i].role == .assistant || history[i].role == .tool {
                answered = true
            } else if history[i].role == .user, answered {
                since = i + 1
                break
            }
        }
        var reported: Set<UUID> = []
        var reports: [String] = []
        for message in history[since...] where message.role == .receipt {
            if let id = message.taskID {
                if reported.insert(id).inserted, let task = task(id, of: botID) { reports.append(report(on: task, of: botID)) }
            } else {
                reports.append(message.text)
            }
        }
        return BotContext.taskUpdates(reports)
    }

    /// A task as its bot's Home hears of it; `replyLimit` keeps an overview of many tasks short.
    private func report(on task: BotTask, of botID: UUID, replyLimit: Int = BotContext.maxReportReply) -> String {
        let target = ChatTarget.task(task.id, of: botID)
        // A closed task's thread isn't read at launch.
        if threads[target] == nil, let bot = bot(botID) {
            threads[target] = BotHome(workspace: bot.workspace).loadThread(task: task.id)
        }
        return BotContext.taskReport(task, status: BotStatus.make(task: task, messages: thread(target), run: runStates[target]),
                                     pullRequest: task.pullRequest, lastReply: thread(target).last(where: { $0.role == .assistant })?.text,
                                     replyLimit: replyLimit)
    }

    /// Whether a task on this Mac has its worktree to run in. A task on a host is asked there.
    private func hasWorktree(_ task: BotTask) -> Bool {
        !task.isRemote && (task.folder.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    }

    /// The open task, of any bot, that already works on this issue or pull request (or reviews it,
    /// for a review), or on this branch, in the repository on the same machine: a second task
    /// there would share its worktree, or do the same review twice.
    func taskAlreadyWorking(on repo: String, hostID: UUID?, work: BotTask.Work?, review: BotTask.Review?, branch: String,
                            except id: UUID? = nil) -> BotTask? {
        tasks.values.joined().first { other in
            guard other.id != id, !other.isArchived, other.hostID == hostID,
                  other.repo.caseInsensitiveCompare(repo) == .orderedSame else { return false }
            if review == nil, other.review == nil, !branch.isEmpty, other.branch == branch { return true }
            guard let work, let theirs = other.work, (review == nil) == (other.review == nil) else { return false }
            return theirs.number == work.number && theirs.isPullRequest == work.isPullRequest
        }
    }

    /// Makes (or reopens) the task's worktree, or waits for the making already under way. Returns
    /// why it couldn't, or nil when the worktree is ready.
    private func worktree(for target: ChatTarget) async -> TaskWorktree.Failure? {
        if let underway = makings[target] { return await underway.value }
        guard let task = task(target) else { return TaskWorktree.Failure(step: "The task is gone", output: "") }
        if hasWorktree(task) { return nil }
        let making = Task { await makeWorktree(for: task, of: target.botID) }
        makings[target] = making
        let failure = await making.value
        makings[target] = nil
        return failure
    }

    /// Looks up the task's issue or pull request, clones the repository on the task's machine when
    /// it isn't there, names the branch and makes (or reopens) the worktree, or a review's detached
    /// one, after any other git work in the same checkout. A task on a host that still has its
    /// worktree there is ready at once. The task's thread says how it went.
    private func makeWorktree(for task: BotTask, of botID: UUID) async -> TaskWorktree.Failure? {
        let machine: Machine
        switch self.machine(of: task) {
        case .success(let found): machine = found
        case .failure(let failure): return recordWorktree(task, of: botID, failure: failure)
        }
        if machine.isRemote, let folder = task.folder, await machine.hasFolder(folder) { return nil }
        var task = task
        var failure: TaskWorktree.Failure?
        if let work = task.work, work.title.isEmpty || (work.isPullRequest && task.branch.isEmpty && task.review == nil) {
            switch await GitHubLookup.work(number: work.number, pullRequest: work.isPullRequest, repo: task.repo) {
            case .success(let found) where found.fromFork && task.review == nil:
                failure = TaskWorktree.Failure(step: "This pull request comes from a fork; start a review task instead", output: "")
            case .success(let found):
                task.work = found.work
                if found.work.isPullRequest, task.review == nil, let head = found.branch { task.branch = head }
            case .failure(let error):
                failure = error
            }
        }
        let looked = task
        let lookupFailure = failure
        return await inCheckout("\(task.hostID?.uuidString ?? "")|\(task.checkout)") { [self] in
            var task = looked
            var failure = lookupFailure
            if failure == nil {
                switch await TaskWorktree.checkout(task.repo, at: task.checkout, on: machine) {
                case .success(let checkout): task.checkout = checkout
                case .failure(let error): failure = error
                }
            }
            if failure == nil, let review = task.work, task.review != nil {
                switch await TaskWorktree.review(number: review.number, checkout: task.checkout, on: machine) {
                case .success(let made):
                    task.folder = made.folder
                    task.head = made.head
                case .failure(let error): failure = error
                }
                return recordWorktree(task, of: botID, failure: failure)
            }
            if failure == nil, task.branch.isEmpty {
                let issue = task.work.flatMap { $0.isPullRequest ? nil : $0.number }
                task.branch = TaskNaming.branch(issue: issue, text: task.work?.title ?? task.brief,
                                                fallback: "task-" + task.id.uuidString.prefix(6).lowercased())
                // A name made from a brief may be another task's, or an older branch of the repository's.
                if task.work == nil { task.branch = await unusedBranch(task.branch, for: task, on: machine) }
            }
            if failure == nil, let other = taskAlreadyWorking(on: task.repo, hostID: task.hostID, work: nil, review: nil,
                                                              branch: task.branch, except: task.id) {
                failure = TaskWorktree.Failure(step: "“\(other.title)” already works on this in the repository",
                                               output: "Continue in that task's conversation.")
            }
            if failure == nil {
                switch await TaskWorktree.prepare(branch: task.branch, checkout: task.checkout, on: machine) {
                case .success(let folder): task.folder = folder
                case .failure(let error): failure = error
                }
            }
            return recordWorktree(task, of: botID, failure: failure)
        }
    }

    /// Saves what making the worktree found (the folder only when it was made), and says so in the
    /// task's thread.
    private func recordWorktree(_ task: BotTask, of botID: UUID, failure: TaskWorktree.Failure?) -> TaskWorktree.Failure? {
        let target = ChatTarget.task(task.id, of: botID)
        guard let i = taskIndex(target) else { return failure ?? TaskWorktree.Failure(step: "The task is gone", output: "") }
        tasks[botID]?[i].work = task.work
        tasks[botID]?[i].branch = task.branch
        tasks[botID]?[i].checkout = task.checkout
        if failure == nil {
            tasks[botID]?[i].folder = task.folder
            tasks[botID]?[i].head = task.head
        }
        saveTask(tasks[botID]![i], of: botID)
        let on = task.isRemote ? " on \(machineName(task.hostID, fallback: task.hostName))" : ""
        if let failure {
            append(ChatMessage(role: .error, text: "Couldn't make this task's worktree\(on). " + failure.message), to: target)
        } else {
            append(ChatMessage(role: .note, text: "Task workspace ready\(on)"), to: target)
        }
        saveThread(target)
        return failure
    }

    /// The branch, numbered when another task in the repository has the name, or the repository has
    /// a branch of that name already.
    private func unusedBranch(_ branch: String, for task: BotTask, on machine: Machine) async -> String {
        let taken = Set(tasks.values.joined().filter { $0.id != task.id && $0.hostID == task.hostID && $0.repo == task.repo }.map(\.branch))
        for n in 1...50 {
            let candidate = n == 1 ? branch : TaskNaming.numbered(branch, n)
            if taken.contains(candidate) { continue }
            let exists = await machine.script(#"git show-ref --verify --quiet "refs/heads/$1" || git show-ref --verify --quiet "refs/remotes/origin/$1""#,
                                              arguments: [candidate], in: task.checkout).ok
            if !exists { return candidate }
        }
        return TaskNaming.numbered(branch, 51)
    }

    /// Runs `work` after the git work already queued in `checkout`.
    private func inCheckout<T: Sendable>(_ checkout: String, _ work: @escaping () async -> T) async -> T {
        let before = checkoutWork[checkout]
        let mine = Task { () -> T in
            await before?.value
            return await work()
        }
        checkoutWork[checkout] = Task { _ = await mine.value }
        return await mine.value
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    // MARK: Pets

    /// Reads the bot's pet again (its manifest; clips load when they play).
    func reloadPet(_ id: UUID) {
        guard let bot = bot(id) else { return }
        pets[id] = PetVideoPackage.load(from: PetVideo.folder(for: BotHome(workspace: bot.workspace)))
    }

    /// Shows a short reaction, unless a turn is running, then goes back to what the bot shows otherwise.
    func react(_ reaction: BotActivity, for target: ChatTarget, seconds: Double) {
        guard !isRunning(target) else { return }
        let ticket = UUID()
        reactionTickets[target] = ticket
        reactions[target] = reaction
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self?.reactionTickets[target] == ticket else { return }
            self?.reactions[target] = nil
            self?.reactionTickets[target] = nil
        }
    }

    // MARK: Turns

    @discardableResult
    func send(_ text: String, to target: ChatTarget, visible: Bool = true) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runSettings(of: target) != nil else { return false }
        if !visible {
            return beginTurn(text, for: target, message: nil)
        }
        var queue = messageQueues[target] ?? MessageQueue()
        queue.enqueue(ChatMessage(role: .user, text: text))
        // Save before clearing the composer; a failed write must leave the owner's draft intact.
        guard saveQueue(queue, for: target) else { return false }
        messageQueues[target] = queue
        sendNextQueued(to: target)
        return true
    }

    /// Resume a paused queue: its next message goes out now, or, during a turn, as a follow-up.
    func resumeQueuedMessages(to target: ChatTarget) {
        guard messageQueues[target]?.messages.isEmpty == false else { return }
        messageQueues[target]?.resume()
        if let queue = messageQueues[target] { _ = saveQueue(queue, for: target) }
        sendNextQueued(to: target)
    }

    func removeQueuedMessage(_ id: UUID, from target: ChatTarget) {
        guard var queue = messageQueues[target] else { return }
        queue.remove(id)
        if saveQueue(queue, for: target) { messageQueues[target] = queue }
    }

    func editQueuedMessage(_ id: UUID, in target: ChatTarget) {
        guard let message = messageQueues[target]?.messages.first(where: { $0.id == id }),
              messageQueues[target]?.isInFlight(id) == false else { return }
        removeQueuedMessage(id, from: target)
        guard messageQueues[target]?.messages.contains(where: { $0.id == id }) == false else { return }
        let draft = drafts[target] ?? ""
        drafts[target] = message.text + (draft.isEmpty ? "" : "\n\n" + draft)
    }

    /// Whether follow-ups reach this conversation's CLI during a turn, at its next tool call, rather
    /// than once the turn ends: Claude Code, on This Mac.
    func takesFollowUpsMidTurn(_ target: ChatTarget) -> Bool {
        guard let current = runSettings(of: target) else { return false }
        return CommandBuilder.takesInputMidTurn(current.account.kind) && task(target)?.isRemote != true
    }

    /// Sends the next queued message: as a new turn when none is running, or written to a running
    /// CLI that takes input mid-turn. Otherwise it waits for the turn to end.
    func sendNextQueued(to target: ChatTarget) {
        // Not while quitting, nor while restoring sub-agents at launch (`init` sends afterwards).
        guard !terminating, delegation != nil else { return }
        if isRunning(target) {
            sendFollowUps(to: target)
            return
        }
        guard let message = messageQueues[target]?.next else { return }
        guard beginTurn(message.text, for: target, message: message) else {
            pauseQueue(target)
            return
        }
        messageQueues[target]?.remove(message.id)
        if let queue = messageQueues[target] { _ = saveQueue(queue, for: target) }
    }

    /// Writes queued messages to the running CLI, which takes them at its next tool call. They stay
    /// queued, unable to be edited, until the CLI echoes them (`AgentEvent.inputTaken`); any it
    /// never takes go out as the next turn.
    private func sendFollowUps(to target: ChatTarget) {
        guard let run = runs[target], run.acceptsInput, var input = inputs[target], input.ledger.acceptsFollowUps else { return }
        while let message = messageQueues[target]?.next, let line = CommandBuilder.inputLine(kind: input.kind, text: message.text) {
            guard run.send(line) else { break }
            messageQueues[target]?.markInFlight(message.id)
            input.ledger.wrote()
        }
        inputs[target] = input
    }

    /// Withdraws automatic delivery, remembered across relaunches: after Stop or a real failure,
    /// the queue waits for the owner. Quitting BotChu doesn't count.
    private func pauseQueue(_ target: ChatTarget) {
        guard !terminating, messageQueues[target]?.messages.isEmpty == false else { return }
        messageQueues[target]?.pause()
        if let queue = messageQueues[target] { _ = saveQueue(queue, for: target) }
    }

    private func beginTurn(_ text: String, for target: ChatTarget, message: ChatMessage?) -> Bool {
        guard !isRunning(target), let bot = bot(target.botID), let current = runSettings(of: target) else { return false }
        let history = thread(target)
        // Home hears what its tasks did since the owner's last message there.
        let updates = target.taskID == nil ? taskUpdates(for: bot.id, in: history) : nil

        if let message {
            if current.resumableSessionID == nil, history.contains(where: { $0.role == .assistant }) {
                // Name the account on the note New Session left, or add one (an account switch).
                if let last = history.last, last.role == .note, last.text.hasPrefix("New session") {
                    threads[target]?.removeLast()
                }
                append(ChatMessage(role: .note, text: "New session on \(current.account.name)"), to: target)
            }
            append(message, to: target)
        } else {
            append(ChatMessage(role: .note, text: "\(bot.name) was created on \(current.account.name)"), to: target)
        }
        guard saveThread(target) else {
            // Still queued, not delivered. Keep one copy in the outbox and explain the failure.
            threads[target] = history + [ChatMessage(role: .error, text: "Couldn't save this message. It is still queued.")]
            return false
        }

        if let task = task(target), !hasWorktree(task) {
            // On a host, the worktree is checked there (and made again if it went) before each turn.
            let ticket = UUID()
            waiting[target] = ticket
            runStates[target] = RunState(preparing: true)
            Task {
                let failure = await worktree(for: target)
                // Stopped meanwhile: the turn doesn't start, and the worktree stays for the next message.
                guard waiting[target] == ticket else { return }
                waiting[target] = nil
                runStates[target] = nil
                if let failure {
                    pauseQueue(target)
                    if let task = self.task(target) {
                        postReceipt(TaskReceipt.failed(task, error: failure.step), task: task.id, for: target.botID)
                    }
                } else {
                    startTurn(text, for: target, history: history, updates: nil)
                    if !isRunning(target) { pauseQueue(target) }
                }
            }
        } else {
            startTurn(text, for: target, history: history, updates: updates)
            if !isRunning(target) { pauseQueue(target) }
        }
        return true
    }

    /// Runs the CLI for one turn of the conversation, in the bot's workspace or the task's worktree.
    private func startTurn(_ text: String, for target: ChatTarget, history: [ChatMessage], updates: String?) {
        guard let bot = bot(target.botID), let current = runSettings(of: target) else { return }
        let task = task(target)
        let id = bot.id
        let account = current.account
        let resume = current.resumableSessionID
        prepareWorkspace(bot)
        let memory = Workspace.read((bot.workspace as NSString).appendingPathComponent(BotContext.memoryFile))
        let soul = Workspace.read((bot.workspace as NSString).appendingPathComponent(BotContext.soulFile))
        let instructions = Workspace.read(BotDocument.instructions.url(for: bot).path)
        let sharedMemory = Workspace.read(settings.sharedMemoryPath)
        let team = Workspace.read(settings.teamPath)
        let directory: String
        var machine = Machine.thisMac
        var preamble: String?
        if let task {
            guard let folder = task.folder else { return }
            switch self.machine(of: task) {
            case .success(let found): machine = found
            case .failure(let failure):
                append(ChatMessage(role: .error, text: failure.message), to: target)
                saveThread(target)
                return
            }
            directory = folder
            if resume == nil {
                // A task on a host can't open the bot's folder, so it hears the recent Home conversation.
                preamble = BotContext.taskPreamble(bot: bot, task: task, memory: memory, sharedMemory: sharedMemory, history: history,
                                                   machine: machineDescription(of: task),
                                                   home: machine.isRemote ? thread(.home(id)) : [], soul: soul,
                                                   instructions: instructions, team: team)
            }
        } else {
            directory = bot.workspace
            if resume == nil {
                preamble = BotContext.sessionPreamble(bot: bot, memory: memory, sharedMemory: sharedMemory, history: history,
                                                      tasks: openTasks(of: id).map { report(on: $0, of: id, replyLimit: 240) }, soul: soul,
                                                      instructions: instructions, team: team)
            }
        }
        let ticket = UUID()
        waiting[target] = ticket
        runStates[target] = RunState(preparing: true)
        Task { [self] in
            do {
                let context = try await delegation.prepareCaller(target: target, directory: directory, machine: machine, hostID: task?.hostID)
                guard waiting[target] == ticket else { delegation.endCaller(context.id); return }
                waiting[target] = nil
                let needsDelegationContext = resume.map { !(delegationSessions[target] ?? []).contains($0) } ?? true
                let delegationInstructions = needsDelegationContext ? BotContext.subagentsSection(availableBots: delegation.roster) : nil
                let contextSections = [preamble, delegationInstructions].compactMap { $0 }
                let prompt = BotContext.prompt(for: text, preamble: contextSections.isEmpty ? nil : contextSections.joined(separator: "\n\n"), updates: updates)
                let model = GenerationOptions.effectiveModel(current.model, kind: account.kind, openRouterDefault: settings.openRouterModel)
                // A CLI that takes input mid-turn keeps its stdin open for follow-ups (This Mac only).
                let liveInput = CommandBuilder.takesInputMidTurn(account.kind) && !machine.isRemote
                var invocation = CommandBuilder.invocation(
                    kind: account.kind,
                    prompt: prompt,
                    model: model,
                    sessionID: resume,
                    reasoningEffort: current.reasoningEffort,
                    openRouterKey: account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil,
                    liveInput: liveInput)

                invocation.environment.merge(context.environment) { _, new in new }

                // On a host, the OpenRouter key stays here: the CLI there uses that machine's own.
                if account.kind == .pi, !machine.isRemote, Keychain.get(Keychain.openRouterAccount)?.isEmpty ?? true {
                    delegation.endCaller(context.id)
                    runStates[target] = nil
                    pauseQueue(target)
                    append(ChatMessage(role: .error, text: "Add your OpenRouter API key in BotChu ▸ Settings first."), to: target)
                    saveThread(target)
                    return
                }

                // On a host, its own command for the account when it has one.
                let command = task.flatMap { settings.host($0.hostID)?.command(for: account) } ?? settings.command(for: account)
                let run = machine.isRemote
                    ? AgentRun(command: command, invocation: invocation, on: machine, folder: directory)
                    : AgentRun(command: command, invocation: invocation, directory: URL(fileURLWithPath: directory, isDirectory: true))
                let place = task.map { machineName($0.hostID, fallback: $0.hostName) } ?? "This Mac"
                let home = BotHome(workspace: bot.workspace)
                let what = task.map { "\($0.title) turn" } ?? "turn"
                let startedAt = Date()
                let turnStart = thread(target).count
                var parser = StreamParsers.make(for: account.kind)
                var assembler = ThreadAssembler()
                var outcome = TurnOutcome()
                let accountID = account.id

                run.onLines = { [weak self, weak run] lines in
                    guard let self, let run, self.runs[target] === run, self.runSettings(of: target) != nil else { return }
                    if self.runStates[target]?.hasOutput == false { self.runStates[target]?.hasOutput = true }
                    var messages = self.thread(target)
                    var delivered = false
                    for line in lines {
                        for event in parser.parse(line: line) {
                            // After Stop, a CLI's last word is about the interruption (Antigravity
                            // repeats its whole reply as a failure); the "Stopped" note says it.
                            if run.stopped, case .failed = event { continue }
                            outcome.record(event)
                            switch event {
                            case .session(let reported):
                                let session = CommandBuilder.resumeID(kind: account.kind, invocation: invocation, reported: reported)
                                self.recordSession(session, accountID: accountID, for: target)
                                self.delegationSessions[target, default: []].insert(session)
                            case .inputTaken:
                                guard self.inputs[target] != nil else { break }
                                if self.inputs[target]?.ledger.taken() == true {
                                    // A follow-up reached the CLI: it joins the transcript here.
                                    if let message = self.messageQueues[target]?.acknowledge() {
                                        assembler.apply(event, to: &messages)
                                        messages.append(message)
                                        delivered = true
                                    }
                                } else {
                                    // The prompt's echo: this CLI takes follow-ups from now on.
                                    self.runStates[target]?.takesInput = true
                                }
                            case .finished, .failed:
                                // Its input closes once the CLI has taken everything written to it.
                                if self.inputs[target]?.ledger.turnEnded() == true {
                                    run.closeInput()
                                    self.runStates[target]?.takesInput = false
                                }
                            default: break
                            }
                            if let activity = BotActivity.next(after: event),
                               activity != self.runStates[target]?.activity || self.runStates[target]?.pending != nil,
                               let wait = self.runStates[target]?.move(to: activity) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak run] in
                                    guard let run, self?.runs[target] === run else { return }
                                    self?.runStates[target]?.settle()
                                }
                            }
                            if case .inputTaken = event { continue }
                            assembler.apply(event, to: &messages)
                        }
                    }
                    self.threads[target] = messages
                    if delivered {
                        // Transcript first: recovery drops a queued copy of a delivered message.
                        self.saveThread(target)
                        if let queue = self.messageQueues[target] { _ = self.saveQueue(queue, for: target) }
                    }
                    // Messages queued before the CLI could take them.
                    self.sendFollowUps(to: target)
                }
                run.onExit = { [weak self, weak run] status, stderr in
                    guard let self, let run, self.runs[target] === run else { return }
                    self.runs[target] = nil
                    self.inputs[target] = nil
                    self.delegation.endCaller(context.id)
                    self.runStates[target] = nil
                    if target.taskID == nil { self.watchDispatches(for: id, while: false) }
                    // The bot (or the task) was deleted while it ran.
                    guard self.runSettings(of: target) != nil else { return }
                    var messages = self.thread(target)
                    assembler.apply(.textEnd, to: &messages)
                    ThreadAssembler.closeRunningTools(&messages)
                    let stopped = run.stopped
                    if stopped {
                        messages.append(ChatMessage(role: .note, text: "Stopped"))
                    } else if !outcome.ended, machine.isRemote, status == 255 {
                        // ssh's own failure: the host didn't answer, or refused the connection.
                        let detail = Self.lastLines(stderr)
                        messages.append(ChatMessage(role: .error, text: "Couldn't reach \(place) over SSH" + (detail.isEmpty ? "." : ":\n\(detail)")))
                    } else if !outcome.ended {
                        // The stream never said the turn finished or failed: report what the CLI printed.
                        let detail = Self.lastLines(stderr)
                        messages.append(ChatMessage(role: .error, text: detail.isEmpty
                            ? "\(account.name) exited with status \(status) without replying."
                            : "\(account.name) exited with status \(status):\n\(detail)"))
                    }
                    self.threads[target] = messages
                    let saved = self.saveThread(target)
                    let failure = outcome.failure(stopped: stopped, exitError: messages.last(where: { !$0.role.isNote }).flatMap { $0.role == .error ? $0.text : nil })
                    if !stopped, failure == nil { self.react(.done, for: target, seconds: 3) }
                    if self.visibleBotID != id || self.tab(of: id) != target { self.unread.insert(target) }
                    let turn = messages.suffix(from: min(turnStart, messages.count))
                    if target.taskID != nil { self.finishTaskTurn(target, stopped: stopped, failure: failure, turn: Array(turn)) }
                    try? home.appendLog(TurnLog.ended(
                        at: Date(), startedAt: startedAt, status: status, stopped: stopped,
                        toolCalls: turn.filter { $0.role == .tool }.count,
                        error: turn.last(where: { $0.role == .error })?.text, stderr: stderr, what: what))
                    // Only Stop and real failures pause the queue (not quitting BotChu); messages the
                    // CLI never took go out as the next turn.
                    self.messageQueues[target]?.finishTurn(stopped: stopped && !self.terminating,
                                                           failed: !self.terminating && (!saved || failure != nil))
                    if let queue = self.messageQueues[target] { _ = self.saveQueue(queue, for: target) }
                    self.sendNextQueued(to: target)
                }

                do {
                    try? home.appendLog(TurnLog.started(at: startedAt, account: account, command: command,
                                                        arguments: invocation.arguments, prompt: prompt, resuming: resume, what: what,
                                                        directory: task == nil ? nil : machine.isRemote ? "\(place): \(directory)" : directory))
                    try run.start()
                    if let resume { delegationSessions[target, default: []].insert(resume) }
                    runs[target] = run
                    if liveInput { inputs[target] = (account.kind, InputLedger()) }
                    reactions[target] = nil
                    reactionTickets[target] = nil
                    runStates[target] = RunState()
                    if target.taskID == nil { watchDispatches(for: id, while: true) }
                    // A CLI that has printed nothing yet is usually blocked on a macOS prompt: as BotChu's
                    // child, it needs BotChu's permission for protected folders (Desktop, Documents) its own
                    // settings point into, and the prompt may be behind other windows.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak run] in
                        guard let self, let run, self.runs[target] === run, self.runStates[target]?.hasOutput == false else { return }
                        self.append(ChatMessage(role: .note, text: machine.isRemote
                            ? "\(account.name) hasn't started yet on \(place)."
                            : "\(account.name) hasn't started yet. If macOS is asking whether BotChu may access a folder, allow it: the CLI reads its settings from there."), to: target)
                    }
                } catch {
                    delegation.endCaller(context.id)
                    runStates[target] = nil
                    pauseQueue(target)
                    append(ChatMessage(role: .error, text: "Couldn't start \(account.name): \(error.localizedDescription)"), to: target)
                    saveThread(target)
                }
            } catch {
                guard waiting[target] == ticket else { return }
                waiting[target] = nil
                runStates[target] = nil
                pauseQueue(target)
                append(ChatMessage(role: .error, text: "Couldn't prepare delegation: \(error.localizedDescription)"), to: target)
                saveThread(target)
            }
        }
    }

    /// After a task's turn: notes the pull request its conversation linked to, saves what a task on a
    /// host asked to remember (it can't write the bot's MEMORY.md itself), and tells its bot's Home
    /// how the turn went (not when the owner stopped it).
    private func finishTaskTurn(_ target: ChatTarget, stopped: Bool, failure: String?, turn: [ChatMessage]) {
        guard let i = taskIndex(target), var task = tasks[target.botID]?[i], let bot = bot(target.botID) else { return }
        let pullRequest = TaskNaming.pullRequest(in: thread(target), task: task)
        if pullRequest != task.pullRequest {
            task.pullRequest = pullRequest
            tasks[target.botID]?[i] = task
            saveTask(task, of: target.botID)
        }
        let notes = task.isRemote ? MemoryNotes.remembered(in: turn) : []
        if !notes.isEmpty {
            do {
                try MemoryNotes.append(notes, toMemoryAt: (bot.workspace as NSString).appendingPathComponent(BotContext.memoryFile))
                append(ChatMessage(role: .note, text: notes.count == 1 ? "Saved 1 note to \(bot.name)'s memory" : "Saved \(notes.count) notes to \(bot.name)'s memory"), to: target)
            } catch {
                append(ChatMessage(role: .error, text: "Couldn't save to \(bot.name)'s MEMORY.md: \(error.localizedDescription)"), to: target)
            }
            saveThread(target)
        }
        guard !stopped else { return }
        postReceipt(failure.map { TaskReceipt.failed(task, error: $0) } ?? TaskReceipt.finished(task),
                    task: task.id, for: target.botID)
    }

    func stop(_ target: ChatTarget) {
        delegation.stopRoot(target)
        pauseQueue(target)
        inputs[target]?.ledger.close()
        if let run = runs[target] {
            run.stop()
        } else if runStates[target]?.preparing == true {
            // The worktree is still being made; the turn just won't start.
            waiting[target] = nil
            runStates[target] = nil
            append(ChatMessage(role: .note, text: "Stopped"), to: target)
            saveThread(target)
        }
    }

    /// BotChu is quitting. Queues stay as they are, to go out on their own after the next launch.
    func stopAll() {
        terminating = true
        delegation.stopAll()
        for target in Array(runStates.keys) { stop(target) }
        for run in petRuns.values { run.stop() }
        for task in petTasks.values { task.cancel() }
    }

    private func recordSession(_ sessionID: String, accountID: String, for target: ChatTarget) {
        guard let current = runSettings(of: target),
              current.sessionID != sessionID || current.sessionAccountID != accountID else { return }
        change(target) {
            $0.sessionID = sessionID
            $0.sessionAccountID = accountID
        }
    }

    // MARK: Storage

    private func append(_ message: ChatMessage, to target: ChatTarget) {
        threads[target, default: []].append(message)
    }

    private func taskIndex(_ target: ChatTarget) -> Int? {
        target.taskID.flatMap { id in tasks[target.botID]?.firstIndex { $0.id == id } }
    }

    /// Changes what a conversation runs on, its task's or its bot's, and saves it.
    private func change(_ target: ChatTarget, _ edit: (inout any RunSettings) -> Void) {
        if let i = taskIndex(target), var task: any RunSettings = tasks[target.botID]?[i] {
            edit(&task)
            guard let task = task as? BotTask else { return }
            tasks[target.botID]?[i] = task
            saveTask(task, of: target.botID)
        } else if target.taskID == nil, let i = bots.firstIndex(where: { $0.id == target.botID }) {
            var bot: any RunSettings = bots[i]
            edit(&bot)
            guard let bot = bot as? Bot else { return }
            bots[i] = bot
            save(bot)
        }
    }

    private func prepareWorkspace(_ bot: Bot) {
        do {
            // Instructions from an older bot.json move into INSTRUCTIONS.md once.
            var bot = bot
            if try Workspace.migrateInstructions(of: &bot), let i = bots.firstIndex(where: { $0.id == bot.id }) {
                bots[i].instructions = bot.instructions
                save(bots[i])
            }
            try Workspace.prepare(bot: bot, sharedMemoryPath: settings.sharedMemoryPath, repositoriesPath: settings.expandedReposRoot,
                                  machines: settings.hosts.map(\.nickname), availableBots: delegation.roster)
            try BotHome(workspace: bot.workspace).prepareDispatch()
        } catch {
            append(ChatMessage(role: .error, text: "Couldn't prepare \(bot.workspace): \(error.localizedDescription)"), to: .home(bot.id))
        }
    }

    /// Writes the bot's `.botchu/bot.json`, and the index of bot folders.
    func save(_ bot: Bot) {
        do {
            try BotHome(workspace: bot.workspace).save(bot)
        } catch {
            append(ChatMessage(role: .error, text: "Couldn't save this bot in \(bot.workspace): \(error.localizedDescription)"), to: .home(bot.id))
        }
        saveIndex()
    }

    private func saveTask(_ task: BotTask, of botID: UUID) {
        guard let bot = bot(botID) else { return }
        do {
            try BotHome(workspace: bot.workspace).save(task)
        } catch {
            append(ChatMessage(role: .error, text: "Couldn't save this task in \(bot.workspace): \(error.localizedDescription)"), to: .task(task.id, of: botID))
        }
    }

    private func saveIndex() {
        try? store.saveIndex(bots.map { Store.Entry(id: $0.id, workspace: $0.workspace) } + missing)
    }

    @discardableResult
    private func saveThread(_ target: ChatTarget) -> Bool {
        guard let bot = bot(target.botID) else { return false }
        let home = BotHome(workspace: bot.workspace)
        do {
            if let taskID = target.taskID {
                guard task(taskID, of: bot.id) != nil else { return false }
                try home.saveThread(thread(target), task: taskID)
            } else {
                try home.saveThread(thread(target))
            }
            return true
        } catch { return false }
    }

    private func saveQueue(_ queue: MessageQueue, for target: ChatTarget) -> Bool {
        guard let bot = bot(target.botID) else { return false }
        do {
            try BotHome(workspace: bot.workspace).saveQueuedMessages(queue.messages, paused: queue.isPaused, task: target.taskID)
            return true
        } catch {
            messageQueues[target]?.pause()
            append(ChatMessage(role: .error, text: "Couldn't save pending messages: \(error.localizedDescription)"), to: target)
            return false
        }
    }

    /// The last few meaningful lines of a CLI's stderr, for an error message.
    static func lastLines(_ text: String, count: Int = 8) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(count).joined(separator: "\n")
    }
}
