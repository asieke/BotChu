import Foundation
import Testing
@testable import BotChuCore

/// `botchu-secret ask` (#266): a bot asks its owner for a key, BotChu answers with what they paste,
/// and the helper puts it in place without printing it.
struct SecretsTests {
    static func fields(id: UUID = UUID(), invocation: UUID, bot: UUID, destinations: [[String: Any]]) -> [String: Any] {
        ["kind": "secret", "id": id.uuidString.lowercased(), "invocationID": invocation.uuidString, "callerBotID": bot.uuidString,
         "title": " Stripe sandbox key ", "note": "From the Stripe dashboard", "destinations": destinations, "wait": 120]
    }

    @Test func requestsAreReadAndCheckedAgainstTheAskingTurn() throws {
        let id = UUID(), invocation = UUID(), bot = UUID()
        let destinations: [[String: Any]] = [["type": "env", "name": "STRIPE_KEY", "path": "/tmp/a/.env"],
                                             ["type": "file", "path": "/tmp/key"], ["type": "pipe", "command": " gh secret set KEY "]]
        let fields = Self.fields(id: id, invocation: invocation, bot: bot, destinations: destinations)
        let data = try JSONSerialization.data(withJSONObject: fields)
        #expect(SecretRequest.isRequest(data) && !InboxRequest.isDelivery(data) && !TaskListRequest.isRequest(data))
        let request = try SecretRequest.parse(data)
        #expect(request == SecretRequest(id: id, invocationID: invocation, callerBotID: bot, title: "Stripe sandbox key",
                                         note: "From the Stripe dashboard",
                                         destinations: [.env(name: "STRIPE_KEY", path: "/tmp/a/.env"), .file(path: "/tmp/key"),
                                                        .pipe(command: "gh secret set KEY")], wait: 120))
        try request.validate(SubagentCallerContext(invocationID: invocation, botID: bot, workingDirectory: "/"))
        #expect(throws: InboxRequest.Problem.self) {
            try request.validate(SubagentCallerContext(invocationID: invocation, botID: bot, parentSubagentID: UUID(), workingDirectory: "/"))
        }

        func rejects(_ change: (inout [String: Any]) -> Void) -> Bool {
            var changed = fields
            change(&changed)
            return (try? SecretRequest.parse(JSONSerialization.data(withJSONObject: changed))) == nil
        }
        #expect(rejects { $0["destinations"] = [] })
        #expect(rejects { $0["destinations"] = [["type": "env", "name": "1BAD", "path": "/tmp/.env"]] })
        #expect(rejects { $0["destinations"] = [["type": "file", "path": "relative/key"]] })
        #expect(rejects { $0["destinations"] = [["type": "upload", "path": "/tmp/key"]] })
        #expect(rejects { $0["destinations"] = Array(repeating: ["type": "file", "path": "/tmp/key"], count: 9) })
        #expect(rejects { $0["title"] = "  " })
        #expect(rejects { $0["wait"] = 5 })
        #expect(rejects { $0["callerBotID"] = nil })
    }

    @Test func destinationsReadAsThePopupListsThem() {
        #expect(SecretDestination.env(name: "KEY", path: "/Users/me/kids/.env").label(home: "/Users/me") == "KEY in ~/kids/.env")
        #expect(SecretDestination.file(path: "/Users/meg/key").label(home: "/Users/me") == "/Users/meg/key")
        #expect(SecretDestination.pipe(command: "vercel env add KEY production").label() == "vercel env add KEY production")
        #expect(SecretDestination.isVariableName("_STRIPE_KEY2") && !SecretDestination.isVariableName("STRIPE-KEY")
                && !SecretDestination.isVariableName(""))
    }

    @Test func whatIsPastedIsTrimmedAndNeverPrinted() throws {
        #expect(SecretRequest.cleaned("  sk_test_123\n") == "sk_test_123")
        #expect(SecretRequest.cleaned(" \n ") == nil)
        #expect(SecretRequest.cleaned(String(repeating: "x", count: SecretRequest.maxValueBytes + 1)) == nil)
        let result = SecretResult(id: UUID(), value: "sk_test_123")
        #expect(!"\(result)".contains("sk_test") && !String(reflecting: result).contains("sk_test"))
        #expect(try SubagentIPC.decode(SecretResult.self, from: SubagentIPC.encode(result)) == result)
    }

    @Test func agentsAreToldToAskForSecretsWithThePopup() {
        let section = BotContext.subagentsSection(availableBots: [BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))])
        #expect(section.contains("<secrets>") && section.contains("`botchu-secret ask --title"))
        #expect(BotContext.subagentsSection(availableBots: [BotRosterEntry(bot: Bot(name: "Worker", workspace: "/tmp/worker"))], depth: 3)
            .contains("`botchu-secret ask`"))
        #expect(SubagentHookInstaller.commands.contains("botchu-secret"))
    }

    // MARK: The helper

    @Test func theHelperPutsThePastedValueInPlaceWithoutPrintingIt() throws {
        let fixture = try SecretFixture()
        // A worktree's .env is a link to the main checkout's, which is the file that changes.
        let checkout = fixture.root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let main = checkout.appendingPathComponent(".env")
        try "# Keys\nexport STRIPE_KEY=old\nOTHER=1\nSTRIPE_KEY=older\n".write(to: main, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: main.path)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent(".env"), withDestinationURL: main)
        let piped = fixture.root.appendingPathComponent("piped")
        let started = try fixture.start(["ask", "--title", "Stripe sandbox key", "--note", "Test mode", "--name", "STRIPE_KEY",
                                         "--env-file", ".env", "--env-file", "fresh/.env", "--file", "key.txt",
                                         "--pipe", "cat > \(piped.path); echo got $(cat \(piped.path))"], makeFolder: "fresh")
        defer { if started.0.isRunning { started.0.terminate() } }
        let asked = try fixture.request()
        let request = try SecretRequest.parse(asked.data)
        #expect(request.title == "Stripe sandbox key" && request.note == "Test mode" && request.wait == SecretRequest.defaultWait)
        let real = realPath(fixture.root)
        #expect(request.destinations == [.env(name: "STRIPE_KEY", path: realPath(main)),
                                         .env(name: "STRIPE_KEY", path: real + "/fresh/.env"), .file(path: real + "/key.txt"),
                                         .pipe(command: "cat > \(piped.path); echo got $(cat \(piped.path))")])
        let secret = "sk_test_a$b'c"
        try fixture.answer(SecretResult(id: request.id, value: secret))
        let finished = fixture.finish(started)
        #expect(finished.code == 0, "\(finished.error)")
        #expect(!finished.output.contains(secret) && !finished.error.contains(secret))
        #expect(finished.output.contains("Your owner pasted Stripe sandbox key; it was saved without being shown here, to:"))
        #expect(finished.output.contains("- STRIPE_KEY in \(realPath(main))"))
        #expect(finished.output.contains(", which printed: got [secret]"))
        // The variable is set where it was, once, and the rest of the file and its mode are kept.
        #expect(try String(contentsOf: main, encoding: .utf8) == "# Keys\nexport STRIPE_KEY=\"sk_test_a\\$b'c\"\nOTHER=1\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.root.appendingPathComponent(".env").path) == main.path)
        #expect((try FileManager.default.attributesOfItem(atPath: main.path)[.posixPermissions] as? Int) == 0o640)
        let fresh = fixture.root.appendingPathComponent("fresh/.env")
        #expect(try String(contentsOf: fresh, encoding: .utf8) == "STRIPE_KEY=\"sk_test_a\\$b'c\"\n")
        #expect((try FileManager.default.attributesOfItem(atPath: fresh.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("key.txt"), encoding: .utf8) == secret)
        #expect(try String(contentsOf: piped, encoding: .utf8) == secret)
        // The answer is gone from the mailbox.
        #expect(!FileManager.default.fileExists(atPath: fixture.ipc.resultURL(request.id).path))
    }

    @Test func plainValuesAreWrittenAsTheyAreAndQuotedOnlyWhenNeeded() throws {
        for (value, line) in [("sk_live_ABC-123/x=", "KEY=sk_live_ABC-123/x="), ("two words", "KEY='two words'")] {
            let fixture = try SecretFixture()
            let started = try fixture.start(["ask", "--title", "Key", "--name", "KEY", "--env-file", ".env"])
            defer { if started.0.isRunning { started.0.terminate() } }
            try fixture.answer(SecretResult(id: try SecretRequest.parse(fixture.request().data).id, value: value))
            #expect(fixture.finish(started).code == 0)
            #expect(try String(contentsOf: fixture.root.appendingPathComponent(".env"), encoding: .utf8) == line + "\n")
        }
    }

    @Test func theHelperSaysWhenTheOwnerCancelsOrThereIsNoPopup() throws {
        let fixture = try SecretFixture()
        let started = try fixture.start(["ask", "--title", "Key", "--file", "key.txt"])
        defer { if started.0.isRunning { started.0.terminate() } }
        try fixture.answer(SecretResult(id: try SecretRequest.parse(fixture.request().data).id, cancelled: true))
        let cancelled = fixture.finish(started)
        #expect(cancelled.code == 1 && cancelled.error.contains("Your owner cancelled: nothing was saved for Key."))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("key.txt").path))

        let next = try fixture.start(["ask", "--title", "Key", "--file", "key.txt"])
        defer { if next.0.isRunning { next.0.terminate() } }
        try fixture.answer(SecretResult(id: try SecretRequest.parse(fixture.request().data).id, errorMessage: "the asking turn has ended"))
        let failed = fixture.finish(next)
        #expect(failed.code == 1 && failed.error.contains("No popup: the asking turn has ended"))

        // Nowhere to put it, or a pipe that fails, is said without the value.
        let nowhere = fixture.finish(try fixture.start(["ask", "--title", "Key"]))
        #expect(nowhere.code == 1 && nowhere.error.contains("Say where it goes"))
        let unnamed = fixture.finish(try fixture.start(["ask", "--title", "Key", "--env-file", ".env"]))
        #expect(unnamed.code == 1 && unnamed.error.contains("--name"))
        let failing = try fixture.start(["ask", "--title", "Key", "--pipe", "cat; exit 3"])
        defer { if failing.0.isRunning { failing.0.terminate() } }
        try fixture.answer(SecretResult(id: try SecretRequest.parse(fixture.request().data).id, value: "hunter2"))
        let piped = fixture.finish(failing)
        #expect(piped.code == 1 && piped.error.contains("it exited with 3: [secret]") && !piped.error.contains("hunter2"))
    }

    @Test func aStoppedHelperClosesItsPopup() throws {
        let fixture = try SecretFixture()
        let started = try fixture.start(["ask", "--title", "Key", "--file", "key.txt"])
        defer { if started.0.isRunning { started.0.terminate() } }
        let request = try SecretRequest.parse(fixture.request().data)
        started.0.terminate()
        let stopped = fixture.finish(started)
        #expect(stopped.code == 128 + 15 && stopped.error.contains("stopped waiting"))
        let withdrawn = try SecretWithdrawal.parse(try fixture.request().data)
        #expect(withdrawn.request == request.id && withdrawn.invocationID == fixture.invocationID)
    }
}

/// The path with every link resolved, `/var` as `/private/var` too, as the helper resolves it.
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A mailbox and the helper as a turn has them, with the app's side played by the test.
private final class SecretFixture {
    let root: URL
    let ipc: SubagentIPC
    let bin: URL
    let botID = UUID()
    let invocationID = UUID()

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = folder.resolvingSymlinksInPath()
        ipc = SubagentIPC(root: root.appendingPathComponent("mailbox"))
        bin = root.appendingPathComponent("bin")
        try SubagentHookInstaller.install(binDirectory: bin)
        try ipc.prepare()
        try ipc.writeHeartbeat()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func start(_ arguments: [String], makeFolder: String? = nil) throws -> (Process, Pipe, Pipe) {
        if let makeFolder {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(makeFolder), withIntermediateDirectories: true)
        }
        let process = Process()
        process.executableURL = bin.appendingPathComponent("botchu-secret")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                               "BOTCHU_IPC_DIR": ipc.root.path, "BOTCHU_INVOCATION_ID": invocationID.uuidString,
                               "BOTCHU_CALLER_BOT_ID": botID.uuidString, "BOTCHU_CALLER_DEPTH": "0"]
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

    /// The request the helper wrote, once it has, taken out of the mailbox as BotChu takes it.
    func request() throws -> (file: URL, data: Data) {
        let deadline = Date().addingTimeInterval(5)
        while ipc.pendingRequests().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let request = try #require(ipc.pendingRequests().first)
        ipc.removeRequest(request.file)
        return request
    }

    func answer(_ result: SecretResult) throws {
        try SubagentIPC.encode(result).write(to: ipc.resultURL(result.id), options: .atomic)
    }
}
