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
}

/// A conversation in the window: a bot's own (its Home), or one of its tasks.
struct ChatTarget: Hashable {
    var botID: UUID
    /// Nil for the bot's Home.
    var taskID: UUID?

    static func home(_ botID: UUID) -> ChatTarget { ChatTarget(botID: botID, taskID: nil) }
    static func task(_ taskID: UUID, of botID: UUID) -> ChatTarget { ChatTarget(botID: botID, taskID: taskID) }
}

@MainActor @Observable
final class AppModel {
    var bots: [Bot] = []
    /// Each bot's tasks, open and closed, oldest first.
    var tasks: [UUID: [BotTask]] = [:]
    /// Every conversation: each bot's Home, and each task.
    var threads: [ChatTarget: [ChatMessage]] = [:]
    /// Turns in progress, by conversation.
    var runStates: [ChatTarget: RunState] = [:]
    var selection: UUID? {
        didSet {
            guard let selection, selection != oldValue else { return }
            react(.greeting, for: selection, seconds: 2)
            unread.remove(tab(of: selection))
        }
    }
    /// The task tab shown for each bot; none shows its Home.
    var openTask: [UUID: UUID] = [:]
    /// Conversations whose turn ended while they weren't shown.
    var unread: Set<ChatTarget> = []
    /// What is typed in each conversation's message box and not sent yet.
    var drafts: [ChatTarget: String] = [:]
    /// Decoded pets, by bot; a bot without one shows its emoji.
    var petSheets: [UUID: PetSheet] = [:]
    /// Short pet reactions after a turn or on selection (`greeting`, `done`), by bot.
    var reactions: [UUID: BotActivity] = [:]
    /// Pets being drawn, or whose drawing failed, by bot (see `PetDrawing.swift`).
    var petDrawings: [UUID: PetDrawing] = [:]
    @ObservationIgnored var petRuns: [UUID: AgentRun] = [:]
    var editor: EditorRequest?
    var taskSheet: TaskSheetRequest?
    let settings: AppSettings

    private let store: Store
    /// Index entries whose folders don't hold their bot right now; kept so the bot returns with it.
    @ObservationIgnored private var missing: [Store.Entry] = []
    @ObservationIgnored private var runs: [ChatTarget: AgentRun] = [:]
    /// While a bot's Home turn runs, BotChu looks for the tasks it asks for (`.botchu/dispatch/`).
    @ObservationIgnored private var dispatchTimers: [UUID: Timer] = [:]

    init(store: Store? = nil, settings: AppSettings? = nil) {
        self.store = store ?? DevHooks.dataDir.map { Store(root: $0) } ?? .applicationSupport
        self.settings = settings ?? AppSettings()
        self.store.migrateIfNeeded()
        let loaded = self.store.loadBots()
        bots = loaded.bots
        missing = loaded.missing
        for bot in bots {
            threads[.home(bot.id)] = self.store.loadThread(for: bot)
            let home = BotHome(workspace: bot.workspace)
            tasks[bot.id] = home.loadTasks()
            for task in tasks[bot.id] ?? [] where !task.isArchived {
                threads[.task(task.id, of: bot.id)] = home.loadThread(task: task.id)
            }
            reloadPet(bot.id)
        }
        selection = bots.first?.id
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        // Requests left while BotChu wasn't running.
        for bot in bots { takeDispatches(for: bot.id) }
    }

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }
    func task(_ id: UUID, of botID: UUID) -> BotTask? { tasks[botID]?.first { $0.id == id } }
    func task(_ target: ChatTarget) -> BotTask? { target.taskID.flatMap { task($0, of: target.botID) } }
    func openTasks(of botID: UUID) -> [BotTask] { tasks[botID, default: []].filter { !$0.isArchived } }
    func closedTasks(of botID: UUID) -> [BotTask] { tasks[botID, default: []].filter(\.isArchived) }
    func thread(_ target: ChatTarget) -> [ChatMessage] { threads[target] ?? [] }
    func isRunning(_ target: ChatTarget) -> Bool { runStates[target] != nil }
    /// Whether any of the bot's conversations has a turn under way.
    func isBusy(_ botID: UUID) -> Bool { runStates.keys.contains { $0.botID == botID } }

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
        if let task = task(target) { return BotStatus.make(task: task, messages: thread(target), run: runStates[target]) }
        guard target.taskID == nil, let bot = bot(target.botID) else { return nil }
        return BotStatus.make(bot: bot, messages: thread(target), run: runStates[target], reaction: reactions[bot.id])
    }

    /// The bot as a whole, for its row and card: its Home, or while Home is idle, its working tasks.
    func status(of bot: Bot) -> BotStatus {
        let home = BotStatus.make(bot: bot, messages: thread(.home(bot.id)), run: runStates[.home(bot.id)], reaction: reactions[bot.id])
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

    /// Why a bot can't use `path` as its workspace, or nil when it can.
    func workspaceProblem(_ path: String, for id: UUID) -> String? {
        Workspace.problem(with: path, for: id, among: bots, botsRoot: settings.expandedBotsRoot)
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
        selection = bot.id
        prepareWorkspace(bot)
        send(BotContext.introPrompt, to: .home(bot.id), visible: false)
    }

    func update(_ edited: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == edited.id }) else { return }
        var bot = edited
        bot.workspace = (bot.workspace as NSString).expandingTildeInPath
        if bot.emoji.isEmpty { bot.emoji = "🤖" }
        if bot.workspace != bots[i].workspace {
            // The bot's history, logs and tasks move with it.
            do {
                try BotHome(workspace: bots[i].workspace).move(toWorkspace: bot.workspace)
            } catch {
                append(ChatMessage(role: .error, text: "Couldn't move this bot's history to \(bot.workspace): \(error.localizedDescription)"), to: .home(bot.id))
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
        guard !isRunning(target) else { return }
        change(target) { $0.reasoningEffort = effort }
    }

    /// Moves a task to another account; its next message starts a session there. (A bot's own
    /// account changes in Edit Bot.)
    func setAccount(_ accountID: String, for target: ChatTarget) {
        guard target.taskID != nil, !isRunning(target) else { return }
        change(target) { $0.selectAccount(accountID) }
    }

    func delete(_ id: UUID) {
        for (target, run) in runs where target.botID == id { run.stop() }
        petRuns[id]?.stop()
        dispatchTimers.removeValue(forKey: id)?.invalidate()
        if let bot = bot(id) { BotHome(workspace: bot.workspace).trash() }
        bots.removeAll { $0.id == id }
        tasks[id] = nil
        threads = threads.filter { $0.key.botID != id }
        runStates = runStates.filter { $0.key.botID != id }
        unread = unread.filter { $0.botID != id }
        drafts = drafts.filter { $0.key.botID != id }
        openTask[id] = nil
        petSheets[id] = nil
        reactions[id] = nil
        petDrawings[id] = nil
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

    func newTask(for botID: UUID) {
        guard bot(botID) != nil else { return }
        taskSheet = TaskSheetRequest(botID: botID)
    }

    /// Records a task, opens its tab (when `show`), says so in its bot's Home, then makes its
    /// worktree and sends its first message.
    func startTask(_ task: BotTask, for botID: UUID, show: Bool) {
        guard let bot = bot(botID) else { return }
        let target = ChatTarget.task(task.id, of: botID)
        tasks[botID, default: []].append(task)
        threads[target] = []
        saveTask(task, of: botID)
        if task.origin == .home {
            append(ChatMessage(role: .note, text: "\(bot.name) started this task from Home"), to: target)
        }
        postReceipt(TaskReceipt.started(task), task: task.id, for: botID)
        if show { self.show(target) }
        send(task.opening, to: target)
    }

    /// Closes a task's tab. Its record, conversation and worktree stay; it can be opened again.
    func closeTask(_ target: ChatTarget) {
        guard target.taskID != nil, !isRunning(target), let i = taskIndex(target) else { return }
        tasks[target.botID]?[i].archivedAt = Date()
        saveTask(tasks[target.botID]![i], of: target.botID)
        unread.remove(target)
        if openTask[target.botID] == target.taskID { openTask[target.botID] = nil }
    }

    func reopenTask(_ target: ChatTarget) {
        guard let i = taskIndex(target), let bot = bot(target.botID) else { return }
        tasks[target.botID]?[i].archivedAt = nil
        saveTask(tasks[target.botID]![i], of: target.botID)
        if threads[target] == nil, let id = target.taskID {
            threads[target] = BotHome(workspace: bot.workspace).loadThread(task: id)
        }
        show(target)
    }

    func revealWorktree(_ target: ChatTarget) {
        guard let folder = task(target)?.folder, FileManager.default.fileExists(atPath: folder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    func openWorktreeInTerminal(_ target: ChatTarget) {
        guard let folder = task(target)?.folder, FileManager.default.fileExists(atPath: folder),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: terminal,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// The checkouts tasks can start from, in the repositories folder.
    func checkouts() -> [RepoCheckout] {
        Repositories.scan(root: settings.expandedReposRoot)
    }

    /// Starts the tasks a bot asked for from its Home: the requests in its `.botchu/dispatch/`.
    func takeDispatches(for botID: UUID) {
        guard let bot = bot(botID) else { return }
        let requests = BotHome(workspace: bot.workspace).takeDispatches()
        guard !requests.isEmpty else { return }
        let root = settings.expandedReposRoot
        Task {
            // Off the main thread: the first look into ~/Desktop or ~/Documents waits on macOS's question.
            let checkouts = await Task.detached { Repositories.scan(root: root) }.value
            startTasks(requests, from: checkouts, for: botID)
        }
    }

    private func startTasks(_ requests: [(name: String, data: Data)], from checkouts: [RepoCheckout], for botID: UUID) {
        guard let bot = bot(botID) else { return }
        for request in requests {
            do {
                let wanted = try TaskRequest.parse(request.data)
                guard let checkout = Repositories.find(wanted.repo, in: checkouts) else {
                    throw TaskRequest.Problem(message: "there is no checkout of \(wanted.repo) in \((settings.expandedReposRoot as NSString).abbreviatingWithTildeInPath)")
                }
                let work = wanted.issue.map { BotTask.Work(number: $0, isPullRequest: false, repo: checkout.repo) }
                    ?? wanted.pullRequest.map { BotTask.Work(number: $0, isPullRequest: true, repo: checkout.repo) }
                let task = BotTask(for: bot, repo: checkout.repo, checkout: checkout.path, work: work, brief: wanted.task,
                                   branch: wanted.branch ?? "", title: wanted.title, origin: .home)
                startTask(task, for: botID, show: false)
            } catch {
                let reason = (error as? TaskRequest.Problem)?.message ?? error.localizedDescription
                postReceipt(TaskReceipt.couldNotStart("dispatch/\(request.name)", reason: reason), task: nil, for: botID)
            }
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
    /// the owner's last message, and each request BotChu couldn't start.
    private func taskUpdates(for botID: UUID, in history: [ChatMessage]) -> String? {
        let since = history.lastIndex(where: { $0.role == .user }).map { $0 + 1 } ?? 0
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
        return BotContext.taskReport(task, status: BotStatus.make(task: task, messages: thread(target), run: runStates[target]),
                                     pullRequest: task.pullRequest, lastReply: thread(target).last(where: { $0.role == .assistant })?.text,
                                     replyLimit: replyLimit)
    }

    /// Whether the task's worktree is there to run in.
    private func hasWorktree(_ task: BotTask) -> Bool {
        task.folder.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    /// Looks up the task's issue or pull request, names its branch and makes (or reopens) its
    /// worktree, then calls `done` with whether it is ready.
    private func prepareWorktree(for task: BotTask, of botID: UUID, then done: @escaping (Bool) -> Void) {
        let target = ChatTarget.task(task.id, of: botID)
        Task {
            var task = task
            var failure: TaskWorktree.Failure?
            if let work = task.work, work.title.isEmpty || (work.isPullRequest && task.branch.isEmpty) {
                switch await GitHubLookup.work(number: work.number, pullRequest: work.isPullRequest, repo: task.repo, in: task.checkout) {
                case .success(let found) where found.fromFork:
                    failure = TaskWorktree.Failure(step: "Pull request #\(work.number) comes from a fork, so its branch isn't on origin", output: "")
                case .success(let found):
                    task.work = found.work
                    if task.branch.isEmpty, let branch = found.branch { task.branch = branch }
                case .failure(let error):
                    failure = error
                }
            }
            if failure == nil, task.branch.isEmpty {
                let issue = task.work.flatMap { $0.isPullRequest ? nil : $0.number }
                task.branch = TaskNaming.branch(issue: issue, text: task.work?.title ?? task.brief,
                                                fallback: "task-" + task.id.uuidString.prefix(6).lowercased())
            }
            if failure == nil {
                switch await TaskWorktree.prepare(branch: task.branch, checkout: task.checkout) {
                case .success(let folder): task.folder = folder
                case .failure(let error): failure = error
                }
            }
            guard let i = taskIndex(target) else { return done(false) }
            tasks[botID]?[i].work = task.work
            tasks[botID]?[i].branch = task.branch
            tasks[botID]?[i].folder = task.folder
            saveTask(tasks[botID]![i], of: botID)
            if let failure {
                append(ChatMessage(role: .error, text: "Couldn't make this task's worktree. " + failure.message), to: target)
                saveThread(target)
                postReceipt(TaskReceipt.failed(task, error: failure.step), task: task.id, for: botID)
                done(false)
            } else {
                let folder = ((task.folder ?? "") as NSString).abbreviatingWithTildeInPath
                append(ChatMessage(role: .note, text: "Working in \(folder), on \(task.branch)"), to: target)
                saveThread(target)
                done(true)
            }
        }
    }

    // MARK: Pets

    /// Reads the bot's pet again, off the main thread (decoding an atlas takes a moment).
    func reloadPet(_ id: UUID) {
        guard let bot = bot(id) else { return }
        let home = BotHome(workspace: bot.workspace)
        Task.detached(priority: .utility) {
            let sheet = home.loadPet().flatMap(PetSheet.load)
            await MainActor.run { [weak self] in
                guard let self, self.bot(id)?.workspace == bot.workspace else { return }
                self.petSheets[id] = sheet
            }
        }
    }

    /// Copies a Codex pet folder (`pet.json` and its spritesheet) into the bot's folder.
    func importPet(from folder: URL, for id: UUID) throws {
        guard let bot = bot(id) else { return }
        let home = BotHome(workspace: bot.workspace)
        try PetPackage.importCodexPet(from: folder, into: home.petURL)
        reloadPet(id)
    }

    /// Shows a short reaction, unless a turn is running, then goes back to what the bot shows otherwise.
    func react(_ reaction: BotActivity, for id: UUID, seconds: Double) {
        guard !isBusy(id) else { return }
        reactions[id] = reaction
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.reactions[id] == reaction { self?.reactions[id] = nil }
        }
    }

    // MARK: Turns

    func send(_ text: String, to target: ChatTarget, visible: Bool = true) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning(target), let bot = bot(target.botID), let current = runSettings(of: target) else { return }
        let history = thread(target)
        // Home hears what its tasks did since the owner's last message there.
        let updates = target.taskID == nil ? taskUpdates(for: bot.id, in: history) : nil

        if visible {
            if current.resumableSessionID == nil, history.contains(where: { $0.role == .assistant }) {
                // Name the account on the note New Session left, or add one (an account switch).
                if let last = history.last, last.role == .note, last.text.hasPrefix("New session") {
                    threads[target]?.removeLast()
                }
                append(ChatMessage(role: .note, text: "New session on \(current.account.name)"), to: target)
            }
            append(ChatMessage(role: .user, text: text), to: target)
        } else {
            append(ChatMessage(role: .note, text: "\(bot.name) was created on \(current.account.name)"), to: target)
        }
        saveThread(target)

        if let task = task(target), !hasWorktree(task) {
            runStates[target] = RunState(preparing: true)
            prepareWorktree(for: task, of: bot.id) { [weak self] ready in
                // Stopped meanwhile: the worktree is kept for the next message.
                guard let self, self.runStates[target]?.preparing == true else { return }
                self.runStates[target] = nil
                if ready { self.startTurn(text, for: target, history: history, updates: nil) }
            }
        } else {
            startTurn(text, for: target, history: history, updates: updates)
        }
    }

    /// Runs the CLI for one turn of the conversation, in the bot's workspace or the task's worktree.
    private func startTurn(_ text: String, for target: ChatTarget, history: [ChatMessage], updates: String?) {
        guard let bot = bot(target.botID), let current = runSettings(of: target) else { return }
        let task = task(target)
        let id = bot.id
        let account = current.account
        let resume = current.resumableSessionID
        let memory = Workspace.read((bot.workspace as NSString).appendingPathComponent(BotContext.memoryFile))
        let sharedMemory = Workspace.read(settings.sharedMemoryPath)
        let directory: String
        var preamble: String?
        if let task {
            guard let folder = task.folder else { return }
            directory = folder
            if resume == nil {
                preamble = BotContext.taskPreamble(bot: bot, task: task, memory: memory, sharedMemory: sharedMemory, history: history)
            }
        } else {
            prepareWorkspace(bot)
            directory = bot.workspace
            if resume == nil {
                preamble = BotContext.sessionPreamble(bot: bot, memory: memory, sharedMemory: sharedMemory, history: history,
                                                      tasks: openTasks(of: id).map { report(on: $0, of: id, replyLimit: 240) })
            }
        }
        let prompt = BotContext.prompt(for: text, preamble: preamble, updates: updates)
        let model = account.kind == .pi && current.model.isEmpty ? settings.openRouterModel : current.model
        let invocation = CommandBuilder.invocation(
            kind: account.kind,
            prompt: prompt,
            model: model,
            sessionID: resume,
            reasoningEffort: current.reasoningEffort,
            openRouterKey: account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil)

        if account.kind == .pi, Keychain.get(Keychain.openRouterAccount)?.isEmpty ?? true {
            append(ChatMessage(role: .error, text: "Add your OpenRouter API key in BotChu ▸ Settings first."), to: target)
            saveThread(target)
            return
        }

        let command = settings.command(for: account)
        let run = AgentRun(command: command, invocation: invocation, directory: URL(fileURLWithPath: directory, isDirectory: true))
        let home = BotHome(workspace: bot.workspace)
        let what = task.map { "\($0.title) turn" } ?? "turn"
        let startedAt = Date()
        let turnStart = thread(target).count
        var parser = StreamParsers.make(for: account.kind)
        var assembler = ThreadAssembler()
        var ended = false
        let accountID = account.id

        run.onLines = { [weak self] lines in
            guard let self, self.runSettings(of: target) != nil else { return }
            if self.runStates[target]?.hasOutput == false { self.runStates[target]?.hasOutput = true }
            var messages = self.thread(target)
            for line in lines {
                for event in parser.parse(line: line) {
                    switch event {
                    case .session(let reported):
                        self.recordSession(CommandBuilder.resumeID(kind: account.kind, invocation: invocation, reported: reported),
                                           accountID: accountID, for: target)
                    case .finished, .failed:
                        ended = true
                    default: break
                    }
                    if let activity = BotActivity.next(after: event),
                       activity != self.runStates[target]?.activity || self.runStates[target]?.pending != nil,
                       let wait = self.runStates[target]?.move(to: activity) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                            self?.runStates[target]?.settle()
                        }
                    }
                    assembler.apply(event, to: &messages)
                }
            }
            self.threads[target] = messages
        }
        run.onExit = { [weak self, weak run] status, stderr in
            guard let self else { return }
            self.runs[target] = nil
            self.runStates[target] = nil
            if target.taskID == nil { self.watchDispatches(for: id, while: false) }
            // The bot (or the task) was deleted while it ran.
            guard self.runSettings(of: target) != nil else { return }
            var messages = self.thread(target)
            assembler.apply(.textEnd, to: &messages)
            ThreadAssembler.closeRunningTools(&messages)
            let stopped = run?.stopped == true
            if stopped {
                messages.append(ChatMessage(role: .note, text: "Stopped"))
            } else if !ended {
                // The stream never said the turn finished or failed: report what the CLI printed.
                let detail = Self.lastLines(stderr)
                messages.append(ChatMessage(role: .error, text: detail.isEmpty
                    ? "\(account.name) exited with status \(status) without replying."
                    : "\(account.name) exited with status \(status):\n\(detail)"))
            }
            self.threads[target] = messages
            self.saveThread(target)
            let failure = messages.last(where: { !$0.role.isNote }).flatMap { $0.role == .error ? $0.text : nil }
            if !stopped, failure == nil { self.react(.done, for: id, seconds: 3) }
            if self.selection != id || self.tab(of: id) != target { self.unread.insert(target) }
            if target.taskID != nil { self.finishTaskTurn(target, stopped: stopped, failure: failure) }
            let turn = messages.suffix(from: min(turnStart, messages.count))
            try? home.appendLog(TurnLog.ended(
                at: Date(), startedAt: startedAt, status: status, stopped: stopped,
                toolCalls: turn.filter { $0.role == .tool }.count,
                error: turn.last(where: { $0.role == .error })?.text, stderr: stderr, what: what))
        }

        do {
            try? home.appendLog(TurnLog.started(at: startedAt, account: account, command: command,
                                                arguments: invocation.arguments, prompt: prompt, resuming: resume, what: what,
                                                directory: task == nil ? nil : directory))
            try run.start()
            runs[target] = run
            reactions[id] = nil
            runStates[target] = RunState()
            if target.taskID == nil { watchDispatches(for: id, while: true) }
            // A CLI that has printed nothing yet is usually blocked on a macOS prompt: as BotChu's
            // child, it needs BotChu's permission for protected folders (Desktop, Documents) its own
            // settings point into, and the prompt may be behind other windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak run] in
                guard let self, let run, self.runs[target] === run, self.runStates[target]?.hasOutput == false else { return }
                self.append(ChatMessage(role: .note, text: "\(account.name) hasn't started yet. If macOS is asking whether BotChu may access a folder, allow it: the CLI reads its settings from there."), to: target)
            }
        } catch {
            append(ChatMessage(role: .error, text: "Couldn't start \(account.name): \(error.localizedDescription)"), to: target)
            saveThread(target)
        }
    }

    /// After a task's turn: notes the pull request its conversation linked to, and tells its bot's
    /// Home how the turn went (not when the owner stopped it).
    private func finishTaskTurn(_ target: ChatTarget, stopped: Bool, failure: String?) {
        guard let i = taskIndex(target), var task = tasks[target.botID]?[i] else { return }
        let pullRequest = TaskNaming.pullRequest(in: thread(target), task: task)
        if pullRequest != task.pullRequest {
            task.pullRequest = pullRequest
            tasks[target.botID]?[i] = task
            saveTask(task, of: target.botID)
        }
        guard !stopped else { return }
        postReceipt(failure.map { TaskReceipt.failed(task, error: $0) } ?? TaskReceipt.finished(task, pullRequest: pullRequest),
                    task: task.id, for: target.botID)
    }

    func stop(_ target: ChatTarget) {
        if let run = runs[target] {
            run.stop()
        } else if runStates[target]?.preparing == true {
            // The worktree is still being made; the turn just won't start.
            runStates[target] = nil
            append(ChatMessage(role: .note, text: "Stopped"), to: target)
            saveThread(target)
        }
    }

    func stopAll() {
        for run in runs.values { run.stop() }
        for run in petRuns.values { run.stop() }
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
            try Workspace.prepare(bot: bot, sharedMemoryPath: settings.sharedMemoryPath, repositoriesPath: settings.expandedReposRoot)
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

    private func saveThread(_ target: ChatTarget) {
        guard let bot = bot(target.botID) else { return }
        let home = BotHome(workspace: bot.workspace)
        if let taskID = target.taskID {
            guard task(taskID, of: bot.id) != nil else { return }
            try? home.saveThread(thread(target), task: taskID)
        } else {
            try? home.saveThread(thread(target))
        }
    }

    /// The last few meaningful lines of a CLI's stderr, for an error message.
    static func lastLines(_ text: String, count: Int = 8) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(count).joined(separator: "\n")
    }
}
