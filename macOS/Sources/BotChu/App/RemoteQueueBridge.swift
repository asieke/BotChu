import Foundation
import Observation
import Security
import BotChuCore

@MainActor @Observable final class RemoteQueueBridge {
    private weak var model: AppModel?
    private var botID: UUID?
    private var queue: RemoteQueue?
    private var server: RemoteQueueServer?
    private var endpoint: RemoteQueueEndpoint?
    private var binding: String?
    private var starting = false
    private var lifecycle: Task<Void, Never>?
    private var generation = 0
    private var appliedRevision = -1
    private var stopped = false
    private var clock: Task<Void, Never>?
    private(set) var pending = 0
    private(set) var lastPoll: Date?
    private(set) var now = Date()
    private(set) var summary = "Off."
    private(set) var servingURL: String?
    private(set) var problem: String?
    @ObservationIgnored var readToken: () -> String? = { Keychain.get(Keychain.remoteQueueAccount) }
    @ObservationIgnored var saveToken: (String) -> Bool = { value in
        Keychain.setChecked(value, for: Keychain.remoteQueueAccount)
    }

    init(model: AppModel) {
        self.model = model
        reloadBot()
        observeSettings()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.now = Date()
            }
        }
    }

    var online: Bool { servingURL != nil && lastPoll.map { (0..<120).contains(now.timeIntervalSince($0)) } == true }
    func isWorking(_ id: UUID) -> Bool { botID == id && pending > 0 }
    var presence: String { online ? "Online" : "Offline" }

    func reloadBot() {
        let bot = model?.bots.first(where: \.isRemoteQueue)
        if bot?.id != botID {
            botID = bot?.id; queue = nil; pending = 0; lastPoll = nil; appliedRevision = -1
            if let bot {
                do { queue = try RemoteQueue(botID: bot.id, file: BotHome(workspace: bot.persistencePath).url.appendingPathComponent("remote-queue.json")) }
                catch { problem = "The remote queue couldn't be read. Its saved file has been kept." }
            }
        }
        Task { [weak self] in await self?.reconcile() }
        restart()
    }

    @discardableResult func regenerateToken() -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            problem = "Couldn't generate a secure token."; return false
        }
        let token = Data(bytes).base64EncodedString()
        guard saveToken(token) else { problem = "Couldn't save the token in your Keychain."; return false }
        restart()
        return true
    }

    func restart() {
        guard !stopped, let model else { return }
        var nextBinding: String?
        var nextEndpoint: RemoteQueueEndpoint?
        let address = model.settings.remoteQueueAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = UInt16(exactly: model.settings.remoteQueuePort)
        if !model.settings.remoteQueueEnabled {
            summary = "Off."
        } else if let queue, let botID {
            guard let port, port > 0 else { summary = "Choose a port from 1 to 65535."; stopListening(); return }
            var token = readToken() ?? ""
            if token.isEmpty {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess,
                      saveToken(Data(bytes).base64EncodedString()) else {
                    problem = "Couldn't save a secure token in your Keychain."; summary = problem!; stopListening(); return
                }
                token = readToken() ?? ""
            }
            guard !token.isEmpty else { summary = "Token unavailable."; stopListening(); return }
            nextBinding = "\(botID):\(address):\(port)"
            if let endpoint, endpoint.queue === queue {
                endpoint.replaceToken(token)
                nextEndpoint = endpoint
            } else {
                nextEndpoint = RemoteQueueEndpoint(queue: queue, token: token)
            }
        } else {
            summary = problem ?? "Create a remote queue bot first."
        }
        if endpoint !== nextEndpoint { endpoint?.replaceToken("") }
        endpoint = nextEndpoint
        // A token change replaces the credential synchronously; it doesn't interrupt the
        // listener. An observed settings change repeated by a caller is also a no-op here.
        if nextBinding == binding, server != nil || starting { return }
        generation += 1
        let expected = generation
        let previous = lifecycle, oldServer = server
        server = nil; servingURL = nil; binding = nextBinding; starting = nextBinding != nil
        if starting { summary = "Starting…" }
        lifecycle = Task { [weak self] in
            await previous?.value
            await oldServer?.shutdown()
            guard let self, !self.stopped, self.generation == expected else { return }
            self.starting = false
            guard nextBinding != nil, let port, let endpoint = self.endpoint, self.model?.settings.remoteQueueEnabled == true else { return }
            let server = RemoteQueueServer(endpoint: endpoint, onActivity: { [weak self] activity in
                guard let self, !self.stopped, self.generation == expected, self.model?.settings.remoteQueueEnabled == true else { return }
                switch activity {
                case .reply: await self.reconcile()
                case .poll:
                    let status = await endpoint.queue.status()
                    guard self.generation == expected else { return }
                    self.pending = status.pending; self.lastPoll = status.lastPoll; self.now = Date()
                }
            }, onReady: { [weak self] port in
                guard let self, self.generation == expected else { return }
                self.servingURL = "http://\(address.contains(":") ? "[\(address)]" : address):\(port)"
                self.summary = "Listening."
            }, onFailure: { [weak self] error in
                guard let self, self.generation == expected else { return }
                self.servingURL = nil; self.server = nil; self.binding = nil
                // NWError contains only a transport error code, never headers or message bodies.
                self.summary = "Couldn't listen (\(error)). Check the address and whether the port is in use."
            })
            do {
                try await server.start(address: address, port: port)
                guard self.generation == expected, !self.stopped else { await server.shutdown(); return }
                self.server = server
            } catch { self.binding = nil; self.summary = "Enter a numeric local IP address and an available port." }
        }
    }

    private func stopListening() {
        generation += 1
        let oldServer = server, previous = lifecycle
        endpoint?.replaceToken("")
        server = nil; servingURL = nil; endpoint = nil; binding = nil; starting = false
        lifecycle = Task { await previous?.value; await oldServer?.shutdown() }
    }

    func stop() {
        stopped = true; generation += 1
        endpoint?.replaceToken("")
        server?.stop(); server = nil; servingURL = nil; endpoint = nil
        clock?.cancel(); clock = nil
    }

    func enqueue(_ text: String, id: UUID, for botID: UUID, accepted: (@MainActor @Sendable (Bool) -> Void)?) -> Bool {
        guard !stopped, self.botID == botID, let queue else { problem = "The remote queue isn't available."; return false }
        Task { [weak self] in
            guard let self, self.botID == botID, let model = self.model else { accepted?(false); return }
            do {
                try await queue.enqueue(text, id: id)
                self.problem = nil
                await self.reconcile()
                accepted?(true)
            } catch {
                let message = (error as? RemoteQueue.Failure) == .full
                    ? "The remote queue is full (10 waiting messages). Wait for a reply before sending another."
                    : "Couldn't save this message in the remote queue. Your draft has been kept."
                self.problem = message
                model.note(message, in: .home(botID))
                accepted?(false)
            }
        }
        return true
    }

    /// Journal first, transcript second. Stable IDs fill any crash gap without duplicates. Home's
    /// normal transcript persistence stays ordered with its other changes by ConversationStorage.
    func reconcile() async {
        guard let id = botID, let queue, let model else { return }
        let target = ChatTarget.home(id)
        _ = await model.loadedThread(target)
        let snapshot = await queue.snapshot()
        guard botID == id, model.bot(id) != nil, snapshot.messages.count >= appliedRevision else { return }
        appliedRevision = snapshot.messages.count
        pending = snapshot.pending
        if let poll = snapshot.lastPoll, poll > (lastPoll ?? .distantPast) { lastPoll = poll }
        now = Date()
        let existing = Set(model.thread(target).map(\.id))
        let added = snapshot.messages.filter { !existing.contains($0.id) }
        for message in added { model.append(message, to: target) }
        if added.contains(where: { $0.role == .assistant || $0.role == .error }), !model.isShown(target) { model.unread.insert(target) }
        model.runStates[target] = snapshot.firstPending.map { RunState(startedAt: $0.date, hasOutput: true) }
        if !added.isEmpty { model.saveThread(target) }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = model?.settings.remoteQueueEnabled
            _ = model?.settings.remoteQueueAddress
            _ = model?.settings.remoteQueuePort
        } onChange: { [weak self] in
            Task { @MainActor in self?.restart(); self?.observeSettings() }
        }
    }
}
