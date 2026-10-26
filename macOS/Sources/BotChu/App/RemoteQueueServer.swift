import Foundation
import Network
import BotChuCore

/// Socket framing, authentication and JSON work run off the main actor. Only successful queue
/// activity crosses back to the UI; rejected traffic never touches conversation storage.
actor RemoteQueueServer {
    enum Activity: Sendable { case poll, reply }
    struct Limits: Sendable {
        var connections = 32
        var uploads = 2
        var burst = 20
        var perSecond = 2.0
        var headerSeconds = 5.0
        var requestSeconds = 30.0
    }
    private static let network = DispatchQueue(label: "local.BotChu.remote-queue", qos: .utility)
    private let endpoint: RemoteQueueEndpoint
    private let limits: Limits
    private let onActivity: @MainActor @Sendable (Activity) async -> Void
    private let onReady: @MainActor @Sendable (UInt16) -> Void
    private let onFailure: @MainActor @Sendable (NWError) -> Void
    private var listener: NWListener?
    private var connections: [UUID: Connection] = [:]
    private var uploads = Set<UUID>()
    private var rate: RemoteQueueRateLimiter
    var activeUploadCount: Int { uploads.count }
    var activeConnectionCount: Int { connections.count }

    init(endpoint: RemoteQueueEndpoint, limits: Limits = Limits(),
         onActivity: @escaping @MainActor @Sendable (Activity) async -> Void = { _ in },
         onReady: @escaping @MainActor @Sendable (UInt16) -> Void = { _ in },
         onFailure: @escaping @MainActor @Sendable (NWError) -> Void = { _ in }) {
        self.endpoint = endpoint; self.limits = limits
        self.onActivity = onActivity; self.onReady = onReady; self.onFailure = onFailure
        rate = RemoteQueueRateLimiter(burst: limits.burst, perSecond: limits.perSecond, now: ProcessInfo.processInfo.systemUptime)
    }

    func start(address: String, port: UInt16) async throws {
        await shutdown()
        // Numeric addresses only: no DNS resolution or implicit wildcard on a failed lookup.
        guard IPv4Address(address) != nil || IPv6Address(address) != nil,
              let port = NWEndpoint.Port(rawValue: port) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let listener else { return }
            Task { await self?.stateChanged(state, listener: listener) }
        }
        listener.newConnectionHandler = { [weak self, weak listener] incoming in
            Task {
                guard let self, let listener else { incoming.cancel(); return }
                await self.accept(incoming, listener: listener)
            }
        }
        listener.start(queue: Self.network)
    }

    private func stateChanged(_ state: NWListener.State, listener: NWListener) async {
        guard self.listener === listener else { return }
        switch state {
        case .ready: if let port = listener.port { await onReady(port.rawValue) }
        case .failed(let error): await onFailure(error); await shutdown()
        default: break
        }
    }

    private func accept(_ incoming: NWConnection, listener: NWListener) async {
        guard self.listener === listener, connections.count < limits.connections else { incoming.cancel(); return }
        let id = UUID()
        let retry = rate.admit(at: ProcessInfo.processInfo.systemUptime)
        let connection = Connection(id: id, connection: incoming, server: self, endpoint: endpoint,
                                    limits: limits, onActivity: onActivity)
        connections[id] = connection
        await connection.start(rejection: retry.map { .init(429, retryAfter: $0) })
    }

    private func admitUpload(_ id: UUID) -> Bool {
        guard connections[id] != nil, uploads.count < limits.uploads else { return false }
        uploads.insert(id)
        return true
    }

    private func finished(_ id: UUID) { connections[id] = nil; uploads.remove(id) }

    nonisolated func stop() { Task { await shutdown() } }

    /// Wait for port release before a replacement listener binds during a rapid off/on change.
    func shutdown() async {
        let previous = listener
        listener = nil
        let old = Array(connections.values)
        connections.removeAll(); uploads.removeAll()
        for connection in old { await connection.stop() }
        guard let previous else { return }
        await withCheckedContinuation { continuation in
            if case .cancelled = previous.state { continuation.resume(); return }
            previous.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.resume() }
            }
            previous.cancel()
        }
    }

    private actor Connection {
        let id: UUID
        let connection: NWConnection
        weak var server: RemoteQueueServer?
        let endpoint: RemoteQueueEndpoint
        let limits: Limits
        let onActivity: @MainActor @Sendable (Activity) async -> Void
        var bytes = Data()
        var header: RemoteQueueHTTP.Header?
        var timeout: Task<Void, Never>?
        var deadline = 0.0
        var closed = false
        var processing = false

        init(id: UUID, connection: NWConnection, server: RemoteQueueServer, endpoint: RemoteQueueEndpoint,
             limits: Limits, onActivity: @escaping @MainActor @Sendable (Activity) async -> Void) {
            self.id = id; self.connection = connection; self.server = server; self.endpoint = endpoint
            self.limits = limits; self.onActivity = onActivity
        }

        func start(rejection: RemoteQueueResponse?) {
            connection.start(queue: RemoteQueueServer.network)
            deadline = ProcessInfo.processInfo.systemUptime + limits.requestSeconds
            setTimeout(seconds: min(limits.headerSeconds, limits.requestSeconds))
            if let rejection { respond(rejection) } else { receive() }
        }

        private func setTimeout(seconds: Double) {
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                if !Task.isCancelled { await self?.stop() }
            }
        }

        private func receive() {
            let remaining = header.map { $0.contentLength - bytes.count } ?? (RemoteQueueHTTP.maximumHeader - bytes.count)
            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, min(64 * 1024, remaining))) { [weak self] data, _, complete, error in
                Task { await self?.received(data, ended: complete || error != nil) }
            }
        }

        private func received(_ data: Data?, ended: Bool) async {
            guard !closed else { return }
            if let data { bytes.append(data) }
            if header == nil {
                switch RemoteQueueHTTP.decodeHeader(bytes) {
                case .incomplete:
                    if ended { await stop() } else { receive() }
                    return
                case .invalid: respond(.init(401)); return
                case .header(let parsed):
                    // At most 16 KiB has been read. Never read a declared body before this check.
                    guard endpoint.isAuthorized(parsed.authorization) else { respond(.init(401)); return }
                    guard parsed.contentLength <= RemoteQueueHTTP.maximumBody else { respond(.init(413)); return }
                    switch (parsed.method, parsed.path) {
                    case ("GET", "/v1/health"), ("GET", "/v1/queue/next"):
                        guard parsed.contentLength == 0 else { respond(.init(400)); return }
                    case ("GET", let path) where path.hasPrefix(RemoteQueueEndpoint.filesPath):
                        guard parsed.contentLength == 0 else { respond(.init(400)); return }
                    case ("POST", "/v1/queue/reply"):
                        guard await server?.admitUpload(id) == true else { if !closed { respond(.init(429, retryAfter: 1)) }; return }
                        guard !closed else { await server?.finished(id); return }
                    default: respond(.init(404)); return
                    }
                    header = parsed
                    bytes = Data(bytes.dropFirst(parsed.byteCount).prefix(parsed.contentLength))
                    setTimeout(seconds: deadline - ProcessInfo.processInfo.systemUptime)
                }
            }
            guard let header, !closed else { return }
            guard bytes.count >= header.contentLength else {
                if ended { await stop() } else { receive() }
                return
            }
            let request = RemoteQueueRequest(method: header.method, path: header.path, authorization: header.authorization, body: bytes)
            bytes = Data()
            processing = true
            let response = await endpoint.handle(request)
            // A durable reply still belongs in Home if the client disconnects before the ack.
            if response.status == 200, header.path == "/v1/queue/reply" { await onActivity(.reply) }
            if (response.status == 200 || response.status == 204), header.path == "/v1/queue/next" { await onActivity(.poll) }
            processing = false
            if closed { await server?.finished(id) } else { respond(response) }
        }

        private func respond(_ response: RemoteQueueResponse) {
            connection.send(content: RemoteQueueHTTP.encode(response), completion: .contentProcessed { [weak self] _ in
                Task { await self?.stop() }
            })
        }

        func stop() async {
            guard !closed else { return }
            closed = true; timeout?.cancel(); timeout = nil; bytes = Data()
            connection.cancel()
            // A timed-out socket must not free an upload slot while its decoded request still
            // retains the body or awaits persistence. This also bounds queued endpoint work.
            if !processing { await server?.finished(id) }
        }
    }
}
