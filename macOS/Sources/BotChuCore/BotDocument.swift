import Foundation

/// The two editable Markdown files that travel with a bot.
public enum BotDocument: String, CaseIterable, Identifiable, Sendable {
    case memory = "MEMORY.md"
    case soul = "SOUL.md"

    public var id: String { rawValue }
    public var summary: String { self == .memory ? "Facts & notes" : "Personality & voice" }

    public func url(for bot: Bot) -> URL {
        URL(fileURLWithPath: bot.workspace, isDirectory: true).appendingPathComponent(rawValue)
    }

    public func seed(for bot: Bot) -> String {
        self == .memory ? BotContext.seedMemory(bot: bot) : BotContext.seedSoul(bot: bot)
    }
}

/// A draft keeps its original contents so saving cannot silently overwrite an agent's newer notes.
public struct BotDocumentDraft {
    public let url: URL
    public var text: String
    private var original: String?

    public init(bot: Bot, document: BotDocument) throws {
        url = document.url(for: bot)
        original = try Self.read(url)
        text = original ?? document.seed(for: bot)
    }

    public mutating func save() throws {
        guard try Self.read(url) == original else { throw SaveError.changedOnDisk(url.lastPathComponent) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        original = text
    }

    private static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private enum SaveError: LocalizedError {
        case changedOnDisk(String)

        var errorDescription: String? {
            switch self {
            case .changedOnDisk(let name):
                "\(name) changed since you opened it. Copy any edits you want to keep, then Reload the latest file before saving."
            }
        }
    }
}
