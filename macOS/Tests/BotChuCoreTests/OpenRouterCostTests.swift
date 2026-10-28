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
        func scheduler() -> OpenRouterCostScheduler {
            OpenRouterCostScheduler(client: OpenRouterCost { [self] request in
                requests.append(request)
                if startDuringResponse { active = true }
                if status == -1 { throw URLError(.notConnectedToInternet) }
                let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems![0].value!
                return (Data("{\"data\":{\"id\":\"\(id)\",\"total_cost\":\(id == "gen-a" ? 0.0012 : 0.0003)}}".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }, now: { [self] in now() }, isActive: { [self] _ in active }, credential: { [self] _ in
                credentialReads += 1
                if startDuringCredentialRead { active = true }
                return keyAvailable ? "planted-private-key" : nil
            }, amend: { [self] _, cost in
                guard writeSucceeds else { return false }
                amendments.append(cost)
                return true
            })
        }
    }
}
