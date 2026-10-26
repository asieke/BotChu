import Foundation

/// A document in the bot's folder, kept under its own name (`attachments/<id>/<name>`) so it opens
/// and drags out as itself. A remote queue bot's messages carry them both ways.
public struct FileAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    /// Its MIME type, when known.
    public let type: String?
    public let size: Int
    public init(id: UUID = UUID(), name: String, type: String? = nil, size: Int) {
        self.id = id; self.name = Self.safeName(name); self.type = type; self.size = size
    }
    public static let maximumCount = 8
    public static let maximumBytes = 10 * 1024 * 1024

    /// One path component that can't leave its folder or hide: no separators, control or
    /// direction characters, or leading dots, at most 120 characters with its extension kept.
    public static func safeName(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return " "
            default: return Character(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 120 {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 16 ? "" : "." + ext
            name = String(name.prefix(120 - keep.count)).trimmingCharacters(in: .whitespaces) + keep
        }
        return name.isEmpty ? "file" : name
    }
}

extension BotHome {
    public init(url: URL) { self.url = url }

    public func fileURL(_ file: FileAttachment) -> URL {
        url.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(file.id.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(file.name)
    }

    public func saveFile(_ data: Data, name: String, type: String?, id: UUID = UUID()) throws -> FileAttachment {
        guard !data.isEmpty, data.count <= FileAttachment.maximumBytes else {
            throw ImageDelivery.Failure("Files must be no larger than 10 MB.")
        }
        let file = FileAttachment(id: id, name: name, type: type, size: data.count)
        let destination = fileURL(file)
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return file
    }

    /// Removes a file saved for a message that wasn't accepted.
    public func removeFile(_ file: FileAttachment) {
        try? FileManager.default.removeItem(at: fileURL(file).deletingLastPathComponent())
    }
}
