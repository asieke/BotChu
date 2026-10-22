import Foundation

public struct UsageState: Equatable, Sendable {
    public var reading: ProviderUsage?
    public var error: String?
    public var checkedAt: Date?
    public var retryAt: Date?

    public init(reading: ProviderUsage? = nil, error: String? = nil, checkedAt: Date? = nil, retryAt: Date? = nil) {
        self.reading = reading
        self.error = error
        self.checkedAt = checkedAt
        self.retryAt = retryAt
    }

    public func isStale(at now: Date, interval: TimeInterval) -> Bool {
        guard let reading else { return false }
        return error != nil || now.timeIntervalSince(reading.readAt) >= interval
    }
}

/// Shared across bots on the same account command. Never stores credentials or raw responses.
/// Coalesces concurrent checks and keeps the last successful reading labelled stale on failure.
public actor UsageCache {
    public typealias Fetch = @Sendable (UsageRequest, String?) async throws -> ProviderUsage
    private let fetch: Fetch
    private var states: [UsageRequest: UsageState] = [:]
    private var running: [UsageRequest: Task<UsageState, Never>] = [:]

    public init(fetch: @escaping Fetch = { try await ProviderUsageClient.read($0, openRouterKey: $1) }) { self.fetch = fetch }

    public func read(_ request: UsageRequest, openRouterKey: String? = nil, manual: Bool = false, now: Date = .now) async -> UsageState {
        if let task = running[request] { return await task.value }
        let previous = states[request] ?? UsageState()
        if let retry = previous.retryAt, now < retry { return previous }
        let interval = manual ? request.manualInterval : request.refreshInterval
        if let checked = previous.checkedAt, now.timeIntervalSince(checked) < interval { return previous }
        let fetch = fetch
        let task = Task<UsageState, Never> {
            do {
                let reading = try await fetch(request, openRouterKey)
                return UsageState(reading: reading, checkedAt: now)
            } catch {
                // Provider errors are deliberately sanitized. No raw auth, CLI or HTTP errors.
                let failure = error as? UsageFailure
                return UsageState(reading: previous.reading, error: failure?.message ?? "Account usage is unavailable. Try refreshing later.",
                    checkedAt: now, retryAt: now.addingTimeInterval(max(request.manualInterval, failure?.retryAfter ?? 0)))
            }
        }
        running[request] = task
        let state = await task.value
        states[request] = state
        running[request] = nil
        return state
    }
}
