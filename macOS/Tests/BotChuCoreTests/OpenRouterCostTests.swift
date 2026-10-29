import Foundation
import Testing
@testable import BotChuCore

@Suite struct OpenRouterCostTests {
    @Test func sumsEveryGenerationOnlyAfterDelayAndAtOneRequestPerSecond() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.isEmpty)
        fixture.advance(59)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.isEmpty)
        fixture.advance(1)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 1)
        #expect(fixture.amendments.isEmpty)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 1)
        fixture.advance(1)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 2)
        #expect(abs((fixture.amendments.first ?? 0) - 0.0015) < 1e-12)
        fixture.advance(1)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.amendments.count == 1)
        #expect(fixture.requests.allSatisfy { $0.url?.host == "openrouter.ai" && $0.httpMethod == "GET" })
    }

    @Test func streamingDefersCredentialsRequestsAndWholeTurnAmendment() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.advance(60)
        fixture.active = true
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.isEmpty && fixture.credentialReads == 0)
        fixture.active = false
        fixture.startDuringCredentialRead = true
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.isEmpty)
        fixture.startDuringCredentialRead = false
        fixture.active = false
        await scheduler.tick([fixture.candidate])
        fixture.advance(1)
        fixture.startDuringResponse = true
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 2 && fixture.amendments.isEmpty)
        fixture.active = false
        await scheduler.tick([fixture.candidate])
        #expect(fixture.amendments.count == 1)
    }

    @Test(arguments: [404, 429, 500, -1]) func transientFailuresKeepEstimateAndRetryLater(status: Int) async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.advance(60)
        fixture.status = status
        await scheduler.tick([fixture.candidate])
        #expect(fixture.amendments.isEmpty)
        fixture.status = 200
        fixture.advance(299)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 1)
        fixture.advance(1)
        await scheduler.tick([fixture.candidate])
        fixture.advance(1)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 3 && fixture.amendments.count == 1)
    }

    @Test func unauthorizedStopsOnlyThatAccountUntilExplicitReset() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.advance(60)
        fixture.status = 401
        await scheduler.tick([fixture.candidate])
        fixture.status = 200
        fixture.advance(600)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 1)
        var other = fixture.candidate
        other.id = UUID(); other.accountID = "other"
        await scheduler.tick([fixture.candidate, other])
        #expect(fixture.requests.count == 2)
        await scheduler.reset(accountID: fixture.candidate.accountID)
        fixture.advance(1)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 3)
    }

    @Test func parsedTurnWithOneMissingIDNeverBecomesPartlyActual() async throws {
        var parser = PiParser()
        _ = parser.parse(line: TokenUsageSamples.pi[0])
        _ = parser.parse(line: #"{"type":"message_end","message":{"role":"assistant","stopReason":"stop"}}"#)
        let events = parser.parse(line: #"{"type":"agent_end"}"#)
        let usage = try #require(events.compactMap { if case .usage(let value) = $0 { value } else { nil } }.first)
        let fixture = Fixture()
        var candidate = fixture.candidate
        candidate.generationIDs = usage.generationIDs
        fixture.advance(60)
        await fixture.scheduler().tick([candidate])
        #expect(fixture.requests.isEmpty && fixture.credentialReads == 0 && fixture.amendments.isEmpty)
    }

    @Test func expiredIncompleteAndUnsupportedIDsNeverReadCredentials() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.advance(60)
        for ids in [[], ["gen-a", "msg_bdrk_123"], ["gen-a", "unrecorded"], ["gen-a", ""], ["gen-../secret"]] {
            var candidate = fixture.candidate
            candidate.generationIDs = ids
            await scheduler.tick([candidate])
        }
        fixture.advance(86_400)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.isEmpty && fixture.credentialReads == 0)
    }

    @Test func missingCredentialStaysEstimateAndRetriesAfterItChanges() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.advance(60)
        fixture.keyAvailable = false
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.isEmpty && fixture.amendments.isEmpty)
        fixture.keyAvailable = true
        fixture.advance(300)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 1)
    }

    @Test func missingCredentialBacksOffAcrossTheWholeAccount() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.advance(60)
        fixture.keyAvailable = false
        var second = fixture.candidate
        second.id = UUID()
        await scheduler.tick([fixture.candidate, second])
        fixture.advance(1)
        await scheduler.tick([fixture.candidate, second])
        #expect(fixture.credentialReads == 1)
        fixture.keyAvailable = true
        await scheduler.reset(accountID: fixture.candidate.accountID)
        await scheduler.tick([fixture.candidate, second])
        #expect(fixture.requests.count == 1)
    }

    @Test func partialSuccessIsKeptWithoutAmendingOrDoubleCounting() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.advance(60)
        await scheduler.tick([fixture.candidate])
        fixture.advance(1)
        fixture.status = 404
        await scheduler.tick([fixture.candidate])
        #expect(fixture.amendments.isEmpty)
        fixture.status = 200
        fixture.advance(300)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems![0].value! } == ["gen-a", "gen-b", "gen-b"])
        #expect(abs((fixture.amendments.first ?? 0) - 0.0015) < 1e-12)
    }

    @Test func failedAmendmentRetriesWithoutAnotherPaidLookup() async {
        let fixture = Fixture()
        let scheduler = fixture.scheduler()
        fixture.writeSucceeds = false
        fixture.advance(60)
        await scheduler.tick([fixture.candidate])
        fixture.advance(1)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 2 && fixture.amendments.isEmpty)
        fixture.writeSucceeds = true
        fixture.advance(300)
        await scheduler.tick([fixture.candidate])
        #expect(fixture.requests.count == 2 && fixture.amendments.count == 1)
    }

    @Test func decoderRejectsWrongIDMissingNegativeBooleanAndNonNumericCosts() async {
        for body in [#"{"data":{"id":"gen-other","total_cost":1}}"#,
                     #"{"data":{"id":"gen-a"}}"#,
                     #"{"data":{"id":"gen-a","total_cost":-1}}"#,
                     #"{"data":{"id":"gen-a","total_cost":true}}"#,
                     #"{"data":{"id":"gen-a","total_cost":"0.1"}}"#] {
            let client = OpenRouterCost { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            #expect(await client.read(generationID: "gen-a", key: "planted-private-key") == .retry(after: 300))
        }
    }

    @Test func secretResponseAndTransportErrorNeverEscapeClient() async {
        let secret = "planted-private-key"
        let client = OpenRouterCost { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)")
            return (Data("{\"error\":\"\(secret)\"}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "700"])!)
        }
        let result = await client.read(generationID: "gen-a", key: secret)
        #expect(result == .retry(after: 700))
        #expect(!String(describing: result).contains(secret))
        let offline = OpenRouterCost { _ in throw NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret]) }
        #expect(await offline.read(generationID: "gen-a", key: secret) == .retry(after: 300))
    }

    @Test func ledgerReconciliationAppendsOneWholeBillAndKeepsSecretsOutOfArtifacts() async throws {
        let fixture = Fixture(), queue = StorageQueue(qos: .utility)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = BotHome(workspace: root.appendingPathComponent("bot").path)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(id: fixture.candidate.accountID, name: "OpenRouter", kind: .pi,
            defaultCommand: "pi", symbol: "", credentialOwnership: .legacyOpenRouter)
        let bot = Bot(id: fixture.candidate.ownerBotID, name: "Owner", accountID: account.id, workspace: home.url.deletingLastPathComponent().path)
        try home.save(bot)
        try Store(root: root).saveIndex([Store.Entry(id: bot.id, workspace: bot.workspace)])
        let entry = UsageLedger.Entry(id: fixture.candidate.id, at: fixture.now(), startedAt: fixture.now().addingTimeInterval(-10),
            kind: .subagent, botID: fixture.candidate.botID, accountID: account.id, provider: .pi, providerID: "openrouter",
            usesLegacyOpenRouterKey: true, outcome: .finished,
            usage: TurnUsage(models: [], reportedCostUSD: 0.002, generationIDs: ["gen-a", "gen-b"]))
        UsageLedger.append(entry, in: home, queue: queue)
        fixture.advance(60)
        let candidates = await OpenRouterCostLedger.pending(in: home, ownerBotID: bot.id, accounts: [account], at: fixture.now(), queue: queue)
        #expect(candidates == [fixture.candidate])
        let scheduler = fixture.scheduler { candidate, amount in
            await OpenRouterCostLedger.amend(candidate, cost: amount, in: home, at: fixture.now(), queue: queue)
        }
        await scheduler.tick(candidates)
        #expect(try UsageLedger.read(in: home).amendments.isEmpty)
        fixture.advance(1)
        await scheduler.tick(candidates)
        let ledger = try UsageLedger.read(in: home)
        #expect(ledger.amendments.count == 1)
        #expect(ledger.amendments.first?.amends == entry.id)
        #expect(abs((ledger.amendments.first?.actualCostUSD ?? 0) - 0.0015) < 1e-12)
        #expect(await OpenRouterCostLedger.pending(in: home, ownerBotID: bot.id, accounts: [account], at: fixture.now(), queue: queue).isEmpty)
        let page = try AnalyticsDashboard.html(for: Analytics.collect(.init(root: root, accounts: [account], now: fixture.now())))
        #expect(!page.contains("planted-private-key"))
        let files = try FileManager.default.contentsOfDirectory(at: UsageLedger.directory(in: home), includingPropertiesForKeys: nil)
        for file in files {
            #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("planted-private-key"))
        }
        #expect(!FileManager.default.fileExists(atPath: home.logsURL.path))
    }

    @Test func ledgerEligibilityRequiresFrozenLocalOpenRouterKeyOwnership() {
        let fixture = Fixture()
        fixture.advance(60)
        let entry = UsageLedger.Entry(at: fixture.candidate.endedAt, startedAt: fixture.candidate.endedAt,
            kind: .task, botID: fixture.candidate.botID, accountID: fixture.candidate.accountID, provider: .pi,
            providerID: "openrouter", usesLegacyOpenRouterKey: true, outcome: .finished,
            usage: TurnUsage(models: [], reportedCostUSD: 0.1, generationIDs: ["gen-a"]))
        func eligible(_ value: UsageLedger.Entry) -> Bool {
            OpenRouterCostLedger.candidate(value, ownerBotID: fixture.candidate.ownerBotID, at: fixture.now()) != nil
        }
        #expect(eligible(entry))
        var value = entry; value.remote = true; #expect(!eligible(value))
        value = entry; value.usesLegacyOpenRouterKey = false; #expect(!eligible(value))
        value = entry; value.providerID = "anthropic"; #expect(!eligible(value))
        value = entry; value.providerID = nil; #expect(!eligible(value))
        value = entry; value.provider = .claude; #expect(!eligible(value))
        value = entry; value.usage?.generationIDs.append("unrecorded"); #expect(!eligible(value))
        value = entry; value.usage?.cumulative = true; #expect(!eligible(value))
        value = entry; value.at = fixture.now(); #expect(!eligible(value))
        value = entry; value.at = fixture.now().addingTimeInterval(-86_401); #expect(!eligible(value))
    }

    @Test func newlyPiOwnedAndMissingAccountsCannotUseLegacyCredential() async {
        let account = Account(id: "new-pi", name: "Pi", kind: .pi, defaultCommand: "pi", symbol: "")
        #expect(!OpenRouterCostLedger.permits(account))
        var legacy = account; legacy.credentialOwnership = .legacyOpenRouter
        #expect(OpenRouterCostLedger.permits(legacy))
        legacy.credentialOwnership = nil
        #expect(OpenRouterCostLedger.permits(legacy)) // Preserves the existing adapter's migration rule.
        let nonPi = Account(id: "claude", name: "Claude", kind: .claude, defaultCommand: "claude", symbol: "", credentialOwnership: .legacyOpenRouter)
        #expect(!OpenRouterCostLedger.permits(nonPi))
        let fixture = Fixture(), queue = StorageQueue()
        let home = BotHome(workspace: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
        defer { try? FileManager.default.removeItem(at: home.url.deletingLastPathComponent()) }
        let entry = UsageLedger.Entry(at: fixture.now(), startedAt: fixture.now(), kind: .home, botID: UUID(),
            accountID: account.id, provider: .pi, providerID: "openrouter", usesLegacyOpenRouterKey: true,
            outcome: .finished, usage: TurnUsage(models: [], generationIDs: ["gen-a"]))
        UsageLedger.append(entry, in: home, queue: queue)
        fixture.advance(60)
        for accounts in [[account], []] {
            let pending = await OpenRouterCostLedger.pending(in: home, ownerBotID: UUID(), accounts: accounts, at: fixture.now(), queue: queue)
            await fixture.scheduler().tick(pending)
        }
        #expect(fixture.credentialReads == 0 && fixture.requests.isEmpty)
        await queue.barrier(UsageLedger.lane(in: home))
    }

    private final class Fixture: @unchecked Sendable {
        // Test calls and the scheduler use these serially, except the clock read; NSLock makes
        // the injected synchronous clock safe without a real timer or network.
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var active = false
        var startDuringCredentialRead = false
        var startDuringResponse = false
        var credentialReads = 0
        var keyAvailable = true
        var writeSucceeds = true
        var status = 200
        var requests: [URLRequest] = []
        var amendments: [Double] = []
        let candidate = OpenRouterCostScheduler.Candidate(id: UUID(), ownerBotID: UUID(), botID: UUID(),
            accountID: "pi-openrouter", endedAt: Date(timeIntervalSince1970: 1_800_000_000), generationIDs: ["gen-a", "gen-b"])
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
        func scheduler(persist: OpenRouterCostScheduler.Amend? = nil) -> OpenRouterCostScheduler {
            OpenRouterCostScheduler(client: OpenRouterCost { [self] request in
                requests.append(request)
                if startDuringResponse { active = true }
                if status == -1 { throw URLError(.notConnectedToInternet) }
                let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems![0].value!
                return (Data("{\"data\":{\"id\":\"\(id)\",\"total_cost\":\(id == "gen-a" ? 0.0012 : 0.0003),\"ignored\":\"planted-private-key\"}}".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }, now: { [self] in now() }, isActive: { [self] _ in active }, credential: { [self] _ in
                credentialReads += 1
                if startDuringCredentialRead { active = true }
                return keyAvailable ? "planted-private-key" : nil
            }, amend: { [self] candidate, cost in
                guard writeSucceeds else { return false }
                if let persist, !(await persist(candidate, cost)) { return false }
                amendments.append(cost)
                return true
            })
        }
    }
}
