import Foundation

/// A command run through the login shell (`zsh -l`, so PATH has git, gh and Homebrew as in
/// Terminal), in a folder, with what it printed. For the short git and gh commands tasks need.
public enum Shell {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var errors: String

        public var ok: Bool { status == 0 }

        /// The last line of its output, after anything the login shell printed first.
        public var lastLine: String? {
            output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        /// The command and what it printed, for an error message.
        public func report(_ command: String) -> String {
            let printed = [output, errors].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return "$ \(command)\n" + (printed.isEmpty ? "(exit \(status), nothing printed)" : printed.joined(separator: "\n"))
        }
    }

    public static func run(_ arguments: [String], in directory: String) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "exec \"$@\"", "botchu"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            var env = AgentRun.childEnvironment(ProcessInfo.processInfo.environment)
            // Never wait for a login or a password: without one, the command just fails.
            env["GH_PROMPT_DISABLED"] = "1"
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["NO_COLOR"] = "1"
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(status: -1, output: "", errors: error.localizedDescription))
                return
            }
            // Both pipes are read to the end at once, so a command that prints a lot never blocks.
            let printed = Printed()
            group.enter()
            DispatchQueue.global().async {
                printed.output = out.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                printed.errors = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.notify(queue: .global()) {
                continuation.resume(returning: Result(status: process.terminationStatus,
                                                      output: String(decoding: printed.output, as: UTF8.self),
                                                      errors: String(decoding: printed.errors, as: UTF8.self)))
            }
        }
    }

    /// What a command printed; each half is written by one reader, then read once both are done.
    private final class Printed: @unchecked Sendable {
        var output = Data()
        var errors = Data()
    }
}

/// A repository's main checkout on this Mac, which tasks make their worktrees from. It stays on its
/// default branch.
public struct RepoCheckout: Identifiable, Hashable, Sendable {
    public var path: String
    /// `owner/name` of its `origin` on GitHub; nil when its origin isn't on GitHub.
    public var nameWithOwner: String?

    public init(path: String, nameWithOwner: String?) {
        self.path = path
        self.nameWithOwner = nameWithOwner
    }

    public var id: String { path }
    /// How tasks name it: `owner/name`, else the folder's name.
    public var repo: String { nameWithOwner ?? (path as NSString).lastPathComponent }
    public var name: String { TaskNaming.repoName(repo) }
    /// Whether it follows the workspace standard, which makes task worktrees with this script.
    public var hasWorktreeScript: Bool {
        FileManager.default.isExecutableFile(atPath: (path as NSString).appendingPathComponent("scripts/worktree.sh"))
    }
}

/// The checkouts tasks can run in: the git repositories directly inside the repositories folder.
public enum Repositories {
    /// Each folder in `root` with a `.git` folder of its own (a main checkout, not a linked
    /// worktree), by name.
    public static func scan(root: String, fileManager: FileManager = .default) -> [RepoCheckout] {
        let base = (root as NSString).expandingTildeInPath
        guard let names = try? fileManager.contentsOfDirectory(atPath: base) else { return [] }
        return names.filter { !$0.hasPrefix(".") }
            .compactMap { checkout(at: (base as NSString).appendingPathComponent($0), fileManager: fileManager) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The checkout at `path`, when it is one.
    public static func checkout(at path: String, fileManager: FileManager = .default) -> RepoCheckout? {
        var isDirectory: ObjCBool = false
        let git = (path as NSString).appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: git, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let config = (try? String(contentsOfFile: (git as NSString).appendingPathComponent("config"), encoding: .utf8)) ?? ""
        return RepoCheckout(path: path, nameWithOwner: originURL(config: config).flatMap(nameWithOwner(remote:)))
    }

    /// The `url` of `[remote "origin"]` in a git config file.
    public static func originURL(config: String) -> String? {
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
            } else if inOrigin, let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces) == "url" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// `owner/name` from a GitHub URL: `https://github.com/o/n(.git)`, `git@github.com:o/n.git` or
    /// `ssh://git@github.com/o/n.git`. Nil for any other host.
    public static func nameWithOwner(remote: String) -> String? {
        var rest: Substring
        let url = remote.trimmingCharacters(in: .whitespaces)
        if let range = url.range(of: "github.com:"), url.hasPrefix("git@") {
            rest = url[range.upperBound...]
        } else if let range = url.range(of: "github.com/"), url.contains("://") {
            rest = url[range.upperBound...]
        } else {
            return nil
        }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// The checkout a request names: `owner/name` (or its GitHub URL), the name alone, or a folder.
    /// A checkout whose origin isn't on GitHub goes by its folder's name, also after an owner.
    public static func find(_ reference: String, in checkouts: [RepoCheckout], fileManager: FileManager = .default) -> RepoCheckout? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }
        if reference.hasPrefix("/") || reference.hasPrefix("~") {
            let path = URL(fileURLWithPath: (reference as NSString).expandingTildeInPath).standardizedFileURL.path
            return checkouts.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }
                ?? checkout(at: path, fileManager: fileManager)
        }
        let wanted = (nameWithOwner(remote: reference) ?? reference).lowercased()
        let folder = { (checkout: RepoCheckout) in (checkout.path as NSString).lastPathComponent.lowercased() }
        if wanted.contains("/") {
            let name = TaskNaming.repoName(wanted)
            return checkouts.first { $0.nameWithOwner?.lowercased() == wanted }
                ?? checkouts.first { $0.nameWithOwner == nil && folder($0) == name }
        }
        return checkouts.first { $0.name.lowercased() == wanted } ?? checkouts.first { folder($0) == wanted }
    }
}

/// A task's worktree, made or reopened from the repository's main checkout, which stays on its
/// default branch.
public enum TaskWorktree {
    /// A step that failed: what BotChu was doing, and the command with what it printed.
    public struct Failure: Error, Equatable, Sendable {
        public var step: String
        public var output: String

        public init(step: String, output: String) {
            self.step = step
            self.output = output
        }

        public var message: String { output.isEmpty ? step : "\(step).\n\(output)" }
    }

    /// Where BotChu puts a branch's worktree itself: `.claude/worktrees/<type>-<slug>` in the main
    /// checkout, where the workspace standard's `scripts/worktree.sh` puts it too.
    public static func folder(for branch: String, in checkout: String) -> String {
        (checkout as NSString).appendingPathComponent(".claude/worktrees/" + branch.replacingOccurrences(of: "/", with: "-"))
    }

    /// The worktree on `branch`, made or reopened. A repository with the standard's
    /// `scripts/worktree.sh` makes it itself (from origin's main, with `.env` linked, and a new
    /// `<type>/<number>-<slug>` branch created on GitHub, linked to its issue). Elsewhere BotChu uses
    /// git: the worktree already on the branch, else a new one on the local branch, on origin's
    /// branch, or on a new branch from origin's default branch. Returns the worktree's folder.
    public static func prepare(branch: String, checkout: String) async -> Result<String, Failure> {
        let script = (checkout as NSString).appendingPathComponent("scripts/worktree.sh")
        if FileManager.default.isExecutableFile(atPath: script), TaskNaming.isStandardBranch(branch) {
            let run = await Shell.run([script, branch], in: checkout)
            guard run.ok, let folder = run.lastLine, FileManager.default.fileExists(atPath: folder) else {
                return .failure(Failure(step: "scripts/worktree.sh \(branch) failed", output: run.report("scripts/worktree.sh \(branch)")))
            }
            return .success(folder)
        }

        let list = await Shell.run(["git", "worktree", "list", "--porcelain"], in: checkout)
        guard list.ok else { return .failure(Failure(step: "\(checkout) isn't a git checkout", output: list.report("git worktree list"))) }
        if let existing = entries(porcelain: list.output).first(where: { $0.branch == branch && FileManager.default.fileExists(atPath: $0.path) }) {
            return .success(existing.path)
        }
        let folder = folder(for: branch, in: checkout)
        if FileManager.default.fileExists(atPath: folder) {
            return .failure(Failure(step: "\(folder) exists but isn't a worktree on \(branch)", output: "Move it out of the way, then try again."))
        }
        let fetched = await Shell.run(["git", "fetch", "--quiet", "origin"], in: checkout).ok
        await ignoreWorktrees(in: checkout)
        let has = { (ref: String) async in await Shell.run(["git", "show-ref", "--verify", "--quiet", ref], in: checkout).ok }
        var add = ["git", "worktree", "add", "--quiet"]
        if await has("refs/heads/\(branch)") {
            add += [folder, branch]
        } else if await has("refs/remotes/origin/\(branch)") {
            add += ["--track", "-b", branch, folder, "origin/\(branch)"]
        } else {
            // A new branch starts from origin's default branch, as fetched just now; without origin,
            // from the main checkout's own branch.
            var base = "HEAD"
            if fetched {
                let head = await Shell.run(["git", "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: checkout)
                if head.ok, let ref = head.lastLine {
                    base = ref.replacingOccurrences(of: "refs/remotes/", with: "")
                } else if await has("refs/remotes/origin/main") {
                    base = "origin/main"
                } else if await has("refs/remotes/origin/master") {
                    base = "origin/master"
                }
            }
            add += ["--no-track", "-b", branch, folder, base]
        }
        let made = await Shell.run(add, in: checkout)
        guard made.ok, FileManager.default.fileExists(atPath: folder) else {
            return .failure(Failure(step: "Making the worktree for \(branch) failed", output: made.report(add.joined(separator: " "))))
        }
        return .success(folder)
    }

    /// The linked worktrees in `git worktree list --porcelain`, without the main checkout (listed first).
    static func entries(porcelain: String) -> [(path: String, branch: String?)] {
        var entries: [(path: String, branch: String?)] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var entry: (path: String, branch: String?)?
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { entry = (String(line.dropFirst(9)), nil) }
                if line.hasPrefix("branch refs/heads/") { entry?.branch = String(line.dropFirst(18)) }
            }
            if let entry { entries.append(entry) }
        }
        return Array(entries.dropFirst())
    }

    /// Keeps `.claude/worktrees/` out of the main checkout's status, in `.git/info/exclude`, when
    /// nothing ignores it yet.
    static func ignoreWorktrees(in checkout: String) async {
        guard !(await Shell.run(["git", "check-ignore", "-q", "--no-index", ".claude/worktrees/x"], in: checkout).ok) else { return }
        let exclude = (checkout as NSString).appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        try? FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + ".claude/worktrees/\n")
            .write(toFile: exclude, atomically: true, encoding: .utf8)
    }
}

/// What BotChu asks GitHub, through the `gh` CLI as the owner signed it in.
public enum GitHubLookup {
    /// An issue or pull request, with a pull request's head branch.
    public struct Found: Equatable, Sendable {
        public var work: BotTask.Work
        public var branch: String?
        /// A pull request from a fork, whose branch isn't on origin.
        public var fromFork: Bool
        /// `OPEN`, `CLOSED` or `MERGED`.
        public var state: String
    }

    public static func work(number: Int, pullRequest: Bool, repo: String, in folder: String) async -> Result<Found, TaskWorktree.Failure> {
        let fields = pullRequest ? "number,title,url,state,headRefName,isCrossRepository" : "number,title,url,state"
        let args = ["gh", pullRequest ? "pr" : "issue", "view", String(number), "--repo", repo, "--json", fields]
        let run = await Shell.run(args, in: folder)
        guard run.ok, let found = parseWork(run.output, pullRequest: pullRequest) else {
            let what = pullRequest ? "pull request" : "issue"
            return .failure(TaskWorktree.Failure(step: "Couldn't read \(what) #\(number) of \(repo) with gh", output: run.report(args.joined(separator: " "))))
        }
        return .success(found)
    }

    /// The open pull requests, then the open issues, each newest first.
    public static func openWork(repo: String, in folder: String) async -> Result<[Found], TaskWorktree.Failure> {
        var all: [Found] = []
        for pullRequest in [true, false] {
            let fields = pullRequest ? "number,title,url,state,headRefName,isCrossRepository" : "number,title,url,state"
            let args = ["gh", pullRequest ? "pr" : "issue", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", fields]
            let run = await Shell.run(args, in: folder)
            guard run.ok else {
                return .failure(TaskWorktree.Failure(step: "Couldn't list \(repo)'s open work with gh", output: run.report(args.joined(separator: " "))))
            }
            all += parseList(run.output, pullRequest: pullRequest)
        }
        return .success(all)
    }

    static func parseWork(_ output: String, pullRequest: Bool) -> Found? {
        (json(output) as? [String: Any]).flatMap { found(in: $0, pullRequest: pullRequest) }
    }

    static func parseList(_ output: String, pullRequest: Bool) -> [Found] {
        (json(output) as? [[String: Any]] ?? []).compactMap { found(in: $0, pullRequest: pullRequest) }
    }

    static func found(in object: [String: Any], pullRequest: Bool) -> Found? {
        guard let number = object["number"] as? Int, let url = (object["url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let work = BotTask.Work(number: number, title: object["title"] as? String ?? "", url: url, isPullRequest: pullRequest)
        return Found(work: work, branch: object["headRefName"] as? String, fromFork: object["isCrossRepository"] as? Bool ?? false,
                     state: object["state"] as? String ?? "")
    }

    /// The JSON gh printed, after anything the login shell printed first.
    static func json(_ output: String) -> Any? {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...].utf8))
    }
}
