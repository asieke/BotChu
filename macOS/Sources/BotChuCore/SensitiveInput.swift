import Foundation

/// Metadata only. The entered value is deliberately absent from this wire protocol.
public struct SensitiveInputRequest: Codable, Equatable, Identifiable, Sendable {
    public var kind = "secret"
    public var id: UUID
    public var invocationID: UUID
    public var callerBotID: UUID
    public var callerTaskID: UUID?
    public var parentSubagentID: UUID?
    public var label: String
    public var destination: String
    public var createdAt: Date
    public static let lifetime: TimeInterval = 300

    public init(id: UUID = UUID(), invocationID: UUID, callerBotID: UUID, callerTaskID: UUID? = nil,
                parentSubagentID: UUID? = nil, label: String, destination: String, createdAt: Date = Date()) {
        self.id = id; self.invocationID = invocationID; self.callerBotID = callerBotID
        self.callerTaskID = callerTaskID; self.parentSubagentID = parentSubagentID
        self.label = label; self.destination = destination; self.createdAt = createdAt
    }

    public static func isRequest(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["kind"] as? String == "secret"
    }

    public func validate(caller: SubagentCallerContext, now: Date = Date()) throws {
        guard kind == "secret", invocationID == caller.invocationID, callerBotID == caller.botID,
              callerTaskID == caller.taskID, parentSubagentID == caller.parentSubagentID,
              caller.hostID == nil else { throw SensitiveInputError.invalidRequest }
        guard now.timeIntervalSince(createdAt) >= -5, now.timeIntervalSince(createdAt) < Self.lifetime else {
            throw SensitiveInputError.expired
        }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 120,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SensitiveInputError.invalidRequest
        }
        try SensitiveInputDestination.validate(destination)
    }
}

public enum SensitiveInputError: Error, LocalizedError, Sendable {
    case invalidRequest, expired, invalidDestination, unavailableDestination, invalidValue, writeFailed
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "This sensitive-input request is invalid or isn't from an active local turn."
        case .expired: "This sensitive-input request expired. Ask the agent to request it again."
        case .invalidDestination: "Use an absolute path to a new file, without links, dot components or control characters."
        case .unavailableDestination: "The destination must be a new file in an existing folder, with no symbolic links."
        case .invalidValue: "Enter a value of 1–65536 UTF-8 bytes."
        case .writeFailed: "The value could not be saved. No value was returned to the agent."
        }
    }
}

/// A receipt never contains the value or an underlying filesystem error (which might include data).
public struct SensitiveInputResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case saved, cancelled, expired, rejected }
    public var kind = "secret"
    public var id: UUID
    public var status: Status
    public init(id: UUID, status: Status) { self.id = id; self.status = status }
}

public enum SensitiveInputDestination {
    public static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.utf8.count <= 4096, parts.count > 2,
              !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" || $0.lowercased() == ".botchu" }),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SensitiveInputError.invalidDestination
        }
    }

    /// Compare components using macOS's case/canonical-equivalence conventions. Resolve only
    /// the trusted exclusion root; destination ancestors are still traversed with O_NOFOLLOW.
    public static func isWithin(_ path: String, directory: String) -> Bool {
        let resolved: String
        if let buffer = realpath(directory, nil) {
            resolved = String(cString: buffer)
            free(buffer)
        } else { resolved = directory }
        func components(_ value: String) -> [String] {
            value.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping.lowercased() }
        }
        return components(path).starts(with: components(resolved))
    }

    /// Walk directory descriptors without following links, including ancestor components. Keep
    /// the final parent open across creation: replacing an ancestor cannot redirect the write.
    private static func parent(_ path: String) throws -> (Int32, String) {
        try validate(path)
        let parts = path.split(separator: "/").map(String.init)
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SensitiveInputError.unavailableDestination }
        for component in parts.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { throw SensitiveInputError.unavailableDestination }
            descriptor = next
        }
        return (descriptor, parts.last!)
    }

    public static func check(_ path: String) throws {
        let (directory, name) = try parent(path)
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
            throw SensitiveInputError.unavailableDestination
        }
    }

    /// The only persistent copy is the approved destination, with exact bytes and no newline.
    /// O_EXCL refuses existing files, links, FIFOs and a destination created since the popup opened.
    public static func save(_ value: String, to path: String) throws {
        try Task.checkCancellation()
        guard !value.isEmpty, value.utf8.count <= 65536 else { throw SensitiveInputError.invalidValue }
        let (directory, name) = try parent(path)
        defer { close(directory) }
        try Task.checkCancellation()
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SensitiveInputError.unavailableDestination }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var complete = false
        defer {
            try? handle.close()
            if !complete { _ = unlinkat(directory, name, 0) }
        }
        do {
            try handle.write(contentsOf: Data(value.utf8))
            try Task.checkCancellation()
            try handle.synchronize()
            try Task.checkCancellation()
            complete = true
        } catch is CancellationError { throw CancellationError() }
        catch { throw SensitiveInputError.writeFailed }
    }
}
