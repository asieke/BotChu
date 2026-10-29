import Foundation

/// What a tool call gave back: the text the model reads (and the chat shows), and how it went.
public struct SailToolResult: Equatable, Sendable {
    public var output: String
    public var isError: Bool
    public var exitCode: Int?

    public init(output: String, isError: Bool = false, exitCode: Int? = nil) {
        self.output = output
        self.isError = isError
        self.exitCode = exitCode
    }
}

/// The Sail agent's tools, run on this Mac in its folder: `read`, `write`, `edit` and `bash`,
/// named and shaped as Pi's are, so the chat files their calls the same way. Their environment is
/// the helper's without the Sail key, which a command could otherwise print.
public struct SailToolbox: Sendable {
    public var directory: URL
    public var environment: [String: String]
    public var shell = "/bin/bash"
    /// How long a command may run when its call doesn't say.
    public var defaultTimeout: TimeInterval = 1_800
    public var live: SailLive?

    /// The most of a tool's output the model is given back, in bytes and lines.
    public static let outputLimit = 50_000
    public static let lineLimit = 2_000
    /// The longest a single line read from a file is kept.
    static let longestLine = 2_000

    public init(directory: URL, environment: [String: String], live: SailLive? = nil) {
        self.directory = directory
        self.environment = Self.toolEnvironment(environment)
        self.live = live
        if !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/sh" }
    }

    /// The tools' environment: the helper's, without Sail's key or endpoint.
    public static func toolEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in key != Sail.keyVariable && key != Sail.baseVariable }
    }

    /// The function tools each request offers.
    public static let definitions: [SailJSON] = [
        tool("read", "Read a text file. Returns up to 2000 lines from `offset` (1-based); use offset and limit to read a long file in parts.",
             properties: ["path": ["type": "string", "description": "The file, relative to the working folder or absolute."],
                          "offset": ["type": "integer", "description": "The first line to read, from 1."],
                          "limit": ["type": "integer", "description": "How many lines to read."]],
             required: ["path"]),
        tool("write", "Create a file, or replace a file's whole content. Makes the folders it needs.",
             properties: ["path": ["type": "string", "description": "The file, relative to the working folder or absolute."],
                          "content": ["type": "string", "description": "The file's complete new content."]],
             required: ["path", "content"]),
        tool("edit", "Replace text in a file. `oldText` must match the file exactly, whitespace included, and only once.",
             properties: ["path": ["type": "string", "description": "The file, relative to the working folder or absolute."],
                          "oldText": ["type": "string", "description": "The exact text to replace."],
                          "newText": ["type": "string", "description": "The text to put in its place."]],
             required: ["path", "oldText", "newText"]),
        tool("bash", "Run a bash command in the working folder and return what it printed (the last 2000 lines or 50 KB) and its exit code.",
             properties: ["command": ["type": "string", "description": "The command."],
                          "timeout": ["type": "number", "description": "Seconds before the command is stopped; 1800 when not given."]],
             required: ["command"]),
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: SailJSON], required: [String]) -> SailJSON {
        ["type": "function", "name": .string(name), "description": .string(description), "strict": false,
         "parameters": ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]]
    }

    public func run(_ call: SailFunctionCall) async -> SailToolResult {
        guard let arguments = SailJSON.parse(call.arguments)?.object else {
            return SailToolResult(output: "Error: \(call.name)'s arguments aren't a JSON object: \(call.arguments.prefix(200))", isError: true)
        }
        switch call.name {
        case "read": return read(arguments)
        case "write": return write(arguments)
        case "edit": return edit(arguments)
        case "bash": return await bash(arguments)
        default: return SailToolResult(output: "Error: there's no tool named \(call.name). The tools are read, write, edit and bash.", isError: true)
        }
    }

    // MARK: Files

    /// A path from a call, in the working folder unless absolute (`~` is the home folder).
    public func url(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : directory.appendingPathComponent(expanded)).standardizedFileURL
    }

    private func read(_ arguments: [String: SailJSON]) -> SailToolResult {
        guard let path = arguments["path"]?.string, !path.isEmpty else { return failure("read needs a `path`.") }
        let file = url(path)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 50_000_000 else { return failure("\(path) is \(size) bytes, too large to read; use bash (head, sed -n, rg) to read part of it.") }
        guard let data = try? Data(contentsOf: file) else {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return failure("\(path) is a folder; use bash (ls) to list it.")
            }
            return failure("Can't read \(path): no such file, or not readable.")
        }
        if data.prefix(8_000).contains(0) { return SailToolResult(output: "\(path) is a binary file (\(data.count) bytes); not shown.") }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return SailToolResult(output: "(\(path) is empty)") }
        let start = max(1, arguments["offset"]?.int ?? 1)
        guard start <= lines.count else { return failure("\(path) has \(lines.count) lines; offset \(start) is past its end.") }
        let limit = max(1, min(Self.lineLimit, arguments["limit"]?.int ?? Self.lineLimit))
        var shown: [String] = []
        var bytes = 0
        for line in lines[(start - 1)..<min(lines.count, start - 1 + limit)] {
            let kept = line.count > Self.longestLine ? String(line.prefix(Self.longestLine)) + " … [line cut]" : line
            bytes += kept.utf8.count + 1
            if bytes > Self.outputLimit, !shown.isEmpty { break }
            shown.append(kept)
        }
        var output = shown.joined(separator: "\n")
        let last = start + shown.count - 1
        if last < lines.count {
            output += "\n\n[Lines \(start)–\(last) of \(lines.count). Read on with offset \(last + 1).]"
        }
        return SailToolResult(output: output)
    }

    private func write(_ arguments: [String: SailJSON]) -> SailToolResult {
        guard let path = arguments["path"]?.string, !path.isEmpty else { return failure("write needs a `path`.") }
        guard let content = arguments["content"]?.string else { return failure("write needs the file's `content`.") }
        let file = url(path)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: file, options: .atomic)
        } catch {
            return failure("Couldn't write \(path): \(error.localizedDescription)")
        }
        return SailToolResult(output: "Wrote \(content.utf8.count) bytes to \(path).")
    }

    private func edit(_ arguments: [String: SailJSON]) -> SailToolResult {
        guard let path = arguments["path"]?.string, !path.isEmpty else { return failure("edit needs a `path`.") }
        guard let old = arguments["oldText"]?.string, !old.isEmpty else { return failure("edit needs the `oldText` to replace.") }
        guard let new = arguments["newText"]?.string else { return failure("edit needs the `newText` to put in its place.") }
        let file = url(path)
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            return failure("Can't read \(path) as text: no such file, or not UTF-8.")
        }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        var found: Range<String.Index>?
        while let range = text.range(of: old, range: searchRange) {
            count += 1
            found = found ?? range
            searchRange = range.upperBound..<text.endIndex
        }
        guard let found else { return failure("oldText isn't in \(path). It must match the file exactly, whitespace and line breaks included; read the file again first.") }
        guard count == 1 else { return failure("oldText is in \(path) \(count) times. Include more of the text around it, so it matches once.") }
        let edited = text.replacingCharacters(in: found, with: new)
        do { try Data(edited.utf8).write(to: file, options: .atomic) } catch {
            return failure("Couldn't write \(path): \(error.localizedDescription)")
        }
        let removed = old.components(separatedBy: "\n").count
        let added = new.isEmpty ? 0 : new.components(separatedBy: "\n").count
        return SailToolResult(output: "Edited \(path): \(removed) line\(removed == 1 ? "" : "s") replaced by \(added).")
    }

    private func failure(_ message: String) -> SailToolResult {
        SailToolResult(output: "Error: " + message, isError: true)
    }

    // MARK: Commands

    private func bash(_ arguments: [String: SailJSON]) async -> SailToolResult {
        guard let command = arguments["command"]?.string, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure("bash needs a `command`.")
        }
        let timeout = min(14_400, max(1, arguments["timeout"]?.number ?? defaultTimeout))
        let result = await SailCommandRunner.run(shell: shell, command: command, directory: directory, environment: environment,
                                                 timeout: timeout, live: live)
        var output = Self.tail(result.output)
        if output.isEmpty { output = "(no output)" }
        if result.timedOut {
            output += "\n\n[Stopped after \(Int(timeout)) s, its time limit.]"
        } else if result.status != 0 {
            output += "\n\n[Exit code \(result.status)]"
        }
        return SailToolResult(output: output, isError: result.timedOut || result.status != 0, exitCode: Int(result.status))
    }

    /// The end of a command's output, at most `lineLimit` lines and `outputLimit` bytes, saying
    /// what was left out.
    public static func tail(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let total = lines.count
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            bytes += line.utf8.count + 1
            if kept.count >= lineLimit || (bytes > outputLimit && !kept.isEmpty) { break }
            kept.append(bytes > outputLimit ? String(line.suffix(outputLimit)) : line)
        }
        let shown = kept.reversed().joined(separator: "\n")
        return kept.count < total ? "[Earlier output cut: the last \(kept.count) of \(total) lines.]\n" + shown : shown
    }
}

/// Runs one command for the `bash` tool: its output and error output together, up to its time
/// limit, its process group stopped with it.
enum SailCommandRunner {
    struct Result: Sendable {
        var output: String
        var status: Int32
        var timedOut: Bool
    }

    /// What a command printed, keeping the last `keep` bytes; written by its reader alone, then read once.
    private final class Printed: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var timedOut = false
        static let keep = 1_000_000

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            if data.count > 2 * Self.keep { data = data.suffix(Self.keep) }
            lock.unlock()
        }
    }

    static func run(shell: String, command: String, directory: URL, environment: [String: String], timeout: TimeInterval,
                    live: SailLive?) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", command]
            process.currentDirectoryURL = directory
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let printed = Printed()
            let reading = DispatchGroup()
            reading.enter()
            process.terminationHandler = { process in
                DispatchQueue.global().async {
                    // What it printed last, unless something it left running holds the output open.
                    _ = reading.wait(timeout: .now() + 2)
                    live?.ended(process)
                    printed.lock.lock()
                    let data = printed.data.count > Printed.keep ? printed.data.suffix(Printed.keep) : printed.data
                    let timedOut = printed.timedOut
                    printed.lock.unlock()
                    continuation.resume(returning: Result(output: String(decoding: data, as: UTF8.self), status: process.terminationStatus,
                                                          timedOut: timedOut))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: Result(output: "Couldn't start \(shell): \(error.localizedDescription)", status: 127, timedOut: false))
                return
            }
            live?.started(process)
            // A blocking pipe reader needs its own thread: global workers can all be waiting
            // for child exits, starving this reader until the termination drain deadline expires.
            Thread.detachNewThread {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    printed.append(chunk)
                }
                reading.leave()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                printed.lock.lock()
                printed.timedOut = true
                printed.lock.unlock()
                SailLive.end(process)
            }
        }
    }
}

/// What the helper is doing now, for a signal to end it cleanly: the command a tool is running,
/// which is stopped with its process group, and the submission Sail may still be working on,
/// which BotChu can only leave there.
public final class SailLive: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var waiting: (row: String, response: String?)?

    public init() {}

    func started(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func ended(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func submitted(row: String, response: String?) {
        lock.lock()
        waiting = (row, response)
        lock.unlock()
    }

    func settled() {
        lock.lock()
        waiting = nil
        lock.unlock()
    }

    /// Stops the running command, if any, and says what remains at Sail: the line the helper
    /// prints as it exits on a signal. Nothing is sent to Sail, which can't cancel a response.
    public func stop() -> SailEvent? {
        lock.lock()
        let process = self.process
        let waiting = self.waiting
        self.process = nil
        lock.unlock()
        if let process { Self.end(process, grace: 1) }
        guard let waiting else { return nil }
        return .flex(row: waiting.row, detail: SailAgent.detachedDetail(response: waiting.response), state: .detached)
    }

    /// TERM to the command and its process group, then KILL to both if it's still running after `grace`.
    static func end(_ process: Process, grace: TimeInterval = 3) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        _ = kill(-pid, SIGTERM)
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            _ = kill(-pid, SIGKILL)
            _ = kill(pid, SIGKILL)
        }
    }
}
