import Foundation

/// A command-line tool BotChu knows (#246): a service or infrastructure CLI that acts with the
/// owner's credentials. While the tool policy is enforced, a catalog tool that isn't approved and
/// on can't run in BotChu's local turns (`ToolSandbox`). Shells, interpreters, git, the agent CLIs
/// and SSH (`ssh`, `scp`, `sftp`, `rsync`, and Tailscale, which carries it) are never in it: agents
/// can't work without them, and deploy scripts use them.
public struct CatalogTool: Identifiable, Hashable, Sendable {
    /// The tool's key, which is also its usual command: `gh`.
    public let id: String
    public let title: String
    /// Every command name it installs (`gcloud`, `gsutil`, `bq`).
    public let executables: [String]
    /// What prints its version without touching the network or its login.
    public let versionArguments: [String]
    /// Variables its version check runs with, to keep it from updating or phoning home.
    public let probeEnvironment: [String: String]

    public init(id: String, title: String, executables: [String]? = nil, versionArguments: [String] = ["--version"],
                probeEnvironment: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.executables = executables ?? [id]
        self.versionArguments = versionArguments
        self.probeEnvironment = probeEnvironment
    }
}

public enum ToolCatalog {
    public static let tools: [CatalogTool] = [
        CatalogTool(id: "gh", title: "GitHub CLI", probeEnvironment: ["GH_NO_UPDATE_NOTIFIER": "1", "GH_PROMPT_DISABLED": "1"]),
        CatalogTool(id: "glab", title: "GitLab CLI"),
        CatalogTool(id: "aws", title: "AWS CLI"),
        CatalogTool(id: "gcloud", title: "Google Cloud CLI", executables: ["gcloud", "gsutil", "bq"]),
        CatalogTool(id: "az", title: "Azure CLI"),
        CatalogTool(id: "vercel", title: "Vercel CLI", probeEnvironment: ["VERCEL_TELEMETRY_DISABLED": "1"]),
        CatalogTool(id: "netlify", title: "Netlify CLI", executables: ["netlify", "ntl"]),
        CatalogTool(id: "fly", title: "Fly.io CLI", executables: ["flyctl", "fly"], versionArguments: ["version"]),
        CatalogTool(id: "heroku", title: "Heroku CLI", probeEnvironment: ["HEROKU_SKIP_AUTOUPDATE": "1"]),
        CatalogTool(id: "wrangler", title: "Cloudflare Wrangler"),
        CatalogTool(id: "supabase", title: "Supabase CLI"),
        CatalogTool(id: "firebase", title: "Firebase CLI"),
        CatalogTool(id: "railway", title: "Railway CLI"),
        CatalogTool(id: "doctl", title: "DigitalOcean CLI", versionArguments: ["version"]),
        CatalogTool(id: "stripe", title: "Stripe CLI"),
        CatalogTool(id: "op", title: "1Password CLI"),
        CatalogTool(id: "docker", title: "Docker"),
        CatalogTool(id: "kubectl", title: "Kubernetes CLI", versionArguments: ["version", "--client"]),
        CatalogTool(id: "helm", title: "Helm", versionArguments: ["version", "--short"]),
        CatalogTool(id: "terraform", title: "Terraform", versionArguments: ["-version"], probeEnvironment: ["CHECKPOINT_DISABLE": "1"]),
        CatalogTool(id: "ngrok", title: "ngrok"),
        CatalogTool(id: "aside", title: "Aside browser"),
    ]

    public static func tool(_ id: String) -> CatalogTool? { tools.first { $0.id == id } }

    /// The catalog tool that installs the command `name`, by any of its names.
    public static func tool(command name: String) -> CatalogTool? {
        let name = name.lowercased()
        return tools.first { $0.id == name || $0.executables.contains(name) }
    }
}

/// The owner's tool policy, global for every bot on This Mac, in `tools.json` beside `index.json`.
/// Installs from before it have no file: `enforcedSince` is nil, nothing is approved, and nothing
/// is blocked until the owner turns enforcement on.
public struct ToolPolicy: Codable, Equatable, Sendable {
    /// When the owner turned enforcement on; nil while it is off (and before it was ever set up).
    public var enforcedSince: Date?
    public var tools: [ApprovedTool]
    /// Candidates the owner chose to ignore, by `ToolCandidate.id`, until restored.
    public var ignored: [String]
    /// SSH destinations, kept as the owner entered them: guidance only, as SSH is never restricted.
    public var destinations: [SSHDestination]

    public init(enforcedSince: Date? = nil, tools: [ApprovedTool] = [], ignored: [String] = [], destinations: [SSHDestination] = []) {
        self.enforcedSince = enforcedSince
        self.tools = tools
        self.ignored = ignored
        self.destinations = destinations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enforcedSince = try container.decodeIfPresent(Date.self, forKey: .enforcedSince)
        tools = try container.decodeIfPresent([ApprovedTool].self, forKey: .tools) ?? []
        ignored = try container.decodeIfPresent([String].self, forKey: .ignored) ?? []
        destinations = try container.decodeIfPresent([SSHDestination].self, forKey: .destinations) ?? []
    }

    public var isEnforced: Bool { enforcedSince != nil }

    public func approved(_ id: String) -> ApprovedTool? { tools.first { $0.id == id } }

    /// The approved tool a skill's declared name means: a catalog tool by any of its commands, or
    /// an approved executable by its name.
    public func approved(declared name: String) -> ApprovedTool? {
        if let catalog = ToolCatalog.tool(command: name) { return approved(ApprovedTool.catalogID(catalog.id)) }
        return tools.first { $0.catalogID == nil && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Approves a candidate, switched on. Approving never happens without the owner choosing it.
    public mutating func approve(_ candidate: ToolCandidate, at date: Date = Date()) {
        guard approved(candidate.id) == nil, let tool = ApprovedTool(candidate, at: date) else { return }
        tools.append(tool)
        ignored.removeAll { $0 == candidate.id }
    }

    public mutating func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = tools.firstIndex(where: { $0.id == id }) else { return }
        tools[index].enabled = enabled
    }

    /// Removes an approval. A catalog tool removed goes back to the candidates, so while the
    /// policy is enforced it is blocked again.
    public mutating func remove(_ id: String) {
        tools.removeAll { $0.id == id }
    }

    public mutating func ignore(_ id: String) {
        if !ignored.contains(id) { ignored.append(id) }
    }

    public mutating func restore(_ id: String) {
        ignored.removeAll { $0 == id }
    }

    /// Why an alias can't be added: not a usable name, or already listed.
    public func problem(addingDestination alias: String) -> String? {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard SSHDestination.isValidAlias(alias) else { return "Use letters, digits, “-”, “_” or “.”." }
        guard !destinations.contains(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) else { return "\(alias) is already listed." }
        return nil
    }

    /// Adds a destination by its alias alone, the rest left for the owner to fill in.
    @discardableResult
    public mutating func addDestination(_ alias: String) -> SSHDestination? {
        guard problem(addingDestination: alias) == nil else { return nil }
        let destination = SSHDestination(alias: alias.trimmingCharacters(in: .whitespaces))
        destinations.append(destination)
        return destination
    }

    public mutating func update(_ destination: SSHDestination) {
        guard let index = destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        destinations[index] = destination
    }

    public mutating func removeDestination(_ id: UUID) {
        destinations.removeAll { $0.id == id }
    }

    /// What local turns are told about the SSH destinations switched on; nil when there are none.
    /// Only guidance: SSH itself is never restricted, whatever is listed.
    public func sshGuidance() -> String? {
        let included = destinations.filter(\.included)
        guard !included.isEmpty else { return nil }
        return """
            SSH destinations your owner described for you:
            <ssh_destinations>
            \(included.map(\.guidance).joined(separator: "\n"))
            </ssh_destinations>
            """
    }

    // MARK: Storage

    public static let fileName = "tools.json"

    /// The policy in `folder`, or the unconfigured one when there is no file. A damaged file
    /// throws, so it is never replaced by an empty policy without the owner seeing it.
    public static func load(from folder: URL, fileManager: FileManager = .default) throws -> ToolPolicy {
        let url = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return ToolPolicy() }
        return try decoder.decode(ToolPolicy.self, from: Data(contentsOf: url))
    }

    public func save(in folder: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// A tool the owner approved: a catalog tool, or an executable they chose by its path.
public struct ApprovedTool: Codable, Identifiable, Hashable, Sendable {
    /// `catalog:<id>` or `path:<absolute path>`.
    public let id: String
    /// The command agents call it by.
    public let name: String
    public var enabled: Bool
    public let approvedAt: Date

    public init(id: String, name: String, enabled: Bool = true, approvedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.approvedAt = approvedAt
    }

    init?(_ candidate: ToolCandidate, at date: Date) {
        guard candidate.catalog != nil || candidate.path != nil else { return nil }
        self.init(id: candidate.id, name: candidate.name, approvedAt: date)
    }

    public static func catalogID(_ id: String) -> String { "catalog:" + id }
    public static func pathID(_ path: String) -> String { "path:" + path }

    public var catalogID: String? { id.hasPrefix("catalog:") ? String(id.dropFirst("catalog:".count)) : nil }
    public var catalog: CatalogTool? { catalogID.flatMap { ToolCatalog.tool($0) } }
    /// The executable an owner chose, for one outside the catalog.
    public var path: String? { id.hasPrefix("path:") ? String(id.dropFirst("path:".count)) : nil }
}

/// An SSH destination as the owner describes it (#246): guidance for agents, not a permission.
/// BotChu never restricts SSH, so ssh, scp, sftp, rsync, forwarding and deploy scripts work the
/// same whether a destination is listed, switched off or absent. One switched on is described in
/// local turns' instructions; one switched off isn't. Every field is the owner's, empty until
/// they fill it; an identity is a key file's path, which BotChu never reads.
public struct SSHDestination: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var alias: String
    public var user: String
    public var host: String
    public var identityFile: String
    /// What it is for, in the owner's words.
    public var note: String
    /// Whether local turns' instructions describe it.
    public var included: Bool

    public init(id: UUID = UUID(), alias: String, user: String = "", host: String = "", identityFile: String = "", note: String = "",
                included: Bool = true) {
        self.id = id
        self.alias = alias
        self.user = user
        self.host = host
        self.identityFile = identityFile
        self.note = note
        self.included = included
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        alias = try container.decode(String.self, forKey: .alias)
        user = try container.decodeIfPresent(String.self, forKey: .user) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        included = try container.decodeIfPresent(Bool.self, forKey: .included) ?? true
    }

    /// Whether the alias is a name agents could use: letters, digits, `-`, `_` and `.`.
    public static func isValidAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.count <= 64 && alias.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// `user@host`, or the host alone; nil until a host is filled in.
    public var target: String? {
        let user = Self.field(user), host = Self.field(host)
        guard !host.isEmpty else { return nil }
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    /// Its line in agents' instructions: only what the owner entered, on one line.
    var guidance: String {
        var parts = ["`\(alias)`"]
        if let target { parts.append("→ `\(target)`") }
        let identity = Self.field(identityFile)
        if !identity.isEmpty { parts.append("(identity file `\(identity)`)") }
        let note = Self.field(note)
        return "- " + parts.joined(separator: " ") + (note.isEmpty ? "" : " — \(note)")
    }

    /// A field on one line, without backticks, within 200 characters.
    static func field(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").replacingOccurrences(of: "`", with: "'")
            .trimmingCharacters(in: .whitespaces).prefix(200))
    }
}

/// Where a command is installed: the path found, and the file it leads to.
public struct ToolLocation: Codable, Hashable, Sendable {
    public let path: String
    public let realPath: String

    public init(path: String, realPath: String) {
        self.path = path
        self.realPath = realPath
    }
}

/// A tool the owner can approve in Add Tools: a catalog tool found on This Mac, or a command a
/// skill declares. Being found or declared never approves it.
public struct ToolCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let title: String
    /// Where it is on This Mac.
    public let path: String?
    public let catalog: CatalogTool?
    /// The skills that declare it, by name.
    public let skills: [String]

    public init(id: String, name: String, title: String, path: String?, catalog: CatalogTool?, skills: [String]) {
        self.id = id
        self.name = name
        self.title = title
        self.path = path
        self.catalog = catalog
        self.skills = skills
    }
}

/// What a skill declares it needs (`cli-tools:` in its frontmatter), and how each stands.
public enum ToolDependency: Equatable, Sendable {
    /// Approved and on.
    case enabled
    /// Approved but switched off.
    case off
    /// On This Mac or in the catalog, but not approved.
    case notApproved
    /// Not approved and not found on This Mac.
    case missing
}

/// The tools in their policy: the rows of Tools, the candidates of Add Tools, the dependencies of
/// skills, the paths a turn blocks and the catalog agents are told about. Made from the policy,
/// where the commands are on This Mac and the skills' declarations; reads no files itself.
public struct ToolInventory: Sendable {
    public let policy: ToolPolicy
    /// Where each catalog tool's commands are, by catalog id.
    public let catalogLocations: [String: [ToolLocation]]
    /// Where each declared command outside the catalog is, by lowercased name.
    public let declaredLocations: [String: ToolLocation]
    /// Each skill's name and the commands it declares.
    public let declarations: [(skill: String, tools: [String])]

    public init(policy: ToolPolicy, catalogLocations: [String: [ToolLocation]], declaredLocations: [String: ToolLocation] = [:],
                declarations: [(skill: String, tools: [String])] = []) {
        self.policy = policy
        self.catalogLocations = catalogLocations
        self.declaredLocations = declaredLocations
        self.declarations = declarations
    }

    /// The candidates not approved, and those the owner ignored. Catalog tools count once found on
    /// This Mac; declared ones once found there too (a declared command not found is `missing`).
    public func candidates() -> (open: [ToolCandidate], ignored: [ToolCandidate]) {
        var all: [ToolCandidate] = []
        for tool in ToolCatalog.tools {
            guard let location = catalogLocations[tool.id]?.first else { continue }
            let id = ApprovedTool.catalogID(tool.id)
            guard policy.approved(id) == nil else { continue }
            all.append(ToolCandidate(id: id, name: tool.id, title: tool.title, path: location.path, catalog: tool, skills: skills(declaring: tool)))
        }
        var seen = Set<String>()
        for (_, names) in declarations {
            for name in names where ToolCatalog.tool(command: name) == nil {
                let key = name.lowercased()
                guard !seen.contains(key), let location = declaredLocations[key], policy.approved(declared: name) == nil else { continue }
                let id = ApprovedTool.pathID(location.path)
                guard policy.approved(id) == nil else { continue }
                seen.insert(key)
                all.append(ToolCandidate(id: id, name: name, title: "", path: location.path, catalog: nil,
                                         skills: declarations.filter { $0.tools.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }.map(\.skill)))
            }
        }
        all.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let ignored = Set(policy.ignored)
        return (all.filter { !ignored.contains($0.id) }, all.filter { ignored.contains($0.id) })
    }

    /// How a skill's declared command stands.
    public func dependency(_ name: String) -> ToolDependency {
        if let approved = policy.approved(declared: name) { return approved.enabled ? .enabled : .off }
        if let catalog = ToolCatalog.tool(command: name) { return catalogLocations[catalog.id]?.isEmpty == false ? .notApproved : .missing }
        return declaredLocations[name.lowercased()] == nil ? .missing : .notApproved
    }

    /// The skills that declare an approved tool or a catalog tool.
    public func skills(declaring tool: ApprovedTool) -> [String] {
        if let catalog = tool.catalog { return skills(declaring: catalog) }
        return declarations.filter { $0.tools.contains { $0.caseInsensitiveCompare(tool.name) == .orderedSame } }.map(\.skill)
    }

    public func skills(declaring tool: CatalogTool) -> [String] {
        declarations.filter { $0.tools.contains { ToolCatalog.tool(command: $0)?.id == tool.id } }.map(\.skill)
    }

    /// Where an approved tool is on This Mac: its catalog commands, or its chosen path.
    public func locations(of tool: ApprovedTool) -> [ToolLocation] {
        if let id = tool.catalogID { return catalogLocations[id] ?? [] }
        guard let path = tool.path else { return [] }
        return [ToolLocation(path: path, realPath: ToolLocator.realPath(path) ?? path)]
    }

    /// Whether a turn started now blocks the tool: the policy is enforced and the tool is off.
    public func blocks(_ tool: ApprovedTool) -> Bool { policy.isEnforced && !tool.enabled }

    /// The installed files a turn started now may not run or read: while the policy is enforced,
    /// every catalog tool not approved and on, and every chosen executable switched off. Empty
    /// while it isn't enforced.
    public func blockedLocations() -> [ToolLocation] {
        guard policy.isEnforced else { return [] }
        var blocked: [ToolLocation] = []
        for tool in ToolCatalog.tools where policy.approved(ApprovedTool.catalogID(tool.id))?.enabled != true {
            blocked += catalogLocations[tool.id] ?? []
        }
        for tool in policy.tools where tool.catalogID == nil && !tool.enabled {
            blocked += locations(of: tool)
        }
        return blocked
    }

    /// What agents are told at the start of a session: the tools approved and on and, while the
    /// policy is enforced, that the catalog's others are blocked. Not enforced, it is only that
    /// list, nil when nothing is approved and on, and claims no blocking.
    public func agentCatalog() -> String? {
        let on = policy.tools.filter(\.enabled).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let lines = on.map { tool -> String in
            if let catalog = tool.catalog { return "- `\(tool.name)` — \(catalog.title)" }
            return "- `\(tool.name)` (`\(tool.path ?? tool.name)`)"
        }
        guard policy.isEnforced else {
            guard !lines.isEmpty else { return nil }
            return """
                Command-line tools your owner approved for you on This Mac:
                <tools>
                \(lines.joined(separator: "\n"))
                </tools>
                """
        }
        let others = ToolCatalog.tools.filter { policy.approved(ApprovedTool.catalogID($0.id))?.enabled != true }.map(\.id)
        return """
            Command-line tools your owner approved for you on This Mac:
            <tools>
            \(lines.isEmpty ? "None." : lines.joined(separator: "\n"))
            </tools>
            Other service CLIs BotChu knows (\(others.map { "`\($0)`" }.joined(separator: ", "))) are blocked in turns on This Mac \
            and fail with "operation not permitted". Don't work around a blocked tool; say what you needed it for. SSH, scp, sftp and \
            rsync are never restricted.
            """
    }

    /// Everything local turns are told about tools: the approved catalog, and the SSH destinations
    /// switched on. Nil when there is neither.
    public func agentInstructions() -> String? {
        let sections = [agentCatalog(), policy.sshGuidance()].compactMap { $0 }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// Why an executable the owner picked can't be added to Tools; nil when it can. A catalog
    /// tool's command is approved as that tool, and SSH, git and shells are never restricted, so
    /// listing one would mean nothing.
    public static func problem(choosing path: String, fileManager: FileManager = .default) -> String? {
        let name = (path as NSString).lastPathComponent
        let real = ToolLocator.realPath(path) ?? path
        guard path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else { return "\(name) isn't an executable file." }
        if let tool = ToolCatalog.tool(command: name) { return "\(name) is \(tool.title): approve it from the list." }
        if [name, (real as NSString).lastPathComponent].contains(where: { ToolSandbox.neverBlocked.contains($0.lowercased()) }) {
            return "BotChu never restricts \(name)."
        }
        return nil
    }

    /// The candidate for an executable the owner picked; nil when it can't be one.
    public func candidate(choosing path: String, fileManager: FileManager = .default) -> ToolCandidate? {
        guard Self.problem(choosing: path, fileManager: fileManager) == nil else { return nil }
        let name = (path as NSString).lastPathComponent
        return ToolCandidate(id: ApprovedTool.pathID(path), name: name, title: "", path: path, catalog: nil,
                             skills: declarations.filter { $0.tools.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }.map(\.skill))
    }
}

/// Finds commands on This Mac without running them: in the login shell's PATH and the usual
/// install folders.
public struct ToolLocator: Sendable {
    public let directories: [String]

    public init(directories: [String]) {
        self.directories = directories
    }

    /// The folders to look in: the login shell's PATH (`loginPath`), then the usual install
    /// folders, each once.
    public init(loginPath: String?, home: String = NSHomeDirectory()) {
        let usual = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin",
                     "/usr/sbin", "/sbin", "/opt/local/bin"]
            + [".local/bin", "bin", ".npm-global/bin", ".bun/bin", ".cargo/bin", ".deno/bin", "go/bin", ".volta/bin",
               "Library/pnpm", ".local/share/mise/shims", ".asdf/shims"].map { (home as NSString).appendingPathComponent($0) }
        var seen = Set<String>()
        let path = (loginPath ?? "").split(separator: ":").map(String.init)
        directories = (path + usual).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// Every place `name` is installed, in search order. A name with a slash is never looked up.
    public func locations(of name: String, fileManager: FileManager = .default) -> [ToolLocation] {
        guard !name.isEmpty, !name.contains("/") else { return [] }
        return directories.compactMap { directory in
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: path) else { return nil }
            return ToolLocation(path: path, realPath: Self.realPath(path) ?? path)
        }
    }

    /// Every catalog tool's locations, by catalog id; tools not found are left out.
    public func catalogLocations(fileManager: FileManager = .default) -> [String: [ToolLocation]] {
        var found: [String: [ToolLocation]] = [:]
        for tool in ToolCatalog.tools {
            let locations = tool.executables.flatMap { locations(of: $0, fileManager: fileManager) }
            if !locations.isEmpty { found[tool.id] = locations }
        }
        return found
    }

    /// The first place each name is installed, by lowercased name.
    public func firstLocations(of names: [String], fileManager: FileManager = .default) -> [String: ToolLocation] {
        var found: [String: ToolLocation] = [:]
        for name in names where found[name.lowercased()] == nil {
            if let location = locations(of: name, fileManager: fileManager).first { found[name.lowercased()] = location }
        }
        return found
    }

    /// PATH as the login shell sets it, which turns run with; nil when the shell couldn't say.
    public static func loginPath() async -> String? {
        let output = await ToolProbe.execute("/bin/zsh", ["-l", "-c", "print -r -- \"$PATH\""], environment: [:])
        guard output.status == 0, !output.timedOut else { return nil }
        let path = output.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return path.contains("/") ? path : nil
    }

    /// The file `path` leads to, with every link resolved (`/tmp` too, unlike Foundation's).
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension Skill {
    /// The commands the skill declares it needs, from `cli-tools:` in its frontmatter: a list
    /// (`[gh, jq]`, or `- gh` lines) or names separated by commas or spaces. Only these link a
    /// skill to tools; its text is never searched for them.
    public var declaredTools: [String] {
        Skills.declaredTools(in: text)
    }
}

extension Skills {
    /// The frontmatter key that declares a skill's command-line tools.
    public static let toolsKey = "cli-tools"

    public static func declaredTools(in text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let (start, stop) = toolsLines(in: lines) else { return [] }
        let value = lines[start...].prefix(stop - start).enumerated().map { index, line in
            index == 0 ? String(line[line.index(after: line.firstIndex(of: ":")!)...]) : line
        }.joined(separator: " ")
        var seen = Set<String>()
        return value.split(whereSeparator: { $0 == "," || $0 == "[" || $0 == "]" || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .prefix(while: { !$0.hasPrefix("#") })
            .filter { $0 != "-" && isToolName($0) && seen.insert($0.lowercased()).inserted }
    }

    /// The frontmatter's lines that hold `cli-tools:`: its key's line, and the indented or `- `
    /// list lines after it. Nil without frontmatter or the key.
    static func toolsLines(in lines: [String]) -> (start: Int, stop: Int)? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) }),
              let start = (1..<end).first(where: { index in
                  let line = lines[index]
                  guard let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") else { return false }
                  return line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == toolsKey
              })
        else { return nil }
        var stop = start + 1
        while stop < end, lines[stop].first.map({ $0.isWhitespace || $0 == "-" }) ?? false { stop += 1 }
        return (start, stop)
    }

    /// A command's name, as a declaration can give it: no paths, spaces or shell characters.
    public static func isToolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.+".contains($0)) }
    }

    /// `text` with its `cli-tools:` set to `tools`: replaced where it is, added at the end of the
    /// frontmatter, or removed when `tools` is empty. A file without frontmatter gets one.
    public static func settingDeclaredTools(_ tools: [String], in text: String) -> String {
        let value = tools.isEmpty ? nil : "\(toolsKey): [\(tools.joined(separator: ", "))]"
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].trimmingCharacters(in: .whitespaces)) })
        else {
            guard let value else { return text }
            return ["---", value, "---", ""].joined(separator: newline) + text
        }
        if let (start, stop) = toolsLines(in: lines) {
            if let value { lines.replaceSubrange(start..<stop, with: [value]) } else { lines.removeSubrange(start..<stop) }
        } else if let value {
            lines.insert(value, at: end)
        }
        return lines.joined(separator: newline)
    }
}
