import Foundation
import Testing
@testable import BotChuCore

/// A Codex profile's own model list (#220): what `model/list` gives, how it is read, kept and shown.
@Suite struct CodexModelTests {
    private func page(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func theCapturedListGivesItsVisibleModelsNamesAndEfforts() throws {
        let models = try CodexModelList.parse([page(CodexModelSamples.page)])
        #expect(models.map(\.id) == ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna",
                                     "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
        // Hidden rows (a reserve model, the auto-review one) aren't choices.
        #expect(!models.contains { $0.id == "gpt-reserve" || $0.id == "codex-auto-review" })
        let terra = try #require(models.first { $0.id == "gpt-6.1-terra" })
        #expect(terra.name == "GPT-6.1 Terra")
        #expect(terra.efforts == [.low, .medium, .high, .xhigh, .max, .ultra])
        #expect(models.first { $0.id == "gpt-6-luna" }?.efforts == [.low, .medium, .high, .xhigh, .max])
        #expect(models.allSatisfy { !$0.moving })
        // Every row listed the Fast tier (`priority`) on 2026-10-28.
        #expect(models.allSatisfy { $0.fast })
    }

    @Test func fastFollowsTheListedTiers() throws {
        let catalog = try CodexModelList.parse([page(#"""
            {"data":[{"model":"tiered","serviceTiers":[{"id":"priority","name":"Fast"}],"additionalSpeedTiers":[]},
                     {"model":"older","additionalSpeedTiers":["fast"]},
                     {"model":"flex-only","serviceTiers":[{"id":"flex","name":"Flex"}],"additionalSpeedTiers":[]},
                     {"model":"plain"}]}
            """#)])
        #expect(catalog.map { $0.fast } == [true, true, false, false])
        #expect(GenerationOptions.offersFast(for: .codex, model: "tiered", catalog: catalog))
        #expect(!GenerationOptions.offersFast(for: .codex, model: "plain", catalog: catalog))
        // The default and a model the list doesn't have are Codex's to judge; the starters have Fast.
        #expect(GenerationOptions.offersFast(for: .codex, model: "", catalog: catalog))
        #expect(GenerationOptions.offersFast(for: .codex, model: "my-fine-tune", catalog: catalog))
        #expect(GenerationOptions.models(for: .codex).allSatisfy { $0.fast })
        #expect(GenerationOptions.offersFast(for: .codex, model: "gpt-6-astra"))
        for kind in AgentKind.allCases where kind != .codex {
            #expect(!GenerationOptions.offersFast(for: kind, model: "", catalog: catalog))
        }

        // Choosing a model without Fast turns it off; one with it, or another effort, keeps it.
        var bot = Bot(name: "B", accountID: "codex-work", model: "tiered", workspace: "/tmp/b")
        bot.fastMode = true
        bot.selectModel("older", catalog: catalog)
        #expect(bot.fastMode == true)
        bot.selectModel("plain", catalog: catalog)
        #expect(bot.fastMode == nil)
        // Another CLI family turns it off with the model and effort; another Codex profile keeps it.
        bot.selectModel("tiered", catalog: catalog)
        bot.fastMode = true
        bot.selectAccount("codex-dev")
        #expect(bot.fastMode == true)
        bot.selectAccount("claude-dev")
        #expect(bot.fastMode == nil)
    }

    @Test func fastTravelsToTasksSubagentsAndJobsAndSurvivesSaving() throws {
        var bot = Bot(name: "B", accountID: "codex-work", model: "gpt-6-astra", workspace: "/tmp/b")
        bot.fastMode = true
        let restored = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        #expect(restored.fastMode == true)
        // A bot saved before #249 has it off.
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(bot)) as? [String: Any])
        old["fastMode"] = nil
        let saved = try JSONSerialization.data(withJSONObject: old)
        #expect(try JSONDecoder().decode(Bot.self, from: saved).fastMode == nil)

        #expect(BotTask(for: bot, repo: "o/r", checkout: "/tmp/r", work: nil, brief: "b").fastMode == true)
        let run = SubagentRun(rootBotID: UUID(), depth: 1, targetBot: bot, title: "t", brief: "b", workingDirectory: "/tmp/b")
        #expect(run.fastMode == true)
        let job = JobLaunch.invocation(for: bot, prompt: "p", openRouterDefault: "", openRouterKey: nil)
        #expect(job.arguments.contains(#"service_tier="fast""#))
    }

    @Test func everyPageCountsAndOddRowsAreReadSafely() throws {
        let models = try CodexModelList.parse([
            page(#"{"data":[{"id":"row-a","model":"run-a","displayName":"A","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"high"},{"reasoningEffort":"warp"},{"reasoningEffort":"high"}]}],"nextCursor":"p2"}"#),
            page(#"{"data":[{"model":"run-a","displayName":"again"},{"id":"run-b","displayName":""},{"model":"run-c","supportedReasoningEfforts":[]}],"nextCursor":null}"#),
        ])
        // The model it runs as, not the row's id; once each; an effort BotChu doesn't know is skipped.
        #expect(models.map(\.id) == ["run-a", "run-b", "run-c"])
        #expect(models[0].name == "A" && models[0].efforts == [.high])
        // No name: its id. No effort list at all: the family's. An empty one: none adjustable.
        #expect(models[1].name == "run-b" && models[1].efforts == GenerationOptions.efforts(for: .codex, model: "run-b"))
        #expect(models[2].efforts.isEmpty)

        #expect(throws: CodexModelFailure.unrecognized) { try CodexModelList.parse([page(#"{"items":[]}"#)]) }
        #expect(throws: CodexModelFailure.unrecognized) { try CodexModelList.parse([page(#"{"data":[{"model":"x","hidden":true}]}"#)]) }
        #expect(throws: CodexModelFailure.unrecognized) { try CodexModelList.parse([]) }
    }

    @Test func aProfilesListReplacesItsStartersAndKeepsSavedChoices() throws {
        let catalog = try CodexModelList.parse([page(CodexModelSamples.page)])
        let picker = ModelPickerData(kind: .codex, model: "gpt-6.1-terra", openRouterDefault: "", native: catalog)
        #expect(picker.title == "GPT-6.1 Terra")
        // The selection first, as always, then the rest of the list in Codex's order.
        #expect(picker.choices.map(\.id) == ["", "gpt-6.1-terra"] + catalog.map(\.id).filter { $0 != "gpt-6.1-terra" })
        #expect(picker.matching("terra").map(\.id) == ["gpt-6.1-terra", "gpt-5.6-terra"])

        // A model the list doesn't have (custom, retired) stays chosen and reachable; starters the
        // list leaves out aren't added back.
        let short = Array(catalog.prefix(1))
        let custom = ModelPickerData(kind: .codex, model: "my-fine-tune", openRouterDefault: "", native: short)
        #expect(custom.choices.map(\.id) == ["", "my-fine-tune", "gpt-6.1-sol"])
        #expect(custom.title == "my-fine-tune")
        #expect(!custom.choices.contains { $0.id == "gpt-6-astra" })

        // Before any list is read, the starters stand in.
        let unread = ModelPickerData(kind: .codex, model: "", openRouterDefault: "", native: nil)
        #expect(unread.choices.map(\.id) == [""] + GenerationOptions.models(for: .codex).map(\.id))
        #expect(unread.title == "Codex default")
        // Another family never takes a Codex list.
        let claude = ModelPickerData(kind: .claude, model: "", openRouterDefault: "", native: catalog)
        #expect(!claude.choices.contains { $0.id == "gpt-6.1-terra" })
    }

    @Test func effortsFollowTheListedModel() {
        let catalog = [ModelOption(id: "gpt-small", name: "Small", efforts: [.low, .medium]),
                       ModelOption(id: "gpt-6-luna", name: "GPT-6-Luna", efforts: [.low, .medium, .high, .xhigh, .max, .ultra])]
        #expect(GenerationOptions.efforts(for: .codex, model: "gpt-small", catalog: catalog) == [.low, .medium])
        #expect(GenerationOptions.efforts(for: .codex, model: "gpt-6-luna", catalog: catalog).contains(.ultra))
        #expect(!GenerationOptions.efforts(for: .codex, model: "gpt-6-luna").contains(.ultra))
        #expect(GenerationOptions.efforts(for: .codex, model: "unlisted", catalog: catalog) == GenerationOptions.efforts(for: .codex, model: "unlisted"))
        #expect(GenerationOptions.efforts(for: .claude, model: "opus", catalog: catalog) == GenerationOptions.efforts(for: .claude, model: "opus"))
        #expect(GenerationOptions.label(for: "gpt-small", kind: .codex, catalog: catalog).title == "Small")

        // Choosing a model drops an effort it doesn't list, by the list; a session stays.
        var bot = Bot(name: "B", accountID: "codex-work", model: "gpt-6-astra", reasoningEffort: .high, workspace: "/tmp/b",
                      sessionID: "s", sessionAccountID: "codex-work")
        bot.selectModel("gpt-small", catalog: catalog)
        #expect(bot.model == "gpt-small" && bot.reasoningEffort == nil && bot.resumableSessionID == "s")
        bot.reasoningEffort = .ultra
        bot.selectModel("gpt-6-luna", catalog: catalog)
        #expect(bot.reasoningEffort == .ultra)
    }

    @Test func listsAreKeptPerProfileAndCommand() {
        let work = ModelCatalogScope(accountID: "codex-work", command: "~/.local/bin/codex-work")
        let dev = ModelCatalogScope(accountID: "codex-dev", command: "~/.local/bin/codex-dev")
        let changed = ModelCatalogScope(accountID: "codex-work", command: "codex --profile other")
        var book = NativeCatalogBook()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let token = book.begin(work, now: now)!
        let recorded = book.finish(work, token: token, .success([ModelOption(id: "w", name: "W", efforts: [])]), now: now)
        #expect(recorded)
        #expect(book.models(for: work)?.map(\.id) == ["w"])
        #expect(book.models(for: dev) == nil)
        // Another command for the same profile is another list, unread until checked.
        #expect(book.models(for: changed) == nil)
        #expect(book.isDue(changed, now: now) && !book.isDue(work, now: now))
        // Nothing in the saved keys names the command.
        #expect(!book.saved.keys.contains { $0.contains("codex") })
    }

    @Test func checksAreDueDailyCoalesceAndBackOffAfterFailures() {
        let scope = ModelCatalogScope(accountID: "codex-work", command: "codex-work")
        var book = NativeCatalogBook()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let first = book.begin(scope, now: now)!
        // One check at a time, even when forced.
        let again = book.begin(scope, now: now), forcedAgain = book.begin(scope, now: now, force: true)
        #expect(again == nil && forcedAgain == nil)
        #expect(book.status(for: scope).checking)
        let listed = [ModelOption(id: "a", name: "A", efforts: [.low])]
        book.finish(scope, token: first, .success(listed), now: now)
        #expect(book.status(for: scope) == NativeCatalogStatus(checkedAt: now))

        // Fresh for a day; Refresh models checks anyway.
        now += NativeCatalogBook.staleAfter - 1
        let fresh = book.begin(scope, now: now)
        #expect(fresh == nil)
        let forced = book.begin(scope, now: now, force: true)!
        book.finish(scope, token: forced, .failure(CodexModelFailure("timed out")), now: now)
        // A failure keeps the last list and says so.
        #expect(book.models(for: scope) == listed)
        #expect(book.status(for: scope).failure == "timed out")
        #expect(book.status(for: scope).checkedAt == now - (NativeCatalogBook.staleAfter - 1))

        // Stale now, but waiting a minute after one failure, two after two, at most an hour.
        now += 2
        #expect(!book.isDue(scope, now: now))
        #expect(book.isDue(scope, now: now + 60))
        let retry = book.begin(scope, now: now + 60)!
        book.finish(scope, token: retry, .failure(CodexModelFailure("again")), now: now + 60)
        #expect(!book.isDue(scope, now: now + 60 + 119) && book.isDue(scope, now: now + 60 + 120))
        #expect(NativeCatalogBook.retryDelay(after: 30) == 3_600)
        #expect(NativeCatalogBook.retryDelay(after: 0) == 0)

        // A success clears the failure and the wait.
        let success = book.begin(scope, now: now + 200, force: true)!
        book.finish(scope, token: success, .success(listed + listed.map { ModelOption(id: "b", name: $0.name, efforts: []) }), now: now + 200)
        #expect(book.status(for: scope) == NativeCatalogStatus(checkedAt: now + 200))
        #expect(book.models(for: scope)?.map(\.id) == ["a", "b"])
    }

    @Test func anAnswerForAProfileGoneOrRecheckedIsDropped() {
        let scope = ModelCatalogScope(accountID: "codex-work", command: "codex-work")
        var book = NativeCatalogBook()
        let token = book.begin(scope)!
        // The profile left Settings (or its command changed) while its check ran.
        book.retain([])
        let late = book.finish(scope, token: token, .success([ModelOption(id: "late", name: "Late", efforts: [])]))
        #expect(!late)
        #expect(book.models(for: scope) == nil)
        // A token that isn't the running check's records nothing either.
        let current = book.begin(scope)!
        let stranger = book.finish(scope, token: UUID(), .success([ModelOption(id: "x", name: "X", efforts: [])]))
        #expect(!stranger)
        #expect(book.status(for: scope).checking)
        let own = book.finish(scope, token: current, .success([ModelOption(id: "y", name: "Y", efforts: [])]))
        #expect(own)
    }

    @Test func savedListsRoundTripWithoutCommandsAndSurviveOddFiles() throws {
        let scope = ModelCatalogScope(accountID: "codex-work", command: "/Users/me/.local/bin/codex-work")
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = NativeCatalog(models: [ModelOption(id: "gpt-6.1-terra", name: "GPT-6.1 Terra", efforts: [.low, .ultra])], checkedAt: checkedAt)
        let data = try #require(NativeCatalogFile.encode([scope.key: catalog]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users") && !text.contains("codex-work"))
        let book = NativeCatalogBook(saved: NativeCatalogFile.decode(data))
        #expect(book.models(for: scope) == catalog.models)
        #expect(book.status(for: scope).checkedAt == checkedAt)
        #expect(!book.status(for: scope).checking && book.status(for: scope).failure == nil)

        // An effort a later BotChu saved is skipped; another version or a damaged file reads as none.
        let later = text.replacingOccurrences(of: #""ultra""#, with: #""hyper""#)
        #expect(NativeCatalogFile.decode(Data(later.utf8))[scope.key]?.models.first?.efforts == [.low])
        #expect(NativeCatalogFile.decode(Data(text.replacingOccurrences(of: #""version":1"#, with: #""version":2"#).utf8)).isEmpty)
        #expect(NativeCatalogFile.decode(Data("{".utf8)).isEmpty)

        // Whether a model has Fast is kept; a list saved before #249 offers it until read again.
        let slow = NativeCatalog(models: [ModelOption(id: "plain", name: "Plain", efforts: [])], checkedAt: checkedAt)
        let slowData = try #require(NativeCatalogFile.encode([scope.key: slow]))
        #expect(NativeCatalogFile.decode(slowData)[scope.key]?.models.first?.fast == false)
        // The same file without the key, whatever order the encoder wrote it in.
        var file = try #require(JSONSerialization.jsonObject(with: slowData) as? [String: Any])
        var catalogs = try #require(file["catalogs"] as? [[String: Any]])
        var models = try #require(catalogs[0]["models"] as? [[String: Any]])
        #expect(models[0].removeValue(forKey: "fast") != nil)
        catalogs[0]["models"] = models
        file["catalogs"] = catalogs
        let older = try JSONSerialization.data(withJSONObject: file)
        #expect(NativeCatalogFile.decode(older)[scope.key]?.models.first?.fast == true)
    }

    @Test func thePickerSaysHowTheListStands() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(NativeCatalogStatus().summary(at: now) == "Starter list · not checked yet")
        #expect(NativeCatalogStatus(checking: true).summary(at: now) == "Checking models…")
        #expect(NativeCatalogStatus(checkedAt: now - 3 * 3_600).summary(at: now) == "Checked 3h ago")
        #expect(NativeCatalogStatus(checkedAt: now - 30).summary(at: now) == "Checked just now")
        #expect(NativeCatalogStatus(checkedAt: now - 2 * 86_400, failure: "x").summary(at: now) == "Couldn’t check · list from 2d ago")
        #expect(NativeCatalogStatus(failure: "x").summary(at: now) == "Couldn’t check · starter list")
    }
}

/// `CodexModelList` against a stand-in `app-server` that logs what it was asked.
@Suite struct CodexModelListTests {
    private func withServer(_ answers: String, _ body: (_ command: String, _ log: URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("methods.log")
        let script = directory.appendingPathComponent("server.py")
        try #"""
        import json, sys
        answers = json.loads(sys.argv[1])
        log = open(sys.argv[2], "a")
        log.write("args " + " ".join(sys.argv[3:]) + "\n"); log.flush()
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            log.write(method + " " + json.dumps(request.get("params", {}), sort_keys=True) + "\n"); log.flush()
            if "id" not in request: continue
            key = method + ("#" + request["params"]["cursor"] if request.get("params", {}).get("cursor") else "")
            answer = answers.get(key, {"error": {"code": -32601, "message": "unknown method"}})
            if answer == "hang": continue
            print(json.dumps({"method": "remoteControl/status/changed", "params": {}}))
            print(json.dumps(dict(answer, id=request["id"], jsonrpc="2.0")), flush=True)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let answersFile = directory.appendingPathComponent("answers.json")
        try answers.write(to: answersFile, atomically: true, encoding: .utf8)
        try await body("/usr/bin/python3 -I \(script.path) \"$(cat \(answersFile.path))\" \(log.path)", log)
    }

    private func methods(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test func readsEveryPageThroughTheProfilesCommandAndNothingElse() async throws {
        try await withServer(#"""
        {"initialize": {"result": {}},
         "model/list": {"result": {"data": [{"model": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "hidden": false}], "nextCursor": "p2"}},
         "model/list#p2": {"result": {"data": [{"model": "gpt-6.1-terra", "displayName": "GPT-6.1 Terra", "hidden": false},
                                               {"model": "gpt-reserve", "hidden": true}], "nextCursor": null}}}
        """#) { command, log in
            let models = try await CodexModelList.list(command: command, timeout: 10)
            #expect(models.map(\.id) == ["gpt-6.1-sol", "gpt-6.1-terra"])
            // Read-only: no thread, turn or tool call; each page asked for in turn; run as app-server.
            let asked = methods(log)
            #expect(asked.first == "args app-server")
            #expect(asked.dropFirst().map { String($0.split(separator: " ")[0]) } == ["initialize", "initialized", "model/list", "model/list"])
            #expect(asked[3] == "model/list {}")
            #expect(asked[4].contains(#""cursor": "p2""#))
        }
    }

    @Test func anIncompleteListIsntUsed() async throws {
        // Every page points at another: after the most BotChu reads, nothing is taken as the list.
        try await withServer(#"""
        {"initialize": {"result": {}}, "model/list": {"result": {"data": [{"model": "a"}], "nextCursor": "p"}},
         "model/list#p": {"result": {"data": [{"model": "b"}], "nextCursor": "p"}}}
        """#) { command, log in
            await #expect(throws: CodexModelFailure("Codex listed more models than BotChu reads.")) {
                _ = try await CodexModelList.list(command: command, timeout: 10)
            }
            #expect(methods(log).filter { $0.hasPrefix("model/list") }.count == CodexModelList.pageLimit)
        }
        // A later page that fails loses the earlier ones too.
        try await withServer(#"""
        {"initialize": {"result": {}}, "model/list": {"result": {"data": [{"model": "a"}], "nextCursor": "p"}},
         "model/list#p": {"error": {"code": -32000, "message": "token sk-private"}}}
        """#) { command, _ in
            do {
                _ = try await CodexModelList.list(command: command, timeout: 10)
                Issue.record("Expected a failure")
            } catch let failure as CodexModelFailure {
                #expect(failure == .failed && !failure.message.contains("private"))
            }
        }
    }

    @Test func anOlderCodexAndOneThatNeverAnswersFailPlainly() async throws {
        try await withServer(#"{"initialize": {"result": {}}}"#) { command, _ in
            await #expect(throws: CodexModelFailure.unsupported) { _ = try await CodexModelList.list(command: command, timeout: 10) }
        }
        try await withServer(#"{"initialize": {"result": {}}, "model/list": "hang"}"#) { command, _ in
            let started = Date()
            await #expect(throws: CodexModelFailure("Codex didn’t list its models within 2 seconds.")) {
                _ = try await CodexModelList.list(command: command, timeout: 2)
            }
            #expect(Date().timeIntervalSince(started) < 8)
        }
    }
}

@Suite struct QuickTaskModelTests {
    @Test func quickTasksOfferTheProfilesListAndKeepTheirChoice() {
        let catalog = [ModelOption(id: "gpt-6.1-terra", name: "GPT-6.1 Terra", efforts: [.low])]
        #expect(QuickTasks.models(for: .codex, catalog: catalog, chosen: "gpt-6.1-terra").map(\.id) == ["gpt-6.1-terra"])
        // The suggested model stays chosen and offered even when the list leaves it out.
        #expect(QuickTasks.models(for: .codex, catalog: catalog, chosen: "gpt-6-luna").map(\.id) == ["gpt-6.1-terra", "gpt-6-luna"])
        #expect(QuickTasks.models(for: .codex, catalog: nil, chosen: "").map(\.id) == GenerationOptions.models(for: .codex).map(\.id))
        #expect(QuickTasks.models(for: .claude, catalog: catalog, chosen: "haiku").map(\.id) == GenerationOptions.models(for: .claude).map(\.id))
    }
}
