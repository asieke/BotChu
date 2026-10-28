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
    /// What to tell the bot, written already (a task over many issues or pull requests).
    var brief = ""
}

/// The repository the Projects sidebar shows, the tab it shows, and the issue or pull request
/// opened there.
struct ProjectSelection: Equatable {
    enum Tab: String, CaseIterable { case overview, issues, pulls }
    var repo: String
    var tab = Tab.overview
    /// The number of the issue (Issues) or pull request (PRs) opened in the tab.
    var item: Int?
}

/// A Markdown file open in the in-app editor: one of a bot's (`BotDocument`) or one every bot
/// shares (`SharedDocument`, from Settings).
struct DocumentEditorRequest: Identifiable {
    let id = UUID()
    let name: String
    /// Whose file it is, beside its name: the bot's, or "Every bot" for one they share.
    let owner: String
    let url: URL
    let seed: String
    /// Shown over an empty draft, in a few words.
    let placeholder: String
    /// The conversation shown when one of a bot's own files was opened, which Save & Start New
    /// Session starts over (#232); nil for the files every bot shares, and skills.
    var conversation: ChatTarget?

    init(bot: Bot, document: BotDocument, conversation: ChatTarget? = nil) {
        name = document.rawValue
        owner = bot.name
        url = document.url(for: bot)
        seed = document.seed(for: bot)
        placeholder = switch document {
        case .instructions: "Role and job in Markdown…"
        case .memory: "Durable facts and preferences…"
        case .soul: ""
        }
        self.conversation = conversation.flatMap { $0.botID == bot.id ? $0 : nil }
    }

    init(shared document: SharedDocument, botsRoot: String) {
        name = document.rawValue
        owner = "Every bot"
        url = document.url(botsRoot: botsRoot)
        seed = document.seed
        placeholder = switch document {
        case .team: "Team process in Markdown…"
        case .memory: "Shared facts and preferences…"
        }
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

enum SkillsTab: String { case skills, tools }

enum LibraryDestination: String, CaseIterable {
    case inbox, projects, agents, providers, skills, jobs, settings
    var title: String { self == .skills ? "Skills & Tools" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .projects: "square.grid.2x2"; case .agents: "person.2"; case .providers: "terminal"; case .skills: "wand.and.stars"
        case .jobs: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
    /// The sidebar's Workspace rows; Settings is its gear, below the bots (#191).
    static let sidebar: [LibraryDestination] = allCases.filter { $0 != .settings }
}

@MainActor @Observable
final class AppModel {
    var bots: [Bot] = [] { didSet { try? delegation?.refreshRoster() } }
    /// The section each bot is in, by bot (`BotSections`); `bots` is in sidebar order, with the
    /// bots in no section first. See `SidebarSections.swift`.
    var sections: [UUID: String] = [:]
    var delegation: SubagentRuntime!
    /// Messages from Telegram, into bots' Homes, and their replies back (Settings ▸ Telegram).
    var telegram: TelegramBridge!
    var remoteQueue: RemoteQueueBridge!
    /// The bots' scheduled jobs, run while BotChu is open (Jobs).
    var jobs: JobRuntime!
    /// What the bots deliver to the owner with `botchu-inbox send` (Inbox).
    var inbox: InboxModel!
    /// The Inbox's banners and Dock badge; their system only in BotChu.app.
    var notifier: InboxNotifier?
    /// Each bot's tasks, open and closed, oldest first.
    var tasks: [UUID: [BotTask]] = [:]
    /// Every conversation (each bot's Home, and each task), observed one by one: see
    /// `ConversationState`. Made when first asked for (`conversation(_:)`).
    @ObservationIgnored private(set) var conversations: [ChatTarget: ConversationState] = [:]
    /// Turns in progress, by conversation.
    var runStates: ConversationField<RunState> { ConversationField(model: self, field: \.run) }
    /// Nil shows the remembered conversation; galleries never discard that conversation.
    var destination: LibraryDestination? {
        // A folder chosen for Providers' Connectors lasts while Providers shows.
        didSet { if destination != .providers { providerConnectorWorkspace = nil } }
    }
    var visibleBotID: UUID? { destination == nil ? selection : nil }
    var selection: UUID? {
        didSet {
            guard let selection, selection != oldValue else { return }
            hydrate(tab(of: selection))
            guard destination == nil else { return }
            react(.greeting, for: tab(of: selection), seconds: 5)
            unread.remove(tab(of: selection))
            inbox?.conversationShown(tab(of: selection))
        }
    }
    /// The task tab shown for each bot; none shows its Home.
    var openTask: [UUID: UUID] = [:]
    /// Conversations whose turn ended while they weren't shown.
    var unread: Set<ChatTarget> = []
    /// What is typed in each conversation's message box and not sent yet.
    var drafts: [ChatTarget: String] = [:]
    /// The agents and projects chosen in each draft from `@` and `#` completion (`Mentions.swift`).
    var draftReferences: [ChatTarget: [MessageReference]] = [:]
    var draftImages: [ChatTarget: [ImageAttachment]] = [:]
    /// Documents in a remote queue bot's draft (`addFiles`).
    var draftFiles: [ChatTarget: [FileAttachment]] = [:]
    var attachmentErrors: [ChatTarget: String] = [:]
    /// How many notes each bot asked to remember that BotChu couldn't save yet (`MemoryWriter`).
    var unsavedMemory: [UUID: Int] = [:]
    /// What became of the notes each conversation asked to remember, for its next turn.
    @ObservationIgnored private var memoryReports: [ChatTarget: [String]] = [:]
    /// Daily reviews of each bot's work (`Evaluations.swift`), the records the status sidebar
    /// shows, by id, and the work waiting for each bot's next review.
    @ObservationIgnored var evaluator: RunEvaluator!
    var evaluationRecords: [String: EvaluationRecord] = [:]
    var reviewStates: [UUID: ReviewState] = [:]
    /// The kind of review failure each bot's Home was last told about, so a repeat isn't.
    @ObservationIgnored var noticedEvaluationFailures: [UUID: EvaluationFailure.Kind] = [:]
    /// Unsent follow-ups and short pet reactions belong to one conversation, not the whole bot.
    var messageQueues: ConversationField<MessageQueue> { ConversationField(model: self, field: \.queue) }
    var reactions: ConversationField<BotActivity> { ConversationField(model: self, field: \.reaction) }
    @ObservationIgnored private var reactionTickets: [ChatTarget: UUID] = [:]
    /// Pets, by bot; a bot without one shows its emoji (see `Pets.swift`).
    var pets: [UUID: PetVideoPackage] = [:]
    var petJobs: [UUID: PetJob] = [:]
    @ObservationIgnored var petRuns: [UUID: AgentRun] = [:]
    @ObservationIgnored var petTasks: [UUID: Task<Void, Never>] = [:]
    /// New tasks waiting for their issue's title before their summary is asked for, and the
    /// summaries asked for, one at a time (#192, `TaskSummaries.swift`).
    @ObservationIgnored var summariesWanted: Set<UUID> = []
    @ObservationIgnored var summaryRuns: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var lastSummaryRun: Task<Void, Never>?
    /// Runs a summary; nil runs it on this Mac (`EvaluationCLI`). Tests set it.
    @ObservationIgnored var summaryRunner: RunEvaluator.Runner?
    /// Tasks' titles being made again from their conversations, the task Rename… asks a title for
    /// and what is typed for it, and why a title couldn't be made again (#236, `TaskSummaries.swift`).
    var titleRequests = TaskTitleRequests()
    @ObservationIgnored var titleRuns: [UUID: Task<Void, Never>] = [:]
    var renamingTask: ChatTarget?
    var renamingText = ""
    var titleNotice: TaskTitleNotice?
    var editor: EditorRequest?
    var taskSheet: TaskSheetRequest?
    /// The repository selected in Projects, shown in its sidebar; nil hides the sidebar.
    var projectSelection: ProjectSelection?
    /// The profile selected in Providers, by account id, shown in its sidebar; nil hides the sidebar.
    var providerSelection: String?
    /// Skills & Tools' tab (#246), and what each tab has selected, shown in its sidebar: a skill by
    /// its id, a tool by its row's id (`ToolRow`).
    var skillsTab = SkillsTab.skills
    var skillSelection: String?
    var toolSelection: String?
    /// Add Tools is open.
    var addingTools = false
    /// The folder (and host) Providers checks the selected profile's connectors in, as a
    /// conversation's Manage or its menu chose; nil is the profile's default (`connectorWorkspace(for:)`).
    var providerConnectorWorkspace: ConnectorWorkspace?
    /// What opens a provider's settings and a Terminal handoff; tests record them instead.
    @ObservationIgnored var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var openTerminal: (ConnectorHandoffRequest) -> Bool = AppModel.openInTerminal
    var documentEditor: DocumentEditorRequest?
    /// Report a Bug or Feature, what files its issues: gh, or a stand-in (`DevHooks`, tests), what
    /// takes its window's screenshot, and whether one is being taken, before the sheet opens.
    var issueReport: IssueReportRequest?
    @ObservationIgnored var issueFiler = DevHooks.issueFiler
    @ObservationIgnored var windowCapture = DevHooks.windowCapture
    var openingReport = false
    /// New Issue (#245): the sheet, the issues being written up and filed in the background, what
    /// writes them (nil: the CLI on this Mac; tests set it) and what files them (gh, or a stand-in).
    var newIssue: NewIssueRequest?
    var issueFilings: [IssueFiling] = []
    @ObservationIgnored var issueRunner: RunEvaluator.Runner?
    @ObservationIgnored var issueCreate: IssueDraft.Create = DevHooks.issueCreate
    let settings: AppSettings
    /// Every profile's allowance, saved between launches (`usage.json`).
    let usage: UsageCache
    /// What Providers and a conversation's Model & Usage show of it, kept current in the background
    /// in the app itself, so both open on numbers instead of checking.
    let usageBoard = ProviderUsageBoard()
    /// The connectors each conversation's CLI reported or a check found (#183), its checks saved
    /// between launches (`connectors.json`, #212).
    let connectorBoard: ConnectorBoard
    /// Skills & Tools' tool policy, where tools are and their checks (#246), in `tools.json`.
    let tools: ToolsBoard
    @ObservationIgnored private var usageWatch: Task<Void, Never>?
    /// Usage views inject this lookup in tests so they never read the owner's Keychain.
    let openRouterKey: @MainActor () -> String?
    /// The Sail key as Settings ▸ Sail shows it; tests replace it, so they never read the Keychain.
    @ObservationIgnored var sailKey: @MainActor () -> String? = { Keychain.get(Keychain.sailAccount) }
    let modelCatalog = ModelCatalog()

    private let store: Store
    /// BotChu's data folder (`~/Library/Application Support/BotChu`, or a test's).
    var dataFolder: URL { store.root }
    /// Where conversations, settings, logs, memory, sub-agents' and jobs' files are written, off the
    /// main thread, each target in order (`StorageQueue`, #107).
    let storage: StorageQueue
    let sessionPreparation: SessionPreparation
    /// How long moving or deleting a bot, a launch, and quitting wait for what is still being saved
    /// there. What quitting couldn't save by then is listed in `unsavedAtQuit` and the system log,
    /// never taken as saved.
    nonisolated static let saveTimeout: TimeInterval = 5
    @ObservationIgnored var quitTimeout = AppModel.saveTimeout
    @ObservationIgnored private(set) var unsavedAtQuit: [String] = []
    /// Index entries whose folders don't hold their bot right now; kept so the bot returns with it.
    @ObservationIgnored var missing: [Store.Entry] = []
    /// Why `index.json` couldn't be saved; nil while it is saved. Until a save works (Try Again in
    /// the sidebar, the next change, or quitting), the sidebar's bots, order and sections since are
    /// only here.
    private(set) var indexFailure: SaveFailure?
    @ObservationIgnored private var delegationSessions: [ChatTarget: Set<String>] = [:]
    /// What each session was told about tools and SSH destinations (#246), "" for nothing, so a
    /// resumed one hears again only when that changed.
    @ObservationIgnored private var toolSessions: [ChatTarget: [String: String]] = [:]
    @ObservationIgnored private var contextSessions: [ChatTarget: [String: UUID]] = [:]
    @ObservationIgnored private var runs: [ChatTarget: AgentRun] = [:]
    /// The heartbeat each conversation waits to send (`Heartbeats.swift`), dropped by any message to it.
    @ObservationIgnored var pendingHeartbeats: [ChatTarget: PendingHeartbeat] = [:]
    /// What each running CLI that takes input mid-turn has been given and has taken back.
    @ObservationIgnored private var inputs: [ChatTarget: (kind: AgentKind, ledger: InputLedger)] = [:]
    /// BotChu is quitting: the turns it stops weren't stopped by the owner, so queues stay unpaused.
    @ObservationIgnored private(set) var terminating = false
    /// While any turn runs, BotChu looks for the tasks bots ask for (`.botchu/dispatch/`), whichever
    /// conversation wrote them (#111).
    @ObservationIgnored private var dispatchTimer: Timer?
    /// Who waits to hear that a task's first turn started (nil) or why it couldn't (#111).
    @ObservationIgnored private var startWatchers: [ChatTarget: [(String?) -> Void]] = [:]
    /// Bots whose dispatch requests are being started.
    @ObservationIgnored private var dispatching: Set<UUID> = []
    /// Worktrees being made, by task: one at a time, so a message sent meanwhile waits for it.
    @ObservationIgnored private var makings: [ChatTarget: Task<TaskWorktree.Failure?, Never>] = [:]
    /// The turn waiting for its task's worktree, by task; Stop withdraws it.
    @ObservationIgnored private var waiting: [ChatTarget: UUID] = [:]
    /// The last git work queued in each checkout: worktrees are made one at a time per repository,
    /// since git locks its refs and config.
    @ObservationIgnored private var checkoutWork: [String: Task<Void, Never>] = [:]
    /// The owner's GitHub repositories, which tasks start from, as saved or synced (`Projects.swift`).
    var repositories: [GitHubLookup.Repo]?
    /// Why the last sync of the Projects catalog failed.
    var repositoriesError: String?
    var projectRecords: [String: ProjectRecord] = [:]
    var projectErrors: [String: String] = [:]
    /// A sync of the Projects catalog is under way.
    var projectsLoading = false
    /// The open pull requests and issues across the repositories, as saved or synced.
    var openItems: [GitHubLookup.OpenItem]?
    var openItemsError: String?
    /// The GitHub account the Projects catalog belongs to, and when it was last synced.
    var projectsLogin: String?
    var repositoriesReadAt: Date?
    /// Keeps the Projects catalog on disk and in step with GitHub.
    let projectSync: ProjectSync
    let openWorkLookup: @Sendable ([String]) async -> Result<GitHubLookup.OpenWork, TaskWorktree.Failure>
    /// An issue or pull request (repository, number, whether a pull request) as the Projects sidebar
    /// shows it, and the ones read so far, by `owner/name#number`.
    let workDetailLookup: @Sendable (String, Int, Bool) async -> Result<GitHubLookup.WorkDetail, TaskWorktree.Failure>
    @ObservationIgnored var workDetails: [String: GitHubLookup.WorkDetail] = [:]
    /// An issue or pull request (repository, number, whether a pull request) as a task starts on it,
    /// with a pull request's head branch.
    let workLookup: @Sendable (String, Int, Bool) async -> Result<GitHubLookup.Found, TaskWorktree.Failure>
    /// The issue the owner chose to delete in Projects, until they confirm it, and then why GitHub
    /// didn't delete it; the issues being deleted, by `owner/name#number` (`Projects.swift`).
    var issueDeletion: IssueDeletion?
    var issueClosure: IssueClosure?
    @ObservationIgnored var closureFailures: [IssueClosure] = []
    var updatingIssues: Set<String> = []
    var githubConnection: ProjectGitHub.Connection?
    var githubChecking = false
    let projectGitHub: ProjectGitHub

    init(store: Store? = nil, settings: AppSettings? = nil, usage: UsageCache? = nil,
         openRouterKey: @escaping @MainActor () -> String? = { Keychain.get(Keychain.openRouterAccount) },
         projectGitHub: ProjectGitHub = ProjectGitHub(),
         openWorkLookup: @escaping @Sendable ([String]) async -> Result<GitHubLookup.OpenWork, TaskWorktree.Failure> = { await GitHubLookup.openWork(repos: $0) },
         workDetailLookup: @escaping @Sendable (String, Int, Bool) async -> Result<GitHubLookup.WorkDetail, TaskWorktree.Failure> = {
             await GitHubLookup.detail(number: $1, pullRequest: $2, repo: $0)
         }, workLookup: @escaping @Sendable (String, Int, Bool) async -> Result<GitHubLookup.Found, TaskWorktree.Failure> = {
             await GitHubLookup.work(number: $1, pullRequest: $2, repo: $0)
         }, evaluationRunner: RunEvaluator.Runner? = nil, storage: StorageQueue = .shared) {
        self.storage = storage
        self.sessionPreparation = SessionPreparation(storage: storage)
        // Files still being written by this process (a model made before, in tests) are read once written.
        storage.wait(timeout: Self.saveTimeout)
        self.projectGitHub = projectGitHub
        self.openWorkLookup = openWorkLookup
        self.workDetailLookup = workDetailLookup
        self.workLookup = workLookup
        DevHooks.configure()
        self.store = store ?? DevHooks.dataDir.map { Store(root: $0) } ?? .applicationSupport
        projectSync = ProjectSync(file: self.store.root.appendingPathComponent("projects.json"), client: ProjectSync.Client(
            gh: { await projectGitHub.gh($0) }, record: { try await projectGitHub.record(repo: $0) }, openWork: openWorkLookup))
        self.settings = settings ?? AppSettings()
        self.usage = usage ?? UsageCache(fetch: DevHooks.usageFetch ?? { try await ProviderUsageClient.read($0, openRouterKey: $1) },
                                         file: self.store.root.appendingPathComponent("usage.json"))
        self.openRouterKey = openRouterKey
        connectorBoard = ConnectorBoard(file: self.store.root.appendingPathComponent("connectors.json"))
        tools = ToolsBoard(folder: self.store.root)
        self.store.migrateIfNeeded()
        let loaded = self.store.loadBots()
        bots = loaded.bots
        missing = loaded.missing
        sections = loaded.sections
        arrange(botSections, save: false)
        connectorBoard.profiles = { [weak self] in self?.connectorProfiles }
        connectorBoard.prune()
        // Lists Codex profiles' models (#220): only the real app, or a review copy with sample lists, checks by itself.
        configureModelCatalogs(file: self.store.root.appendingPathComponent("model-catalogs.json"), live: store == nil && DevHooks.dataDir == nil)
        // Only the bots' and tasks' settings are read here; conversations are read when they are
        // needed (#109). A Home's or open task's queue with something in its files is recovered off
        // the main thread, with its transcript only when messages wait in it; the others have nothing
        // to recover, and their digests are read from their indexes. The shown conversation is read first.
        for bot in bots {
            tasks[bot.id] = BotHome(workspace: bot.persistencePath).loadTasks()
            reloadPet(bot.id)
        }
        let shown = bots.first.map { ChatTarget.home($0.id) }
        for bot in bots {
            let home = BotHome(workspace: bot.persistencePath)
            for target in [ChatTarget.home(bot.id)] + openTasks(of: bot.id).map({ .task($0.id, of: bot.id) }) {
                if target == shown || home.hasQueueFiles(task: target.taskID) {
                    recover(target, load: target == shown)
                } else {
                    conversation(target).history = .clean
                    readDigest(target)
                }
            }
        }
        // Reviews spend the accounts' allowance: only the real app runs them by itself.
        evaluator = makeEvaluator(runner: store == nil && DevHooks.dataDir == nil ? evaluationRunner ?? liveEvaluationRunner() : evaluationRunner)
        // Usage checks run the profiles' CLIs: only the real app, or a review copy with sample usage, checks by itself.
        if store == nil && (DevHooks.dataDir == nil || DevHooks.usageFetch != nil) {
            usageWatch = Task { [weak self] in
                while !Task.isCancelled {
                    self?.refreshUsageInBackground()
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                }
            }
        }
        delegation = SubagentRuntime(model: self, root: (store != nil || DevHooks.dataDir != nil)
            ? self.store.root.appendingPathComponent("subagents") : SubagentIPC.defaultRoot, archive: SubagentArchive(storage: storage))
        remoteQueue = RemoteQueueBridge(model: self)
        telegram = TelegramBridge(model: self, stateURL: self.store.root.appendingPathComponent("telegram.json"))
        jobs = JobRuntime(model: self, runs: DevHooks.runsJobs)
        inbox = InboxModel(model: self, root: self.store.root, storage: storage)
        inbox.load(bots: bots)
        notifier = InboxNotifier(model: self, system: store == nil ? LiveBannerSystem.make() : nil)
        selection = bots.first?.id
        showSavedProjects()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
        // Requests left while BotChu wasn't running.
        for bot in bots where !bot.isRemoteQueue { takeDispatches(for: bot.id) }
        evaluator.load(bots: bots.filter { !$0.isRemoteQueue }.map { ($0.id, $0.workspace) })
        evaluationRecords = evaluator.records
        reviewStates = evaluator.states
        // Follow-ups left queued when BotChu quit go out on their own, unless Stop or a failure
        // paused them, once their own conversation is recovered (`recovered`), after the window is up.
    }

    /// A profile's usage request, the one Providers, the background checks and a conversation's
    /// Model & Usage share, so they show one reading.
    func usageRequest(for account: Account) -> UsageRequest {
        UsageRequest(account: account, command: settings.command(for: account), openRouterKeyRevision: settings.usageCredentialRevision)
    }

    /// Every profile's usage request.
    var usageRequests: [UsageRequest] { settings.accounts.map(usageRequest) }

    /// Checks each profile whose reading is older than its background interval, each on its own,
    /// so a slow CLI holds up no other.
    private func refreshUsageInBackground() {
        for request in usageRequests {
            Task { await usageBoard.refresh(request, usage: usage, openRouterKey: openRouterKey, for: .background) }
        }
    }

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }
    func task(_ id: UUID, of botID: UUID) -> BotTask? { tasks[botID]?.first { $0.id == id } }
    func task(_ target: ChatTarget) -> BotTask? { target.taskID.flatMap { task($0, of: target.botID) } }
    func openTasks(of botID: UUID) -> [BotTask] { tasks[botID, default: []].open }
    /// The closed tasks to open again from Home's status; a job's run whose history keeps it is
    /// found there instead (#146).
    func closedTasks(of botID: UUID) -> [BotTask] {
        let jobs = jobs?.jobs(of: botID) ?? []
        return tasks[botID, default: []].filter { $0.isArchived && !JobTasks.inHistory($0, jobs: jobs) }
    }

    /// The conversation's live state, made when first asked for.
    func conversation(_ target: ChatTarget) -> ConversationState {
        if let existing = conversations[target] { return existing }
        let made = ConversationState()
        conversations[target] = made
        return made
    }

    func thread(_ target: ChatTarget) -> [ChatMessage] { conversation(target).messages }
    /// Whether the conversation is the one in the window now.
    func isShown(_ target: ChatTarget) -> Bool { visibleBotID == target.botID && tab(of: target.botID) == target }
    func isRunning(_ target: ChatTarget) -> Bool { (target.taskID == nil && remoteQueue?.isWorking(target.botID) == true) || runStates[target] != nil || (delegation?.activeCount(target) ?? 0) > 0 }
    /// Whether any of the bot's conversations has a turn under way. Reading its Home's and its
    /// tasks' turns by name observes them, also a task's that is made later.
    func isBusy(_ botID: UUID) -> Bool {
        let known = [ChatTarget.home(botID)] + tasks[botID, default: []].map { .task($0.id, of: botID) }
        return known.contains { runStates[$0] != nil }
            || conversations.contains { $0.key.botID == botID && $0.value.run != nil }
            || delegation.usesBot(botID)
            || jobs?.isRunning(botID: botID) == true
    }

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
        inbox?.conversationShown(target)
        if selection != target.botID { selection = target.botID }
        hydrate(target)
    }

    /// Shows the tab `offset` places after the shown one (before, when negative), wrapping around.
    func showTab(offset: Int, of botID: UUID) {
        let tabs = [ChatTarget.home(botID)] + openTasks(of: botID).map { .task($0.id, of: botID) }
        guard let index = tabs.firstIndex(of: tab(of: botID)), tabs.count > 1 else { return }
        show(tabs[(index + offset % tabs.count + tabs.count) % tabs.count])
    }

    /// One conversation's status, from its thread's summary: it costs the same however long the
    /// thread, and a view showing it isn't redrawn while a reply's text streams in.
    func status(of target: ChatTarget) -> BotStatus? {
        let conversation = conversation(target)
        if let task = task(target) {
            return BotStatus.make(settings: task, summary: conversation.summary, run: conversation.run, reaction: conversation.reaction)
        }
        guard target.taskID == nil, let bot = bot(target.botID) else { return nil }
        return BotStatus.make(settings: bot, summary: conversation.summary, run: conversation.run, reaction: conversation.reaction)
    }

    /// The bot as a whole, for its list row only. Profile cards always use status(of: ChatTarget).
    func status(of bot: Bot) -> BotStatus {
        let conversation = conversation(.home(bot.id))
        let home = BotStatus.make(settings: bot, summary: conversation.summary, run: conversation.run, reaction: conversation.reaction)
        let working = openTasks(of: bot.id).compactMap { task in runStates[.task(task.id, of: bot.id)].map { (title: task.title, run: $0) } }
        return home.working(on: working)
    }

    // MARK: Bots

    /// Opens New Bot, as an agent or a specialist (#250).
    func newBot(role: Bot.Role = .agent) {
        let bot = Bot(name: "", workspace: "", role: role)
        editor = EditorRequest(bot: bot, isNew: true)
    }

    /// The bots that can own tasks and scheduled jobs (#250): what every agent picker for a task or a
    /// job lists, in sidebar order. Specialists and the remote queue bot are left out.
    var taskOwners: [Bot] { bots.filter(\.canOwnTasks) }

    /// The jobs that saving the bot as a specialist would pause (#250), for the confirmation before
    /// it; none when it is one already, or a remote queue bot.
    func jobsPausedBySpecialistSwitch(of botID: UUID) -> [Job] {
        guard let bot = bot(botID), bot.canOwnTasks else { return [] }
        return jobs?.pausedBySpecialistSwitch(of: botID) ?? []
    }

    func edit(_ id: UUID) {
        guard let bot = bot(id) else { return }
        editor = EditorRequest(bot: bot, isNew: false)
    }

    func editDocument(_ document: BotDocument, for id: UUID) {
        guard let bot = bot(id), !bot.isRemoteQueue else { return }
        // The conversation shown, which Save & Start New Session can start over; none for a bot not shown.
        documentEditor = DocumentEditorRequest(bot: bot, document: document, conversation: visibleBotID == id ? tab(of: id) : nil)
    }

    /// Whether Save & Start New Session is offered for a file of the conversation's bot (#232), and
    /// whether that conversation is idle enough for it now.
    func sessionRestart(of target: ChatTarget?) -> DocumentSessionRestart {
        guard let target, let bot = bot(target.botID), let settings = runSettings(of: target) else { return .unavailable }
        return DocumentSessionRestart(selected: visibleBotID == target.botID && tab(of: target.botID) == target,
                                      local: !bot.isRemoteQueue && task(target)?.isRemote != true,
                                      hasSession: settings.resumableSessionID != nil, running: isRunning(target))
    }

    /// Opens a file every bot shares, in the bots folder, as Settings does.
    func editSharedDocument(_ document: SharedDocument) {
        documentEditor = DocumentEditorRequest(shared: document, botsRoot: settings.botsRoot)
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
        if bot.isRemoteQueue {
            guard !bots.contains(where: \.isRemoteQueue) else { return }
            bot.workspace = ""
            bot.accountID = ""
            bot.model = ""
            bot.remoteStorage = store.root.appendingPathComponent("remote-bots/\(bot.id.uuidString.lowercased())").path
        } else if bot.workspace.trimmingCharacters(in: .whitespaces).isEmpty { bot.workspace = defaultWorkspace(for: bot.name) }
        bot.workspace = (bot.workspace as NSString).expandingTildeInPath
        if bot.emoji.isEmpty { bot.emoji = "🤖" }
        // In no section: last among the bots in none, above the sections.
        var layout = botSections
        layout.add(bot.id)
        bots.insert(bot, at: layout.order.firstIndex(of: bot.id) ?? bots.endIndex)
        conversation(.home(bot.id)).start()
        tasks[bot.id] = []
        save(bot)
        destination = nil
        selection = bot.id
        if bot.isRemoteQueue { remoteQueue.reloadBot(); return }
        prepareWorkspace(bot)
        send(BotContext.introPrompt, to: .home(bot.id), visible: false)
    }

    func update(_ edited: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == edited.id }) else { return }
        var bot = edited
        if bots[i].isRemoteQueue {
            bot.kind = .remoteQueue; bot.workspace = ""; bot.remoteStorage = bots[i].remoteStorage
            bots[i] = bot; save(bot); return
        }
        bot.workspace = (bot.workspace as NSString).expandingTildeInPath
        if bot.emoji.isEmpty { bot.emoji = "🤖" }
        if let problem = workspaceProblem(bot.workspace, for: bot.id) {
            append(ChatMessage(role: .error, text: problem), to: .home(bot.id))
            return
        }
        if bot.workspace != bots[i].workspace {
            // The bot's history, logs, tasks and memory move with it, once what is being saved
            // there is written, so nothing makes the old folder again.
            let old = BotHome(workspace: bots[i].workspace)
            guard storage.wait(under: bots[i].workspace, timeout: Self.saveTimeout).isEmpty else {
                append(ChatMessage(role: .error, text: "Couldn't move this bot's history to \(bot.workspace): its files are still being saved. Try again."), to: .home(bot.id))
                return
            }
            do {
                try old.move(toWorkspace: bot.workspace)
            } catch {
                append(ChatMessage(role: .error, text: "Couldn't move this bot's history to \(bot.workspace): \(error.localizedDescription)"), to: .home(bot.id))
                return
            }
        }
        let moved = bot.workspace != bots[i].workspace
        let roleChanged = bot.isSpecialist != bots[i].isSpecialist
        // The editor doesn't change what a turn reported while it was open.
        bot.reportedModel = bots[i].reportedModel
        bots[i] = bot
        save(bot)
        // Its AGENTS.md says whether it runs tasks, so it is written again with the role.
        prepareWorkspace(bot)
        // A specialist's jobs pause, and an agent's that paused for it resume; its open tasks go on (#250).
        if roleChanged { jobs?.roleChanged(bot.id, toSpecialist: bot.isSpecialist) }
        if moved {
            reloadPet(bot.id)
            // Its jobs' runs work in its workspace, wherever it is now (#146).
            for task in tasks[bot.id, default: []] where task.jobRun != nil {
                guard let t = taskIndex(.task(task.id, of: bot.id)) else { continue }
                tasks[bot.id]?[t].folder = bot.workspace
                tasks[bot.id]?[t].checkout = bot.workspace
                saveTask(tasks[bot.id]![t], of: bot.id)
            }
        }
    }

    func setModel(_ selected: String, for target: ChatTarget) {
        guard !isRunning(target) else { return }
        let catalog = runSettings(of: target).flatMap(nativeModels(for:))
        change(target) { $0.selectModel(selected, catalog: catalog) }
    }

    func setReasoningEffort(_ effort: ReasoningEffort?, for target: ChatTarget) {
        guard !isRunning(target), let current = runSettings(of: target) else { return }
        let effective = GenerationOptions.effectiveModel(current.model, kind: current.account.kind, openRouterDefault: settings.openRouterModel)
        if let effort, !GenerationOptions.efforts(for: current.account.kind, model: effective, catalog: nativeModels(for: current)).contains(effort) { return }
        change(target) { $0.reasoningEffort = effort }
    }

    /// Turns Codex's Fast tier on or off for this conversation's next turns (#249).
    func setFastMode(_ on: Bool, for target: ChatTarget) {
        guard !isRunning(target), let current = runSettings(of: target) else { return }
        if on, !GenerationOptions.offersFast(for: current.account.kind, model: current.model, catalog: nativeModels(for: current)) { return }
        change(target) { $0.fastMode = on ? true : nil }
    }

    /// Changes this Home or task conversation's account; its next message starts a session there.
    func setAccount(_ accountID: String, for target: ChatTarget) {
        guard !isRunning(target) else { return }
        let account = settings.account(accountID)
        change(target) { $0.selectAccount(account) }
    }

    /// A bot's own account, model and effort, changed in place from the Agents table (#250) and saved,
    /// as Edit Bot changes them: also while a turn runs, which goes on as it started, so the change
    /// applies from its next turn. A new account of another kind resets the model and effort, a model
    /// drops an effort it doesn't take, and an effort the model doesn't take is ignored (`RunSettings`).
    func setAccount(_ accountID: String, ofBot botID: UUID) {
        let account = settings.account(accountID)
        editRunSettings(of: botID) { $0.selectAccount(account) }
    }

    func setModel(_ selected: String, ofBot botID: UUID) {
        guard let bot = bot(botID) else { return }
        let catalog = nativeModels(for: bot)
        editRunSettings(of: botID) { $0.selectModel(selected, catalog: catalog) }
    }

    func setReasoningEffort(_ effort: ReasoningEffort?, ofBot botID: UUID) {
        guard let bot = bot(botID) else { return }
        let effective = GenerationOptions.effectiveModel(bot.model, kind: bot.account.kind, openRouterDefault: settings.openRouterModel)
        if let effort, !GenerationOptions.efforts(for: bot.account.kind, model: effective, catalog: nativeModels(for: bot)).contains(effort) { return }
        editRunSettings(of: botID) { $0.reasoningEffort = effort }
    }

    private func editRunSettings(of botID: UUID, _ edit: (inout Bot) -> Void) {
        guard let i = bots.firstIndex(where: { $0.id == botID }), !bots[i].isRemoteQueue else { return }
        var bot = bots[i]
        edit(&bot)
        guard bot != bots[i] else { return }
        bots[i] = bot
        saveSettings(bot)
    }

    func delete(_ id: UUID) {
        sessionPreparation.retire(id)
        delegation.stopBot(id)
        jobs.removeBot(id)
        inbox.forget(bot: id)
        for (target, run) in runs where target.botID == id { run.stop() }
        petRuns[id]?.stop()
        petTasks.removeValue(forKey: id)?.cancel()
        if let bot = bot(id) {
            // What waits to be saved in its folder (its memory too) is dropped, and what is being
            // written finishes first, so nothing makes the folder again once it is in the Trash.
            storage.retire(bot.persistencePath, timeout: Self.saveTimeout)
            BotHome(workspace: bot.persistencePath).trash()
            storage.reopen(bot.persistencePath)
        }
        bots.removeAll { $0.id == id }
        remoteQueue?.reloadBot()
        sections[id] = nil
        tasks[id] = nil
        // Its threads, turns, queues and reactions, and how its chats were shown; what waited for
        // its history hears that it went, and a read under way finds it gone.
        for (target, conversation) in conversations where target.botID == id {
            historyBudget.remove(target)
            let waited = conversation.waiting
            conversation.waiting = []
            for waiting in waited { waiting.cancel?() }
        }
        conversations = conversations.filter { $0.key.botID != id }
        TranscriptCache.forget(bot: id)
        waiting = waiting.filter { $0.key.botID != id }
        unread = unread.filter { $0.botID != id }
        drafts = drafts.filter { $0.key.botID != id }
        draftReferences = draftReferences.filter { $0.key.botID != id }
        draftImages = draftImages.filter { $0.key.botID != id }
        draftFiles = draftFiles.filter { $0.key.botID != id }
        attachmentErrors = attachmentErrors.filter { $0.key.botID != id }
        openTask[id] = nil
        pets[id] = nil
        petJobs[id] = nil
        reactionTickets = reactionTickets.filter { $0.key.botID != id }
        saveIndex()
        if selection == id { selection = bots.first?.id }
    }

    /// Starts the conversation's next turn in a fresh CLI session (with the identity, memory and recap again).
    func newSession(_ target: ChatTarget) {
        guard bot(target.botID)?.isRemoteQueue != true, !isRunning(target), runSettings(of: target) != nil else { return }
        change(target) {
            $0.sessionID = nil
            $0.sessionAccountID = nil
        }
        append(ChatMessage(role: .note, text: "New session"), to: target)
        saveThread(target)
    }

    func revealWorkspace(_ id: UUID) {
        guard let bot = bot(id), !bot.isRemoteQueue else { return }
        prepareWorkspace(bot) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bot.workspace)])
        }
    }

    /// Opens the bot's `.botchu` folder (its settings, thread, tasks and logs) in Finder.
    func revealHistory(_ id: UUID) {
        guard let bot = bot(id) else { return }
        let home = BotHome(workspace: bot.persistencePath)
        try? FileManager.default.createDirectory(at: home.logsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(home.url)
    }

    // MARK: Tasks

    func newTask(for botID: UUID, repo: String? = nil, work: BotTask.Work? = nil, purpose: NewTaskSheet.Purpose = .work, brief: String = "") {
        guard let bot = bot(botID), bot.canOwnTasks else { return }
        taskSheet = TaskSheetRequest(botID: botID, repo: repo, work: work, purpose: work?.isPullRequest == true ? purpose : .work, brief: brief)
    }

    /// Records a task, opens its tab (when `show`), says so in its bot's Home, then makes its
    /// worktree and sends its first message, with `images` (already in the bot's folder) and the
    /// brief's mentions, `references`. `saved` hears whether its record was saved, with the error
    /// when it wasn't.
    func startTask(_ task: BotTask, for botID: UUID, show: Bool, images: [ImageAttachment] = [], references: [MessageReference] = [],
                   saved: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        guard let bot = bot(botID), bot.canOwnTasks else {
            saved?(CocoaError(.fileNoSuchFile))
            return
        }
        let target = ChatTarget.task(task.id, of: botID)
        tasks[botID, default: []].append(task)
        conversation(target).start()
        saveTask(task, of: botID, saved: saved)
        postReceipt(TaskReceipt.started(task), task: task.id, for: botID)
        if show { self.show(target) }
        send(task.opening, to: target, images: images, references: references)
        summarizeNewTask(target)
    }

    /// Records a scheduled job's run as a new task of its agent (#146), whose conversation the job's
    /// runtime writes the run into: Home gets no receipt of it (only the job's, for a finding or a
    /// failure), and nothing is sent. The job's earlier runs' tasks close, so the job keeps one open
    /// task beside the chat, unless the owner took one over or it is busy or shown.
    func startJobTask(_ task: BotTask, for botID: UUID) -> ChatTarget? {
        guard let bot = bot(botID), bot.canOwnTasks, task.jobRun != nil else { return nil }
        let target = ChatTarget.task(task.id, of: botID)
        tasks[botID, default: []].append(task)
        conversation(target).start()
        saveTask(task, of: botID)
        let superseded = JobTasks.superseded(by: task, among: tasks[botID, default: []]) { [self] other in
            let shown = ChatTarget.task(other.id, of: botID)
            return isRunning(shown) || tab(of: botID) == shown || !(drafts[shown] ?? "").isEmpty
                || conversations[shown]?.queue?.messages.isEmpty == false
        }
        for id in superseded { closeTask(.task(id, of: botID)) }
        return target
    }

    /// A job's run in its task ended: it is news when the agent's Home hears of the run too (a
    /// finding or a failure), and what the owner queued in the task meanwhile goes out, in the run's
    /// session.
    func endJobRun(in target: ChatTarget, news: Bool) {
        guard task(target) != nil else { return }
        if news, visibleBotID != target.botID || tab(of: target.botID) != target { unread.insert(target) }
        sendNextQueued(to: target)
    }

    /// Opens a task, closed or open: a closed one goes back beside the chat.
    func openTask(_ target: ChatTarget) {
        guard let task = task(target) else { return }
        if task.isArchived { reopenTask(target) } else { show(target) }
    }

    /// Takes away the closed runs' tasks a job's history let go with their runs
    /// (`JobTasks.expired`): each task's record and conversation, its folder in the bot's
    /// `.botchu/tasks/` and nothing else (never the workspace it ran in), once what is being
    /// written there is done.
    func removeJobTasks(_ ids: [UUID], of botID: UUID) {
        guard let bot = bot(botID) else { return }
        let home = BotHome(workspace: bot.persistencePath)
        for id in ids {
            let target = ChatTarget.task(id, of: botID)
            guard let task = task(id, of: botID), task.jobRun != nil, task.isArchived, !isRunning(target) else { continue }
            tasks[botID]?.removeAll { $0.id == id }
            if let conversation = conversations.removeValue(forKey: target) {
                historyBudget.remove(target)
                let waited = conversation.waiting
                conversation.waiting = []
                for waiting in waited { waiting.cancel?() }
            }
            TranscriptCache.forget(target)
            unread.remove(target)
            drafts[target] = nil
            draftReferences[target] = nil
            draftImages[target] = nil
            attachmentErrors[target] = nil
            // After the writes asked for in its conversation's lane and then its settings' lane.
            let folder = home.taskURL(id), taskLane = home.taskLane(id), storage = storage
            storage.submit(home.conversationLane(task: id), label: "remove", work: {
                try storage.sync(taskLane, label: "remove") {
                    if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                }
            })
        }
    }

    /// Closes a task's tab. Its record, conversation and worktree stay, and it can be opened again;
    /// a review's worktree, a temporary one, goes (unless it has changes), and opening it again
    /// makes a new one at the pull request's head.
    func closeTask(_ target: ChatTarget) {
        guard target.taskID != nil, !isRunning(target), delegation.activeCount(target) == 0, let i = taskIndex(target) else { return }
        // The tab above it shows in its place: the task opened before it, or Home (#128).
        let above = openTasks(of: target.botID).prefix { $0.id != target.taskID }.last.map { ChatTarget.task($0.id, of: target.botID) }
            ?? .home(target.botID)
        tasks[target.botID]?[i].archivedAt = Date()
        let task = tasks[target.botID]![i]
        saveTask(task, of: target.botID)
        unread.remove(target)
        TranscriptCache.forget(target)
        if openTask[target.botID] == target.taskID {
            if visibleBotID == target.botID { show(above) } else { openTask[target.botID] = above.taskID }
        }
        trimHistories()
        if task.review != nil, let folder = task.folder, case .success(let machine) = machine(of: task) {
            Task {
                guard await TaskWorktree.remove(folder, checkout: task.checkout, on: machine).ok, let i = taskIndex(target) else { return }
                tasks[target.botID]?[i].folder = nil
                saveTask(tasks[target.botID]![i], of: target.botID)
            }
        }
    }

    func reopenTask(_ target: ChatTarget) {
        guard let i = taskIndex(target), bot(target.botID) != nil else { return }
        tasks[target.botID]?[i].archivedAt = nil
        saveTask(tasks[target.botID]![i], of: target.botID)
        // A closed task's queue wasn't recovered at launch: it is now, with its transcript, and
        // what waits in it goes out once it is (`recovered`).
        if conversation(target).history.recovery != .recovered {
            recover(target, load: true)
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

    /// Starts the tasks a bot asked for: the requests in its `.botchu/dispatch/`, from its Home or any
    /// other conversation that writes there.
    func takeDispatches(for botID: UUID) {
        guard let bot = bot(botID), !bot.isRemoteQueue, !dispatching.contains(botID), BotHome(workspace: bot.persistencePath).hasDispatches() else { return }
        dispatching.insert(botID)
        let root = settings.expandedReposRoot
        Task {
            // Off the main thread: the first look into ~/Desktop or ~/Documents waits on macOS's question.
            let checkouts = await Task.detached { Repositories.scan(root: root) }.value
            await loadRepositories()
            if let bot = self.bot(botID) {
                for request in BotHome(workspace: bot.persistencePath).peekDispatches() {
                    await startTask(requestedIn: request.file, data: request.data, checkouts: checkouts, for: botID)
                }
            }
            dispatching.remove(botID)
        }
    }

    /// Starts the task one request asks for, where its repository lives (or on the machine it
    /// names), or says in Home why it can't. The request is taken just before its task is recorded,
    /// so it is never lost in between, nor taken twice. A request naming another bot (`agent`) hands
    /// the task to that bot, and Home gets a receipt that opens it.
    private func startTask(requestedIn file: URL, data: Data, checkouts: [RepoCheckout], for botID: UUID) async {
        let name = "dispatch/\(file.lastPathComponent)"
        do {
            let wanted = try TaskRequest.parse(data)
            guard let asking = bot(botID) else { return }
            let owner = try wanted.agent.map { try resolveTaskBot($0) } ?? asking
            var task = try await plannedTask(wanted, for: owner, checkouts: checkouts, origin: owner.id == botID ? .home : .agent)
            if owner.id != botID {
                task.requestedBy = BotTask.Requester(name: asking.name, botID: botID, conversation: "\(asking.name)'s Home")
            }
            guard BotHome(workspace: asking.workspace).take(dispatch: file) else { return }
            startTask(task, for: owner.id, show: false)
            if owner.id != botID {
                postReceipt(TaskReceipt.handedOff(task, to: owner.name), task: task.id, of: owner.id, in: .home(botID))
            }
        } catch {
            guard let bot = bot(botID), BotHome(workspace: bot.persistencePath).take(dispatch: file) else { return }
            let reason = (error as? TaskRequest.Problem)?.message ?? error.localizedDescription
            postReceipt(TaskReceipt.couldNotStart(name, reason: reason), task: nil, for: botID)
        }
    }

    /// The bot a request hands its task to, by name, slug or ID: never a specialist (#250).
    func resolveTaskBot(_ name: String) throws -> Bot {
        do { return try SubagentResolver.resolveTaskOwner(name, bots: bots) }
        catch { throw TaskRequest.Problem(message: error.localizedDescription) }
    }

    /// The task a request asks `bot` for, where its repository lives (or on the machine it names),
    /// or why it can't be: a repository BotChu can't find, or another open task already on it (its
    /// pull request's head branch too, looked up first, so no tab is made for it: #215). Checked
    /// after its last wait, so a caller that starts it without waiting again can't race another.
    func plannedTask(_ wanted: TaskRequest, for bot: Bot, checkouts: [RepoCheckout], origin: BotTask.Origin) async throws -> BotTask {
        if let problem = bot.taskOwnershipProblem { throw TaskRequest.Problem(message: problem) }
        let found = try repository(named: wanted.repo, checkouts: checkouts).get()
        var location: RepoLocation
        if let checkout = found.checkout {
            location = RepoLocation(path: checkout.path)
        } else if let machine = wanted.machine {
            let host = try await host(named: machine).get()
            location = RepoLocation(hostID: host?.id, path: folder(of: found.repo, on: host?.id))
        } else {
            location = self.location(of: found.repo)
        }
        if location.hostID == nil { location.path = (location.path as NSString).expandingTildeInPath }
        var work = wanted.issue.map { BotTask.Work(number: $0, isPullRequest: false, repo: found.repo) }
            ?? wanted.pullRequest.map { BotTask.Work(number: $0, isPullRequest: true, repo: found.repo) }
        // A pull request's task works on the pull request's own branch (or its head, for a review).
        var branch = work?.isPullRequest == true ? "" : wanted.branch ?? ""
        if let pull = work, wanted.review == nil, let head = await pullRequestHead(pull, repo: found.repo) {
            work = head.work
            branch = head.branch
        }
        if let other = taskWorking(on: found.repo, hostID: location.hostID, work: work, review: wanted.review, branch: branch) {
            throw TaskRequest.Problem.alreadyWorking(other.task, of: other.botID)
        }
        return BotTask(for: bot, repo: found.repo, checkout: location.path, work: work, brief: wanted.task, branch: branch,
                       title: wanted.title, origin: origin, host: settings.host(location.hostID), review: wanted.review)
    }

    /// Looks for every bot's requests every two seconds while any turn runs, whichever bot's or
    /// conversation's, so a request one conversation writes into another bot's folder doesn't wait
    /// for that bot's Home (#111); and once more after the last turn ends.
    private func watchDispatches() {
        if !runs.isEmpty {
            guard dispatchTimer == nil else { return }
            dispatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.takeAllDispatches() }
            }
        } else {
            dispatchTimer?.invalidate()
            dispatchTimer = nil
            takeAllDispatches()
            // A file written just before the turn ended waits until it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.takeAllDispatches() }
        }
    }

    private func takeAllDispatches() {
        for bot in bots where !bot.isRemoteQueue { takeDispatches(for: bot.id) }
    }

    /// Adds a receipt to the bot's Home thread. A newer word on the task the last receipt is about
    /// replaces it, so a task that keeps working doesn't fill Home.
    private func postReceipt(_ text: String, task taskID: UUID?, for botID: UUID) {
        postReceipt(text, task: taskID, in: .home(botID))
    }

    /// Adds a receipt to a conversation, as to Home; `owner` is the task's bot, for a task the
    /// conversation handed to another bot.
    func postReceipt(_ text: String, task taskID: UUID?, of owner: UUID? = nil, in place: ChatTarget) {
        // The conversation's thread decides whether it replaces the last receipt: once it is in memory.
        if later(place, needs: .history, { [weak self] in self?.postReceipt(text, task: taskID, of: owner, in: place) }) { return }
        var receipt = ChatMessage(role: .receipt, text: text, taskID: taskID)
        receipt.taskBotID = owner == place.botID ? nil : owner
        if let taskID, let last = thread(place).last, last.role == .receipt, last.taskID == taskID, last.taskBotID == receipt.taskBotID {
            conversation(place).edit { $0[$0.count - 1] = receipt }
        } else {
            append(receipt, to: place)
        }
        saveThread(place)
    }

    /// Calls `report` once the task's first turn has started (with nil) or couldn't (with why): at
    /// once when it already has.
    func whenTaskStarts(_ target: ChatTarget, _ report: @escaping (String?) -> Void) {
        if runs[target] != nil || thread(target).contains(where: { $0.role == .assistant || $0.role == .tool }) { return report(nil) }
        if waiting[target] == nil, makings[target] == nil, let error = thread(target).last(where: { $0.role == .error }) {
            return report(error.text)
        }
        startWatchers[target, default: []].append(report)
    }

    private func reportTaskStart(_ target: ChatTarget, failure: String?) {
        guard target.taskID != nil, let watchers = startWatchers.removeValue(forKey: target) else { return }
        for watcher in watchers { watcher(failure) }
    }

    /// A scheduled job's finding or failure, in the bot's Home with Open Run. It touches nothing
    /// else of Home's (its session, queue or draft), and Home's next turn hears of it with its
    /// task updates. Shown as news while Home isn't.
    func postJobReceipt(_ text: String, job: UUID, run: UUID, to botID: UUID) {
        guard bot(botID) != nil else { return }
        let home = ChatTarget.home(botID)
        var receipt = ChatMessage(role: .receipt, text: text)
        receipt.jobRun = JobRunLink(job: job, run: run)
        append(receipt, to: home)
        saveThread(home)
        if visibleBotID != botID || tab(of: botID) != home { unread.insert(home) }
    }

    /// Jobs, showing one agent's (or every agent's, for nil).
    func showJobs(for botID: UUID?) {
        jobs.agentFilter = botID
        destination = .jobs
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
                let owner = message.taskBotID ?? botID
                if reported.insert(id).inserted, let task = task(id, of: owner) {
                    // A Task handed to another bot is that bot's own.
                    let whose = owner == botID ? "" : "Handed to \(bot(owner)?.name ?? "another bot"): "
                    reports.append(whose + report(on: task, of: owner))
                }
            } else {
                reports.append(message.text)
            }
        }
        return BotContext.taskUpdates(reports)
    }

    /// The tasks a Home turn reports on (`taskUpdates`): those with receipts in `history`.
    private func reportedTasks(of botID: UUID, in history: [ChatMessage]) -> [UUID] {
        history.compactMap { $0.role == .receipt ? $0.taskID : nil }
    }

    /// A task as its bot's Home hears of it; `replyLimit` keeps an overview of many tasks short. A
    /// task whose thread isn't in memory is told from its digest (`digests(of:)` reads those first),
    /// so a Home turn reads no task's transcript.
    private func report(on task: BotTask, of botID: UUID, replyLimit: Int = BotContext.maxReportReply) -> String {
        let conversation = conversation(.task(task.id, of: botID))
        let status = BotStatus.make(settings: task, summary: conversation.summary, run: conversation.run)
        let digest = conversation.reportDigest
        return BotContext.taskReport(task, status: status, pullRequest: task.pullRequest, lastReply: digest.lastReply,
                                     replyCut: digest.lastReplyCut, replyLimit: replyLimit)
    }

    /// Whether a task on this Mac has its worktree to run in. A task on a host is asked there.
    private func hasWorktree(_ task: BotTask) -> Bool {
        !task.isRemote && (task.folder.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    }

    /// The open task, of any bot, that already works on this issue or pull request (or reviews it,
    /// for a review), or on this branch, in the repository on the same machine
    /// (`BotTask.alreadyWorks`).
    func taskAlreadyWorking(on repo: String, hostID: UUID?, work: BotTask.Work?, review: BotTask.Review?, branch: String,
                            except id: UUID? = nil) -> BotTask? {
        taskWorking(on: repo, hostID: hostID, work: work, review: review, branch: branch, except: id)?.task
    }

    /// `taskAlreadyWorking`, with the bot whose task it is.
    func taskWorking(on repo: String, hostID: UUID?, work: BotTask.Work?, review: BotTask.Review?, branch: String,
                     except id: UUID? = nil) -> (task: BotTask, botID: UUID)? {
        for (botID, list) in tasks {
            if let other = list.first(where: { $0.id != id && $0.alreadyWorks(on: repo, hostID: hostID, work: work, review: review, branch: branch) }) {
                return (other, botID)
            }
        }
        return nil
    }

    /// A pull request to continue, read from GitHub with its title, and the head branch its task
    /// works on: empty for a fork's, which only a review can work on (the worktree says so). Nil
    /// when it is an issue's, or GitHub can't say; making the worktree asks again.
    func pullRequestHead(_ work: BotTask.Work, repo: String) async -> (work: BotTask.Work, branch: String)? {
        guard work.isPullRequest, case .success(let found) = await workLookup(repo, work.number, true) else { return nil }
        return (found.work, found.fromFork ? "" : found.branch ?? "")
    }

    /// Makes (or reopens) the task's worktree, or waits for the making already under way. Returns
    /// why it couldn't, or nil when the worktree is ready.
    private func worktree(for target: ChatTarget) async -> TaskWorktree.Failure? {
        if let underway = makings[target] { return await underway.value }
        guard let task = task(target) else { return TaskWorktree.Failure(step: "The task is gone", output: "") }
        if hasWorktree(task) { return nil }
        // A job's run works in its agent's workspace, which BotChu doesn't make (#146).
        if task.jobRun != nil {
            append(ChatMessage(role: .error, text: "\(bot(target.botID)?.name ?? "The agent")'s workspace is missing."), to: target)
            saveThread(target)
            return TaskWorktree.Failure(step: "The agent's workspace is missing", output: "")
        }
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
            switch await workLookup(task.repo, work.number, work.isPullRequest) {
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
        summarizeIfReady(target)
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
        pets[id] = PetVideoPackage.load(from: PetVideo.folder(for: BotHome(workspace: bot.persistencePath)))
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

    /// `id` is the message's own: a message from Telegram has one made from it, so the same
    /// message sent again is recognized.
    ///
    /// The message shows in the queue at once and its save goes on off the main thread; it is sent
    /// only once a saved queue holds it. `accepted` hears whether it was: when the queue can't be
    /// saved, the message leaves the queue again (for the composer to put back into its draft), the
    /// queue pauses and the conversation says why.
    @discardableResult
    func send(_ text: String, to target: ChatTarget, visible: Bool = true, images: [ImageAttachment] = [], files: [FileAttachment] = [],
              id: UUID = UUID(), references: [MessageReference] = [], delivery: UUID? = nil, fromAgent: AgentLink? = nil,
              heartbeat: Int? = nil, accepted: (@MainActor @Sendable (Bool) -> Void)? = nil) -> Bool {
        let (text, references) = MessageReference.trimming(text, references: references)
        // Anything sent to the conversation answers the heartbeat it waited to send.
        pendingHeartbeats[target] = nil
        if bot(target.botID)?.isRemoteQueue == true {
            guard visible, target.taskID == nil, !text.isEmpty || !files.isEmpty, images.isEmpty,
                  files.count <= FileAttachment.maximumCount else { return false }
            return remoteQueue.enqueue(text, files: files, id: id, for: target.botID, accepted: accepted)
        }
        guard images.count <= ImageAttachment.maximumCount else {
            attachmentErrors[target] = "Attach up to 8 images per message. Remove an image before sending."
            return false
        }
        guard (!text.isEmpty || !images.isEmpty || !files.isEmpty), runSettings(of: target) != nil else { return false }
        if !visible {
            return beginTurn(text, for: target, message: nil)
        }
        // A job's run the owner writes in is theirs from now on (#146).
        if heartbeat == nil, let i = taskIndex(target), tasks[target.botID]?[i].jobRun?.continued == false {
            tasks[target.botID]?[i].jobRun?.continued = true
            saveTask(tasks[target.botID]![i], of: target.botID)
        }
        // An idle conversation is busy from now on, so nothing else starts in it before this message
        // does, and Stop withdraws it.
        let ticket = isRunning(target) ? nil : UUID()
        if let ticket {
            waiting[target] = ticket
            runStates[target] = RunState(preparing: true)
        }
        // The queue changes once it is recovered after the launch, so what was saved in it isn't lost.
        if later(target, needs: .recovery, { [weak self] in self?.enqueue(text, to: target, images: images, files: files, id: id,
                                                                         references: references, delivery: delivery, fromAgent: fromAgent,
                                                                         heartbeat: heartbeat, reserved: ticket, accepted: accepted) },
                 cancel: { accepted?(false) }) {
            return true
        }
        enqueue(text, to: target, images: images, files: files, id: id, references: references, delivery: delivery, fromAgent: fromAgent,
                heartbeat: heartbeat, reserved: ticket, accepted: accepted)
        return true
    }

    /// Queues a message being sent, saves the queue, then sends it (`send`); `reserved` is the
    /// ticket that keeps the conversation busy meanwhile.
    private func enqueue(_ text: String, to target: ChatTarget, images: [ImageAttachment], files: [FileAttachment] = [], id: UUID,
                         references: [MessageReference], delivery: UUID? = nil, fromAgent: AgentLink? = nil, heartbeat: Int? = nil,
                         reserved ticket: UUID?, accepted: (@MainActor @Sendable (Bool) -> Void)?) {
        var queue = messageQueues[target] ?? MessageQueue()
        var message = ChatMessage(id: id, role: .user, text: text, images: images, references: references)
        message.delivery = delivery
        message.files = files.isEmpty ? nil : files
        message.fromAgent = fromAgent
        message.heartbeat = heartbeat
        queue.enqueue(message, unsaved: true)
        messageQueues[target] = queue
        saveQueue(for: target) { [weak self] saved in
            guard let self else { return accepted?(false) ?? () }
            if let ticket, self.waiting[target] == ticket {
                self.waiting[target] = nil
                self.runStates[target] = nil
            }
            if saved {
                self.messageQueues[target]?.accepted(id)
                self.sendNextQueued(to: target)
            } else {
                self.messageQueues[target]?.remove(id)
            }
            accepted?(saved)
        }
    }

    /// `send`, returning once the message's save is done: whether a saved queue holds it.
    func sendAccepted(_ text: String, to target: ChatTarget, id: UUID = UUID(), references: [MessageReference] = []) async -> Bool {
        await withCheckedContinuation { continuation in
            let started = send(text, to: target, id: id, references: references) { continuation.resume(returning: $0) }
            if !started { continuation.resume(returning: false) }
        }
    }

    /// Puts a message that couldn't be queued back into the composer, before what was typed since.
    func returnToDraft(_ text: String, references: [MessageReference], images: [ImageAttachment], files: [FileAttachment] = [],
                       in target: ChatTarget) {
        let draft = MessageReference.joining((text, references), (drafts[target] ?? "", draftReferences[target] ?? []))
        drafts[target] = draft.text
        draftReferences[target] = draft.references.isEmpty ? nil : draft.references
        draftImages[target] = images + (draftImages[target] ?? [])
        if !files.isEmpty { draftFiles[target] = files + (draftFiles[target] ?? []) }
    }

    /// Resume a paused queue: its next message goes out now, or, during a turn, as a follow-up.
    func resumeQueuedMessages(to target: ChatTarget) {
        if later(target, needs: .recovery, { [weak self] in self?.resumeQueuedMessages(to: target) }) { return }
        guard messageQueues[target]?.messages.isEmpty == false else { return }
        messageQueues[target]?.resume()
        saveQueue(for: target)
        sendNextQueued(to: target)
    }

    /// Takes a pending message out of the queue now; if the queue can't be saved without it, it
    /// goes back where it was, so what is queued is what is saved.
    func removeQueuedMessage(_ id: UUID, from target: ChatTarget) {
        if later(target, needs: .recovery, { [weak self] in self?.removeQueuedMessage(id, from: target) }) { return }
        guard var queue = messageQueues[target], let index = queue.messages.firstIndex(where: { $0.id == id }) else { return }
        let message = queue.messages[index]
        queue.remove(id)
        guard queue != messageQueues[target] else { return }
        messageQueues[target] = queue
        saveQueue(for: target) { [weak self] saved in
            guard !saved, let self, var queue = self.messageQueues[target] else { return }
            queue.restore(message, at: index)
            self.messageQueues[target] = queue
        }
    }

    func editQueuedMessage(_ id: UUID, in target: ChatTarget) {
        if later(target, needs: .recovery, { [weak self] in self?.editQueuedMessage(id, in: target) }) { return }
        guard let message = messageQueues[target]?.messages.first(where: { $0.id == id }),
              messageQueues[target]?.isInFlight(id) == false else { return }
        removeQueuedMessage(id, from: target)
        guard messageQueues[target]?.messages.contains(where: { $0.id == id }) == false else { return }
        returnToDraft(message.text, references: message.mentions, images: message.images, in: target)
    }

    /// Whether follow-ups reach this conversation's CLI during a turn, once its current step ends,
    /// rather than once the turn ends: Claude Code, on This Mac.
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
        // A queue not recovered yet has nothing to send; its recovery sends what waits in it.
        guard conversation(target).history.recovery != .recovering, let message = messageQueues[target]?.next else { return }
        // The turn starts from the conversation's history: once it is read, unless Stop withdraws it.
        guard conversation(target).isLoaded else {
            let ticket = UUID()
            waiting[target] = ticket
            runStates[target] = RunState(preparing: true)
            hydrate(target, then: { [weak self] in
                guard let self, self.waiting[target] == ticket else { return }
                self.waiting[target] = nil
                self.runStates[target] = nil
                self.sendNextQueued(to: target)
            })
            return
        }
        // It leaves the queue once the saved transcript holds it (`beginTurn`).
        guard beginTurn(message.text, for: target, message: message) else {
            pauseQueue(target)
            return
        }
    }

    /// Writes queued messages to the running CLI, which takes them once its current step ends (after
    /// the running tool call returns). They stay queued, unable to be edited, until the CLI echoes
    /// them (`AgentEvent.inputTaken`), however long that takes; any it never takes go out as the
    /// next turn.
    private func sendFollowUps(to target: ChatTarget) {
        guard let run = runs[target], run.acceptsInput, var input = inputs[target], input.ledger.acceptsFollowUps else { return }
        while let message = messageQueues[target]?.next,
              case let text = deliveredText(of: message, for: target),
              let textLine = CommandBuilder.inputLine(kind: input.kind, text: text) {
            var line = textLine
            if !message.images.isEmpty {
                guard let bot = bot(target.botID) else { break }
                do {
                    let urls = message.images.map { BotHome(workspace: bot.persistencePath).imageURL($0) }
                    let invocation = try ImageDelivery.attaching(urls, to: Invocation(arguments: [], input: [textLine]),
                                                                kind: input.kind, prompt: text.isEmpty ? "Please describe the attached images." : text)
                    guard let imageLine = invocation.input?.first else { break }
                    line = imageLine
                } catch {
                    pauseQueue(target)
                    append(ChatMessage(role: .error, text: "Couldn't send images: \(error.localizedDescription)"), to: target)
                    saveThread(target)
                    break
                }
            }
            guard run.send(line) else { break }
            messageQueues[target]?.markInFlight(message.id)
            input.ledger.wrote()
        }
        inputs[target] = input
    }

    /// Withdraws automatic delivery, remembered across relaunches: after Stop or a real failure,
    /// the queue waits for the owner. Quitting BotChu doesn't count.
    private func pauseQueue(_ target: ChatTarget) {
        if later(target, needs: .recovery, { [weak self] in self?.pauseQueue(target) }) { return }
        guard !terminating, messageQueues[target]?.messages.isEmpty == false else { return }
        messageQueues[target]?.pause()
        saveQueue(for: target)
    }

    private func beginTurn(_ text: String, for target: ChatTarget, message: ChatMessage?) -> Bool {
        guard bot(target.botID)?.isRemoteQueue != true else { return false }
        guard !isRunning(target), conversation(target).isLoaded, let bot = bot(target.botID), let current = runSettings(of: target) else { return false }
        let history = thread(target)
        // Every conversation hears what became of the notes it asked to remember (and Home what its
        // tasks did since the owner's last message there, as its turn launches).
        let updates = BotContext.memoryUpdates(memoryReports.removeValue(forKey: target) ?? [])
        // What the message's mentions point at goes with it, in a new session or a resumed one.
        let text = message.map { deliveredText(of: $0, for: target) } ?? text

        var added: [ChatMessage] = []
        var replacedNote: ChatMessage?
        if let message {
            if current.resumableSessionID == nil, (history.contains(where: { $0.role == .assistant }) || conversation(target).digest?.lastReply != nil) {
                // Name the account on the note New Session left, or add one (an account switch).
                if let last = history.last, last.role == .note, last.text.hasPrefix("New session") {
                    replacedNote = last
                    conversation(target).edit { $0.removeLast() }
                }
                added.append(ChatMessage(role: .note, text: "New session on \(current.account.name)"))
            }
            added.append(message)
            // It shows in the conversation now, and stays in the saved queue until the saved transcript holds it.
            messageQueues[target]?.deliver(message.id)
        } else {
            added.append(ChatMessage(role: .note, text: "\(bot.name) was created on \(current.account.name)"))
        }
        for line in added { append(line, to: target) }
        // The CLI runs only once the transcript holding the message is saved, off the main thread.
        // Meanwhile the conversation is busy, so nothing else starts in it, and Stop withdraws the turn.
        let ticket = UUID()
        waiting[target] = ticket
        runStates[target] = RunState(preparing: true)
        saveThread(target) { [weak self] saved in
            guard let self else { return }
            guard self.waiting[target] == ticket else {
                // Stopped meanwhile: the turn doesn't start, and an unsaved message waits again.
                if !saved, let message { self.messageQueues[target]?.undeliver(message.id) }
                return
            }
            self.waiting[target] = nil
            self.runStates[target] = nil
            guard saved else {
                // Still queued, not delivered. Keep one copy in the outbox and explain the failure.
                if let message { self.messageQueues[target]?.undeliver(message.id) }
                let ids = Set(added.map(\.id))
                self.conversation(target).edit { messages in
                    messages.removeAll { ids.contains($0.id) }
                    if let replacedNote { messages.append(replacedNote) }
                    messages.append(ChatMessage(role: .error, text: "Couldn't save this message. It is still queued."))
                }
                self.pauseQueue(target)
                self.reportTaskStart(target, failure: "Couldn't save its first message. It is still queued.")
                return
            }
            self.startSavedTurn(text, for: target, history: history, updates: updates, images: message?.images ?? [])
        }
        return true
    }

    /// Starts a turn whose message the saved transcript holds: in the task's worktree once it is
    /// ready, or at once.
    private func startSavedTurn(_ text: String, for target: ChatTarget, history: [ChatMessage], updates: String?, images: [ImageAttachment]) {
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
                    reportTaskStart(target, failure: failure.step)
                } else {
                    startTurn(text, for: target, history: history, updates: nil, images: images)
                    if !isRunning(target) { pauseQueue(target) }
                }
            }
        } else {
            startTurn(text, for: target, history: history, updates: updates, images: images)
            if !isRunning(target) { pauseQueue(target) }
        }
    }

    /// Runs the CLI for one turn of the conversation, in the bot's workspace or the task's worktree.
    private func startTurn(_ text: String, for target: ChatTarget, history: [ChatMessage], updates: String?, images: [ImageAttachment]) {
        guard !images.isEmpty else { launchTurn(text, for: target, history: history, updates: updates); return }
        guard let bot = bot(target.botID), let current = runSettings(of: target) else { return }
        let ticket = UUID()
        waiting[target] = ticket
        runStates[target] = RunState()
        Task {
            do {
                var urls = images.map { BotHome(workspace: bot.persistencePath).imageURL($0) }
                // Inline image input travels over SSH for Claude. File-based providers
                // need copies on the host before their CLI can open the attachments.
                if let task = task(target), task.isRemote, current.account.kind != .claude {
                    let machine = try self.machine(of: task).get()
                    urls = try await machine.stageImages(urls)
                }
                guard waiting[target] == ticket else { return }
                waiting[target] = nil
                runStates[target] = nil
                launchTurn(text.isEmpty ? "Please describe the attached images." : text, for: target, history: history, updates: updates, imageURLs: urls)
                if !isRunning(target) { pauseQueue(target) }
            } catch {
                guard waiting[target] == ticket else { return }
                waiting[target] = nil
                runStates[target] = nil
                append(ChatMessage(role: .error, text: "Couldn't send images: \(error.localizedDescription)"), to: target)
                saveThread(target)
                pauseQueue(target)
            }
        }
    }

    private func launchTurn(_ text: String, for target: ChatTarget, history: [ChatMessage], updates: String?, imageURLs: [URL] = []) {
        guard let bot = bot(target.botID), let current = runSettings(of: target) else { return }
        let task = task(target)
        let id = bot.id
        let account = current.account
        let resume = current.resumableSessionID
        let directory: String
        var machine = Machine.thisMac
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
        } else {
            directory = bot.workspace
        }
        let ticket = UUID()
        waiting[target] = ticket
        runStates[target] = RunState(preparing: true)
        let historyLast = history.last?.id
        Task { [self] in
            defer { if waiting[target] == ticket { waiting[target] = nil } }
            // Read the requested recap/receipt history before taking the latest preparation snapshot.
            let historyHome = BotHome(workspace: bot.persistencePath)
            let history = (try? await storage.perform(historyHome.conversationLane(task: target.taskID), label: "resume context") {
                historyLast == nil ? [] : try PagedTranscript.context(historyHome.transcriptURL(task: target.taskID), through: historyLast)
            }) ?? history
            guard waiting[target] == ticket else { return }
            let home = task?.isRemote == true && resume == nil ? await loadedThread(.home(id)) ?? [] : []
            if task == nil {
                await digests(of: (resume == nil ? openTasks(of: id).map(\.id) : []) + reportedTasks(of: id, in: history), of: id)
            }
            guard waiting[target] == ticket else { return }
            do {
                let context = try await delegation.prepareCaller(target: target, directory: directory, machine: machine, hostID: task?.hostID)
                guard waiting[target] == ticket else { delegation.endCaller(context.id); return }
                let needsDelegationContext = resume.map { !(delegationSessions[target] ?? []).contains($0) } ?? true
                let delegationInstructions = needsDelegationContext ? BotContext.subagentsSection(availableBots: delegation.roster) : nil
                let prepared: PreparedSession
                do {
                    prepared = try await prepareSessionForLaunch(of: id, kind: account.kind, remote: machine.isRemote,
                                                                  current: { self.waiting[target] == ticket })
                } catch { delegation.endCaller(context.id); throw error }
                guard waiting[target] == ticket else { delegation.endCaller(context.id); return }
                let snapshot = prepared.context
                let toolProfile = prepared.toolProfile
                let refreshContext = resume.map { contextSessions[target]?[$0] != snapshot.revision } ?? true
                var preamble: String?
                var updates = updates
                if let task {
                    if refreshContext {
                        preamble = BotContext.taskPreamble(bot: self.bot(id) ?? bot, task: task,
                            memory: snapshot.memory, sharedMemory: snapshot.sharedMemory, history: resume == nil ? history : [],
                            machine: machineDescription(of: task), home: home, soul: snapshot.soul,
                            instructions: snapshot.instructions, team: snapshot.team, skills: snapshot.skills)
                    }
                } else {
                    if refreshContext {
                        preamble = BotContext.sessionPreamble(bot: self.bot(id) ?? bot,
                            memory: snapshot.memory, sharedMemory: snapshot.sharedMemory, history: resume == nil ? history : [],
                            tasks: openTasks(of: id).map { report(on: $0, of: id, replyLimit: 240) }, soul: snapshot.soul,
                            instructions: snapshot.instructions, team: snapshot.team, skills: snapshot.skills)
                    }
                    let sections = [taskUpdates(for: id, in: history), updates].compactMap { $0 }
                    updates = sections.isEmpty ? nil : sections.joined(separator: "\n\n")
                }
                let toolText = machine.isRemote ? "" : tools.instructions() ?? ""
                let toldBefore = resume.flatMap { toolSessions[target]?[$0] }
                let toolInstructions: String? = toldBefore == nil || toldBefore == toolText
                    ? (toldBefore == nil && !toolText.isEmpty ? toolText : nil)
                    : (toolText.isEmpty ? ToolsBoard.cleared : toolText)
                let contextSections = [preamble, delegationInstructions, toolInstructions].compactMap { $0 }
                let prompt = BotContext.prompt(for: text, preamble: contextSections.isEmpty ? nil : contextSections.joined(separator: "\n\n"), updates: updates)
                let model = GenerationOptions.effectiveModel(current.model, kind: account.kind, openRouterDefault: settings.openRouterModel,
                                                             sailDefault: settings.sailModel)
                // A CLI that takes input mid-turn keeps its stdin open for follow-ups (This Mac only).
                let liveInput = CommandBuilder.takesInputMidTurn(account.kind) && !machine.isRemote
                let sailKey = account.kind == .sail && !machine.isRemote ? Keychain.get(Keychain.sailAccount) : nil
                var invocation = CommandBuilder.invocation(
                    kind: account.kind,
                    prompt: prompt,
                    model: model,
                    sessionID: resume,
                    reasoningEffort: current.reasoningEffort,
                    fast: current.fastMode == true,
                    openRouterKey: account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil,
                    sailKey: sailKey,
                    liveInput: liveInput)
                invocation.toolProfile = toolProfile

                do {
                    invocation = try ImageDelivery.attaching(imageURLs, to: invocation, kind: account.kind, prompt: prompt)
                } catch {
                    delegation.endCaller(context.id)
                    runStates[target] = nil
                    pauseQueue(target)
                    append(ChatMessage(role: .error, text: "Couldn't send images: \(error.localizedDescription)"), to: target)
                    saveThread(target)
                    return
                }
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

                // Sail's helper is built beside BotChu and its key never leaves this Mac.
                if account.kind == .sail, let problem = SailLaunch.problem(remote: machine.isRemote, key: sailKey) {
                    delegation.endCaller(context.id)
                    runStates[target] = nil
                    pauseQueue(target)
                    append(ChatMessage(role: .error, text: problem), to: target)
                    saveThread(target)
                    return
                }

                // On a host, its own command for the account when it has one.
                let command = effectiveCommand(for: account, task: task)
                let connectorScope = ConnectorScope(accountID: account.id, command: command, folder: directory, hostID: task?.hostID)
                let run = machine.isRemote
                    ? AgentRun(command: command, invocation: invocation, on: machine, folder: directory)
                    : AgentRun(command: command, invocation: invocation, directory: URL(fileURLWithPath: directory, isDirectory: true))
                let place = task.map { machineName($0.hostID, fallback: $0.hostName) } ?? "This Mac"
                let home = BotHome(workspace: bot.persistencePath)
                let what = task.map { "\($0.title) turn" } ?? "turn"
                let startedAt = Date()
                let turnStart = conversation(target).historyStart + thread(target).count
                let turnPrompt = thread(target).last(where: { $0.role == .user })
                var lastCheckpoint = Date()
                var assembler = ThreadAssembler()
                var outcome = TurnOutcome()
                let accountID = account.id

                // The CLI's lines are parsed off the main thread; their events arrive here in
                // batches, a few times a second at most, and go into this conversation alone.
                run.deliverEvents(parsedBy: StreamParsers.make(for: account.kind)) { [weak self, weak run] events in
                    guard let self, let run, self.runs[target] === run, self.runSettings(of: target) != nil else { return }
                    let conversation = self.conversation(target)
                    var state = conversation.run
                    if state?.hasOutput == false { state?.hasOutput = true }
                    // The CLI's first lines held no events: it has started, and that's all.
                    guard !events.isEmpty else {
                        if state != conversation.run { conversation.run = state }
                        return
                    }
                    var sessions: [String] = []
                    var reported: String?
                    var connectors: [Connector]?
                    var settles: [TimeInterval] = []
                    var delivered = false
                    conversation.stream { messages in
                        for event in events {
                            // After Stop, a CLI's last word is about the interruption (Antigravity
                            // repeats its whole reply as a failure); the "Stopped" note says it.
                            if run.stopped, case .failed = event { continue }
                            outcome.record(event)
                            switch event {
                            case .session(let reported):
                                sessions.append(CommandBuilder.resumeID(kind: account.kind, invocation: invocation, reported: reported))
                            case .model(let id):
                                reported = id
                            case .connectors(let list):
                                connectors = list
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
                                    state?.takesInput = true
                                }
                            case .finished, .failed:
                                // Its input closes once the CLI has taken everything written to it.
                                if self.inputs[target]?.ledger.turnEnded() == true {
                                    run.closeInput()
                                    state?.takesInput = false
                                }
                            default: break
                            }
                            if let activity = BotActivity.next(after: event), activity != state?.activity || state?.pending != nil,
                               let wait = state?.move(to: activity) {
                                settles.append(wait)
                            }
                            if case .inputTaken = event { continue }
                            assembler.apply(event, to: &messages)
                        }
                    }
                    if state != conversation.run { conversation.run = state }
                    for wait in settles {
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak run] in
                            guard let run, self?.runs[target] === run else { return }
                            self?.runStates[target]?.settle()
                        }
                    }
                    for session in sessions {
                        self.recordSession(session, accountID: accountID, for: target)
                        self.delegationSessions[target, default: []].insert(session)
                        self.toolSessions[target, default: [:]][session] = toolText
                        self.contextSessions[target, default: [:]][session] = snapshot.revision
                    }
                    if let reported { self.recordReportedModel(reported, requested: current.model, accountID: accountID, for: target) }
                    if let connectors {
                        self.connectorBoard.record(connectors, scope: connectorScope, sessionID: sessions.last ?? self.runSettings(of: target)?.resumableSessionID, for: target)
                    }
                    if delivered || (conversation.messages.count > PagedTranscript.residentLimit && Date().timeIntervalSince(lastCheckpoint) >= 1) {
                        lastCheckpoint = Date()
                        // The taken message leaves the saved queue only once the saved transcript holds it.
                        self.saveThread(target)
                    }
                    // Messages queued before the CLI could take them.
                    self.sendFollowUps(to: target)
                }
                run.onExit = { [weak self, weak run] status, stderr in
                    guard let self, let run, self.runs[target] === run else { return }
                    self.runs[target] = nil
                    self.inputs[target] = nil
                    self.delegation.endCaller(context.id)
                    self.watchDispatches()
                    // The bot (or the task) was deleted while it ran.
                    guard self.runSettings(of: target) != nil else {
                        if self.bot(target.botID) != nil { self.runStates[target] = nil }
                        return
                    }
                    let stopped = run.stopped
                    // Interrupt & send stopped it, not the owner: the conversation goes on at once.
                    let interrupted = self.messageQueues[target]?.isInterrupting == true
                    // What the turn delivered to the Inbox shows after its reply.
                    let cards = self.inbox.takeCards(for: target)
                    // The heartbeat this turn answered, if it did; its bare acknowledgement leaves a note instead.
                    let pulse = self.thread(target).last(where: { $0.role == .user })?.heartbeat ?? turnPrompt?.heartbeat
                    let localTurnStart = max(0, turnStart - self.conversation(target).historyStart)
                    var acknowledged = false
                    self.conversation(target).stream { messages in
                        assembler.apply(.textEnd, to: &messages)
                        ThreadAssembler.closeRunningTools(&messages)
                        messages += cards
                        if stopped {
                            messages.append(.stopNote(byOwner: !self.terminating && !interrupted))
                        } else if run.lingered {
                            messages.append(ChatMessage(role: .note, text: "\(account.name) didn't exit after its reply, so BotChu ended it."))
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
                        if pulse != nil, !stopped, let i = messages.indices.last(where: { messages[$0].role == .assistant }), i >= localTurnStart,
                           Heartbeat.isAck(messages[i].text) {
                            messages.remove(at: i)
                            messages.append(ChatMessage(role: .note, text: Heartbeat.acknowledged))
                            acknowledged = true
                        }
                    }
                    let messages = self.thread(target)
                    let failure = outcome.failure(stopped: stopped, exitError: messages.last(where: { !$0.role.isNote }).flatMap { $0.role == .error ? $0.text : nil })
                    let fallback = Array(messages.suffix(from: min(localTurnStart, messages.count)))
                    self.inbox.turnEnded(target)
                    // The turn's end is saved off the main thread, then what it asked to remember;
                    // until both are done the conversation stays busy, so nothing else starts in it.
                    self.saveThread(target) { [weak self] saved in
                        guard let self else { return }
                        self.readTurn(target, from: turnStart, fallback: fallback) { [weak self] turn in
                            guard let self else { return }
                            self.log(TurnLog.ended(
                                at: Date(), startedAt: startedAt, status: status, stopped: stopped,
                                toolCalls: turn.filter { $0.role == .tool }.count,
                                error: turn.last(where: { $0.role == .error })?.text, stderr: stderr, what: what), in: home)
                            self.saveMemory(from: turn, for: target) { [weak self] in
                                guard let self, self.runSettings(of: target) != nil else { return }
                                self.runStates[target] = nil
                                if !stopped, failure == nil { self.react(.done, for: target, seconds: 3) }
                                if !acknowledged, self.visibleBotID != id || self.tab(of: id) != target { self.unread.insert(target) }
                                if target.taskID != nil { self.finishTaskTurn(target, messages: turn, stopped: stopped, failure: failure, reported: !acknowledged) }
                                self.scheduleHeartbeat(after: Heartbeat.Turn(reply: turn.last(where: { $0.role == .assistant })?.text, pulse: pulse,
                                                                             stopped: stopped, failed: failure != nil,
                                                                             endedBackgroundTasks: run.endedBackgroundTasks), in: target)
                                // Home's turns and tasks' join the work their bot's next run review covers.
                                self.reviewTurn(target, thread: (turnPrompt.map { [$0] } ?? []) + turn, turnStart: turnPrompt == nil ? 0 : 1, accountID: account.id)
                                // Only Stop and real failures pause the queue (not quitting BotChu, nor Interrupt &
                                // send); messages the CLI never took go out as the next turn.
                                self.messageQueues[target]?.finishTurn(stopped: stopped && !self.terminating,
                                                                       failed: !self.terminating && (!saved || failure != nil))
                                self.saveQueue(for: target)
                                self.sendNextQueued(to: target)
                                // The account may be idle now, for a review waiting for it.
                                self.evaluator.pump()
                            }
                        }
                    }
                }

                do {
                    log(TurnLog.started(at: startedAt, account: account, command: command,
                                        arguments: invocation.arguments, prompt: prompt, resuming: resume, what: what,
                                        directory: task == nil ? nil : machine.isRemote ? "\(place): \(directory)" : directory), in: home)
                    try run.start()
                    if let resume {
                        delegationSessions[target, default: []].insert(resume)
                        toolSessions[target, default: [:]][resume] = toolText
                        contextSessions[target, default: [:]][resume] = snapshot.revision
                    }
                    runs[target] = run
                    if liveInput { inputs[target] = (account.kind, InputLedger()) }
                    reactions[target] = nil
                    reactionTickets[target] = nil
                    runStates[target] = RunState()
                    watchDispatches()
                    reportTaskStart(target, failure: nil)
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
                    reportTaskStart(target, failure: "Couldn't start \(account.name): \(error.localizedDescription)")
                }
            } catch {
                guard waiting[target] == ticket else { return }
                waiting[target] = nil
                runStates[target] = nil
                pauseQueue(target)
                append(ChatMessage(role: .error, text: "Couldn't prepare the turn: \(error.localizedDescription)"), to: target)
                reportTaskStart(target, failure: "Couldn't prepare the turn: \(error.localizedDescription)")
                saveThread(target)
            }
        }
    }

    /// After a task's turn: notes the pull request its conversation linked to, and tells its bot's
    /// Home how the turn went (not when the owner stopped it, nor for a heartbeat acknowledged).
    private func finishTaskTurn(_ target: ChatTarget, messages: [ChatMessage], stopped: Bool, failure: String?, reported: Bool = true) {
        guard let i = taskIndex(target), var task = tasks[target.botID]?[i] else { return }
        let pullRequest = TaskNaming.pullRequest(in: messages, task: task)
        if pullRequest != task.pullRequest {
            task.pullRequest = pullRequest
            tasks[target.botID]?[i] = task
            saveTask(task, of: target.botID)
        }
        guard !stopped, reported else { return }
        postReceipt(failure.map { TaskReceipt.failed(task, error: $0) } ?? TaskReceipt.finished(task),
                    task: task.id, for: target.botID)
    }

    // MARK: Memory

    /// A turn consumer (memory, log, review) explicitly requests its complete content after the
    /// checkpoint. It does not put those old pages back in the active conversation.
    private func readTurn(_ target: ChatTarget, from start: Int, fallback: [ChatMessage],
                          done: @escaping @MainActor @Sendable ([ChatMessage]) -> Void) {
        guard let files = files(target) else { done(fallback); return }
        let snapshot = conversation(target).snapshot, home = files.home, task = target.taskID
        storage.submit(files.lane, label: "finished turn", work: {
            let prefix = start < snapshot.start
                ? home.loadHistory(task: task, before: snapshot.start, limit: snapshot.start - start).messages : []
            let held = Dictionary(snapshot.pending.map { ($0.message.id, $0.message) }, uniquingKeysWith: { _, last in last })
            return prefix.map { held[$0.id] ?? $0 } + snapshot.messages.dropFirst(max(0, start - snapshot.start))
        }) { result in done((try? result.get()) ?? fallback) }
    }

    /// After a turn of Home or a task, on this Mac or a host (or on Retry): saves what its replies
    /// asked to remember, and any notes still waiting, off the main thread, says how it went in the
    /// conversation, and then calls `done`.
    private func saveMemory(from turn: [ChatMessage], for target: ChatTarget, retrying: Bool = false,
                            done: (@MainActor @Sendable () -> Void)? = nil) {
        guard let bot = bot(target.botID) else { done?(); return }
        saveMemory(from: turn, of: bot, reportTo: target, retrying: retrying) { [weak self] lines in
            if let self, !lines.isEmpty, self.bot(target.botID) != nil {
                for line in lines { self.append(line, to: target) }
                self.saveThread(target)
            }
            done?()
        }
    }

    /// Saves what the replies asked to remember (`<remember>` for the bot's own memory, `<remember
    /// scope="shared">` for the shared one) after any notes still waiting for those files, off the
    /// main thread (`MemoryWriter` saves one file at a time), keeps what became of them for the next
    /// turn of `target`, and gives `done` the lines that say so. Waiting notes that fail again on
    /// their own are left to the banner, unless the owner chose Retry.
    func saveMemory(from replies: [ChatMessage], of bot: Bot, reportTo target: ChatTarget, retrying: Bool = false,
                    done: @escaping @MainActor @Sendable ([ChatMessage]) -> Void) {
        let requests = MemoryNotes.requests(in: replies)
        let files = memoryFiles(of: bot)
        storage.submit(Self.memoryLane(of: bot), label: "memory", work: { () -> (saves: [MemorySave], waiting: Int) in
            let saves = MemoryWriter.shared.save(requests, to: files)
            return (saves, files.reduce(0) { $0 + MemoryWriter.shared.waitingCount($1) })
        }) { [weak self] result in
            guard let self, case .success(let saved) = result else { return done([]) }
            var lines: [ChatMessage] = []
            for save in saved.saves {
                if save.failure != nil, !retrying, requests[save.file.scope]?.isEmpty ?? true { continue }
                if let summary = save.summary(botName: bot.name) {
                    lines.append(ChatMessage(role: summary.failed ? .error : .note, text: summary.text))
                }
                if let report = save.report { self.memoryReports[target, default: []].append(report) }
            }
            if self.bot(bot.id) != nil, self.unsavedMemory[bot.id, default: 0] != saved.waiting { self.unsavedMemory[bot.id] = saved.waiting }
            done(lines)
        }
    }

    /// Tries the notes waiting for the bot's memory again, saying how it went in `target` (Retry).
    func retryMemory(for target: ChatTarget) {
        saveMemory(from: [], for: target, retrying: true)
    }

    /// Counts the notes waiting for the bot's memory files, read off the main thread.
    func refreshUnsavedMemory(of botID: UUID) {
        guard let bot = bot(botID) else { return }
        let files = memoryFiles(of: bot)
        storage.submit(Self.memoryLane(of: bot), label: "memory", work: {
            files.reduce(0) { $0 + MemoryWriter.shared.waitingCount($1) }
        }) { [weak self] result in
            guard let self, self.bot(botID) != nil, case .success(let count) = result else { return }
            if self.unsavedMemory[botID, default: 0] != count { self.unsavedMemory[botID] = count }
        }
    }

    /// The lane a bot's memory saves go in: its `MEMORY.md`, beside the workspace's `.botchu/`.
    private static func memoryLane(of bot: Bot) -> String { MemoryFile.bot(workspace: bot.workspace).path }

    private func memoryFiles(of bot: Bot) -> [MemoryFile] {
        [.bot(workspace: bot.workspace), .shared(settings.sharedMemoryPath, botWorkspace: bot.workspace)]
    }

    /// Whether Interrupt & send can stop this conversation's running CLI for its next queued message.
    func canInterrupt(_ target: ChatTarget) -> Bool {
        runs[target] != nil && messageQueues[target]?.interruptible != nil
    }

    /// Interrupt & send: stops the running turn and its sub-agents as Stop does, but leaves the queue
    /// to go on. Once the CLI has exited and its output is read, so every message it took is in the
    /// conversation, its next message starts a turn of the same session, and what it never took
    /// follows in order (`MessageQueue.finishTurn`). What the turn's tools did stays done.
    func interruptAndSend(_ target: ChatTarget) {
        guard bot(target.botID)?.isRemoteQueue != true, let run = runs[target],
              messageQueues[target]?.interrupt() == true else { return }
        delegation.stopRoot(target)
        inputs[target]?.ledger.close()
        run.stop()
    }

    func stop(_ target: ChatTarget) {
        guard bot(target.botID)?.isRemoteQueue != true else { return }
        delegation.stopRoot(target)
        // The owner's Stop calls off an Interrupt & send under way, even once the CLI took everything.
        if messageQueues[target]?.isInterrupting == true { messageQueues[target]?.pause() }
        pauseQueue(target)
        inputs[target]?.ledger.close()
        if let run = runs[target] {
            run.stop()
        } else if let jobRun = jobs?.runID(in: target) {
            // A job's run in its task stops as Stop in Jobs stops it (#146).
            jobs.stop(run: jobRun)
        } else if runStates[target]?.preparing == true || waiting[target] != nil {
            // Workspace setup or image transfer may finish, but this turn must not start.
            waiting[target] = nil
            runStates[target] = nil
            append(.stopNote(byOwner: !terminating), to: target)
            saveThread(target)
        }
    }

    /// BotChu is quitting. Queues stay as they are, to go out on their own after the next launch.
    /// Everything asked to be saved is written before it quits, waiting up to `quitTimeout` for the
    /// writes still under way; what isn't written by then is listed in `unsavedAtQuit` and the
    /// system log, and its files stay as they were (with any messages the CLI took in their queue).
    func stopAll() {
        remoteQueue?.stop()
        terminating = true
        // What waits for a conversation's history or its recovery is done now, so quitting loses
        // none of it: read here, in order with its writes, in the place of a read under way.
        for (target, conversation) in conversations where !conversation.waiting.isEmpty { settleNow(target) }
        // What each CLI printed last goes into its thread, and the thread is saved: BotChu may
        // quit before the turn's end would save it, and nothing streamed may be lost.
        for (target, run) in Array(runs) {
            run.flushOutput()
            saveUnfinishedTurn(target)
        }
        delegation.stopAll()
        evaluator.stopAll()
        jobs?.stopAll()
        for target in Array(runStates.keys) { stop(target) }
        for run in petRuns.values { run.stop() }
        for task in petTasks.values { task.cancel() }
        for run in summaryRuns.values { run.cancel() }
        for run in titleRuns.values { run.cancel() }
        // Sidebar changes that couldn't be saved get one more try.
        if indexFailure != nil { saveIndex() }
        unsavedAtQuit = storage.wait(timeout: quitTimeout)
        if !unsavedAtQuit.isEmpty {
            NSLog("BotChu quit before it could save %@; those files are as they were last saved.", unsavedAtQuit.joined(separator: ", "))
        }
    }

    /// Saves a turn still running as it stands, with its running tool calls marked interrupted,
    /// after the conversation's other writes; the thread in memory is left as it is, for the
    /// turn's end.
    func saveUnfinishedTurn(_ target: ChatTarget) {
        guard let bot = bot(target.botID), runSettings(of: target) != nil else { return }
        var closed = thread(target)
        ThreadAssembler.closeRunningTools(&closed)
        let home = BotHome(workspace: bot.persistencePath), taskID = target.taskID
        let current = conversation(target).snapshot
        let pending = current.pending.map { update in
            var update = update
            if update.message.toolState == .running { update.message.toolState = .interrupted }
            return update
        }
        let snapshot = PagedTranscript.Snapshot(closed, start: current.start, base: current.base, pending: pending)
        storage.submit(home.conversationLane(task: taskID), label: "unfinished", work: { try home.writeTranscript(snapshot, task: taskID) })
    }

    /// The model the CLI said it ran, for the model choice the turn ran with. Changes no choice.
    func recordReportedModel(_ id: String, requested: String, accountID: String, for target: ChatTarget) {
        guard var current = runSettings(of: target), current.accountID == accountID,
              current.recordReportedModel(id, requested: requested) else { return }
        change(target) { $0.recordReportedModel(id, requested: requested) }
    }

    func recordSession(_ sessionID: String, accountID: String, for target: ChatTarget) {
        guard let current = runSettings(of: target),
              current.sessionID != sessionID || current.sessionAccountID != accountID else { return }
        change(target) {
            $0.sessionID = sessionID
            $0.sessionAccountID = accountID
        }
    }

    // MARK: History (#109)

    /// At most this many bytes of the inactive conversations' histories stay in memory (those not
    /// shown, running, unsaved or being read); the least recently shown go first. Their digests
    /// stay, and they are read again when they are needed.
    nonisolated static let inactiveHistoryBytes = 48 << 20
    @ObservationIgnored var historyBudget = HistoryBudget<ChatTarget>(limit: AppModel.inactiveHistoryBytes)
    /// Conversations whose index is made again, one at a time, off the main thread.
    @ObservationIgnored private var reindexing: [ChatTarget] = []
    @ObservationIgnored private var isReindexing = false

    /// The conversation shown, or remembered behind a gallery.
    private var shownTarget: ChatTarget? { selection.map(tab(of:)) }

    /// Runs `action` now or, while the conversation's queue is being recovered (or, for `.history`,
    /// while its history isn't in memory, or is being read or recovered), once that is done, after
    /// what waits already for the same; returns whether it waits. What `action` asks for in turn while
    /// it runs goes first. A queue being read doesn't hold up changes to its queue. A conversation
    /// whose bot or task is gone runs it now.
    @discardableResult
    func later(_ target: ChatTarget, needs: ConversationState.Waiting.Need, _ action: @escaping () -> Void,
               cancel: (() -> Void)? = nil) -> Bool {
        guard files(target) != nil else { return false }
        let conversation = conversation(target)
        if meets(conversation, needs), conversation.draining || !conversation.waiting.contains(where: { $0.need == needs }) { return false }
        let waiting = ConversationState.Waiting(need: needs, run: action, cancel: cancel)
        if conversation.draining {
            conversation.waiting.insert(waiting, at: min(conversation.insertion, conversation.waiting.count))
            conversation.insertion += 1
        } else {
            conversation.waiting.append(waiting)
        }
        startWaitingRead(target)
        return true
    }

    private func meets(_ conversation: ConversationState, _ need: ConversationState.Waiting.Need) -> Bool {
        switch need {
        case .recovery: conversation.history.recovery != .recovering
        case .idle: !conversation.history.isBusy
        case .history: !conversation.history.isBusy && conversation.isLoaded
        }
    }

    /// Runs what waits for the conversation, each kind in the order asked, as far as it can; reads
    /// its history when something waits for it.
    private func drain(_ target: ChatTarget) {
        guard let conversation = conversations[target], !conversation.draining else { return }
        conversation.draining = true
        var index = 0
        while index < conversation.waiting.count {
            let next = conversation.waiting[index]
            guard meets(conversation, next.need) else {
                index += 1
                continue
            }
            conversation.waiting.remove(at: index)
            conversation.insertion = index
            next.run()
        }
        conversation.draining = false
        startWaitingRead(target)
    }

    private func startWaitingRead(_ target: ChatTarget) {
        guard let conversation = conversations[target], !conversation.history.isBusy, !conversation.isLoaded,
              conversation.waiting.contains(where: { $0.need == .history }) else { return }
        startRead(target)
    }

    /// Reads the conversation's history into memory, off the main thread on its lane, unless it is
    /// there (the chat shows a spinner meanwhile); `then` runs once it is, at once when it is already.
    func hydrate(_ target: ChatTarget, then: (() -> Void)? = nil, cancel: (() -> Void)? = nil) {
        if later(target, needs: .history, { then?() }, cancel: cancel) { return }
        if conversations[target]?.isLoaded == true, let conversation = conversations[target] {
            historyBudget.use(target, bytes: HistoryBudget<ChatTarget>.estimate(conversation.messages))
            trimHistories()
        }
        then?()
    }

    /// The conversation's history, once it is in memory (read for it when it isn't); nil when its
    /// bot or task is gone.
    func loadedThread(_ target: ChatTarget) async -> [ChatMessage]? {
        guard files(target) != nil else { return nil }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            hydrate(target, then: { continuation.resume() }, cancel: { continuation.resume() })
        }
        guard let files = files(target) else { return nil }
        let state = conversation(target)
        guard state.historyStart > 0 else { return state.messages }
        let home = files.home, task = target.taskID, snapshot = state.snapshot
        return try? await storage.perform(files.lane, label: "requested history") {
            let prefix = home.loadHistory(task: task, before: snapshot.start, limit: Int.max).messages
            let held = Dictionary(snapshot.pending.map { ($0.message.id, $0.message) }, uniquingKeysWith: { _, last in last })
            return prefix.map { held[$0.id] ?? $0 } + snapshot.messages
        }
    }

    /// Waits until no read or recovery of the conversation is under way.
    private func settled(_ target: ChatTarget) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !later(target, needs: .idle, { continuation.resume() }, cancel: { continuation.resume() }) { continuation.resume() }
        }
    }

    /// An earlier window uses the same lane and stable message IDs as the active tail. Its
    /// payload is capped separately, so a reader can stay here while the run keeps checkpointing.
    func pageEarlier(_ target: ChatTarget, done: @escaping @MainActor () -> Void) {
        let state = conversation(target)
        guard !state.isPaging, state.displayStart > 0, let files = files(target) else { return }
        state.isPaging = true
        let end = state.displayStart, home = files.home, task = target.taskID
        storage.submit(files.lane, label: "page", work: { home.loadHistory(task: task, before: end, limit: PagedTranscript.pageSize) }) { [weak self, weak state] result in
            guard let self, let state, self.conversations[target] === state else { return }
            state.isPaging = false
            guard state.displayStart == end, case .success(let page) = result else { return }
            state.browse(page)
            done()
        }
    }

    func pageLater(_ target: ChatTarget, done: @escaping @MainActor () -> Void = {}) {
        let state = conversation(target)
        guard !state.isPaging, state.hasLaterPage, let page = state.browsing, let files = files(target) else { return }
        let end = page.start + page.messages.count, home = files.home, task = target.taskID
        if end >= state.historyStart {
            let messages = Array(state.messages.dropFirst(end - state.historyStart).prefix(PagedTranscript.pageSize))
            state.browseLater(HistoryLoad(messages: messages, digest: state.reportDigest, bytes: 0, reindexed: false, start: end))
            done()
            return
        }
        state.isPaging = true
        storage.submit(files.lane, label: "page", work: { home.loadHistory(task: task, before: end + PagedTranscript.pageSize, limit: PagedTranscript.pageSize) }) { [weak self, weak state] result in
            guard let self, let state, self.conversations[target] === state else { return }
            state.isPaging = false
            guard state.browsing?.start == page.start, case .success(let later) = result else { return }
            state.browseLater(later)
            done()
        }
    }

    private func startRead(_ target: ChatTarget) {
        guard let files = files(target) else { return }
        let conversation = conversation(target)
        guard let ticket = conversation.history.begin(load: true, recover: false) else { return }
        let home = files.home, task = target.taskID, lane = files.lane
        storage.submit(lane, label: "read", work: { home.loadHistory(task: task) }) { [weak self, weak conversation] result in
            guard let self, let conversation else { return }
            self.read(target, conversation, ticket: ticket, lane: lane, result: result)
        }
    }

    /// A read is taken only by the conversation it was for, while it is the latest: one that ends
    /// after its bot or task was deleted, or after the conversation was read, recovered or dropped
    /// from memory again, is ignored, and one from where its bot's folder was is made again where
    /// it is now.
    private func read(_ target: ChatTarget, _ conversation: ConversationState, ticket: Int, lane: String, result: Result<HistoryLoad, Error>) {
        guard conversations[target] === conversation, let files = files(target) else { return }
        guard files.lane == lane else {
            conversation.history.abandon(ticket)
            drain(target)
            return
        }
        // Only a folder going away (its bot deleted) fails a read.
        guard case .success(let history) = result else { return conversation.history.abandon(ticket) }
        guard conversation.history.finish(ticket, loaded: true, recovered: false) else { return }
        took(history, into: conversation, target)
        drain(target)
        trimHistories()
    }

    private func took(_ history: HistoryLoad, into conversation: ConversationState, _ target: ChatTarget) {
        conversation.load(history)
        historyBudget.use(target, bytes: HistoryBudget<ChatTarget>.estimate(history.messages))
        if target == shownTarget { warmMarkdown(target) }
    }

    /// Recovers a Home's or open task's queue (at launch, or as a closed task opens again) off the
    /// main thread, on its lane: messages the CLI took that the transcript lacks go back into it,
    /// and what waits in the queue goes out once that's done, as nothing else in the conversation
    /// changes before. The transcript is read only when recovery needs it, or `load` asks for it.
    private func recover(_ target: ChatTarget, load: Bool) {
        guard let files = files(target) else { return }
        let conversation = conversation(target)
        let given = conversation.isLoaded ? conversation.messages : nil
        let start = conversation.historyStart, prefix = conversation.prefixDigest
        guard let ticket = conversation.history.begin(load: load, recover: true) else {
            later(target, needs: .idle, { [weak self] in self?.recover(target, load: load) })
            return
        }
        let home = files.home, task = target.taskID, lane = files.lane
        storage.submit(lane, label: "recover", work: { home.recover(task: task, transcript: given, load: load, start: start, prefix: prefix) }) { [weak self, weak conversation] result in
            guard let self, let conversation else { return }
            self.recovered(target, conversation, ticket: ticket, lane: lane, inMemory: given != nil, load: load, result: result)
        }
    }

    private func recovered(_ target: ChatTarget, _ conversation: ConversationState, ticket: Int, lane: String, inMemory: Bool, load: Bool,
                           result: Result<HistoryRecovery, Error>) {
        guard conversations[target] === conversation, let files = files(target) else { return }
        guard files.lane == lane, case .success(let recovery) = result else {
            conversation.history.abandon(ticket)
            if files.lane != lane { recover(target, load: load) }
            return
        }
        guard conversation.history.finish(ticket, loaded: recovery.history != nil, recovered: true) else { return }
        if let history = recovery.history {
            if !inMemory {
                took(history, into: conversation, target)
            } else if history.messages.count != conversation.messages.count {
                conversation.load(history)
            }
        } else if let digest = recovery.digest {
            conversation.know(digest)
        } else {
            reindex(target)
        }
        messageQueues[target] = recovery.queue
        show(recovery.failures, in: target)
        drain(target)
        sendNextQueued(to: target)
        trimHistories()
    }

    /// Quitting: recovers the conversation, or reads its history, at once, then runs what waits for it.
    private func settleNow(_ target: ChatTarget) {
        guard let files = files(target), let conversation = conversations[target] else { return }
        let home = files.home, task = target.taskID
        if conversation.history.recovery == .recovering {
            let given = conversation.isLoaded ? conversation.messages : nil
            let start = conversation.historyStart, prefix = conversation.prefixDigest
            let recovery = storage.sync(files.lane, label: "recover") { home.recover(task: task, transcript: given, load: true, start: start, prefix: prefix) }
            conversation.history.took(loaded: true, recovered: true)
            if let history = recovery.history {
                if given == nil { took(history, into: conversation, target) } else { conversation.load(history) }
            }
            messageQueues[target] = recovery.queue
            show(recovery.failures, in: target)
        } else if !conversation.isLoaded, conversation.waiting.contains(where: { $0.need == .history }) {
            let history = storage.sync(files.lane, label: "read") { home.loadHistory(task: task) }
            conversation.history.took(loaded: true, recovered: false)
            took(history, into: conversation, target)
        }
        drain(target)
    }

    /// Makes sure Home can report on each task without reading its transcript: in memory, or its
    /// digest read from its index (made again when it doesn't match), off the main thread.
    private func digests(of taskIDs: [UUID], of botID: UUID) async {
        var reads: [(ConversationState, Task<ThreadDigest?, Never>)] = []
        for id in Set(taskIDs) {
            let target = ChatTarget.task(id, of: botID)
            await settled(target)
            guard let files = files(target), let conversation = conversations[target] ?? (task(target) != nil ? conversation(target) : nil),
                  !conversation.isLoaded, conversation.digest == nil else { continue }
            let home = files.home, storage = storage, lane = files.lane
            reads.append((conversation, Task { try? await storage.perform(lane, label: "digest") { home.readDigest(task: id) ?? home.rebuildDigest(task: id) } }))
        }
        for (conversation, read) in reads {
            if let digest = await read.value, !conversation.history.isBusy { conversation.know(digest) }
        }
    }

    /// Reads the digest of a conversation not in memory from its index, off the main thread, or
    /// makes its index again when it doesn't match its transcript (`reindex`).
    private func readDigest(_ target: ChatTarget) {
        guard let files = files(target) else { return }
        let home = files.home, task = target.taskID
        storage.submit(files.lane, label: "digest", work: { home.readDigest(task: task) }) { [weak self] result in
            guard let self, let conversation = self.conversations[target], !conversation.isLoaded, !conversation.history.isBusy,
                  case .success(let found) = result else { return }
            if let found { conversation.know(found) } else { self.reindex(target) }
        }
    }

    /// Makes a conversation's index again, one conversation at a time, in the background: a launch
    /// after an upgrade, or after a transcript changed outside BotChu.
    private func reindex(_ target: ChatTarget) {
        reindexing.append(target)
        reindexNext()
    }

    private func reindexNext() {
        guard !isReindexing, !reindexing.isEmpty else { return }
        let target = reindexing.removeFirst()
        guard let files = files(target), let conversation = conversations[target], !conversation.isLoaded,
              !conversation.history.isBusy, conversation.digest == nil else { return reindexNext() }
        isReindexing = true
        let home = files.home, task = target.taskID
        storage.submit(files.lane, label: "reindex", work: { home.rebuildDigest(task: task) }) { [weak self, weak conversation] result in
            guard let self else { return }
            self.isReindexing = false
            if case .success(let digest) = result, let conversation, self.conversations[target] === conversation,
               !conversation.history.isBusy { conversation.know(digest) }
            self.reindexNext()
        }
    }

    /// Drops inactive histories from memory, the least recently shown first, while they take more
    /// than `inactiveHistoryBytes`. Never the one shown (or remembered behind a gallery), one with
    /// a turn, a sub-agent, a worktree being made, a read or recovery under way, changes waiting
    /// for it, or anything not saved yet; its draft, queue, settings and session stay as they are.
    private func trimHistories() {
        delegation?.trimThreads()
        let shown = shownTarget
        for target in historyBudget.overflow(pinned: { !self.evictable($0, shown: shown) }) {
            guard let conversation = conversations[target], conversation.history.evict() else { continue }
            conversation.unload()
            historyBudget.remove(target)
            TranscriptCache.forget(target)
        }
    }

    private func evictable(_ target: ChatTarget, shown: ChatTarget?) -> Bool {
        guard target != shown, let conversation = conversations[target], conversation.isLoaded, conversation.isSaved,
              !conversation.history.isBusy, conversation.waiting.isEmpty, conversation.run == nil, waiting[target] == nil,
              runs[target] == nil, makings[target] == nil, (delegation?.activeCount(target) ?? 0) == 0,
              let files = files(target) else { return false }
        return storage.isIdle(under: files.lane)
    }

    // MARK: Storage

    /// Adds a message to the conversation; to one not in memory, once it is read (`later`).
    func append(_ message: ChatMessage, to target: ChatTarget) {
        if later(target, needs: .history, { [weak self] in self?.append(message, to: target) }) { return }
        conversation(target).append(message)
    }

    /// Adds one of BotChu's own lines to a conversation, and saves it.
    func note(_ text: String, in target: ChatTarget) {
        append(ChatMessage(role: .note, text: text), to: target)
        saveThread(target)
    }

    /// Parses the latest replies of a conversation just read, in the background, so it finds
    /// them parsed and doesn't parse them on the main thread. Only the conversation being shown is
    /// warmed, and only so much of it: the rest parse as they show.
    private func warmMarkdown(_ target: ChatTarget) {
        var budget = Self.warmedBytes
        let replies = Array(thread(target).reversed().lazy.filter { $0.role == .assistant }.prefix(Self.warmedReplies).map(\.text)
            .prefix { text in
                budget -= text.utf8.count
                return budget >= 0
            })
        guard !replies.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { MarkdownCache.shared.warm(replies) }
    }

    /// How many of a conversation's latest replies are parsed ahead, and at most how much text.
    static let warmedReplies = 60
    static let warmedBytes = 256 << 10

    func taskIndex(_ target: ChatTarget) -> Int? {
        target.taskID.flatMap { id in tasks[target.botID]?.firstIndex { $0.id == id } }
    }

    /// Changes what a conversation runs on, its task's or its bot's, and saves it off the main
    /// thread (the index of bot folders doesn't change with it).
    private func change(_ target: ChatTarget, _ edit: (inout any RunSettings) -> Void) {
        guard bot(target.botID)?.isRemoteQueue != true else { return }
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
            saveSettings(bot)
        }
    }

    /// Captures only settings on MainActor. All context/catalog reads and owned-file work run on
    /// a storage lane; changed settings while awaiting it are retried before a snapshot is used.
    func prepareSession(of id: UUID) async throws -> SessionPreparation.Snapshot {
        while let bot = bot(id), !bot.isRemoteQueue {
            try Task.checkCancellation()
            let input = sessionInput(bot)
            let snapshot: SessionPreparation.Snapshot
            do { snapshot = try await sessionPreparation.prepare(input) }
            catch StorageQueue.Failure.superseded { continue }
            guard let current = self.bot(id) else { throw CancellationError() }
            guard sessionInput(current) == input else { continue }
            if snapshot.migratedInstructions, let i = bots.firstIndex(where: { $0.id == id }),
               bots[i].instructions == input.bot.instructions, !bots[i].instructions.isEmpty {
                bots[i].instructions = ""
                save(bots[i])
            }
            return snapshot
        }
        throw CancellationError()
    }

    struct PreparedSession {
        let context: SessionPreparation.Snapshot
        let toolProfile: String?
    }

    /// Tool discovery can suspend too. Validate the context again afterwards, and retry when
    /// either it or the policy changed meanwhile, so neither half of a launch is out of date.
    func prepareSessionForLaunch(of id: UUID, kind: AgentKind, remote: Bool,
                                 current: () -> Bool = { true }) async throws -> PreparedSession {
        var snapshot = try await prepareSession(of: id)
        while true {
            guard current(), !Task.isCancelled else { throw CancellationError() }
            let policy = tools.policy
            let profile = remote ? nil : try await tools.turnProfile(for: kind)
            guard current(), !Task.isCancelled else { throw CancellationError() }
            let latest = try await prepareSession(of: id)
            guard current(), !Task.isCancelled else { throw CancellationError() }
            if latest.revision == snapshot.revision, remote || tools.policy == policy {
                return PreparedSession(context: latest, toolProfile: profile)
            }
            snapshot = latest
        }
    }

    private func sessionInput(_ bot: Bot) -> SessionPreparation.Input {
        SessionPreparation.Input(bot: bot, sharedMemoryPath: settings.sharedMemoryPath,
            repositoriesPath: settings.expandedReposRoot, machines: settings.hosts.map(\.nickname), availableBots: delegation.roster)
    }

    private func prepareWorkspace(_ bot: Bot, then: (() -> Void)? = nil) {
        guard !bot.isRemoteQueue else { return }
        Task {
            do { _ = try await prepareSession(of: bot.id); then?() }
            catch {
                guard self.bot(bot.id) != nil else { return }
                append(ChatMessage(role: .error, text: "Couldn't prepare \(bot.workspace): \(error.localizedDescription)"), to: .home(bot.id))
            }
        }
    }

    /// Writes the bot's `.botchu/bot.json`, and the index of bot folders.
    func save(_ bot: Bot) {
        saveSettings(bot)
        saveIndex()
    }

    /// Writes the bot's `.botchu/bot.json` off the main thread, after its earlier saves.
    private func saveSettings(_ bot: Bot) {
        let home = BotHome(workspace: bot.persistencePath), id = bot.id, workspace = bot.workspace
        storage.replace(home.botLane, slot: "bot", value: bot, write: { try home.save($0); return 0 }) { [weak self] result in
            guard case .failure(let error) = result, (error as? StorageQueue.Failure) == nil, let self, self.bot(id) != nil else { return }
            self.append(ChatMessage(role: .error, text: "Couldn't save this bot in \(workspace): \(error.localizedDescription)"), to: .home(id))
        }
    }

    /// Writes the task's `task.json` off the main thread, after its earlier saves.
    func saveTask(_ task: BotTask, of botID: UUID, saved: (@MainActor @Sendable (Error?) -> Void)? = nil) {
        guard let bot = bot(botID) else {
            saved?(CocoaError(.fileNoSuchFile))
            return
        }
        let home = BotHome(workspace: bot.persistencePath), workspace = bot.workspace, target = ChatTarget.task(task.id, of: botID)
        storage.replace(home.taskLane(task.id), slot: "task", value: task, write: { try home.save($0); return 0 }) { [weak self] result in
            if let saved {
                if case .failure(let error) = result { saved(error) } else { saved(nil) }
            }
            guard case .failure(let error) = result, (error as? StorageQueue.Failure) == nil, let self, self.task(target) != nil else { return }
            self.append(ChatMessage(role: .error, text: "Couldn't save this task in \(workspace): \(error.localizedDescription)"), to: target)
        }
    }

    /// Appends to the bot's turn log off the main thread, in order.
    func log(_ text: String, in home: BotHome, at date: Date = Date()) {
        storage.submit(home.logsLane, label: "log", work: { try home.appendLog(text, at: date) })
    }

    /// Writes `index.json`: the bots in sidebar order, with their sections, then the entries whose
    /// folders are missing. A failure shows in the sidebar until a save works.
    func saveIndex() {
        let failure = store.commitIndex(Store.entries(for: bots, sections: sections, missing: missing))
        if failure != indexFailure { indexFailure = failure }
    }

    /// The conversation's files, written off the main thread in order (`ConversationStorage`); nil
    /// once its bot or task is gone.
    private func files(_ target: ChatTarget) -> ConversationStorage? {
        guard let bot = bot(target.botID) else { return nil }
        if let taskID = target.taskID, task(taskID, of: bot.id) == nil { return nil }
        return ConversationStorage(storage: storage, home: BotHome(workspace: bot.persistencePath), task: target.taskID)
    }

    private func queueAccess(_ target: ChatTarget) -> ConversationStorage.Queue {
        ConversationStorage.Queue(get: { [weak self] in self?.bot(target.botID) == nil ? nil : self?.messageQueues[target] },
                                  set: { [weak self] in self?.messageQueues[target] = $0 },
                                  files: { [weak self] in self?.files(target) })
    }

    /// Saves the conversation as it is now, off the main thread, after its earlier saves; then the
    /// messages the CLI took, or the turn starts with, that the saved transcript holds leave its
    /// queue (`ConversationStorage.saveTranscript`). `done` says whether a transcript holding
    /// everything in it now was saved.
    ///
    /// A conversation not in memory is never saved as it is (that would write an empty or partial
    /// transcript over the full one): it is read first, the changes asked for meanwhile go into it,
    /// in order, then it is saved; when nothing changed, what is on disk is already it.
    func saveThread(_ target: ChatTarget, done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        saveThread(target, skippingUnchanged: false, done: done)
    }

    private func saveThread(_ target: ChatTarget, skippingUnchanged: Bool, done: (@MainActor @Sendable (Bool) -> Void)?) {
        guard let files = files(target) else { done?(false); return }
        if later(target, needs: .history, { [weak self] in self?.saveThread(target, skippingUnchanged: true, done: done) },
                 cancel: { done?(false) }) { return }
        let conversation = conversation(target)
        if skippingUnchanged, conversation.isSaved, storage.isIdle(under: files.lane) { done?(true); return }
        let revision = conversation.revision
        let snapshot = conversation.snapshot
        files.saveTranscript(snapshot, version: conversation.version, queue: queueAccess(target),
                             failed: { [weak self] failures in self?.show(failures, in: target) }) { [weak conversation] saved in
            if saved { conversation?.saved(revision, snapshot: snapshot) }
            done?(saved)
        }
    }

    /// Saves the conversation's queue as it is now, off the main thread; when it can't be saved,
    /// the queue pauses and the conversation says why. `done` says whether it was saved.
    private func saveQueue(for target: ChatTarget, done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        if later(target, needs: .recovery, { [weak self] in self?.saveQueue(for: target, done: done) }, cancel: { done?(false) }) { return }
        guard let files = files(target), let queue = messageQueues[target] else { done?(false); return }
        files.saveQueue(queue) { [weak self] failure in
            guard let failure else { done?(true); return }
            if let self, self.bot(target.botID) != nil {
                self.messageQueues[target]?.pause()
                self.show([failure], in: target)
            }
            done?(false)
        }
    }

    /// Says in the conversation why its files couldn't be saved; once while the same failure repeats.
    private func show(_ failures: [SaveFailure], in target: ChatTarget) {
        guard bot(target.botID) != nil, !failures.isEmpty else { return }
        if later(target, needs: .history, { [weak self] in self?.show(failures, in: target) }) { return }
        for failure in failures where thread(target).last(where: { $0.role == .error })?.text != failure.message {
            append(ChatMessage(role: .error, text: failure.message), to: target)
        }
    }

    /// The last few meaningful lines of a CLI's stderr, for an error message.
    static func lastLines(_ text: String, count: Int = 8) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(count).joined(separator: "\n")
    }
}
