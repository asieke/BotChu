import Foundation
import Testing
@testable import BotChuCore

/// Claude Code's own model list (#326): what its `initialize` control response gives and how it is read.
@Suite struct ClaudeModelListTests {
    private func parsed(_ sample: String) throws -> [ModelOption] {
        try ClaudeModelList.parse(ClaudeModelList.result(in: Data(sample.utf8)))
    }

    @Test func theCapturedListGivesAliasesPinsAndReportedEfforts() throws {
        let models = try parsed(ClaudeModelSamples.initialize)
        // Claude Code's order; the `default` row is the picker's "Use account default", so it isn't a choice.
        #expect(models.map(\.id) == ["opus", "claude-opus-5-5", "claude-fable-5-1[1m]", "sonnet", "claude-sonnet-5-5", "haiku",
                                     "claude-haiku-5-5", "claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5",
                                     "claude-fable-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6"])
        // An alias moves and names no version; the pin it resolved to follows it with its version.
        #expect(models.filter(\.moving).map(\.id) == ["opus", "sonnet", "haiku"])
        #expect(models.prefix(3).map(\.name) == ["Claude Opus", "Claude Opus 5.5", "Claude Fable 5.1 (1M context)"])
        #expect(models.first { $0.id == "claude-haiku-4-5-20251001" }?.name == "Claude Haiku 4.5")
        // Only the efforts a row reports: none for one that reports none, four for Opus 4.6.
        let extended: [ReasoningEffort] = [.low, .medium, .high, .xhigh, .max]
        #expect(models.first { $0.id == "haiku" }?.efforts == extended)
        #expect(models.first { $0.id == "claude-haiku-4-5-20251001" }?.efforts == [])
        #expect(models.first { $0.id == "claude-opus-4-6" }?.efforts == [.low, .medium, .high, .max])
        #expect(models.allSatisfy { !$0.fast && $0.effortsKnown && $0.contextLength == nil })
    }

    @Test func aFableAliasBringsItsPin() throws {
        // Run from inside a Claude Code session, the same CLI lists Fable as its alias.
        let models = try parsed(ClaudeModelSamples.initializeInSession)
        #expect(Array(models.map(\.id).prefix(4)) == ["opus", "claude-opus-5-5", "fable", "claude-fable-5-1"])
        #expect(models[2] == ModelOption(id: "fable", name: "Claude Fable", efforts: [.low, .medium, .high, .xhigh, .max], moving: true))
        #expect(models[3].name == "Claude Fable 5.1" && !models[3].moving)
        // The starters are this list's first rows, for before a profile's is read.
        let starters = GenerationOptions.models(for: .claude)
        #expect(models.prefix(8).map(\.id) == starters.map(\.id) && models.prefix(8).map(\.name) == starters.map(\.name))
        #expect(models.prefix(8).map(\.moving) == starters.map(\.moving))
    }

    @Test func rowsAreReadDefensively() throws {
        let models = try ClaudeModelList.parse(["models": [
            ["value": " opus ", "resolvedModel": "claude-opus-9", "displayName": "Opus 9", "supportsEffort": true, "supportedEffortLevels": ["low", "turbo", "low", "max"]],
            ["value": "opus", "displayName": "Again"],
            ["value": "", "displayName": "Blank"],
            ["displayName": "No value"],
            ["value": "claude-opus-9", "displayName": "Opus 9", "supportsEffort": false, "supportedEffortLevels": ["low"]],
            ["value": "default", "resolvedModel": "claude-opus-9"],
            ["value": "claude-sonnet-9"],
        ]])
        // Unknown and repeated efforts are dropped; a listed pin isn't added twice; a row that says it
        // takes no effort offers none; a row without a name is spelled out from its ID.
        #expect(models == [ModelOption(id: "opus", name: "Claude Opus", efforts: [.low, .max], moving: true),
                           ModelOption(id: "claude-opus-9", name: "Claude Opus 9", efforts: []),
                           ModelOption(id: "claude-sonnet-9", name: "Claude Sonnet 9", efforts: [])])
        // A Claude Code without the list, or with nothing in it, can't be read as one.
        #expect(throws: ModelListFailure.unsupported("Claude Code")) { try ClaudeModelList.parse(["commands": []]) }
        #expect(throws: ModelListFailure.unrecognized("Claude Code")) { try ClaudeModelList.parse(["models": [["value": "default"]]]) }
    }

    @Test func onlyItsOwnAnswerCounts() throws {
        let other = #"{"type":"control_response","response":{"subtype":"success","request_id":"someone-else","response":{"models":[]}}}"#
        let refused = #"{"type":"control_response","response":{"subtype":"error","request_id":"botchu-models","error":"Unknown request"}}"#
        #expect(throws: ModelListFailure.unsupported("Claude Code")) {
            try ClaudeModelList.result(in: Data((other + "\nnot json\n" + refused).utf8))
        }
        #expect(throws: ModelListFailure.unrecognized("Claude Code")) { try ClaudeModelList.result(in: Data((other + "\n").utf8)) }
        #expect(try ClaudeModelList.result(in: Data((other + "\n" + ClaudeModelSamples.initialize).utf8))["models"] != nil)
    }

    @Test func listsThroughOneControlRequestAndNothingElse() async throws {
        try await StandInLister.run(output: ClaudeModelSamples.initialize) { command, log in
            let models = try await ClaudeModelList.list(command: command, timeout: 10)
            #expect(models.count == 15)
            // No user message, so no turn: one initialize request, then end of input; no tools,
            // MCP servers, customizations or saved session.
            let asked = StandInLister.log(log)
            #expect(asked.first == "args " + ClaudeModelList.arguments.joined(separator: " "))
            #expect(asked.count == 2)
            let request = try #require(JSONSerialization.jsonObject(with: Data(asked[1].dropFirst(6).utf8)) as? [String: Any])
            #expect(request["type"] as? String == "control_request" && request["request_id"] as? String == "botchu-models")
            #expect((request["request"] as? [String: Any])?["subtype"] as? String == "initialize")
            // The shared scope reads a Claude profile the same way.
            let scoped = try await NativeModelList.list(ModelCatalogScope(accountID: "claude-dev", command: command, kind: .claude), timeout: 10)
            #expect(scoped == models)
        }
        try await StandInLister.run(output: #"{"type":"control_response","response":{"subtype":"error","request_id":"botchu-models"}}"#) { command, _ in
            await #expect(throws: ModelListFailure.unsupported("Claude Code")) { _ = try await ClaudeModelList.list(command: command, timeout: 10) }
        }
        try await StandInLister.run(output: "", exit: 1) { command, _ in
            await #expect(throws: ModelListFailure.failed("Claude Code")) { _ = try await ClaudeModelList.list(command: command, timeout: 10) }
        }
        try await StandInLister.run(output: "", hang: true) { command, _ in
            await #expect(throws: ModelListFailure("Claude Code didn’t list its models within 2 seconds.")) {
                _ = try await ClaudeModelList.list(command: command, timeout: 2)
            }
        }
    }

    @Test func aListedAliasReadsAsLatestAndItsPinAsItsVersion() throws {
        let listed = try parsed(ClaudeModelSamples.initialize)
        #expect(GenerationOptions.label(for: "opus", kind: .claude, catalog: listed) == ModelLabel(title: "Claude Opus · latest", detail: "opus · moving alias · version unresolved"))
        #expect(GenerationOptions.label(for: "claude-fable-5-1[1m]", kind: .claude, catalog: listed).title == "Claude Fable 5.1 (1M context)")
        // An alias the CLI added after BotChu's release still reads as one, from the list.
        let newer = listed + [ModelOption(id: "opusplan", name: "Claude Opus Plan", efforts: [], moving: true)]
        #expect(GenerationOptions.label(for: "opusplan", kind: .claude, catalog: newer).title == "Claude Opus Plan · latest")
        #expect(GenerationOptions.label(for: "opusplan", kind: .claude, resolved: "claude-opus-5-5", catalog: newer).title == "Claude Opus 5.5 · latest")
        #expect(GenerationOptions.efforts(for: .claude, model: "claude-haiku-4-5-20251001", catalog: listed) == [])
    }

    @Test func aReadListKeepsEverySavedChoice() throws {
        let listed = try parsed(ClaudeModelSamples.initialize)
        // Choices the list doesn't have (Fable's alias from the starters, a custom ID) stay chosen and labelled.
        let alias = ModelPickerData(kind: .claude, model: "fable", openRouterDefault: "", native: listed)
        #expect(alias.choices.map(\.id) == ["", "fable"] + listed.map(\.id))
        #expect(alias.title == "Claude Fable · latest")
        let custom = ModelPickerData(kind: .claude, model: "my-proxy-model", openRouterDefault: "", native: listed)
        #expect(custom.choices.map(\.id).prefix(2) == ["", "my-proxy-model"] && custom.title == "my-proxy-model")
        // Before any list is read, the starters stand in.
        #expect(ModelPickerData(kind: .claude, model: "", openRouterDefault: "").choices.map(\.id) == [""] + GenerationOptions.models(for: .claude).map(\.id))

        // Reading a list changes no saved model, effort or session: they're the conversation's own.
        let bot = Bot(name: "B", accountID: "claude-dev", model: "claude-opus-4-6", reasoningEffort: .xhigh, workspace: "/tmp/b",
                      sessionID: "s", sessionAccountID: "claude-dev")
        var book = NativeCatalogBook()
        let scope = ModelCatalogScope(accountID: "claude-dev", command: "~/.local/bin/claude-dev", kind: .claude)
        let token = book.begin(scope)!
        book.finish(scope, token: token, .success(listed))
        #expect(bot.model == "claude-opus-4-6" && bot.reasoningEffort == .xhigh && bot.resumableSessionID == "s")
        // Choosing again uses the list's efforts, as choosing does.
        var chosen = bot
        chosen.selectModel("claude-opus-4-6", catalog: book.models(for: scope))
        #expect(chosen.reasoningEffort == nil && chosen.resumableSessionID == "s")
    }
}

/// Antigravity's own model list (#326): `agy models`.
@Suite struct AntigravityModelListTests {
    @Test func theCapturedListGivesEachFamilyWithItsEfforts() throws {
        let models = try AntigravityModelList.parse(AntigravityModelSamples.models)
        #expect(models.map(\.id) == ["gemini-4-argon-medium", "gemini-3.8-flash-medium", "claude-opus-5-5-medium",
                                     "claude-sonnet-5-5-medium", "gpt-oss-120b-medium"])
        #expect(models.map(\.name) == ["Gemini 4 Argon", "Gemini 3.8 Flash", "Claude Opus 5.5", "Claude Sonnet 5.5", "GPT-OSS 120B"])
        #expect(models.dropLast().allSatisfy { $0.efforts == [.low, .medium, .high] })
        #expect(models.last?.efforts == [.medium])
        // The starters are the same list, so a picker offers it before the first check too.
        #expect(models == GenerationOptions.models(for: .antigravity))
    }

    @Test func linesAreReadDefensively() throws {
        let models = try AntigravityModelList.parse("""
            Fetching available models...
            gemini-5-pro-high\tGemini 5 Pro (High)
            gemini-5-pro-low\tGemini 5 Pro (Low)
            gemini-5-pro-high\tGemini 5 Pro (High)
            with spaces\tNo
            \tNo ID
            nova-1\tNova 1

            """)
        // A family without a medium variant is chosen by the first one it lists; one without
        // variants offers no effort.
        #expect(models == [ModelOption(id: "gemini-5-pro-high", name: "Gemini 5 Pro", efforts: [.low, .high]),
                           ModelOption(id: "nova-1", name: "Nova 1", efforts: [])])
        #expect(throws: ModelListFailure.unrecognized("Antigravity")) { try AntigravityModelList.parse("Fetching available models...\n") }
    }

    @Test func aListedFamilyRunsAsTheVariantForItsEffort() throws {
        let listed = try AntigravityModelList.parse("gemini-5-pro-low\tGemini 5 Pro (Low)\ngemini-5-pro-medium\tGemini 5 Pro (Medium)\ngemini-5-pro-high\tGemini 5 Pro (High)\n")
        #expect(GenerationOptions.modelArgument("gemini-5-pro-medium", kind: .antigravity, effort: .high, catalog: listed) == "gemini-5-pro-high")
        // Without the list, a family the starters don't have is sent as chosen.
        #expect(GenerationOptions.modelArgument("gemini-5-pro-medium", kind: .antigravity, effort: .high) == "gemini-5-pro-medium")
        let bot = Bot(name: "G", accountID: "google", model: "gemini-5-pro-medium", reasoningEffort: .low, workspace: "/tmp/g")
        let invocation = bot.invocation(prompt: "Hi", model: "gemini-5-pro-medium", sessionID: nil, catalog: listed)
        #expect(invocation.arguments.contains("gemini-5-pro-low") && invocation.arguments.contains("low"))
    }

    @Test func listsThroughAgyModelsAndNothingElse() async throws {
        try await StandInLister.run(output: AntigravityModelSamples.models) { command, log in
            let models = try await AntigravityModelList.list(command: command, timeout: 10)
            #expect(models.count == 5)
            // Its input is closed at once: nothing is asked of a model.
            #expect(StandInLister.log(log) == ["args models"])
            let scoped = try await NativeModelList.list(ModelCatalogScope(accountID: "google", command: command, kind: .antigravity), timeout: 10)
            #expect(scoped == models)
        }
        try await StandInLister.run(output: "Not signed in\n", exit: 1) { command, _ in
            await #expect(throws: ModelListFailure.failed("Antigravity")) { _ = try await AntigravityModelList.list(command: command, timeout: 10) }
        }
    }
}

/// Where each list is kept and how it is saved (#326).
@Suite struct ModelListScopeTests {
    @Test func everyFamilyListsItsModels() {
        #expect(AgentKind.allCases.allSatisfy(NativeModelList.lists))
    }

    @Test func listsAreKeptPerProfileCommandHostAndSailKey() {
        let local = ModelCatalogScope(accountID: "claude-dev", command: "claude-dev", kind: .claude)
        // Lists saved before #326 keep their keys on this Mac.
        #expect(local.key == ConnectorScope.profile(accountID: "claude-dev", command: "claude-dev"))
        let omarchy = ModelCatalogScope(accountID: "claude-dev", command: "claude-dev", kind: .claude,
                                        machine: Machine(destination: "me@omarchy"), folder: "~")
        let hermes = ModelCatalogScope(accountID: "claude-dev", command: "claude-dev", kind: .claude,
                                       machine: Machine(destination: "me@hermes"), folder: "~")
        // A host's list, by the same command, is its own, and never this Mac's.
        #expect(Set([local.key, omarchy.key, hermes.key]).count == 3)
        var book = NativeCatalogBook()
        book.finish(local, token: book.begin(local)!, .success([ModelOption(id: "here", name: "Here", efforts: [])]))
        #expect(book.models(for: omarchy) == nil && book.isDue(omarchy))

        // A new Sail key is another account's list; the revision means nothing to the others.
        let sail = ModelCatalogScope(accountID: "sail", command: "botchu-sail", kind: .sail, credentialRevision: 1)
        let rekeyed = ModelCatalogScope(accountID: "sail", command: "botchu-sail", kind: .sail, credentialRevision: 2)
        #expect(sail.key != rekeyed.key)
        #expect(ModelCatalogScope(accountID: "claude-dev", command: "claude-dev", kind: .claude, credentialRevision: 7) == local)
        #expect(!sail.key.contains("sail") && !omarchy.key.contains("omarchy"))
    }

    @Test func aliasesAndContextWindowsAreSaved() throws {
        let scope = ModelCatalogScope(accountID: "claude-dev", command: "claude-dev", kind: .claude)
        let models = [ModelOption(id: "opus", name: "Claude Opus", efforts: [.low], moving: true),
                      ModelOption(id: "kimi", name: "Kimi", efforts: [], effortsKnown: false, contextLength: 262_144)]
        let data = try #require(NativeCatalogFile.encode([scope.key: NativeCatalog(models: models, checkedAt: Date(timeIntervalSince1970: 1_800_000_000))]))
        #expect(NativeCatalogFile.decode(data)[scope.key]?.models == models)
        // A list saved before #326 has no aliases or context windows.
        var file = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var catalogs = try #require(file["catalogs"] as? [[String: Any]])
        var rows = try #require(catalogs[0]["models"] as? [[String: Any]])
        #expect(rows[0].removeValue(forKey: "moving") as? Bool == true && rows[0]["contextLength"] == nil)
        #expect(rows[1].removeValue(forKey: "contextLength") as? Int == 262_144 && rows[1]["moving"] == nil)
        catalogs[0]["models"] = rows
        file["catalogs"] = catalogs
        let older = NativeCatalogFile.decode(try JSONSerialization.data(withJSONObject: file))[scope.key]?.models
        #expect(older?.map(\.moving) == [false, false] && older?.map(\.contextLength) == [nil, nil])
    }

    @Test func sailsListComesFromItsKeyAndKeepsItsEfforts() async throws {
        let options = SailRuntimeAdapter.options([CatalogModel(id: "moonshotai/kimi-k3", name: "Moonshot: Kimi K3", contextLength: 262_144),
                                                  CatalogModel(id: "zai/glm-5.2", name: "GLM 5.2")])
        #expect(options.map(\.name) == ["Kimi K3", "GLM 5.2"])
        // Sail doesn't say which efforts a model takes: the family's stand, as before.
        #expect(GenerationOptions.efforts(for: .sail, model: "zai/glm-5.2", catalog: options) == [.low, .medium, .high])
        let picker = ModelPickerData(kind: .sail, model: "", openRouterDefault: "", sailDefault: "zai/glm-5.2", native: options)
        #expect(picker.choices.map(\.id) == ["", "zai/glm-5.2", "moonshotai/kimi-k3"])
        #expect(picker.choices.last?.detail == "moonshotai/kimi-k3 · 262K context")
        // Before a list is read, Sail has no starters: the default and a custom ID.
        #expect(ModelPickerData(kind: .sail, model: "", openRouterDefault: "", sailDefault: "zai/glm-5.2").choices.map(\.id) == ["", "zai/glm-5.2"])

        let scope = ModelCatalogScope(accountID: "sail", command: "botchu-sail", kind: .sail)
        await #expect(throws: ModelListFailure("Save a Sail API key in Settings ▸ Sail to list its models.")) {
            _ = try await SailRuntimeAdapter().catalog(scope, environment: [Sail.keyVariable: " \n"])
        }
        var remote = scope
        remote.machine = Machine(destination: "me@omarchy")
        await #expect(throws: ModelListFailure.unsupported("Sail on a host")) {
            _ = try await SailRuntimeAdapter().catalog(remote, environment: [Sail.keyVariable: "test-key"])
        }
    }
}

/// `botchu-models refresh` (#326): an agent checks the lists now.
@Suite struct ModelRefreshTests {
    @Test func requestsAreReadAndCheckedAgainstTheAskingTurn() throws {
        let id = UUID(), invocation = UUID(), bot = UUID()
        let fields: [String: Any] = ["kind": "modelRefresh", "id": id.uuidString, "invocationID": invocation.uuidString,
                                     "callerBotID": bot.uuidString, "accountIDs": ["claude-dev"]]
        let data = try JSONSerialization.data(withJSONObject: fields)
        #expect(ModelRefreshRequest.isRequest(data) && !TaskListRequest.isRequest(data) && !TaskHandoff.isHandoff(data))
        let request = try ModelRefreshRequest.parse(data)
        #expect(request == ModelRefreshRequest(id: id, invocationID: invocation, callerBotID: bot, accountIDs: ["claude-dev"]))
        try request.validate(SubagentCallerContext(invocationID: invocation, botID: bot, taskID: nil, parentSubagentID: nil, depth: 0, workingDirectory: "/"))
        #expect(throws: InboxRequest.Problem.self) {
            try request.validate(SubagentCallerContext(invocationID: UUID(), botID: bot, taskID: nil, parentSubagentID: nil, depth: 0, workingDirectory: "/"))
        }
        var odd = fields
        odd["accountIDs"] = [1]
        #expect(throws: InboxRequest.Problem.self) { try ModelRefreshRequest.parse(JSONSerialization.data(withJSONObject: odd)) }
        odd["accountIDs"] = nil
        #expect(try ModelRefreshRequest.parse(JSONSerialization.data(withJSONObject: odd)).accountIDs.isEmpty)

        let result = ModelRefreshResult(id: id, entries: [
            ModelRefreshEntry(accountID: "claude-dev", name: "Claude Dev", models: ["opus", "claude-opus-5-5"], status: "Checked just now"),
            ModelRefreshEntry(accountID: "codex-work", name: "Codex Work on Omarchy", models: (1...45).map { "m\($0)" },
                              status: "Couldn’t check · list from 2d ago", failure: "Codex didn’t list its models within 20 seconds."),
        ])
        #expect(try SubagentIPC.decode(ModelRefreshResult.self, from: SubagentIPC.encode(result)) == result)
        let lines = try #require(result.text).split(separator: "\n").map(String.init)
        #expect(lines[0] == "Checked 2 model lists; every picker set to them shows them now:")
        #expect(lines[1] == "- Claude Dev (claude-dev): Checked just now · 2 models: opus, claude-opus-5-5")
        #expect(lines[2].hasPrefix("- Codex Work on Omarchy (codex-work): Couldn’t check · list from 2d ago (Codex didn’t list its models within 20 seconds.) · 45 models: m1, "))
        #expect(lines[2].hasSuffix("m40, and 5 more"))
    }

    @Test func agentsAreToldHowToRefreshTheLists() {
        let section = BotContext.subagentsSection(availableBots: [BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))])
        #expect(section.contains("`botchu-models refresh`") && section.contains("`--account <profile id>`"))
    }

    @Test func theHelperAsksAndPrintsTheLists() throws {
        let fixture = try HelperFixture()
        let started = try fixture.start("botchu-models", ["refresh", "--account", "claude-dev", "--account", " "])
        defer { if started.0.isRunning { started.0.terminate() } }
        let request = try ModelRefreshRequest.parse(try fixture.request().data)
        #expect(request.invocationID == fixture.invocationID && request.callerBotID == fixture.botID && request.accountIDs == ["claude-dev"])
        let result = ModelRefreshResult(id: request.id, entries: [ModelRefreshEntry(accountID: "claude-dev", name: "Claude Dev", models: ["opus"], status: "Checked just now")])
        try SubagentIPC.encode(result).write(to: fixture.ipc.resultURL(request.id), options: .atomic)
        let finished = fixture.finish(started)
        #expect(finished.code == 0, "\(finished.error)")
        #expect(finished.output == (result.text ?? "") + "\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.ipc.resultURL(request.id).path))

        let refused = try fixture.start("botchu-models", ["refresh", "--account", "nobody"])
        defer { if refused.0.isRunning { refused.0.terminate() } }
        let asked = try ModelRefreshRequest.parse(try fixture.request().data)
        try SubagentIPC.encode(ModelRefreshResult(id: asked.id, errorMessage: "no profile nobody lists models"))
            .write(to: fixture.ipc.resultURL(asked.id), options: .atomic)
        let failed = fixture.finish(refused)
        #expect(failed.code == 1 && failed.error.contains("No model lists checked: no profile nobody lists models"))
    }
}

/// A stand-in CLI for a model list: it logs its arguments and what it is sent, then prints `output`
/// (or waits, with `hang`) and exits with `exit`.
enum StandInLister {
    static func run(output: String, exit: Int32 = 0, hang: Bool = false, _ body: (_ command: String, _ log: URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-lister-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("asked.log"), printed = directory.appendingPathComponent("output.txt")
        let script = directory.appendingPathComponent("lister.py")
        try #"""
        import sys, time
        log = open(sys.argv[1], "a")
        log.write("args " + " ".join(sys.argv[5:]) + "\n"); log.flush()
        for line in sys.stdin:
            log.write("stdin " + line.strip() + "\n"); log.flush()
        if sys.argv[4] == "hang": time.sleep(30)
        sys.stdout.write(open(sys.argv[2]).read()); sys.stdout.flush()
        sys.exit(int(sys.argv[3]))
        """#.write(to: script, atomically: true, encoding: .utf8)
        try output.write(to: printed, atomically: true, encoding: .utf8)
        try await body("/usr/bin/python3 -I \(script.path) \(log.path) \(printed.path) \(exit) \(hang ? "hang" : "answer")", log)
    }

    static func log(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// A mailbox and the helpers as a turn has them, with the app's side played by the test.
private final class HelperFixture {
    let root: URL
    let ipc: SubagentIPC
    let bin: URL
    let botID = UUID()
    let invocationID = UUID()

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-models-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.resolvingSymlinksInPath()
        ipc = SubagentIPC(root: root.appendingPathComponent("mailbox"))
        bin = root.appendingPathComponent("bin")
        try SubagentHookInstaller.install(binDirectory: bin)
        try ipc.prepare()
        try ipc.writeHeartbeat()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start(_ command: String, _ arguments: [String]) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = bin.appendingPathComponent(command)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                               "BOTCHU_IPC_DIR": ipc.root.path, "BOTCHU_INVOCATION_ID": invocationID.uuidString,
                               "BOTCHU_CALLER_BOT_ID": botID.uuidString, "BOTCHU_WAIT_TIMEOUT_SECONDS": "5"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        return (process, out, err)
    }

    func finish(_ started: (Process, Pipe, Pipe)) -> (code: Int32, output: String, error: String) {
        started.0.waitUntilExit()
        return (started.0.terminationStatus,
                String(decoding: started.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: started.2.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// The request the helper wrote, once it has, taken from the mailbox.
    func request() throws -> (file: URL, data: Data) {
        let deadline = Date().addingTimeInterval(3)
        while ipc.pendingRequests().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let found = try #require(ipc.pendingRequests().first)
        try? FileManager.default.removeItem(at: found.file)
        return found
    }
}
