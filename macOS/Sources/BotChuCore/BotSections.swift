import Foundation

/// The sections the owner groups bots into in the sidebar and Agents. A bot is in one section, by its
/// name, or in none; the bots in none come first, under Conversations, then each section in turn,
/// each with its bots in order. A bot's section is kept with its place in `index.json`
/// (`Store.Entry`), so a section lasts while a bot is in it.
public struct BotSections: Equatable, Sendable {
    /// The heading of the bots in no section, which no section can be named.
    public static let unsectioned = "Conversations"

    /// A heading in the sidebar and its bots, in order.
    public struct Group: Identifiable, Equatable, Sendable {
        /// Nil for the bots in no section.
        public var name: String?
        public var botIDs: [UUID]

        public init(name: String?, botIDs: [UUID]) {
            self.name = name
            self.botIDs = botIDs
        }

        public var title: String { name ?? BotSections.unsectioned }
        public var id: String { title }
    }

    /// The bots in sidebar order: the bots in no section, then each section's.
    public private(set) var order: [UUID]
    /// The section of each bot in one.
    public private(set) var membership: [UUID: String]

    /// The bots in `order`, each in the section `membership` names, regrouped so that each section's
    /// bots are together where its first bot was. Names are tidied as typed ones are
    /// (`sectionName(_:)`), and one that differs only in case joins the section listed first.
    public init(order: [UUID], membership: [UUID: String]) {
        var names: [String] = []
        var tidied: [UUID: String] = [:]
        for id in order {
            guard let typed = membership[id], let name = Self.tidy(typed) else { continue }
            let existing = names.first { $0.caseInsensitiveCompare(name) == .orderedSame }
            if existing == nil { names.append(name) }
            tidied[id] = existing ?? name
        }
        self.order = order
        self.membership = tidied
        self.order = groups.flatMap(\.botIDs)
    }

    /// The headings and their bots, in order. Conversations comes first while a bot is in no
    /// section, and also when there are no sections at all, as before there were any.
    public var groups: [Group] {
        var groups: [Group] = []
        let loose = order.filter { membership[$0] == nil }
        if !loose.isEmpty || membership.isEmpty { groups.append(Group(name: nil, botIDs: loose)) }
        var index: [String: Int] = [:]
        for id in order {
            guard let name = membership[id] else { continue }
            if let i = index[name] {
                groups[i].botIDs.append(id)
            } else {
                index[name] = groups.count
                groups.append(Group(name: name, botIDs: [id]))
            }
        }
        return groups
    }

    /// The headings and bots a search for `query` finds, in order, as Agents shows them: a heading
    /// whose title has the query in it keeps all its bots, any other only the bots whose `text` has
    /// it, and a heading with neither is left out. An empty query finds every heading, as `groups`.
    public func groups(matching query: String, text: (UUID) -> String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(query) { return group }
            let found = group.botIDs.filter { text($0).localizedCaseInsensitiveContains(query) }
            return found.isEmpty ? nil : Group(name: group.name, botIDs: found)
        }
    }

    /// The sections' names, in order.
    public var names: [String] { groups.compactMap(\.name) }

    public func section(of id: UUID) -> String? { membership[id] }

    /// The section a name the owner typed stands for: the name with its spaces tidied, or the
    /// existing section's when they differ only in case; nil, for no section, when it is empty or
    /// Conversations.
    public func sectionName(_ typed: String) -> String? {
        guard let name = Self.tidy(typed) else { return nil }
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    /// Adds a new bot: in no section, after the bots already there and before the first section. A
    /// bot already listed stays where it is.
    public mutating func add(_ id: UUID) {
        guard !order.contains(id) else { return }
        order.insert(id, at: order.firstIndex { membership[$0] != nil } ?? order.endIndex)
    }

    /// Puts a bot in the section `typed` names, last among its bots, or in none with nil. A new name
    /// starts a section, listed last. A bot already there keeps its place.
    public mutating func move(_ id: UUID, to typed: String?) {
        let section = typed.flatMap { sectionName($0) }
        guard order.contains(id), membership[id] != section else { return }
        order.removeAll { $0 == id }
        membership[id] = section
        let end: Int
        if let section {
            // After the section's last bot; a new section's first bot goes last.
            end = order.lastIndex { membership[$0] == section }.map { $0 + 1 } ?? order.endIndex
        } else {
            // After the bots in no section, before the first section.
            end = order.firstIndex { membership[$0] != nil } ?? order.endIndex
        }
        order.insert(id, at: end)
    }

    /// Renames a section in place. A name another section has merges the two: this one's bots go
    /// last in that one. Conversations returns its bots to no section; an empty name changes nothing.
    public mutating func rename(_ section: String, to typed: String) {
        let members = order.filter { membership[$0] == section }
        guard !members.isEmpty, !typed.allSatisfy(\.isWhitespace) else { return }
        guard let name = Self.tidy(typed) else {
            remove(section)
            return
        }
        if let other = names.first(where: { $0 != section && $0.caseInsensitiveCompare(name) == .orderedSame }) {
            for id in members { move(id, to: other) }
        } else {
            for id in members { membership[id] = name }
        }
    }

    /// Removes a section: its bots go back to no section, after the bots already there. No bot is
    /// deleted.
    public mutating func remove(_ section: String) {
        for id in order.filter({ membership[$0] == section }) { move(id, to: nil) }
    }

    /// Moves a section before the one above it (offset -1) or after the one below (+1). The bots in
    /// no section stay first.
    public mutating func moveSection(_ section: String, by offset: Int) {
        var sections = groups.filter { $0.name != nil }
        guard let from = sections.firstIndex(where: { $0.name == section }),
              sections.indices.contains(from + offset) else { return }
        sections.insert(sections.remove(at: from), at: from + offset)
        order = order.filter { membership[$0] == nil } + sections.flatMap(\.botIDs)
    }

    /// Whether a saved name, such as a missing bot's in `index.json`, stands for the section `name`.
    public static func matches(_ saved: String?, section name: String) -> Bool {
        saved.flatMap(tidy)?.caseInsensitiveCompare(name) == .orderedSame
    }

    /// A typed name with its runs of spaces and line breaks made single spaces and its ends trimmed,
    /// or nil when that leaves nothing, or Conversations.
    static func tidy(_ typed: String) -> String? {
        let name = typed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !name.isEmpty, name.caseInsensitiveCompare(unsectioned) != .orderedSame else { return nil }
        return name
    }
}
