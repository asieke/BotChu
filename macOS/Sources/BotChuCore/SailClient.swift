import Foundation

/// Sends one HTTP request. Tests answer from fixtures; the helper uses `URLSessionSailTransport`.
public protocol SailTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionSailTransport: SailTransport, @unchecked Sendable {
    private let session: URLSession

    /// `timeout` bounds one request, never the inference: a poll that times out is made again.
    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// How long to wait before trying again.
public struct SailRetryPolicy: Equatable, Sendable {
    /// The wait after the first failed attempt; each next one doubles, up to `maxDelay`, less up to
    /// half at random so retries don't arrive together.
    public var initialDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 60
    /// The longest `Retry-After` taken as given.
    public var maxRetryAfter: TimeInterval = 900
    /// Submission attempts in one run; the idempotency key is kept for the next run.
    public var submitAttempts = 8

    public init() {}

    /// `Retry-After` when Sail sent one, else exponential backoff. `random` is in 0...1.
    public func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 0), maxRetryAfter) }
        let base = min(maxDelay, initialDelay * pow(2, Double(max(0, attempt - 1))))
        return base * (0.5 + 0.5 * min(max(random, 0), 1))
    }
}

/// How often a queued or running response is checked: soon at first, then every `longest`
/// seconds, as Flex work can wait in its queue for a long time.
public struct SailPollSchedule: Equatable, Sendable {
    public var first: TimeInterval = 2
    public var growth: Double = 1.5
    public var longest: TimeInterval = 30

    public init() {}

    public func interval(afterPolls count: Int) -> TimeInterval {
        min(longest, first * pow(growth, Double(max(0, count))))
    }
}

/// What happens while a request is submitted and waited for, for the conversation to show.
public enum SailProgress: Equatable, Sendable {
    /// A poll found the response in a new status.
    case status(SailResponse)
    /// An attempt failed in a way worth trying again, which happens after `after` seconds.
    case retrying(String, after: TimeInterval)
}

/// Sail's Responses API with BotChu's retries: a submission is sent again with the same
/// idempotency key until Sail takes it, and polling goes on through timeouts, rate limits and
/// server errors, which never cancel the inference itself.
public struct SailClient: Sendable {
    public var key: String
    public var baseURL: URL
    public var transport: any SailTransport
    public var retry = SailRetryPolicy()
    public var poll = SailPollSchedule()
    public var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
    public var random: @Sendable () -> Double = { Double.random(in: 0...1) }
    public var now: @Sendable () -> Date = { Date() }

    public init(key: String, baseURL: URL = Sail.apiBase, transport: any SailTransport = URLSessionSailTransport()) {
        self.key = key
        self.baseURL = baseURL
        self.transport = transport
    }

    func request(_ method: String, _ path: String, body: Data? = nil, idempotencyKey: String? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }

    /// Submits a request until Sail takes it, with the same `idempotencyKey` each time, so a
    /// submission that reached Sail before its answer was lost doesn't start a second inference.
    public func submit(_ body: SailJSON, idempotencyKey: String, model: String,
                       progress: @Sendable (SailProgress) -> Void = { _ in }) async throws -> SailResponse {
        let data = body.data()
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let reason: String
            let wait: TimeInterval
            do {
                let (answer, http) = try await transport.send(request("POST", "responses", body: data, idempotencyKey: idempotencyKey))
                if (200..<300).contains(http.statusCode) { return try SailResponse.parse(answer) }
                guard SailHTTP.isTransient(http.statusCode) else {
                    throw SailHTTP.submissionFailure(status: http.statusCode, data: answer, model: model)
                }
                reason = "HTTP \(http.statusCode): \(SailHTTP.message(answer))"
                wait = retry.delay(afterAttempt: attempt, retryAfter: SailHTTP.retryAfter(http, now: now()), random: random())
            } catch let failure as SailFailure {
                throw failure
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                reason = error.localizedDescription
                wait = retry.delay(afterAttempt: attempt, retryAfter: nil, random: random())
            }
            guard attempt < retry.submitAttempts else {
                throw SailFailure(.unavailable, """
                    Sail didn't take the request after \(attempt) tries (last: \(reason)). Its idempotency key is kept, \
                    so sending a message here again tries the same submission and can't start it twice.
                    """)
            }
            progress(.retrying(reason, after: wait))
            try await sleep(wait)
        }
    }

    /// Polls `submitted` until it ends: completed, incomplete, failed or cancelled. Only a refused
    /// key or a response Sail no longer has ends the wait early; Stop ends it by cancelling the task.
    public func wait(for submitted: SailResponse, progress: @Sendable (SailProgress) -> Void = { _ in }) async throws -> SailResponse {
        var current = submitted
        var polls = 0
        var failures = 0
        var next: TimeInterval?
        while !current.status.isTerminal {
            try await sleep(next ?? poll.interval(afterPolls: polls))
            polls += 1
            next = nil
            var reason: String?
            var retryAfter: TimeInterval?
            do {
                let (answer, http) = try await transport.send(request("GET", "responses/\(current.id)"))
                if (200..<300).contains(http.statusCode) {
                    let response = try SailResponse.parse(answer)
                    failures = 0
                    next = SailHTTP.retryAfter(http, now: now()).map { min($0, retry.maxRetryAfter) }
                    if response.status != current.status { progress(.status(response)) }
                    current = response
                    continue
                }
                guard SailHTTP.isTransient(http.statusCode) else {
                    throw SailHTTP.pollFailure(status: http.statusCode, data: answer, id: current.id)
                }
                reason = "HTTP \(http.statusCode): \(SailHTTP.message(answer))"
                retryAfter = SailHTTP.retryAfter(http, now: now())
            } catch let failure as SailFailure where failure.kind != .malformed {
                throw failure
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                reason = (error as? SailFailure)?.message ?? error.localizedDescription
            }
            failures += 1
            let wait = retry.delay(afterAttempt: failures, retryAfter: retryAfter, random: random())
            progress(.retrying(reason ?? "no answer", after: wait))
            next = wait
        }
        return current
    }

    /// The models Sail lists for this key, for Settings to choose a default from.
    public func models() async throws -> [CatalogModel] {
        let (data, http) = try await transport.send(request("GET", "models"))
        guard (200..<300).contains(http.statusCode) else {
            let said = SailHTTP.message(data)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw SailFailure(.key, status: http.statusCode, "Sail refused the API key (HTTP \(http.statusCode): \(said)).")
            }
            throw SailFailure(.rejected, status: http.statusCode, "Sail didn't list its models (HTTP \(http.statusCode): \(said)).")
        }
        return try SailCatalog.parse(data)
    }
}

/// Sail's model list (`GET /models`, OpenAI's shape). It doesn't say which models take Flex; a
/// model that doesn't is refused on its first request, with the choices (`SailHTTP.submissionFailure`).
public enum SailCatalog {
    public static func parse(_ data: Data) throws -> [CatalogModel] {
        let json = try? SailJSON.parse(data)
        let entries = json?["data"]?.array ?? json?["models"]?.array ?? json?.array ?? []
        var seen = Set<String>()
        let models = entries.compactMap { entry -> CatalogModel? in
            guard let id = entry["id"]?.string ?? entry.string, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let context = entry["context_length"]?.int ?? entry["context_window"]?.int ?? entry["max_context_length"]?.int
            return CatalogModel(id: id, name: entry["name"]?.string ?? entry["display_name"]?.string ?? id, contextLength: context)
        }
        guard !models.isEmpty else { throw SailFailure(.malformed, "Sail's model list was empty or unreadable.") }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
