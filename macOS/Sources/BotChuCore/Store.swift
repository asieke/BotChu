import Foundation

/// Bots and their threads as JSON files: `bots.json` and `threads/<bot id>.json` under one folder
/// (`~/Library/Application Support/BotChu` in the app).
public struct Store: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var applicationSupport: Store {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Store(root: base.appendingPathComponent("BotChu", isDirectory: true))
    }

    var botsURL: URL { root.appendingPathComponent("bots.json") }

    func threadURL(_ id: UUID) -> URL {
        root.appendingPathComponent("threads", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func loadBots() -> [Bot] {
        guard let data = try? Data(contentsOf: botsURL) else { return [] }
        return (try? Self.decoder.decode([Bot].self, from: data)) ?? []
    }

    public func saveBots(_ bots: [Bot]) throws {
        try write(Self.encoder.encode(bots), to: botsURL)
    }

    public func loadThread(_ id: UUID) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: threadURL(id)) else { return [] }
        return (try? Self.decoder.decode([ChatMessage].self, from: data)) ?? []
    }

    public func saveThread(_ messages: [ChatMessage], for id: UUID) throws {
        try write(Self.encoder.encode(messages), to: threadURL(id))
    }

    public func deleteThread(_ id: UUID) {
        try? FileManager.default.removeItem(at: threadURL(id))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
