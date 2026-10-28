import Foundation
import Observation
import BotChuCore

/// The Telegram gateway (`TelegramGateway`) as it runs in the app, from Settings ▸ Telegram. It
/// runs while it is on and the Keychain has a token, and starts again when either, or the allowed
/// chats, change. A chat's text goes into its bot's Home (or the one it chose with `@`, #114)
/// through that conversation's queue, as the owner's own messages do, so it resumes the Home's CLI
/// session and waits behind a turn under way; the gateway sends back what the turn said. `/task`
/// makes a task of its own for the bot, as New Task and `botchu-task create` do.
@MainActor @Observable
final class TelegramBridge {
    enum State: Equatable {
        case off
        /// On, but no token is saved.
        case needsToken
        case running(TelegramGateway.Status)
    }

    private(set) var state = State.off
    /// Chats refused since BotChu started, newest first, for Settings to offer to allow. Never saved.
    private(set) var refused: [TelegramRefusal] = []
    /// Where the token comes from and what carries requests: the Keychain and URLSession, or
    /// stand-ins in tests.
    @ObservationIgnored var readToken: @MainActor () -> String? = { Keychain.get(Keychain.telegramAccount) }
    @ObservationIgnored var transport: any TelegramTransport = URLSessionTelegramTransport()
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private var run: Task<Void, Never>?
    /// Which gateway is the current one: one already replaced doesn't change the status.
    @ObservationIgnored private var generation = 0

    init(model: AppModel, stateURL: URL) {
        self.model = model
        self.stateURL = stateURL
        observeSettings()
        restart()
    }

    /// Starts the gateway for the settings and token as they are now, once the one running has
    /// stopped and saved where it was.
    func restart() {
        let previous = run
        previous?.cancel()
        // Keep the cancelled run as a barrier even while disabled or missing a token: a quick
        // off/on must still wait for its final checkpoint before loading the replacement state.
        generation += 1
        guard let settings = model?.settings, settings.telegramEnabled else {
            state = .off
            return
        }
        let token = (readToken() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            state = .needsToken
            return
        }
        state = .running(.connecting)
        let chats = settings.telegramChats
        let link = connection()
        let stateURL = stateURL
        let transport = transport
        run = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            let gateway = TelegramGateway(token: token, chats: chats, app: link,
                                          stateURL: stateURL, transport: transport)
            await gateway.run()
        }
    }

    /// Captures this run's generation; callbacks from it are invalid once restart() is called.
    func connection() -> TelegramLink { TelegramLink(bridge: self, generation: generation) }

    /// What Settings says about it.
    var summary: String {
        switch state {
        case .off: "Off."
        case .needsToken: "Save a bot token from BotFather to connect."
        case .running(.connecting): "Connecting…"
        case .running(.connected(let name)):
            model?.settings.telegramChats.isEmpty == false
                ? "Connected as \(name)."
                : "Connected as \(name). Message it from Telegram, then allow your chat below."
        case .running(.retrying(let reason, let seconds)): "\(reason) Trying again in \(seconds) s."
        case .running(.stopped(let reason)): reason
        }
    }

    /// Lets a refused private chat reach a bot: the one selected, else the first.
    func allow(_ refusal: TelegramRefusal) {
        guard let model, refusal.isPrivate else { return }
        refused.removeAll { $0.id == refusal.id }
        guard !model.settings.telegramChats.contains(where: { $0.id == refusal.id }) else { return }
        model.settings.telegramChats.append(TelegramChat(id: refusal.id, botID: model.selection ?? model.bots.first?.id, label: refusal.name))
    }

    private func observeSettings() {
        withObservationTracking {
            _ = model?.settings.telegramEnabled
            _ = model?.settings.telegramChats
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.restart()
                self?.observeSettings()
            }
        }
    }

    // MARK: What the gateway asks

    fileprivate func name(of botID: UUID) -> String? { model?.bot(botID)?.name }

    /// What `@` and `#` choose from, as BotChu's message box completes them (#84): every bot, and
    /// the saved Projects catalog, synced in the background when none is saved yet.
    fileprivate func directory() -> TelegramDirectory {
        guard let model else { return TelegramDirectory() }
        if model.repositories == nil { Task { await model.loadProjects() } }
        return TelegramDirectory(bots: model.bots.map(BotRosterEntry.init), projects: model.repositories == nil ? nil : model.projectCatalog,
                                 login: model.projectsLogin)
    }

    fileprivate func authorization(for chat: Int64, botID: UUID?, generation: Int) -> TelegramAuthorization {
        guard !Task.isCancelled, generation == self.generation, let model, model.settings.telegramEnabled else { return .stopped }
        if case .running(.stopped) = state { return .stopped }
        guard let allowed = model.settings.telegramChats.first(where: { $0.id == chat }), allowed.botID == botID else { return .revoked }
        return .allowed
    }

    /// Into the bot's Home (never a task), through its queue, under the message's own ID, once a
    /// saved queue holds it (so Telegram's offset moves on only past a message that is kept).
    /// `mapped` is the chat's bot in Settings, which must still be its bot.
    fileprivate func deliver(_ text: String, references: [MessageReference], id: UUID, to botID: UUID, from chat: Int64, mapped: UUID?,
                             generation: Int) async -> TelegramDelivery {
        let target = ChatTarget.home(botID)
        // A repeated message is recognized in Home's whole history and recovered queue, read first
        // when Home isn't in memory (#109).
        let history = await model?.loadedThread(target)
        // No suspension between the final authorization check and AppModel.send. Settings may
        // have changed before observation has had a chance to cancel/restart this gateway.
        guard case .allowed = authorization(for: chat, botID: mapped, generation: generation) else { return .discarded }
        guard let model, let bot = model.bot(botID) else { return .unavailable }
        let queued = { model.messageQueues[target]?.messages.contains { $0.id == id } == true }
        if queued() || history?.contains(where: { $0.id == id }) == true { return .duplicate }
        guard await model.sendAccepted(text, to: target, id: id, references: references) else {
            return .failed("it couldn't be saved in \(bot.name)'s queue.")
        }
        // Still waiting in the queue, behind a turn: not one starting with it.
        let waiting = model.messageQueues[target]?.pending.contains { $0.id == id } == true
        return .queued(busy: waiting && model.isRunning(target))
    }

    /// A task of its own for the bot, in the repository's checkout, as New Task makes one: in the
    /// left sidebar under that bot, with its own conversation and session, never a sub-agent run of
    /// another conversation. Its ID is the Telegram message's, so a request Telegram sends again
    /// finds the task it made.
    fileprivate func startTask(_ brief: String, in repo: String, id: UUID, for botID: UUID, from chat: Int64, mapped: UUID?,
                               generation: Int) async -> TelegramTaskStart {
        guard case .allowed = authorization(for: chat, botID: mapped, generation: generation) else { return .discarded }
        guard let model, model.bot(botID) != nil else { return .unavailable }
        if let task = model.task(id, of: botID) { return .duplicate(title: task.title) }
        let root = model.settings.expandedReposRoot
        // Off the main thread: the first look into ~/Desktop or ~/Documents waits on macOS's question.
        let checkouts = await Task.detached { Repositories.scan(root: root) }.value
        await model.loadRepositories()
        var task: BotTask
        do {
            guard let owner = model.bot(botID) else { return .unavailable }
            task = try await model.plannedTask(TaskRequest(repo: repo, task: brief), for: owner, checkouts: checkouts, origin: .owner)
        } catch {
            return .failed((error as? TaskRequest.Problem)?.message ?? error.localizedDescription)
        }
        task.id = id
        // No suspension between the final checks and startTask.
        guard case .allowed = authorization(for: chat, botID: mapped, generation: generation) else { return .discarded }
        guard model.bot(botID) != nil else { return .unavailable }
        if let made = model.task(id, of: botID) { return .duplicate(title: made.title) }
        let failure: String? = await withCheckedContinuation { continuation in
            model.startTask(task, for: botID, show: false) { continuation.resume(returning: $0?.localizedDescription) }
        }
        return .started(title: task.title, unsaved: failure.map { "Its record couldn't be saved: \($0)" })
    }

    fileprivate func progress(of id: UUID, for botID: UUID) async -> TelegramProgress {
        let target = ChatTarget.home(botID)
        // From Home's whole history, never a thread that isn't read yet.
        guard let thread = await model?.loadedThread(target), let model, let bot = model.bot(botID) else { return .gone(TelegramReply.unavailable) }
        return .of(id, thread: thread, queue: model.messageQueues[target], running: model.isRunning(target), botName: bot.name)
    }

    fileprivate func fullReply(of id: UUID, for botID: UUID) async -> String? {
        guard let thread = await model?.loadedThread(.home(botID)), let bot = model?.bot(botID) else { return nil }
        return TelegramReply.full(after: id, in: thread, botName: bot.name)
    }

    fileprivate func replyFailed(_ id: UUID, for botID: UUID, reason: String, generation: Int) {
        guard !Task.isCancelled, generation == self.generation, let model, model.settings.telegramEnabled,
              model.bot(botID) != nil else { return }
        model.note("Couldn't send the reply to Telegram. \(reason)", in: .home(botID))
    }

    fileprivate func changed(_ status: TelegramGateway.Status, generation: Int) {
        guard !Task.isCancelled, generation == self.generation, run != nil, model?.settings.telegramEnabled == true else { return }
        if case .running(.stopped) = state { return }
        state = .running(status)
    }

    fileprivate func refuse(_ chat: TelegramRefusal, generation: Int) {
        guard !Task.isCancelled, generation == self.generation, model?.settings.telegramEnabled == true else { return }
        refused.removeAll { $0.id == chat.id }
        refused.insert(chat, at: 0)
        if refused.count > 5 { refused.removeLast(refused.count - 5) }
    }
}

/// What one gateway reaches the app through, without keeping it alive.
@MainActor final class TelegramLink: TelegramApp {
    private weak var bridge: TelegramBridge?
    private let generation: Int

    init(bridge: TelegramBridge, generation: Int) {
        self.bridge = bridge
        self.generation = generation
    }

    func name(of botID: UUID) -> String? { bridge?.name(of: botID) }

    func authorization(for chat: Int64, botID: UUID?) -> TelegramAuthorization {
        bridge?.authorization(for: chat, botID: botID, generation: generation) ?? .stopped
    }

    func directory() -> TelegramDirectory { bridge?.directory() ?? TelegramDirectory() }

    func deliver(_ text: String, references: [MessageReference], id: UUID, to botID: UUID, from chat: Int64, mapped: UUID?) async -> TelegramDelivery {
        await bridge?.deliver(text, references: references, id: id, to: botID, from: chat, mapped: mapped, generation: generation) ?? .discarded
    }

    func startTask(_ brief: String, in repo: String, id: UUID, for botID: UUID, from chat: Int64, mapped: UUID?) async -> TelegramTaskStart {
        await bridge?.startTask(brief, in: repo, id: id, for: botID, from: chat, mapped: mapped, generation: generation) ?? .discarded
    }

    func progress(of id: UUID, for botID: UUID) async -> TelegramProgress {
        await bridge?.progress(of: id, for: botID) ?? .queued(paused: false)
    }

    func fullReply(of id: UUID, for botID: UUID) async -> String? {
        await bridge?.fullReply(of: id, for: botID)
    }

    func replyFailed(_ id: UUID, for botID: UUID, reason: String) {
        bridge?.replyFailed(id, for: botID, reason: reason, generation: generation)
    }
    func gatewayChanged(_ status: TelegramGateway.Status) { bridge?.changed(status, generation: generation) }
    func refused(_ chat: TelegramRefusal) { bridge?.refuse(chat, generation: generation) }
}
