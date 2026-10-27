import Foundation
import Testing
@testable import BotChuCore

/// A turn's mailbox and the helper, as `botchu-inbox send` finds them, with BotChu's side played by
/// the test: the mailbox is the one a local `SubagentTransport` reads.
private final class InboxFixture {
    let root: URL
    let mailbox: URL
    let ipc: SubagentIPC
    let bin: URL
    let botID = UUID()
    let invocationID = UUID()
    let transport: SubagentTransport

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.resolvingSymlinksInPath()
        transport = SubagentTransport(machine: .thisMac, namespace: UUID(), invocationID: invocationID, localRoot: root.appendingPathComponent("ipc"))
        mailbox = root.appendingPathComponent("ipc").appendingPathComponent(invocationID.uuidString.lowercased())
        ipc = SubagentIPC(root: mailbox)
        bin = root.appendingPathComponent("bin")
        try SubagentHookInstaller.install(binDirectory: bin)
        try ipc.prepare()
        try ipc.writeHeartbeat()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start(_ arguments: [String], subagent: UUID? = nil) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = bin.appendingPathComponent("botchu-inbox")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                               "BOTCHU_IPC_DIR": ipc.root.path, "BOTCHU_INVOCATION_ID": invocationID.uuidString,
                               "BOTCHU_CALLER_BOT_ID": botID.uuidString, "BOTCHU_CALLER_SUBAGENT_ID": subagent?.uuidString ?? "",
                               "BOTCHU_CALLER_DEPTH": subagent == nil ? "0" : "1"]
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

    func request() throws -> (file: URL, data: Data) {
        let deadline = Date().addingTimeInterval(3)
        while ipc.pendingRequests().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        return try #require(ipc.pendingRequests().first)
    }

    func answer(_ result: InboxResult) throws {
        try SubagentIPC.encode(result).write(to: ipc.resultURL(result.id), options: .atomic)
    }

    var context: SubagentCallerContext {
        SubagentCallerContext(invocationID: invocationID, botID: botID, workingDirectory: root.path)
    }
}

@Suite struct InboxTests {
    @Test func theHelperStagesCopiesOfItsFilesAndPrintsTheDelivery() async throws {
        let fixture = try InboxFixture()
        let report = fixture.root.appendingPathComponent("telegram-subagents.md")
        try "# Summary\nAnswer first.".write(to: report, atomically: true, encoding: .utf8)
        let note = fixture.root.appendingPathComponent("note.md")
        try "Research Assistant looked into #118. $(touch injected)".write(to: note, atomically: true, encoding: .utf8)
        let started = try fixture.start(["send", "--purpose", "needs-input", "--title", "Should sub-agent work block Telegram?",
                                         "--note-file", note.path, "--file", report.path, "--issue", "asieke/BotChu#118",
                                         "--pr", "https://github.com/asieke/BotChu/pull/153", "--ask", "Which should I file?",
                                         "--choice", "Answer first", "--choice", "Hold, but say so", "--recommend", "Answer first",
                                         "--credit", "Research Assistant"])
        defer { if started.0.isRunning { started.0.terminate() } }
        let pending = try fixture.request()
        #expect(InboxRequest.isDelivery(pending.data))
        #expect(!TaskHandoff.isHandoff(pending.data))
        let request = try InboxRequest.parse(pending.data)
        try request.validate(fixture.context)
        #expect(request.title == "Should sub-agent work block Telegram?")
        #expect(request.note == "Research Assistant looked into #118. $(touch injected)")
        #expect(request.links == [Delivery.Link(repo: "asieke/BotChu", number: 153, isPullRequest: true),
                                  Delivery.Link(repo: "asieke/BotChu", number: 118, isPullRequest: false)])
        #expect(request.question == Delivery.Question(text: "Which should I file?", choices: ["Answer first", "Hold, but say so"],
                                                      recommended: "Answer first"))
        #expect(request.purpose == .needsInput && request.updates == nil)
        #expect(request.credits == ["Research Assistant"])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("injected").path))

        // The file is a copy from the moment it was sent: editing it afterwards changes nothing.
        let file = try #require(request.files.first)
        #expect(file.name == "telegram-subagents.md" && file.source?.hasSuffix("/telegram-subagents.md") == true)
        try "Changed later".write(to: report, atomically: true, encoding: .utf8)
        let staged = try await fixture.transport.readStaged(file.staged, request: request.id, limit: InboxRequest.maxFileBytes)
        #expect(String(decoding: staged, as: UTF8.self) == "# Summary\nAnswer first.")
        await #expect(throws: (any Error).self) {
            _ = try await fixture.transport.readStaged(file.staged, request: request.id, limit: 4)
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.transport.readStaged("inbox/\(request.id.uuidString.lowercased())/../../heartbeat.json",
                                                       request: request.id, limit: 1000)
        }
        try await fixture.transport.removeStaged(request: request.id)
        #expect(!FileManager.default.fileExists(atPath: fixture.mailbox.appendingPathComponent("inbox").appendingPathComponent(request.id.uuidString.lowercased()).path))

        let delivery = UUID()
        try fixture.answer(InboxResult(id: request.id, deliveryID: delivery))
        let finished = fixture.finish(started)
        #expect(finished.code == 0, "\(finished.error)")
        #expect(finished.output.contains("Delivered to your owner's Inbox: Should sub-agent work block Telegram?"))
        #expect(finished.output.contains("Delivery: \(delivery.uuidString)"))
    }

    @Test func theHelperReportsAnUpdateAFailureAndRefusesWhatItCantSend() throws {
        let fixture = try InboxFixture()
        let updating = try fixture.start(["send", "--purpose", "review", "--title", "Providers, today and improved", "--note", "v2"],
                                         subagent: UUID())
        let asked = try InboxRequest.parse(fixture.request().data)
        #expect(asked.parentSubagentID != nil && asked.files.isEmpty && asked.question == nil && asked.purpose == .review)
        // A sub-agent's request doesn't match the turn it claims to be.
        #expect(throws: InboxRequest.Problem.self) { try asked.validate(fixture.context) }
        try fixture.answer(InboxResult(id: asked.id, deliveryID: UUID(), updated: true))
        let updated = fixture.finish(updating)
        #expect(updated.code == 0 && updated.output.contains("Updated to your owner's Inbox"))
        _ = fixture.ipc.removeRequest(fixture.ipc.requestURL(asked.id))

        // A delivery from an earlier turn, named by the ID the helper printed.
        let earlier = UUID()
        let naming = try fixture.start(["send", "--purpose", "completed", "--title", "Dashboard is live", "--update", earlier.uuidString])
        let renewed = try InboxRequest.parse(fixture.request().data)
        #expect(renewed.updates == earlier && renewed.purpose == .completed)
        try fixture.answer(InboxResult(id: renewed.id, deliveryID: earlier, updated: true))
        #expect(fixture.finish(naming).code == 0)
        _ = fixture.ipc.removeRequest(fixture.ipc.requestURL(renewed.id))

        let failing = try fixture.start(["send", "--purpose", "fyi", "--title", "Report"])
        let failed = try InboxRequest.parse(fixture.request().data)
        try fixture.answer(InboxResult(id: failed.id, errorMessage: "its bot is gone"))
        let refused = fixture.finish(failing)
        #expect(refused.code == 1 && refused.error.contains("Not delivered: its bot is gone"))
        _ = fixture.ipc.removeRequest(fixture.ipc.requestURL(failed.id))

        // Refused before anything reaches BotChu.
        let hidden = fixture.root.appendingPathComponent(".env")
        try "SECRET=1".write(to: hidden, atomically: true, encoding: .utf8)
        let fyi = ["send", "--purpose", "fyi", "--title"]
        for arguments in [fyi + [" "], fyi + ["A", "--file", hidden.path],
                          fyi + ["A", "--file", fixture.root.appendingPathComponent("missing.md").path],
                          fyi + ["A", "--choice", "Yes"], fyi + ["A", "--pr", "not a link"], fyi + ["A", "--issue", "12"],
                          // Senders say what it is for, and a question goes with Needs input or For review.
                          ["send", "--title", "A"], ["send", "--purpose", "urgent", "--title", "A"],
                          ["send", "--purpose", "needs-input", "--title", "A"], fyi + ["A", "--ask", "Which?"],
                          ["send", "--purpose", "review", "--title", "A", "--recommend", "Yes"], fyi + ["A", "--update", "not-an-id"]] {
            let result = fixture.finish(try fixture.start(arguments))
            #expect(result.code != 0, "\(arguments)")
        }
        #expect(fixture.ipc.pendingRequests().isEmpty)
    }

    @Test func aHostsStagedFilesAreFetchedOverSSHAndRemoved() async throws {
        let transport = SubagentTransport(machine: FakeSSH.machine, namespace: UUID(), invocationID: UUID())
        let endpoint = try await transport.prepare(script: SubagentHookInstaller.script, roster: Data("[]".utf8))
        let directory = URL(fileURLWithPath: endpoint.ipcDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        #expect(FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("bin/botchu-inbox").path))
        let request = UUID()
        let staged = directory.appendingPathComponent("inbox/\(request.uuidString.lowercased())")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let page = Data((0..<300_000).map { UInt8($0 % 251) })
        try page.write(to: staged.appendingPathComponent("index.html"))
        let path = "inbox/\(request.uuidString.lowercased())/index.html"
        #expect(try await transport.readStaged(path, request: request, limit: InboxRequest.maxFileBytes) == page)
        await #expect(throws: SubagentTransport.Failure.self) { _ = try await transport.readStaged(path, request: request, limit: 1000) }
        await #expect(throws: SubagentTransport.Failure.self) { _ = try await transport.readStaged("results/x.json", request: request, limit: 1000) }
        try await transport.removeStaged(request: request)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test func aRequestIsReadStrictly() throws {
        let id = UUID(), invocation = UUID(), bot = UUID()
        func request(_ delivery: [String: Any], id: UUID = id) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["kind": "inbox", "id": id.uuidString, "invocationID": invocation.uuidString,
                                                        "callerBotID": bot.uuidString, "delivery": delivery])
        }
        let staged = "inbox/\(id.uuidString.lowercased())/report.md"
        let parsed = try InboxRequest.parse(request(["title": "  Report  ", "files": [["name": "report.md", "staged": staged, "bytes": 3]]]))
        #expect(parsed.title == "Report" && parsed.files.map(\.name) == ["report.md"])
        let problems: [[String: Any]] = [
            ["title": ""],
            ["title": String(repeating: "x", count: 201)],
            ["title": "A", "note": String(repeating: "x", count: InboxRequest.maxNoteBytes + 1)],
            ["title": "A", "files": [["name": "../escape", "staged": staged, "bytes": 3]]],
            ["title": "A", "files": [["name": "report.md", "staged": "inbox/\(UUID().uuidString.lowercased())/report.md", "bytes": 3]]],
            ["title": "A", "files": [["name": "report.md", "staged": "results/x.json", "bytes": 3]]],
            ["title": "A", "files": [["name": "report.md", "staged": staged, "bytes": InboxRequest.maxFileBytes + 1]]],
            ["title": "A", "links": [["repo": "not a repo", "number": 1]]],
            ["title": "A", "question": ["text": "", "choices": []]],
            ["title": "A", "question": ["text": "Which?", "choices": Array(repeating: "x", count: 7)]],
        ]
        for delivery in problems {
            #expect(throws: InboxRequest.Problem.self, "\(delivery.keys.sorted())") { try InboxRequest.parse(request(delivery)) }
        }
        #expect(throws: InboxRequest.Problem.self) { try InboxRequest.parse(Data(#"{"kind": "task"}"#.utf8)) }
    }

    @Test func aRequestSaysWhatItIsForAndRecommendsAnAnswer() throws {
        let invocation = UUID(), bot = UUID()
        func parse(_ delivery: [String: Any]) throws -> InboxRequest {
            try InboxRequest.parse(JSONSerialization.data(withJSONObject: ["kind": "inbox", "id": UUID().uuidString,
                                                                           "invocationID": invocation.uuidString,
                                                                           "callerBotID": bot.uuidString, "delivery": delivery]))
        }
        // From a helper before purposes: a question needs input, anything else is for review.
        #expect(try parse(["title": "A", "question": ["text": "Which?"]]).purpose == .needsInput)
        #expect(try parse(["title": "A"]).purpose == .review)
        for purpose in Delivery.Purpose.allCases where ![.needsInput].contains(purpose) {
            #expect(try parse(["title": "A", "purpose": purpose.rawValue]).purpose == purpose)
        }
        // The recommended answer is one click too, first when it wasn't offered.
        let asked = try parse(["title": "A", "purpose": "needs-input",
                               "question": ["text": "Which?", "choices": ["Hold"], "recommended": " Answer first "]])
        #expect(asked.question == Delivery.Question(text: "Which?", choices: ["Answer first", "Hold"], recommended: "Answer first"))
        let offered = try parse(["title": "A", "purpose": "review", "question": ["text": "Merge it?", "choices": ["No", "Yes"], "recommended": "Yes"]])
        #expect(offered.question?.choices == ["No", "Yes"] && offered.purpose == .review)
        let update = UUID()
        #expect(try parse(["title": "A", "purpose": "completed", "updates": update.uuidString]).updates == update)

        let problems: [[String: Any]] = [
            ["title": "A", "purpose": "urgent"],
            ["title": "A", "purpose": "needs-input"],
            ["title": "A", "purpose": "fyi", "question": ["text": "Which?"]],
            ["title": "A", "purpose": "completed", "question": ["text": "Which?"]],
            ["title": "A", "question": ["text": "Which?", "recommended": ""]],
            ["title": "A", "question": ["text": "Which?", "choices": (1...6).map(String.init), "recommended": "7"]],
            ["title": "A", "updates": "not-an-id"],
        ]
        for delivery in problems {
            #expect(throws: InboxRequest.Problem.self, "\(delivery)") { try parse(delivery) }
        }
    }

    /// Deliveries kept before purposes (#217) load with the purpose their content suggests, as does
    /// one with a purpose this version doesn't know.
    @Test func deliveriesKeptBeforePurposesLoadWithAFallback() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let folder = InboxFolder(home: BotHome(workspace: workspace.path))
        let bot = UUID()
        func keep(_ id: UUID, _ extra: String) throws {
            let record = """
                {"id": "\(id.uuidString)", "botID": "\(bot.uuidString)", "title": "Old", "note": "", "files": [], "links": [],
                 "credits": [], "sentAt": "2026-10-20T09:00:00Z", "updatedAt": "2026-10-20T09:00:00Z"\(extra)}
                """
            try FileManager.default.createDirectory(at: folder.folder(id), withIntermediateDirectories: true)
            try Data(record.utf8).write(to: folder.folder(id).appendingPathComponent("delivery.json"))
        }
        let report = UUID(), asking = UUID(), future = UUID(), done = UUID()
        try keep(report, "")
        try keep(asking, #", "question": {"text": "Which?", "choices": ["A", "B"]}"#)
        try keep(future, #", "purpose": "celebrate""#)
        try keep(done, #", "purpose": "completed""#)
        let loaded = Dictionary(uniqueKeysWithValues: folder.load().map { ($0.id, $0) })
        #expect(loaded.count == 4)
        #expect(loaded[report]?.purpose == .review && loaded[future]?.purpose == .review && loaded[done]?.purpose == .completed)
        #expect(loaded[asking]?.purpose == .needsInput && loaded[asking]?.question?.recommended == nil)
        // Saved again, it keeps its purpose.
        let kept = try #require(loaded[asking])
        #expect(try Store.decoder.decode(Delivery.self, from: Store.encoder.encode(kept)) == kept)
    }

    /// Sent again (the same title in the turn, or `--update` later), a delivery that says something
    /// new is renewed: unread, out of Done and unanswered. One that says nothing new keeps all that.
    @Test func onlyAChangedUpdateAsksForTheOwnerAgain() {
        let first = Delivery(botID: UUID(), title: "Which?", note: "v1", question: Delivery.Question(text: "Which?", choices: ["A"]),
                             sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -600)))
        var state = InboxState()
        state.received(first.id, renewed: true, shown: false)
        #expect(state.isUnread(first) && state.needsInput(first))
        state.answer(first.id, at: Delivery.stamp(Date(timeIntervalSinceNow: -300)))
        #expect(!state.needsInput(first) && state[first.id].done)

        var same = first
        same.updatedAt = Delivery.stamp()
        let (unchanged, renewed) = Delivery.resent(same, replacing: first)
        #expect(!renewed && unchanged.updatedAt == first.updatedAt && unchanged.sentAt == first.sentAt)
        state.received(unchanged.id, renewed: renewed, shown: false)
        #expect(state[first.id].done && state.isAnswered(unchanged) && !state.isUnread(unchanged))

        var changed = first
        changed.note = "v2: the options changed"
        changed.updatedAt = Delivery.stamp()
        let (again, asks) = Delivery.resent(changed, replacing: first)
        #expect(asks && again.sentAt == first.sentAt && again.updatedAt > first.updatedAt)
        state.received(again.id, renewed: asks, shown: false)
        #expect(!state[first.id].done && state.isUnread(again) && state.needsInput(again) && !state.isAnswered(again))
        // Arriving where the owner is looking, it is read there, still not Done.
        state.received(again.id, renewed: true, shown: true)
        #expect(!state.isUnread(again) && !state[again.id].done)
        #expect(Delivery.resent(changed, replacing: nil).renewed)
        // A different purpose is a change too.
        var review = first
        review.purpose = .review
        #expect(Delivery.resent(review, replacing: first).renewed)
    }

    /// For #218: each conversation with unresolved Needs input deliveries waits on the owner.
    @Test func aConversationAwaitsInputWhileItsNeedsInputIsUnresolved() {
        let bot = UUID(), task = UUID()
        let question = Delivery.Question(text: "Which?", choices: ["A"])
        let home = Delivery(botID: bot, title: "Home asks", question: question, sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -60)))
        let newer = Delivery(botID: bot, title: "Home asks again", question: question, sentAt: Delivery.stamp())
        let inTask = Delivery(botID: bot, taskID: task, title: "Task asks", question: question)
        let review = Delivery(botID: bot, taskID: task, title: "Review", question: question, purpose: .review)
        let fyi = Delivery(botID: UUID(), title: "FYI", purpose: .fyi)
        var state = InboxState()
        let all = [home, newer, inTask, review, fyi]
        #expect(state.awaitingInput(all) == [Delivery.Origin(botID: bot, taskID: nil): [newer.id, home.id],
                                             Delivery.Origin(botID: bot, taskID: task): [inTask.id]])
        // Answered, or Done without an answer, it no longer waits; read, it still does.
        state[home.id].read = true
        state.answer(newer.id, at: Delivery.stamp())
        state[inTask.id].done = true
        #expect(state.awaitingInput(all) == [Delivery.Origin(botID: bot, taskID: nil): [home.id]])
        #expect(state.needsInput(home) && !state.needsInput(review) && !state.needsInput(fyi))
    }

    @Test func linksAreReadAsGitHubWritesThem() {
        #expect(Delivery.Link.parse("asieke/BotChu#118", isPullRequest: false) == Delivery.Link(repo: "asieke/BotChu", number: 118, isPullRequest: false))
        #expect(Delivery.Link.parse("https://github.com/asieke/BotChu/pull/153/files", isPullRequest: false)
                == Delivery.Link(repo: "asieke/BotChu", number: 153, isPullRequest: true))
        #expect(Delivery.Link.parse("#12", isPullRequest: true, defaultRepo: "asieke/GitChu") == Delivery.Link(repo: "asieke/GitChu", number: 12, isPullRequest: true))
        #expect(Delivery.Link.parse("12", isPullRequest: true) == nil)
        #expect(Delivery.Link.parse("asieke/../x#1", isPullRequest: true) == nil)
        #expect(Delivery.Link(repo: "asieke/BotChu", number: 118, isPullRequest: false).url?.absoluteString == "https://github.com/asieke/BotChu/issues/118")
        #expect(Delivery.File.kind(of: "index.HTML") == .page && Delivery.File.kind(of: "a.md") == .document
                && Delivery.File.kind(of: "shot.png") == .image && Delivery.File.kind(of: "data.csv") == .other)
    }

    @Test func aBotKeepsItsDeliveriesWithTheirCopies() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-bot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let folder = InboxFolder(home: BotHome(workspace: workspace.path))
        let bot = UUID()
        let first = Delivery(botID: bot, title: "Report", note: "v1",
                             files: [Delivery.File(name: "report.md", kind: .document, bytes: 2)], sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -60)))
        try folder.save(first, contents: ["report.md": Data("v1".utf8)])
        let second = Delivery(botID: bot, taskID: UUID(), title: "Mockup", sentAt: Delivery.stamp())
        try folder.save(second, contents: [:])
        #expect(folder.load().map(\.id) == [second.id, first.id])

        // Sent again: its files are replaced, never mixed with the earlier ones.
        var again = first
        again.files = [Delivery.File(name: "index.html", kind: .page, bytes: 6)]
        again.updatedAt = Delivery.stamp(Date(timeIntervalSinceNow: 10))
        try folder.save(again, contents: ["index.html": Data("<html>".utf8)])
        #expect(folder.load().first == again)
        #expect(try String(contentsOf: folder.fileURL("index.html", of: first.id), encoding: .utf8) == "<html>")
        #expect(!FileManager.default.fileExists(atPath: folder.fileURL("report.md", of: first.id).path))

        // A delivery without its file's contents isn't saved at all.
        let broken = Delivery(botID: bot, title: "Broken", files: [Delivery.File(name: "a.md", kind: .document, bytes: 1)])
        #expect(throws: InboxRequest.Problem.self) { try folder.save(broken, contents: [:]) }
        #expect(folder.load().count == 2)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(entries.count == 2, "No temporary folders are left: \(entries)")
    }

    /// A scheduled run's report (#170) is its task's delivery, read again at launch with its
    /// origin, and delivering it again (a retry) replaces it rather than adding another.
    @Test func aJobRunsReportIsItsTasksDeliveryOnce() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-job-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let folder = InboxFolder(home: BotHome(workspace: workspace.path))
        let job = Job(botID: UUID(), title: "10x Product Analysis", prompt: "x", schedule: JobSchedule(kind: .daily))
        var run = JobRun(trigger: .scheduled, scheduledFor: Date(), timeZone: "America/New_York", reservedAt: Date())
        run.taskID = UUID()
        let report = try #require(JobReport.delivery(job: job, run: run, reply: "20 recommendations"))
        try folder.save(report, contents: [:])
        try folder.save(report, contents: [:])
        let kept = folder.load()
        #expect(kept == [report])
        #expect(kept.first?.botID == job.botID && kept.first?.taskID == run.taskID && kept.first?.id == run.id)
    }

    @Test func readDoneAndAnsweredAreKeptBesideTheIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let asking = Delivery(botID: UUID(), title: "Which?", question: Delivery.Question(text: "Which?", choices: ["A"]), sentAt: Delivery.stamp())
        let report = Delivery(botID: UUID(), title: "Report")
        var state = InboxState()
        #expect(state.isUnread(asking) && state.needsAnswer(asking) && !state.needsAnswer(report))
        #expect(state.unreadCount([asking, report]) == 2)
        state[asking.id].repliedAt = asking.updatedAt.addingTimeInterval(1)
        state[asking.id].read = true
        #expect(!state.isUnread(asking) && !state.needsAnswer(asking))
        // Sent again after the answer, it asks again.
        var again = asking
        again.updatedAt = asking.updatedAt.addingTimeInterval(5)
        #expect(state.needsAnswer(again))
        state[report.id].done = true
        #expect(!state.isUnread(report) && state.unreadCount([asking, report]) == 0)
        // An entry back to the defaults isn't kept.
        state[report.id] = InboxState.Entry()
        #expect(state.entries[report.id] == nil)
        state[report.id].done = true
        try state.save(to: root)
        #expect(InboxState.load(from: root) == state)
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("inbox.json"))) as? [String: Any]
        #expect((file?["entries"] as? [String: Any])?[report.id.uuidString] != nil, "Kept by ID, as an object")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox.json").path))
        #expect(InboxState.load(from: root.appendingPathComponent("missing")) == InboxState())
    }

    /// Beside Inbox, what isn't Done, read or not; the Dock keeps counting what is unread (#189).
    @Test func theSidebarCountsWhatIsntDoneReadOrNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-unfinished-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let report = Delivery(botID: UUID(), title: "Report")
        let mockup = Delivery(botID: UUID(), title: "Mockup")
        let asking = Delivery(botID: UUID(), title: "Which?", question: Delivery.Question(text: "Which?", choices: ["A"]))
        let all = [report, mockup, asking]
        var state = InboxState()
        #expect(state.unfinishedCount(all) == 3 && state.unreadCount(all) == 3)
        #expect(state.unfinishedCount([]) == 0)
        // Reading alone leaves it.
        state[report.id].read = true
        state[asking.id].repliedAt = Delivery.stamp()
        #expect(state.unfinishedCount(all) == 3 && state.unreadCount(all) == 2)
        // Done takes it off, read or not; moved back to the Inbox, it counts again, though read.
        state[mockup.id].done = true
        #expect(state.unfinishedCount(all) == 2 && state.unreadCount(all) == 1)
        state[report.id].done = true
        state[report.id].read = true
        #expect(state.unfinishedCount(all) == 1)
        state[report.id].done = false
        #expect(state.unfinishedCount(all) == 2 && state.unreadCount(all) == 1)
        // A delivery that is gone (its bot deleted) isn't counted, whatever was kept for it.
        #expect(state.unfinishedCount([report, mockup]) == 1)
        // Saved beside the index, the count comes back.
        try state.save(to: root)
        #expect(InboxState.load(from: root).unfinishedCount(all) == 2)
        state[asking.id].done = true
        state[report.id].done = true
        #expect(state.unfinishedCount(all) == 0)
    }

    @Test func theListGroupsWhatNeedsAnAnswerThenByDayWithDoneLast() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z"))
        func delivery(_ hours: Double, asks: Bool = false, _ purpose: Delivery.Purpose? = nil) -> Delivery {
            Delivery(botID: UUID(), title: "\(hours)", question: asks ? Delivery.Question(text: "Which?") : nil, purpose: purpose,
                     sentAt: now.addingTimeInterval(-hours * 3600))
        }
        let question = delivery(20, asks: true), today = delivery(1, .completed), earlierToday = delivery(3, .fyi)
        let yesterday = delivery(14, asks: true, .review), older = delivery(60), done = delivery(2, asks: true)
        var state = InboxState()
        state[done.id].done = true
        // Read, it is still unfinished and keeps its place.
        state[question.id].read = true
        state[today.id].read = true
        let groups = InboxList.groups([today, older, done, question, yesterday, earlierToday], state: state, now: now, calendar: calendar)
        #expect(groups.map(\.section) == [.needsInput, .today, .yesterday, .day(calendar.startOfDay(for: older.updatedAt)), .done])
        #expect(groups.map(\.ids) == [[question.id], [today.id, earlierToday.id], [yesterday.id], [older.id], [done.id]])
        #expect(state.unfinishedCount([today, older, done, question, yesterday, earlierToday]) == 5)

        // Answered while it is read, it stays where it was until the owner leaves it.
        state[question.id].repliedAt = now
        #expect(InboxList.section(of: question, state: state, now: now, calendar: calendar) == .yesterday)
        let pinned = InboxList.groups([question, today], state: state, now: now, calendar: calendar, pinned: [question.id: .needsInput])
        #expect(pinned.map(\.section) == [.needsInput, .today])

        // Done while it is read moves it to Done at once, and both counts change.
        state[today.id].done = true
        let read = InboxList.groups([question, today, earlierToday], state: state, now: now, calendar: calendar,
                                    pinned: [today.id: .today])
        #expect(read.map(\.section) == [.today, .yesterday, .done])
        #expect(read.map(\.ids) == [[earlierToday.id], [question.id], [today.id]])
        // Moved to the Inbox while it is read in Done, it goes back to its group at once.
        state[today.id].done = false
        let moved = InboxList.groups([today, earlierToday], state: state, now: now, calendar: calendar, pinned: [today.id: .done])
        #expect(moved.map(\.section) == [.today])
        #expect(moved.map(\.ids) == [[today.id, earlierToday.id]])
    }

    /// The order ↑ and ↓ (and #219's shortcuts) move through: every group's, Done's while open.
    @Test func theListIsSteppedThroughInTheOrderShown() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let groups = [InboxList.Group(section: .needsInput, ids: [a]), InboxList.Group(section: .today, ids: [b, c]),
                      InboxList.Group(section: .done, ids: [d])]
        #expect(InboxList.shown(groups, showsDone: false) == [a, b, c])
        #expect(InboxList.shown(groups, showsDone: true) == [a, b, c, d])
        #expect(InboxList.first(groups) == a)
        #expect(InboxList.first([InboxList.Group(section: .done, ids: [d])]) == nil)
        let shown = InboxList.shown(groups, showsDone: false)
        #expect(InboxList.step(from: a, by: 1, in: shown) == b && InboxList.step(from: c, by: -1, in: shown) == b)
        // At either end it stays; one not shown (or none) doesn't move.
        #expect(InboxList.step(from: c, by: 1, in: shown) == c && InboxList.step(from: a, by: -1, in: shown) == a)
        #expect(InboxList.step(from: d, by: 1, in: shown) == nil && InboxList.step(from: nil, by: 1, in: shown) == nil)
    }

    @Test func whenTheSelectedDeliveryLeavesTheListTheNextOneShownIsSelected() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(InboxList.selection(after: b, was: [a, b, c], now: [a, c]) == c)
        // The last one shown: the one before it.
        #expect(InboxList.selection(after: c, was: [a, b, c], now: [a, b]) == b)
        #expect(InboxList.selection(after: a, was: [a], now: []) == nil)
        // Done closed with a Done delivery selected: the last active one.
        #expect(InboxList.selection(after: c, was: [a, b, c, UUID()], now: [a, b]) == b)
    }

    @Test func aReplyNamesItsDelivery() {
        let delivery = Delivery(botID: UUID(), title: "Should sub-agent work block Telegram?")
        #expect(InboxReply.prompt("Answer first.", delivery: delivery)
                == "[Your owner's reply from the Inbox to your delivery “Should sub-agent work block Telegram?” (\(delivery.id.uuidString.lowercased()))]\n\nAnswer first.")
    }

    @Test func anAcceptedAnswerIsReadAndDoneAndAsksNothingMore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-inbox-answer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let asking = Delivery(botID: UUID(), title: "Which?", question: Delivery.Question(text: "Which?", choices: ["A", "B"]),
                              sentAt: Delivery.stamp(Date(timeIntervalSinceNow: -60)))
        var state = InboxState()
        let now = Delivery.stamp()
        state.answer(asking.id, at: now)
        #expect(state[asking.id] == InboxState.Entry(read: true, done: true, repliedAt: now))
        #expect(!state.needsAnswer(asking) && !state.isUnread(asking) && state.isAnswered(asking))
        #expect(InboxList.section(of: asking, state: state, now: now) == .done)
        // After a relaunch it is still answered and Done.
        try state.save(to: root)
        let read = InboxState.load(from: root)
        #expect(read[asking.id].done && read[asking.id].repliedAt == now && !read.needsAnswer(asking))
        // Out of Done again, it is answered and asks nothing until it is sent again.
        state[asking.id].done = false
        #expect(!state.needsAnswer(asking))
        var again = asking
        again.updatedAt = now.addingTimeInterval(5)
        #expect(state.needsAnswer(again) && !state.isAnswered(again))
    }

    /// A delivery's dates are as its record keeps them, in whole seconds: an answer in the second it
    /// was made answers it, in memory as after a relaunch.
    @Test func anAnswerInTheSecondADeliveryWasMadeAnswersIt() throws {
        let made = Date(timeIntervalSinceReferenceDate: 800_000_000.75)
        let asking = Delivery(botID: UUID(), title: "Which?", question: Delivery.Question(text: "Which?", choices: ["A"]), sentAt: made)
        #expect(asking.sentAt == Delivery.stamp(made) && asking.updatedAt == asking.sentAt)
        #expect(Delivery(botID: UUID(), title: "Again", sentAt: made, updatedAt: made.addingTimeInterval(2)).updatedAt
                == Delivery.stamp(made.addingTimeInterval(2)))
        var state = InboxState()
        state.answer(asking.id, at: Delivery.stamp(made.addingTimeInterval(0.2)))
        #expect(state.isAnswered(asking) && !state.needsAnswer(asking))
        let read = try Store.decoder.decode(Delivery.self, from: Store.encoder.encode(asking))
        #expect(read == asking && state.isAnswered(read))
    }

    @Test func everySessionLearnsHowToDeliver() {
        let roster = [BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))]
        let home = BotContext.subagentsSection(availableBots: roster)
        for text in ["botchu-inbox send --purpose <purpose> --title", "`needs-input`", "`review`", "`completed`", "`fyi`",
                     "--note-file", "--ask", "--choice", "--recommend", "--credit <bot>", "same title again", "`--update <id>`",
                     "25–50 words", "Done isn't approval", "https://example.com/dash", "names the delivery it answers"] {
            #expect(home.contains(text), "Missing \(text)")
        }
        // Routine updates stay out of the Inbox.
        #expect(home.contains("Never deliver a turn ending, a task starting, progress or a minor note."))
        #expect(BotContext.subagentsSection(availableBots: roster, depth: 1).contains("You are a sub-agent run"))
        #expect(BotContext.subagentsSection(availableBots: roster, depth: SubagentLimits.maxDepth).contains("botchu-inbox send"))
    }
}
