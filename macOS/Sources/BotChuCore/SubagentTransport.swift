import Foundation

/// An invocation's mailbox lives on the machine where its shell tools run. Polling it separately
/// from the agent's output avoids deadlocking a shell tool whose output is buffered until exit.
public struct SubagentEndpoint: Equatable, Sendable {
    public var ipcDirectory: String
    public var binDirectory: String
}

public struct SubagentEnvelope: Equatable, Sendable {
    public var filename: String
    public var data: Data
    /// Malformed files are still acknowledged by the coordinator, rather than retried forever.
    public var problem: String?
}

public struct SubagentTransport: Sendable {
    public struct Failure: LocalizedError, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static let maximumRequestBytes = 262_144
    public static let maximumBatchCount = 32
    public let machine: Machine
    private let directory: String
    private let timeout: TimeInterval

    /// A separate app namespace prevents two coordinators using the same SSH host from taking
    /// each other's requests. Local tests can supply a temporary root, including their helper.
    public init(machine: Machine = .thisMac, namespace: UUID, invocationID: UUID,
                localRoot: URL? = nil, timeout: TimeInterval = 15) {
        self.machine = machine
        self.timeout = timeout
        let id = invocationID.uuidString.lowercased()
        directory = machine.isRemote
            ? "~/.botchu/ipc/subagents/\(namespace.uuidString.lowercased())/\(id)"
            : (localRoot ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".botchu/ipc/subagents"))
                .appendingPathComponent(id).path
    }

    /// Installs only in this invocation's private directory. A remote Python check is part of
    /// preparation, so an unavailable helper fails before the agent is launched.
    public func prepare(script: String, roster: Data) async throws -> SubagentEndpoint {
        if machine.isRemote {
            let data = try await remote("prepare", [Data(script.utf8).base64EncodedString(), roster.base64EncodedString()])
            let result = try JSONDecoder().decode([String: String].self, from: data)
            guard let root = result["directory"], root.hasPrefix("/") else { throw Failure(message: "The host did not return an absolute sub-agent mailbox path.") }
            return SubagentEndpoint(ipcDirectory: root, binDirectory: root + "/bin")
        }
        try Task.checkCancellation()
        let root = URL(fileURLWithPath: directory)
        for name in ["", "requests", "results", "status", "bin"] {
            let folder = name.isEmpty ? root : root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let helper = root.appendingPathComponent("bin/botchu-subagent")
        try Data(script.utf8).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try roster.write(to: root.appendingPathComponent("roster.json"), options: .atomic)
        try await heartbeat()
        return SubagentEndpoint(ipcDirectory: directory, binDirectory: directory + "/bin")
    }

    /// Files stay until acknowledge, which the coordinator calls only after recording the run.
    /// Each read is bounded; incomplete .tmp writes never appear here.
    public func poll() async throws -> [SubagentEnvelope] {
        if machine.isRemote {
            struct Entry: Decodable { var filename: String; var data: Data; var problem: String? }
            return try JSONDecoder().decode([Entry].self, from: await remote("poll"))
                .map { SubagentEnvelope(filename: $0.filename, data: $0.data, problem: $0.problem) }
        }
        try Task.checkCancellation()
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("requests")
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            .filter { Self.validFilename($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.prefix(Self.maximumBatchCount).map { file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= Self.maximumRequestBytes else {
                return SubagentEnvelope(filename: file.lastPathComponent, data: Data(), problem: "Request must be a regular JSON file no larger than 256 KiB.")
            }
            // Read at most limit + 1 even if another process replaced or grew the file meanwhile.
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                return SubagentEnvelope(filename: file.lastPathComponent, data: Data(), problem: "Request cannot be read safely.")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                return SubagentEnvelope(filename: file.lastPathComponent, data: Data(), problem: "Request must be a regular file.")
            }
            let data = try handle.read(upToCount: Self.maximumRequestBytes + 1) ?? Data()
            return SubagentEnvelope(filename: file.lastPathComponent,
                data: data.count <= Self.maximumRequestBytes ? data : Data(),
                problem: data.count <= Self.maximumRequestBytes ? nil : "Request exceeds 256 KiB.")
        }
    }

    public func acknowledge(filename: String) async throws {
        guard Self.validFilename(filename) else { throw Failure(message: "Invalid request filename.") }
        if machine.isRemote { _ = try await remote("ack", [filename]); return }
        try Task.checkCancellation()
        let file = URL(fileURLWithPath: directory).appendingPathComponent("requests").appendingPathComponent(filename)
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile { }
    }

    public func writeResult(id: UUID, data: Data) async throws {
        try await write(data, relativePath: "results/\(id.uuidString.lowercased()).result.json")
    }

    public func writeStatus(id: UUID, data: Data) async throws {
        try await write(data, relativePath: "status/\(id.uuidString.lowercased()).status.json")
    }

    public func heartbeat() async throws {
        if machine.isRemote { _ = try await remote("heartbeat"); return }
        try await write(Self.heartbeatData(closed: false), relativePath: "heartbeat.json")
    }

    /// Keep results for recovery/late waiters. An expired heartbeat makes new calls fail promptly.
    public func close() async throws {
        if machine.isRemote { _ = try await remote("close"); return }
        try await write(Self.heartbeatData(closed: true), relativePath: "heartbeat.json")
    }

    private func write(_ data: Data, relativePath: String) async throws {
        if machine.isRemote { _ = try await remote("write", [relativePath, data.base64EncodedString()]); return }
        try Task.checkCancellation()
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(relativePath), options: .atomic)
    }

    private static func validFilename(_ name: String) -> Bool {
        name.count <= 128 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && name.hasSuffix(".json")
    }

    private static func heartbeatData(closed: Bool) -> Data {
        let date = ISO8601DateFormatter().string(from: closed ? Date(timeIntervalSince1970: 0) : Date())
        return Data("{\"updatedAt\":\"\(date)\",\"closed\":\(closed ? "true" : "false")}".utf8)
    }

    private func remote(_ operation: String, _ arguments: [String] = []) async throws -> Data {
        try Task.checkCancellation()
        let script = "printf '%s\\n' \(Shell.marker); exec python3 -c \"$@\""
        let command = Machine.remoteCommand(script: script, arguments: [Self.remoteScript, operation, directory], in: "~")
        let input = try JSONEncoder().encode(arguments)
        let run = TransportCommand()
        let result = await withTaskCancellationHandler {
            await run.execute(executable: Machine.ssh, arguments: Machine.sshOptions + [machine.destination ?? "", command], input: input, timeout: timeout)
        } onCancel: { run.cancel() }
        try Task.checkCancellation()
        guard result.status == 0 else {
            let detail = result.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: "Sub-agent mailbox on \(machine.destination ?? "host") failed" + (detail.isEmpty ? "." : ": \(detail.suffix(500))"))
        }
        return Data(Shell.commandOutput(result.output).utf8)
    }

    private static let remoteScript = #"""
import base64, datetime, json, os, pathlib, stat, sys, tempfile
operation, raw_directory = sys.argv[1:3]
parameters = json.load(sys.stdin)
root = pathlib.Path(os.path.expanduser(raw_directory))
def atomic(path, data):
    fd, name = tempfile.mkstemp(prefix='.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream: stream.write(data)
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)
def valid(name):
    return len(name) <= 128 and not name.startswith('.') and '/' not in name and '\\' not in name and name.endswith('.json')
if operation == 'prepare':
    for part in ['', 'requests', 'results', 'status', 'bin']:
        folder = root / part
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(folder, 0o700)
    helper = root / 'bin' / 'botchu-subagent'
    atomic(helper, base64.b64decode(parameters[0]))
    os.chmod(helper, 0o755)
    atomic(root / 'roster.json', base64.b64decode(parameters[1]))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    atomic(root / 'heartbeat.json', json.dumps({'updatedAt': stamp, 'closed': False}).encode())
    print(json.dumps({'directory': str(root.resolve())}))
elif operation == 'poll':
    entries = []
    for name in sorted(os.listdir(root / 'requests')):
        if not valid(name): continue
        path = root / 'requests' / name
        data, problem = b'', None
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size > 262144:
                    problem = 'Request must be a regular JSON file no larger than 256 KiB.'
                else:
                    data = stream.read(262145)
                    if len(data) > 262144: data, problem = b'', 'Request exceeds 256 KiB.'
        except FileNotFoundError: continue
        except OSError: problem = 'Request cannot be read safely.'
        entries.append({'filename': name, 'data': base64.b64encode(data).decode(), 'problem': problem})
        if len(entries) >= 32: break
    print(json.dumps(entries))
elif operation == 'ack':
    name = parameters[0]
    if not valid(name): raise ValueError('Invalid request filename')
    try: os.unlink(root / 'requests' / name)
    except FileNotFoundError: pass
elif operation == 'write':
    relative = pathlib.PurePosixPath(parameters[0])
    if relative.is_absolute() or '..' in relative.parts: raise ValueError('Invalid mailbox path')
    atomic(root / relative, base64.b64decode(parameters[1]))
elif operation in ['heartbeat', 'close']:
    closed = operation == 'close'
    stamp = '1970-01-01T00:00:00Z' if closed else datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    atomic(root / 'heartbeat.json', json.dumps({'updatedAt': stamp, 'closed': closed}).encode())
else: raise ValueError('Unknown mailbox operation')
"""#
}

/// Unlike long-lived AgentRun, mailbox commands must release their coordinator after a network
/// failure or cancellation. Each operation owns its process, bounded output and timeout.
final class TransportCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var completed = false

    func cancel() {
        lock.lock()
        cancelled = true
        if !completed, process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if !self.completed, self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            self.lock.unlock()
        }
    }

    func execute(executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval) async -> Shell.Result {
        await withCheckedContinuation { continuation in
            let out = Pipe(), err = Pipe(), group = DispatchGroup()
            let stdin = input.map { _ in Pipe() }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
            process.environment = AgentRun.childEnvironment(ProcessInfo.processInfo.environment)
            if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
            process.standardOutput = out
            process.standardError = err
            group.enter()
            process.terminationHandler = { _ in group.leave() }
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(returning: Shell.Result(status: -1, output: "", errors: "Cancelled"))
                return
            }
            do { try process.run() }
            catch {
                lock.unlock()
                continuation.resume(returning: Shell.Result(status: -1, output: "", errors: error.localizedDescription))
                return
            }
            lock.unlock()
            if let stdin, let input {
                group.enter()
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                    group.leave()
                }
            }
            let output = TransportOutput()
            for (handle, isError) in [(out.fileHandleForReading, false), (err.fileHandleForReading, true)] {
                group.enter()
                DispatchQueue.global().async {
                    let cap = isError ? 16_384 : 12_000_000
                    var data = Data()
                    while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                        if data.count < cap { data.append(chunk.prefix(cap - data.count)) }
                    }
                    if isError { output.errors = data } else { output.output = data }
                    group.leave()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0.1, timeout)) { [weak self] in self?.cancel() }
            group.notify(queue: .global()) { [self] in
                lock.lock()
                completed = true
                let wasCancelled = cancelled
                lock.unlock()
                continuation.resume(returning: Shell.Result(status: wasCancelled ? -1 : process.terminationStatus,
                    output: String(decoding: output.output, as: UTF8.self),
                    errors: wasCancelled ? "Command cancelled or timed out." : String(decoding: output.errors, as: UTF8.self)))
            }
        }
    }
}

private final class TransportOutput: @unchecked Sendable {
    var output = Data()
    var errors = Data()
}
