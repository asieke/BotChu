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
        let started = try fixture.start(["send", "--title", "Should sub-agent work block Telegram?", "--note-file", note.path,
                                         "--file", report.path, "--issue", "asieke/BotChu#118",
                                         "--pr", "https://github.com/asieke/BotChu/pull/153", "--ask", "Which should I file?",
                                         "--choice", "Answer first", "--choice", "Hold, but say so", "--credit", "Research Assistant"])
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
        #expect(request.question == Delivery.Question(text: "Which should I file?", choices: ["Answer first", "Hold, but say so"]))
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
        let updating = try fixture.start(["send", "--title", "Providers, today and improved", "--note", "v2"], subagent: UUID())
        let asked = try InboxRequest.parse(fixture.request().data)
        #expect(asked.parentSubagentID != nil && asked.files.isEmpty && asked.question == nil)
        // A sub-agent's request doesn't match the turn it claims to be.
        #expect(throws: InboxRequest.Problem.self) { try asked.validate(fixture.context) }
        try fixture.answer(InboxResult(id: asked.id, deliveryID: UUID(), updated: true))
        let updated = fixture.finish(updating)
        #expect(updated.code == 0 && updated.output.contains("Updated to your owner's Inbox"))
        _ = fixture.ipc.removeRequest(fixture.ipc.requestURL(asked.id))

        let failing = try fixture.start(["send", "--title", "Report"])
        let failed = try InboxRequest.parse(fixture.request().data)
        try fixture.answer(InboxResult(id: failed.id, errorMessage: "its bot is gone"))
        let refused = fixture.finish(failing)
        #expect(refused.code == 1 && refused.error.contains("Not delivered: its bot is gone"))
        _ = fixture.ipc.removeRequest(fixture.ipc.requestURL(failed.id))

        // Refused before anything reaches BotChu.
        let hidden = fixture.root.appendingPathComponent(".env")
        try "SECRET=1".write(to: hidden, atomically: true, encoding: .utf8)
        for arguments in [["send", "--title", " "], ["send", "--title", "A", "--file", hidden.path],
                          ["send", "--title", "A", "--file", fixture.root.appendingPathComponent("missing.md").path],
                          ["send", "--title", "A", "--choice", "Yes"], ["send", "--title", "A", "--pr", "not a link"],
                          ["send", "--title", "A", "--issue", "12"]] {
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

    @Test func theListGroupsWhatNeedsAnAnswerThenByDayWithDoneLast() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z"))
        func delivery(_ hours: Double, asks: Bool = false) -> Delivery {
            Delivery(botID: UUID(), title: "\(hours)", question: asks ? Delivery.Question(text: "Which?") : nil,
                     sentAt: now.addingTimeInterval(-hours * 3600))
        }
        let question = delivery(20, asks: true), today = delivery(1), earlierToday = delivery(3), yesterday = delivery(14)
        let older = delivery(60), done = delivery(2)
        var state = InboxState()
        state[done.id].done = true
        let groups = InboxList.groups([today, older, done, question, yesterday, earlierToday], state: state, now: now, calendar: calendar)
        #expect(groups.map(\.section) == [.needsYou, .today, .yesterday, .day(calendar.startOfDay(for: older.updatedAt)), .done])
        #expect(groups.map(\.ids) == [[question.id], [today.id, earlierToday.id], [yesterday.id], [older.id], [done.id]])

        // Answered while it is read, it stays where it was until the owner leaves it.
        state[question.id].repliedAt = now
        #expect(InboxList.section(of: question, state: state, now: now, calendar: calendar) == .yesterday)
        let pinned = InboxList.groups([question, today], state: state, now: now, calendar: calendar, pinned: [question.id: .needsYou])
        #expect(pinned.map(\.section) == [.needsYou, .today])
    }

    @Test func aReplyNamesItsDeliveryAndOnlyItsExchangeShowsUnderIt() {
        let delivery = Delivery(botID: UUID(), title: "Should sub-agent work block Telegram?")
        #expect(InboxReply.prompt("Answer first.", delivery: delivery)
                == "[Your owner's reply from the Inbox to your delivery “Should sub-agent work block Telegram?” (\(delivery.id.uuidString.lowercased()))]\n\nAnswer first.")
        var reply = ChatMessage(role: .user, text: "Answer first.")
        reply.delivery = delivery.id
        var other = ChatMessage(role: .user, text: "Another reply")
        other.delivery = UUID()
        let thread = [
            ChatMessage(role: .user, text: "Look into #118"), ChatMessage(role: .assistant, text: "Delivered."),
            delivery.card, reply, ChatMessage(role: .tool, toolName: "Bash"),
            ChatMessage(role: .assistant, text: "Filing it as #156."), ChatMessage(role: .note, text: "Stopped"),
            ChatMessage(role: .user, text: "Something else"), ChatMessage(role: .assistant, text: "Unrelated"),
            other, ChatMessage(role: .assistant, text: "Not this one"),
        ]
        #expect(InboxReply.exchange(for: delivery.id, in: thread).map(\.text) == ["Answer first.", "Filing it as #156."])
        #expect(InboxReply.answered(in: thread) == [delivery.id, other.delivery!])
    }

    @Test func everySessionLearnsHowToDeliver() {
        let roster = [BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))]
        let home = BotContext.subagentsSection(availableBots: roster)
        for text in ["botchu-inbox send --title", "--note-file", "--ask", "--choice", "--credit <bot>", "same title again",
                     "names the delivery it answers"] {
            #expect(home.contains(text), "Missing \(text)")
        }
        #expect(BotContext.subagentsSection(availableBots: roster, depth: 1).contains("You are a sub-agent run"))
        #expect(BotContext.subagentsSection(availableBots: roster, depth: SubagentLimits.maxDepth).contains("botchu-inbox send"))
    }
}
