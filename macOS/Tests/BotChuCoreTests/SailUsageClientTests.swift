import Foundation
import Testing
@testable import BotChuCore

/// Sail's Usage API over real HTTP, against a loopback server answering as Sail's docs say
/// (`GET /v2/usage/summary?range=30d`): the address, the request's key, and how its answers read.
/// No test here reaches Sail, and the key is a dummy.
@Suite(.serialized) struct SailUsageClientTests {
    @Test func theSummaryIsReadWithTheKeysOwnBearer() async throws {
        let answer = #"{"object":"usage.summary","has_metronome_customer":true,"range":"30d","balance":5498.0166062,"# +
            #""period_spend":1.9833938,"burn_rate":0.2833419714285714,"days_remaining":null,"empty":false,"# +
            #""effective_range":"7d","plan_limited":true}"#
        let server = try SailUsageServer(status: 200, body: answer)
        defer { server.stop() }
        let reading = try await SailUsage.read(key: "sail-secret-key", url: server.url)
        let request = try #require(server.requests.first)
        #expect(request.path == "/v2/usage/summary")
        #expect(request.query == "range=30d", "The range asked for, as the docs' example does")
        #expect(request.authorization == "Bearer sail-secret-key")
        #expect(reading.balance?.creditText == "$54.98")
        #expect(reading.note == "Your Sail plan limits usage history to 7d.")
        #expect(!String(describing: reading).contains("sail-secret-key"), "Never the key in a reading")
    }

    @Test func answersSayWhatToDoWithoutLeakingTheBody() async throws {
        func failure(_ status: Int, _ body: String, headers: [String: String] = [:]) async -> UsageFailure? {
            let server = (try? SailUsageServer(status: status, body: body, headers: headers)) ?? nil
            defer { server?.stop() }
            guard let server else { return nil }
            do {
                _ = try await SailUsage.read(key: "sail-secret-key", url: server.url)
                return nil
            } catch {
                return error as? UsageFailure
            }
        }
        let refused = await failure(401, #"{"detail":"key sk_live_secret is not valid"}"#)
        #expect(refused?.message.contains("Settings ▸ Sail") == true)
        #expect(refused?.message.contains("sk_live_secret") != true, "Sail's own words never reach the UI")
        let limited = await failure(429, "slow down", headers: ["Retry-After": "42"])
        #expect(limited?.retryAfter == 300, "At least five minutes, as OpenRouter's limit is")
        let more = await failure(429, "slow down", headers: ["Retry-After": "900"])
        #expect(more?.retryAfter == 900)
        let failed = await failure(500, "boom")
        #expect(failed?.message.contains("HTTP 500") == true)
        // A 200 that isn't a summary is no reading, not a zero balance.
        let unreadable = await failure(200, "<html>Bad gateway</html>")
        #expect(unreadable != nil)
    }

    @Test func productionUsesTheProvidersHTTPSAddress() {
        #expect(SailUsage.url == Sail.usageURL, "Production always uses the provider endpoint")
        #expect(Sail.usageURL.absoluteString == "https://api.sailresearch.com/v2/usage/summary")
        #expect(Sail.usageURL.host() == Sail.apiBase.host(), "The same host as the API")
    }
}

/// A loopback server that answers one request and keeps what it was sent.
private final class SailUsageServer: @unchecked Sendable {
    struct Sent {
        var path: String
        var query: String
        var authorization: String?
    }

    private var listener: Int32
    private let lock = NSLock()
    private var sent: [Sent] = []
    private let answer: Data
    private let status: Int
    private let extraHeaders: [String: String]
    private var thread: Thread?

    var port: UInt16 = 0
    var url: URL { URL(string: "http://127.0.0.1:\(port)/v2/usage/summary")! }

    var requests: [Sent] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    init(status: Int, body: String, headers: [String: String] = [:]) throws {
        listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CocoaError(.fileReadUnknown) }
        self.status = status
        self.answer = Data(body.utf8)
        self.extraHeaders = headers
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(listener, 4) == 0 else { Darwin.close(listener); throw CocoaError(.fileReadUnknown) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var actual = sockaddr_in()
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else { Darwin.close(listener); throw CocoaError(.fileReadUnknown) }
        port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread { [weak self] in self?.serve() }
        thread.start()
        self.thread = thread
    }

    deinit { stop() }

    /// Idempotent: the server closes once, and stopping it again does nothing.
    func stop() {
        lock.lock()
        let listener = self.listener
        thread = nil
        self.listener = -1
        lock.unlock()
        guard listener >= 0 else { return }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func serve() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let read = Darwin.recv(client, &buffer, buffer.count, 0)
        guard read > 0, let head = String(bytes: buffer[0..<read], encoding: .utf8) else { return }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.components(separatedBy: " ") ?? []
        let target = requestLine.count > 1 ? requestLine[1] : ""
        let parts = target.components(separatedBy: "?")
        let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }?
            .dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces)
        lock.lock()
        sent.append(Sent(path: parts[0], query: parts.count > 1 ? parts[1] : "", authorization: authorization))
        lock.unlock()
        let headers = ["Content-Type": "application/json", "Content-Length": "\(answer.count)", "Connection": "close"]
            .merging(extraHeaders) { $1 }
        let head1 = "HTTP/1.1 \(status) Answer\r\n" + headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(head1.utf8)
        response.append(answer)
        _ = response.withUnsafeBytes { Darwin.send(client, $0.baseAddress, response.count, 0) }
    }
}
