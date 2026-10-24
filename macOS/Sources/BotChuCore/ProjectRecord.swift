import Foundation

/// The small, editable part of PROJECT.md. Unknown frontmatter and the Markdown body stay intact.
public struct ProjectMetadata: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case docs, library, local, hosted
        public var label: String {
            switch self {
            case .docs: "Docs · non-code"
            case .library: "Library · code"
            case .local: "Local app · code"
            case .hosted: "Hosted app · code"
            }
        }
        public var symbol: String { self == .docs ? "doc.text" : "chevron.left.forwardslash.chevron.right" }
    }
    public enum Status: String, CaseIterable, Sendable { case active, paused, maintenance, deprecated }
    public var name: String
    public var kind: Kind
    public var status: Status
    public var deploy: String
    public var merge: String

    public init(name: String, kind: Kind = .docs, status: Status = .active, deploy: String = "none", merge: String = "owner") {
        self.name = name; self.kind = kind; self.status = status; self.deploy = deploy; self.merge = merge
    }

    public var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the project a name." }
        if [name, deploy].contains(where: { $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }) {
            return "Metadata fields must fit on one line."
        }
        if !["owner", "agent"].contains(merge) { return "Choose who merges pull requests." }
        let target = deploy.trimmingCharacters(in: .whitespaces)
        if target == "none" { return nil }
        if kind == .docs { return "A non-code project uses ‘none’ for deployment." }
        let targets = target.split(separator: ",", omittingEmptySubsequences: false)
        var machines = Set<String>()
        var hostedTargets = 0
        if kind == .library, targets.count != 1 { return "A library has one registry target, or none." }
        for value in targets {
            let value = value.trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, parts[0] == "local", [.local, .hosted].contains(kind),
               (parts[1].first?.isLetter == true || parts[1].first?.isNumber == true),
               parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
               (parts[2].hasPrefix("~/") || parts[2].hasPrefix("/")), !parts[2].contains(where: \.isWhitespace),
               machines.insert(parts[1].lowercased()).inserted { continue }
            if parts.count == 2, !parts[1].isEmpty, !parts[1].contains(where: \.isWhitespace),
               (parts[0] == "vercel" && kind == .hosted || parts[0] == "registry" && kind == .library) {
                if parts[0] == "vercel" { hostedTargets += 1 }
                continue
            }
            return "Use none, local:<machine>:<path>, vercel:<project>, or registry:<name>, matching the project type. Separate targets with commas."
        }
        if kind == .hosted, targets.count > 1, hostedTargets != 1 { return "A hosted project with several targets needs exactly one Vercel target, plus its local targets." }
        if hostedTargets > 1 { return "Use one Vercel target per project." }
        return nil
    }
}

public struct ProjectRecord: Equatable, Codable, Sendable {
    public var text: String
    /// GitHub's blob SHA, nil when PROJECT.md does not exist yet.
    public var sha: String?
    public var exists: Bool { sha != nil }

    public init(text: String, sha: String?) { self.text = text; self.sha = sha }

    public struct Problem: Error, LocalizedError, Equatable, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private var newline: String { text.contains("\r\n") ? "\r\n" : "\n" }
    private var lines: [String] { text.components(separatedBy: newline) }
    private var end: Int? { lines.first == "---" ? lines.dropFirst().firstIndex(of: "---") : nil }
    private static let keys = ["name", "type", "status", "deploy", "merge"]

    /// Only simple, single-line fields are editable. Refuse ambiguous YAML instead of rewriting it.
    public func fields() throws -> [String: String] {
        guard let end else {
            if !exists { return [:] }
            throw Problem("PROJECT.md needs YAML frontmatter between --- lines before it can be edited here.")
        }
        var values: [String: String] = [:]
        var editableField = false
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if editableField, line.first?.isWhitespace == true {
                throw Problem("An editable field continues across multiple lines. Edit it on GitHub first.")
            }
            editableField = false
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            guard Self.keys.contains(key) else { continue }
            editableField = true
            guard values[key] == nil else { throw Problem("PROJECT.md contains more than one \(key) field. Resolve it on GitHub first.") }
            values[key] = try Self.scalar(String(line[line.index(after: colon)...]))
        }
        return values
    }

    public func metadata(repoName: String) throws -> ProjectMetadata {
        let values = try fields()
        let kind = values["type"].flatMap(ProjectMetadata.Kind.init(rawValue:))
        let status = values["status"].flatMap(ProjectMetadata.Status.init(rawValue:))
        if values["type"] != nil && kind == nil { throw Problem("This PROJECT.md uses an unsupported project type. Edit it on GitHub.") }
        if values["status"] != nil && status == nil { throw Problem("This PROJECT.md uses an unsupported status. Edit it on GitHub.") }
        if let merge = values["merge"], !["agent", "owner"].contains(merge) { throw Problem("This PROJECT.md uses an unsupported merge policy.") }
        return ProjectMetadata(name: values["name"] ?? repoName, kind: kind ?? .docs, status: status ?? .active,
                               deploy: values["deploy"] ?? "none", merge: values["merge"] ?? "owner")
    }

    public func updating(_ metadata: ProjectMetadata) throws -> String {
        if let problem = metadata.problem { throw Problem(problem) }
        let old = try fields()
        let values = ["name": metadata.name.trimmingCharacters(in: .whitespaces), "type": metadata.kind.rawValue,
                      "status": metadata.status.rawValue, "deploy": metadata.deploy.trimmingCharacters(in: .whitespaces), "merge": metadata.merge]
        var updated = lines
        if let end {
            for index in 1..<end {
                guard let colon = updated[index].firstIndex(of: ":") else { continue }
                let key = String(updated[index][..<colon])
                if let value = values[key], old[key] != value { updated[index] = "\(key): \(Self.encoded(value, key: key))" }
            }
            updated.insert(contentsOf: Self.keys.filter { old[$0] == nil }.map { "\($0): \(Self.encoded(values[$0]!, key: $0))" }, at: end)
            return updated.joined(separator: newline)
        }
        // A minimal record makes no claim that the repository follows the full workspace standard.
        return (["---"] + Self.keys.map { "\($0): \(Self.encoded(values[$0]!, key: $0))" } + ["---", "", "# \(metadata.name)", ""]).joined(separator: "\n")
    }

    static func scalar(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            // Find the closing quote, respecting escaped quotes; comments may follow it.
            var escaped = false
            for index in value.indices.dropFirst() {
                if value[index] == "\"", !escaped {
                    let quoted = String(value[...index])
                    let tail = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                    if (tail.isEmpty || tail.hasPrefix("#")), let data = quoted.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode(String.self, from: data) { return decoded }
                    break
                }
                escaped = value[index] == "\\" && !escaped
            }
            throw Problem("An editable field uses unsupported YAML quoting. Edit it on GitHub first.")
        }
        if value.hasPrefix("'") {
            var index = value.index(after: value.startIndex)
            var decoded = ""
            while index < value.endIndex {
                let next = value.index(after: index)
                if value[index] == "'" {
                    if next < value.endIndex, value[next] == "'" { decoded += "'"; index = value.index(after: next); continue }
                    let tail = value[next...].trimmingCharacters(in: .whitespaces)
                    if tail.isEmpty || tail.hasPrefix("#") { return decoded }
                    break
                }
                decoded.append(value[index]); index = next
            }
            throw Problem("An editable field has invalid YAML quoting.")
        }
        let plain = value.components(separatedBy: " #").first!.trimmingCharacters(in: .whitespaces)
        if plain.isEmpty || "|>&*!{[".contains(plain.first!) { throw Problem("An editable field needs a simple, single-line value.") }
        return plain
    }

    private static func encoded(_ value: String, key: String) -> String {
        // Existing workspace scripts read deploy as plain text, including non-ASCII paths.
        if key == "deploy" { return value }
        if key != "name", !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " _-./~:,".contains($0)) }),
           !value.contains(": "), !["true", "false", "null", "~"].contains(value.lowercased()) { return value }
        return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}
