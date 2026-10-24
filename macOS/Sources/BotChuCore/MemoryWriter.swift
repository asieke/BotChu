import Foundation

/// Which memory a note is for: the bot's own `MEMORY.md`, or the one every bot shares. Run
/// reviews (`RunEvaluator`) also add lessons to the bot's `INSTRUCTIONS.md` (`instructions`), which
/// no `<remember>` block can ask for.
public enum MemoryScope: String, Codable, Sendable, CaseIterable {
    case bot, shared, instructions
}

/// Why a note wasn't saved. A secret's text is never repeated.
public enum MemoryRefusal: Equatable, Sendable {
    case secret, tooLong, question, transcript

    var reason: String {
        switch self {
        case .secret: "looks like a secret"
        case .tooLong: "too long for one note"
        case .question: "a question, not a fact"
        case .transcript: "a transcript or command output"
        }
    }
}

/// What saving notes changed in a memory file.
public struct MemoryChanges: Equatable, Sendable {
    public var added: [String] = []
    public var replaced: [String] = []
    public var forgotten: [String] = []
    /// Notes that were there already, and forgets of nothing.
    public var unchanged = 0

    public var isEmpty: Bool { added.isEmpty && replaced.isEmpty && forgotten.isEmpty }
}

/// A memory file, and where its notes wait while they can't be saved: in the `.botchu/` of the
/// bot that asked, so they come back after a relaunch.
public struct MemoryFile: Hashable, Sendable {
    public var scope: MemoryScope
    public var path: String
    public var waitingPath: String
    /// The heading new notes go under (made at the end when missing); nil adds them at the end.
    public var section: String?

    public init(scope: MemoryScope, path: String, waitingPath: String, section: String? = nil) {
        self.scope = scope
        self.path = path
        self.waitingPath = waitingPath
        self.section = section
    }

    /// The bot's own `MEMORY.md`, in its workspace.
    public static func bot(workspace: String) -> MemoryFile {
        MemoryFile(scope: .bot, path: (workspace as NSString).appendingPathComponent(BotContext.memoryFile),
                   waitingPath: waiting("memory-unsaved.json", in: workspace))
    }

    /// The shared `MEMORY.md` at `path`, for the bot in `workspace`.
    public static func shared(_ path: String, botWorkspace workspace: String) -> MemoryFile {
        MemoryFile(scope: .shared, path: path, waitingPath: waiting("shared-memory-unsaved.json", in: workspace))
    }

    /// The lessons section of the bot's `INSTRUCTIONS.md`, where run reviews add what they learn.
    public static func instructions(workspace: String) -> MemoryFile {
        MemoryFile(scope: .instructions, path: (workspace as NSString).appendingPathComponent(BotContext.instructionsFile),
                   waitingPath: waiting("instructions-unsaved.json", in: workspace), section: lessonsHeading)
    }

    /// The heading of the lessons run reviews add to a bot's instructions.
    public static let lessonsHeading = "## Lessons from run reviews"

    private static func waiting(_ name: String, in workspace: String) -> String {
        ((workspace as NSString).appendingPathComponent(BotHome.folderName) as NSString).appendingPathComponent(name)
    }
}

/// How saving notes to a memory file went.
public struct MemorySave: Equatable, Sendable {
    public var file: MemoryFile
    public var changes = MemoryChanges()
    public var refused: [MemoryRefusal] = []
    /// Why the file couldn't be saved (without a closing period), or nil when it was (or needed no change).
    public var failure: String?
    /// How many notes wait to be tried again, after a failure.
    public var waiting = 0
    /// The file before and after the save, when it changed it.
    public var previous: String?
    public var saved: String?

    public init(file: MemoryFile) {
        self.file = file
    }

    /// Nothing was asked of the file, and nothing waited.
    public var isEmpty: Bool { changes.isEmpty && changes.unchanged == 0 && refused.isEmpty && failure == nil }

    /// The line BotChu adds to the conversation, and whether it reports a failure; nil when there
    /// was nothing to save. `botName` names the bot whose memory it is.
    public func summary(botName: String) -> (text: String, failed: Bool)? {
        guard !isEmpty else { return nil }
        let place = switch file.scope {
        case .bot: "\(botName)'s memory"
        case .shared: "the shared memory"
        case .instructions: "\(botName)'s instructions"
        }
        if let failure {
            return ("Couldn't save \(Self.count(waiting, "note")) to \(place) (\(file.scope == .instructions ? BotContext.instructionsFile : BotContext.memoryFile)): \(failure). "
                + "It is unchanged. BotChu keeps \(waiting == 1 ? "the note" : "them") and tries again after the next turn, "
                + "or choose Retry.", true)
        }
        var text: String
        if changes.added.count + changes.replaced.count + changes.forgotten.count == 1 {
            text = changes.added.first.map { "Saved to \(place): “\($0)”" }
                ?? changes.replaced.first.map { "Updated in \(place): “\($0)”" }
                ?? "Removed from \(place): “\(changes.forgotten[0])”"
        } else if !changes.isEmpty {
            let counts: [(Int, String)] = [(changes.added.count, "added"), (changes.replaced.count, "updated"),
                                           (changes.forgotten.count, "removed")]
            var parts: [String] = []
            for (n, what) in counts where n > 0 {
                parts.append(parts.isEmpty ? "\(Self.count(n, "note")) \(what)" : "\(n) \(what)")
            }
            text = "Saved to \(place): " + parts.joined(separator: ", ")
        } else if changes.unchanged > 0 {
            text = "Already in \(place)"
        } else {
            text = "Nothing saved to \(place)"
        }
        if !refused.isEmpty { text += " · left out \(refusals)" }
        return (text, false)
    }

    /// What the CLI hears at its next turn, so it never takes a request to save for a save; nil
    /// when there was nothing to save.
    public var report: String? {
        guard !isEmpty else { return nil }
        let place = switch file.scope {
        case .bot: "your \(BotContext.memoryFile)"
        case .shared: "the shared \(BotContext.memoryFile)"
        case .instructions: "your \(BotContext.instructionsFile)"
        }
        var lines: [String] = []
        if let failure {
            lines.append("Couldn't save \(Self.count(waiting, "note")) to \(place) (\(failure)). BotChu keeps "
                + "\(waiting == 1 ? "it" : "them") and tries again after your next turn: don't say \(waiting == 1 ? "it is" : "they are") "
                + "saved, and don't repeat \(waiting == 1 ? "it" : "them").")
        } else {
            var saved = changes.added.map { "added “\($0)”" } + changes.replaced.map { "updated “\($0)”" }
            saved += changes.forgotten.map { "removed “\($0)”" }
            if !saved.isEmpty { lines.append("Saved to \(place): " + saved.joined(separator: "; ") + ".") }
            if changes.unchanged > 0 { lines.append("Already in \(place): \(Self.count(changes.unchanged, "note")) you asked to save.") }
        }
        if !refused.isEmpty { lines.append("Left out of \(place): \(refusals). Don't say \(refused.count == 1 ? "it is" : "they are") saved.") }
        return lines.joined(separator: " ")
    }

    private var refusals: String {
        var reasons: [String] = []
        for refusal in refused where !reasons.contains(refusal.reason) { reasons.append(refusal.reason) }
        return "\(Self.count(refused.count, "note")) (\(reasons.joined(separator: "; ")))"
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

/// Saves notes to memory files, for every conversation (Home, tasks on this Mac and on hosts,
/// sub-agents) and anything else that keeps memory: one writer for the app (`shared`), safe to call
/// from any thread. It saves one file at a time, re-reading it just before writing so edits made
/// meanwhile (by another conversation, the owner, a CLI) are kept, and reads it back afterwards to
/// check the change held. A file that exists but can't be read is never overwritten. Notes that
/// can't be saved wait (in the bot's `.botchu/`, or in memory when even that fails) and go first,
/// in order, with the next save to that file or `retry`, so corrections and forgets keep their
/// order and nothing needs saying again.
public final class MemoryWriter: @unchecked Sendable {
    public static let shared = MemoryWriter()

    private let lock = NSLock()
    /// Waiting notes that couldn't be written to their waiting file either, by that file's path.
    private var unwritten: [String: [String]] = [:]

    public init() {}

    /// Saves the notes (lines of `<remember>` blocks) to the file, after any still waiting.
    @discardableResult
    public func save(_ notes: [String], to file: MemoryFile) -> MemorySave {
        lock.lock()
        defer { lock.unlock() }
        var result = MemorySave(file: file)
        var accepted: [String] = []
        for note in notes {
            if let refusal = MemoryNotes.refusal(of: note) {
                result.refused.append(refusal)
            } else if MemoryNotes.parseOperation(note) != nil {
                accepted.append(note)
            }
        }
        let queue = waitingNotes(file) + accepted
        guard !queue.isEmpty else { return result }
        do {
            let original = try Self.read(file.path)
            let (text, changes) = MemoryNotes.applying(queue, to: original, section: file.section)
            if !changes.isEmpty {
                try text.write(toFile: file.path, atomically: true, encoding: .utf8)
                guard MemoryNotes.kept(text, over: original, in: try Self.read(file.path)) else { throw NotKept() }
                result.previous = original
                result.saved = text
            }
            result.changes = changes
            unwritten[file.waitingPath] = nil
            try? FileManager.default.removeItem(atPath: file.waitingPath)
        } catch {
            let reason = (error as? NotKept)?.description ?? error.localizedDescription
            result.failure = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
            result.waiting = MemoryNotes.distinct(queue)
            keepWaiting(queue, for: file)
        }
        return result
    }

    /// Saves a conversation's requests (`MemoryNotes.requests`) to the files they are for, each
    /// after its waiting notes; a file with neither is left alone.
    public func save(_ requests: [MemoryScope: [String]], to files: [MemoryFile]) -> [MemorySave] {
        files.compactMap { file in
            let notes = requests[file.scope] ?? []
            guard !notes.isEmpty || !waiting(file).isEmpty else { return nil }
            return save(notes, to: file)
        }
    }

    /// Tries the file's waiting notes again.
    @discardableResult
    public func retry(_ file: MemoryFile) -> MemorySave {
        save([], to: file)
    }

    /// The notes waiting for the file, in order.
    public func waiting(_ file: MemoryFile) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return waitingNotes(file)
    }

    /// How many distinct notes wait for the file.
    public func waitingCount(_ file: MemoryFile) -> Int {
        MemoryNotes.distinct(waiting(file))
    }

    private func waitingNotes(_ file: MemoryFile) -> [String] {
        if let notes = unwritten[file.waitingPath] { return notes }
        guard let data = FileManager.default.contents(atPath: file.waitingPath) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func keepWaiting(_ notes: [String], for file: MemoryFile) {
        let url = URL(fileURLWithPath: file.waitingPath)
        // Only `.botchu/` itself: a bot folder that is gone isn't made again.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false)
        do {
            try JSONEncoder().encode(notes).write(to: url, options: .atomic)
            unwritten[file.waitingPath] = nil
        } catch {
            unwritten[file.waitingPath] = notes
        }
    }

    /// The file's text: empty when there is no file yet, an error when there is one but it can't be
    /// read, so it is never overwritten.
    static func read(_ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private struct NotKept: Error, CustomStringConvertible {
        var description: String { "it changed again as it was saved" }
    }
}
