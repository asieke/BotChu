import Foundation

/// One headless CLI process for one turn. It runs the account's command through the login shell
/// (`zsh -l`, so PATH and Homebrew are the user's), in the bot's workspace, with stdin closed, or
/// open for a CLI that takes input mid-turn (`Invocation.input`, This Mac only). On a host it runs
/// there over SSH, through that user's login shell, and only its output comes back.
/// Complete stdout lines (or, with `deliverEvents`, the events parsed from them off the main
/// thread) and the exit are delivered on the main queue. Output that arrives within
/// `deliveryInterval` of the last delivery waits and goes with the next one, so a fast stream
/// costs the main thread a few updates a second rather than one per read; everything is delivered,
/// in order, before the exit.
public final class AgentRun: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let input: Data?
    /// The CLI's stdin, while it takes input; written on `inputQueue`, in order.
    private var stdin: Pipe?
    private let initialInput: [String]
    private let inputQueue = DispatchQueue(label: "BotChu.AgentRun.input")
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()
    public private(set) var stopped = false
    /// How long a CLI may go on running once it has said its turn ended and has nothing more to
    /// read. CLIs exit within a second of their last event; one still running then is ended, and
    /// its turn stands as it said (#145: Antigravity printed its result and never exited, so a
    /// sub-agent whose handoff was written stayed running for hours).
    public var lingerLimit: TimeInterval = AgentRun.defaultLingerLimit
    /// `lingerLimit` for the runs made from now on; tests shorten it.
    nonisolated(unsafe) public static var defaultLingerLimit: TimeInterval = 30
    /// How long a CLI may go on running after its turn while its background tasks run: it waits
    /// for them, then carries on with their results (#255: Claude Code waiting on a full test run
    /// was ended 30 s after its reply, test run and all).
    public var backgroundLimit: TimeInterval = 2 * 60 * 60
    /// How long after SIGTERM a CLI still running is killed, with its process group.
    public var killDelay: TimeInterval = 5
    /// Whether BotChu ended the CLI because it was still running `lingerLimit` after its turn
    /// ended. It wasn't stopped: its turn ended as it said, though its exit status is a signal's.
    public private(set) var lingered = false
    /// Whether it lingered while its background tasks still ran, so they ended unfinished with it.
    public private(set) var endedBackgroundTasks = false
    /// Whether the CLI said its turn ended (`.finished`) and hasn't carried on since, how many
    /// background tasks it has running, which wait for its exit is the current one and how long
    /// that wait is; guarded by `lock`.
    private var turnEnded = false
    private var backgroundTasks = 0
    private var exitWatch = 0
    private var exitWait: TimeInterval = 0
    /// The shortest time between two deliveries to the main queue.
    public var deliveryInterval: TimeInterval = 0.04
    /// Parses stdout off the main thread, when set (`deliverEvents`); guarded by `parseLock`.
    private var parser: (any StreamParser)?
    private let parseLock = NSLock()
    private var onEvents: (([AgentEvent]) -> Void)?
    /// Output not delivered yet, and whether a delivery is on its way; guarded by `lock`.
    private var pendingLines: [String] = []
    private var pendingEvents: [AgentEvent] = []
    private var deliveryScheduled = false
    private var lastDelivery: UInt64 = 0
    /// The CLI's first output is delivered even when it holds no events (`onEvents([])`): it has
    /// started, whatever it printed.
    private var printed = false
    private var announcePrinted = false
    /// Whether `send` can still write to the CLI: its stdin is open and the run hasn't stopped.
    public var acceptsInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stdin != nil && !stopped
    }
    /// The host it runs on, and the CLI's process there, once it has said which.
    private let remote: Machine?
    private var remotePID: String?

    /// The process's priority; background work (run reviews) runs at `.utility`. Set before `start`.
    public var qualityOfService: QualityOfService {
        get { process.qualityOfService }
        set { process.qualityOfService = newValue }
    }

    public var onLines: ([String]) -> Void = { _ in }
    public var onExit: (_ status: Int32, _ stderr: String) -> Void = { _, _ in }

    /// The line a run on a host prints first, with the CLI's process id there.
    static let pidMarker = "__BOTCHU_PID__"

    public init(command: String, invocation: Invocation, directory: URL) {
        input = invocation.standardInput
        remote = nil
        initialInput = invocation.input ?? []
        // Under the tool policy's profile, when it blocks any tool (#246).
        let launch = ToolSandbox.launch("/bin/zsh", ["-l", "-c", Self.profileShellPrefix(invocation.environment, unset: invocation.unsetEnvironment)
                                                     + Self.delegationShellPrefix(invocation.environment) + CommandBuilder.shellScript(command: command),
                                                     "botchu"] + invocation.arguments, profile: invocation.toolProfile)
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = directory
        var env = Self.childEnvironment(ProcessInfo.processInfo.environment)
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env.merge(Self.profileEnvironment(invocation.environment)) { _, value in value }
        process.environment = env
        attachInput(invocation)
    }

    /// A run in `folder` on a host. Only the explicit delegation context crosses SSH; credentials
    /// such as the OpenRouter key stay on this Mac, so a CLI there uses that machine's own.
    public init(command: String, invocation: Invocation, on machine: Machine, folder: String) {
        input = invocation.standardInput
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
        let prefixes = ["CLAUDE", "CODEX_", "ANTHROPIC_", "OPENAI_", "BOTCHU_", "MCP_", "AI_AGENT", "AZURE_OPENAI_"]
        let names: Set<String> = ["API_TIMEOUT_MS", "BAGGAGE", "DISABLE_AUTOUPDATER", "DISABLE_MICROCOMPACT",
                                  "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "PI_PACKAGE_DIR"]
        return env.filter { key, _ in !names.contains(key) && !modelCredentialNames.contains(key) && !prefixes.contains(where: key.hasPrefix) }
    }

    /// Credentials for the installed runtimes' model services. A profile command can explicitly
    /// supply its own after the shell starts; another agent's or global shell's keys are not its login.
    public static let modelCredentialNames: Set<String> = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN",
                                  "OPENAI_API_KEY", "OPENROUTER_API_KEY", "SAIL_API_KEY", "AZURE_OPENAI_API_KEY",
                                  "ANT_LING_API_KEY", "DEEPSEEK_API_KEY", "NVIDIA_API_KEY", "GEMINI_API_KEY", "GROQ_API_KEY",
                                  "CEREBRAS_API_KEY", "XAI_API_KEY", "FIREWORKS_API_KEY", "TOGETHER_API_KEY", "BASETEN_API_KEY",
                                  "AI_GATEWAY_API_KEY", "ZAI_API_KEY", "ZAI_CODING_CN_API_KEY", "MISTRAL_API_KEY", "MINIMAX_API_KEY",
                                  "MOONSHOT_API_KEY", "OPENCODE_API_KEY", "KIMI_API_KEY", "META_API_KEY", "RADIUS_API_KEY",
                                  "CLOUDFLARE_API_KEY", "QWEN_TOKEN_PLAN_API_KEY", "QWEN_TOKEN_PLAN_CN_API_KEY", "XIAOMI_API_KEY",
                                  "XIAOMI_TOKEN_PLAN_CN_API_KEY", "XIAOMI_TOKEN_PLAN_AMS_API_KEY", "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
                                  "AWS_BEARER_TOKEN_BEDROCK"]

    private static let openRouterLaunchVariable = "BOTCHU_LAUNCH_OPENROUTER_API_KEY"

    static func profileEnvironment(_ environment: [String: String]) -> [String: String] {
        var result = environment
        if let key = result.removeValue(forKey: "OPENROUTER_API_KEY") { result[openRouterLaunchVariable] = key }
        return result
    }

    /// Applied after login shell initialization, on This Mac only. Only a config path is exported,
    /// never a credential value; this same prefix scopes Pi's catalog query and its turns.
    static func profileShellPrefix(_ environment: [String: String], unset: [String] = []) -> String {
        let names = unset.filter { modelCredentialNames.contains($0) }
        var prefix = names.isEmpty ? "" : "unset " + names.joined(separator: " ") + "; "
        if let directory = environment["PI_CODING_AGENT_DIR"] {
            prefix += "unset PI_CODING_AGENT_SESSION_DIR; export PI_CODING_AGENT_DIR=\(Shell.quote(directory)); "
        }
        if environment["OPENROUTER_API_KEY"] != nil {
            // Preserve the selected Keychain credential across shell startup without putting its
            // value in argv. It replaces a global shell key only for the authorized legacy profile.
            prefix += "export OPENROUTER_API_KEY=\"$\(openRouterLaunchVariable)\"; unset \(openRouterLaunchVariable); "
        }
        return prefix
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

    /// Delivers stdout to `handler` as the events `parser` makes of it, instead of as lines to
    /// `onLines`. The lines are parsed as they arrive, off the main thread. Batches hold events,
    /// except the first, which can be empty when the CLI's first lines aren't events. Call before
    /// `start`.
    public func deliverEvents(parsedBy parser: any StreamParser, to handler: @escaping ([AgentEvent]) -> Void) {
        parseLock.lock()
        self.parser = parser
        parseLock.unlock()
        onEvents = handler
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
            if self.enqueue(self.takeLines(appending: data)) { self.scheduleDelivery() }
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
        let inputFile = try ProcessInput.file(input)
        defer { try? inputFile?.close() }
        if let inputFile { process.standardInput = inputFile }
        try process.run()
        for line in initialInput { send(line) }
        group.notify(queue: .main) { [self] in
            closeInput()
            // The last line may lack its newline; then everything still waiting goes before the exit.
            _ = enqueue(takeLines(appending: Data("\n".utf8)))
            flushOutput()
            lock.lock()
            var tail = String(decoding: errorTail, as: UTF8.self)
            if lingered {
                tail += (tail.isEmpty || tail.hasSuffix("\n") ? "" : "\n")
                    + "BotChu ended it: it was still running \(String(format: "%g", exitWait)) s after it said its turn had ended"
                    + (backgroundTasks > 0 ? ", waiting for its background tasks." : ".")
            }
            lock.unlock()
            onExit(process.terminationStatus, tail)
        }
    }

    /// Delivers the output received and not delivered yet, now. On the main queue; BotChu calls
    /// it when quitting, so what a CLI said last is in its thread before the thread is saved.
    public func flushOutput() {
        lock.lock()
        let lines = pendingLines
        let events = pendingEvents
        let announce = announcePrinted
        pendingLines = []
        pendingEvents = []
        announcePrinted = false
        deliveryScheduled = false
        lastDelivery = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        if !lines.isEmpty { onLines(lines) }
        if !events.isEmpty || announce { onEvents?(events) }
    }

    /// Adds lines to what waits for delivery: parsed into events, when parsing here. True when
    /// there is something to deliver.
    private func enqueue(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        parseLock.lock()
        var events: [AgentEvent]?
        if parser != nil {
            events = []
            for line in lines { events! += parser!.parse(line: line) }
        }
        parseLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        if let events {
            pendingEvents += events
            noteTurn(events)
            if !printed {
                printed = true
                announcePrinted = true
            }
            return !pendingEvents.isEmpty || announcePrinted
        }
        pendingLines += lines
        return true
    }

    /// Delivers what waits on the main queue: right away when the last delivery was at least
    /// `deliveryInterval` ago, else once it is. One delivery is on its way at a time.
    private func scheduleDelivery() {
        lock.lock()
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        let interval = UInt64(max(0, deliveryInterval) * 1_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastDelivery
        let wait = elapsed >= interval ? 0 : interval - elapsed
        lock.unlock()
        if wait == 0 {
            DispatchQueue.main.async { self.flushOutput() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { self.flushOutput() }
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
        if pipe != nil, turnEnded { watchForExit() }
        lock.unlock()
        guard let pipe else { return }
        inputQueue.async { try? pipe.fileHandleForWriting.close() }
    }

    /// Notes whether these events end the CLI's turn or carry it on, and starts waiting for its
    /// exit once its turn has ended and it has nothing more to read; that wait starts again when
    /// its background tasks start or all finish. A session event starts a new turn, as Claude
    /// Code's does once its background tasks have finished. Under `lock`.
    private func noteTurn(_ events: [AgentEvent]) {
        let wasEnded = turnEnded
        let wasWaiting = backgroundTasks > 0
        for event in events {
            switch event {
            case .finished: turnEnded = true
            case .text, .textDelta, .toolStarted, .toolFinished, .inputTaken, .session: turnEnded = false
            case .backgroundTasks(let tasks): backgroundTasks = tasks.count
            default: break
            }
        }
        if turnEnded, stdin == nil, !wasEnded || wasWaiting != (backgroundTasks > 0) { watchForExit() }
    }

    /// Ends the CLI `lingerLimit` from now (`backgroundLimit` while its background tasks run) if it
    /// is still running then, its turn still over and not stopped; a newer wait replaces this one.
    /// Under `lock`.
    private func watchForExit() {
        exitWatch += 1
        let watch = exitWatch
        let wait = backgroundTasks > 0 ? backgroundLimit : lingerLimit
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let lingering = watch == self.exitWatch && self.turnEnded && self.stdin == nil && !self.stopped
                && self.process.isRunning
            if lingering {
                self.lingered = true
                self.endedBackgroundTasks = self.backgroundTasks > 0
                self.exitWait = wait
            }
            let pid = self.remotePID
            self.lock.unlock()
            guard lingering else { return }
            if let remote = self.remote, let pid { self.signalHost(remote, pid, ["TERM", "KILL"]) }
            self.terminate(after: 0)
        }
    }

    /// Interrupts the CLI as Ctrl-C would, then terminates it if it is still running, then kills
    /// it: a CLI that ignores both (Antigravity stuck shutting down, #145) still ends, and with it
    /// its turn. On a host, the CLI there is interrupted too: closing the connection alone would
    /// leave it running.
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        closeInput()
        guard process.isRunning else { return }
        lock.lock()
        let pid = remotePID
        lock.unlock()
        if let remote, let pid { signalHost(remote, pid, ["INT", "TERM", "KILL"]) }
        process.interrupt()
        terminate(after: remote == nil ? 3 : 5)
    }

    /// Terminates the CLI `delay` from now if it is still running, and kills it with its process
    /// group (BotChu starts each CLI in a group of its own) `killDelay` after that.
    private func terminate(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [process, killDelay] in
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + killDelay) {
                if process.isRunning { Self.killGroup(of: process) }
            }
        }
    }

    /// Sends the CLI on a host these signals in turn, each 3 seconds after the one before, and
    /// KILL `killDelay` after it.
    private func signalHost(_ machine: Machine, _ pid: String, _ signals: [String]) {
        let killDelay = killDelay
        Task.detached {
            for (index, name) in signals.enumerated() {
                if index > 0 { try? await Task.sleep(for: .seconds(name == "KILL" ? killDelay : 3)) }
                _ = await machine.run(["kill", "-\(name)", pid], in: "~")
            }
        }
    }

    private static func killGroup(of process: Process) {
        let pid = process.processIdentifier
        if Darwin.killpg(pid, SIGKILL) != 0 { Darwin.kill(pid, SIGKILL) }
    }

    /// Ends the CLI at once (SIGKILL) if it is still running: for a run that must not outlive its
    /// limit once `stop` has asked it to end (a run review). On this Mac only.
    public func kill() {
        lock.lock()
        stopped = true
        lock.unlock()
        guard remote == nil, process.isRunning else { return }
        Self.killGroup(of: process)
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
