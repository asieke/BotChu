import AppKit
import Foundation
import Observation
import BotChuCore

/// Settings kept in `defaults` (domain `local.BotChu`); the OpenRouter key is in the Keychain.
@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults

    var botsRoot: String { didSet { defaults.set(botsRoot, forKey: "botsRoot") } }
    var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "openRouterModel") } }
    /// Command overrides by account id; a missing or empty entry means the account's default.
    var commands: [String: String] { didSet { defaults.set(commands, forKey: "commands") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let dev = DevHooks.dataDir {
            botsRoot = dev.appendingPathComponent("bots").path
        } else {
            botsRoot = defaults.string(forKey: "botsRoot") ?? (NSHomeDirectory() as NSString).appendingPathComponent("BotChu")
        }
        openRouterModel = defaults.string(forKey: "openRouterModel") ?? CommandBuilder.defaultOpenRouterModel
        commands = defaults.dictionary(forKey: "commands") as? [String: String] ?? [:]
    }

    func command(for account: Account) -> String {
        let override = commands[account.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return override.isEmpty ? account.defaultCommand : override
    }

    var expandedBotsRoot: String { (botsRoot as NSString).expandingTildeInPath }
    var sharedMemoryPath: String { (expandedBotsRoot as NSString).appendingPathComponent(BotContext.memoryFile) }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var bot: Bot
    var isNew: Bool
}

@MainActor @Observable
final class AppModel {
    var bots: [Bot] = []
    var threads: [UUID: [ChatMessage]] = [:]
    var running: Set<UUID> = []
    var selection: UUID?
    var editor: EditorRequest?
    let settings: AppSettings

    private let store: Store
    @ObservationIgnored private var runs: [UUID: AgentRun] = [:]

    init(store: Store? = nil, settings: AppSettings? = nil) {
        self.store = store ?? DevHooks.dataDir.map { Store(root: $0) } ?? .applicationSupport
        self.settings = settings ?? AppSettings()
        bots = self.store.loadBots()
        for bot in bots { threads[bot.id] = self.store.loadThread(bot.id) }
        selection = bots.first?.id
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    func bot(_ id: UUID) -> Bot? { bots.first { $0.id == id } }
    func thread(_ id: UUID) -> [ChatMessage] { threads[id] ?? [] }

    // MARK: Bots

    func newBot() {
        let bot = Bot(name: "", workspace: "")
        editor = EditorRequest(bot: bot, isNew: true)
    }

    func edit(_ id: UUID) {
        guard let bot = bot(id) else { return }
        editor = EditorRequest(bot: bot, isNew: false)
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
        saveBots()
        selection = bot.id
        prepareWorkspace(bot)
        send(BotContext.introPrompt, to: bot.id, visible: false)
    }

    func update(_ edited: Bot) {
        guard let i = bots.firstIndex(where: { $0.id == edited.id }) else { return }
        var bot = edited
        bot.workspace = (bot.workspace as NSString).expandingTildeInPath
        if bot.emoji.isEmpty { bot.emoji = "🤖" }
        bots[i] = bot
        saveBots()
        prepareWorkspace(bot)
    }

    func setAccount(_ accountID: String, for id: UUID) {
        guard var bot = bot(id), bot.accountID != accountID else { return }
        bot.accountID = accountID
        // A model name belongs to one provider; the new account starts on its own default.
        if Accounts.account(id: accountID).kind != bot.account.kind { bot.model = "" }
        update(bot)
    }

    func delete(_ id: UUID) {
        runs[id]?.stop()
        bots.removeAll { $0.id == id }
        threads[id] = nil
        store.deleteThread(id)
        saveBots()
        if selection == id { selection = bots.first?.id }
    }

    /// Starts the next turn in a fresh CLI session (with the identity, memory and recap again).
    func newSession(_ id: UUID) {
        guard var bot = bot(id), !running.contains(id) else { return }
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

    // MARK: Turns

    func send(_ text: String, to id: UUID, visible: Bool = true) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running.contains(id), let bot = bot(id) else { return }
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
            openRouterKey: account.kind == .pi ? Keychain.get(Keychain.openRouterAccount) : nil)

        if account.kind == .pi, Keychain.get(Keychain.openRouterAccount)?.isEmpty ?? true {
            append(ChatMessage(role: .error, text: "Add your OpenRouter API key in BotChu ▸ Settings first."), to: id)
            saveThread(id)
            return
        }

        let run = AgentRun(command: settings.command(for: account), invocation: invocation,
                           directory: URL(fileURLWithPath: bot.workspace, isDirectory: true))
        var parser = StreamParsers.make(for: account.kind)
        var assembler = ThreadAssembler()
        var ended = false
        let accountID = account.id

        run.onLines = { [weak self] lines in
            guard let self, self.bot(id) != nil else { return }
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
            self.running.remove(id)
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
        }

        do {
            try run.start()
            runs[id] = run
            running.insert(id)
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
        saveBots()
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

    private func saveBots() {
        try? store.saveBots(bots)
    }

    private func saveThread(_ id: UUID) {
        try? store.saveThread(thread(id), for: id)
    }

    /// The last few meaningful lines of a CLI's stderr, for an error message.
    static func lastLines(_ text: String, count: Int = 8) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(count).joined(separator: "\n")
    }
}
