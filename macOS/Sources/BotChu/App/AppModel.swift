import AppKit
import Foundation
import Observation
import BotChuCore

struct EditorRequest: Identifiable {
    let id = UUID()
    var bot: Bot
    var isNew: Bool
}

@MainActor @Observable
final class AppModel {
    var bots: [Bot] = []
    var threads: [UUID: [ChatMessage]] = [:]
    /// Turns in progress, by bot.
    var runStates: [UUID: RunState] = [:]
    var selection: UUID?
    var editor: EditorRequest?
    let settings: AppSettings

    private let store: Store
    /// Index entries whose folders don't hold their bot right now; kept so the bot returns with it.
    @ObservationIgnored private var missing: [Store.Entry] = []
    @ObservationIgnored private var runs: [UUID: AgentRun] = [:]

    init(store: Store? = nil, settings: AppSettings? = nil) {
        self.store = store ?? DevHooks.dataDir.map { Store(root: $0) } ?? .applicationSupport
        self.settings = settings ?? AppSettings()
        self.store.migrateIfNeeded()
        let loaded = self.store.loadBots()
        bots = loaded.bots
        missing = loaded.missing
        for bot in bots { threads[bot.id] = self.store.loadThread(for: bot) }
        selection = bots.first?.id
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }
    func thread(_ id: UUID) -> [ChatMessage] { threads[id] ?? [] }
    func isRunning(_ id: UUID) -> Bool { runStates[id] != nil }

    func status(of bot: Bot) -> BotStatus {
        BotStatus.make(bot: bot, messages: thread(bot.id), run: runStates[bot.id])
    }

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
        threads[bot.id] = []
        save(bot)
        selection = bot.id
        prepareWorkspace(bot)
        send(BotContext.introPrompt, to: bot.id, visible: false)
    }

    func update(_ edited: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == edited.id }) else { return }
        var bot = edited
        bot.workspace = (bot.workspace as NSString).expandingTildeInPath
        if bot.emoji.isEmpty { bot.emoji = "🤖" }
        if bot.workspace != bots[i].workspace {
            // The bot's history and logs move with it.
            do {
                try BotHome(workspace: bots[i].workspace).move(toWorkspace: bot.workspace)
            } catch {
                append(ChatMessage(role: .error, text: "Couldn't move this bot's history to \(bot.workspace): \(error.localizedDescription)"), to: bot.id)
            }
        }
        bots[i] = bot
        save(bot)
        prepareWorkspace(bot)
    }

    func setModel(_ selected: String, for id: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == id }), !isRunning(id) else { return }
        bots[i].selectModel(selected)
        save(bots[i])
    }

    func setReasoningEffort(_ effort: ReasoningEffort?, for id: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == id }), !isRunning(id) else { return }
        bots[i].reasoningEffort = effort
        save(bots[i])
    }

    func delete(_ id: UUID) {
        runs[id]?.stop()
        if let bot = bot(id) { BotHome(workspace: bot.workspace).trash() }
        bots.removeAll { $0.id == id }
        threads[id] = nil
        saveIndex()
        if selection == id { selection = bots.first?.id }
    }

    /// Starts the next turn in a fresh CLI session (with the identity, memory and recap again).
    func newSession(_ id: UUID) {
        guard var bot = bot(id), !isRunning(id) else { return }
        bot.sessionID = nil
        bot.sessionAccountID = nil
        update(bot)
        append(ChatMessage(role: .note, text: "New session"), to: id)
        saveThread(id)
    }

    func revealWorkspace(_ id: UUID) {
        guard let bot = bot(id) else { return }
        prepareWorkspace(bot)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bot.workspace)])
    }

    /// Opens the bot's `.botchu` folder (its settings, thread and logs) in Finder.
    func revealHistory(_ id: UUID) {
        guard let bot = bot(id) else { return }
        let home = BotHome(workspace: bot.workspace)
        try? FileManager.default.createDirectory(at: home.logsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(home.url)
    }

    // MARK: Turns

    func send(_ text: String, to id: UUID, visible: Bool = true) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning(id), let bot = bot(id) else { return }
        let account = bot.account
        let history = thread(id)
        let resume = bot.resumableSessionID

        if visible {
            if resume == nil, history.contains(where: { $0.role == .assistant }) {
                // Name the account on the note New Session left, or add one (an account switch).
                if let last = history.last, last.role == .note, last.text.hasPrefix("New session") {
                    threads[id]?.removeLast()
                }
                append(ChatMessage(role: .note, text: "New session on \(account.name)"), to: id)
            }
            append(ChatMessage(role: .user, text: text), to: id)
        } else {
            append(ChatMessage(role: .note, text: "\(bot.name) was created on \(account.name)"), to: id)
        }
        saveThread(id)

        prepareWorkspace(bot)
        var preamble: String?
        if resume == nil {
            preamble = BotContext.sessionPreamble(
                bot: bot,
                memory: Workspace.read((bot.workspace as NSString).appendingPathComponent(BotContext.memoryFile)),
                sharedMemory: Workspace.read(settings.sharedMemoryPath),
                history: history)
        }
        let model = account.kind == .pi && bot.model.isEmpty ? settings.openRouterModel : bot.model
        let invocation = CommandBuilder.invocation(
            kind: account.kind,
            prompt: BotContext.prompt(for: text, preamble: preamble),
            model: model,
            sessionID: resume,
            reasoningEffort: bot.reasoningEffort,
            openRouterKey: account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil)

        if account.kind == .pi, Keychain.get(Keychain.openRouterAccount)?.isEmpty ?? true {
            append(ChatMessage(role: .error, text: "Add your OpenRouter API key in BotChu ▸ Settings first."), to: id)
            saveThread(id)
            return
        }

        let command = settings.command(for: account)
        let run = AgentRun(command: command, invocation: invocation,
                           directory: URL(fileURLWithPath: bot.workspace, isDirectory: true))
        let home = BotHome(workspace: bot.workspace)
        let startedAt = Date()
        let turnStart = thread(id).count
        var parser = StreamParsers.make(for: account.kind)
        var assembler = ThreadAssembler()
        var ended = false
        let accountID = account.id

        run.onLines = { [weak self] lines in
            guard let self, self.bot(id) != nil else { return }
            if self.runStates[id]?.hasOutput == false { self.runStates[id]?.hasOutput = true }
            var messages = self.thread(id)
            for line in lines {
                for event in parser.parse(line: line) {
                    switch event {
                    case .session(let reported):
                        self.recordSession(CommandBuilder.resumeID(kind: account.kind, invocation: invocation, reported: reported),
                                           accountID: accountID, for: id)
                    case .finished, .failed:
                        ended = true
                    default: break
                    }
                    assembler.apply(event, to: &messages)
                }
            }
            self.threads[id] = messages
        }
        run.onExit = { [weak self, weak run] status, stderr in
            guard let self else { return }
            self.runs[id] = nil
            self.runStates[id] = nil
            // The bot was deleted while it ran.
            guard self.bot(id) != nil else { return }
            var messages = self.thread(id)
            assembler.apply(.textEnd, to: &messages)
            ThreadAssembler.closeRunningTools(&messages)
            if run?.stopped == true {
                messages.append(ChatMessage(role: .note, text: "Stopped"))
            } else if !ended {
                // The stream never said the turn finished or failed: report what the CLI printed.
                let detail = Self.lastLines(stderr)
                messages.append(ChatMessage(role: .error, text: detail.isEmpty
                    ? "\(account.name) exited with status \(status) without replying."
                    : "\(account.name) exited with status \(status):\n\(detail)"))
            }
            self.threads[id] = messages
            self.saveThread(id)
            let turn = messages.suffix(from: min(turnStart, messages.count))
            try? home.appendLog(TurnLog.ended(
                at: Date(), startedAt: startedAt, status: status, stopped: run?.stopped == true,
                toolCalls: turn.filter { $0.role == .tool }.count,
                error: turn.last(where: { $0.role == .error })?.text, stderr: stderr))
        }

        do {
            try? home.appendLog(TurnLog.started(at: startedAt, account: account, command: command,
                                                arguments: invocation.arguments,
                                                prompt: BotContext.prompt(for: text, preamble: preamble), resuming: resume))
            try run.start()
            runs[id] = run
            runStates[id] = RunState()
            // A CLI that has printed nothing yet is usually blocked on a macOS prompt: as BotChu's
            // child, it needs BotChu's permission for protected folders (Desktop, Documents) its own
            // settings point into, and the prompt may be behind other windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self, weak run] in
                guard let self, let run, self.runs[id] === run, self.runStates[id]?.hasOutput == false else { return }
                self.append(ChatMessage(role: .note, text: "\(account.name) hasn't started yet. If macOS is asking whether BotChu may access a folder, allow it: the CLI reads its settings from there."), to: id)
            }
        } catch {
            append(ChatMessage(role: .error, text: "Couldn't start \(account.name): \(error.localizedDescription)"), to: id)
            saveThread(id)
        }
    }

    func stop(_ id: UUID) {
        runs[id]?.stop()
    }

    func stopAll() {
        for run in runs.values { run.stop() }
    }

    private func recordSession(_ sessionID: String, accountID: String, for id: UUID) {
        guard let i = bots.firstIndex(where: { $0.id == id }),
              bots[i].sessionID != sessionID || bots[i].sessionAccountID != accountID else { return }
        bots[i].sessionID = sessionID
        bots[i].sessionAccountID = accountID
        save(bots[i])
    }

    // MARK: Storage

    private func append(_ message: ChatMessage, to id: UUID) {
        threads[id, default: []].append(message)
    }

    private func prepareWorkspace(_ bot: Bot) {
        do {
            try Workspace.prepare(bot: bot, sharedMemoryPath: settings.sharedMemoryPath)
        } catch {
            append(ChatMessage(role: .error, text: "Couldn't prepare \(bot.workspace): \(error.localizedDescription)"), to: bot.id)
        }
    }

    /// Writes the bot's `.botchu/bot.json`, and the index of bot folders.
    private func save(_ bot: Bot) {
        do {
            try BotHome(workspace: bot.workspace).save(bot)
        } catch {
            append(ChatMessage(role: .error, text: "Couldn't save this bot in \(bot.workspace): \(error.localizedDescription)"), to: bot.id)
        }
        saveIndex()
    }

    private func saveIndex() {
        try? store.saveIndex(bots.map { Store.Entry(id: $0.id, workspace: $0.workspace) } + missing)
    }

    private func saveThread(_ id: UUID) {
        guard let bot = bot(id) else { return }
        try? BotHome(workspace: bot.workspace).saveThread(thread(id))
    }

    /// The last few meaningful lines of a CLI's stderr, for an error message.
    static func lastLines(_ text: String, count: Int = 8) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(count).joined(separator: "\n")
    }
}
