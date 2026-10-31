import Foundation

/// A request that used to open a task's tab (`botchu-task create`, a dispatch file, Telegram's
/// `/task`, Projects' actions) posted instead as a turn in its repository's Project Area (#399
/// decision 9): under the bot it names when that bot has the area or nobody does (attached first),
/// else in the area of the bot that has it.
public enum AreaPost {
    /// Where a request for a repository goes.
    public enum Placement: Equatable, Sendable {
        /// The bot's own area of it, hidden or not.
        case own(area: UUID)
        /// No bot has the repository: it is attached to the bot first.
        case attach
        /// Another bot has it: the request goes into that bot's area.
        case owner(botID: UUID, area: UUID)
    }

    public static func placement(repo: String, for botID: UUID, among bots: [(botID: UUID, tasks: [BotTask])]) -> Placement {
        guard let owner = Areas.owner(of: repo, among: bots) else { return .attach }
        return owner.botID == botID ? .own(area: owner.area.id) : .owner(botID: owner.botID, area: owner.area.id)
    }

    /// The message posted: "Work on issue #12 “Title” <url>" (or the pull request's continue,
    /// review or review-and-comment line) for an issue or pull request, then the brief and the
    /// branch asked for, if any.
    public static func text(brief: String, work: BotTask.Work?, review: BotTask.Review?, branch: String? = nil) -> String {
        var text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty {
            text += (text.isEmpty ? "" : "\n\n") + "Branch: `\(branch)`"
        }
        guard let work else { return text }
        let verb: String
        switch review {
        case .review: verb = "Review"
        case .comment: verb = "Review and comment on"
        case nil: verb = work.isPullRequest ? "Continue" : "Work on"
        }
        let line = "\(verb) \(work.reference) \(work.url.absoluteString)"
        return text.isEmpty ? line : line + "\n\n" + text
    }

    /// The posted message's ID for a request's idempotency key (`TaskHandoff.key`), the same on
    /// every launch, so asking again finds the message the request posted before.
    public static func messageID(key: String) -> UUID {
        func fnv(_ text: String) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return hash
        }
        var bytes = withUnsafeBytes(of: fnv("area-post\u{1F}" + key).bigEndian, Array.init)
            + withUnsafeBytes(of: fnv(key + "\u{1F}area-post").bigEndian, Array.init)
        // A version 8 (custom) UUID, RFC 9562 variant.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Whether the message `id` was posted already: in the area's transcript or its queue.
    public static func posted(_ id: UUID, thread: [ChatMessage], queue: [ChatMessage]) -> Bool {
        thread.contains { $0.id == id } || queue.contains { $0.id == id }
    }

    /// What the area's bot reads for a message another bot posted there (`ChatMessage.fromAgent`
    /// without `messageID`): who asks and from where, then the request.
    public static func prompt(_ text: String, from link: AgentLink, place: String) -> String {
        "[\(link.name) asks this of you, from \(place). Carry it through here as your own work.]\n\n\(text)"
    }
}

/// One of a bot's areas, as its `AGENTS.md` lists them.
public struct AreaListing: Equatable, Sendable {
    public var name: String
    /// `owner/name` for a repository's area, empty for a folder's.
    public var repo: String
    public var folder: String

    public init(name: String, repo: String, folder: String) {
        self.name = name
        self.repo = repo
        self.folder = folder
    }

    /// The bot's areas it shows (not hidden), in the order it took them on.
    public static func of(_ tasks: [BotTask]) -> [AreaListing] {
        Areas.areas(in: tasks).filter { !$0.isArchived }.map { AreaListing(name: $0.title, repo: $0.repo, folder: $0.checkout) }
    }
}

extension TaskReceipt {
    /// In the conversation that asked: the request is in the area, under the bot it named.
    public static func posted(in area: BotTask, of bot: String) -> String {
        "Asked \(bot) in \(area.title)"
    }

    /// The request named `asked`, but `owner` has the repository's area, so it went there, where
    /// `asked` answers it in a cameo turn (#406).
    public static func posted(in area: BotTask, of owner: String, for asked: String) -> String {
        "Asked \(asked) in \(owner)'s area \(area.title): \(owner) has \(area.repo)"
    }
}
