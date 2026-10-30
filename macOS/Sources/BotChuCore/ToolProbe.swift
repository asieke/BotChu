import Foundation

/// What BotChu last learned about an approved tool on This Mac (#246), kept between launches in
/// `tool-checks.json`. Only catalog tools are checked, by running their own version command and,
/// for `gh`, `gh auth status --json hosts`, with a time limit; an executable the owner chose is
/// never run. Only the parsed values are kept, never what a tool printed.
public struct ToolReading: Codable, Equatable, Sendable {
    public var readAt: Date
    /// The path that was run.
    public var path: String
    /// Nil when the tool didn't print a version BotChu recognises.
    public var version: String?
    /// The GitHub CLI's sign-in, for `gh`; nil for other tools, and when it wasn't reported.
    public var github: GitHubSignIn?

    public init(readAt: Date, path: String, version: String?, github: GitHubSignIn? = nil) {
        self.readAt = readAt
        self.path = path
        self.version = version
        self.github = github
    }
}

/// The active github.com account as `gh auth status --json hosts` reports it.
public struct GitHubSignIn: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case signedIn
        /// gh has an account whose check failed (expired, revoked, or not reachable).
        case failed
        case signedOut
    }

    public var state: State
    public var login: String?
    /// The token's OAuth scopes. Nil when gh didn't report them (a fine-grained or app token);
    /// empty when it reported none. Scopes never grant more than the account itself can do.
    public var scopes: [String]?

    public init(state: State, login: String? = nil, scopes: [String]? = nil) {
        self.state = state
        self.login = login
        self.scopes = scopes
    }
}

/// An approved tool's check: the last reading that worked, and why the latest one failed, if it
/// did. A failed check keeps the reading before it, shown as stale.
public struct ToolCheck: Codable, Equatable, Sendable {
    public var reading: ToolReading?
    public var failure: String?
    public var attemptedAt: Date

    public init(reading: ToolReading?, failure: String?, attemptedAt: Date) {
        self.reading = reading
        self.failure = failure
        self.attemptedAt = attemptedAt
    }

    public var isStale: Bool { failure != nil && reading != nil }

    /// This check after `result`: a new reading replaces the old one; a failure keeps it.
    public func updated(with result: Result<ToolReading, ToolProbe.Failure>, at date: Date) -> ToolCheck {
        switch result {
        case .success(let reading): ToolCheck(reading: reading, failure: nil, attemptedAt: date)
        case .failure(let failure): ToolCheck(reading: reading, failure: failure.message, attemptedAt: date)
        }
    }

    public static let fileName = "tool-checks.json"

    public static func load(from folder: URL) -> [String: ToolCheck] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return [:] }
        return (try? ToolPolicy.decoder.decode([String: ToolCheck].self, from: data)) ?? [:]
    }

    public static func save(_ checks: [String: ToolCheck], in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ToolPolicy.encoder.encode(checks).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }
}

public struct ToolProbe: Sendable {
    public struct Failure: Error, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Runs an executable with arguments and extra environment, within a time limit.
    public typealias Run = @Sendable (_ path: String, _ arguments: [String], _ environment: [String: String]) async -> Shell.Result
    private let run: Run

    public init(run: @escaping Run = { await ToolProbe.execute($0, $1, environment: $2) }) {
        self.run = run
    }

    /// Checks a catalog tool installed at `location`.
    public func check(_ tool: CatalogTool, at location: ToolLocation, now: @Sendable () -> Date = Date.init) async -> Result<ToolReading, Failure> {
        let version = await run(location.path, tool.versionArguments, tool.probeEnvironment)
        if version.timedOut { return .failure(Failure("\(tool.id) didn't answer within \(Int(Self.timeout)) seconds.")) }
        guard version.status == 0 else { return .failure(Failure("\(tool.id) couldn't report its version (exit \(version.status)).")) }
        var reading = ToolReading(readAt: now(), path: location.path, version: Self.version(in: version.output))
        if tool.id == "gh" {
            let status = await run(location.path, ["auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"], tool.probeEnvironment)
            reading.github = status.timedOut ? nil : Self.githubSignIn(status.output)
        }
        return .success(reading)
    }

    /// The first version number in a tool's version output, such as `2.102.0` or `7.1.2-25`.
    public static func version(in output: String) -> String? {
        let head = output.split(whereSeparator: \.isNewline).prefix(3).joined(separator: "\n")
        guard let range = head.range(of: #"\d+\.\d+(\.\d+){0,2}([-+][0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?"#, options: .regularExpression) else { return nil }
        return String(head[range].prefix(40))
    }

    /// The github.com account's sign-in from `gh auth status --json hosts`, which exits 0 even when
    /// it failed; nil when the output isn't that (an older gh without `--json`).
    public static func githubSignIn(_ output: String) -> GitHubSignIn? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = object["hosts"] as? [String: Any] else { return nil }
        let accounts = (hosts["github.com"] as? [[String: Any]]) ?? []
        guard let account = accounts.first(where: { $0["active"] as? Bool == true }) ?? accounts.first else {
            return GitHubSignIn(state: .signedOut)
        }
        let login = (account["login"] as? String).flatMap { login in
            login.count <= 39 && !login.isEmpty && login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) ? login : nil
        }
        let scopes = (account["scopes"] as? String).map { text in
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ":_-".contains($0)) } }
        }
        return GitHubSignIn(state: account["state"] as? String == "success" ? .signedIn : .failed, login: login, scopes: scopes)
    }

    public static let timeout: TimeInterval = 5
    /// How much of a tool's output is read; the rest is dropped.
    static let outputLimit = 64 * 1024

    /// Runs `path` directly (no shell), with stdin closed, a small environment and the time limit,
    /// returning its output and error output together, cut to `outputLimit`.
    public static func execute(_ path: String, _ arguments: [String], environment: [String: String],
                               timeout: TimeInterval = ToolProbe.timeout) async -> Shell.Result {
        let inherited = ProcessInfo.processInfo.environment
        var env = ["HOME": NSHomeDirectory(), "NO_COLOR": "1", "TERM": "dumb", "LANG": "en_US.UTF-8",
                   "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        env.merge(environment) { _, new in new }
        return await ChildProcess.run(path, arguments, environment: env, timeout: timeout, outputLimit: outputLimit, mergeErrors: true)
    }
}
