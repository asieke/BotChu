import Foundation

/// One headless CLI process for one turn. It runs the account's command through the login shell
/// (`zsh -l`, so PATH and Homebrew are the user's), in the bot's workspace, with stdin closed, or
/// open for a CLI that takes input mid-turn (`Invocation.input`, This Mac only). On a host it runs
/// there over SSH, through that user's login shell, and only its output comes back.
/// Complete stdout lines and the exit are delivered on the main queue.
public final class AgentRun: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    /// The CLI's stdin, while it takes input; written on `inputQueue`, in order.
    private var stdin: Pipe?
    private let initialInput: [String]
    private let inputQueue = DispatchQueue(label: "BotChu.AgentRun.input")
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()
    public private(set) var stopped = false
    /// Whether `send` can still write to the CLI: its stdin is open and the run hasn't stopped.
    public var acceptsInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdin != nil && !stopped
    }
    /// The host it runs on, and the CLI's process there, once it has said which.
    private let remote: Machine?
    private var remotePID: String?

    public var onLines: ([String]) -> Void = { _ in }
    public var onExit: (_ status: Int32, _ stderr: String) -> Void = { _, _ in }

    /// The line a run on a host prints first, with the CLI's process id there.
    static let pidMarker = "__BOTCHU_PID__"

    public init(command: String, invocation: Invocation, directory: URL) {
        remote = nil
        initialInput = invocation.input ?? []
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", Self.delegationShellPrefix(invocation.environment) + CommandBuilder.shellScript(command: command), "botchu"] + invocation.arguments
        process.currentDirectoryURL = directory
        var env = Self.childEnvironment(ProcessInfo.processInfo.environment)
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (key, value) in invocation.environment { env[key] = value }
        process.environment = env
        attachInput(invocation)
    }

    /// A run in `folder` on a host. Only the explicit delegation context crosses SSH; credentials
    /// such as the OpenRouter key stay on this Mac, so a CLI there uses that machine's own.
    public init(command: String, invocation: Invocation, on machine: Machine, folder: String) {
        remote = machine
        initialInput = invocation.input ?? []
        process.executableURL = URL(fileURLWithPath: Machine.ssh)
        let script = "export NO_COLOR=1 TERM=dumb; " + Self.delegationShellPrefix(invocation.environment)
            + "printf '%s %s\\n' \(Self.pidMarker) \"$$\"; "
            + CommandBuilder.shellScript(command: command)
        process.arguments = Machine.sshOptions + [machine.destination ?? "",
                                                  Machine.remoteCommand(script: script, arguments: invocation.arguments, in: folder)]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        process.environment = Self.childEnvironment(ProcessInfo.processInfo.environment)
        attachInput(invocation)
    }

    /// stdin is closed, or a pipe for a CLI that takes input (ssh forwards it to a host).
    private func attachInput(_ invocation: Invocation) {
        if invocation.input != nil {
            let pipe = Pipe()
            // A CLI that has exited must not take BotChu with it: writing then fails with EPIPE
            // instead of raising SIGPIPE.
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            stdin = pipe
            process.standardInput = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = stdout
        process.standardError = stderr
    }

    /// The environment a CLI starts from: BotChu's own, without the variables an agent session sets
    /// for the processes under it. When BotChu itself was opened from inside Claude Code or Codex,
    /// those would make each bot's CLI act as a nested child of that session (Claude Code then waits
    /// on its parent's auth and messaging sockets) or use its account.
    public static func childEnvironment(_ env: [String: String]) -> [String: String] {
        let prefixes = ["CLAUDE", "CODEX_", "ANTHROPIC_", "OPENAI_", "BOTCHU_", "MCP_", "AI_AGENT"]
        let names: Set<String> = ["API_TIMEOUT_MS", "BAGGAGE", "DISABLE_AUTOUPDATER", "DISABLE_MICROCOMPACT",
                                  "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH", "OPENROUTER_API_KEY"]
        return env.filter { key, _ in !names.contains(key) && !prefixes.contains(where: key.hasPrefix) }
    }

    /// Login shell files can replace PATH. Install the helper path afterwards, and export only
    /// these coordinator-owned values on remote hosts, never the invocation's API credentials.
    static func delegationShellPrefix(_ environment: [String: String]) -> String {
        let names = ["BOTCHU_INVOCATION_ID", "BOTCHU_CALLER_BOT_ID", "BOTCHU_CALLER_TASK_ID",
                     "BOTCHU_CALLER_SUBAGENT_ID", "BOTCHU_CALLER_DEPTH", "BOTCHU_IPC_DIR", "BOTCHU_BIN_DIR"]
        var script = names.compactMap { name in
            environment[name].map { "export \(name)=\(Shell.quote($0)); " }
        }.joined()
        if let directory = environment["BOTCHU_BIN_DIR"], !directory.isEmpty {
            script += "export PATH=\(Shell.quote(directory)):\"$PATH\"; "
        }
        return script
    }

    public func start() throws {
        let group = DispatchGroup()
        group.enter()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
                return
            }
            let lines = self.takeLines(appending: data)
            if !lines.isEmpty { DispatchQueue.main.async { self.onLines(lines) } }
        }
        group.enter()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
                return
            }
            self.lock.lock()
            self.errorTail.append(data)
            if self.errorTail.count > 16_384 { self.errorTail = self.errorTail.suffix(8_192) }
            self.lock.unlock()
        }
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        try process.run()
        for line in initialInput { send(line) }
        group.notify(queue: .main) { [self] in
            closeInput()
            let rest = takeLines(appending: Data("\n".utf8))
            if !rest.isEmpty { onLines(rest) }
            lock.lock()
            let tail = String(decoding: errorTail, as: UTF8.self)
            lock.unlock()
            onExit(process.terminationStatus, tail)
        }
    }

    /// Writes one line to the CLI's stdin, after the lines written before it. False when the CLI
    /// doesn't take input (any more): its stdin was never open, or was closed, or it was stopped.
    @discardableResult
    public func send(_ line: String) -> Bool {
        lock.lock()
        let handle = stopped ? nil : stdin?.fileHandleForWriting
        lock.unlock()
        guard let handle else { return false }
        // Off the main thread: a long prompt can fill the pipe before the CLI reads it.
        inputQueue.async { try? handle.write(contentsOf: Data((line + "\n").utf8)) }
        return true
    }

    /// Closes the CLI's stdin once what was written has gone, so it ends when it has nothing left
    /// to do. Nothing can be sent after this.
    public func closeInput() {
        lock.lock()
        let pipe = stdin
        stdin = nil
        lock.unlock()
        guard let pipe else { return }
        inputQueue.async { try? pipe.fileHandleForWriting.close() }
    }

    /// Interrupts the CLI as Ctrl-C would, then terminates it if it is still running. On a host,
    /// the CLI there is interrupted too: closing the connection alone would leave it running.
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        closeInput()
        guard process.isRunning else { return }
        lock.lock()
        let pid = remotePID
        lock.unlock()
        if let remote, let pid {
            Task.detached {
                _ = await remote.run(["kill", "-INT", pid], in: "~")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                _ = await remote.run(["kill", "-TERM", pid], in: "~")
            }
        }
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + (remote == nil ? 3 : 5)) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func takeLines(appending data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if remote != nil, remotePID == nil, line.hasPrefix(Self.pidMarker + " ") {
                remotePID = String(line.dropFirst(Self.pidMarker.count + 1)).trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}

/// Whether an account's command can be found by the login shell.
public enum CommandCheck {
    public static func isAvailable(_ command: String) async -> Bool {
        let word = command.split(separator: " ").first.map(String.init) ?? command
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "command -v \(word) >/dev/null 2>&1"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
