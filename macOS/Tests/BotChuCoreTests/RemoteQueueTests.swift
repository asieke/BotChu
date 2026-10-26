import Foundation
import Testing
@testable import BotChuCore

struct RemoteQueueTests {
    private func fixture() throws -> (URL, UUID, RemoteQueue) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-remote-\(UUID())")
        let id = UUID()
        return (root, id, try RemoteQueue(botID: id, file: root.appendingPathComponent("queue.json")))
    }

    @Test func fifoRedeliveryRelaunchAndExactlyOnceReplies() async throws {
        let (root, bot, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 10)
        let first = try await queue.enqueue("first", at: date)
        let second = try await queue.enqueue("second", at: date)
        #expect(await queue.next()?.id == first.id)
        #expect(await queue.next()?.id == first.id)
        let reloaded = try RemoteQueue(botID: bot, file: root.appendingPathComponent("queue.json"))
        #expect(await reloaded.next()?.id == first.id)
        #expect(try await reloaded.reply(to: first.id, text: "answer", error: nil, at: date))
        #expect(try await !reloaded.reply(to: first.id, text: "a duplicate", error: nil))
        #expect(await reloaded.next()?.id == second.id)
        #expect(try await reloaded.reply(to: second.id, text: nil, error: "Remote turn failed", at: date))
        #expect(await reloaded.next() == nil)
        let again = try RemoteQueue(botID: bot, file: root.appendingPathComponent("queue.json"))
        let snapshot = await again.snapshot()
        #expect(snapshot.messages.map(\.text) == ["first", "second", "answer", "Remote turn failed"])
        #expect(snapshot.messages.map(\.role) == [.user, .user, .assistant, .error])
        #expect(snapshot.pending == 0)
        #expect(try await !again.reply(to: first.id, text: "retry after relaunch", error: nil))
    }

    @Test func queueCapsAndFailedPersistenceNeverAcceptAMessage() async throws {
        let (root, _, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<RemoteQueue.capacity { try await queue.enqueue("\(n)") }
        await #expect(throws: RemoteQueue.Failure.full) { try await queue.enqueue("eleven") }
        #expect(await queue.snapshot().pending == 10)
        let occupied = root.appendingPathComponent("not-a-directory")
        try Data().write(to: occupied)
        let failing = try RemoteQueue(botID: UUID(), file: occupied.appendingPathComponent("queue.json"))
        await #expect(throws: (any Error).self) { try await failing.enqueue("not accepted") }
        #expect(await failing.snapshot().pending == 0)
    }

    @Test func authenticationCoversEveryRouteAndTokenRotation() async throws {
        let (root, _, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = RemoteQueueEndpoint(queue: queue, token: "fixture-only-not-a-real-token")
        for path in ["/v1/queue/next", "/v1/queue/reply", "/v1/health", "/unknown"] {
            for auth in [String?.none, "Bearer wrong"] {
                let response = await endpoint.handle(.init(method: "GET", path: path, authorization: auth, body: Data("bad json".utf8)))
                #expect(response.status == 401)
                #expect(response.body.isEmpty)
            }
        }
        #expect(await queue.snapshot().lastPoll == nil)
        let auth = "Bearer fixture-only-not-a-real-token"
        #expect(await endpoint.handle(.init(method: "GET", path: "/v1/queue/next", authorization: auth)).status == 204)
        #expect(await queue.snapshot().online())
        #expect(await !queue.snapshot().online(at: Date().addingTimeInterval(121)))
        endpoint.replaceToken("replacement-fixture")
        #expect(await endpoint.handle(.init(method: "GET", path: "/v1/health", authorization: auth)).status == 401)
        #expect(await endpoint.handle(.init(method: "GET", path: "/v1/health", authorization: "Bearer replacement-fixture")).status == 200)
    }

    @Test func replyEndpointKeepsWholeTextAndRejectsInvalidBodies() async throws {
        let (root, _, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = RemoteQueueEndpoint(queue: queue, token: "fixture")
        let message = try await queue.enqueue("Reply with pineapple")
        let text = String(repeating: "pineapple 🍍\n", count: 10_000)
        let body = try JSONSerialization.data(withJSONObject: ["id": message.id.uuidString, "text": text])
        let request = RemoteQueueRequest(method: "POST", path: "/v1/queue/reply", authorization: "Bearer fixture", body: body)
        #expect(await endpoint.handle(request).status == 200)
        #expect(await endpoint.handle(request).status == 200)
        #expect(await queue.snapshot().messages.last?.text == text)
        #expect(await queue.snapshot().messages.count == 2)
        let unknown = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "text": "unknown"])
        #expect(await endpoint.handle(.init(method: "POST", path: request.path, authorization: request.authorization, body: unknown)).status == 404)
        #expect(await endpoint.handle(.init(method: "POST", path: request.path, authorization: request.authorization, body: Data())).status == 400)
    }

    @Test func filesGoOutWithAWaitingMessageAndComeBackWithItsReply() async throws {
        let (root, bot, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = RemoteQueueEndpoint(queue: queue, token: "fixture")
        let auth = "Bearer fixture"
        let pdf = Data("%PDF-1.7 fixture".utf8)
        let sent = try BotHome(url: root).saveFile(pdf, name: "roster.pdf", type: "application/pdf")
        let message = try await queue.enqueue("", files: [sent])
        let next = await endpoint.handle(.init(method: "GET", path: "/v1/queue/next", authorization: auth))
        let listed = try #require(try JSONSerialization.jsonObject(with: next.body) as? [String: Any])
        let files = try #require(listed["files"] as? [[String: Any]])
        #expect(files.count == 1)
        #expect(files.first?["name"] as? String == "roster.pdf")
        #expect(files.first?["type"] as? String == "application/pdf")
        #expect(files.first?["size"] as? Int == pdf.count)
        let path = RemoteQueueEndpoint.filesPath + sent.id.uuidString
        let download = await endpoint.handle(.init(method: "GET", path: path, authorization: auth))
        #expect(download.status == 200)
        #expect(download.body == pdf)
        #expect(String(decoding: RemoteQueueHTTP.encode(download), as: UTF8.self).contains("Content-Type: application/pdf\r\n"))
        #expect(await endpoint.handle(.init(method: "GET", path: path, authorization: nil)).status == 401)
        #expect(await endpoint.handle(.init(method: "GET", path: RemoteQueueEndpoint.filesPath + UUID().uuidString, authorization: auth)).status == 404)
        #expect(await endpoint.handle(.init(method: "GET", path: RemoteQueueEndpoint.filesPath + "../queue.json", authorization: auth)).status == 404)

        let csv = Data("name\nAlex\n".utf8)
        let body = try JSONSerialization.data(withJSONObject: ["id": message.id.uuidString, "text": "Here it is.",
            "files": [["name": "../../bald eagles.csv", "type": "text/csv\r\nX-Injected: 1", "data": csv.base64EncodedString()]]])
        #expect(await endpoint.handle(.init(method: "POST", path: "/v1/queue/reply", authorization: auth, body: body)).status == 200)
        // Answered, so its files aren't offered any more.
        #expect(await endpoint.handle(.init(method: "GET", path: path, authorization: auth)).status == 404)
        let reloaded = try RemoteQueue(botID: bot, file: root.appendingPathComponent("queue.json"))
        let reply = try #require(await reloaded.snapshot().messages.last)
        let received = try #require(reply.documents.first)
        #expect(reply.text == "Here it is.")
        #expect(received.name == "-..-bald eagles.csv")
        #expect(received.type == nil)
        #expect(received.size == csv.count)
        let saved = BotHome(url: root).fileURL(received)
        #expect(saved.deletingLastPathComponent().deletingLastPathComponent() == root.appendingPathComponent("attachments", isDirectory: true))
        #expect(try Data(contentsOf: saved) == csv)
    }

    @Test func filesAloneMakeAMessageOrReplyButNotAnError() async throws {
        let (root, _, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: RemoteQueue.Failure.emptyText) { try await queue.enqueue(" ") }
        let first = try await queue.enqueue("Send the roster")
        let file = RemoteQueue.IncomingFile(name: "roster.pdf", type: "application/pdf", data: Data("pdf".utf8))
        await #expect(throws: RemoteQueue.Failure.invalidReply) { try await queue.reply(to: first.id, text: nil, error: "failed", files: [file]) }
        await #expect(throws: RemoteQueue.Failure.invalidReply) {
            try await queue.reply(to: first.id, text: "", error: nil, files: Array(repeating: file, count: FileAttachment.maximumCount + 1))
        }
        await #expect(throws: RemoteQueue.Failure.invalidReply) {
            try await queue.reply(to: first.id, text: "", error: nil, files: [.init(name: "empty.txt", data: Data())])
        }
        #expect(try await queue.reply(to: first.id, text: "", error: nil, files: [file]))
        #expect(await queue.snapshot().messages.last?.documents.map(\.name) == ["roster.pdf"])
        let missing = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "text": "", "files": [["name": "x", "data": "not base64!"]]])
        let endpoint = RemoteQueueEndpoint(queue: queue, token: "fixture")
        #expect(await endpoint.handle(.init(method: "POST", path: "/v1/queue/reply", authorization: "Bearer fixture", body: missing)).status == 400)
    }

    @Test func fileNamesStayInsideTheirFolder() {
        #expect(FileAttachment.safeName("report.pdf") == "report.pdf")
        #expect(FileAttachment.safeName("../../etc/passwd") == "-..-etc-passwd")
        #expect(FileAttachment.safeName("...hidden") == "hidden")
        #expect(FileAttachment.safeName("a\u{202E}fdp.exe") == "a fdp.exe")
        #expect(FileAttachment.safeName("\n") == "file")
        let long = FileAttachment.safeName(String(repeating: "x", count: 300) + ".pdf")
        #expect(long.count == 120)
        #expect(long.hasSuffix(".pdf"))
    }

    @Test func httpFramingHandlesFragmentsAndRejectsAmbiguity() throws {
        let body = Data("{\"text\":\"🍍\"}".utf8)
        let header = "POST /v1/queue/reply HTTP/1.1\r\nAuthorization: Bearer fixture\r\nContent-Length: \(body.count)\r\n\r\n"
        guard case .incomplete = RemoteQueueHTTP.decode(Data(header.utf8)) else { Issue.record("Partial body was accepted"); return }
        guard case .request(let request) = RemoteQueueHTTP.decode(Data(header.utf8) + body) else { Issue.record("Valid HTTP rejected"); return }
        #expect(request.authorization == "Bearer fixture")
        #expect(request.body == body)
        for raw in ["GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", "GET / HTTP/1.1\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n",
                    "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"] {
            guard case .invalid = RemoteQueueHTTP.decode(Data(raw.utf8)) else { Issue.record("Ambiguous request accepted"); continue }
        }
    }

    @Test func headersCanAuthenticateBeforeAnyDeclaredBodyArrives() throws {
        let raw = "POST /v1/queue/reply HTTP/1.1\r\nAuthorization: Bearer fixture\r\nContent-Length: \(RemoteQueueHTTP.maximumBody)\r\n\r\n"
        guard case .header(let header) = RemoteQueueHTTP.decodeHeader(Data(raw.utf8)) else {
            Issue.record("Complete headers waited for the body"); return
        }
        #expect(header.authorization == "Bearer fixture")
        #expect(header.contentLength == RemoteQueueHTTP.maximumBody)
        #expect(header.byteCount == raw.utf8.count)
        for raw in ["GET / HTTP/1.1\r\nBad Header: x\r\n\r\n", "GET / HTTP/1.1\r\nX: a\nb\r\n\r\n",
                    "POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: 99999999999999999999999\r\n\r\n",
                    String(repeating: "a", count: RemoteQueueHTTP.maximumHeader),
                    "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: RemoteQueueHTTP.maximumHeader) + "\r\n\r\n"] {
            guard case .invalid = RemoteQueueHTTP.decodeHeader(Data(raw.utf8)) else { Issue.record("Unsafe headers accepted"); continue }
        }
    }

    @Test func admissionBudgetBoundsBurstsRecoversAndSuppliesRetryGuidance() {
        var rate = RemoteQueueRateLimiter(burst: 3, perSecond: 2, now: 10)
        for _ in 0..<3 { #expect(rate.admit(at: 10) == nil) }
        #expect(rate.admit(at: 10) == 1)
        #expect(rate.admit(at: 9) == 1)
        #expect(rate.admit(at: 10.49) == 1)
        #expect(rate.admit(at: 10.5) == nil)
        #expect(rate.admit(at: 10.5) == 1)
        for _ in 0..<3 { #expect(rate.admit(at: 100) == nil) }
        #expect(rate.admit(at: 100) == 1)
        let response = String(decoding: RemoteQueueHTTP.encode(.init(429, retryAfter: 1)), as: UTF8.self)
        #expect(response.contains("429 Too Many Requests\r\n"))
        #expect(response.contains("Retry-After: 1\r\n"))
        #expect(response.contains("Cache-Control: no-store\r\n"))
    }

    @Test func revocationInvalidatesAnAlreadyAuthenticatedUpload() async throws {
        let (root, _, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = RemoteQueueEndpoint(queue: queue, token: "old-fixture")
        let message = try await queue.enqueue("waiting")
        #expect(endpoint.isAuthorized("Bearer old-fixture"))
        endpoint.replaceToken("new-fixture")
        let body = try JSONSerialization.data(withJSONObject: ["id": message.id.uuidString, "text": "stale upload"])
        #expect(await endpoint.handle(.init(method: "POST", path: "/v1/queue/reply", authorization: "Bearer old-fixture", body: body)).status == 401)
        #expect(await queue.status().pending == 1)
        endpoint.replaceToken("")
        #expect(!endpoint.isAuthorized("Bearer new-fixture"))
        #expect(!endpoint.isAuthorized("Bearer "))
    }

    @Test func failedReplySaveIsNotAcknowledgedAndCorruptJournalIsPreserved() async throws {
        let (root, botID, queue) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = try await queue.enqueue("must stay pending")
        let file = root.appendingPathComponent("queue.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let endpoint = RemoteQueueEndpoint(queue: queue, token: "fixture")
        let body = try JSONSerialization.data(withJSONObject: ["id": message.id.uuidString, "text": "not durable"])
        #expect(await endpoint.handle(.init(method: "POST", path: "/v1/queue/reply", authorization: "Bearer fixture", body: body)).status == 503)
        #expect(await queue.next()?.id == message.id)
        #expect(await queue.snapshot().messages.count == 1)
        try FileManager.default.removeItem(at: file)
        let corrupt = Data("not a journal".utf8)
        try corrupt.write(to: file)
        #expect(throws: (any Error).self) { try RemoteQueue(botID: botID, file: file) }
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func oldBotsRemainLocalAndRemoteHistoryHasNoWorkspace() throws {
        let old = Bot(name: "Old", workspace: "/fixture")
        let data = try Store.encoder.encode(old)
        #expect(try !Store.decoder.decode(Bot.self, from: data).isRemoteQueue)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-remote-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var bot = Bot(name: "Danny", workspace: "")
        bot.kind = .remoteQueue
        bot.remoteStorage = root.appendingPathComponent("remote-bots/\(bot.id)").path
        try BotHome(workspace: bot.persistencePath).save(bot)
        let store = Store(root: root)
        try store.saveIndex(Store.entries(for: [bot], sections: [:], missing: []))
        let reloaded = try #require(store.loadBots().bots.first)
        #expect(reloaded.isRemoteQueue)
        #expect(reloaded.workspace.isEmpty)
        #expect(reloaded.remoteStorage == bot.remoteStorage)
    }
}
