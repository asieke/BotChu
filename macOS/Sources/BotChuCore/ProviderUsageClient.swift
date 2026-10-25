import Foundation

/// A query follows the same configured profile command as the bot. No credentials are cache keys.
public struct UsageRequest: Hashable, Sendable, Codable {
    public var account: Account
    public var command: String
    public var credentialRevision: Int

    public init(account: Account, command: String, credentialRevision: Int = 0) {
        self.account = account
        self.command = command
        self.credentialRevision = credentialRevision
    }

    public var refreshInterval: TimeInterval { account.kind == .muse ? 3_600 : 300 }
    /// How often the app checks while Providers isn't showing, so it opens on current numbers;
    /// a reading older than this is stale there.
    public var backgroundInterval: TimeInterval { account.kind == .muse ? 3_600 : 900 }
    public var manualInterval: TimeInterval { account.kind == .muse ? 300 : 30 }
}

public enum ProviderUsageClient {
    public static func read(_ request: UsageRequest, openRouterKey: String? = nil) async throws -> ProviderUsage {
        if request.account.kind == .pi {
            guard let key = openRouterKey, !key.isEmpty else {
                throw UsageFailure("Add an OpenRouter API key in Settings to see its allowance.")
            }
            return try await OpenRouterUsage.read(key: key)
        }
        return try await Task.detached(priority: .utility) { try readCLI(request) }.value
    }

    private static func readCLI(_ request: UsageRequest) throws -> ProviderUsage {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let kind = request.account.kind
        let arguments: [String]
        switch kind {
        case .claude:
            arguments = ["--safe-mode", "-p", "/usage", "--tools", "", "--max-turns", "1",
                         "--no-session-persistence", "--output-format", "json"]
        case .codex: arguments = ["app-server"]
        case .antigravity: arguments = ["-p", "/usage", "--output-format", "json", "--log-file", "/dev/null"]
        case .muse: arguments = ["serve", "--no-session-log"]
        case .pi: throw UsageFailure.unrecognized
        }
        let process = try UsageProcess(command: request.command, arguments: arguments, directory: dir,
            environment: kind == .muse ? ["XDG_DATA_HOME": dir.appendingPathComponent("data").path] : [:],
            timeout: kind == .muse ? 90 : 40)
        defer { process.stop() }
        switch kind {
        case .claude: return try UsageParser.claude(process.output())
        case .antigravity: return try UsageParser.antigravity(process.output())
        case .codex, .muse:
            _ = try process.call("initialize", ["clientInfo": ["name": "botchu", "title": "BotChu", "version": "1"], "capabilities": [:]])
            try process.send(["jsonrpc": "2.0", "method": "initialized"])
            if kind == .codex {
                return try UsageParser.codex(JSONSerialization.data(withJSONObject: process.call("account/rateLimits/read")))
            }
            return try museUsage(process, workspace: dir.path)
        case .pi: throw UsageFailure.unrecognized
        }
    }

    /// Muse keeps usage in its host's memory and learns it from a model response. First ask
    /// passively; if empty, use one tiny turn in throwaway state, never a bot session. The reading
    /// comes as `usage/changed`, or in `usage/read`, from the answer onwards, but often only when
    /// the turn winds down after it, seconds or much later. So keep listening, ask every `poll`
    /// seconds from the answer on, and a few times more once the turn has ended; the process's
    /// deadline bounds it all.
    static func museUsage(_ process: UsageProcess, workspace: String, poll: TimeInterval = 1) throws -> ProviderUsage {
        if let reading = try museRead(process) { return reading }
        let session = try process.call("session/start", ["commandId": uuidV7(), "workspaceRoot": workspace])
        guard let id = (session["session"] as? [String: Any])?["sessionId"] as? String else { throw UsageFailure.unrecognized }
        _ = try process.call("turn/start", ["commandId": uuidV7(), "sessionId": id, "reasoningEffort": "none",
            "input": [["type": "text", "text": "Reply with OK."]]])
        var nextAsk = Date.distantFuture
        var endSeen = false
        var asksAfterEnd = 0
        while process.museReading == nil {
            if process.museAnswered, nextAsk == .distantFuture { nextAsk = Date() }
            if process.museEnded != nil, !endSeen {
                endSeen = true
                nextAsk = Date()
            }
            if Date() >= nextAsk {
                if let reading = try museRead(process) { return reading }
                if endSeen { asksAfterEnd += 1 }
                if asksAfterEnd >= 5 { break }
                nextAsk = Date().addingTimeInterval(poll)
            }
            _ = try process.next(until: nextAsk)
        }
        if let reading = process.museReading { return reading }
        throw UsageFailure(process.museEnded == "turn/failed" ? "Muse could not answer its usage check. Check its sign-in and allowance, then refresh."
            : "Muse did not return account usage. Try refreshing later.")
    }

    /// One `usage/read`. A reading `usage/changed` brought while waiting for the answer stays,
    /// even when the answer itself is still empty.
    private static func museRead(_ process: UsageProcess) throws -> ProviderUsage? {
        let result = try process.call("usage/read")
        if let data = try? JSONSerialization.data(withJSONObject: result), let reading = try? UsageParser.muse(data) {
            process.museReading = reading
        }
        return process.museReading
    }

    /// Muse's command IDs are time-ordered UUIDs (v7).
    private static func uuidV7() -> String {
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let ms = UInt64(Date().timeIntervalSince1970 * 1_000)
        for i in 0..<6 { bytes[i] = UInt8(truncatingIfNeeded: ms >> (8 * (5 - i))) }
        bytes[6] = bytes[6] & 0x0F | 0x70
        bytes[8] = bytes[8] & 0x3F | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map {
            String(hex[hex.index(hex.startIndex, offsetBy: $0.lowerBound)..<hex.index(hex.startIndex, offsetBy: $0.upperBound)])
        }.joined(separator: "-")
    }
}

/// A bounded native CLI query. All raw output stays in memory; stderr is discarded. A deadline
/// kills even an unresponsive CLI, and the host is reaped on success, parse failure or timeout.
final class UsageProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), stdout = Pipe()
    private let lock = NSLock()
    private var timer: DispatchWorkItem?
    private var timedOut = false
    private var buffer = Data()
    private var requestID = 0
    private let deadline: Date
    /// What Muse announces, also while a call waits for its answer: usage, and how its turn went.
    var museReading: ProviderUsage?
    var museAnswered = false
    var museEnded: String?

    init(command: String, arguments: [String], directory: URL, environment: [String: String] = [:], timeout: TimeInterval) throws {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", CommandBuilder.shellScript(command: command), "botchu-usage"] + arguments
        process.currentDirectoryURL = directory
        process.environment = AgentRun.childEnvironment(ProcessInfo.processInfo.environment)
            .merging(["NO_COLOR": "1", "TERM": "dumb"]) { $1 }.merging(environment) { $1 }
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw UsageFailure("Could not start the account’s CLI. Check its command in Settings.") }
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.timedOut = true
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
        }
        self.timer = timer
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    func stop() {
        lock.lock()
        timer?.cancel()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        lock.unlock()
        process.waitUntilExit()
        try? input.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
    }

    private func failure() -> UsageFailure {
        lock.lock()
        defer { lock.unlock() }
        return UsageFailure(timedOut ? "Usage check timed out. Try refreshing later."
            : "Could not read account usage. Check the CLI’s sign-in and command, then refresh.")
    }

    func output() throws -> Data {
        try input.fileHandleForWriting.close()
        var data = Data()
        while true {
            guard let chunk = try chunk() else { continue }
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= 2 << 20 else { throw UsageFailure.unrecognized }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure() }
        return data
    }

    /// poll also bounds a read when a broken wrapper leaves a child holding stdout open after
    /// its parent exits. Killing the parent alone cannot close that inherited pipe. Nil once
    /// `until` passes with nothing to read; only the deadline is a failure.
    private func chunk(until soft: Date = .distantFuture) throws -> Data? {
        var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            if Date() >= soft { return nil }
            let result = poll(&descriptor, 1, Int32(max(1, min(200, soft.timeIntervalSinceNow * 1_000))))
            if result > 0 {
                // read(upToCount:) can wait to fill its requested size on macOS. RPC hosts
                // keep stdout open between frames, so consume just the bytes available now.
                return stdout.fileHandleForReading.availableData
            }
            if result < 0 && errno != EINTR { throw failure() }
        }
        throw UsageFailure("Usage check timed out. Try refreshing later.")
    }

    func send(_ frame: [String: Any]) throws {
        do { try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: frame) + Data([10])) }
        catch { throw failure() }
    }

    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        requestID += 1
        try send(["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])
        while true {
            guard let frame = try next(), frame["id"] as? Int == requestID else { continue }
            if let error = frame["error"], !(error is NSNull) { throw failure() }
            guard let result = frame["result"] as? [String: Any] else { throw UsageFailure.unrecognized }
            return result
        }
    }

    /// The next frame, remembering what Muse announces; nil once `until` passes first.
    func next(until soft: Date = .distantFuture) throws -> [String: Any]? {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                guard let frame = try? UsageParser.object(line) else { continue }
                switch frame["method"] as? String {
                case "usage/changed":
                    if let params = frame["params"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: params),
                       let reading = try? UsageParser.muse(data) { museReading = reading }
                case "turn/foregroundCompleted": museAnswered = true
                case let method? where method == "turn/completed" || method == "turn/failed":
                    museAnswered = true
                    museEnded = museEnded ?? method
                default: break
                }
                return frame
            }
            guard let chunk = try chunk(until: soft) else { return nil }
            guard !chunk.isEmpty else { throw failure() }
            buffer.append(chunk)
            guard buffer.count <= 2 << 20 else { throw UsageFailure.unrecognized }
        }
    }
}

private final class OpenRouterUsage: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func read(key: String) async throws -> ProviderUsage {
        let delegate = OpenRouterUsage()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw UsageFailure("Could not reach OpenRouter. Try refreshing later.") }
        guard let http = response as? HTTPURLResponse else { throw UsageFailure.unrecognized }
        switch http.statusCode {
        case 200: return try UsageParser.openRouter(data)
        case 401, 403: throw UsageFailure("Check the OpenRouter API key in Settings, then refresh.")
        case 429:
            let seconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw UsageFailure("OpenRouter is limiting usage checks. Try again later.", retryAfter: max(300, seconds ?? 300))
        default: throw UsageFailure("OpenRouter usage is unavailable (HTTP \(http.statusCode)).")
        }
    }
}
