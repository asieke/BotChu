import Foundation

/// One headless CLI process for one turn. It runs the account's command through the login shell
/// (`zsh -l`, so PATH and Homebrew are the user's), in the bot's workspace, with stdin closed.
/// Complete stdout lines and the exit are delivered on the main queue.
public final class AgentRun: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()
    public private(set) var stopped = false

    public var onLines: ([String]) -> Void = { _ in }
    public var onExit: (_ status: Int32, _ stderr: String) -> Void = { _, _ in }

    public init(command: String, invocation: Invocation, directory: URL) {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", CommandBuilder.shellScript(command: command), "botchu"] + invocation.arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        for (key, value) in invocation.environment { env[key] = value }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
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
        group.notify(queue: .main) { [self] in
            let rest = takeLines(appending: Data("\n".utf8))
            if !rest.isEmpty { onLines(rest) }
            lock.lock()
            let tail = String(decoding: errorTail, as: UTF8.self)
            lock.unlock()
            onExit(process.terminationStatus, tail)
        }
    }

    /// Interrupts the CLI as Ctrl-C would, then terminates it if it is still running.
    public func stop() {
        stopped = true
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func takeLines(appending data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
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
