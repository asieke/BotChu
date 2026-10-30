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
    /// Where a local turn finds the helper, installed once by the app (`SubagentIPC.binDirectory`).
    private let binDirectory: String
    private let timeout: TimeInterval
    private let sshExecutable: String

    /// A separate app namespace prevents two coordinators using the same SSH host from taking
    /// each other's requests. Local tests can supply a temporary root, with their helper beside it.
    public init(machine: Machine = .thisMac, namespace: UUID, invocationID: UUID,
                localRoot: URL? = nil, timeout: TimeInterval = 15) {
        self.machine = machine
        self.timeout = timeout
        sshExecutable = Machine.ssh
        let local = SubagentIPC(root: localRoot ?? SubagentIPC.defaultRoot)
        directory = machine.isRemote
            ? "~/.botchu/ipc/subagents/\(namespace.uuidString.lowercased())/\(invocationID.uuidString.lowercased())"
            : local.mailbox(invocationID).root.path
        binDirectory = local.binDirectory.path
    }

    /// A host's mailbox gets its own copies of the helper (`script`) and of `timeout` (`TimeoutShim`),
    /// after a Python check, so an unavailable helper fails before the agent is launched; a local one
    /// uses the app's.
    public func prepare(script: String, roster: Data) async throws -> SubagentEndpoint {
        if machine.isRemote {
            let data = try await remote("prepare", [Data(script.utf8).base64EncodedString(), roster.base64EncodedString(),
                                                    Data(TimeoutShim.script.utf8).base64EncodedString()])
            let result = try JSONDecoder().decode([String: String].self, from: data)
            guard let root = result["directory"], root.hasPrefix("/") else { throw Failure(message: "The host did not return an absolute sub-agent mailbox path.") }
            return SubagentEndpoint(ipcDirectory: root, binDirectory: root + "/bin")
        }
        try Task.checkCancellation()
        let root = URL(fileURLWithPath: directory)
        for name in ["", "requests", "results", "status"] {
            let folder = name.isEmpty ? root : root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try roster.write(to: root.appendingPathComponent("roster.json"), options: .atomic)
        try await heartbeat()
        return SubagentEndpoint(ipcDirectory: directory, binDirectory: binDirectory)
    }

    /// Files stay until acknowledge, which the coordinator calls only after recording the run.
    /// Each read is bounded; incomplete .tmp writes never appear here. With `heartbeat`, the
    /// heartbeat is refreshed first, in the same round trip to a host.
    public func poll(heartbeat: Bool = false) async throws -> [SubagentEnvelope] {
        if machine.isRemote {
            struct Entry: Decodable { var filename: String; var data: Data; var problem: String? }
            return try JSONDecoder().decode([Entry].self, from: await remote("poll", heartbeat ? ["heartbeat"] + Self.load : []))
                .map { SubagentEnvelope(filename: $0.filename, data: $0.data, problem: $0.problem) }
        }
        if heartbeat { try await self.heartbeat() }
        return try localRequests()
    }

    /// Local callers arm this before their first drain. SSH keeps its existing poll protocol.
    public func watchRequests() -> LocalMailboxWatcher? {
        guard !machine.isRemote else { return nil }
        return LocalMailboxWatcher(directory: URL(fileURLWithPath: directory).appendingPathComponent("requests"))
    }

    /// Consume bounded batches until empty. A request whose durable acknowledgment failed is
    /// retried on the next hint/recovery, without spinning or hiding requests after that batch.
    /// Returns the number of directory scans, including the final empty scan.
    @discardableResult
    public func drainRequests(_ receive: @Sendable ([SubagentEnvelope]) async -> Bool) async throws -> Int {
        precondition(!machine.isRemote)
        var seen: Set<String> = []
        var scans = 0
        while !Task.isCancelled {
            let envelopes = try localRequests(excluding: seen)
            scans += 1
            guard !envelopes.isEmpty, await receive(envelopes) else { return scans }
            seen.formUnion(envelopes.map(\.filename))
        }
        return scans
    }

    private func localRequests(excluding seen: Set<String> = []) throws -> [SubagentEnvelope] {
        try Task.checkCancellation()
        let folder = URL(fileURLWithPath: directory).appendingPathComponent("requests")
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            .filter { Self.validFilename($0.lastPathComponent) && !seen.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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

    public func writeRoster(data: Data) async throws {
        try await write(data, relativePath: "roster.json")
    }

    /// A file `botchu-inbox send` staged in the mailbox (`inbox/<request id>/<name>`), at most `limit`
    /// bytes, read without following links.
    public func readStaged(_ relativePath: String, request: UUID, limit: Int) async throws -> Data {
        guard InboxRequest.isStagedPath(relativePath, request: request) else { throw Failure(message: "Invalid staged file path.") }
        if machine.isRemote {
            let data = try await remote("read", [relativePath, String(limit)], outputLimit: limit * 4 / 3 + 1024)
            guard let decoded = Data(base64Encoded: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  decoded.count <= limit else { throw Failure(message: "A staged file couldn't be read.") }
            return decoded
        }
        try Task.checkCancellation()
        let path = URL(fileURLWithPath: directory).appendingPathComponent(relativePath).path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure(message: "A staged file couldn't be opened.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= limit else {
            throw Failure(message: "A staged file must be a regular file of at most \(limit / (1 << 20)) MB.")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure(message: "A staged file grew too large.") }
        return data
    }

    /// Removes what `botchu-inbox send` staged for a request, once BotChu has its copies.
    public func removeStaged(request: UUID) async throws {
        let name = request.uuidString.lowercased()
        if machine.isRemote { _ = try await remote("drop", [name]); return }
        try Task.checkCancellation()
        do { try FileManager.default.removeItem(at: URL(fileURLWithPath: directory).appendingPathComponent("inbox").appendingPathComponent(name)) }
        catch CocoaError.fileNoSuchFile { }
    }

    public func heartbeat() async throws {
        if machine.isRemote { _ = try await remote("heartbeat", Self.load); return }
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
        let load = Self.load
        return Data("{\"updatedAt\":\"\(date)\",\"closed\":\(closed ? "true" : "false"),\"load\":\(load[0]),\"cpus\":\(load[1])}".utf8)
    }

    /// This Mac's one-minute load average and its CPUs, written with each heartbeat, so a helper
    /// waiting on a host gives a loaded Mac's late heartbeats as long as one here would (#368).
    static var load: [String] {
        var averages = [Double](repeating: 0, count: 3)
        let load = getloadavg(&averages, 3) > 0 ? averages[0] : 0
        return [String(format: "%.2f", load), String(ProcessInfo.processInfo.activeProcessorCount)]
    }

    /// Unlike a long-lived AgentRun, a mailbox command must release its coordinator after a network
    /// failure or cancellation, so each has its own time limit and output limit.
    private func remote(_ operation: String, _ arguments: [String] = [], outputLimit: Int = ChildProcess.outputLimit) async throws -> Data {
        try Task.checkCancellation()
        let script = "printf '%s\\n' \(Shell.marker); exec python3 -c \"$@\""
        let command = Machine.remoteCommand(script: script, arguments: [Self.remoteScript, operation, directory], in: "~")
        let result = await ChildProcess.run(sshExecutable, Machine.sshOptions + [machine.destination ?? "", command],
                                            environment: AgentRun.childEnvironment(ProcessInfo.processInfo.environment),
                                            input: try JSONEncoder().encode(arguments),
                                            timeout: operation == "read" ? max(timeout, 120) : timeout, outputLimit: outputLimit)
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
def beat(stamp, closed, load):
    value = {'updatedAt': stamp, 'closed': closed}
    try:
        value['load'], value['cpus'] = float(load[0]), int(load[1])
    except (IndexError, ValueError, TypeError): pass
    return value
def valid(name):
    return len(name) <= 128 and not name.startswith('.') and '/' not in name and '\\' not in name and name.endswith('.json')
if operation == 'prepare':
    for part in ['', 'requests', 'results', 'status', 'bin', 'bin/fallback']:
        folder = root / part
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(folder, 0o700)
    for command in ['botchu-subagent', 'botchu-task', 'botchu-inbox', 'botchu-secret', 'botchu-models']:
        helper = root / 'bin' / command
        atomic(helper, base64.b64decode(parameters[0]))
        os.chmod(helper, 0o755)
    shim = root / 'bin' / 'fallback' / 'timeout'
    atomic(shim, base64.b64decode(parameters[2]))
    os.chmod(shim, 0o755)
    atomic(root / 'roster.json', base64.b64decode(parameters[1]))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    atomic(root / 'heartbeat.json', json.dumps({'updatedAt': stamp, 'closed': False}).encode())
    print(json.dumps({'directory': str(root.resolve())}))
elif operation == 'poll':
    if parameters and parameters[0] == 'heartbeat':
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        atomic(root / 'heartbeat.json', json.dumps(beat(stamp, False, parameters[1:])).encode())
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
elif operation == 'read':
    relative = pathlib.PurePosixPath(parameters[0])
    limit = int(parameters[1])
    if relative.is_absolute() or '..' in relative.parts or len(relative.parts) != 3 or relative.parts[0] != 'inbox': raise ValueError('Invalid staged path')
    fd = os.open(root / relative, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit: raise ValueError('Staged file is not a regular file within the limit')
        data = stream.read(limit + 1)
        if len(data) > limit: raise ValueError('Staged file grew past the limit')
        sys.stdout.write(base64.b64encode(data).decode())
elif operation == 'drop':
    name = parameters[0]
    if not name or '/' in name or name.startswith('.'): raise ValueError('Invalid staged request')
    import shutil
    shutil.rmtree(root / 'inbox' / name, ignore_errors=True)
elif operation in ['heartbeat', 'close']:
    closed = operation == 'close'
    stamp = '1970-01-01T00:00:00Z' if closed else datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    atomic(root / 'heartbeat.json', json.dumps(beat(stamp, closed, parameters)).encode())
else: raise ValueError('Unknown mailbox operation')
"""#
}
