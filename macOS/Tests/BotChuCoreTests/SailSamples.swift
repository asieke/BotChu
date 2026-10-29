import Foundation
import Testing
@testable import BotChuCore

// Fixtures for Sail Research's Responses API. Sail's docs (completion windows, API support,
// retries) describe it as OpenAI's Responses API with Flex chosen by background requests: these
// bodies follow that shape, as checked on 2026-10-27. No request here reaches the network, and the
// key is a dummy.

enum SailSamples {
    static let key = "test-key"
    static let base = URL(string: "https://sail.test/v1")!
    static let model = "sail-test/agent-1"
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func response(_ id: String, _ status: String, output: String = "[]", extra: String = "") -> String {
        #"{"id":"\#(id)","object":"response","created_at":1800000000,"status":"\#(status)","background":true,"model":"\#(model)","# +
            #""metadata":{"completion_window":"flex"},"output":\#(output)\#(extra)}"#
    }

    static func message(_ text: String) -> String {
        #"{"type":"message","id":"msg_1","status":"completed","role":"assistant","content":[{"type":"output_text","text":"\#(text)","annotations":[]}]}"#
    }

    static func call(_ id: String, _ name: String, _ arguments: String) -> String {
        let escaped = arguments.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"type":"function_call","id":"fc_\#(id)","call_id":"\#(id)","name":"\#(name)","arguments":"\#(escaped)","status":"completed"}"#
    }

    static let reasoning = #"{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Thinking it over."}]}"#
    static let usage = #","usage":{"input_tokens":1200,"output_tokens":34,"total_tokens":1234}"#

    /// Synthetic `GET /v2/usage/summary` fixture shaped as Sail's docs describe, with
    /// the balance, spend and burn rate in fractional US cents, and a free plan's 7 days noted.
    static func usageSummary(range: String = "30d", effective: String = "7d", limited: Bool = true) -> String {
        #"{"object":"usage.summary","available":true,"empty":false,"has_metronome_customer":true,"# +
            #""range":"\#(range)","balance":5498.0166062,"balance_unavailable":false,"period_spend":1.9833938,"# +
            #""product_spend":{"inference":1.9833938,"sailboxes":0},"burn_rate":0.2833419714285714,"days_remaining":null,"# +
            #""model_count":1,"total_requests":2,"tokens":{"total":3000,"input":2500,"output":500,"cached":0},"# +
            #""avg_cost_per_day":0.2833419714285714,"sla_mix":{"flex":1},"effective_range":"\#(effective)","plan_limited":\#(limited)}"#
    }
}

/// Answers each request with the next fixture, checking it is the request expected, and keeps every
/// request it was sent.
final class SailFixture: SailTransport, @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
        var error: URLError?

        static func ok(_ body: String, headers: [String: String] = [:]) -> Answer { Answer(status: 200, body: body, headers: headers) }
        static func http(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Answer { Answer(status: status, body: body, headers: headers) }
        static func failure(_ code: URLError.Code) -> Answer { Answer(error: URLError(code)) }
    }

    private let lock = NSLock()
    private var answers: [(method: String, path: String, answer: Answer)]
    private var sent: [URLRequest] = []

    init(_ answers: [(String, String, Answer)]) {
        self.answers = answers.map { (method: $0.0, path: $0.1, answer: $0.2) }
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    var remaining: Int {
        lock.lock()
        defer { lock.unlock() }
        return answers.count
    }

    /// Each request's JSON body.
    var bodies: [SailJSON] { requests.compactMap { $0.httpBody.flatMap { try? SailJSON.parse($0) } } }

    /// Keeps the request and takes the answer due.
    private func take(_ request: URLRequest) -> (method: String, path: String, answer: Answer)? {
        lock.lock()
        defer { lock.unlock() }
        sent.append(request)
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let next = take(request) else {
            Issue.record("Unexpected request: \(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
            throw URLError(.cannotConnectToHost)
        }
        #expect(request.httpMethod == next.method)
        #expect(request.url?.path == next.path)
        if let error = next.answer.error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.answer.status, httpVersion: "HTTP/1.1", headerFields: next.answer.headers)!
        return (Data(next.answer.body.utf8), response)
    }
}

/// Things recorded from `@Sendable` closures.
final class SailLog<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func add(_ item: Element) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// A Sail agent in a throwaway folder, on fixtures, with numbered idempotency keys.
struct SailHarness {
    let root: URL
    let work: URL
    let store: SailSessionStore
    let sleeps = SailLog<TimeInterval>()
    let events = SailLog<SailEvent>()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-sail-\(UUID().uuidString)")
        work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store = SailSessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func client(_ fixture: SailFixture) -> SailClient {
        var client = SailClient(key: SailSamples.key, baseURL: SailSamples.base, transport: fixture)
        let sleeps = sleeps
        client.sleep = { sleeps.add($0) }
        client.random = { 1 }
        client.now = { SailSamples.start }
        return client
    }

    func agent(_ fixture: SailFixture, live: SailLive? = nil) -> SailAgent {
        let environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, Sail.keyVariable: SailSamples.key, "BOTCHU_BIN_DIR": "/tmp/botchu-bin"]
        var agent = SailAgent(client: client(fixture), store: store, toolbox: SailToolbox(directory: work, environment: environment, live: live),
                              instructions: "Be brief.", live: live)
        let keys = SailLog<Int>()
        agent.newKey = {
            keys.add(1)
            return "key-\(keys.all.count)"
        }
        agent.now = { SailSamples.start }
        return agent
    }

    func run(_ fixture: SailFixture, _ turn: SailAgent.Turn, live: SailLive? = nil) async -> Bool {
        let events = events
        return await agent(fixture, live: live).run(turn) { events.add($0) }
    }

    /// The events as the chat would show them.
    var thread: [ChatMessage] {
        var parser = SailParser()
        var assembler = ThreadAssembler()
        var messages: [ChatMessage] = []
        for event in events.all {
            for parsed in parser.parse(line: event.line) { assembler.apply(parsed, to: &messages) }
        }
        return messages
    }
}

// Captured from a completed Sail Flex response on 2026-10-28; response ID made up.
// No billed cost field. Output includes its reasoning subset (18 = 5 text + 13 reasoning).
extension SailSamples {
    static let capturedUsage = #"{"object":"response","status":"completed","model":"deepseek-ai/DeepSeek-V4.1-Flash-1017","usage":{"input_tokens":38,"input_tokens_details":{"cached_tokens":0,"reasoning_tokens":0},"output_tokens":18,"output_tokens_details":{"cached_tokens":0,"reasoning_tokens":13},"total_tokens":56},"background":true,"metadata":{"completion_window":"flex","supercache_write_input_tokens":"0","supercached_input_tokens":"0"},"id":"resp_usage_sample"}"#
}
