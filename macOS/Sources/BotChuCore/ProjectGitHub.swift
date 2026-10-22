import Foundation

/// GitHub project records and small metadata PRs. Uses gh's login; never reads credential files.
public struct ProjectGitHub: Sendable {
    public typealias Run = @Sendable ([String], Data?) async -> Shell.Result
    private let run: Run
    public init(run: @escaping Run = { await ProjectGitHub.command($0, body: $1) }) { self.run = run }

    public enum Connection: Equatable, Sendable {
        case connected(login: String, version: String)
        case unavailable(String)
    }

    public func connection() async -> Connection {
        let version = await run(["gh", "--version"], nil)
        guard version.ok else { return .unavailable("GitHub CLI was not found. Install gh, then run gh auth login in Terminal.") }
        let user = await api("user", query: ".login")
        let login = user.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.ok, !login.isEmpty, login.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return .unavailable("GitHub could not verify your account. Check your connection and run gh auth login --hostname github.com in Terminal, then try again.")
        }
        return .connected(login: login, version: version.output.components(separatedBy: .newlines).first ?? "gh")
    }

    public func record(repo: String, ref: String? = nil) async throws -> ProjectRecord {
        var args = ["gh", "api", "--hostname", "github.com", "repos/\(repo)/contents/PROJECT.md", "--method", "GET"]
        if let ref { args += ["-f", "ref=\(ref)"] }
        let result = await run(args, nil)
        let object = Self.object(result.output)
        if !result.ok, String(describing: object?["status"] ?? "") == "404" {
            // A missing repository / revoked access is also 404. Do not mistake that for a new file.
            let repository = await api("repos/\(repo)")
            guard repository.ok else { throw ProjectRecord.Problem("Cannot read this repository. Check GitHub access and try again.") }
            return ProjectRecord(text: "", sha: nil)
        }
        guard result.ok, object?["type"] as? String == "file", object?["encoding"] as? String == "base64",
              let sha = object?["sha"] as? String, let encoded = object?["content"] as? String,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let text = String(data: data, encoding: .utf8) else {
            throw ProjectRecord.Problem("Could not read PROJECT.md from GitHub. Check the connection and repository access, then retry.")
        }
        return ProjectRecord(text: text, sha: sha)
    }

    public struct Publication: Equatable, Sendable {
        public let branch: String
        public var url: URL?
        public var problem: String?
    }

    /// Creates one branch/commit/PR. A retry resumes its branch and recognizes an already-created PR.
    /// It never clones, runs checks, changes the default branch, or merges.
    public func publish(repo: String, original: ProjectRecord, text: String, retryBranch: String? = nil) async throws -> Publication {
        guard original.text != text else { throw ProjectRecord.Problem("There are no changes to propose.") }
        let info = await api("repos/\(repo)")
        guard info.ok, let repository = Self.object(info.output), let base = repository["default_branch"] as? String,
              (repository["archived"] as? Bool) != true else { throw ProjectRecord.Problem("This repository is unavailable or archived.") }
        if let permissions = repository["permissions"] as? [String: Any], permissions["push"] as? Bool != true {
            throw ProjectRecord.Problem("You need write access to propose metadata from BotChu. Open PROJECT.md on GitHub to use a fork.")
        }
        let branch: String
        if let retryBranch {
            branch = retryBranch
        } else {
            let head = await api("repos/\(repo)/commits/\(Self.path(base))", query: ".sha")
            let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.ok, commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw ProjectRecord.Problem("Could not read the default branch. Try again.") }
            let latest = try await record(repo: repo, ref: commit)
            guard latest == original else { throw ProjectRecord.Problem("PROJECT.md changed since you opened it. Close this editor and refresh the project before editing again.") }
            var created: String?
            for suffix in 0..<20 {
                let candidate = "docs/update-project-metadata" + (suffix == 0 ? "" : "-\(suffix + 1)")
                let existing = await api("repos/\(repo)/git/ref/heads/\(candidate)")
                if existing.ok { continue }
                guard String(describing: Self.object(existing.output)?["status"] ?? "") == "404" else {
                    throw ProjectRecord.Problem("Could not check for an existing metadata branch. Try again.")
                }
                let result = await api("repos/\(repo)/git/refs", method: "POST", body: ["ref": "refs/heads/\(candidate)", "sha": commit])
                if result.ok { created = candidate; break }
                // A simultaneous editor may have claimed this name. Only that conflict is retried.
                let raced = await api("repos/\(repo)/git/ref/heads/\(candidate)")
                guard raced.ok else { throw ProjectRecord.Problem("Could not create a metadata branch. Check repository write access and try again.") }
            }
            guard let created else { throw ProjectRecord.Problem("Too many existing metadata branches. Finish one of their pull requests first.") }
            branch = created
        }
        do {
            let onBranch = try await record(repo: repo, ref: branch)
            if onBranch.text != text {
                guard onBranch == original else { throw ProjectRecord.Problem("The metadata branch changed. Open it on GitHub to review its changes.") }
                var body: [String: Any] = ["message": "Update project metadata", "branch": branch,
                                            "content": Data(text.utf8).base64EncodedString()]
                if let sha = onBranch.sha { body["sha"] = sha }
                let saved = await api("repos/\(repo)/contents/PROJECT.md", method: "PUT", body: body)
                guard saved.ok else { throw ProjectRecord.Problem("The branch was created, but PROJECT.md could not be saved. Retry to continue on the same branch.") }
            }
            let head = await api("repos/\(repo)/commits/\(Self.path(branch))", query: ".sha")
            let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.ok, commit.count == 40, commit.allSatisfy(\.isHexDigit) else { throw ProjectRecord.Problem("Could not verify the saved commit. Retry to continue.") }
            let found = await api("repos/\(repo)/pulls?state=all&head=\(Self.path(repo.components(separatedBy: "/")[0] + ":" + branch))")
            guard found.ok, let pulls = Self.array(found.output) else { throw ProjectRecord.Problem("The changes are saved, but existing pull requests could not be checked. Retry to continue.") }
            if let pull = pulls.first(where: {
                ($0["head"] as? [String: Any])?["sha"] as? String == commit
                    && ($0["base"] as? [String: Any])?["ref"] as? String == base
            }), let address = pull["html_url"] as? String, let url = Self.githubURL(address) {
                return Publication(branch: branch, url: url, problem: nil)
            }
            let body = "## What\nUpdate the project’s name, type, status, deployment, or merge policy in PROJECT.md.\n\n## Decisions\n- Metadata-only edit proposed from BotChu; all other file content is preserved.\n\n## Checks\n- Only PROJECT.md changed; edited fields validated in BotChu.\n- Repository test suite not run for this metadata edit. Required repository checks and merge rules still apply.\n\nAgent session: n/a"
            let created = await api("repos/\(repo)/pulls", method: "POST", body: ["title": "Update project metadata", "head": branch, "base": base, "body": body])
            guard created.ok, let address = Self.object(created.output)?["html_url"] as? String, let url = Self.githubURL(address) else {
                throw ProjectRecord.Problem("The changes are saved on the branch, but the pull request could not be opened. Retry to continue.")
            }
            return Publication(branch: branch, url: url, problem: nil)
        } catch {
            return Publication(branch: branch, url: nil, problem: error.localizedDescription)
        }
    }

    private func api(_ endpoint: String, method: String = "GET", query: String? = nil, body: [String: Any]? = nil) async -> Shell.Result {
        var args = ["gh", "api", "--hostname", "github.com", endpoint, "--method", method]
        if let query { args += ["--jq", query] }
        return await run(args, body.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
    }
    private static func object(_ output: String) -> [String: Any]? { output.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    private static func array(_ output: String) -> [[String: Any]]? { output.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } }
    private static func path(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text }
    private static func githubURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    public static func command(_ arguments: [String], body: Data?) async -> Shell.Result {
        guard let body else { return await Shell.run(arguments, in: NSHomeDirectory()) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-project-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("request.json")
            try body.write(to: file, options: .atomic)
            return await Shell.run(arguments + ["--input", file.path], in: NSHomeDirectory())
        } catch { return Shell.Result(status: -1, output: "", errors: "Could not prepare the GitHub request.") }
    }
}
