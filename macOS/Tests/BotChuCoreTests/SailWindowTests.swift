import Foundation
import Testing
@testable import BotChuCore

@Suite struct SailWindowTests {
    @Test(arguments: SailCompletionWindow.allCases)
    func selectionPersistsAndReachesHelper(_ window: SailCompletionWindow) throws {
        var bot = Bot(name: "Sail", accountID: "sail", workspace: "/tmp/sail-window")
        #expect(bot.effectiveSailCompletionWindow == .flex)
        bot.sailCompletionWindow = window
        let restored = try JSONDecoder().decode(Bot.self, from: JSONEncoder().encode(bot))
        #expect(restored.effectiveSailCompletionWindow == window)
        let task = BotTask(for: restored, repo: "test/repo", checkout: "/tmp", work: nil, brief: "Check")
        #expect(task.effectiveSailCompletionWindow == window)
        let jobChoice = try JSONDecoder().decode(JobRunsOn.self, from: JSONEncoder().encode(JobRunsOn(restored)))
        #expect(jobChoice.applied(to: bot).effectiveSailCompletionWindow == window)
        let invocation = CommandBuilder.invocation(kind: .sail, prompt: "Hi", model: SailSamples.model,
            sessionID: nil, sailCompletionWindow: window)
        #expect(try SailCommand.parse(invocation.arguments).completionWindow == window)
        bot.selectAccount(Accounts.account(id: "codex"))
        #expect(bot.sailCompletionWindow == nil)
    }

    @Test func oldSavesKeepFlexAndBadCLIChoiceFails() throws {
        let bot = Bot(name: "Old", accountID: "sail", workspace: "/tmp/old")
        let data = try JSONEncoder().encode(bot)
        #expect(!String(decoding: data, as: UTF8.self).contains("sailCompletionWindow"))
        #expect(try JSONDecoder().decode(Bot.self, from: data).effectiveSailCompletionWindow == .flex)
        #expect(throws: SailFailure.self) { try SailCommand.parse(["--completion-window", "priority", "Hi"]) }
        #expect(try SailCommand.parse(["Hi"]).completionWindow == .flex)
    }

    @Test(arguments: SailCompletionWindow.allCases)
    func submissionAndUsageUseChosenWindow(_ window: SailCompletionWindow) async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let fixture = SailFixture([("POST", "/v1/responses", .ok(SailSamples.response("r", "completed",
            output: "[\(SailSamples.message("Done."))]", extra: SailSamples.usage)))])
        #expect(await harness.run(fixture, .init(sessionID: "windows", resume: false, model: SailSamples.model,
            completionWindow: window, prompt: "Hi")))
        let body = try #require(fixture.bodies.first)
        #expect(body["background"] == .bool(window != .asap))
        #expect(body["metadata"]?["completion_window"] == .string(window.rawValue))
        #expect(fixture.requests.count == 1, "A completed foreground response needs no polling")
        let usage = try #require(harness.events.all.compactMap { if case .usage(let value) = $0 { value } else { nil } }.first)
        #expect(usage.models.first?.sailCompletionWindow == window)
        #expect(SailEvent(line: SailEvent.usage(usage).line) == .usage(usage))
    }

    @Test func pendingRequestRetainsItsWindowWhenTheNextTurnChangesIt() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        let body = SailRequest.body(model: SailSamples.model, instructions: "", input: [], tools: [], effort: nil,
                                    completionWindow: .balanced)
        try harness.store.save(SailSession(id: "resume", pending: SailPending(idempotencyKey: "old-key", body: body,
            model: SailSamples.model, submittedAt: SailSamples.start)))
        let fixture = SailFixture([("POST", "/v1/responses", .ok(SailSamples.response("old", "completed",
                output: "[\(SailSamples.message("Earlier answer."))]", extra: SailSamples.usage))),
            ("POST", "/v1/responses", .ok(SailSamples.response("new", "completed",
                output: "[\(SailSamples.message("New answer."))]", extra: SailSamples.usage)))])
        #expect(await harness.run(fixture, .init(sessionID: "resume", resume: true, model: SailSamples.model,
                                                completionWindow: .asap, prompt: "Again")))
        #expect(fixture.bodies.map(SailCompletionWindow.from) == [.balanced, .asap])
        #expect(fixture.requests.first?.value(forHTTPHeaderField: "Idempotency-Key") == "old-key")
        let usage = try #require(harness.events.all.compactMap { if case .usage(let value) = $0 { value } else { nil } }.first)
        #expect(usage.models.map(\.sailCompletionWindow) == [.balanced, .asap])
        #expect(usage.models.map(\.uncachedInput) == [1200, 1200])
    }

    @Test func eachWindowUsesItsOwnPricesAndUnknownRatesStayUnknown() throws {
        let model = "deepseek-ai/DeepSeek-V4.1-Flash-1017"
        for (window, expected) in [(SailCompletionWindow.asap, 0.396), (.balanced, 0.295), (.flex, 0.204)] {
            let usage = ModelUsage(model: model, uncachedInput: 1_000_000, cacheRead: 1_000_000,
                                   output: 1_000_000, sailCompletionWindow: window)
            #expect(abs(try #require(ModelPricing.price(usage, provider: .sail)).usd - expected) < 1e-12)
        }
        #expect(ModelPricing.price(ModelUsage(model: "Qwen/Qwen3.6-35B-A3B", output: 100,
            sailCompletionWindow: .asap), provider: .sail) == nil)
    }

    /// Normalized usage captured from a real resumed ASAP smoke turn on 2026-10-29.
    @Test func capturedASAPUsageKeepsItsWindowInTheParser() throws {
        let captured = #"{"cumulative":false,"generationIDs":[],"models":[{"cacheRead":4864,"model":"deepseek-ai\/DeepSeek-V4.1-Flash-1017","output":6,"reasoning":1,"sailCompletionWindow":"asap","uncachedInput":70}]}"#
        let usage = try JSONDecoder().decode(TurnUsage.self, from: Data(captured.utf8))
        #expect(usage.models.first?.sailCompletionWindow == .asap)
        #expect(usage.models.first?.uncachedInput == 70)
        #expect(usage.models.first?.cacheRead == 4864)
        var parser = SailParser()
        #expect(parser.parse(line: "{\"type\":\"usage\",\"usage\":" + captured + "}") == [.usage(usage)])
    }

    @Test func concurrentShortToolsKeepTheirOutput() async throws {
        let harness = try SailHarness()
        defer { harness.remove() }
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let result = await SailCommandRunner.run(shell: "/bin/sh", command: "printf output-\(index)",
                        directory: harness.work, environment: ["PATH": "/usr/bin:/bin"], timeout: 30, live: nil)
                    return result.output == "output-\(index)" && result.status == 0 && !result.timedOut
                }
            }
            for await kept in group { #expect(kept) }
        }
    }

    @Test func refusalNamesTheChosenWindow() {
        let failure = SailHTTP.submissionFailure(status: 400, data: Data(#"{"error":{"message":"Unsupported completion_window"}}"#.utf8),
                                                 model: "model", completionWindow: .asap)
        #expect(failure.message.contains("on ASAP"))
        #expect(!failure.message.contains("on Flex"))
    }
}
