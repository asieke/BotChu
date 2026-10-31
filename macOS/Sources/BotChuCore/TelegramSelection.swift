import Foundation

/// The bots and repositories a Telegram chat chooses from with `@` and `#` (#114), as BotChu's own
/// message box completes them (#84): the configured bots, in the sidebar's order, and the saved
/// Projects catalog (nil until one is saved).
public struct TelegramDirectory: Sendable {
    public var bots: [BotRosterEntry]
    public var projects: [ProjectCatalogEntry]?
    /// The GitHub account whose catalog it is.
    public var login: String?

    public init(bots: [BotRosterEntry] = [], projects: [ProjectCatalogEntry]? = nil, login: String? = nil) {
        self.bots = bots
        self.projects = projects
        self.login = login
    }

    /// How a message names a bot: `@` and its name, then the start of its ID in brackets when another
    /// bot has the same name. A chosen bot is known by its ID, never by a name alone.
    public func word(for bot: BotRosterEntry) -> String {
        let fold = MentionDirectory.fold(bot.name)
        let twin = bots.contains { $0.id != bot.id && MentionDirectory.fold($0.name) == fold }
        return "@" + bot.name + (twin ? " [\(bot.id.uuidString.lowercased().prefix(8))]" : "")
    }

    /// A chosen repository as BotChu's message box keeps a `#` mention, for the bot it goes to
    /// (`ReferenceContext`).
    public func reference(to repo: String) -> MessageReference {
        MessageReference(kind: .project, target: repo, label: "#" + repo, login: login)
    }
}

/// The words at the start of a Telegram message that say where it goes (#114), in any order, each
/// once: `@` and a BotChu bot's name, `#` and a repository, and `/task`. What follows them is the
/// message. A bot is matched by its whole name, ignoring case and accents, and never by part of one,
/// so a name that matches no bot (one deleted, or mistyped) is refused rather than taken for another.
/// A repository is matched by `owner/name`, or by its name alone when only one in the catalog has
/// it; `#` with a word that names none (a hashtag) or digits alone (an issue) is the message's text.
/// Further `@` words are text too: a message goes to one bot.
public struct TelegramAddress: Equatable, Sendable {
    public var bot: BotRosterEntry?
    /// `owner/name`, as the catalog writes it.
    public var repo: String?
    /// `/task`: the message asks for a task of its own.
    public var isTask = false
    /// The message after the address words: as sent when there are none.
    public var body: String

    public init(bot: BotRosterEntry? = nil, repo: String? = nil, isTask: Bool = false, body: String) {
        self.bot = bot
        self.repo = repo
        self.isTask = isTask
        self.body = body
    }

    /// Why a message's address words can't be followed: the message isn't sent.
    public struct Problem: Error, Equatable, Sendable {
        public var message: String
    }

    /// Whether it only chooses a bot or a repository: nothing to send or start.
    public var isSelection: Bool { !isTask && body.isEmpty && (bot != nil || repo != nil) }

    /// Whether `text` may start with address words, so the bots and repositories are needed to read it.
    public static func mayAddress(_ text: String) -> Bool {
        let start = text.drop { $0.isWhitespace }
        return start.first == "@" || start.first == "#" || taskCommand(in: start, username: nil) != nil
            || start.lowercased().hasPrefix("/task@")
    }

    /// The address words at the start of `text`. `username` is the Telegram bot's own, which Telegram
    /// puts before a message written in inline mode: it is left out.
    public static func parse(_ text: String, in directory: TelegramDirectory, username: String?) -> Result<TelegramAddress, Problem> {
        var address = TelegramAddress(body: text)
        var rest = Substring(text).drop { $0.isWhitespace }
        var addressed = false
        var ownName = false
        while let first = rest.first {
            if first == "/", !address.isTask, let after = taskCommand(in: rest, username: username) {
                address.isTask = true
                rest = after
            } else if first == "@", let username, !ownName, let after = word(rest.dropFirst(), startsWith: username) {
                ownName = true
                rest = after
            } else if first == "@", address.bot == nil {
                switch bot(at: rest.dropFirst(), in: directory) {
                case .success(let found):
                    address.bot = found.bot
                    rest = found.rest
                case .failure(let problem):
                    return .failure(problem)
                }
            } else if first == "#", address.repo == nil {
                switch repository(at: rest.dropFirst(), in: directory) {
                case .success(let found?):
                    address.repo = found.repo
                    rest = found.rest
                case .success(nil):
                    break
                case .failure(let problem):
                    return .failure(problem)
                }
                if address.repo == nil { break }
            } else {
                break
            }
            addressed = true
            rest = rest.drop { $0.isWhitespace || $0 == ":" || $0 == "," }
        }
        guard addressed else { return .success(address) }
        address.body = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(address)
    }

    /// The text after `/task` (or `/task@username`) at the start of `text`; nil when it doesn't start so.
    static func taskCommand(in text: Substring, username: String?) -> Substring? {
        if let after = word(text, startsWith: "/task") { return after }
        guard let username else { return nil }
        return word(text, startsWith: "/task@" + username)
    }

    /// The text after `word` when `text` starts with it, ignoring case, as a whole word.
    static func word(_ text: Substring, startsWith word: String) -> Substring? {
        guard text.count >= word.count, text.prefix(word.count).caseInsensitiveCompare(word) == .orderedSame else { return nil }
        let rest = text.dropFirst(word.count)
        guard rest.first.map(endsWord) ?? true else { return nil }
        return rest
    }

    static func endsWord(_ character: Character) -> Bool {
        character.isWhitespace || ",:;.!?)".contains(character)
    }

    /// The bot whose whole name `text` starts with: the longest name that matches, and among bots of
    /// that name the one whose ID starts as the bracketed tag after it says.
    static func bot(at text: Substring, in directory: TelegramDirectory) -> Result<(bot: BotRosterEntry, rest: Substring), Problem> {
        var named: [(bot: BotRosterEntry, length: Int)] = []
        for bot in directory.bots {
            let name = bot.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, text.count >= name.count,
                  MentionDirectory.fold(String(text.prefix(name.count))) == MentionDirectory.fold(name),
                  text.dropFirst(name.count).first.map(endsWord) ?? true else { continue }
            named.append((bot, name.count))
        }
        let typed = text.prefix { !$0.isWhitespace }
        guard let length = named.map(\.length).max() else {
            return .failure(Problem(message: TelegramReply.unknownBot(String(typed), among: directory.bots)))
        }
        var twins = named.filter { $0.length == length }.map(\.bot)
        var rest = text.dropFirst(length)
        if let tag = idTag(rest) {
            let matching = twins.filter { $0.id.uuidString.lowercased().hasPrefix(tag.id) }
            guard !matching.isEmpty else {
                return .failure(Problem(message: TelegramReply.unknownBot(String(text.prefix(length)) + " [\(tag.id)]", among: directory.bots)))
            }
            twins = matching
            rest = tag.rest
        }
        guard twins.count == 1 else {
            return .failure(Problem(message: TelegramReply.ambiguousBot(String(text.prefix(length)), twins.map {
                (directory.word(for: $0), $0.title)
            })))
        }
        return .success((twins[0], rest))
    }

    /// The start of an ID in brackets right after a bot's name: `[1a2b3c4d]`.
    static func idTag(_ text: Substring) -> (id: String, rest: Substring)? {
        let start = text.drop { $0 == " " }
        guard start.first == "[", let close = start.firstIndex(of: "]") else { return nil }
        let id = start[start.index(after: start.startIndex)..<close].lowercased()
        guard (4...36).contains(id.count), id.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        return (id, start[start.index(after: close)...])
    }

    /// The repository `text` names, up to white space; nil when it names none and isn't meant to
    /// (a hashtag, an issue number).
    static func repository(at text: Substring, in directory: TelegramDirectory) -> Result<(repo: String, rest: Substring)?, Problem> {
        var token = text.prefix { !$0.isWhitespace }
        let rest = text.dropFirst(token.count)
        while let last = token.last, ",:;.!?)".contains(last) { token = token.dropLast() }
        let name = String(token)
        guard !name.isEmpty, !name.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .success(nil) }
        let qualified = name.contains("/")
        guard let projects = directory.projects else {
            return qualified ? .failure(Problem(message: TelegramReply.projectsNotLoaded(name))) : .success(nil)
        }
        let matches = projects.filter {
            (qualified ? $0.repo : TaskNaming.repoName($0.repo)).caseInsensitiveCompare(name) == .orderedSame
        }
        switch matches.count {
        case 1: return .success((matches[0].repo, rest))
        case 0: return qualified ? .failure(Problem(message: TelegramReply.unknownRepository(name))) : .success(nil)
        default: return .failure(Problem(message: TelegramReply.ambiguousRepository(name, matches.map(\.repo))))
        }
    }
}

/// What a Telegram chat chose with `@` and `#` (#114), kept in `telegram.json`: the bot its messages
/// go to instead of its bot in Settings, until it chooses another, and a repository for its next
/// message. Both stand only while Settings gives the chat the bot it had when they were chosen
/// (`mapped`): choosing another bot for the chat in Settings, or removing the chat, sets them aside.
public struct TelegramSelection: Codable, Equatable, Sendable {
    public var chat: Int64
    public var mapped: UUID?
    public var botID: UUID?
    /// The bot's name when it was chosen, to say which one isn't there any more.
    public var botName: String?
    /// `owner/name`, for the chat's next message.
    public var repo: String?

    public init(chat: Int64, mapped: UUID?, botID: UUID? = nil, botName: String? = nil, repo: String? = nil) {
        self.chat = chat
        self.mapped = mapped
        self.botID = botID
        self.botName = botName
        self.repo = repo
    }

    /// The bot the chat's messages go to: the one it chose, else its bot in Settings.
    public var recipient: UUID? { botID ?? mapped }
    public var isEmpty: Bool { botID == nil && repo == nil }
}

/// What a typed inline query (`@yourbot …`) is offered (#114): BotChu's bots after `@` (or nothing),
/// its repositories after `#`, never both in one list, filtered as BotChu's own `@` and `#` lists are
/// (`MentionDirectory`). Choosing one sends, through the bot, the address words it makes (`@Danny`,
/// `#owner/repo`, or both) and nothing else: Telegram sends a chosen result at once, so the list is
/// offered only while the query holds address words alone, never a draft a tap would lose.
public struct TelegramSuggestions: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var title: String
        public var description: String
        /// The message choosing it sends.
        public var message: String
    }

    public var items: [Item]
    /// Shown above the list when it's empty for a reason worth saying.
    public var note: String?

    /// Telegram shows at most 50.
    public static let limit = 50

    public static func answer(_ query: String, in directory: TelegramDirectory, username: String?, current: UUID?) -> TelegramSuggestions {
        let text = String(query.drop { $0.isWhitespace })
        let typed: MentionQuery
        if text.trimmingCharacters(in: .whitespaces) == "#" {
            typed = MentionQuery(kind: .project, text: "", range: NSRange(location: (text as NSString).range(of: "#").location, length: 1))
        } else if let found = MentionQuery.at((text as NSString).length, in: text) {
            typed = found
        } else if !text.contains("@"), !text.contains("#"), text.count <= MentionQuery.maxAgentLength,
                  !text.contains(where: { $0.isNewline || MentionQuery.agentStops.contains($0) }) {
            // Telegram's own `@yourbot ` is the `@`: what follows names a bot.
            typed = MentionQuery(kind: .agent, text: text, range: NSRange(location: 0, length: (text as NSString).length))
        } else {
            return TelegramSuggestions(items: [])
        }
        // What comes before the word being typed must be address words already complete.
        let before = (text as NSString).substring(to: typed.range.location)
        guard case .success(let chosen) = TelegramAddress.parse(before, in: directory, username: username),
              chosen.body.isEmpty, !chosen.isTask else { return TelegramSuggestions(items: []) }
        let mentions = MentionDirectory(agents: directory.bots, projects: directory.projects ?? [])
        switch typed.kind {
        case .agent:
            let bots = mentions.agents(matching: typed.text)
            guard !bots.isEmpty else {
                return TelegramSuggestions(items: [], note: directory.bots.isEmpty ? "BotChu has no bots yet" : "No bot is called “\(typed.text)”")
            }
            return TelegramSuggestions(items: bots.prefix(limit).map { bot in
                var detail = MentionDirectory.detail(of: bot, among: directory.bots)
                if bot.id == current { detail = detail.isEmpty ? "Talking to it now" : detail + " · talking to it now" }
                let words = [directory.word(for: bot)] + (chosen.repo.map { ["#" + $0] } ?? [])
                return Item(title: [bot.emoji, bot.name].filter { !$0.isEmpty }.joined(separator: " "), description: detail,
                            message: words.joined(separator: " "))
            })
        case .project:
            guard directory.projects != nil else { return TelegramSuggestions(items: [], note: "Projects aren’t loaded in BotChu yet") }
            let projects = mentions.projects(matching: typed.text)
            guard !projects.isEmpty else {
                return TelegramSuggestions(items: [], note: typed.text.isEmpty ? "No repositories in BotChu’s Projects" : "No repository matches “\(typed.text)”")
            }
            return TelegramSuggestions(items: projects.prefix(limit).map { project in
                let short = TaskNaming.repoName(project.repo)
                let name = MentionDirectory.fold(project.name) == MentionDirectory.fold(short) ? nil : project.name
                let words = (chosen.bot.map { [directory.word(for: $0)] } ?? []) + ["#" + project.repo]
                return Item(title: project.repo, description: [name, project.status?.rawValue, project.workplace].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " · "), message: words.joined(separator: " "))
            })
        }
    }
}

/// The gateway's words about `@`, `#` and `/task` (#114).
extension TelegramReply {
    static func unknownBot(_ typed: String, among bots: [BotRosterEntry]) -> String {
        let names = bots.prefix(12).map(\.name).joined(separator: ", ") + (bots.count > 12 ? ", …" : "")
        let known = bots.isEmpty ? "BotChu has no bots yet." : "Your bots: \(names)."
        return "No BotChu bot is called “\(typed)”, so this message wasn't sent. \(known) Start a message with @ and one of these names."
    }

    static func ambiguousBot(_ name: String, _ choices: [(word: String, title: String)]) -> String {
        let list = choices.map { $0.title.isEmpty ? $0.word : "\($0.word) (\($0.title))" }.joined(separator: ", ")
        return "More than one bot is called \(name), so this message wasn't sent. Start it with one of these: \(list)."
    }

    static func projectsNotLoaded(_ name: String) -> String {
        "BotChu hasn't loaded your Projects yet, so #\(name) can't be checked and this message wasn't sent. Open Projects in BotChu, then send it again."
    }

    static func unknownRepository(_ name: String) -> String {
        "#\(name) isn't in your Projects in BotChu, so this message wasn't sent. Name a repository as owner/name, as Projects lists it."
    }

    static func ambiguousRepository(_ name: String, _ repos: [String]) -> String {
        "More than one repository is called \(name), so this message wasn't sent. Use one of these: \(repos.map { "#" + $0 }.joined(separator: ", "))."
    }

    /// What choosing a bot, a repository or both says. Nothing is sent or started.
    static func selected(bot: String?, repo: String?, recipient: String?) -> String {
        var parts: [String] = []
        if let bot { parts.append("Now talking to \(bot): your messages go to its Home until you choose another bot with @.") }
        if let repo {
            let to = bot == nil ? recipient.map { " (to \($0))" } ?? "" : ""
            parts.append("#\(repo) goes with your next message\(to). Start that message with /task to post it in \(repo)'s area.")
        }
        return parts.joined(separator: " ")
    }

    /// A message for a bot the chat chose that isn't in BotChu any more: never sent to another.
    static func chosenUnavailable(_ name: String?) -> String {
        "\(name ?? "The bot you chose") isn't in BotChu any more, so this message wasn't sent. Choose another bot with @ and its name."
    }

    static func chosenGone(_ name: String?) -> String {
        "Messages here go to \(name ?? "the bot you chose"), which isn't in BotChu any more. Choose another bot with @ and its name.\n\n" + choosing
    }

    static let taskNeedsRepository = "A task works in a repository: start the message with /task #owner/repo and say what to do, or choose a repository with # first. Nothing was started."
    static let taskNeedsBrief = "Say what the task is after /task. Nothing was started."
    static let nothingToSend = "Write a message after the bot's name, or send @ and a bot's name to talk to it."

    public static func taskStarted(_ title: String, bot: String, repo: String) -> String {
        "Started “\(title)” for \(bot) in \(repo): a task of its own in BotChu, under \(bot), with its own conversation. Its replies stay in BotChu."
    }

    public static func taskPosted(in area: String, bot: String, owner: String?, repo: String) -> String {
        guard let owner else { return "Posted in \(bot)'s area “\(area)” for \(repo). Its replies stay in BotChu." }
        return "Posted in \(owner)'s area “\(area)” for \(repo), for \(bot): \(owner) has that repository. Its replies stay in BotChu."
    }

    static func taskAlreadyStarted(_ title: String) -> String { "BotChu already has this request: “\(title)”." }

    static func taskNotStarted(_ reason: String) -> String { "BotChu couldn't start this task: \(reason)" }
}
