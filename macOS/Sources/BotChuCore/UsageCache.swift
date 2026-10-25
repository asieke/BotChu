import Foundation

public struct UsageState: Equatable, Sendable, Codable {
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

    /// When Refresh may check again: `interval` (the request's `manualInterval`) after the last
    /// check, or at the retry the provider asked for, whichever is later; nil before any check.
    public func nextManualCheck(interval: TimeInterval) -> Date? {
        [retryAt, checkedAt?.addingTimeInterval(interval)].compactMap { $0 }.max()
    }
}

/// Shared across bots on the same account command. Never stores credentials or raw responses.
/// Coalesces concurrent checks and keeps the last successful reading labelled stale on failure.
/// Given a file, it keeps what it last read there, so a relaunch shows those readings at once; a
/// reading saved is only usage fields, and one unchecked for a week is dropped.
public actor UsageCache {
    public typealias Fetch = @Sendable (UsageRequest, String?) async throws -> ProviderUsage
    private let fetch: Fetch
    private let file: URL?
    private var states: [UsageRequest: UsageState] = [:]
    private var running: [UsageRequest: Task<UsageState, Never>] = [:]

    public init(fetch: @escaping Fetch = { try await ProviderUsageClient.read($0, openRouterKey: $1) }, file: URL? = nil) {
        self.fetch = fetch
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            states = Dictionary(saved.map { ($0.request, $0.state) }) { $1 }
        }
    }

    /// What was last read for this profile, here or before a relaunch, without checking.
    public func saved(_ request: UsageRequest) -> UsageState? { states[request] }

    /// Whether `read` would check now rather than give the last reading: none is under way, no
    /// retry is pending, and the last check is older than the interval for who asks.
    public func isDue(_ request: UsageRequest, for check: UsageCheck = .providers, now: Date = .now) -> Bool {
        guard running[request] == nil else { return false }
        let previous = states[request] ?? UsageState()
        if let retry = previous.retryAt, now < retry { return false }
        return previous.checkedAt.map { now.timeIntervalSince($0) >= request.interval(for: check) } ?? true
    }

    public func read(_ request: UsageRequest, openRouterKey: String? = nil, for check: UsageCheck = .providers,
                     now: Date = .now) async -> UsageState {
        if let task = running[request] { return await task.value }
        let previous = states[request] ?? UsageState()
        guard isDue(request, for: check, now: now) else { return previous }
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
        save(now: now)
        return state
    }

    private struct Saved: Codable {
        var request: UsageRequest
        var state: UsageState
    }

    /// Writes every profile's last state, atomically; one that can't be written stays in memory.
    private func save(now: Date) {
        guard let file else { return }
        let kept = states.filter { now.timeIntervalSince($0.value.checkedAt ?? .distantPast) < 7 * 86_400 }
        guard let data = try? JSONEncoder().encode(kept.map { Saved(request: $0.key, state: $0.value) }) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
