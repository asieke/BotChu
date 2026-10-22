import Foundation

/// A copied image in the bot's folder. Relative, UUID-based names survive workspace moves.
public struct ImageAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
    public var filename: String { id.uuidString.lowercased() + ".png" }
    public static let maximumCount = 8
    public static let maximumBytes = 5 * 1024 * 1024
}

extension BotHome {
    public func imageURL(_ image: ImageAttachment) -> URL {
        url.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(image.filename)
    }

    public func saveImage(_ data: Data, name: String) throws -> ImageAttachment {
        guard !data.isEmpty, data.count <= ImageAttachment.maximumBytes else {
            throw ImageDelivery.Failure("Images must be no larger than 5 MB after resizing.")
        }
        let image = ImageAttachment(name: name)
        let file = imageURL(image)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return image
    }
}

public enum ImageDelivery {
    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// Add images without changing the text-only invocation or its output format.
    public static func attaching(_ images: [URL], to invocation: Invocation, kind: AgentKind, prompt: String) throws -> Invocation {
        guard !images.isEmpty else { return invocation }
        guard images.count <= ImageAttachment.maximumCount else { throw Failure("Attach up to 8 images per message.") }
        var result = invocation
        switch kind {
        case .claude:
            var content: [[String: Any]] = [["type": "text", "text": prompt]]
            for url in images {
                let data = try Data(contentsOf: url)
                guard data.count <= ImageAttachment.maximumBytes else { throw Failure("An attached image is too large.") }
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data.base64EncodedString()]])
            }
            let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            result.standardInput = try JSONSerialization.data(withJSONObject: message) + Data([10])
            result.arguments.removeLast()
            result.arguments += ["--input-format", "stream-json"]
        case .antigravity:
            // agy's streaming input accepts text blocks only. Its file reader opens image files.
            result.arguments[1] = prompt + "\n\nAttached images (open these files to inspect them):\n" + images.map(\.path).joined(separator: "\n")
        case .codex, .muse:
            result.arguments.removeLast()
            for url in images { result.arguments += ["--image", url.path] }
            result.arguments += ["--", invocation.arguments.last ?? prompt]
        case .pi:
            result.arguments.removeLast()
            result.arguments += images.map { "@" + $0.path }
            result.arguments.append(invocation.arguments.last ?? prompt)
        }
        return result
    }
}

/// File-backed stdin avoids blocking a pipe on a large image payload. The file is unlinked before
/// launching; only its open descriptor remains, and nothing sensitive is placed in process arguments.
enum ProcessInput {
    static func file(_ data: Data?) throws -> FileHandle? {
        guard let data else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("stdin")
        try data.write(to: file)
        return try FileHandle(forReadingFrom: file)
    }
}


extension Machine {
    /// Keep remote copies outside the checkout, so attachments never become repository changes.
    /// Their stable paths remain available when the provider resumes the session.
    public func stageImages(_ images: [URL]) async throws -> [URL] {
        guard isRemote else { return images }
        var staged: [URL] = []
        for image in images {
            try Task.checkCancellation()
            let bytes = try Data(contentsOf: image)
            guard bytes.count <= ImageAttachment.maximumBytes else { throw ImageDelivery.Failure("An attached image is too large.") }
            let filename = UUID().uuidString.lowercased() + ".png"
            let script = "umask 077; dir=\"$HOME/.cache/botchu/attachments\"; mkdir -p \"$dir\" && cat > \"$dir/$1.tmp\" && mv \"$dir/$1.tmp\" \"$dir/$1\" && printf '%s\\n' \"$dir/$1\""
            let result = await run(["/bin/sh", "-c", script, "botchu", filename], in: "~", input: bytes)
            guard result.ok, let path = result.lastLine, path.hasPrefix("/"), path.hasSuffix("/" + filename) else {
                throw ImageDelivery.Failure("Couldn't copy the attached image to the task's host. Check its connection and try again.")
            }
            staged.append(URL(fileURLWithPath: path))
        }
        try Task.checkCancellation()
        return staged
    }
}
