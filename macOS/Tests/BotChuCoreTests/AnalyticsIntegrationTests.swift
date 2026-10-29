import Foundation
import Testing
@testable import BotChuCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Epic #295: exercise the persisted capture → billing → snapshot → page boundary together.
@Suite @MainActor struct AnalyticsIntegrationTests {
    private struct Day {
        var snapshot: AnalyticsSnapshot
        var ledger: UsageLedger.ReadResult
        var privateValues: [String]
    }

    private func mixedDay() async throws -> Day {
        var folder = try AnalyticsTests.Folder()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let (bot, home) = try folder.add("Mixed day", accountID: "codex-work")
        let (delegate, _) = try folder.add("Delegate", accountID: "claude-personal")
        let queue = StorageQueue()
        let base = AnalyticsTests.at("2026-10-28T12:00:00Z")
        let session = UUID().uuidString
        let secret = "PLANTED-PRIVATE-CONTENT-295"
        let prompts = (0..<12).map { ChatMessage(role: .user, text: secret, date: base.addingTimeInterval(Double($0 * 100))) }
        func pair(_ i: Int) -> [ChatMessage] {
            [prompts[i], ChatMessage(role: .assistant, text: secret, date: prompts[i].date.addingTimeInterval(10))]
        }
        try home.saveThread((0..<9).flatMap(pair))
        func entry(_ i: Int, _ provider: AgentKind, _ model: String, kind: UsageLedger.Kind = .home) -> UsageLedger.Entry {
            UsageLedger.Entry(at: prompts[i].date.addingTimeInterval(10), startedAt: prompts[i].date,
                              kind: kind, botID: bot.id, messageID: prompts[i].id,
                              accountID: provider == .claude ? "claude-personal" : provider == .codex ? "codex-work" : provider.rawValue,
                              provider: provider, model: model, modelSource: .requested, outcome: .finished)
        }
        func capture(_ entry: UsageLedger.Entry, _ usage: TurnUsage) {
            let capture = UsageLedger.Capture(entry)
            capture.record(.textDelta(secret))
            capture.record(.usage(usage))
            capture.finish(.finished, at: entry.at, in: home, queue: queue)
            capture.finish(.finished, at: entry.at, in: home, queue: queue)
        }
        var claude = entry(0, .claude, "claude-haiku-5-5")
        claude.messageIDs.append(prompts[1].id)
        // Prompt identity survives queue delay and live follow-ups; capture owns usage once.
        claude.startedAt = claude.startedAt.addingTimeInterval(20)
        capture(claude, TurnUsage(models: [.init(model: claude.model!, uncachedInput: 100, cacheRead: 200,
                                               cacheWrite: 10, cacheWrite1h: 5, output: 20, reasoning: 3)]))
        for (i, counts) in [(2, [1_000, 2_000, 100, 20]), (3, [1_050, 2_100, 110, 22]), (4, [1_120, 2_250, 130, 26])] {
            var codex = entry(i, .codex, "gpt-6-astra")
            codex.sessionID = session; codex.resumed = true
            capture(codex, TurnUsage(models: [.init(model: "", uncachedInput: counts[0], cacheRead: counts[1],
                                                  output: counts[2], reasoning: counts[3])], cumulative: true))
        }
        var pi = entry(5, .pi, "deepseek/deepseek-v4.1-flash-1017")
        pi.providerID = "openrouter"; pi.usesLegacyOpenRouterKey = true
        capture(pi, TurnUsage(models: [.init(model: pi.model!, uncachedInput: 30, cacheRead: 20, output: 5)],
                              reportedCostUSD: 0.009, generationIDs: ["gen-fixture-a", "gen-fixture-b"]))
        capture(entry(6, .sail, "deepseek-ai/DeepSeek-V4.1-Flash-1017"),
                TurnUsage(models: [.init(model: "deepseek-ai/DeepSeek-V4.1-Flash-1017", uncachedInput: 40, cacheRead: 30, output: 10)]))
        capture(entry(7, .claude, "unlisted-model"), TurnUsage(models: [.init(model: "unlisted-model", uncachedInput: 7, output: 3)]))
        // Prompt 8 predates capture and must stay unavailable.
        let task = BotTask(title: secret, repo: "owner/project", checkout: folder.root.path, brief: secret,
                           accountID: "codex-work", createdAt: prompts[9].date)
        try home.save(task); try home.saveThread(pair(9), task: task.id)
        var taskEntry = entry(9, .claude, "claude-haiku-5-5", kind: .task)
        taskEntry.taskID = task.id
        capture(taskEntry, TurnUsage(models: [.init(model: taskEntry.model!, uncachedInput: 60, output: 20)]))
        var job = Job(botID: bot.id, title: secret, prompt: secret, schedule: JobSchedule(timeZone: "UTC"))
        var run = JobRun(trigger: .scheduled, scheduledFor: prompts[10].date, timeZone: "UTC",
                         reservedAt: prompts[10].date, outcome: .succeeded)
        run.startedAt = prompts[10].date; run.finishedAt = prompts[10].date.addingTimeInterval(10)
        run.accountID = "codex-work"
        let runTask = JobTasks.task(for: bot, job: job, run: run, startedAt: prompts[10].date)
        run.taskID = runTask.id; job.runs = [run]
        try home.save(job); try home.save(runTask); try home.saveThread(pair(10), task: runTask.id)
        var jobEntry = entry(10, .claude, "claude-haiku-5-5", kind: .job)
        jobEntry.jobRunID = run.id; jobEntry.taskID = runTask.id
        capture(jobEntry, TurnUsage(models: [.init(model: jobEntry.model!, uncachedInput: 70, output: 30)]))
        var subagent = SubagentRun(rootBotID: bot.id, rootTaskID: task.id, depth: 1, targetBot: delegate,
                                  title: secret, brief: secret, workingDirectory: folder.root.path,
                                  phase: .completed, createdAt: prompts[11].date)
        subagent.startedAt = prompts[11].date; subagent.finishedAt = prompts[11].date.addingTimeInterval(10)
        try home.saveSubagent(subagent)
        var subEntry = entry(11, .claude, "claude-haiku-5-5", kind: .subagent)
        subEntry.botID = delegate.id; subEntry.subagentRunID = subagent.id; subEntry.taskID = task.id
        capture(subEntry, TurnUsage(models: [.init(model: subEntry.model!, uncachedInput: 80, output: 40)]))
        await queue.settle()
        let beforeBilling = Analytics.collect(.init(root: folder.root, now: base, zone: TimeZone(secondsFromGMT: 0)!))
        #expect(beforeBilling.records.first { $0.provider == .pi }?.costProvenance == .estimated)
        let savedPi = try #require(UsageLedger.read(in: home).entries.first { $0.id == pi.id })
        let candidate = try #require(OpenRouterCostLedger.candidate(savedPi, ownerBotID: bot.id, at: pi.at.addingTimeInterval(60)))
        let client = OpenRouterCost(http: { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
            let cost = id == "gen-fixture-a" ? 0.0012 : 0.0003
            let data = try JSONSerialization.data(withJSONObject: ["data": ["id": id, "total_cost": cost, "private": secret]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        var bill = 0.0
        for id in candidate.generationIDs {
            guard case .billed(let cost) = await client.read(generationID: id, key: secret) else {
                Issue.record("Fixture billing failed"); continue
            }
            bill += cost
        }
        #expect(await OpenRouterCostLedger.amend(candidate, cost: bill, in: home, at: base, queue: queue))
        #expect(await OpenRouterCostLedger.amend(candidate, cost: bill, in: home, at: base, queue: queue))
        // A repeated durable entry and a torn line cannot inflate or erase neighboring totals.
        UsageLedger.append(savedPi, in: home, queue: queue)
        await queue.settle()
        let file = UsageLedger.directory(in: home).appendingPathComponent("2026-10.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("damaged-line\n".utf8)); try handle.close()
        let before = folder.files()
        let snapshot = Analytics.collect(.init(root: folder.root, now: base, zone: TimeZone(secondsFromGMT: 0)!))
        #expect(folder.files() == before)
        #expect(try !String(contentsOf: file, encoding: .utf8).contains(secret))
        return Day(snapshot: snapshot, ledger: try UsageLedger.read(in: home),
                   privateValues: [secret, session.lowercased(), folder.root.path, prompts[0].id.uuidString, "gen-fixture-a", "gen-fixture-b"])
    }

    @Test func mixedDayLedgerBillingAndSnapshotAgreeWithoutDoubleCounting() async throws {
        let fixture = try await mixedDay(), snapshot = fixture.snapshot
        let summary = AnalyticsSummary(snapshot.records, from: snapshot.today, through: snapshot.today, tasks: snapshot.tasks)
        #expect(fixture.ledger.entries.count == 10 && fixture.ledger.amendments.count == 1)
        #expect(snapshot.records.count == 12 && summary.runs == 12)
        #expect(snapshot.records.filter { $0.kind == .job }.count == 1)
        #expect(snapshot.records.filter { $0.kind == .subagent }.count == 1)
        #expect(summary.tokens.uncachedInput == 507 && summary.tokens.cacheRead == 500)
        #expect(summary.tokens.cacheWrite == 10 && summary.tokens.cacheWrite1h == 5)
        #expect(summary.tokens.output == 158 && summary.tokens.reasoning == 9 && summary.tokens.total == 1_175)
        #expect(abs((summary.cacheHitRate ?? -1) - 500.0 / 1_017) < 1e-12)
        #expect(summary.unpriced == 1 && summary.unavailable == 3)
        #expect(summary.costProvenance == .estimated && abs((summary.actualCost ?? -1) - 0.0015) < 1e-12)
        // Independent arithmetic from the bundled rates: two Codex deltas, Haiku, Sail, and three runs.
        let estimated = 0.000023625 + 0.0011 + 0.00185 + 0.00000362 + 0.000016 + 0.000022 + 0.000028
        #expect(abs((summary.estimatedCost ?? -1) - estimated) < 1e-12)
        #expect(abs((summary.cost ?? -1) - (estimated + 0.0015)) < 1e-12)
        #expect(summary.finishedTasks == 1 && abs((summary.costPerFinishedTask ?? -1) - 0.000044) < 1e-12)
        let codex = snapshot.records.filter { $0.provider == .codex }
        #expect(codex.map { $0.tokens.uncachedInput } == [nil, 50, 70])
        #expect(codex.allSatisfy { snapshot.accounts[$0.account!].name == "Codex Work" && $0.model == "gpt-6-astra" })
        #expect(snapshot.records.filter { $0.provider == .claude }.allSatisfy { snapshot.accounts[$0.account!].name == "Claude Personal" })
        #expect(snapshot.records.first { $0.provider == .pi }?.providerID == "openrouter")
        #expect(snapshot.unpricedModelIDs == ["unlisted-model"] && snapshot.coverage.unreadableUsageLines == 1)
        let page = try AnalyticsDashboard.html(for: snapshot), json = String(decoding: try snapshot.encoded(), as: UTF8.self)
        for privateValue in fixture.privateValues {
            #expect(!page.contains(privateValue)); #expect(!json.contains(privateValue))
        }
        #expect(page.contains("default-src 'none'") && !page.contains("connect-src") && !page.contains("fetch("))
    }

    #if canImport(JavaScriptCore)
    @Test func persistedMixedDayMatchesEveryExplorerGroupingAndCardFilter() async throws {
        let snapshot = try await mixedDay().snapshot
        let context = try #require(JSContext())
        context.evaluateScript(AnalyticsDashboard.script)
        context.setObject(try JSONSerialization.jsonObject(with: snapshot.encoded()), forKeyedSubscript: "fixture" as NSString)
        context.evaluateScript("var E=BotChuAnalytics.createExplorer(fixture), rows=E.range(fixture.today,fixture.today)")
        #expect(context.exception == nil)
        let summary = AnalyticsSummary(snapshot.records, from: snapshot.today, through: snapshot.today, tasks: snapshot.tasks)
        #expect(abs(context.evaluateScript("E.aggregate(rows).cost").toDouble() - (summary.cost ?? -1)) < 1e-12)
        #expect(context.evaluateScript("E.aggregate(rows).totalTokens").toInt32() == 1_175)
        for dimension in ["bot", "project", "model", "provider", "account", "kind"] {
            context.setObject(dimension, forKeyedSubscript: "dimension" as NSString)
            #expect(context.evaluateScript("E.groups(rows,dimension,'cost',-1).reduce((n,g)=>n+g.summary.runs,0)").toInt32() == 12)
            #expect(abs(context.evaluateScript("E.groups(rows,dimension,'cost',-1).reduce((n,g)=>n+(g.summary.cost||0),0)").toDouble() - (summary.cost ?? -1)) < 1e-12)
        }
        #expect(context.evaluateScript("E.insights(fixture.today,fixture.today).every(c=>{let v=E.metric(rows.filter(r=>E.matches(r,c.filters)),c.spec);return c.value==null?v==null:Math.abs(v-c.value)<1e-12})").toBool() == true)
        #expect(context.evaluateScript("E.aggregate(rows.filter(r=>E.matches(r,[{k:'price',v:'unpriced'}]))).cost===null").toBool() == true)
        #expect(abs(context.evaluateScript("E.aggregate(rows.filter(r=>E.matches(r,[{k:'price',v:'actual'}]))).cost").toDouble() - 0.0015) < 1e-12)
        #expect(context.evaluateScript("E.aggregate(rows.filter(r=>E.matches(r,[{k:'kind',v:'task'},{k:'kind',v:'subagent'},{k:'provider',v:'claude'}]))).totalTokens").toInt32() == 200)
        #expect(context.exception == nil)
    }
    #endif
}
