import Foundation
import Observation
import BotChuCore

/// The Telegram gateway (`TelegramGateway`) as it runs in the app, from Settings ▸ Telegram. It
/// runs while it is on and the Keychain has a token, and starts again when either, or the allowed
/// chats, change. A chat's text goes into its bot's Home through that conversation's queue, as the
/// owner's own messages do, so it resumes the Home's CLI session and waits behind a turn under
/// way; the gateway sends back what the turn said.
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
        run = nil
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
        let gateway = TelegramGateway(token: token, chats: settings.telegramChats, app: Link(bridge: self, generation: generation),
                                      stateURL: stateURL, transport: transport)
        run = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await gateway.run()
        }
    }

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

    /// Into the bot's Home (never a task), through its queue, under the message's own ID.
    fileprivate func deliver(_ text: String, id: UUID, to botID: UUID) -> TelegramDelivery {
        guard let model, let bot = model.bot(botID) else { return .unavailable }
        let target = ChatTarget.home(botID)
        let queued = { model.messageQueues[target]?.messages.contains { $0.id == id } == true }
        if queued() || model.thread(target).contains(where: { $0.id == id }) { return .duplicate }
        guard model.send(text, to: target, id: id) else { return .failed("it couldn't be saved in \(bot.name)'s queue.") }
        return .queued(busy: queued() && model.isRunning(target))
    }

    fileprivate func progress(of id: UUID, for botID: UUID) -> TelegramProgress {
        guard let model, let bot = model.bot(botID) else { return .gone(TelegramReply.unavailable) }
        let target = ChatTarget.home(botID)
        return .of(id, thread: model.thread(target), queue: model.messageQueues[target], running: model.isRunning(target), botName: bot.name)
    }

    fileprivate func replyFailed(_ id: UUID, for botID: UUID, reason: String) {
        guard let model, model.bot(botID) != nil else { return }
        model.note("Couldn't send the reply to Telegram. \(reason)", in: .home(botID))
    }

    fileprivate func changed(_ status: TelegramGateway.Status, generation: Int) {
        guard generation == self.generation, run != nil else { return }
        state = .running(status)
    }

    fileprivate func refuse(_ chat: TelegramRefusal) {
        refused.removeAll { $0.id == chat.id }
        refused.insert(chat, at: 0)
        if refused.count > 5 { refused.removeLast(refused.count - 5) }
    }
}

/// What one gateway reaches the app through, without keeping it alive.
private final class Link: TelegramApp, @unchecked Sendable {
    private weak var bridge: TelegramBridge?
    private let generation: Int

    init(bridge: TelegramBridge, generation: Int) {
        self.bridge = bridge
        self.generation = generation
    }

    func name(of botID: UUID) async -> String? { await bridge?.name(of: botID) }

    func deliver(_ text: String, id: UUID, to botID: UUID) async -> TelegramDelivery {
        await bridge?.deliver(text, id: id, to: botID) ?? .failed("BotChu is closing.")
    }

    func progress(of id: UUID, for botID: UUID) async -> TelegramProgress {
        await bridge?.progress(of: id, for: botID) ?? .queued(paused: false)
    }

    func replyFailed(_ id: UUID, for botID: UUID, reason: String) async { await bridge?.replyFailed(id, for: botID, reason: reason) }
    func gatewayChanged(_ status: TelegramGateway.Status) async { await bridge?.changed(status, generation: generation) }
    func refused(_ chat: TelegramRefusal) async { await bridge?.refuse(chat) }
}
