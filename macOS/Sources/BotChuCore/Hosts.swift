import Foundation

/// A computer besides this Mac that tasks can run on, reached over SSH (Settings ▸ Hosts). A task
/// for a repository that lives there works there: BotChu connects, makes the worktree and runs the
/// task's CLI there, and its output streams back here.
public struct SSHHost: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// What BotChu shows for it, such as "Omarchy".
    public var nickname: String
    /// What follows `ssh`: an alias from ~/.ssh/config, a host name, or `user@host`.
    public var destination: String
    /// What PROJECT.md's `deploy` calls it (`local:<machine>:<path>`), which isn't always its SSH
    /// host: a Tailscale address for a machine `deploy` calls `omarchy-1`, say.
    public var machine: String
    /// Where repositories are checked out there, and where BotChu clones one that isn't yet.
    public var reposFolder: String
    /// Each account's command there, by account id, when it isn't the same as on this Mac (where the
    /// profile wrappers in `~/.local/bin` may not exist). Optional for hosts saved without it.
    public var commands: [String: String]?

    public init(id: UUID = UUID(), nickname: String, destination: String, machine: String = "", reposFolder: String = "~/apps",
                commands: [String: String]? = nil) {
        self.id = id
        self.nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        self.machine = machine.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reposFolder = Self.trimmedFolder(reposFolder)
        self.commands = commands
    }

    /// The account's command there, or nil to use this Mac's.
    public func command(for account: Account) -> String? {
        let command = commands?[account.id]?.trimmingCharacters(in: .whitespaces) ?? ""
        return command.isEmpty ? nil : command
    }

    /// Why BotChu can't use it, or nil when it can.
    public var problem: String? {
        if nickname.isEmpty { return "Give the host a nickname, such as Omarchy." }
        return Self.destinationProblem(destination) ?? Self.folderProblem(reposFolder)
    }

    /// Why BotChu can't put `destination` after `ssh`, or nil when it can: `host` or `user@host`,
    /// not starting with `-`, in letters, digits, `.`, `_`, `:` and `-`.
    public static func destinationProblem(_ destination: String) -> String? {
        if destination.isEmpty { return "Enter the SSH host: an alias from ~/.ssh/config, a host name, or user@host." }
        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        if parts.count > 2 { return "The SSH host has more than one @." }
        let allowed = { (c: Character, extra: String) in c.isASCII && (c.isLetter || c.isNumber || extra.contains(c)) }
        if parts.count == 2, parts[0].isEmpty || parts[0].hasPrefix("-") || !parts[0].allSatisfy({ allowed($0, "._-") }) {
            return "The user before the @ may only have letters, digits, ., _ and -."
        }
        let host = parts[parts.count - 1]
        if host.isEmpty || host.hasPrefix("-") || !host.allSatisfy({ allowed($0, "._:-") }) {
            return "The SSH host may only have letters, digits, ., _, : and -, and can't start with -."
        }
        return nil
    }

    /// Why BotChu can't use `path` as a folder there, or nil when it can: `~`, or starting with `/` or `~/`.
    public static func folderProblem(_ path: String) -> String? {
        if path.isEmpty { return "Enter a folder, such as ~/apps." }
        if path != "~", !path.hasPrefix("/"), !path.hasPrefix("~/") { return "The folder starts with / or ~/ (or is ~)." }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "The folder has a line break." }
        return nil
    }

    /// The machine name a host starts with: its SSH host's short name, without the user or the
    /// domain (`root@srv1902831.example.net` is `srv1902831`).
    public static func machineName(destination: String) -> String {
        let host = destination.split(separator: "@").last.map(String.init) ?? destination
        return host.split(separator: ".").first.map(String.init) ?? host
    }

    /// A folder as typed, without the spaces around it or a trailing `/`.
    static func trimmedFolder(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Where a repository is worked on: its checkout's folder on this Mac, or on a host.
public struct RepoLocation: Codable, Hashable, Sendable {
    /// The host it is on; nil for this Mac.
    public var hostID: UUID?
    /// The checkout's folder there: absolute, or (on a host) starting with `~/`.
    public var path: String

    public init(hostID: UUID? = nil, path: String) {
        self.hostID = hostID
        self.path = SSHHost.trimmedFolder(path)
    }
}

/// Which computer and folder each repository is worked on.
public enum Locations {
    /// Where a repository is worked on: where its owner chose (on a host still in Settings), else in
    /// the repositories folder on this Mac, wherever PROJECT.md's `deploy` runs it.
    public static func resolve(repo: String, chosen: RepoLocation?, hosts: [SSHHost], reposRoot: String) -> RepoLocation {
        if let chosen, chosen.hostID == nil || hosts.contains(where: { $0.id == chosen.hostID }) { return chosen }
        return RepoLocation(path: (reposRoot as NSString).appendingPathComponent(TaskNaming.repoName(repo)))
    }

    /// This Mac's short name, as PROJECT.md's `deploy` calls it: its LocalHostName, else its host
    /// name up to the first dot.
    public static func thisMacName() -> String {
        localHostName() ?? ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
    }

    private static func localHostName() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--get", "LocalHostName"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !name.isEmpty ? name : nil
    }
}
