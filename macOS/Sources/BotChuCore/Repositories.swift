import Foundation

/// A command run through the login shell (`zsh -l`, so PATH has git, gh and Homebrew as in
/// Terminal), in a folder, with what it printed. For the short git and gh commands tasks need.
public enum Shell {
    /// Printed before the command runs, so what the login shell's own files print is left out.
    static let marker = "__BOTCHU_COMMAND_OUTPUT__"

    public struct Result: Equatable, Sendable {
        public var status: Int32
        public var output: String
        public var errors: String

        public var ok: Bool { status == 0 }

        /// The last line of its output.
        public var lastLine: String? {
            output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        }

        /// The command and what it printed, for an error message.
        public func report(_ command: String) -> String {
            let printed = [output, errors].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return "$ \(command)\n" + (printed.isEmpty ? "(exit \(status), nothing printed)" : printed.joined(separator: "\n"))
        }
    }

    public static func run(_ arguments: [String], in directory: String, input: Data? = nil) async -> Result {
        await execute("/bin/zsh", ["-l", "-c", "print -r -- \(marker); exec \"$@\"", "botchu"] + arguments,
                      in: (directory as NSString).expandingTildeInPath, input: input)
    }

    /// Runs a program and collects what it printed after the marker.
    static func execute(_ executable: String, _ arguments: [String], in directory: String, input: Data? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
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
                let inputFile = try ProcessInput.file(input)
                defer { try? inputFile?.close() }
                process.standardInput = inputFile ?? FileHandle.nullDevice
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
                                                      output: commandOutput(String(decoding: printed.output, as: UTF8.self)),
                                                      errors: String(decoding: printed.errors, as: UTF8.self)))
            }
        }
    }

    /// What the command printed: everything after the marker.
    static func commandOutput(_ printed: String) -> String {
        guard let range = printed.range(of: marker + "\n") else { return printed }
        return String(printed[range.upperBound...])
    }

    /// What a command printed; each half is written by one reader, then read once both are done.
    private final class Printed: @unchecked Sendable {
        var output = Data()
        var errors = Data()
    }

    /// `text` as one word for a POSIX shell, in single quotes.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where a command runs: this Mac, through the login shell, or a host, over SSH through that
/// user's login shell there, never asking for a password.
public struct Machine: Hashable, Sendable {
    /// What follows `ssh`; nil for this Mac.
    public var destination: String?

    public init(destination: String?) {
        self.destination = destination
    }

    public static let thisMac = Machine(destination: nil)

    public var isRemote: Bool { destination != nil }

    /// The `ssh` that reaches hosts. Tests use a stand-in that runs the command here.
    nonisolated(unsafe) public static var ssh = "/usr/bin/ssh"

    /// Options for every connection: never prompt, give up on a host that doesn't answer, notice a
    /// connection that died, and share one connection per host for a couple of minutes, so the
    /// steps of a task don't each connect anew.
    public static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15",
                                    "-o", "ServerAliveCountMax=4", "-o", "ControlMaster=auto",
                                    "-o", "ControlPath=~/.ssh/botchu-%C", "-o", "ControlPersist=120", "-T"]

    /// Runs `arguments` in `folder` (which may start with `~`), here or there.
    public func run(_ arguments: [String], in folder: String, input: Data? = nil) async -> Shell.Result {
        guard let destination else { return await Shell.run(arguments, in: folder, input: input) }
        let script = "printf '%s\\n' \(Shell.marker); exec \"$@\""
        return await Shell.execute(Self.ssh, Self.sshOptions + [destination, Self.remoteCommand(script: script, arguments: arguments, in: folder)],
                                   in: NSHomeDirectory(), input: input)
    }

    /// Runs a POSIX `sh` script with arguments (`$1`…) in `folder`.
    public func script(_ script: String, arguments: [String] = [], in folder: String) async -> Shell.Result {
        await run(["/bin/sh", "-c", script, "botchu"] + arguments, in: folder)
    }

    /// The command string `ssh` gives the host's shell: go to the folder, then run `script` with
    /// `arguments` in the user's login shell there, so PATH is theirs.
    public static func remoteCommand(script: String, arguments: [String], in folder: String) -> String {
        "cd \(remotePath(folder)) && exec \"${SHELL:-/bin/sh}\" -lc \(Shell.quote(script)) botchu "
            + arguments.map(Shell.quote).joined(separator: " ")
    }

    /// A folder for the host's shell: quoted, with a leading `~` left for it to expand.
    public static func remotePath(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + Shell.quote(String(path.dropFirst(2))) }
        return Shell.quote(path)
    }

    /// Whether the folder is there.
    public func hasFolder(_ path: String) async -> Bool {
        guard isRemote else { return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) }
        return await run(["test", "-d", path], in: "~").ok
    }

    /// The host's short name, as PROJECT.md's `deploy` would call it, when it answers.
    public func machineName() async -> Result<String, TaskWorktree.Failure> {
        let run = await script("scutil --get LocalHostName 2>/dev/null || uname -n | cut -d. -f1", in: "~")
        guard run.ok, let name = run.lastLine, !name.isEmpty else {
            return .failure(TaskWorktree.Failure(step: "Couldn't reach \(destination ?? "this Mac")", output: run.report("ssh \(destination ?? "")")))
        }
        return .success(name)
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
/// default branch, on this Mac or on a host. Each step is one shell script, run on the machine
/// with one connection.
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

    /// A pull request's review worktree: where it is, and the commit it is detached at.
    public struct Review: Equatable, Sendable {
        public var folder: String
        public var head: String
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
    public static func prepare(branch: String, checkout: String, on machine: Machine = .thisMac) async -> Result<String, Failure> {
        let run = await machine.script(prepareScript, arguments: [branch, TaskNaming.isStandardBranch(branch) ? "1" : "0"], in: checkout)
        guard run.ok, let folder = run.lastLine, !folder.isEmpty else {
            let step: String
            switch run.status {
            case 3: step = lastLine(run.errors) ?? "\(checkout) isn't a git checkout"
            case 5: step = "scripts/worktree.sh \(branch) failed"
            default: step = machine.isRemote && run.status == 255 ? "Couldn't reach \(machine.destination ?? "")" : "Making the worktree for \(branch) failed"
            }
            return .failure(Failure(step: step, output: run.report("make the worktree for \(branch) in \(checkout)")))
        }
        return .success(folder)
    }

    /// A review worktree of pull request `number`, detached at its head (`pull/<number>/head` on
    /// origin, so a pull request from a fork works too), in a new temporary folder, as AGENTS.md's
    /// "Reviewing a pull request" makes one. The main checkout stays as it is.
    public static func review(number: Int, checkout: String, on machine: Machine = .thisMac) async -> Result<Review, Failure> {
        let run = await machine.script(reviewScript, arguments: [String(number)], in: checkout)
        let lines = run.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard run.ok, lines.count >= 2 else {
            let step = run.status == 3 || run.status == 6 ? lastLine(run.errors) ?? "Couldn't fetch pull request #\(number)"
                : machine.isRemote && run.status == 255 ? "Couldn't reach \(machine.destination ?? "")"
                : "Making the review worktree for pull request #\(number) failed"
            return .failure(Failure(step: step, output: run.report("make the review worktree for #\(number) in \(checkout)")))
        }
        return .success(Review(folder: lines[lines.count - 1], head: lines[lines.count - 2]))
    }

    /// Removes a worktree that is done with, unless it has changes git would lose.
    public static func remove(_ folder: String, checkout: String, on machine: Machine = .thisMac) async -> Shell.Result {
        await machine.run(["git", "worktree", "remove", folder], in: checkout)
    }

    /// The repository's checkout at `folder` on the machine, cloned from `source` (`owner/name` on
    /// GitHub, or a git URL) when it isn't there yet: with `gh` when it is signed in there, else
    /// with git. Returns the checkout's folder, with `~` expanded.
    public static func checkout(_ source: String, at folder: String, on machine: Machine = .thisMac) async -> Result<String, Failure> {
        let run = await machine.script(cloneScript, arguments: [folder, source], in: "~")
        guard run.ok, let checkout = run.lastLine, !checkout.isEmpty else {
            let step = run.status == 3 ? lastLine(run.errors) ?? "\(folder) isn't a git checkout"
                : machine.isRemote && run.status == 255 ? "Couldn't reach \(machine.destination ?? "")"
                : "Cloning \(source) into \(folder) failed"
            return .failure(Failure(step: step, output: run.report("clone \(source) into \(folder)")))
        }
        return .success(checkout)
    }

    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `prepare`: `$1` the branch, `$2` 1 when `scripts/worktree.sh` takes it. Prints the folder
    /// last; exits 3 (saying why) for a folder in the way, 5 when the repository's script failed.
    static let prepareScript = #"""
        branch=$1
        git rev-parse --git-dir >/dev/null 2>&1 || { echo "$(pwd -P) isn't a git checkout" >&2; exit 3; }
        # A worktree whose folder was deleted by hand is still registered, and git won't make it again.
        git worktree prune 2>/dev/null
        if [ "$2" = 1 ] && [ -x scripts/worktree.sh ]; then
          scripts/worktree.sh "$branch" || exit 5
          exit 0
        fi
        dir=$(git worktree list --porcelain | awk -v b="branch refs/heads/$branch" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}')
        if [ -n "$dir" ] && [ -d "$dir" ]; then printf '%s\n' "$dir"; exit 0; fi
        folder="$(pwd -P)/.claude/worktrees/$(printf '%s' "$branch" | tr / -)"
        if [ -e "$folder" ]; then
          echo "$folder exists but isn't a worktree on $branch. Move it out of the way, then try again." >&2; exit 3
        fi
        git fetch --quiet origin 2>/dev/null
        git check-ignore -q --no-index .claude/worktrees/x || printf '.claude/worktrees/\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
        if git show-ref --verify --quiet "refs/heads/$branch"; then
          git worktree add --quiet "$folder" "$branch" || exit 4
        elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          git worktree add --quiet --track -b "$branch" "$folder" "origin/$branch" || exit 4
        else
          # From origin's default branch as last fetched (just now, unless offline); without origin,
          # from the main checkout's own branch.
          base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
          [ -n "$base" ] || { git show-ref --verify --quiet refs/remotes/origin/main && base=origin/main; }
          [ -n "$base" ] || { git show-ref --verify --quiet refs/remotes/origin/master && base=origin/master; }
          git worktree add --quiet --no-track -b "$branch" "$folder" "${base:-HEAD}" || exit 4
        fi
        printf '%s\n' "$folder"
        """#

    /// `review`: `$1` the pull request's number. Prints the head commit, then the folder.
    static let reviewScript = #"""
        n=$1
        git rev-parse --git-dir >/dev/null 2>&1 || { echo "$(pwd -P) isn't a git checkout" >&2; exit 3; }
        git fetch --quiet origin "pull/$n/head" 2>/dev/null || { echo "Couldn't fetch pull request #$n from origin" >&2; exit 6; }
        tmp=$(mktemp -d "${TMPDIR:-/tmp}/botchu-review.XXXXXX") || exit 4
        git worktree add --quiet --detach "$tmp/pr-$n" FETCH_HEAD || exit 4
        printf '%s\n%s\n' "$(git -C "$tmp/pr-$n" rev-parse HEAD)" "$tmp/pr-$n"
        """#

    /// `checkout`: `$1` the folder (`~/…` allowed), `$2` `owner/name` or a git URL. Prints the folder.
    static let cloneScript = #"""
        dest=$1
        case $dest in "~") dest=$HOME ;; "~/"*) dest="$HOME/${dest#\~/}" ;; esac
        if [ -d "$dest/.git" ]; then printf '%s\n' "$dest"; exit 0; fi
        if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then echo "$dest is there but isn't a git checkout" >&2; exit 3; fi
        mkdir -p "$(dirname "$dest")" || exit 4
        case $2 in
          */*:*|/*|*://*) git clone --quiet "$2" "$dest" || exit 4 ;;
          *) if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
               gh repo clone "$2" "$dest" -- --quiet || exit 4
             else
               git clone --quiet "https://github.com/$2.git" "$dest" || exit 4
             fi ;;
        esac
        printf '%s\n' "$dest"
        """#
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

    /// A repository the owner's GitHub account can work on.
    public struct Repo: Identifiable, Hashable, Sendable {
        /// `owner/name`.
        public var nameWithOwner: String
        public var description: String
        public var pushedAt: Date?
        public var isPrivate: Bool
        public var isFork: Bool
        /// The owner's avatar on GitHub, and whether the owner is an organization.
        public var ownerAvatar: URL?
        public var ownerIsOrganization: Bool
        public var language: String?
        /// Open issues and open pull requests, as GitHub counts them.
        public var openIssues: Int
        public var openPullRequests: Int

        public init(nameWithOwner: String, description: String = "", pushedAt: Date? = nil, isPrivate: Bool = false,
                    isFork: Bool = false, ownerAvatar: URL? = nil, ownerIsOrganization: Bool = false, language: String? = nil,
                    openIssues: Int = 0, openPullRequests: Int = 0) {
            self.nameWithOwner = nameWithOwner; self.description = description; self.pushedAt = pushedAt; self.isPrivate = isPrivate
            self.isFork = isFork; self.ownerAvatar = ownerAvatar; self.ownerIsOrganization = ownerIsOrganization; self.language = language
            self.openIssues = openIssues; self.openPullRequests = openPullRequests
        }
        public var id: String { nameWithOwner }
        public var name: String { TaskNaming.repoName(nameWithOwner) }
        public var owner: String { String(nameWithOwner.prefix { $0 != "/" }) }
    }

    /// The repositories tasks can work on: those of the account `gh` is signed in to, and of the
    /// organizations it belongs to, without archived ones, most recently pushed first, with their
    /// open issue and pull request counts.
    public static func repositories() async -> Result<[Repo], TaskWorktree.Failure> {
        let args = ["gh", "api", "graphql", "--paginate", "-f", "query=\(repositoriesQuery)", "--jq", repositoriesFields]
        let run = await Shell.run(args, in: NSHomeDirectory())
        guard run.ok else {
            return .failure(TaskWorktree.Failure(step: "Couldn't list your GitHub repositories with gh", output: run.report("gh api graphql (repositories)")))
        }
        return .success(parseRepositories(run.output))
    }

    static let repositoriesQuery = """
        query($endCursor: String) { viewer { repositories(first: 100, after: $endCursor, \
        ownerAffiliations: [OWNER, ORGANIZATION_MEMBER], affiliations: [OWNER, ORGANIZATION_MEMBER], isArchived: false, \
        orderBy: {field: PUSHED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } nodes { \
        nameWithOwner description isArchived isPrivate isFork pushedAt owner { __typename login avatarUrl(size: 64) } \
        primaryLanguage { name } issues(states: OPEN) { totalCount } pullRequests(states: OPEN) { totalCount } } } } }
        """
    static let repositoriesFields = #".data.viewer.repositories.nodes[] | [.nameWithOwner, (.description // ""), (.isArchived | tostring), (.pushedAt // ""), (.isPrivate | tostring), (.owner.avatarUrl // ""), .owner.__typename, (.isFork | tostring), (.primaryLanguage.name // ""), (.issues.totalCount | tostring), (.pullRequests.totalCount | tostring)] | @tsv"#

    /// One repository per line: name, description, archived, pushed, private, and then (optionally)
    /// avatar, owner type, fork, language, open issues and open pull requests.
    static func parseRepositories(_ tsv: String) -> [Repo] {
        let dates = ISO8601DateFormatter()
        return tsv.split(whereSeparator: \.isNewline).compactMap { line -> Repo? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 || fields.count == 11, fields[0].contains("/"), fields[2] != "true" else { return nil }
            var repo = Repo(nameWithOwner: fields[0], description: fields[1].replacingOccurrences(of: "\\t", with: " ").replacingOccurrences(of: "\\n", with: " "),
                            pushedAt: dates.date(from: fields[3]), isPrivate: fields[4] == "true")
            if fields.count == 11 {
                repo.ownerAvatar = URL(string: fields[5]).flatMap { $0.scheme == "https" ? $0 : nil }
                repo.ownerIsOrganization = fields[6] == "Organization"
                repo.isFork = fields[7] == "true"
                repo.language = fields[8].isEmpty ? nil : fields[8]
                repo.openIssues = Int(fields[9]) ?? 0
                repo.openPullRequests = Int(fields[10]) ?? 0
            }
            return repo
        }
        .sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
    }

    /// The repository's PROJECT.md on its default branch, when it has one.
    public static func projectFile(repo: String) async -> String? {
        let run = await Shell.run(["gh", "api", "repos/\(repo)/contents/PROJECT.md", "-H", "Accept: application/vnd.github.raw"],
                                  in: NSHomeDirectory())
        return run.ok ? run.output : nil
    }

    public static func work(number: Int, pullRequest: Bool, repo: String) async -> Result<Found, TaskWorktree.Failure> {
        let fields = pullRequest ? "number,title,url,state,headRefName,isCrossRepository" : "number,title,url,state"
        let args = ["gh", pullRequest ? "pr" : "issue", "view", String(number), "--repo", repo, "--json", fields]
        let run = await Shell.run(args, in: NSHomeDirectory())
        guard run.ok, let found = parseWork(run.output, pullRequest: pullRequest) else {
            let what = pullRequest ? "pull request" : "issue"
            return .failure(TaskWorktree.Failure(step: "Couldn't read \(what) #\(number) of \(repo) with gh", output: run.report(args.joined(separator: " "))))
        }
        return .success(found)
    }

    /// The open pull requests, then the open issues, each newest first.
    public static func openWork(repo: String) async -> Result<[Found], TaskWorktree.Failure> {
        var all: [Found] = []
        for pullRequest in [true, false] {
            let fields = pullRequest ? "number,title,url,state,headRefName,isCrossRepository" : "number,title,url,state"
            let args = ["gh", pullRequest ? "pr" : "issue", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", fields]
            let run = await Shell.run(args, in: NSHomeDirectory())
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

    /// The JSON gh printed, from the first line that starts one.
    static func json(_ output: String) -> Any? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let first = lines.first, !(first.first == "{" || first.first == "[") { lines = lines.dropFirst() }
        return try? JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8))
    }
}
