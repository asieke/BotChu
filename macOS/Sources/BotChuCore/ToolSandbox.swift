import Foundation

/// Blocks tools in a turn on This Mac (#246): the turn's login shell runs under `sandbox-exec`
/// with a profile that allows everything except running or reading the blocked tools' files.
/// That stops them by name, by path, through a link made at any time, through an interpreter, and
/// as a copy or hard link made during the turn. It isn't a sandbox otherwise: it doesn't stop a
/// copy that was already elsewhere or is downloaded, the service's API reached another way,
/// connectors, or anything on another computer. A turn keeps the profile it started with.
public enum ToolSandbox {
    public static let launcher = "/usr/bin/sandbox-exec"

    /// What a profile denies: files no process may run or read, and folders whose files none may.
    public struct Rules: Equatable, Sendable {
        public var files: [String]
        public var folders: [String]

        public init(files: [String] = [], folders: [String] = []) {
            self.files = files
            self.folders = folders
        }

        public var isEmpty: Bool { files.isEmpty && folders.isEmpty }
    }

    /// Files a policy never blocks, whatever a tool's link leads to: the shells and launchers every
    /// turn needs.
    static let protected: Set<String> = ["/bin/sh", "/bin/zsh", "/bin/bash", "/bin/dash", "/usr/bin/env", "/usr/bin/sandbox-exec",
                                         "/usr/bin/login", "/usr/bin/arch"]

    /// Commands a policy never blocks, by name, whatever leads to them: SSH and its file transfers,
    /// which deploy scripts and remote work use (#246), git, and the shells and launchers every
    /// turn needs.
    public static let neverBlocked: Set<String> = ["ssh", "scp", "sftp", "rsync", "ssh-agent", "ssh-add", "ssh-keygen", "ssh-keyscan",
                                                   "ssh-copy-id", "tailscale", "git", "sh", "zsh", "bash", "dash", "env", "sandbox-exec",
                                                   "login", "arch"]

    /// Launchers that many commands lead to (version managers' shims). A tool's link to one is
    /// blocked, but not the launcher, which the agent's other tools need.
    static let sharedLaunchers: Set<String> = ["mise", "rtx", "volta-shim", "volta", "asdf", "proto", "rbenv", "pyenv", "nodenv",
                                               "goenv", "jenv", "rustup", "node", "python", "python3", "ruby", "bun", "deno"]

    /// The rules that block `locations`. Each path found and the file it leads to; and, for a tool
    /// that Homebrew or npm installed, its whole package, so an upgrade during the turn, or another
    /// file of the same tool, stays blocked too.
    public static func rules(blocking locations: [ToolLocation]) -> Rules {
        var files: [String] = []
        var folders: [String] = []
        for location in locations {
            let name = (location.path as NSString).lastPathComponent
            let real = location.realPath
            let realName = (real as NSString).lastPathComponent
            guard !neverBlocked.contains(name.lowercased()), !neverBlocked.contains(realName.lowercased()) else { continue }
            if !protected.contains(location.path) { files.append(location.path) }
            guard !protected.contains(real), !sharedLaunchers.contains(realName) || realName == name else { continue }
            files.append(real)
            if let package = package(of: real) { folders.append(package) }
        }
        var seenFiles = Set<String>(), seenFolders = Set<String>()
        files = files.filter { usable($0) && seenFiles.insert($0).inserted }
        folders = folders.filter { usable($0) && seenFolders.insert($0).inserted }
        return Rules(files: files, folders: folders)
    }

    /// The package a file is part of: an npm package (`…/node_modules/<name>`,
    /// `…/node_modules/@scope/<name>`) or else a Homebrew keg (`…/Cellar/<formula>`,
    /// `…/Caskroom/<cask>`), never a language runtime's keg, which the agent's other tools need.
    static func package(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let index = parts.lastIndex(of: "node_modules") {
            let last = index + (parts.indices.contains(index + 1) && parts[index + 1].hasPrefix("@") ? 2 : 1)
            return last < parts.count - 1 ? parts[...last].joined(separator: "/") : nil
        }
        for marker in ["Cellar", "Caskroom"] {
            guard let index = parts.lastIndex(of: marker), index >= 2, index + 1 < parts.count - 1 else { continue }
            let name = parts[index + 1].lowercased()
            guard !runtimes.contains(where: { name == $0 || name.hasPrefix($0 + "@") }) else { return nil }
            return parts[...(index + 1)].joined(separator: "/")
        }
        return nil
    }

    /// Kegs never blocked as a package: language runtimes, and what SSH and git come from.
    static let runtimes = ["node", "python", "ruby", "openjdk", "go", "deno", "bun", "perl", "php", "rust", "llvm",
                           "openssh", "rsync", "git", "tailscale"]

    /// A path a profile can name: absolute, without control characters, and never `/` itself.
    private static func usable(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count > 1 && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The profile for `rules`, or nil when they block nothing.
    public static func profile(_ rules: Rules) -> String? {
        guard !rules.isEmpty else { return nil }
        let filters = (rules.files.map { "(literal \(quoted($0)))" } + rules.folders.map { "(subpath \(quoted($0)))" })
            .map { "    " + $0 }.joined(separator: "\n")
        return """
            (version 1)
            (allow default)
            (deny process-exec*
            \(filters))
            (deny file-read-data
            \(filters))
            """
    }

    /// A path as a profile's string.
    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// What a turn runs: `executable` with `arguments`, under `profile` when there is one.
    public static func launch(_ executable: String, _ arguments: [String], profile: String?) -> (executable: String, arguments: [String]) {
        guard let profile else { return (executable, arguments) }
        return (launcher, ["-p", profile, executable] + arguments)
    }

    public struct Unavailable: LocalizedError, Equatable {
        public var errorDescription: String? {
            "BotChu couldn't block the tools that are off: \(ToolSandbox.launcher) is missing on this Mac. Turn tool enforcement off in Skills & Tools to run turns without it."
        }
    }

    /// A CLI that runs its shell in a macOS sandbox of its own, which macOS won't start inside a
    /// turn's profile (`sandbox_apply: Operation not permitted`), so every shell command it ran
    /// would fail. Muse does (verified with Muse 1.4 on 2026-10-28); Claude Code, Codex and
    /// Antigravity, as BotChu runs them, don't.
    public struct SandboxedCLI: LocalizedError, Equatable {
        public let kind: AgentKind
        public var errorDescription: String? {
            "\(kind.displayName) runs its shell in its own macOS sandbox, which can’t start inside BotChu’s tool blocking. Turn Enforce off in Skills & Tools to run \(kind.displayName) turns on This Mac."
        }
    }

    /// The CLIs whose turns can't run under a profile (`SandboxedCLI`).
    public static let sandboxedCLIs: Set<AgentKind> = [.muse]

    /// The profile a turn on This Mac starts with, for the inventory as it is now. Throws when
    /// tools should be blocked and this Mac, or the turn's CLI (`kind`), can't, so a turn never
    /// runs unblocked by mistake.
    public static func profile(for inventory: ToolInventory, kind: AgentKind? = nil, fileManager: FileManager = .default) throws -> String? {
        guard let profile = profile(rules(blocking: inventory.blockedLocations())) else { return nil }
        guard fileManager.isExecutableFile(atPath: launcher) else { throw Unavailable() }
        if let kind, sandboxedCLIs.contains(kind) { throw SandboxedCLI(kind: kind) }
        return profile
    }
}
