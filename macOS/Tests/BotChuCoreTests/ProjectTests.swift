import Foundation
import Testing
@testable import BotChuCore

@Suite struct ProjectRecordTests {
    @Test func preservesUnknownFrontmatterBodyAndLineEndings() throws {
        let text = "---\r\nname: Before # keep until edited\r\ntype: local\r\nstatus: active\r\ndeploy: local:my-mac:~/apps/repo\r\nmerge: owner\r\nsources:\r\n  - kind: gdoc\r\n    url: https://example.com\r\nstandard: 2026-10-20\r\n---\r\n\r\n# Purpose\r\nKeep this exactly.\r\n"
        let record = ProjectRecord(text: text, sha: "original")
        var metadata = try record.metadata(repoName: "repo")
        #expect(try record.updating(metadata) == text)
        metadata.name = "Plan: #1"
        metadata.status = .paused
        let updated = try record.updating(metadata)
        #expect(updated == text.replacingOccurrences(of: "name: Before # keep until edited", with: "name: \"Plan: #1\"").replacingOccurrences(of: "status: active", with: "status: paused"))
        #expect(try ProjectRecord(text: updated, sha: "new").metadata(repoName: "repo") == metadata)
    }

    @Test(arguments: ["- leading", "Plan:", "123", "true", "Someone's # notes"])
    func namesAreAlwaysStrings(_ name: String) throws {
        let record = ProjectRecord(text: "", sha: nil)
        let text = try record.updating(ProjectMetadata(name: name))
        #expect(text.contains("name: \""))
        #expect(try ProjectRecord(text: text, sha: "new").metadata(repoName: "repo").name == name)
    }

    @Test(arguments: ["name: One\nname: Two", "name: Before\n  and continuation", "name: |\n  Multiline", "type: unknown", "status: unknown"])
    func refusesAmbiguousRecords(_ fields: String) {
        let record = ProjectRecord(text: "---\n\(fields)\n---\nBody\n", sha: "blob")
        #expect(throws: ProjectRecord.Problem.self) { try record.metadata(repoName: "repo") }
    }

    @Test func quotedDeploymentResolvesToTheRightHost() throws {
        let record = ProjectRecord(text: "", sha: nil)
        let text = try record.updating(ProjectMetadata(name: "Café", kind: .local, deploy: "local:far-mac:~/apps/café"))
        #expect(text.contains("deploy: local:far-mac:~/apps/café\n"))
        let targets = DeployTarget.parse(try ProjectRecord(text: text, sha: "1").metadata(repoName: "café").deploy)
        #expect(targets == [DeployTarget(kind: .local, name: "far-mac", path: "~/apps/café")])
        let quoted = ProjectRecord(text: "---\nname: repo\ntype: local\ndeploy: 'local:far-mac:~/apps/repo' # comment\n---", sha: "2")
        #expect(DeployTarget.parse(try quoted.metadata(repoName: "repo").deploy).first?.name == "far-mac")
    }

    @Test func validatesDeploymentAgainstProjectType() {
        #expect(ProjectMetadata(name: "Docs", kind: .docs, deploy: "local:mac:~/repo").problem != nil)
        #expect(ProjectMetadata(name: "App", kind: .local, deploy: "local:mac:~/repo, local:mac:~/other").problem != nil)
        #expect(ProjectMetadata(name: "App", kind: .hosted, deploy: "vercel:app, local:mac:~/repo").problem == nil)
        #expect(ProjectMetadata(name: "App", kind: .hosted, deploy: "vercel:a,vercel:b").problem != nil)
        #expect(ProjectMetadata(name: "App", kind: .library, deploy: "registry:a,registry:b").problem != nil)
        #expect(ProjectMetadata(name: "App", kind: .local, deploy: "local:-mac:~/repo").problem != nil)
    }
}

@Suite struct ProjectGitHubTests {
    @Test func staleDraftMakesNoRemoteChanges() async throws {
        let server = ProjectServer()
        let client = ProjectGitHub { await server.run($0, $1) }
        await #expect(throws: ProjectRecord.Problem.self) {
            try await client.publish(repo: "test/repo", original: ProjectRecord(text: "old", sha: "stale"), text: "new")
        }
        #expect(await server.mutations == 0)
    }

    @Test(arguments: ["write", "pr"])
    func retryRecoversLostResponsesWithoutDuplicateCommitsOrPRs(_ lost: String) async throws {
        let server = ProjectServer(lost: lost)
        let client = ProjectGitHub { await server.run($0, $1) }
        let original = try await client.record(repo: "test/repo")
        let first = try await client.publish(repo: "test/repo", original: original, text: "updated")
        #expect(first.url == nil)
        #expect(first.problem != nil)
        let second = try await client.publish(repo: "test/repo", original: original, text: "updated", retryBranch: first.branch)
        #expect(second.url?.absoluteString == "https://github.com/test/repo/pull/2")
        #expect(await server.writes == 1)
        #expect(await server.prs == 1)
        #expect(await server.createdRefs == 1)
        #expect(await server.changedDefaultBranch == false)
    }

    @Test func oldMergedPRWithReusedBranchNameIsNotReportedAsNewEdit() async throws {
        let server = ProjectServer()
        let client = ProjectGitHub { await server.run($0, $1) }
        let original = try await client.record(repo: "test/repo")
        let result = try await client.publish(repo: "test/repo", original: original, text: "updated")
        #expect(result.url?.absoluteString == "https://github.com/test/repo/pull/2")
        #expect(await server.prs == 1)
    }

    @Test func missingFileAndInaccessibleRepositoryAreDifferent() async throws {
        let missing = ProjectGitHub { arguments, _ in
            if arguments.contains("repos/test/repo/contents/PROJECT.md") { return Shell.Result(status: 1, output: #"{"status":"404"}"#, errors: "") }
            return Shell.Result(status: 0, output: #"{"default_branch":"main"}"#, errors: "")
        }
        #expect(try await missing.record(repo: "test/repo").exists == false)
        let denied = ProjectGitHub { _, _ in Shell.Result(status: 1, output: #"{"status":"404"}"#, errors: "denied") }
        await #expect(throws: ProjectRecord.Problem.self) { try await denied.record(repo: "test/repo") }
    }

    @Test func connectionReportsIdentityWithoutRawErrors() async {
        let connected = ProjectGitHub { arguments, _ in
            Shell.Result(status: 0, output: arguments.contains("--version") ? "gh version 2.82.1\nMore info" : "octocat\n", errors: "")
        }
        #expect(await connected.connection() == .connected(login: "octocat", version: "gh version 2.82.1"))
        let missing = ProjectGitHub { _, _ in Shell.Result(status: 127, output: "", errors: "private diagnostic") }
        if case .unavailable(let error) = await missing.connection() { #expect(!error.contains("private diagnostic")) } else { Issue.record("Expected missing CLI") }
        let failed = ProjectGitHub { args, _ in Shell.Result(status: args.contains("--version") ? 0 : 1, output: "", errors: "private diagnostic") }
        if case .unavailable(let error) = await failed.connection() { #expect(error.contains("gh auth login")); #expect(!error.contains("private diagnostic")) } else { Issue.record("Expected failed login") }
    }
}

/// Stateful GitHub stand-in: mutations can succeed on the server while their response is lost.
private actor ProjectServer {
    let base = String(repeating: "a", count: 40)
    let head = String(repeating: "b", count: 40)
    var branch: String?
    var text = "original"
    var lost: String
    var writes = 0
    var prs = 0
    var createdRefs = 0
    var changedDefaultBranch = false
    var mutations: Int { writes + prs + createdRefs }
    init(lost: String = "") { self.lost = lost }

    func run(_ args: [String], _ data: Data?) -> Shell.Result {
        let endpoint = args[4]
        let method = args[args.firstIndex(of: "--method")! + 1]
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func json(_ value: Any, status: Int32 = 0) -> Shell.Result {
            Shell.Result(status: status, output: String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self), errors: "")
        }
        if endpoint == "repos/test/repo" { return json(["default_branch": "main", "permissions": ["push": true]]) }
        if endpoint.contains("/commits/") { return Shell.Result(status: 0, output: endpoint.hasSuffix("/main") ? base : head, errors: "") }
        if endpoint.contains("/contents/PROJECT.md") {
            if method == "PUT" {
                writes += 1
                changedDefaultBranch = body["branch"] as? String != branch
                text = String(decoding: Data(base64Encoded: body["content"] as! String)!, as: UTF8.self)
                if lost == "write" { lost = ""; return json(["status": "502"], status: 1) }
                return json(["content": ["sha": "updated-blob"]])
            }
            let original = args.contains("ref=\(base)") || !args.contains(where: { $0.hasPrefix("ref=") })
            let content = original ? "original" : text
            return json(["type": "file", "sha": content == "original" ? "original-blob" : "updated-blob", "encoding": "base64", "content": Data(content.utf8).base64EncodedString()])
        }
        if endpoint.contains("/git/ref/heads/") { return json(["status": "404"], status: 1) }
        if endpoint.hasSuffix("/git/refs") {
            createdRefs += 1
            branch = (body["ref"] as! String).replacingOccurrences(of: "refs/heads/", with: "")
            #expect(body["sha"] as? String == base)
            return json(["ref": body["ref"]!])
        }
        if endpoint.contains("/pulls") {
            if method == "POST" {
                prs += 1
                if lost == "pr" { lost = ""; return json(["status": "502"], status: 1) }
                return json(["html_url": "https://github.com/test/repo/pull/2"])
            }
            var pulls: [[String: Any]] = [["html_url": "https://github.com/test/repo/pull/1", "head": ["sha": base], "base": ["ref": "main"], "state": "closed"]]
            if prs > 0 { pulls.append(["html_url": "https://github.com/test/repo/pull/2", "head": ["sha": head], "base": ["ref": "main"], "state": "open"]) }
            return json(pulls)
        }
        Issue.record("Unexpected request: \(args)")
        return json(["status": "500"], status: 1)
    }
}

@Suite struct CustomProviderTests {
    @Test func profileSurvivesBotTaskAndSessionPersistence() throws {
        let account = Account(id: "custom-research", name: "Research", kind: .codex, defaultCommand: "codex-research", symbol: "terminal")
        var bot = Bot(name: "Scout", workspace: "/tmp/scout")
        bot.selectAccount(account)
        bot.model = "gpt-6"
        bot.sessionID = "session"
        bot.sessionAccountID = account.id
        let saved = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        #expect(saved.account == account)
        #expect(saved.resumableSessionID == "session")
        let task = BotTask(for: saved, repo: "test/repo", checkout: "/tmp/repo", work: nil, brief: "Work")
        let savedTask = try JSONDecoder().decode(BotTask.self, from: JSONEncoder().encode(task))
        #expect(savedTask.account == account)
        #expect(savedTask.model == "gpt-6")
        bot.selectAccount("claude-dev")
        #expect(bot.accountProfile == nil)
        #expect(bot.account.kind == .claude)
        #expect(bot.model.isEmpty)
        #expect(bot.resumableSessionID == nil)
    }
}
