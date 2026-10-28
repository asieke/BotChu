import Foundation

/// Token counts for one model in a request. Nil means the provider did not report the bucket.
/// `cacheWrite1h` is a subset of `cacheWrite`; `reasoning` is a subset of `output`.
/// `uncachedInput`, `cacheRead` and `cacheWrite` are disjoint input buckets.
public struct ModelUsage: Codable, Equatable, Sendable {
    public var model: String
    public var uncachedInput: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var cacheWrite1h: Int?
    public var output: Int?
    public var reasoning: Int?

    public init(model: String, uncachedInput: Int? = nil, cacheRead: Int? = nil,
                cacheWrite: Int? = nil, cacheWrite1h: Int? = nil, output: Int? = nil,
                reasoning: Int? = nil) {
        self.model = model
        self.uncachedInput = uncachedInput
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.output = output
        self.reasoning = reasoning
    }
}
