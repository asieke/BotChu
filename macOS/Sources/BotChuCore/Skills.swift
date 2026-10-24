import Foundation

/// A reusable workflow or tool runbook: a `SKILL.md` in a `skills/<slug>/` folder, with YAML
/// frontmatter (`name`, `description`) and the steps in Markdown, and any helper scripts or
/// references beside it. Shared skills are in the bots folder, for every bot that keeps them on; a
/// bot's own are in its workspace. Only a catalog of them (name, description and path) opens a
/// session; the agent reads a skill's file when it matches what it is doing.
public struct Skill: Identifiable, Hashable, Sendable {
    public enum Scope: String, Hashable, Sendable {
        /// In the bots folder: every bot's, unless turned off for it (`Bot.disabledSkills`).
        case shared
        /// In one bot's workspace: only that bot's, always on.
        case bot
    }

    /// The skill's folder name, which a bot's own skill shares to take a shared one's place.
    public let slug: String
    /// The frontmatter's `name`, else the slug.
    public let name: String
    /// The frontmatter's `description`, else the first line of text after the title.
    public let description: String
    public let scope: Scope
    /// The skill's `SKILL.md`.
    public let url: URL
    /// All of `SKILL.md`.
    public let text: String
    /// Files beside `SKILL.md` (helper scripts, references), which the agent reads only when it needs them.
    public let resourceCount: Int

    public var id: String { url.path }
    public var folder: URL { url.deletingLastPathComponent() }

    public init(slug: String, text: String, scope: Scope, url: URL, resourceCount: Int = 0) {
        let parsed = Skills.frontmatter(of: text)
        let name = Skills.oneLine(parsed.fields["name"] ?? "")
        self.slug = slug
        self.name = name.isEmpty ? slug : name
        let description = Skills.oneLine(parsed.fields["description"] ?? "")
        self.description = description.isEmpty ? Skills.firstLine(of: parsed.body) : description
        self.scope = scope
        self.url = url
        self.text = text
        self.resourceCount = resourceCount
    }

    /// The description as the catalog gives it: on one line, and within `Skills.maxDescription`.
    public var summary: String {
        description.count > Skills.maxDescription ? String(description.prefix(Skills.maxDescription)) + " […]" : description
    }

    /// Puts the skill's folder in the Trash.
    public func trash() throws {
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }
}

public enum Skills {
    public static let folderName = "skills"
    public static let fileName = "SKILL.md"
    /// Claude Code's limit for a skill's description; longer ones are cut in the catalog.
    public static let maxDescription = 1_024

    /// The skills every bot shares: `skills/` in the bots folder, beside the shared `MEMORY.md`.
    public static func sharedFolder(besideSharedMemory sharedMemoryPath: String) -> URL {
        URL(fileURLWithPath: (sharedMemoryPath as NSString).deletingLastPathComponent, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// A bot's own skills: `skills/` in its workspace.
    public static func folder(of bot: Bot) -> URL {
        URL(fileURLWithPath: bot.workspace, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
    }

    /// The skills in `folder`: each subfolder (or link to one) with a readable `SKILL.md`, by name.
    public static func discover(in folder: URL, scope: Skill.Scope, fileManager: FileManager = .default) -> [Skill] {
        // Paths stay as the folder is given (`contentsOfDirectory(at:)` would resolve links in them),
        // so the catalog names them as the owner's settings do.
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { name -> Skill? in
            let entry = folder.appendingPathComponent(name, isDirectory: true)
            let file = entry.appendingPathComponent(fileName)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return Skill(slug: entry.lastPathComponent, text: text, scope: scope, url: file,
                         resourceCount: resources(in: entry, fileManager: fileManager))
        }
        .sorted(by: ordered)
    }

    /// The skills a session of `bot` gets: its own, and the shared ones it keeps on, except those
    /// whose slug one of its own takes the place of.
    public static func active(for bot: Bot, shared: [Skill], own: [Skill]) -> [Skill] {
        let ownSlugs = Set(own.map(\.slug))
        return (own + shared.filter { !ownSlugs.contains($0.slug) && bot.usesSharedSkill($0.slug) }).sorted(by: ordered)
    }

    public static func active(for bot: Bot, sharedFolder: URL, fileManager: FileManager = .default) -> [Skill] {
        active(for: bot, shared: discover(in: sharedFolder, scope: .shared, fileManager: fileManager),
               own: discover(in: folder(of: bot), scope: .bot, fileManager: fileManager))
    }

    static func ordered(_ a: Skill, _ b: Skill) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.scope == .bot && b.scope == .shared : order == .orderedAscending
    }

    // MARK: Making one

    /// A folder name for a skill called `name`: lowercase letters, digits and hyphens, as the
    /// frontmatter's `name` is in other agents' skills.
    public static func slug(_ name: String) -> String {
        let slug = Bot.slug(name)
        // `Bot.slug` names a folder "bot" when nothing in the name can make one.
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return slug == "bot" && !folded.contains("bot") ? "skill" : slug
    }

    /// What a new skill starts as: its frontmatter and the outline of a runbook.
    public static func template(name: String, description: String) -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            ---
            name: \(slug(title))
            description: \(quoted(oneLine(description)))
            ---

            # \(title.isEmpty ? slug(title) : title)

            ## When to use

            ## Steps
            1.

            ## Pitfalls

            """
    }

    /// Makes `skills/<slug>/SKILL.md` in `folder` from the template, refusing a skill that exists.
    /// Returns the new `SKILL.md`.
    public static func create(name: String, description: String, in folder: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = folder.appendingPathComponent(slug(name), isDirectory: true)
        guard !fileManager.fileExists(atPath: directory.path) else { throw Problem.exists(slug(name)) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName)
        try template(name: name, description: description).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    public enum Problem: LocalizedError, Equatable {
        case exists(String)

        public var errorDescription: String? {
            switch self {
            case .exists(let slug): "There is already a skill called \(slug) there. Choose another name."
            }
        }
    }

    // MARK: Reading SKILL.md

    /// The top-level fields of a Markdown file's YAML frontmatter (between `---` lines), by
    /// lowercased key, and the text after it. Reads the scalars skills use: plain, quoted, and `|`
    /// or `>` blocks, over several lines too; nested values are kept as plain text.
    public static func frontmatter(of text: String) -> (fields: [String: String], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) })
        else { return ([:], text) }
        var fields: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard let first = line.first, !first.isWhitespace, first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // The lines that continue the value: indented ones, and blank ones between them.
            var continuation: [String] = []
            while index < end, lines[index].first.map({ $0.isWhitespace }) ?? true {
                continuation.append(lines[index])
                index += 1
            }
            while continuation.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continuation.removeLast() }
            fields[key] = scalar(value, continuation: continuation)
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    static func scalar(_ value: String, continuation: [String]) -> String {
        if let indicator = value.first, indicator == "|" || indicator == ">" {
            let indent = continuation.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
            let block = continuation.map { String($0.dropFirst(min(indent, $0.count))) }
            return indicator == "|" ? block.joined(separator: "\n") : folded(block)
        }
        let joined = ([value] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).filter { !$0.isEmpty }
            .joined(separator: " ")
        if joined.hasPrefix("\""), let close = closingQuote(in: joined, quote: "\"") {
            return unescaped(String(joined[joined.index(after: joined.startIndex)..<close]))
        }
        if joined.hasPrefix("'"), let close = closingQuote(in: joined, quote: "'") {
            return String(joined[joined.index(after: joined.startIndex)..<close]).replacingOccurrences(of: "''", with: "'")
        }
        // A plain scalar ends at a comment.
        return joined.components(separatedBy: " #").first ?? joined
    }

    /// A `>` block: lines of a paragraph join with spaces, and blank lines separate paragraphs.
    private static func folded(_ lines: [String]) -> String {
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(line) }
        }
        return paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    private static func closingQuote(in text: String, quote: Character) -> String.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if quote == "\"", character == "\\" {
                index = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                continue
            }
            if character == quote {
                let next = text.index(after: index)
                // In single quotes, '' is a quote within the text.
                if quote == "'", next < text.endIndex, text[next] == "'" { index = text.index(after: next); continue }
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func unescaped(_ text: String) -> String {
        var out = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// `text` as a double-quoted YAML scalar.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The first line of text that isn't a heading or code, for a skill without a description.
    static func firstLine(of body: String) -> String {
        var inCode = false
        for line in body.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
            if !inCode, !line.isEmpty, !line.hasPrefix("#") { return line }
        }
        return ""
    }

    /// How many files are in a skill's folder besides its `SKILL.md`.
    private static func resources(in folder: URL, fileManager: FileManager) -> Int {
        // A linked skill folder is counted where the link leads.
        let root = folder.resolvingSymlinksInPath().path
        return (fileManager.subpaths(atPath: root) ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return path != fileName && !path.split(separator: "/").contains { $0.hasPrefix(".") }
                && fileManager.fileExists(atPath: (root as NSString).appendingPathComponent(path), isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }.count
    }
}

extension Bot {
    /// Whether the bot keeps the shared skill `slug` on (all are, until turned off).
    public func usesSharedSkill(_ slug: String) -> Bool {
        !(disabledSkills ?? []).contains(slug)
    }

    /// Turns the shared skill `slug` on or off for this bot.
    public mutating func setSharedSkill(_ slug: String, enabled: Bool) {
        var disabled = Set(disabledSkills ?? [])
        if enabled { disabled.remove(slug) } else { disabled.insert(slug) }
        disabledSkills = disabled.isEmpty ? nil : disabled.sorted()
    }
}
