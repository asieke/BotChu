import Foundation
import Network
import BotChuCore

/// Network.framework stays in the app target; the HTTP decoder and queue remain Foundation-only.
@MainActor final class RemoteQueueServer {
    private var listener: NWListener?
    private var connections: [UUID: Connection] = [:]
    var onReady: ((UInt16) -> Void)?
    var onFailure: ((NWError) -> Void)?
    let handle: @MainActor (RemoteQueueRequest) async -> RemoteQueueResponse

    init(handle: @escaping @MainActor (RemoteQueueRequest) async -> RemoteQueueResponse) { self.handle = handle }

    func start(address: String, port: UInt16) throws {
        stop()
        // Numeric addresses only: no DNS resolution or implicit wildcard if a hostname fails.
        guard IPv4Address(address) != nil || IPv6Address(address) != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready: if let port = listener.port { self.onReady?(port.rawValue) }
                case .failed(let error): self.onFailure?(error); self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] incoming in
            Task { @MainActor in
                guard let self, self.listener != nil, self.connections.count < 32 else { incoming.cancel(); return }
                let id = UUID()
                let connection = Connection(connection: incoming, handle: self.handle) { [weak self] in self?.connections[id] = nil }
                self.connections[id] = connection
                connection.start()
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel(); listener = nil
        let old = connections.values
        connections.removeAll()
        for connection in old { connection.stop() }
    }

    /// Cancellation releases the bound port asynchronously. A replacement listener waits for the
    /// cancelled state, so rapid off/on or an address change cannot race the previous listener.
    func shutdown() async {
        guard let previous = listener else { stop(); return }
        listener = nil
        let old = connections.values
        connections.removeAll()
        for connection in old { connection.stop() }
        await withCheckedContinuation { continuation in
            if case .cancelled = previous.state { continuation.resume(); return }
            previous.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.resume() }
            }
            previous.cancel()
        }
    }

    @MainActor private final class Connection {
        let connection: NWConnection
        let handle: @MainActor (RemoteQueueRequest) async -> RemoteQueueResponse
        let finished: () -> Void
        var bytes = Data()
        var timeout: Task<Void, Never>?
        var closed = false
        init(connection: NWConnection, handle: @escaping @MainActor (RemoteQueueRequest) async -> RemoteQueueResponse, finished: @escaping () -> Void) {
            self.connection = connection; self.handle = handle; self.finished = finished
        }
        func start() {
            connection.start(queue: .main)
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                if !Task.isCancelled { self?.stop() }
            }
            receive()
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    if let data { self.bytes.append(data) }
                    switch RemoteQueueHTTP.decode(self.bytes) {
                    case .incomplete:
                        if complete || error != nil { self.stop() } else { self.receive() }
                    case .invalid: self.respond(.init(401))
                    case .request(let request):
                        self.bytes = Data()
                        let response = await self.handle(request)
                        if !self.closed { self.respond(response) }
                    }
                }
            }
        }
        func respond(_ response: RemoteQueueResponse) {
            connection.send(content: RemoteQueueHTTP.encode(response), completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.stop() }
            })
        }
        func stop() {
            guard !closed else { return }
            closed = true; timeout?.cancel(); timeout = nil
            connection.cancel(); finished()
        }
    }
}
