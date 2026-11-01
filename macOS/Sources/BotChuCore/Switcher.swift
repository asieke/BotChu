import Foundation

/// A result of ⌘K's switcher (#428): an agent, a specialist or a project, and where choosing it goes.
public struct SwitcherItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case agent, specialist, project

        public var label: String {
            switch self {
            case .agent: "Agent"
            case .specialist: "Specialist"
            case .project: "Project"
            }
        }
    }

    public enum Place: Hashable, Sendable {
        /// A bot: an agent's conversation, or a specialist's row in Agents.
        case bot(UUID)
        /// A repository (`owner/name`): its area, else its page in Projects.
        case repo(String)
        /// A folder's area.
        case area(botID: UUID, taskID: UUID)
    }

    public var kind: Kind
    public var place: Place
    public var title: String
    /// What tells it apart: an agent's title; a project's `owner/name` and the bot whose area it is.
    public var detail: String
    /// A bot's pet emoji; empty for a project.
    public var emoji: String
    public var id: Place { place }

    public init(kind: Kind, place: Place, title: String, detail: String, emoji: String = "") {
        self.kind = kind
        self.place = place
        self.title = title
        self.detail = detail
        self.emoji = emoji
    }
}

/// What ⌘K's switcher searches, made once when it opens: the bots, the Projects catalog and the
/// areas not in it (folders, and repositories before the catalog loads), matched by name as `@` and
/// `#` completion match them (`MentionDirectory`), so filtering while typing stays quick. Results are
/// ranked by how well they match, then agents, specialists and projects, then as the directory
/// orders each (bots in the sidebar's order, active projects first).
public struct SwitcherIndex: Sendable {
    let directory: MentionDirectory
    let bots: [SwitcherItem]
    let projects: [SwitcherItem]

    /// - Parameters:
    ///   - bots: every bot, specialists too, in the sidebar's order.
    ///   - catalog: the saved Projects catalog.
    ///   - areas: the areas not hidden, each with its bot, in the sidebar's order.
    public init(bots: [BotRosterEntry], catalog: [ProjectCatalogEntry], areas: [(bot: BotRosterEntry, area: BotTask)]) {
        self.bots = bots.map { bot in
            SwitcherItem(kind: bot.isSpecialist ? .specialist : .agent, place: .bot(bot.id), title: bot.name, detail: bot.title, emoji: bot.emoji)
        }
        var owners: [String: String] = [:]
        for (bot, area) in areas where area.area?.kind == .repo && owners[area.repo.lowercased()] == nil {
            owners[area.repo.lowercased()] = bot.name
        }
        func detail(_ repo: String) -> String { owners[repo.lowercased()].map { "\(repo) · \($0)" } ?? repo }
        var entries = catalog
        var items = catalog.map { SwitcherItem(kind: .project, place: .repo($0.repo), title: $0.name, detail: detail($0.repo)) }
        let listed = Set(catalog.map { $0.repo.lowercased() })
        for (bot, area) in areas {
            guard let info = area.area else { continue }
            switch info.kind {
            case .repo:
                guard !listed.contains(area.repo.lowercased()), !items.contains(where: { $0.place == .repo(area.repo) }) else { continue }
                entries.append(ProjectCatalogEntry(name: info.name, repo: area.repo))
                items.append(SwitcherItem(kind: .project, place: .repo(area.repo), title: info.name, detail: detail(area.repo)))
            case .folder:
                entries.append(ProjectCatalogEntry(name: info.name, repo: info.name))
                items.append(SwitcherItem(kind: .project, place: .area(botID: bot.id, taskID: area.id), title: info.name, detail: "Folder · \(bot.name)"))
            }
        }
        projects = items
        directory = MentionDirectory(agents: bots, projects: entries)
    }

    /// The bots and projects whose names match `query`, best first, at most `limit`; all of them,
    /// up to `limit`, for an empty query.
    public func results(matching query: String, limit: Int = 50) -> [SwitcherItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let bots = directory.rankedAgents(matching: query).enumerated().map { rank, match in
            (tier: match.tier, kind: self.bots[match.offset].kind == .agent ? 0 : 1, rank: rank, item: self.bots[match.offset])
        }
        let projects = directory.rankedProjects(matching: query).enumerated().map { rank, match in
            (tier: match.tier, kind: 2, rank: rank, item: self.projects[match.offset])
        }
        return (bots + projects).sorted { ($0.tier, $0.kind, $0.rank) < ($1.tier, $1.kind, $1.rank) }.prefix(limit).map(\.item)
    }
}

/// The switcher's highlighted row (#428): the first when its results change, moved by the arrow
/// keys and kept within them.
public enum SwitcherHighlight {
    public static func moved(_ index: Int, by offset: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(index + offset, 0), count - 1)
    }
}
