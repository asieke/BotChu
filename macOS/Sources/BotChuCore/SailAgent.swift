import Foundation

/// One line the Sail helper prints, as `SailParser` reads it back.
public enum SailEvent: Equatable, Sendable {
    public enum FlexState: String, Sendable {
        /// Submitted, queued or running at Sail.
        case waiting
        /// Sail completed it.
        case done
        /// It ended without a usable result: incomplete, failed, cancelled, refused or gone.
        case failed
        /// BotChu stopped waiting; Sail may still finish it, and the next run picks it up.
        case detached
    }

    case session(String)
    /// The model Sail says ran the response.
    case model(String)
    case usage(TurnUsage)
    /// The row in the chat that follows one submission (`row` is its idempotency key).
    // Historical wire name retained for all completion windows.
    case flex(row: String, detail: String, state: FlexState)
    case text(String)
    case toolStarted(id: String, name: String, arguments: SailJSON)
    case toolFinished(id: String, name: String, output: String, isError: Bool, exitCode: Int?)
    case failed(String)
    case finished

    public var json: SailJSON {
        switch self {
        case .session(let id): return ["type": "session", "id": .string(id)]
        case .model(let id): return ["type": "model", "id": .string(id)]
        case .usage(let usage):
            let data = (try? JSONEncoder().encode(usage)) ?? Data()
            return ["type": "usage", "usage": (try? SailJSON.parse(data)) ?? .object([:])]
        case let .flex(row, detail, state): return ["type": "flex", "row": .string(row), "detail": .string(detail), "state": .string(state.rawValue)]
        case .text(let text): return ["type": "text", "text": .string(text)]
        case let .toolStarted(id, name, arguments): return ["type": "tool_start", "id": .string(id), "name": .string(name), "args": arguments]
        case let .toolFinished(id, name, output, isError, exitCode):
            var line: [String: SailJSON] = ["type": "tool_end", "id": .string(id), "name": .string(name), "output": .string(output), "is_error": .bool(isError)]
            if let exitCode { line["exit_code"] = .number(Double(exitCode)) }
            return .object(line)
        case .failed(let message): return ["type": "error", "message": .string(message)]
        case .finished: return ["type": "done"]
        }
    }

    /// One line of JSON.
    public var line: String { json.text }

    public init?(line: String) {
        guard line.hasPrefix("{"), let json = SailJSON.parse(line), let type = json["type"]?.string else { return nil }
        switch type {
        case "session": guard let id = json["id"]?.string else { return nil }; self = .session(id)
        case "model": guard let id = json["id"]?.string else { return nil }; self = .model(id)
        case "usage":
            guard let value = json["usage"], let usage = try? JSONDecoder().decode(TurnUsage.self, from: Data(value.text.utf8)) else { return nil }
            self = .usage(usage)
        case "flex":
            guard let row = json["row"]?.string, let state = json["state"]?.string.flatMap(FlexState.init(rawValue:)) else { return nil }
            self = .flex(row: row, detail: json["detail"]?.string ?? "", state: state)
        case "text": self = .text(json["text"]?.string ?? "")
        case "tool_start":
            guard let id = json["id"]?.string else { return nil }
            self = .toolStarted(id: id, name: json["name"]?.string ?? "Tool", arguments: json["args"] ?? .object([:]))
        case "tool_end":
            guard let id = json["id"]?.string else { return nil }
            self = .toolFinished(id: id, name: json["name"]?.string ?? "Tool", output: json["output"]?.string ?? "",
                                 isError: json["is_error"]?.bool ?? false, exitCode: json["exit_code"]?.int)
        case "error": self = .failed(json["message"]?.string ?? "The Sail agent failed.")
        case "done": self = .finished
        default: return nil
        }
    }
}

/// The Sail agent's system prompt: what it is, its tools, and the folder's own instructions
/// (`AGENTS.md`, else `CLAUDE.md`, from the folder up), as Pi and Codex read them.
public enum SailInstructions {
    static let contextLimit = 100_000

    public static func make(directory: URL, date: Date = Date(), fileManager: FileManager = .default) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy"
        var text = """
            You are a coding agent that BotChu runs on its owner's Mac, through Sail Research. You work in \
            \(directory.path), with four tools: read (read a file), write (create or replace a file), edit (replace \
            text in a file) and bash (run a command there).

            - Read a file before you edit it. Use edit for changes and write for new files or complete rewrites.
            - Use bash for the rest: listing and searching (ls, rg, find), git, builds and tests.
            - Requests on Balanced or Flex can wait in a queue, so work in fewer, larger steps: run independent \
            commands in one bash call where that is safe, and read what you need at once.
            - Keep going until the task is done. A reply without a tool call ends your turn and hands it back to \
            the owner, so never end one by saying what you'll do next: make the call instead.
            - Reply in Markdown, briefly: what you did, and anything left.

            Today is \(formatter.string(from: date)).
            """
        let files = contextFiles(from: directory, fileManager: fileManager)
        guard !files.isEmpty else { return text }
        text += "\n\n# Instructions from the working folder\n"
        var budget = contextLimit
        for (path, content) in files where budget > 0 {
            let kept = String(content.prefix(budget))
            budget -= kept.count
            text += "\n## \(path)\n\n\(kept)\n"
        }
        return text
    }

    /// Each folder's `AGENTS.md` (or its `CLAUDE.md` when it has none), outermost first.
    static func contextFiles(from directory: URL, fileManager: FileManager) -> [(String, String)] {
        var found: [(String, String)] = []
        var folder = directory.standardizedFileURL
        while true {
            for name in ["AGENTS.md", "CLAUDE.md"] {
                let file = folder.appendingPathComponent(name)
                if fileManager.fileExists(atPath: file.path) {
                    if let content = try? String(contentsOf: file, encoding: .utf8),
                       !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        found.append((file.path, content))
                    }
                    break
                }
            }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path == folder.path || folder.path == "/" { break }
            folder = parent
        }
        return found.reversed()
    }

    /// What BotChu says when a reply ends the turn by announcing a step it didn't take.
    static let keepGoing = """
        BotChu: your last reply said what you'd do next but called no tool, and a reply without a tool call ends \
        your turn. If there's more to do, make the call now. If you're done, reply with your final summary.
        """

    /// Whether a reply without a tool call stops short: empty, or ending by announcing its next step
    /// ("Now the two failing tests, one at a time:"), as some models do mid-task instead of calling
    /// the tool. A final answer doesn't read as one.
    public static func announcesNextStep(_ reply: String) -> Bool {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        if text.hasSuffix(":") || text.hasSuffix("…") || text.hasSuffix("...") { return true }
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        let start = body.lastIndex { ".!?\n".contains($0) }.map(body.index(after:)) ?? body.startIndex
        let sentence = body[start...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !sentence.hasPrefix("let me know") else { return false }
        return ["let me ", "now let me ", "next, let me ", "now i'll ", "next, i'll ", "next i'll ", "continuing "]
            .contains { sentence.hasPrefix($0) }
    }
}

/// One Sail turn, end to end: picks up a submission an earlier run left at Sail, adds the owner's
/// message, then submits the conversation in the chosen window, waits for the response, runs the tools
/// it calls and submits again, until it answers without one. The session is saved at each step.
public struct SailAgent: Sendable {
    public struct Turn: Sendable {
        public var sessionID: String
        /// The session must exist: BotChu resumes a conversation it started.
        public var resume: Bool
        public var model: String
        public var effort: String?
        public var completionWindow: SailCompletionWindow
        public var prompt: String
        public var images: [Data]

        public init(sessionID: String, resume: Bool, model: String, effort: String? = nil, completionWindow: SailCompletionWindow = .flex, prompt: String, images: [Data] = []) {
            self.sessionID = sessionID
            self.resume = resume
            self.model = model
            self.effort = effort
            self.completionWindow = completionWindow
            self.prompt = prompt
            self.images = images
        }
    }

    public var client: SailClient
    public var store: SailSessionStore
    public var toolbox: SailToolbox
    public var instructions: String
    public var live: SailLive?
    /// Requests one turn may make, as a guard against a model that never stops calling tools.
    public var maxRequests = 200
    /// Replies in a row that stop short (`SailInstructions.announcesNextStep`) and are asked to go
    /// on, before one is taken as the answer.
    public var maxNudges = 2
    public var newKey: @Sendable () -> String = { UUID().uuidString.lowercased() }
    public var now: @Sendable () -> Date = { Date() }

    public init(client: SailClient, store: SailSessionStore, toolbox: SailToolbox, instructions: String, live: SailLive? = nil) {
        self.client = client
        self.store = store
        self.toolbox = toolbox
        self.instructions = instructions
        self.live = live
    }

    /// The name of a submission's row in the chat.
    public static let rowName = "Sail"

    /// What the chat's row says once BotChu has stopped waiting.
    public static func detachedDetail(response: String?) -> String {
        let which = response.map { "response \($0)" } ?? "the submission"
        return "Stopped in BotChu only: Sail can't cancel \(which), so it may still finish and be billed. "
            + "The next message in this conversation picks it up."
    }

    /// Runs the turn, printing its events; true when it ended well.
    public func run(_ turn: Turn, emit: @escaping @Sendable (SailEvent) -> Void) async -> Bool {
        do {
            try await perform(turn, emit: emit)
            emit(.finished)
            return true
        } catch is CancellationError {
            return false
        } catch {
            emit(.failed((error as? SailFailure)?.message ?? error.localizedDescription))
            return false
        }
    }

    func perform(_ turn: Turn, emit: @escaping @Sendable (SailEvent) -> Void) async throws {
        var usage = TurnUsageAccumulator()
        // Emit once, including work consumed before a later response or tool failed.
        defer { if let value = usage.value { emit(.usage(value)) } }
        guard !client.key.isEmpty else {
            throw SailFailure(.key, "There's no Sail API key. Add yours in BotChu ▸ Settings ▸ Sail.")
        }
        let model = turn.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw SailFailure(.rejected, "No Sail model is chosen. Choose one in BotChu ▸ Settings ▸ Sail, or in this conversation's model menu.")
        }
        var session: SailSession
        if let saved = try store.load(turn.sessionID) {
            session = saved
        } else if turn.resume {
            throw SailFailure(.notFound, "This conversation's Sail session (\(turn.sessionID)) is no longer on this Mac, so it can't go on. Start a new conversation.")
        } else {
            session = SailSession(id: turn.sessionID, updatedAt: now())
        }

        if let pending = session.pending { try await pickUp(pending, in: &session, usage: &usage, emit: emit) }
        closeUnansweredCalls(in: &session)
        session.items.append(SailRequest.userMessage(turn.prompt, images: turn.images))
        try save(&session)
        emit(.session(session.id))

        var reportedModel: String?
        var nudges = 0
        for _ in 0..<maxRequests {
            let response = try await submitAndWait(model: model, effort: turn.effort, completionWindow: turn.completionWindow, session: &session, emit: emit)
            if var reported = response.turnUsage {
                for index in reported.models.indices { reported.models[index].sailCompletionWindow = turn.completionWindow }
                usage.add(reported)
            }
            if let ran = response.model, ran != reportedModel {
                reportedModel = ran
                emit(.model(ran))
            }
            switch response.status {
            case .completed:
                let calls = try record(response, in: &session, includeCalls: true, emit: emit)
                if calls.isEmpty {
                    // A reply announcing its next step without the call would end the turn
                    // mid-task, so the model is asked to go on, or to say it's done.
                    guard nudges < maxNudges, SailInstructions.announcesNextStep(response.texts.last ?? "") else { return }
                    nudges += 1
                    session.items.append(SailRequest.userMessage(SailInstructions.keepGoing))
                    try save(&session)
                    continue
                }
                nudges = 0
                for call in calls {
                    try Task.checkCancellation()
                    emit(.toolStarted(id: call.callID, name: call.name, arguments: SailJSON.parse(call.arguments) ?? .string(call.arguments)))
                    let result = await toolbox.run(call)
                    emit(.toolFinished(id: call.callID, name: call.name, output: result.output, isError: result.isError, exitCode: result.exitCode))
                    session.items.append(SailRequest.functionOutput(callID: call.callID, output: result.output))
                    try save(&session)
                }
            case .incomplete:
                _ = try record(response, in: &session, includeCalls: false, emit: emit)
                throw SailFailure(.rejected, "Sail stopped response \(response.id) before it finished (\(response.incompleteReason ?? "no reason given")). What it wrote is above; send a message to go on.")
            case .failed:
                try settle(&session)
                let said = response.errorMessage ?? response.errorCode ?? "no reason given"
                if SailHTTP.isAboutFlex(said + " " + (response.errorCode ?? "")) {
                    throw SailFailure(.flex, SailHTTP.flexRefusal(model: model, said: "response \(response.id) failed: \(said)", completionWindow: turn.completionWindow))
                }
                throw SailFailure(.rejected, "Sail couldn't complete response \(response.id): \(said).")
            case .cancelled:
                try settle(&session)
                throw SailFailure(.rejected, "Sail cancelled response \(response.id). BotChu never asks it to; check the Sail dashboard.")
            case .queued, .inProgress, .other:
                throw SailFailure(.malformed, "Sail's response \(response.id) ended without a final status.")
            }
        }
        throw SailFailure(.rejected, "This turn made \(maxRequests) requests to Sail without a final answer, so BotChu stopped it. Send a message to go on.")
    }

    // MARK: Submissions

    /// Submits the conversation as it stands and waits for Sail to finish the response.
    func submitAndWait(model: String, effort: String?, completionWindow: SailCompletionWindow = .flex, session: inout SailSession, emit: @escaping @Sendable (SailEvent) -> Void) async throws -> SailResponse {
        let body = SailRequest.body(model: model, instructions: instructions, input: session.items, tools: SailToolbox.definitions, effort: effort, completionWindow: completionWindow)
        let key = newKey()
        let started = now()
        session.pending = SailPending(idempotencyKey: key, body: body, model: model, submittedAt: started)
        // Saved before it is sent: a run that ends now sends it again, with the same key.
        try save(&session)
        live?.submitted(row: key, response: nil)
        emit(.flex(row: key, detail: "Submitting to Sail \(completionWindow.title) · \(model)", state: .waiting))
        return try await send(session.pending!, in: &session, emit: emit)
    }

    /// Sends a pending submission (again, with its key, when it has no response yet) and waits.
    private func send(_ pending: SailPending, in session: inout SailSession, emit: @escaping @Sendable (SailEvent) -> Void) async throws -> SailResponse {
        let row = pending.idempotencyKey
        let model = pending.model
        let completionWindow = SailCompletionWindow.from(pending.body)
        var response: SailResponse
        if let id = pending.responseID {
            // As last seen; the first poll says how it stands now.
            response = SailResponse(id: id, status: SailStatus(pending.status) == .inProgress ? .inProgress : .queued)
        } else {
            do {
                response = try await client.submit(pending.body, idempotencyKey: row, model: model) { progress in
                    if case let .retrying(reason, wait) = progress {
                        emit(.flex(row: row, detail: "Submitting to Sail \(completionWindow.title) · \(model) · trying again in \(Self.duration(wait)) after \(reason)", state: .waiting))
                    }
                }
            } catch let failure as SailFailure where failure.kind != .unavailable && failure.kind != .malformed {
                // Refused outright: nothing is running at Sail. An unreadable answer to a submission
                // Sail may have taken stays pending, for the next run to send again with its key.
                try settle(&session)
                emit(.flex(row: row, detail: "Refused by Sail · \(model)", state: .failed))
                throw failure
            }
            session.pending?.responseID = response.id
            session.pending?.status = response.status.raw
            try save(&session)
            live?.submitted(row: row, response: response.id)
        }
        let id = response.id
        let since = pending.submittedAt
        if !response.status.isTerminal {
            emit(.flex(row: row, detail: Self.waitingDetail(response.status, id: id, model: model, completionWindow: completionWindow), state: .waiting))
            let seen = SailSeen(response.status)
            do {
                response = try await client.wait(for: response) { progress in
                    switch progress {
                    case .status(let next):
                        seen.status = next.status
                        // The end is reported below, with what it took.
                        if !next.status.isTerminal {
                            emit(.flex(row: row, detail: Self.waitingDetail(next.status, id: id, model: model, completionWindow: completionWindow), state: .waiting))
                        }
                    case let .retrying(reason, wait):
                        emit(.flex(row: row, detail: Self.waitingDetail(seen.status, id: id, model: model, completionWindow: completionWindow)
                                   + " · checking again in \(Self.duration(wait)) after \(reason)", state: .waiting))
                    }
                }
            } catch let failure as SailFailure where failure.kind == .notFound {
                try settle(&session)
                emit(.flex(row: row, detail: "Gone from Sail · \(id)", state: .failed))
                throw failure
            }
        }
        live?.settled()
        let took = Self.duration(now().timeIntervalSince(since))
        switch response.status {
        case .completed:
            emit(.flex(row: row, detail: "Completed on Sail \(completionWindow.title) · \(id) · \(took)" + Self.tokens(response), state: .done))
        case .incomplete:
            emit(.flex(row: row, detail: "Incomplete · \(id) · \(response.incompleteReason ?? "no reason given")", state: .failed))
        case .failed:
            emit(.flex(row: row, detail: "Failed at Sail · \(id) · \(response.errorMessage ?? response.errorCode ?? "no reason given")", state: .failed))
        case .cancelled:
            emit(.flex(row: row, detail: "Cancelled by Sail · \(id)", state: .failed))
        case .queued, .inProgress, .other:
            break
        }
        return response
    }

    /// Picks up a submission an earlier run left: its response is waited for and kept, but the tools
    /// it calls aren't run, as the turn that asked for them was stopped or ended. The model hears
    /// so, and calls them again if they're still needed.
    func pickUp(_ pending: SailPending, in session: inout SailSession, usage: inout TurnUsageAccumulator, emit: @escaping @Sendable (SailEvent) -> Void) async throws {
        let row = pending.idempotencyKey
        let completionWindow = SailCompletionWindow.from(pending.body)
        let what = pending.responseID.map { "response \($0)" } ?? "the earlier submission"
        emit(.flex(row: row, detail: "Picking up \(what), submitted \(Self.clock(pending.submittedAt)), on Sail \(completionWindow.title)", state: .waiting))
        live?.submitted(row: row, response: pending.responseID)
        let response: SailResponse
        do {
            response = try await send(pending, in: &session, emit: emit)
        } catch let failure as SailFailure where failure.kind == .notFound || failure.kind == .rejected || failure.kind == .flex {
            // That submission is over; the owner's new message goes on without it.
            if session.pending != nil {
                try settle(&session)
                emit(.flex(row: row, detail: "Couldn't pick up \(what): \(failure.message)", state: .failed))
            }
            return
        }
        if var reported = response.turnUsage {
            for index in reported.models.indices { reported.models[index].sailCompletionWindow = completionWindow }
            usage.add(reported)
        }
        switch response.status {
        case .completed:
            let calls = try record(response, in: &session, includeCalls: true, emit: emit)
            for call in calls {
                let note = "Not run: BotChu stopped before running this call (the owner pressed Stop, or BotChu quit). Call it again if it's still needed."
                emit(.toolStarted(id: call.callID, name: call.name, arguments: SailJSON.parse(call.arguments) ?? .string(call.arguments)))
                emit(.toolFinished(id: call.callID, name: call.name, output: note, isError: true, exitCode: nil))
                session.items.append(SailRequest.functionOutput(callID: call.callID, output: note))
            }
            try save(&session)
        case .incomplete:
            _ = try record(response, in: &session, includeCalls: false, emit: emit)
        default:
            try settle(&session)
        }
    }

    /// Answers calls an earlier run left without an output, which it may have partly run.
    func closeUnansweredCalls(in session: inout SailSession) {
        for call in session.unansweredCalls {
            session.items.append(SailRequest.functionOutput(callID: call.callID, output: """
                Interrupted: BotChu stopped while this call was running, so it may have partly run. Check its effects before \
                calling it again.
                """))
        }
    }

    /// Adds a finished response's output to the conversation, ends its submission and shows its text.
    @discardableResult
    func record(_ response: SailResponse, in session: inout SailSession, includeCalls: Bool, emit: @Sendable (SailEvent) -> Void) throws -> [SailFunctionCall] {
        let items = response.conversationItems.filter { includeCalls || $0["type"]?.string != "function_call" }
        session.items += items
        try settle(&session)
        for text in response.texts { emit(.text(text)) }
        return includeCalls ? response.functionCalls : []
    }

    private func settle(_ session: inout SailSession) throws {
        session.pending = nil
        live?.settled()
        try save(&session)
    }

    private func save(_ session: inout SailSession) throws {
        session.updatedAt = now()
        try store.save(session)
    }

    // MARK: Wording

    static func waitingDetail(_ status: SailStatus, id: String, model: String, completionWindow: SailCompletionWindow = .flex) -> String {
        switch status {
        case .inProgress: "Running on Sail \(completionWindow.title) · \(id) · \(model)"
        case .queued: "Queued on Sail \(completionWindow.title) · \(id) · \(model)"
        default: "\(status.label.prefix(1).uppercased() + status.label.dropFirst()) on Sail \(completionWindow.title) · \(id) · \(model)"
        }
    }

    static func tokens(_ response: SailResponse) -> String {
        guard let input = response.inputTokens, let output = response.outputTokens else { return "" }
        return " · \(input) in, \(output) out"
    }

    /// `45 s`, `3 min 12 s`, `2 h 5 min`.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        if total < 3_600 { return "\(total / 60) min" + (total % 60 == 0 ? "" : " \(total % 60) s") }
        return "\(total / 3_600) h" + ((total % 3_600) / 60 == 0 ? "" : " \((total % 3_600) / 60) min")
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

/// The status a wait last saw, for the progress it reports from its `@Sendable` callback.
private final class SailSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SailStatus

    init(_ status: SailStatus) { current = status }

    var status: SailStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}
