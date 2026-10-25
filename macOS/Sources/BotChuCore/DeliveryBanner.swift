import Foundation

/// A delivery's macOS banner, shown as it arrives while BotChu is in the background: from its
/// sender, with its title, its question (or the start of its note), a button per choice, and Reply.
/// A button or Reply answers the delivery as a reply from the Inbox would; clicking the banner
/// shows the delivery.
public struct DeliveryBanner: Equatable, Sendable {
    /// What the owner did with a banner, by the action's identifier.
    public enum Action: Equatable, Sendable {
        /// The button of the question's choice at this index.
        case choice(Int)
        /// Reply, with what the owner typed.
        case reply
        /// The banner itself, clicked.
        case open

        public var identifier: String {
            switch self {
            case .choice(let index): "choice.\(index)"
            case .reply: "reply"
            case .open: "open"
            }
        }

        public init?(identifier: String) {
            switch identifier {
            case "reply": self = .reply
            case "open": self = .open
            default:
                guard identifier.hasPrefix("choice."), let index = Int(identifier.dropFirst("choice.".count)), index >= 0 else { return nil }
                self = .choice(index)
            }
        }
    }

    /// The buttons a banner has, registered with the system by `identifier`: one per delivery that
    /// offers choices, and one per sender for Reply alone, since Reply's placeholder names the bot.
    public struct Category: Equatable, Sendable {
        public var identifier: String
        /// A button each, in order, before Reply.
        public var choices: [String]
        public var replyPlaceholder: String

        public init(identifier: String, choices: [String], replyPlaceholder: String) {
            self.identifier = identifier
            self.choices = choices
            self.replyPlaceholder = replyPlaceholder
        }

        public var actions: [Action] { choices.indices.map(Action.choice) + [.reply] }
    }

    /// What a click on a banner asks for.
    public struct Response: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// Send this into the conversation that sent the delivery, word for word.
            case reply(String)
            /// Bring BotChu forward and show the delivery.
            case open
        }

        public var deliveryID: UUID
        public var kind: Kind

        public init(deliveryID: UUID, kind: Kind) {
            self.deliveryID = deliveryID
            self.kind = kind
        }
    }

    /// The system shows up to ten actions on a notification; Reply takes one.
    public static let maxActions = 10
    /// Banners can be answered while they are in Notification Center: the categories of this many
    /// recent ones stay registered.
    public static let keptCategories = 20
    /// The note's start, in characters, when the delivery asks nothing.
    public static let maxBody = 240

    public static let deliveryKey = "delivery"
    public static let choicesKey = "choices"

    public var deliveryID: UUID
    public var botID: UUID
    /// The sender, and who it credits.
    public var title: String
    public var subtitle: String
    /// Its question, or the start of its note as plain text.
    public var body: String
    public var category: Category

    public init(delivery: Delivery, sender: String) {
        deliveryID = delivery.id
        botID = delivery.botID
        title = Self.sender(sender, credits: delivery.credits)
        subtitle = delivery.title
        body = delivery.question?.text ?? Self.plainText(delivery.note)
        let choices = Array((delivery.question?.choices ?? []).prefix(Self.maxActions - 1))
        let placeholder = "Reply to \(sender)"
        category = choices.isEmpty
            ? Category(identifier: "inbox.reply.\(delivery.botID.uuidString.lowercased())", choices: [], replyPlaceholder: placeholder)
            : Category(identifier: "inbox.choices.\(delivery.id.uuidString.lowercased())", choices: choices, replyPlaceholder: placeholder)
    }

    /// What the notification carries, to know its delivery and the buttons it had when clicked.
    public var userInfo: [String: Any] {
        [Self.deliveryKey: deliveryID.uuidString, Self.choicesKey: category.choices]
    }

    /// "Product Fox", or "Product Fox with Research Assistant" when it credits another bot.
    public static func sender(_ name: String, credits: [Delivery.Credit]) -> String {
        let others = credits.map(\.name)
        guard let last = others.last else { return name }
        let rest = others.dropLast()
        return "\(name) with " + (rest.isEmpty ? last : "\(rest.joined(separator: ", ")) and \(last)")
    }

    /// The note's first paragraph, up to three lines, without its Markdown.
    public static func plainText(_ markdown: String, maxLines: Int = 3) -> String {
        var lines: [String] = []
        var fenced = false
        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if line.isEmpty { if lines.isEmpty { continue } else { break } }
            if !fenced { line = inline(blockless(line)) }
            guard !line.isEmpty else { continue }
            lines.append(line)
            if lines.count == maxLines { break }
        }
        let text = lines.joined(separator: " ")
        return text.count > maxBody ? String(text.prefix(maxBody - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }

    /// The line without a heading's, list item's or quote's marker.
    private static func blockless(_ line: String) -> String {
        var line = Substring(line)
        while line.hasPrefix(">") { line = line.dropFirst().drop(while: { $0 == " " }) }
        if let marker = line.firstIndex(of: " "), line[..<marker].allSatisfy({ $0 == "#" }), !line[..<marker].isEmpty {
            line = line[marker...].drop(while: { $0 == " " })
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            line = line.dropFirst(2)
            for box in ["[ ] ", "[x] ", "[X] "] where line.hasPrefix(box) { line = line.dropFirst(box.count) }
        } else if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), !line[..<dot].isEmpty,
                  line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ") {
            line = line[line.index(after: dot)...].drop(while: { $0 == " " })
        }
        return String(line)
    }

    /// The text without emphasis, code marks, and links' or images' targets.
    private static func inline(_ text: String) -> String {
        var text = text
        for (pattern, template) in [(#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"(\*\*|__|~~)(.+?)\1"#, "$2"),
                                    (#"(?<![\w*])[*_](\S(?:.*?\S)?)[*_](?![\w*])"#, "$1"), ("`+", "")] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// What a click on a banner asks for: `action` is its identifier (`Action`), with the system's
    /// default action as `open`; `text` is what Reply sent. Nil for one that asks nothing.
    public static func response(action: String, userInfo: [AnyHashable: Any], text: String?) -> Response? {
        guard let id = (userInfo[deliveryKey] as? String).flatMap(UUID.init(uuidString:)), let action = Action(identifier: action) else {
            return nil
        }
        switch action {
        case .open:
            return Response(deliveryID: id, kind: .open)
        case .reply:
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Response(deliveryID: id, kind: .reply(text))
        case .choice(let index):
            guard let choices = userInfo[choicesKey] as? [String], choices.indices.contains(index) else { return nil }
            return Response(deliveryID: id, kind: .reply(choices[index]))
        }
    }
}

/// The banner categories registered with the system: the newest `DeliveryBanner.keptCategories`,
/// so their banners keep their buttons in Notification Center, and the set stays bounded.
public struct BannerCategories: Equatable, Sendable {
    public private(set) var all: [DeliveryBanner.Category] = []

    public init() {}

    /// Adds a banner's category, or brings it up to date, as the newest; true when the set changed.
    @discardableResult
    public mutating func add(_ category: DeliveryBanner.Category) -> Bool {
        let before = all
        all.removeAll { $0.identifier == category.identifier }
        all.append(category)
        if all.count > DeliveryBanner.keptCategories { all.removeFirst(all.count - DeliveryBanner.keptCategories) }
        return all != before
    }
}
