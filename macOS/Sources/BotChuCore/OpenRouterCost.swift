import Foundation

/// The generation endpoint's billing metadata only. Responses, credentials and transport errors
/// never escape this boundary; callers receive a cost or a small, content-free retry decision.
/// Schema: https://openrouter.ai/docs/api/api-reference/generations/get-generation
public struct OpenRouterCost: Sendable {
    public enum Result: Equatable, Sendable {
        case billed(Double)
        case unauthorized
        case retry(after: TimeInterval)
    }
    public typealias HTTP = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let http: HTTP

    public init(http: @escaping HTTP = { try await OpenRouterCost.request($0) }) { self.http = http }

    public func read(generationID: String, key: String) async -> Result {
        guard Self.supports(generationID), !key.isEmpty else { return .retry(after: 300) }
        var parts = URLComponents(string: "https://openrouter.ai/api/v1/generation")!
        parts.queryItems = [URLQueryItem(name: "id", value: generationID)]
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await http(request)
            if response.statusCode == 401 { return .unauthorized }
            guard response.statusCode == 200 else {
                let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
                return .retry(after: wait.isFinite ? min(86_400, max(60, wait)) : 300)
            }
            struct Envelope: Decodable {
                struct Generation: Decodable { var id: String; var total_cost: Double }
                var data: Generation
            }
            let value = try JSONDecoder().decode(Envelope.self, from: data).data
            guard value.id == generationID, value.total_cost.isFinite, value.total_cost >= 0 else {
                return .retry(after: 300)
            }
            return .billed(value.total_cost)
        } catch { return .retry(after: 300) }
    }

    public static func supports(_ id: String) -> Bool {
        id.hasPrefix("gen-") && id.count > 4 && id.utf8.count <= 512 &&
            id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    /// Ephemeral sessions keep Authorization and metadata out of URL caches and persistent cookies.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public static func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

/// One app-wide scheduler: each tick can start at most one HTTP request, at least a second after
/// the preceding one. The app calls it from utility work, supplying idle ledger snapshots. No
/// timers, network, file scans or credentials are involved in recording a completed turn.
public actor OpenRouterCostScheduler {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public var id: UUID
        public var ownerBotID: UUID
        public var botID: UUID
        public var accountID: String
        public var endedAt: Date
        public var generationIDs: [String]
        public init(id: UUID, ownerBotID: UUID, botID: UUID, accountID: String, endedAt: Date,
                    generationIDs: [String]) {
            self.id = id; self.ownerBotID = ownerBotID; self.botID = botID; self.accountID = accountID
            self.endedAt = endedAt; self.generationIDs = generationIDs
        }
    }
    public typealias Activity = @Sendable (Candidate) async -> Bool
    public typealias Credential = @Sendable (String) async -> String?
    public typealias Amend = @Sendable (Candidate, Double) async -> Bool
    private let client: OpenRouterCost
    private let now: @Sendable () -> Date
    private let isActive: Activity
    private let credential: Credential
    private let amend: Amend
    private var nextRequest = Date.distantPast
    private var disabledAccounts = Set<String>()
    private var credentialRevisions: [String: Int] = [:]
    private var missingCredentialUntil: [String: Date] = [:]
    private var costs: [UUID: [String: Double]] = [:]
    private var retryAt: [UUID: Date] = [:]
    private var completed = Set<UUID>()
    private var running = false

    public init(client: OpenRouterCost = OpenRouterCost(), now: @escaping @Sendable () -> Date = { Date() },
                isActive: @escaping Activity, credential: @escaping Credential, amend: @escaping Amend) {
        self.client = client; self.now = now; self.isActive = isActive
        self.credential = credential; self.amend = amend
    }

    /// Called when that account's permitted credential or profile changes, never every poll.
    public func reset(accountID: String) {
        disabledAccounts.remove(accountID)
        missingCredentialUntil.removeValue(forKey: accountID)
        credentialRevisions[accountID, default: 0] += 1
    }

    public func tick(_ candidates: [Candidate]) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let ids = Set(candidates.map(\.id))
        costs = costs.filter { ids.contains($0.key) }
        retryAt = retryAt.filter { ids.contains($0.key) }
        completed.formIntersection(ids)
        for candidate in candidates {
            let date = now()
            guard !completed.contains(candidate.id), !disabledAccounts.contains(candidate.accountID),
                  date.timeIntervalSince(candidate.endedAt) >= 60,
                  date.timeIntervalSince(candidate.endedAt) <= 86_400,
                  retryAt[candidate.id, default: .distantPast] <= date,
                  missingCredentialUntil[candidate.accountID, default: .distantPast] <= date,
                  !candidate.generationIDs.isEmpty,
                  candidate.generationIDs.allSatisfy(OpenRouterCost.supports),
                  !(await isActive(candidate)) else { continue }
            let ids = Array(Set(candidate.generationIDs)).sorted()
            if let id = ids.first(where: { costs[candidate.id]?[$0] == nil }) {
                guard date >= nextRequest else { return }
                let revision = credentialRevisions[candidate.accountID, default: 0]
                guard let key = await credential(candidate.accountID), !key.isEmpty else {
                    missingCredentialUntil[candidate.accountID] = now().addingTimeInterval(300)
                    continue
                }
                // The credential lookup may have suspended while a turn began.
                guard !Task.isCancelled, !(await isActive(candidate)) else { continue }
                nextRequest = now().addingTimeInterval(1)
                switch await client.read(generationID: id, key: key) {
                case .billed(let amount): costs[candidate.id, default: [:]][id] = amount
                case .unauthorized:
                    if revision == credentialRevisions[candidate.accountID, default: 0] {
                        disabledAccounts.insert(candidate.accountID)
                    }
                case .retry(let after): retryAt[candidate.id] = now().addingTimeInterval(after)
                }
                if costs[candidate.id]?.count != ids.count { return }
            }
            guard let amounts = costs[candidate.id], amounts.count == ids.count,
                  !(await isActive(candidate)), !Task.isCancelled else { continue }
            let total = amounts.values.reduce(0, +)
            guard total.isFinite else { completed.insert(candidate.id); continue }
            if await amend(candidate, total) {
                completed.insert(candidate.id)
                costs.removeValue(forKey: candidate.id)
            } else { retryAt[candidate.id] = now().addingTimeInterval(300) }
            return
        }
    }
}
