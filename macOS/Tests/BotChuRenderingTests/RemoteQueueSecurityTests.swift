import Foundation
import Darwin
import Testing
import BotChuCore
@testable import BotChu

extension RenderingTests {
    @Test func remoteQueueRejectsBodiesBeforeReadingAndWorksWhileMainActorIsBusy() async throws {
        let fixture = try RemoteSecurityFixture()
        defer { fixture.remove() }
        var activities = 0
        let (server, port) = try await remoteSecurityServer(endpoint: fixture.endpoint, onActivity: { _ in activities += 1 })
        defer { server.stop() }
        // The socket client uses its own thread. Holding the main actor must not delay an
        // unauthorized response, even when the request withholds a declared 16 MiB body.
        let completed = DispatchSemaphore(value: 0)
        let client = Task.detached {
            defer { completed.signal() }
            let socket = try RemoteTestSocket(port: port)
            try socket.send("POST /v1/queue/reply HTTP/1.1\r\nContent-Length: 16777216\r\n\r\n")
            return try socket.response()
        }
        let responsive = await MainActor.run { completed.wait(timeout: .now() + 3) == .success }
        #expect(responsive)
        #expect(try await client.value.contains("401 Unauthorized"))
        for (headers, status) in [
            ("Authorization: Bearer fixture\r\nContent-Length: 16777217", 413),
            ("Authorization: Bearer wrong\r\nContent-Length: 16777217", 401),
            ("Authorization: Bearer fixture\r\nAuthorization: Bearer fixture", 401),
            ("Transfer-Encoding: chunked", 401)
        ] {
            let response = try await Task.detached {
                let socket = try RemoteTestSocket(port: port)
                try socket.send("POST /v1/queue/reply HTTP/1.1\r\n\(headers)\r\n\r\n")
                return try socket.response()
            }.value
            #expect(response.hasPrefix("HTTP/1.1 \(status) "))
        }
        #expect(activities == 0)
        #expect(await fixture.queue.status().lastPoll == nil)
        await server.shutdown()
    }

    @Test func remoteQueueBoundsUploadsAndRevokesPartiallySentReplies() async throws {
        let fixture = try RemoteSecurityFixture()
        defer { fixture.remove() }
        let message = try await fixture.queue.enqueue("waiting")
        let body = try JSONSerialization.data(withJSONObject: ["id": message.id.uuidString, "text": "complete reply"])
        var limits = RemoteQueueServer.Limits()
        limits.uploads = 1
        let (server, port) = try await remoteSecurityServer(endpoint: fixture.endpoint, limits: limits)
        defer { server.stop() }
        let upload = try RemoteTestSocket(port: port)
        let header = "POST /v1/queue/reply HTTP/1.1\r\nAuthorization: Bearer fixture\r\nContent-Length: \(body.count)\r\n\r\n"
        try upload.send(header)
        try await remoteSecurityEventually { await server.activeUploadCount == 1 }
        let rejected = try await Task.detached {
            let socket = try RemoteTestSocket(port: port)
            try socket.send(header)
            return try socket.response()
        }.value
        #expect(rejected.contains("429 Too Many Requests"))
        #expect(rejected.contains("Retry-After: 1"))
        fixture.endpoint.replaceToken("new-fixture")
        try upload.send(body)
        #expect(try await Task.detached { try upload.response() }.value.contains("401 Unauthorized"))
        #expect(await fixture.queue.status().pending == 1)
        try await remoteSecurityEventually { await server.activeUploadCount == 0 }
        let accepted = try await Task.detached {
            let socket = try RemoteTestSocket(port: port)
            try socket.send(header.replacingOccurrences(of: "Bearer fixture", with: "Bearer new-fixture"))
            try socket.send(body)
            return try socket.response()
        }.value
        #expect(accepted.contains("200 OK"))
        #expect(await fixture.queue.snapshot().messages.last?.text == "complete reply")
        await server.shutdown()
    }

    @Test func remoteQueueSlowConnectionsExpireAndReleaseCapacity() async throws {
        let fixture = try RemoteSecurityFixture()
        defer { fixture.remove() }
        var limits = RemoteQueueServer.Limits()
        limits.connections = 1; limits.headerSeconds = 0.3; limits.requestSeconds = 0.6
        let (server, port) = try await remoteSecurityServer(endpoint: fixture.endpoint, limits: limits)
        defer { server.stop() }
        let slowHeader = try RemoteTestSocket(port: port)
        try slowHeader.send("GET /v1/health HTTP/1.1\r\n")
        try await remoteSecurityEventually { await server.activeConnectionCount == 1 }
        let excess = try RemoteTestSocket(port: port)
        #expect(try await Task.detached { try excess.response() }.value.isEmpty)
        #expect(try await Task.detached { try slowHeader.response() }.value.isEmpty)
        try await remoteSecurityEventually { await server.activeConnectionCount == 0 }
        let slowBody = try RemoteTestSocket(port: port)
        try slowBody.send("POST /v1/queue/reply HTTP/1.1\r\nAuthorization: Bearer fixture\r\nContent-Length: 100\r\n\r\n{")
        try await remoteSecurityEventually { await server.activeUploadCount == 1 }
        #expect(try await Task.detached { try slowBody.response() }.value.isEmpty)
        try await remoteSecurityEventually {
            let uploads = await server.activeUploadCount
            let connections = await server.activeConnectionCount
            return uploads == 0 && connections == 0
        }
        let recovered = try await Task.detached {
            let socket = try RemoteTestSocket(port: port)
            try socket.send("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer fixture\r\n\r\n")
            return try socket.response()
        }.value
        #expect(recovered.contains("200 OK"))
        await server.shutdown()
    }
}

@MainActor private func remoteSecurityServer(
    endpoint: RemoteQueueEndpoint, limits: RemoteQueueServer.Limits = .init(),
    onActivity: @escaping @MainActor @Sendable (RemoteQueueServer.Activity) async -> Void = { _ in }
) async throws -> (RemoteQueueServer, UInt16) {
    var readyPort: UInt16?
    let server = RemoteQueueServer(endpoint: endpoint, limits: limits, onActivity: onActivity, onReady: { readyPort = $0 })
    try await server.start(address: "127.0.0.1", port: 0)
    try await remoteSecurityEventually { readyPort != nil }
    return (server, try #require(readyPort))
}

private struct RemoteSecurityFixture {
    let root: URL
    let queue: RemoteQueue
    let endpoint: RemoteQueueEndpoint
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-remote-security-\(UUID())")
        queue = try RemoteQueue(botID: UUID(), file: root.appendingPathComponent("queue.json"))
        endpoint = RemoteQueueEndpoint(queue: queue, token: "fixture")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func remoteSecurityEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await condition())
}

/// Blocking socket operations run on a detached task except tiny loopback writes. The immutable
/// descriptor is closed only on deinit after all tasks holding this object have completed.
private final class RemoteTestSocket: @unchecked Sendable {
    private let descriptor: Int32
    init(port: UInt16) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(descriptor); throw CocoaError(.fileReadUnknown) }
        self.descriptor = descriptor
    }
    deinit { Darwin.close(descriptor) }
    func send(_ text: String) throws { try send(Data(text.utf8)) }
    func send(_ data: Data) throws {
        let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!, $0.count, 0) }
        guard count == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
    func response() throws -> String {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while result.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 || (count < 0 && errno == ECONNRESET) { break }
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            result.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: result, as: UTF8.self)
    }
}
