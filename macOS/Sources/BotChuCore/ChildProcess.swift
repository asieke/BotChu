import Foundation

/// A program BotChu runs and waits for, such as git, gh, ssh or a tool's version check: with a time
/// limit, its output read up to a limit, and stopped when the task waiting for it is cancelled. No
/// thread waits on it while it runs.
enum ChildProcess {
    /// How much of each output is kept, unless the caller asks for less; the rest is read and dropped.
    static let outputLimit = 12_000_000
    /// How long a stopped program has after TERM before KILL, and after KILL before BotChu stops
    /// waiting for it.
    static let grace: TimeInterval = 1

    /// Runs `executable` in `directory`, with stdin from `input` (or none), and returns once it has
    /// exited and its output has closed. At `timeout`, or when the task is cancelled, its process
    /// group is sent TERM, then KILL, and the result is what it printed so far, with status -1 and
    /// why it was stopped as the last line of `errors`. `mergeErrors` puts its error output in `output`.
    static func run(_ executable: String, _ arguments: [String], in directory: String = NSHomeDirectory(),
                    environment: [String: String], input: Data? = nil, timeout: TimeInterval,
                    outputLimit: Int = ChildProcess.outputLimit, mergeErrors: Bool = false) async -> Shell.Result {
        let run = Run(timeout: timeout, outputLimit: outputLimit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.start(executable, arguments, in: directory, environment: environment, input: input,
                          mergeErrors: mergeErrors, continuation)
            }
        } onCancel: {
            run.stop(timedOut: false)
        }
    }

    /// One program's run: what it printed, and whether it ended or was stopped. Its output is read as
    /// it arrives, and it ends in `finish`, once.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private let timeout: TimeInterval
        private let outputLimit: Int
        private var streams: [FileHandle] = []
        private var printed = [Data(), Data()]
        private var open = 0
        private var launched = false, exited = false, stopped = false, timedOut = false, finished = false
        private var problem: String?
        private var continuation: CheckedContinuation<Shell.Result, Never>?

        init(timeout: TimeInterval, outputLimit: Int) {
            self.timeout = timeout
            self.outputLimit = outputLimit
        }

        func start(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String], input: Data?,
                   mergeErrors: Bool, _ continuation: CheckedContinuation<Shell.Result, Never>) {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            process.environment = environment
            let out = Pipe(), err = mergeErrors ? out : Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { [weak self] _ in self?.ended() }
            streams = (mergeErrors ? [out] : [out, err]).map(\.fileHandleForReading)
            for (index, stream) in streams.enumerated() {
                stream.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    self?.read(data, into: index)
                }
            }
            lock.lock()
            self.continuation = continuation
            if !stopped {
                do {
                    // From a file, so a program that never reads it can't hold BotChu up, or end it with SIGPIPE.
                    let inputFile = try ProcessInput.file(input)
                    defer { try? inputFile?.close() }
                    process.standardInput = inputFile ?? FileHandle.nullDevice
                    try process.run()
                    launched = true
                    open = streams.count
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop(timedOut: true) }
                } catch {
                    problem = error.localizedDescription
                }
            }
            lock.unlock()
            finish()
        }

        /// Sends its process group TERM, then KILL, then stops waiting for it.
        func stop(timedOut: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped, !finished else { return }
            stopped = true
            self.timedOut = timedOut
            guard launched else { return }
            send(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + ChildProcess.grace) { [weak self] in
                guard let self else { return }
                lock.lock()
                send(SIGKILL)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + ChildProcess.grace) { [weak self] in self?.finish(waiting: false) }
            }
        }

        /// Only while it runs: once it has been reaped, its process ID can belong to another program.
        private func send(_ signal: Int32) {
            guard !exited, process.isRunning else { return }
            let pid = process.processIdentifier
            if killpg(pid, signal) != 0 { kill(pid, signal) }
        }

        private func read(_ data: Data, into index: Int) {
            lock.lock()
            if data.isEmpty {
                open -= 1
            } else if printed[index].count < outputLimit {
                printed[index].append(data.prefix(outputLimit - printed[index].count))
            }
            lock.unlock()
            if data.isEmpty { finish() }
        }

        private func ended() {
            lock.lock()
            exited = true
            lock.unlock()
            finish()
        }

        /// Hands back the result once it has exited and its output has closed, or it never started;
        /// with `waiting` false, as it is now.
        private func finish(waiting: Bool = true) {
            lock.lock()
            guard !finished, let continuation, !waiting || !launched || exited && open == 0 else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            var errors = problem ?? String(decoding: printed[1], as: UTF8.self)
            if stopped {
                let reason = timedOut ? "it was still running after \(String(format: "%g", timeout)) s" : "cancelled"
                errors += (errors.isEmpty || errors.hasSuffix("\n") ? "" : "\n") + "BotChu stopped it: \(reason)."
            }
            let result = Shell.Result(status: exited && !stopped ? process.terminationStatus : -1,
                                      output: String(decoding: printed[0], as: UTF8.self), errors: errors, timedOut: timedOut)
            let streams = streams
            lock.unlock()
            for stream in streams { stream.readabilityHandler = nil }
            continuation.resume(returning: result)
        }
    }
}
