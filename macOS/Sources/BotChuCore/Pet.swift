import Foundation

/// One animation row of a Codex pet atlas: its name, its row, how many frames it uses and how long
/// each frame shows, in milliseconds.
public struct PetRow: Equatable, Sendable {
    public let name: String
    public let index: Int
    public let durations: [Int]

    public var frames: Int { durations.count }

    /// Frame times for `count` frames: the row's own when the counts match; otherwise its usual
    /// frame time, ending on its longer final frame (atlases may use a frame more or less).
    public func durations(frameCount count: Int) -> [Int] {
        PetRow.fit(durations, to: count)
    }

    static func fit(_ durations: [Int], to count: Int) -> [Int] {
        guard count > 0, let last = durations.last else { return [] }
        if count == durations.count { return durations }
        if count == 1 { return [last] }
        let body = durations.dropLast()
        let usual = body.last ?? last
        let head = Array(body.prefix(count - 1))
        return head + Array(repeating: usual, count: count - 1 - head.count) + [last]
    }
}

/// The sprite atlas Codex pets use (the `hatch-pet` skill's contract): 8 columns of 192 × 208 cells,
/// one animation per row. Version 1 has the 9 animation rows; version 2 adds two rows of look
/// directions, which BotChu does not use.
public enum PetAtlas {
    public static let columns = 8
    public static let cellWidth = 192
    public static let cellHeight = 208
    public static let width = columns * cellWidth
    /// 8 × 9 (version 1) and 8 × 11 (version 2).
    public static let heights = [9 * cellHeight, 11 * cellHeight]

    public static let rows: [PetRow] = [
        PetRow(name: "idle", index: 0, durations: [280, 110, 110, 140, 140, 320]),
        PetRow(name: "running-right", index: 1, durations: Array(repeating: 120, count: 7) + [220]),
        PetRow(name: "running-left", index: 2, durations: Array(repeating: 120, count: 7) + [220]),
        PetRow(name: "waving", index: 3, durations: [140, 140, 140, 280]),
        PetRow(name: "jumping", index: 4, durations: [140, 140, 140, 140, 280]),
        PetRow(name: "failed", index: 5, durations: Array(repeating: 140, count: 7) + [240]),
        PetRow(name: "waiting", index: 6, durations: Array(repeating: 150, count: 5) + [260]),
        PetRow(name: "running", index: 7, durations: Array(repeating: 120, count: 5) + [220]),
        PetRow(name: "review", index: 8, durations: Array(repeating: 150, count: 5) + [280]),
    ]

    public static func row(named name: String) -> PetRow? { rows.first { $0.name == name } }

    public static func isValidSize(width: Int, height: Int) -> Bool {
        width == self.width && heights.contains(height)
    }
}

/// An animation BotChu draws for a pet beyond the atlas, for one of its activities. `alias` is the
/// atlas row whose frame count and layout guide the `hatch-pet` scripts slice it with.
public struct PetActivitySpec: Equatable, Sendable {
    public let id: String
    public let alias: String
    public let durations: [Int]
    /// What the frames show, for the image prompt.
    public let prompt: String
    /// Another extra whose strip is attached as the pose to match, drawn before this one.
    public let poseReference: String?

    public init(id: String, alias: String, durations: [Int], prompt: String, poseReference: String? = nil) {
        self.id = id
        self.alias = alias
        self.durations = durations
        self.prompt = prompt
        self.poseReference = poseReference
    }

    public var frames: Int { durations.count }

    /// The extra animations, in the order they are drawn. Adding one is one entry here. Motions are
    /// kept small: these loop for as long as a tool runs, beside the chat.
    public static let all: [PetActivitySpec] = [
        PetActivitySpec(
            id: "thinking", alias: "waiting", durations: Array(repeating: 190, count: 5) + [380],
            prompt: "Thinking: chin resting on one paw or hand, eyes glancing up, one slow blink. The head and body stay still; only the eyes, eyelids and a fingertip move. No thought bubbles, symbols or punctuation."),
        PetActivitySpec(
            id: "researching", alias: "review", durations: Array(repeating: 170, count: 5) + [340],
            prompt: "Researching: holding an open book close with both hands and reading it, eyes moving along the page, turning one page slowly midway. The head and body stay still. The book is a simple solid shape held against the body, with no text."),
        PetActivitySpec(
            id: "browsing", alias: "review", durations: Array(repeating: 160, count: 5) + [320],
            prompt: "Browsing the web: holding a small tablet in front with both hands, looking at it and swiping slowly with one finger. Only the finger and the eyes move. The tablet's face is a plain light rectangle with no text or interface."),
        PetActivitySpec(
            id: "testing", alias: "running", durations: Array(repeating: 150, count: 5) + [320],
            prompt: "Testing: sitting with a small open laptop on its lap or set right in front of it, pressing one key, watching the screen with an expectant look, then a small satisfied nod in the last frames. No checkmarks, text or symbols."),
        PetActivitySpec(
            id: "coding", alias: "running", durations: Array(repeating: 130, count: 5) + [240],
            prompt: "Coding, locked in: the same seat and the same open laptop as the testing animation, now wearing over-ear headphones, typing with small alternating finger taps while its eyes stay on the screen. The head and body stay still. The laptop and headphones touch the pet and fit inside its slot; the screen faces the pet and shows no text.",
            poseReference: "testing"),
        PetActivitySpec(
            id: "working", alias: "failed", durations: Array(repeating: 120, count: 7) + [220],
            prompt: "Working: tinkering with a small wrench held at chest height, focused expression, a small steady turning motion of the wrench. The body stays planted. No sparks, motion lines or floating effects."),
    ]

    public static func spec(id: String) -> PetActivitySpec? { all.first { $0.id == id } }
}

/// What a bot is doing, which picks its pet's animation.
public enum BotActivity: String, CaseIterable, Codable, Sendable {
    case idle, greeting, thinking, researching, browsing, coding, testing, working, done, failed

    /// The animations that show this activity, best first: BotChu's own extra animation, then the
    /// closest atlas row, then `idle`.
    public var animations: [String] {
        switch self {
        case .idle: ["idle"]
        case .greeting: ["waving", "idle"]
        case .thinking: ["thinking", "waiting", "idle"]
        case .researching: ["researching", "review", "idle"]
        case .browsing: ["browsing", "researching", "review", "idle"]
        case .coding: ["coding", "running", "idle"]
        case .testing: ["testing", "running", "idle"]
        case .working: ["working", "running", "idle"]
        case .done: ["jumping", "idle"]
        case .failed: ["failed", "idle"]
        }
    }

    /// Played once, then the pet goes back to idle.
    public var isOneShot: Bool { self == .greeting || self == .done }

    /// The first of this activity's animations that the pet has.
    public func animation(among available: Set<String>) -> String? {
        animations.first { available.contains($0) }
    }

    /// The activity a turn's event moves to, or nil when it leaves the activity as it is.
    public static func next(after event: AgentEvent) -> BotActivity? {
        switch event {
        case .textDelta, .text, .toolFinished: .thinking
        case let .toolStarted(_, name, input): classify(toolName: name, input: input)
        case .session, .textEnd, .failed, .finished: nil
        }
    }

    /// What a tool call is for, from its name and input. The CLIs name their tools differently
    /// (Claude `Read`/`Edit`/`Bash`, Codex `Shell`/`Edit files`/`Web search`, Antigravity
    /// `run_command`, Muse and Pi `bash`), so this goes by words in the name, and for shell
    /// commands by the command itself.
    public static func classify(toolName: String, input: String) -> BotActivity {
        let name = toolName.lowercased()
        if shellTools.contains(name) { return classify(command: input) }
        if name == "todowrite" || name == "todoread" || name.contains("plan") { return .thinking }
        if ["task", "agent", "invoke_subagent"].contains(name) { return .working }
        if ["web", "url", "browser", "fetch"].contains(where: name.contains) { return .browsing }
        if ["edit", "write", "patch", "replace", "create"].contains(where: name.contains) { return .coding }
        if ["read", "grep", "glob", "search", "list", "view", "find"].contains(where: name.contains) || name == "ls" {
            return .researching
        }
        return .working
    }

    static let shellTools: Set<String> = ["bash", "shell", "run_command", "run_shell_command", "exec_command", "command", "terminal"]

    /// What a shell command does. A command line with several commands takes the most telling one.
    public static func classify(command: String) -> BotActivity {
        let separators = CharacterSet(charactersIn: "&|;\n")
        let parts = command.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("cd ") && $0 != "cd" }
        let found = Set(parts.map(classifyOne))
        for activity in [BotActivity.testing, .coding, .browsing, .working, .researching] where found.contains(activity) {
            return activity
        }
        return .working
    }

    static let readCommands: Set<String> = [
        "ls", "cat", "head", "tail", "find", "grep", "rg", "fd", "wc", "tree", "less", "more", "man", "file",
        "stat", "pwd", "which", "awk", "jq", "du", "nl", "sort", "uniq", "diff", "echo", "printf",
    ]

    static let testPattern = try! NSRegularExpression(pattern: [
        #"\b(tests?|pytest|jest|vitest|xcodebuild|tsc|eslint|swiftlint|lint|check\.sh|test\.sh)\b"#,
        #"\bswift (build|test)\b"#,
        #"\b(npm|pnpm|yarn|bun) (test|run (build|test|lint|check))\b"#,
        #"\bcargo (build|test|check|clippy)\b"#,
        #"\bgo (test|build|vet)\b"#,
        #"\bmake\b"#,
        #"\bgradle"#,
        #"\bmvn\b"#,
    ].joined(separator: "|"))

    private static func classifyOne(_ part: String) -> BotActivity {
        let lower = part.lowercased()
        let words = lower.split(separator: " ").map(String.init)
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { return .working }
        let second = words.count > 1 ? words[1] : ""
        switch first {
        case "curl", "wget": return .browsing
        case "sed": return words.contains(where: { $0.hasPrefix("-i") }) ? .coding : .researching
        case "git":
            if ["log", "status", "diff", "show", "blame", "grep", "ls-files", "branch", "remote"].contains(second) { return .researching }
            if ["add", "commit", "apply", "mv", "rm", "restore"].contains(second) { return .coding }
        case "apply_patch", "patch", "tee", "touch", "mkdir", "cp", "mv": return .coding
        default:
            if readCommands.contains(first) {
                return lower.contains(" > ") || lower.contains(" >> ") || lower.contains("<<") ? .coding : .researching
            }
        }
        let range = NSRange(lower.startIndex..., in: lower)
        if testPattern.firstMatch(in: lower, range: range) != nil { return .testing }
        return .working
    }
}

/// `pet.json`, the manifest of a Codex pet package.
public struct CodexPetManifest: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var description: String?
    public var spritesheetPath: String
    public var spriteVersionNumber: Int?

    public init(id: String, displayName: String, description: String? = nil, spritesheetPath: String = "spritesheet.webp",
                spriteVersionNumber: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
        self.spriteVersionNumber = spriteVersionNumber
    }
}

/// `activities.json`: the extra animations BotChu drew for a pet, each a folder of frames
/// `activities/<id>/00.png, 01.png, …`.
public struct PetActivitiesManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var frames: Int
        public var durations: [Int]

        public init(id: String, frames: Int, durations: [Int]) {
            self.id = id
            self.frames = frames
            self.durations = durations
        }
    }

    public var version: Int
    public var activities: [Entry]

    public init(version: Int = 1, activities: [Entry]) {
        self.version = version
        self.activities = activities
    }
}

/// A bot's pet as files on disk: a Codex pet package in `.botchu/pet/`, plus BotChu's extra
/// animations. Images are decoded by the app.
public struct PetPackage: Equatable, Sendable {
    public struct Extra: Equatable, Sendable {
        public var id: String
        public var frameURLs: [URL]
        public var durations: [Int]
    }

    public var folder: URL
    public var manifest: CodexPetManifest
    public var sheetURL: URL
    public var extras: [Extra]

    public static let manifestFile = "pet.json"
    public static let activitiesFile = "activities.json"
    public static let activitiesFolder = "activities"

    /// The pet in `folder`, or nil when there is none (no manifest, or its spritesheet is missing).
    public static func load(from folder: URL) -> PetPackage? {
        let files = FileManager.default
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestFile)),
              let manifest = try? Store.decoder.decode(CodexPetManifest.self, from: data),
              let sheet = safeChild(manifest.spritesheetPath, of: folder),
              files.fileExists(atPath: sheet.path) else { return nil }
        var extras: [Extra] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent(activitiesFile)),
           let activities = try? Store.decoder.decode(PetActivitiesManifest.self, from: data) {
            for entry in activities.activities {
                guard let dir = safeChild("\(activitiesFolder)/\(entry.id)", of: folder) else { continue }
                let frames = (0..<max(entry.frames, 0)).map { dir.appendingPathComponent(String(format: "%02d.png", $0)) }
                guard frames.count >= 2, frames.allSatisfy({ files.fileExists(atPath: $0.path) }) else { continue }
                extras.append(Extra(id: entry.id, frameURLs: frames, durations: PetRow.fit(entry.durations, to: frames.count)))
            }
        }
        return PetPackage(folder: folder, manifest: manifest, sheetURL: sheet, extras: extras)
    }

    /// Copies a Codex pet (a folder with `pet.json` and its spritesheet, as in `~/.codex/pets/<name>`)
    /// to `folder`. A pet already there goes to the Trash.
    public static func importCodexPet(from source: URL, into folder: URL) throws {
        let files = FileManager.default
        let manifestURL = source.appendingPathComponent(manifestFile)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PetError("\(source.lastPathComponent) has no pet.json.")
        }
        let manifest: CodexPetManifest
        do {
            manifest = try Store.decoder.decode(CodexPetManifest.self, from: data)
        } catch {
            throw PetError("\(source.lastPathComponent)/pet.json isn't a Codex pet manifest.")
        }
        guard let sheet = safeChild(manifest.spritesheetPath, of: source), files.fileExists(atPath: sheet.path) else {
            throw PetError("\(source.lastPathComponent) has no \(manifest.spritesheetPath).")
        }
        if files.fileExists(atPath: folder.path) {
            try files.trashItem(at: folder, resultingItemURL: nil)
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.copyItem(at: manifestURL, to: folder.appendingPathComponent(manifestFile))
        try files.copyItem(at: sheet, to: folder.appendingPathComponent(manifest.spritesheetPath))
    }

    /// `path` inside `folder`, or nil when it would leave it.
    static func safeChild(_ path: String, of folder: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return folder.appendingPathComponent(path)
    }
}

public struct PetError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
