import Foundation

/// Something a bot hands its owner on purpose with `botchu-inbox send`: a note, copies of files,
/// pull request and issue links, and a question with choices. It arrives in the Inbox and shows in
/// the chat of the conversation that sent it; a reply from the Inbox goes into that conversation.
///
/// It is kept with the bot of that conversation (`.botchu/inbox/<id>/`, `InboxFolder`): a sub-agent's
/// delivery is its caller's, at the top of the chain, crediting the sub-agent's bot.
public struct Delivery: Identifiable, Codable, Hashable, Sendable {
    /// A bot credited for the work besides the sender.
    public struct Credit: Codable, Hashable, Sendable {
        public var botID: UUID
        public var name: String

        public init(botID: UUID, name: String) {
            self.botID = botID
            self.name = name
        }
    }

    /// A copy of a file, taken when the delivery was sent, in its folder's `files/`.
    public struct File: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Markdown or plain text, shown with the chat's Markdown.
            case document
            /// An HTML page, shown in a web view without network access.
            case page
            case image
            case other
        }

        /// Its name as sent, and in `files/`.
        public var name: String
        public var kind: Kind
        public var bytes: Int
        /// Where it was copied from, on the machine that sent it, to find the live file.
        public var source: String?
        /// The bot whose work it is, when not the sender's (a sub-agent's).
        public var credit: Credit?

        public init(name: String, kind: Kind, bytes: Int, source: String? = nil, credit: Credit? = nil) {
            self.name = name
            self.kind = kind
            self.bytes = bytes
            self.source = source
            self.credit = credit
        }

        public static func kind(of name: String) -> Kind {
            switch (name as NSString).pathExtension.lowercased() {
            case "md", "markdown", "txt", "text": .document
            case "html", "htm": .page
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif": .image
            default: .other
            }
        }
    }

    /// A pull request or issue on GitHub.
    public struct Link: Codable, Hashable, Sendable {
        public var repo: String
        public var number: Int
        public var isPullRequest: Bool

        public init(repo: String, number: Int, isPullRequest: Bool) {
            self.repo = repo
            self.number = number
            self.isPullRequest = isPullRequest
        }

        public var url: URL? { URL(string: "https://github.com/\(repo)/\(isPullRequest ? "pull" : "issues")/\(number)") }

        /// `owner/name`, as GitHub allows them.
        public static func isRepo(_ text: String) -> Bool {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { part in
                !part.isEmpty && part.count <= 100 && part != "." && part != ".."
                    && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
            }
        }

        /// `owner/name#12`, a GitHub URL of a pull request or issue, or a number with `repo` given.
        public static func parse(_ text: String, isPullRequest: Bool, defaultRepo: String? = nil) -> Link? {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: text), url.host?.lowercased() == "github.com" {
                let parts = url.path.split(separator: "/").map(String.init)
                guard parts.count >= 4, ["pull", "issues"].contains(parts[2]), let number = Int(parts[3]), number > 0 else { return nil }
                return Link(repo: "\(parts[0])/\(parts[1])", number: number, isPullRequest: parts[2] == "pull")
            }
            let pieces = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let repo = pieces.count == 2 && !pieces[0].isEmpty ? pieces[0] : defaultRepo
            guard let number = Int(pieces.count == 2 ? pieces[1] : text.replacingOccurrences(of: "#", with: "")), number > 0,
                  let repo, Delivery.Link.isRepo(repo) else { return nil }
            return Link(repo: repo, number: number, isPullRequest: isPullRequest)
        }
    }

    /// What the bot can't go on without, with answers to choose in one click.
    public struct Question: Codable, Hashable, Sendable {
        public var text: String
        public var choices: [String]

        public init(text: String, choices: [String] = []) {
            self.text = text
            self.choices = choices
        }
    }

    public var id: UUID
    /// The bot whose conversation sent it, which keeps it.
    public var botID: UUID
    /// That conversation: one of the bot's tasks, or nil for its Home.
    public var taskID: UUID?
    public var title: String
    /// Markdown.
    public var note: String
    public var files: [File]
    public var links: [Link]
    public var question: Question?
    public var credits: [Credit]
    public var sentAt: Date
    /// When it was last sent again with the same title, in the same turn; `sentAt` until then.
    public var updatedAt: Date

    public init(id: UUID = UUID(), botID: UUID, taskID: UUID? = nil, title: String, note: String = "", files: [File] = [],
                links: [Link] = [], question: Question? = nil, credits: [Credit] = [], sentAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.botID = botID
        self.taskID = taskID
        self.title = title
        self.note = note
        self.files = files
        self.links = links
        self.question = question
        self.credits = credits
        // As its record keeps them, so an answer stamped in the same second still counts.
        self.sentAt = Self.stamp(sentAt)
        self.updatedAt = Self.stamp(updatedAt ?? sentAt)
    }

    /// A date as its record keeps it: in whole seconds.
    public static func stamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    public var pullRequests: [Link] { links.filter(\.isPullRequest) }

    /// Its card in the chat of the conversation that sent it: a note, which BotChu versions without
    /// the Inbox show as its text.
    public var card: ChatMessage {
        var note = ChatMessage(role: .note, text: "Delivered to your Inbox: \(title)", date: sentAt)
        note.delivery = id
        return note
    }
    public var issues: [Link] { links.filter { !$0.isPullRequest } }
}

// MARK: The request from `botchu-inbox send`

/// A delivery as it reaches BotChu through the sending turn's mailbox, beside its sub-agent and
/// Task requests: who sends it (the turn's identifiers) and what, with its files staged in the
/// mailbox (`inbox/<request id>/`) by the helper, so they are copies from the moment it ran.
public struct InboxRequest: Equatable, Sendable {
    /// The `kind` that tells a delivery from the other requests in the mailbox.
    public static let kind = "inbox"
    public static let maxTitleCharacters = 200
    public static let maxNoteBytes = 160_000
    public static let maxFiles = 20
    public static let maxFileBytes = 20 << 20
    public static let maxLinks = 40
    public static let maxChoices = 6

    /// A file the helper copied into the mailbox.
    public struct StagedFile: Equatable, Sendable {
        public var name: String
        /// Its path in the mailbox, relative to the mailbox's folder.
        public var staged: String
        public var bytes: Int
        public var source: String?
    }

    public var id: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    public var title: String
    public var note: String
    public var files: [StagedFile]
    public var links: [Delivery.Link]
    public var question: Delivery.Question?
    /// Bots credited by name, slug or ID (`--credit`).
    public var credits: [String]
    public var createdAt: Date

    public struct Problem: Error, Equatable, Sendable, LocalizedError {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Whether a mailbox request is a delivery.
    public static func isDelivery(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String == kind
    }

    public static func parse(_ data: Data) throws -> InboxRequest {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["kind"] as? String == kind else {
            throw Problem("it isn't a delivery")
        }
        func uuid(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
        guard let id = uuid("id"), let invocationID = uuid("invocationID"), let callerBotID = uuid("callerBotID"),
              let fields = object["delivery"] as? [String: Any] else {
            throw Problem("it doesn't say which turn sent it")
        }
        let title = ((fields["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= maxTitleCharacters else {
            throw Problem("give it a title of 1–\(maxTitleCharacters) characters (--title)")
        }
        let note = ((fields["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.utf8.count <= maxNoteBytes else { throw Problem("the note is larger than \(maxNoteBytes / 1000) KB") }
        let files = try ((fields["files"] as? [[String: Any]]) ?? []).map { file -> StagedFile in
            guard let name = file["name"] as? String, Self.isSafeName(name),
                  let staged = file["staged"] as? String, Self.isStagedPath(staged, request: id),
                  let bytes = file["bytes"] as? Int, (0...maxFileBytes).contains(bytes) else {
                throw Problem("a file it sends can't be read as sent")
            }
            return StagedFile(name: name, staged: staged, bytes: bytes, source: file["source"] as? String)
        }
        guard files.count <= maxFiles else { throw Problem("send at most \(maxFiles) files") }
        guard Set(files.map(\.name)).count == files.count else { throw Problem("two of its files have the same name") }
        let links = try ((fields["links"] as? [[String: Any]]) ?? []).map { link -> Delivery.Link in
            guard let repo = link["repo"] as? String, Delivery.Link.isRepo(repo), let number = link["number"] as? Int, number > 0 else {
                throw Problem("a pull request or issue isn't owner/name#number")
            }
            return Delivery.Link(repo: repo, number: number, isPullRequest: link["pullRequest"] as? Bool ?? false)
        }
        guard links.count <= maxLinks else { throw Problem("link at most \(maxLinks) pull requests and issues") }
        var question: Delivery.Question?
        if let asked = fields["question"] as? [String: Any] {
            let text = ((asked["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let choices = ((asked["choices"] as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !text.isEmpty, text.count <= 500 else { throw Problem("the question (--ask) must be 1–500 characters") }
            guard choices.count <= maxChoices, choices.allSatisfy({ $0.count <= 80 }) else {
                throw Problem("offer at most \(maxChoices) choices, each up to 80 characters")
            }
            question = Delivery.Question(text: text, choices: choices)
        }
        let credits = ((fields["credits"] as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard credits.count <= 8 else { throw Problem("credit at most 8 bots") }
        let created = (object["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return InboxRequest(id: id, invocationID: invocationID, callerBotID: callerBotID, callerTaskID: uuid("callerTaskID"),
                            parentSubagentID: uuid("parentSubagentID"), title: title, note: note, files: files, links: links,
                            question: question, credits: credits, createdAt: created)
    }

    /// Checks that the delivery comes from the turn whose mailbox it is in, as BotChu registered it.
    public func validate(_ caller: SubagentCallerContext) throws {
        guard invocationID == caller.invocationID, callerBotID == caller.botID, callerTaskID == caller.taskID,
              parentSubagentID == caller.parentSubagentID else {
            throw Problem("the sending turn no longer matches this request; send it again from the active turn")
        }
    }

    /// A file name without folders, which can't step out of the delivery's `files/`.
    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && !name.contains("\0")
    }

    /// Where the helper stages a request's files: `inbox/<request id>/<file>`, and nowhere else.
    static func isStagedPath(_ path: String, request: UUID) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 && parts[0] == "inbox" && parts[1] == request.uuidString.lowercased() && isSafeName(parts[2])
    }
}

/// What became of a delivery, as BotChu writes it into the sender's mailbox; `botchu-inbox send`
/// prints it.
public struct InboxResult: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: String
    public var delivered: Bool
    public var deliveryID: UUID?
    /// It replaced the one sent with the same title earlier in the turn.
    public var updated: Bool
    public var errorMessage: String?

    public init(id: UUID, deliveryID: UUID? = nil, updated: Bool = false, errorMessage: String? = nil) {
        self.id = id
        kind = InboxRequest.kind
        delivered = errorMessage == nil && deliveryID != nil
        self.deliveryID = deliveryID
        self.updated = updated
        self.errorMessage = errorMessage
    }
}

// MARK: Storage

/// A bot's deliveries: `.botchu/inbox/<id>/delivery.json`, with its files' copies in `files/`.
public struct InboxFolder: Sendable {
    public let url: URL

    public init(home: BotHome) {
        url = home.url.appendingPathComponent("inbox", isDirectory: true)
    }

    public func folder(_ id: UUID) -> URL { url.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    public func fileURL(_ name: String, of id: UUID) -> URL {
        folder(id).appendingPathComponent("files", isDirectory: true).appendingPathComponent(name)
    }

    /// Saves a delivery with its files' contents, replacing what was saved for it before: the files
    /// first, in a new folder that takes the old one's place, then its record, so a delivery never
    /// lists a file it hasn't got.
    public func save(_ delivery: Delivery, contents: [String: Data]) throws {
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        let fresh = url.appendingPathComponent(".\(delivery.id.uuidString.lowercased())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? files.removeItem(at: fresh) }
        try files.createDirectory(at: fresh.appendingPathComponent("files", isDirectory: true), withIntermediateDirectories: true)
        for file in delivery.files {
            guard InboxRequest.isSafeName(file.name), let data = contents[file.name] else {
                throw InboxRequest.Problem("\(file.name) wasn't received")
            }
            try data.write(to: fresh.appendingPathComponent("files").appendingPathComponent(file.name))
        }
        try Store.encoder.encode(delivery).write(to: fresh.appendingPathComponent("delivery.json"))
        let target = folder(delivery.id)
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: fresh)
        } else {
            try files.moveItem(at: fresh, to: target)
        }
    }

    /// Every delivery the bot keeps, newest first; folders that don't hold one are left out.
    public func load() -> [Delivery] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("delivery.json")))
                .flatMap { try? Store.decoder.decode(Delivery.self, from: $0) }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folder(id))
    }
}

/// What the owner did with each delivery: `inbox.json`, beside `index.json`. A delivery it doesn't
/// list is unread, isn't done and hasn't been replied to.
public struct InboxState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var read: Bool
        public var done: Bool
        /// When the owner last replied from the Inbox.
        public var repliedAt: Date?

        public init(read: Bool = false, done: Bool = false, repliedAt: Date? = nil) {
            self.read = read
            self.done = done
            self.repliedAt = repliedAt
        }
    }

    public var entries: [UUID: Entry]

    public init(entries: [UUID: Entry] = [:]) {
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case entries }

    /// By the delivery's ID as a string, so the file is an object a person can read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        entries = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }), forKey: .entries)
    }

    public subscript(id: UUID) -> Entry {
        get { entries[id] ?? Entry() }
        set { entries[id] = newValue == Entry() ? nil : newValue }
    }

    public func isUnread(_ delivery: Delivery) -> Bool { !self[delivery.id].read && !self[delivery.id].done }

    /// It asks something the owner hasn't answered since it was sent.
    public func needsAnswer(_ delivery: Delivery) -> Bool {
        delivery.question != nil && !self[delivery.id].done && !isAnswered(delivery)
    }

    /// The owner replied to it from the Inbox since it was sent.
    public func isAnswered(_ delivery: Delivery) -> Bool {
        self[delivery.id].repliedAt.map { $0 >= delivery.updatedAt } ?? false
    }

    /// The owner's answer is saved in the queue of the conversation that sent the delivery: it is
    /// answered, read and Done. What the bot does with it shows in that conversation.
    public mutating func answer(_ id: UUID, at date: Date) {
        self[id] = Entry(read: true, done: true, repliedAt: date)
    }

    public func unreadCount(_ deliveries: [Delivery]) -> Int { deliveries.filter(isUnread).count }

    /// Forgets deliveries that are gone, so the file doesn't grow with them.
    public mutating func keep(only ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    public static func url(in root: URL) -> URL { root.appendingPathComponent("inbox.json") }

    public static func load(from root: URL) -> InboxState {
        guard let data = try? Data(contentsOf: url(in: root)) else { return InboxState() }
        return (try? Store.decoder.decode(InboxState.self, from: data)) ?? InboxState()
    }

    public func save(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Store.encoder.encode(self).write(to: Self.url(in: root), options: .atomic)
    }
}

// MARK: The list

/// The Inbox's list in groups: what needs the owner's answer, Today, Yesterday, then each earlier
/// day, newest first, with Done at the end.
public enum InboxList {
    public enum Section: Hashable, Sendable {
        case needsYou, today, yesterday
        /// An earlier day, by its start.
        case day(Date)
        case done
    }

    public struct Group: Equatable, Sendable {
        public var section: Section
        public var ids: [UUID]
    }

    public static func section(of delivery: Delivery, state: InboxState, now: Date, calendar: Calendar = .current) -> Section {
        if state[delivery.id].done { return .done }
        if state.needsAnswer(delivery) { return .needsYou }
        if calendar.isDate(delivery.updatedAt, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(delivery.updatedAt, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .day(calendar.startOfDay(for: delivery.updatedAt))
    }

    /// `pinned` keeps a delivery in the group it was in (the one being read), whatever it has
    /// become since, until the owner leaves it; only Done, or moving it out of Done, moves it at once.
    public static func groups(_ deliveries: [Delivery], state: InboxState, now: Date, calendar: Calendar = .current,
                              pinned: [UUID: Section] = [:]) -> [Group] {
        var grouped: [Section: [Delivery]] = [:]
        for delivery in deliveries {
            var section = section(of: delivery, state: state, now: now, calendar: calendar)
            if section != .done, let pin = pinned[delivery.id], pin != .done { section = pin }
            grouped[section, default: []].append(delivery)
        }
        func rank(_ section: Section) -> (Int, TimeInterval) {
            switch section {
            case .needsYou: (0, 0)
            case .today: (1, 0)
            case .yesterday: (2, 0)
            case .day(let date): (3, -date.timeIntervalSinceReferenceDate)
            case .done: (4, 0)
            }
        }
        return grouped.keys.sorted { rank($0) < rank($1) }.map { section in
            Group(section: section, ids: grouped[section]!.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }.map(\.id))
        }
    }

    /// What to select when the selected delivery leaves the list shown (`was`, now `now`), as when
    /// it is Done while Done is closed: the next one still shown, else the one before, else none.
    public static func selection(after selected: UUID, was: [UUID], now: [UUID]) -> UUID? {
        guard let index = was.firstIndex(of: selected) else { return nil }
        let shown = Set(now)
        return was[(index + 1)...].first(where: shown.contains) ?? was[..<index].last(where: shown.contains)
    }
}

// MARK: Replies

/// A reply from the Inbox, which goes into the conversation that sent the delivery, through its
/// queue like any message, marked with the delivery (`ChatMessage.delivery`).
public enum InboxReply {
    /// What the bot reads: the reply, with the delivery it answers.
    public static func prompt(_ text: String, delivery: Delivery) -> String {
        "[Your owner's reply from the Inbox to your delivery “\(delivery.title)” (\(delivery.id.uuidString.lowercased()))]\n\n\(text)"
    }
}
