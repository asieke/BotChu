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

    /// A process as it was seen: its ID and when it started, which tell it from a later one with the
    /// same ID.
    struct Member: Equatable {
        let pid: pid_t
        let started: UInt64

        /// Whether this same process is still running, in process group `group`.
        func isStill(in group: pid_t) -> Bool {
            ChildProcess.member(pid).map { $0 == self && ChildProcess.group(of: pid) == group } ?? false
        }
    }

    /// The processes in process group `group`, without those that have exited.
    static func members(of group: pid_t) -> [Member] {
        let size = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 16)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count)) }
        return pids.prefix(max(0, Int(filled)) / MemoryLayout<pid_t>.stride)
            .filter { $0 > 0 && Self.group(of: $0) == group }.compactMap(Self.member)
    }

    private static func member(_ pid: pid_t) -> Member? {
        info(pid).map { Member(pid: pid, started: $0.pbi_start_tvsec * 1_000_000 + $0.pbi_start_tvusec) }
    }

    private static func group(of pid: pid_t) -> pid_t? {
        info(pid).map { pid_t($0.pbi_pgid) }
    }

    /// Nil once it has exited.
    private static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != UInt32(SZOMB) ? info : nil
    }

    /// Runs `executable` in `directory`, with stdin from `input` (or none), and returns once it has
    /// exited and its output has closed. At `timeout`, or when the task is cancelled, its process
    /// group is sent TERM, then KILL, and the result is what it printed so far, with status -1 and
    /// why it was stopped, with how many processes that ended, as the last line of `errors`.
    /// `mergeErrors` puts its error output in `output`.
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
        /// What it left in its process group when it exited, such as a background process still
        /// holding its output.
        private var leftovers: [Member] = []
        /// Every process a stop signal was sent to, which its reason counts.
        private var ended: Set<pid_t> = []
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
            process.terminationHandler = { [weak self] _ in self?.exitedNow() }
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

        /// To its process group (`Process` makes it the leader of its own). While it runs, the group's
        /// ID is its process ID. Once it has been reaped, that ID can belong to another program, so the
        /// group is signalled only while something it left there (`leftovers`) still is, the same
        /// process by its start time: a group's ID isn't given to anything new while the group has
        /// members, so it is still the group it started.
        private func send(_ signal: Int32) {
            let pid = process.processIdentifier
            let running = !exited && process.isRunning
            guard running || leftovers.contains(where: { $0.isStill(in: pid) }) else { return }
            ended.formUnion(ChildProcess.members(of: pid).map(\.pid))
            if killpg(pid, signal) != 0, running {
                kill(pid, signal)
                ended.insert(pid)
            }
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

        /// Called once it has been reaped, so its group can be stopped after it (`send`).
        private func exitedNow() {
            let left = ChildProcess.members(of: process.processIdentifier)
            lock.lock()
            exited = true
            leftovers = left
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
                let count = ended.isEmpty ? "" : " (\(ended.count) \(ended.count == 1 ? "process" : "processes") ended)"
                errors += (errors.isEmpty || errors.hasSuffix("\n") ? "" : "\n") + "BotChu stopped it: \(reason)\(count)."
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
