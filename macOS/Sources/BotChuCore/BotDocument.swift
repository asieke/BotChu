import Foundation

/// The editable Markdown files that travel with a bot.
public enum BotDocument: String, CaseIterable, Identifiable, Sendable {
    case instructions = "INSTRUCTIONS.md"
    case soul = "SOUL.md"
    case memory = "MEMORY.md"

    public var id: String { rawValue }
    public var summary: String {
        switch self {
        case .instructions: "Role & job"
        case .soul: "Personality & voice"
        case .memory: "Facts & notes"
        }
    }

    public func url(for bot: Bot) -> URL {
        URL(fileURLWithPath: bot.workspace, isDirectory: true).appendingPathComponent(rawValue)
    }

    /// What a missing file starts as in the editor. Instructions start from a bot.json's
    /// `instructions` field that hasn't moved into the file yet, and are otherwise empty, so an
    /// untouched file still reads as "no instructions yet".
    public func seed(for bot: Bot) -> String {
        switch self {
        case .instructions: bot.instructions
        case .soul: BotContext.seedSoul(bot: bot)
        case .memory: BotContext.seedMemory(bot: bot)
        }
    }
}

/// The editable Markdown files every bot shares, in the bots folder.
public enum SharedDocument: String, CaseIterable, Identifiable, Sendable {
    case team = "TEAM.md"
    case memory = "MEMORY.md"

    public var id: String { rawValue }
    public var summary: String { self == .team ? "Playbook every bot follows" : "Memory every bot keeps" }

    public func url(botsRoot: String) -> URL {
        URL(fileURLWithPath: (botsRoot as NSString).expandingTildeInPath, isDirectory: true).appendingPathComponent(rawValue)
    }

    /// TEAM.md starts empty: a missing or empty playbook is left out of every bot's context.
    public var seed: String { self == .team ? "" : BotContext.seedSharedMemory }
}

/// A draft keeps its original contents so saving cannot silently overwrite an agent's newer notes.
public struct BotDocumentDraft {
    public let url: URL
    public var text: String
    private var original: String?
    private let seed: String

    public init(bot: Bot, document: BotDocument) throws {
        try self.init(url: document.url(for: bot), seed: document.seed(for: bot))
    }

    public init(url: URL, seed: String) throws {
        self.url = url
        self.seed = seed
        original = try Self.read(url)
        text = original ?? seed
    }

    /// Whether the draft differs from what it was opened with.
    public var hasChanges: Bool { text != (original ?? seed) }

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
