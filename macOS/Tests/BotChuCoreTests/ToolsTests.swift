import Foundation
import Testing
@testable import BotChuCore

/// Skills & Tools (#246): the owner's tool policy, its inventory, the profile that blocks the tools
/// that are off in local turns, skills' `cli-tools:` declarations, and SSH destinations, which are
/// only guidance.
@Suite struct ToolsTests {
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: ToolLocator.realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory())
            .appendingPathComponent("botchu-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An executable script at `folder/name` that prints `name ok`.
    @discardableResult
    private func tool(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try "#!/bin/sh\necho \(name) ok\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func location(_ path: String, real: String? = nil) -> ToolLocation { ToolLocation(path: path, realPath: real ?? path) }

    private let gh = ToolCandidate(id: "catalog:gh", name: "gh", title: "GitHub CLI", path: "/opt/homebrew/bin/gh",
                                   catalog: ToolCatalog.tool("gh"), skills: [])

    // MARK: Policy

    @Test func anInstallWithoutAPolicyIsUnconfiguredAndBlocksNothing() throws {
        let folder = try folder()
        let policy = try ToolPolicy.load(from: folder)
        #expect(policy == ToolPolicy())
        #expect(!policy.isEnforced)
        let inventory = ToolInventory(policy: policy, catalogLocations: ["aws": [location("/opt/homebrew/bin/aws")]])
        #expect(inventory.blockedLocations().isEmpty)
        #expect(inventory.agentCatalog() == nil)
        #expect(try ToolSandbox.profile(for: inventory) == nil)
        // Being found never approves a tool.
        #expect(inventory.candidates().open.map(\.id) == ["catalog:aws"])
        #expect(policy.tools.isEmpty)
    }

    @Test func aDamagedPolicyThrowsRatherThanStartingOver() throws {
        let folder = try folder()
        try Data("{not json".utf8).write(to: folder.appendingPathComponent(ToolPolicy.fileName))
        #expect(throws: (any Error).self) { try ToolPolicy.load(from: folder) }
    }

    @Test func thePolicyIsSavedAndReadBack() throws {
        let folder = try folder()
        var policy = ToolPolicy(enforcedSince: Date(timeIntervalSince1970: 1_800_000_000))
        policy.approve(gh, at: Date(timeIntervalSince1970: 1_800_000_100))
        policy.setEnabled(false, for: "catalog:gh")
        policy.ignore("catalog:aws")
        policy.addDestination("sshclaw")
        try policy.save(in: folder)
        #expect(try ToolPolicy.load(from: folder) == policy)
    }

    @Test func destinationsFromBeforeTheirSwitchAreIncluded() throws {
        let json = #"{"tools":[],"ignored":[],"destinations":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","alias":"sshwork"}]}"#
        let policy = try ToolPolicy.decoder.decode(ToolPolicy.self, from: Data(json.utf8))
        #expect(policy.destinations.first?.included == true)
        #expect(policy.destinations.first?.host == "")
        #expect(!policy.isEnforced)
    }

    @Test func approvingIgnoringAndRemovingAreTheOwnersAlone() {
        var policy = ToolPolicy()
        policy.ignore(gh.id)
        #expect(policy.ignored == [gh.id])
        policy.approve(gh)
        #expect(policy.approved(gh.id)?.enabled == true)
        #expect(policy.ignored.isEmpty)
        policy.approve(gh)
        #expect(policy.tools.count == 1)
        policy.setEnabled(false, for: gh.id)
        #expect(policy.approved(declared: "gh")?.enabled == false)
        policy.remove(gh.id)
        #expect(policy.tools.isEmpty)
        // A candidate with no catalog tool and no path is nothing to approve.
        policy.approve(ToolCandidate(id: "x", name: "x", title: "", path: nil, catalog: nil, skills: []))
        #expect(policy.tools.isEmpty)
    }

    // MARK: Inventory

    @Test func candidatesAreFoundCatalogToolsAndDeclaredCommandsNeverApproved() {
        var policy = ToolPolicy()
        policy.approve(gh)
        policy.ignore("catalog:docker")
        let inventory = ToolInventory(
            policy: policy,
            catalogLocations: ["gh": [location("/opt/homebrew/bin/gh")], "aws": [location("/opt/homebrew/bin/aws")],
                               "docker": [location("/usr/local/bin/docker")]],
            declaredLocations: ["jq": location("/opt/homebrew/bin/jq")],
            declarations: [(skill: "research", tools: ["gh", "jq", "pandoc"]), (skill: "deploy", tools: ["aws", "JQ"])])
        let candidates = inventory.candidates()
        #expect(candidates.open.map(\.id) == ["catalog:aws", "path:/opt/homebrew/bin/jq"])
        #expect(candidates.open.first?.skills == ["deploy"])
        #expect(candidates.open.last?.skills == ["research", "deploy"])
        #expect(candidates.ignored.map(\.id) == ["catalog:docker"])
        // pandoc isn't on This Mac, so it is missing rather than a candidate.
        #expect(inventory.dependency("gh") == .enabled)
        #expect(inventory.dependency("jq") == .notApproved)
        #expect(inventory.dependency("aws") == .notApproved)
        #expect(inventory.dependency("pandoc") == .missing)
        #expect(inventory.dependency("heroku") == .missing)
        #expect(inventory.skills(declaring: policy.tools[0]) == ["research"])
    }

    @Test func dependenciesTellOffFromMissingAndNotApproved() {
        var policy = ToolPolicy(enforcedSince: Date())
        policy.approve(gh)
        policy.setEnabled(false, for: gh.id)
        let inventory = ToolInventory(policy: policy, catalogLocations: ["gh": [location("/opt/homebrew/bin/gh")]])
        // A catalog tool counts by any of its commands.
        #expect(inventory.dependency("gh") == .off)
        #expect(inventory.dependency("gsutil") == .missing)
    }

    @Test func enforcementBlocksTheCatalogToolsThatAreNotApprovedAndOn() {
        var policy = ToolPolicy(enforcedSince: Date())
        policy.approve(gh)
        policy.approve(ToolCandidate(id: "catalog:aws", name: "aws", title: "AWS CLI", path: "/b/aws", catalog: ToolCatalog.tool("aws"), skills: []))
        policy.setEnabled(false, for: "catalog:aws")
        policy.approve(ToolCandidate(id: "path:/opt/x/mytool", name: "mytool", title: "", path: "/opt/x/mytool", catalog: nil, skills: []))
        policy.approve(ToolCandidate(id: "path:/opt/x/offtool", name: "offtool", title: "", path: "/opt/x/offtool", catalog: nil, skills: []))
        policy.setEnabled(false, for: "path:/opt/x/offtool")
        let inventory = ToolInventory(policy: policy, catalogLocations: [
            "gh": [location("/opt/homebrew/bin/gh")], "aws": [location("/b/aws")],
            "gcloud": [location("/b/gcloud"), location("/b/gsutil")],
        ])
        #expect(Set(inventory.blockedLocations().map(\.path)) == ["/b/aws", "/b/gcloud", "/b/gsutil", "/opt/x/offtool"])
        let catalog = inventory.agentCatalog() ?? ""
        #expect(catalog.contains("- `gh` — GitHub CLI"))
        #expect(catalog.contains("- `mytool` (`/opt/x/mytool`)"))
        #expect(!catalog.contains("offtool"))
        #expect(catalog.contains("`aws`"))
        #expect(catalog.contains("SSH, scp, sftp and rsync are never restricted."))
        #expect(inventory.blocks(policy.approved("catalog:aws")!))
        #expect(!inventory.blocks(policy.approved(gh.id)!))
    }

    @Test func turningEnforcementOffUnblocksEverything() {
        var policy = ToolPolicy(enforcedSince: Date())
        let inventory = { ToolInventory(policy: policy, catalogLocations: ["aws": [self.location("/b/aws")]]) }
        #expect(!inventory().blockedLocations().isEmpty)
        policy.enforcedSince = nil
        #expect(inventory().blockedLocations().isEmpty)
        // Not enforced, sessions are told only what is approved and on, and nothing is said to be blocked.
        #expect(inventory().agentCatalog() == nil)
        policy.approve(ToolCandidate(id: "catalog:gh", name: "gh", title: "GitHub CLI", path: "/b/gh", catalog: ToolCatalog.tool("gh"), skills: []))
        let told = inventory().agentCatalog() ?? ""
        #expect(told.contains("- `gh` — GitHub CLI"))
        #expect(!told.localizedCaseInsensitiveContains("blocked"))
        policy.setEnabled(false, for: "catalog:gh")
        #expect(inventory().agentCatalog() == nil)
    }

    @Test func theCatalogLeavesOutSSHGitShellsAndAgentCLIs() {
        for name in ["ssh", "scp", "sftp", "rsync", "tailscale", "git", "zsh", "sh", "python3", "node", "claude", "codex", "botchu-subagent"] {
            #expect(ToolCatalog.tool(command: name) == nil, "\(name)")
        }
        #expect(ToolCatalog.tool(command: "gsutil")?.id == "gcloud")
        #expect(ToolCatalog.tool(command: "flyctl")?.id == "fly")
    }

    // MARK: Locating

    @Test func skillExecutablePathsOutsideTheSearchPathAreFoundWithoutRunningThem() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try tool("kalshi", in: root)
        let document = root.appendingPathComponent("notes")
        try "not a tool".write(to: document, atomically: true, encoding: .utf8)
        let locator = ToolLocator(directories: ["/usr/bin", "/bin"])
        let locations = locator.firstLocations(of: ["cat", "git", "ls", executable.path, document.path, root.path])
        #expect(locations["kalshi"]?.path == executable.path)
        #expect(locations["notes"] == nil)
        #expect(locations[root.lastPathComponent] == nil)
        let text = "```sh\ncat x\ngit status\nls\n```\nExecutable: `\(executable.path)`."
        let skill = Skill(slug: "kalshi-cli", text: text, scope: .bot, url: root.appendingPathComponent("SKILL.md"))
        #expect(skill.usedTools(in: ToolInventory(policy: ToolPolicy(), catalogLocations: [:], declaredLocations: locations)) == ["kalshi"])
    }

    @Test func inferredToolsConnectSkillsAndApprovalWithoutWritingTheSkillOrEnforcing() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try tool("kalshi", in: root)
        let source = "---\nname: kalshi-cli\n---\n```sh\nkalshi markets\n```\n"
        let url = root.appendingPathComponent("SKILL.md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let skill = Skill(slug: "kalshi-cli", text: source, scope: .bot, url: url)
        var policy = ToolPolicy()
        let locations = ["kalshi": location(executable.path)]
        let detected = skill.usedTools(in: ToolInventory(policy: policy, catalogLocations: [:], declaredLocations: locations))
        let inventory = { ToolInventory(policy: policy, catalogLocations: [:], declaredLocations: locations,
                                        declarations: [("kalshi-cli", detected), ("kalshi-backtest", detected)]) }
        #expect(inventory().dependency("kalshi") == .notApproved)
        let candidate = try #require(inventory().candidates().open.first)
        #expect(candidate.skills == ["kalshi-cli", "kalshi-backtest"])
        policy.ignore(candidate.id)
        // Inline approval can also restore an ignored candidate, through the same policy action.
        #expect(inventory().candidate(for: "kalshi") == candidate)
        policy.approve(try #require(inventory().candidate(for: "kalshi")))
        let approved = try #require(policy.approved(candidate.id))
        #expect(inventory().dependency("kalshi") == .enabled)
        #expect(inventory().skills(declaring: approved) == ["kalshi-cli", "kalshi-backtest"])
        #expect(inventory().candidate(for: "kalshi") == nil)
        #expect(inventory().candidates().open.isEmpty)
        #expect(policy.ignored.isEmpty)
        #expect(!policy.isEnforced && inventory().blockedLocations().isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == source)
    }

    @Test func theLocatorFindsExecutablesWithoutRunningThem() throws {
        let one = try folder(), two = try folder()
        try tool("aws", in: two)
        let link = one.appendingPathComponent("aws")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: two.appendingPathComponent("aws"))
        try "not executable".write(to: one.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: one.appendingPathComponent("doctl"), withIntermediateDirectories: true)
        let locator = ToolLocator(directories: [one.path, two.path])
        let found = locator.catalogLocations()
        #expect(found["aws"] == [ToolLocation(path: link.path, realPath: two.appendingPathComponent("aws").path),
                                 ToolLocation(path: two.appendingPathComponent("aws").path, realPath: two.appendingPathComponent("aws").path)])
        #expect(found["gh"] == nil)
        #expect(found["doctl"] == nil)
        #expect(locator.locations(of: "../aws").isEmpty)
    }

    @Test func theLocatorSearchesTheLoginPathFirstAndEachFolderOnce() {
        let locator = ToolLocator(loginPath: "/custom/bin:/opt/homebrew/bin:relative", home: "/Users/me")
        #expect(locator.directories.first == "/custom/bin")
        #expect(locator.directories.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(!locator.directories.contains("relative"))
        #expect(locator.directories.contains("/Users/me/.local/bin"))
    }

    // MARK: Sandbox rules

    @Test func rulesBlockTheLinkTheFileItLeadsToAndItsPackage() {
        let rules = ToolSandbox.rules(blocking: [
            location("/opt/homebrew/bin/aws", real: "/opt/homebrew/Cellar/awscli/2.36.36/libexec/bin/aws"),
            location("/opt/homebrew/bin/vercel", real: "/opt/homebrew/lib/node_modules/vercel/dist/vc.js"),
            location("/opt/homebrew/bin/wrangler", real: "/opt/homebrew/lib/node_modules/@cloudflare/wrangler/bin/wrangler.js"),
            location("/usr/local/bin/docker", real: "/Applications/Docker.app/Contents/Resources/bin/docker"),
        ])
        #expect(rules.files == ["/opt/homebrew/bin/aws", "/opt/homebrew/Cellar/awscli/2.36.36/libexec/bin/aws",
                                "/opt/homebrew/bin/vercel", "/opt/homebrew/lib/node_modules/vercel/dist/vc.js",
                                "/opt/homebrew/bin/wrangler", "/opt/homebrew/lib/node_modules/@cloudflare/wrangler/bin/wrangler.js",
                                "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"])
        #expect(rules.folders == ["/opt/homebrew/Cellar/awscli", "/opt/homebrew/lib/node_modules/vercel",
                                  "/opt/homebrew/lib/node_modules/@cloudflare/wrangler"])
    }

    @Test func rulesNeverBlockRuntimesSharedLaunchersOrShells() {
        let rules = ToolSandbox.rules(blocking: [
            location("/opt/homebrew/bin/firebase", real: "/opt/homebrew/Cellar/node/24.1.0/bin/node"),
            location("/Users/me/.local/share/mise/shims/heroku", real: "/opt/homebrew/bin/mise"),
            location("/b/stripe", real: "/bin/zsh"),
        ])
        #expect(rules.files == ["/opt/homebrew/bin/firebase", "/Users/me/.local/share/mise/shims/heroku"])
        #expect(rules.folders.isEmpty)
    }

    @Test func rulesNeverBlockSSHItsTransfersOrGitWhateverLeadsToThem() {
        let rules = ToolSandbox.rules(blocking: [
            location("/usr/bin/ssh"), location("/usr/bin/scp"), location("/usr/bin/sftp"), location("/opt/homebrew/bin/rsync"),
            location("/opt/homebrew/bin/fly", real: "/usr/bin/ssh"),
            location("/opt/homebrew/bin/op", real: "/opt/homebrew/Cellar/openssh/9.9p1/bin/ssh"),
            location("/opt/homebrew/bin/ngrok", real: "/opt/homebrew/Cellar/git/2.47.0/bin/ngrok-helper"),
            location("/usr/local/bin/tailscale"), location("/usr/bin/git"),
        ])
        #expect(rules.files == ["/opt/homebrew/bin/ngrok", "/opt/homebrew/Cellar/git/2.47.0/bin/ngrok-helper"])
        #expect(rules.folders.isEmpty)
        #expect(ToolInventory.problem(choosing: "/usr/bin/ssh") == "BotChu never restricts ssh.")
        #expect(ToolInventory.problem(choosing: "/usr/bin/rsync") == "BotChu never restricts rsync.")
    }

    @Test func theProfileDeniesRunningAndReadingOnlyWhatIsBlocked() {
        #expect(ToolSandbox.profile(ToolSandbox.Rules()) == nil)
        let profile = ToolSandbox.profile(ToolSandbox.Rules(files: ["/b/a \"q\"\\"], folders: ["/b/pkg"])) ?? ""
        #expect(profile == """
            (version 1)
            (allow default)
            (deny process-exec*
                (literal "/b/a \\"q\\"\\\\")
                (subpath "/b/pkg"))
            (deny file-read-data
                (literal "/b/a \\"q\\"\\\\")
                (subpath "/b/pkg"))
            """)
        #expect(!profile.contains("network"))
    }

    @Test func aLaunchKeepsItsCommandAndArgumentsAsTheyAre() {
        let arguments = ["-l", "-c", "ssh -i ~/.ssh/k sshwork 'cd app && ./deploy.sh' && rsync -az dist/ sshclaw:/srv/", "botchu", "--flag"]
        let plain = ToolSandbox.launch("/bin/zsh", arguments, profile: nil)
        #expect(plain.executable == "/bin/zsh")
        #expect(plain.arguments == arguments)
        let blocked = ToolSandbox.launch("/bin/zsh", arguments, profile: "(version 1)")
        #expect(blocked.executable == "/usr/bin/sandbox-exec")
        #expect(blocked.arguments == ["-p", "(version 1)", "/bin/zsh"] + arguments)
    }

    @Test func aMissingLauncherStopsATurnThatShouldBlock() throws {
        let inventory = ToolInventory(policy: ToolPolicy(enforcedSince: Date()), catalogLocations: ["aws": [location("/b/aws")]])
        final class NoLauncher: FileManager, @unchecked Sendable {
            override func isExecutableFile(atPath path: String) -> Bool { path == ToolSandbox.launcher ? false : super.isExecutableFile(atPath: path) }
        }
        #expect(throws: ToolSandbox.Unavailable.self) { try ToolSandbox.profile(for: inventory, fileManager: NoLauncher()) }
    }

    /// Muse sandboxes its own shell, which macOS won't nest inside a profile: its turns stop while
    /// tools are blocked, rather than run with every shell command failing or nothing blocked.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ToolSandbox.launcher)))
    func aCLIThatSandboxesItsOwnShellStopsOnlyWhileToolsAreBlocked() throws {
        let enforced = ToolInventory(policy: ToolPolicy(enforcedSince: Date()), catalogLocations: ["aws": [location("/b/aws")]])
        #expect(throws: ToolSandbox.SandboxedCLI(kind: .muse)) { try ToolSandbox.profile(for: enforced, kind: .muse) }
        for kind in AgentKind.allCases where kind != .muse {
            #expect(try ToolSandbox.profile(for: enforced, kind: kind) != nil, "\(kind)")
        }
        // Nothing to block, or not enforced: Muse runs as before.
        #expect(try ToolSandbox.profile(for: ToolInventory(policy: ToolPolicy(enforcedSince: Date()), catalogLocations: [:]), kind: .muse) == nil)
        #expect(try ToolSandbox.profile(for: ToolInventory(policy: ToolPolicy(), catalogLocations: ["aws": [location("/b/aws")]]), kind: .muse) == nil)
    }

    /// Runs `script` in zsh under the profile that blocks `blocked`, as a turn's shell runs.
    private func run(_ script: String, blocking blocked: [ToolLocation], in directory: URL) throws -> (status: Int32, output: String) {
        let profile = try #require(ToolSandbox.profile(ToolSandbox.rules(blocking: blocked)))
        let launch = ToolSandbox.launch("/bin/zsh", ["-f", "-c", script], profile: profile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "\(directory.path)/bin:/usr/bin:/bin", "HOME": directory.path]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ToolSandbox.launcher)))
    func aBlockedToolCantRunByNamePathLinkInterpreterOrCopy() throws {
        let root = try folder()
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let aws = try tool("aws", in: bin)
        let allowed = try tool("gh", in: bin)
        let blocked = [ToolLocation(path: aws.path, realPath: aws.path)]
        #expect(try run("aws", blocking: blocked, in: root).output.contains("operation not permitted"))
        #expect(try run("\(aws.path)", blocking: blocked, in: root).status != 0)
        #expect(try run("ln -s \(aws.path) link && ./link", blocking: blocked, in: root).status != 0)
        #expect(try run("/bin/sh \(aws.path)", blocking: blocked, in: root).status != 0)
        #expect(try run("cp \(aws.path) copy && ./copy", blocking: blocked, in: root).status != 0)
        #expect(try run("ln \(aws.path) hard && ./hard", blocking: blocked, in: root).status != 0)
        let other = try run("gh", blocking: blocked, in: root)
        #expect(other.status == 0)
        #expect(other.output == "gh ok\n")
        _ = allowed
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: ToolSandbox.launcher)))
    func sshAndItsTransfersStillRunWhileToolsAreBlocked() throws {
        let root = try folder()
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Every catalog tool blocked, and a catalog name that leads to ssh itself.
        var blocked = try ToolCatalog.tools.map { tool -> ToolLocation in
            let url = try self.tool(tool.id, in: bin)
            return ToolLocation(path: url.path, realPath: url.path)
        }
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("flyctl").path, withDestinationPath: "/usr/bin/ssh")
        blocked.append(ToolLocation(path: bin.appendingPathComponent("flyctl").path, realPath: "/usr/bin/ssh"))
        let ssh = try run("/usr/bin/ssh -V", blocking: blocked, in: root)
        #expect(ssh.status == 0)
        #expect(ssh.output.contains("OpenSSH"))
        // Without arguments they print their usage, not "operation not permitted".
        for command in ["/usr/bin/scp", "/usr/bin/sftp", "/usr/bin/rsync --version", "/usr/bin/git --version"] {
            let result = try run(command, blocking: blocked, in: root)
            #expect(!result.output.localizedCaseInsensitiveContains("operation not permitted"), "\(command): \(result.output)")
        }
        #expect(try run("/usr/bin/git --version", blocking: blocked, in: root).status == 0)
        // Reading the SSH config and known hosts is untouched.
        let config = root.appendingPathComponent("config")
        try "Host sshwork\n  HostName example.invalid\n".write(to: config, atomically: true, encoding: .utf8)
        let parsed = try run("/usr/bin/ssh -G -F \(config.path) sshwork", blocking: blocked, in: root)
        #expect(parsed.status == 0)
        #expect(parsed.output.contains("hostname example.invalid"))
    }

    // MARK: Declarations

    @Test func skillsDeclareTheirToolsInFrontmatterOnly() {
        #expect(Skills.declaredTools(in: "---\nname: a\ncli-tools: [gh, jq, \"aws\"]\n---\nUse gh and docker.") == ["gh", "jq", "aws"])
        #expect(Skills.declaredTools(in: "---\nname: a\ncli-tools:\n- gh\n- jq\ndescription: x\n---\n") == ["gh", "jq"])
        #expect(Skills.declaredTools(in: "---\ncli-tools:\n  - gh\n  - GH\n---\n") == ["gh"])
        #expect(Skills.declaredTools(in: "---\ncli-tools: gh, jq docker # later: aws\n---\n") == ["gh", "jq", "docker"])
        #expect(Skills.declaredTools(in: "---\ncli-tools: [gh, ../evil, /bin/rm, rm;x, $(id)]\n---\n") == ["gh"])
        // Mentioned in the text, never declared.
        #expect(Skills.declaredTools(in: "---\nname: a\n---\nRun `gh pr list`.").isEmpty)
        #expect(Skills.declaredTools(in: "cli-tools: [gh]").isEmpty)
    }

    @Test func declarationsAreSetInPlaceAddedAndKeptEmptyToOverrideInference() {
        let text = "---\nname: a\ncli-tools:\n- gh\n- jq\ndescription: x\n---\nBody"
        let replaced = Skills.settingDeclaredTools(["aws"], in: text)
        #expect(replaced == "---\nname: a\ncli-tools: [aws]\ndescription: x\n---\nBody")
        #expect(Skills.settingDeclaredTools([], in: replaced) == "---\nname: a\ncli-tools: []\ndescription: x\n---\nBody")
        #expect(Skills.settingDeclaredTools(["gh"], in: "---\nname: a\n---\nBody") == "---\nname: a\ncli-tools: [gh]\n---\nBody")
        #expect(Skills.settingDeclaredTools(["gh"], in: "Body") == "---\ncli-tools: [gh]\n---\nBody")
        #expect(Skills.settingDeclaredTools([], in: "Body") == "---\ncli-tools: []\n---\nBody")
        let removed = Skills.settingDeclaredTools([], in: "Run `gh pr list`.")
        #expect(Skills.toolCommands(in: removed).isEmpty)
        #expect(Skills.settingDeclaredTools(["gh"], in: "---\r\nname: a\r\n---\r\nBody") == "---\r\nname: a\r\ncli-tools: [gh]\r\n---\r\nBody")
        // The rest of the frontmatter still reads as before.
        let skill = Skill(slug: "a", text: replaced, scope: .shared, url: URL(fileURLWithPath: "/b/skills/a/SKILL.md"))
        #expect(skill.name == "a")
        #expect(skill.description == "x")
        #expect(skill.declaredTools == ["aws"])
    }

    // MARK: SSH destinations

    @Test func sshDestinationsAreGuidanceWithOnlyWhatTheOwnerEntered() {
        var policy = ToolPolicy()
        #expect(policy.sshGuidance() == nil)
        #expect(policy.problem(addingDestination: "ssh claw") != nil)
        let claw = policy.addDestination("sshclaw")!
        #expect(policy.addDestination("SSHCLAW") == nil)
        var work = policy.addDestination("sshwork")!
        work.user = "deploy"
        work.host = "work.example.com"
        work.identityFile = "~/.ssh/id_work"
        work.note = "Work box\nfor `deploys`"
        policy.update(work)
        let guidance = policy.sshGuidance() ?? ""
        #expect(guidance.contains("- `sshclaw`\n"))
        #expect(guidance.contains("- `sshwork` → `deploy@work.example.com` (identity file `~/.ssh/id_work`) — Work box for 'deploys'"))
        var off = claw
        off.included = false
        policy.update(off)
        #expect(!(policy.sshGuidance() ?? "").contains("sshclaw"))
        // Destinations are guidance whether or not tools are enforced, and block nothing.
        let inventory = ToolInventory(policy: policy, catalogLocations: [:])
        #expect(inventory.agentCatalog() == nil)
        #expect(inventory.agentInstructions() == policy.sshGuidance())
        #expect(inventory.blockedLocations().isEmpty)
        policy.removeDestination(work.id)
        #expect(policy.sshGuidance() == nil)
    }

    // MARK: Checks

    @Test func versionsAreReadFromRealOutput() {
        #expect(ToolProbe.version(in: "gh version 2.102.0 (2026-09-30)\nhttps://github.com/cli/cli/releases/tag/v2.102.0") == "2.102.0")
        #expect(ToolProbe.version(in: "aws-cli/2.36.36 Python/3.14.7 Darwin/27.0.0 source/arm64") == "2.36.36")
        #expect(ToolProbe.version(in: "Vercel CLI 64.5.0 (native)\n64.5.0") == "64.5.0")
        #expect(ToolProbe.version(in: "Docker version 28.1.1, build 4eba377") == "28.1.1")
        #expect(ToolProbe.version(in: "Client Version: v1.32.2\nKustomize Version: v5.5.0") == "1.32.2")
        #expect(ToolProbe.version(in: "2.121.0\nA new version of Supabase CLI is available: v2.122.0") == "2.121.0")
        #expect(ToolProbe.version(in: "railwayapp 4.0.0\n") == "4.0.0")
        #expect(ToolProbe.version(in: "ngrok version 3.22.1") == "3.22.1")
        #expect(ToolProbe.version(in: "1.26.1023.1115") == "1.26.1023.1115")
        #expect(ToolProbe.version(in: "usage: tool [options]") == nil)
    }

    /// `gh auth status --active --hostname github.com --json hosts` from gh 2.102.0, with the login
    /// and scopes replaced; it has no token field.
    static let githubSignedIn = #"""
        {"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octo-cat","tokenSource":"keyring","scopes":"gist, read:org, repo, workflow","gitProtocol":"https"}]}}
        """#

    @Test func githubSignInIsParsedFromItsJSON() {
        #expect(ToolProbe.githubSignIn(Self.githubSignedIn) == GitHubSignIn(state: .signedIn, login: "octo-cat", scopes: ["gist", "read:org", "repo", "workflow"]))
        // It exits 0 when the check failed too; the state says so.
        let failed = #"{"hosts":{"github.com":[{"state":"error","error":"HTTP 401","active":true,"host":"github.com","login":"octo-cat","tokenSource":"GH_TOKEN"}]}}"#
        #expect(ToolProbe.githubSignIn(failed) == GitHubSignIn(state: .failed, login: "octo-cat", scopes: nil))
        #expect(ToolProbe.githubSignIn(#"{"hosts":{}}"#) == GitHubSignIn(state: .signedOut))
        let empty = #"{"hosts":{"github.com":[{"state":"success","active":true,"login":"o","scopes":""}]}}"#
        #expect(ToolProbe.githubSignIn(empty)?.scopes == [])
        let odd = #"{"hosts":{"github.com":[{"state":"success","active":true,"login":"a b<script>","scopes":"repo, bad scope!"}]}}"#
        #expect(ToolProbe.githubSignIn(odd) == GitHubSignIn(state: .signedIn, login: nil, scopes: ["repo"]))
        // An older gh without --json prints text.
        #expect(ToolProbe.githubSignIn("unknown flag: --json") == nil)
    }

    @Test func aCheckRunsOnlyTheToolsOwnVersionAndStatusCommands() async throws {
        let calls = ProbeCalls()
        let probe = ToolProbe { path, arguments, environment in
            calls.append([path] + arguments + environment.keys.sorted())
            return arguments == ["--version"] ? .init(status: 0, output: "gh version 2.102.0 (2026-09-30)") : .init(status: 0, output: Self.githubSignedIn)
        }
        let result = await probe.check(ToolCatalog.tool("gh")!, at: location("/opt/homebrew/bin/gh"), now: { Date(timeIntervalSince1970: 5) })
        #expect(try result.get() == ToolReading(readAt: Date(timeIntervalSince1970: 5), path: "/opt/homebrew/bin/gh", version: "2.102.0",
                                                github: GitHubSignIn(state: .signedIn, login: "octo-cat", scopes: ["gist", "read:org", "repo", "workflow"])))
        #expect(calls.all == [
            ["/opt/homebrew/bin/gh", "--version", "GH_NO_UPDATE_NOTIFIER", "GH_PROMPT_DISABLED"],
            ["/opt/homebrew/bin/gh", "auth", "status", "--active", "--hostname", "github.com", "--json", "hosts", "GH_NO_UPDATE_NOTIFIER", "GH_PROMPT_DISABLED"],
        ])
    }

    @Test func aFailedCheckKeepsTheLastReadingAsStale() async throws {
        let timedOut = ToolProbe { _, _, _ in .init(status: 0, output: "", timedOut: true) }
        let failing = ToolProbe { _, _, _ in .init(status: 3, output: "secret-looking output") }
        let reading = ToolReading(readAt: Date(timeIntervalSince1970: 1), path: "/b/aws", version: "2.0.0")
        let check = ToolCheck(reading: reading, failure: nil, attemptedAt: Date(timeIntervalSince1970: 1))
        let aws = ToolCatalog.tool("aws")!
        let late = check.updated(with: await timedOut.check(aws, at: location("/b/aws")), at: Date(timeIntervalSince1970: 9))
        #expect(late.reading == reading)
        #expect(late.isStale)
        #expect(late.failure == "aws didn't answer within 5 seconds.")
        let failed = late.updated(with: await failing.check(aws, at: location("/b/aws")), at: Date(timeIntervalSince1970: 10))
        #expect(failed.failure == "aws couldn't report its version (exit 3).")
        #expect(!(failed.failure ?? "").contains("secret"))
        let none = ToolCheck(reading: nil, failure: nil, attemptedAt: .distantPast)
            .updated(with: await failing.check(aws, at: location("/b/aws")), at: Date())
        #expect(none.reading == nil)
        #expect(!none.isStale)
        // A version it can't recognise is unknown, not empty.
        let unknown = ToolProbe { _, _, _ in .init(status: 0, output: "usage: aws") }
        #expect(try await unknown.check(aws, at: location("/b/aws")).get().version == nil)
    }

    @Test func checksAreSavedAndADamagedFileReadsAsNone() throws {
        let folder = try folder()
        let checks = ["catalog:gh": ToolCheck(reading: ToolReading(readAt: Date(timeIntervalSince1970: 1_800_000_000), path: "/b/gh", version: "2.1.0"),
                                              failure: "x", attemptedAt: Date(timeIntervalSince1970: 1_800_000_001))]
        try ToolCheck.save(checks, in: folder)
        #expect(ToolCheck.load(from: folder) == checks)
        try Data("nope".utf8).write(to: folder.appendingPathComponent(ToolCheck.fileName))
        #expect(ToolCheck.load(from: folder).isEmpty)
    }

    @Test func theProbeRunsWithATimeLimit() async {
        let start = Date()
        let output = await ToolProbe.execute("/bin/sleep", ["30"], environment: [:], timeout: 0.2)
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
        let echo = await ToolProbe.execute("/bin/sh", ["-c", "echo hi; echo there >&2"], environment: [:])
        #expect(echo.status == 0)
        #expect(echo.output == "hi\nthere\n")
    }

    @Test func accountCommandsAreFoundAsTheLoginShellFindsThem() async {
        #expect(await ToolLocator.isAvailable("/bin/ls -la"))
        #expect(await ToolLocator.isAvailable("sh -c true"))
        #expect(!(await ToolLocator.isAvailable("/nonexistent/botchu-cli --flag")))
        #expect(!(await ToolLocator.isAvailable("~/botchu-missing-\(UUID().uuidString)")))
        #expect(!(await ToolLocator.isAvailable("botchu-missing-\(UUID().uuidString)")))
    }
}

private final class ProbeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func append(_ call: [String]) { lock.lock(); calls.append(call); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return calls }
}
