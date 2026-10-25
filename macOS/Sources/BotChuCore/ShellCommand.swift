import Foundation

/// A shell command line as far as the chat needs to understand it: the simple commands it runs
/// (through `&&`, `||`, `;`, pipes, newlines, subshells and `$(…)`), their words with quotes
/// removed, the files they write with `>`, and their heredocs skipped as data. It is not the whole
/// shell language: what isn't understood counts as changing something, so a command is only ever
/// folded into exploration when every part of it is known to just read.
public struct ShellCommand: Equatable, Sendable {
    public struct Simple: Equatable, Sendable {
        /// Words with quotes removed; a command substitution stands as `$(…)`.
        public var words: [String] = []
        /// Where `>`, `>>` and `&>` write (not /dev/null or another descriptor).
        public var writes: [String] = []
        /// Files read with `<`.
        public var inputs: [String] = []
        /// The folder an earlier `cd` in the line moved to, if any.
        public var directory: String?
        /// Reads the previous command's output through a pipe.
        public var piped = false
        /// Runs in the background (`&`).
        public var background = false
        /// Has a heredoc or here-string as its input.
        public var heredoc = false
    }

    public var commands: [Simple]
    /// What `$(…)` and backticks run.
    public var substitutions: [ShellCommand]
    /// Only part of it was read: it was longer than `longest`, or its substitutions nested deeper
    /// than `deepest`. What the rest does isn't known, so it never counts as only reading.
    public var truncated = false

    /// The most of a command line that is read, in characters: a script in a heredoc can be long.
    public static let longest = 100_000
    /// The deepest `$(…)` inside `$(…)` that is followed.
    public static let deepest = 16

    public init(_ line: String) {
        self.init(line, level: 0)
    }

    init(_ line: String, level: Int) {
        let text = line.utf8.count > Self.longest ? String(line.prefix(Self.longest)) : line
        var parser = ShellParser(Array(text), start: 0, closing: nil, level: level)
        parser.run()
        commands = parser.commands
        substitutions = parser.substitutions
        truncated = parser.tooDeep || text.utf8.count < line.utf8.count
    }

    init(commands: [Simple], substitutions: [ShellCommand], truncated: Bool = false) {
        self.commands = commands
        self.substitutions = substitutions
        self.truncated = truncated
    }

    /// Every simple command, including those inside substitutions.
    public var allCommands: [Simple] { commands + substitutions.flatMap(\.allCommands) }
}

/// A recursive reader of one command line, or of one `$(…)` inside it (`closing` is `)`).
struct ShellParser {
    let chars: [Character]
    var index: Int
    let closing: Character?
    /// How many substitutions this one is inside.
    let level: Int
    /// A substitution nested deeper than `ShellCommand.deepest` was read as plain text.
    var tooDeep = false
    var commands: [ShellCommand.Simple] = []
    var substitutions: [ShellCommand] = []
    private var current = ShellCommand.Simple()
    private var word = ""
    private var inWord = false
    private var pending: Redirect?
    private var heredocs: [(delimiter: String, stripTabs: Bool)] = []
    private var directory: String?
    private var nextPiped = false
    private var depth = 0

    private enum Redirect { case write, input, heredoc(stripTabs: Bool), hereString, duplicate }

    init(_ chars: [Character], start: Int, closing: Character?, level: Int = 0) {
        self.chars = chars
        index = start
        self.closing = closing
        self.level = level
    }

    private func peek(_ offset: Int = 1) -> Character? {
        index + offset < chars.count ? chars[index + offset] : nil
    }

    mutating func run() {
        while index < chars.count {
            let c = chars[index]
            switch c {
            case " ", "\t", "\r":
                endWord(); index += 1
            case "\n":
                endWord(); endCommand(); index += 1; skipHeredocs()
            case "\\":
                if peek() == "\n" { index += 2 } else if let next = peek() { append(next); index += 2 } else { index += 1 }
            case "'":
                inWord = true
                index += 1
                while index < chars.count, chars[index] != "'" { word.append(chars[index]); index += 1 }
                index += 1
            case "\"":
                readDoubleQuoted()
            case "$":
                readDollar()
            case "`":
                readBackticks()
            case "#" where !inWord:
                while index < chars.count, chars[index] != "\n" { index += 1 }
            case ";":
                endWord(); endCommand(); index += 1
            case "&":
                if peek() == "&" {
                    endWord(); endCommand(); index += 2
                } else if peek() == ">" {
                    endWord(); index += 2
                    if index < chars.count, chars[index] == ">" { index += 1 }
                    pending = .write
                } else {
                    endWord(); current.background = true; endCommand(); index += 1
                }
            case "|":
                endWord()
                if peek() == "|" {
                    endCommand(); index += 2
                } else {
                    endCommand(); nextPiped = true; index += 1
                    if index < chars.count, chars[index] == "&" { index += 1 }
                }
            case ">", "<":
                readRedirect(c)
            case "(":
                endWord(); endCommand(); depth += 1; index += 1
            case ")":
                if let closing, closing == ")", depth == 0 {
                    endWord(); endCommand()
                    return
                }
                endWord(); endCommand(); depth = max(0, depth - 1); index += 1
            default:
                append(c); index += 1
            }
        }
        endWord()
        endCommand()
    }

    private mutating func append(_ c: Character) {
        word.append(c)
        inWord = true
    }

    private mutating func readDoubleQuoted() {
        inWord = true
        index += 1
        while index < chars.count, chars[index] != "\"" {
            let c = chars[index]
            if c == "\\", let next = peek(), "\"\\$`\n".contains(next) {
                if next != "\n" { word.append(next) }
                index += 2
            } else if c == "$", peek() == "(" {
                readDollar()
            } else if c == "`" {
                readBackticks()
            } else {
                word.append(c)
                index += 1
            }
        }
        index += 1
    }

    private mutating func readDollar() {
        inWord = true
        if peek() == "(" && peek(2) == "(" {
            // Arithmetic: kept as text up to the matching `))`.
            var parens = 0
            while index < chars.count {
                let c = chars[index]
                word.append(c)
                index += 1
                if c == "(" { parens += 1 } else if c == ")" { parens -= 1; if parens == 0 { break } }
            }
        } else if peek() == "(", level >= ShellCommand.deepest {
            // Too deep to follow (and to recurse into): read on as text.
            tooDeep = true
            word += "$("
            index += 2
        } else if peek() == "(" {
            var inner = ShellParser(chars, start: index + 2, closing: ")", level: level + 1)
            inner.run()
            tooDeep = tooDeep || inner.tooDeep
            substitutions.append(ShellCommand(commands: inner.commands, substitutions: inner.substitutions, truncated: inner.tooDeep))
            word += "$(…)"
            index = inner.index + 1
        } else if peek() == "{" {
            while index < chars.count, chars[index] != "}" { word.append(chars[index]); index += 1 }
            if index < chars.count { word.append("}"); index += 1 }
        } else {
            word.append("$")
            index += 1
        }
    }

    private mutating func readBackticks() {
        inWord = true
        var end = index + 1
        while end < chars.count, chars[end] != "`" { end += chars[end] == "\\" ? 2 : 1 }
        let body = String(chars[min(index + 1, chars.count)..<min(end, chars.count)])
        if level >= ShellCommand.deepest {
            tooDeep = true
        } else {
            let inner = ShellCommand(body, level: level + 1)
            tooDeep = tooDeep || inner.truncated
            substitutions.append(inner)
        }
        word += "$(…)"
        index = min(end + 1, chars.count)
    }

    private mutating func readRedirect(_ c: Character) {
        // A descriptor number right before the operator (`2>`) belongs to it, not the command.
        if inWord, !word.isEmpty, word.allSatisfy(\.isNumber) {
            word = ""
            inWord = false
        } else {
            endWord()
        }
        index += 1
        if c == ">" {
            if index < chars.count, chars[index] == ">" { index += 1 }
            if index < chars.count, chars[index] == "|" { index += 1 }
            if index < chars.count, chars[index] == "&" {
                index += 1
                pending = .duplicate
            } else {
                pending = .write
            }
        } else if index < chars.count, chars[index] == "<" {
            index += 1
            if index < chars.count, chars[index] == "<" {
                index += 1
                pending = .hereString
            } else {
                let strip = index < chars.count && chars[index] == "-"
                if strip { index += 1 }
                pending = .heredoc(stripTabs: strip)
            }
            current.heredoc = true
        } else if index < chars.count, chars[index] == "&" {
            index += 1
            pending = .duplicate
        } else if index < chars.count, chars[index] == ">" {
            index += 1
            pending = .write
        } else {
            pending = .input
        }
    }

    private mutating func endWord() {
        guard inWord else { return }
        let text = word
        word = ""
        inWord = false
        if let redirect = pending {
            pending = nil
            switch redirect {
            case .write:
                if !["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty", "-"].contains(text) { current.writes.append(text) }
            case .input:
                current.inputs.append(text)
            case .heredoc(let strip):
                heredocs.append((text, strip))
            case .hereString, .duplicate:
                break
            }
            return
        }
        current.words.append(text)
    }

    private mutating func endCommand() {
        if !current.words.isEmpty || !current.writes.isEmpty {
            current.directory = directory
            current.piped = nextPiped
            nextPiped = false
            // `cd` moves the commands after it, until the line ends.
            if let first = current.words.first, first == "cd" || first == "pushd" {
                let target = current.words.dropFirst().first { !$0.hasPrefix("-") } ?? "~"
                directory = ShellPaths.join(directory, target)
            }
            commands.append(current)
        }
        current = ShellCommand.Simple()
    }

    /// After a line with heredocs, their bodies are data up to each delimiter line.
    private mutating func skipHeredocs() {
        while !heredocs.isEmpty {
            let (delimiter, strip) = heredocs.removeFirst()
            while index < chars.count {
                var end = index
                while end < chars.count, chars[end] != "\n" { end += 1 }
                var line = String(chars[index..<end])
                index = min(end + 1, chars.count)
                if strip { line = String(line.drop(while: { $0 == "\t" })) }
                if line.trimmingCharacters(in: .whitespaces) == delimiter { break }
            }
        }
    }
}

enum ShellPaths {
    /// `path` as seen from `directory`: absolute and home paths stand alone.
    static func join(_ directory: String?, _ path: String) -> String {
        guard let directory, !directory.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return path }
        if path == "." { return directory }
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return base + "/" + (path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
    }
}

/// What a command line does, as exploration counts it: files read (with their line ranges),
/// folders listed, searches, fetches and other read-only commands, or that it changes something.
public struct ShellFacts: Equatable, Sendable {
    public struct Read: Equatable, Sendable {
        public var path: String
        public var range: LineRange?
    }

    public struct Search: Equatable, Sendable {
        public var pattern: String
        public var paths: [String]
    }

    /// Something in it isn't known to only read: a build, a test, a write, a long or unknown command.
    public var changes = false
    public var reads: [Read] = []
    public var lists: [String] = []
    public var searches: [Search] = []
    public var fetches: [String] = []
    /// Other read-only commands, by their first words (`git status -sb`).
    public var inspections: [String] = []
    /// `botchu-subagent call`, `spawn` and `wait` in it.
    public var delegation: DelegationCall?
    /// The commands that do something (not `cd`, `export` and the like), in order.
    public var meaningful: [ShellCommand.Simple] = []
    /// The words each `for name in …` loop goes through, by its variable.
    private var loops: [String: [String]] = [:]

    public init(_ command: ShellCommand) {
        if command.truncated { changes = true }
        for simple in command.commands { add(simple) }
        for substitution in command.substitutions {
            let inner = ShellFacts(substitution)
            changes = changes || inner.changes
            reads += inner.reads
            lists += inner.lists
            searches += inner.searches
            fetches += inner.fetches
            inspections += inner.inspections
            if let call = inner.delegation { delegation = (delegation ?? DelegationCall()).merged(with: call) }
        }
    }

    public init(_ line: String) { self.init(ShellCommand(line)) }

    private mutating func add(_ simple: ShellCommand.Simple) {
        if !simple.writes.isEmpty || simple.background { changes = true }
        if simple.words.count >= 3, simple.words[0] == "for", simple.words[2] == "in" {
            loops[simple.words[1]] = Array(simple.words.dropFirst(3))
        }
        let effect = ShellFacts.classify(simple)
        if case .neutral = effect { return }
        // A filter after a pipe (`| head -20`, `| rg foo`) is part of the command before it.
        if simple.piped, !meaningful.isEmpty {
            switch effect {
            case .read(let paths, let range) where paths.isEmpty:
                if let range, !reads.isEmpty { reads[reads.count - 1].range = range }
                return
            case .search(_, let paths) where paths.isEmpty:
                return
            case .inspect, .list([]):
                return
            default:
                break
            }
        }
        meaningful.append(simple)
        switch effect {
        case .neutral: break
        case .changes: changes = true
        case .delegation(let call):
            changes = true
            delegation = (delegation ?? DelegationCall()).merged(with: call)
        case .read(let paths, let range):
            if paths.isEmpty {
                inspections.append(ShellFacts.head(of: simple))
            } else {
                // `for f in a b; do cat "$f"`: the loop's files. Any other `$file` is only known
                // when it runs.
                let files = paths.flatMap { path -> [String] in
                    let name = path.hasPrefix("${") ? String(path.dropFirst(2).dropLast()) : String(path.dropFirst())
                    if path.hasPrefix("$"), let words = loops[name] { return words }
                    return path.contains("$") ? [] : [path]
                }
                reads += files.map { Read(path: ShellPaths.join(simple.directory, $0), range: range) }
            }
        case .list(let paths):
            lists += (paths.isEmpty ? [simple.directory ?? "."] : paths.map { ShellPaths.join(simple.directory, $0) })
        case .search(let pattern, let paths):
            searches.append(Search(pattern: pattern, paths: paths.map { ShellPaths.join(simple.directory, $0) }))
        case .fetch(let target):
            fetches.append(target)
        case .inspect:
            inspections.append(ShellFacts.head(of: simple))
        }
    }

    /// Only reads: nothing in it changes anything, and it does something.
    public var readOnly: Bool { !changes && !meaningful.isEmpty }

    /// A command's program and leading options, as a row names it: `tail -n 30`, `git status -sb`.
    public static func head(of simple: ShellCommand.Simple, limit: Int = 4) -> String {
        split(simple, limit: limit).head.joined(separator: " ")
    }

    /// The words after what `head(of:)` shows: paths, patterns and the rest.
    public static func arguments(of simple: ShellCommand.Simple, limit: Int = 4) -> [String] {
        split(simple, limit: limit).rest
    }

    private static func split(_ simple: ShellCommand.Simple, limit: Int) -> (head: [String], rest: [String]) {
        let words = Array(stripWrappers(simple.words))
        guard let first = words.first else { return ([], []) }
        let program = (first as NSString).lastPathComponent
        let values = valueFlags(for: program)
        var shown = [program]
        var rest: [String] = []
        var index = 1
        // Subcommands (`git status`, `gh pr view`) belong to the name; global options before them
        // (`git -C path`) are left for the arguments.
        if let taking = subcommandDepth[program] {
            var taken = 0
            while index < words.count, taken < taking {
                let word = words[index]
                if word.hasPrefix("-") {
                    rest.append(word)
                    if values.contains(word), index + 1 < words.count { rest.append(words[index + 1]); index += 1 }
                } else {
                    shown.append(word)
                    taken += 1
                }
                index += 1
            }
        }
        while index < words.count, shown.count < limit, words[index].hasPrefix("-"), words[index] != "-" {
            shown.append(words[index])
            if index + 1 < words.count, values.contains(words[index]) {
                shown.append(words[index + 1])
                index += 1
            }
            index += 1
        }
        return (shown, rest + words[min(index, words.count)...])
    }

    static let subcommandDepth: [String: Int] = [
        "git": 1, "gh": 2, "swift": 1, "npm": 1, "pnpm": 1, "yarn": 1, "brew": 1, "xcrun": 1, "defaults": 1,
        "botchu-subagent": 1, "botchu-task": 1, "launchctl": 1, "pip": 1, "pip3": 1, "go": 1, "cargo": 1, "docker": 1, "kubectl": 1,
    ]

    // MARK: Classification

    enum Effect: Equatable {
        case neutral
        case read(paths: [String], range: LineRange?)
        case list([String])
        case search(pattern: String, paths: [String])
        case fetch(String)
        case inspect
        case delegation(DelegationCall)
        case changes
    }

    static let neutral: Set<String> = [
        "cd", "pushd", "popd", "export", "set", "unset", "shopt", "local", "declare", "typeset", "alias", "unalias",
        "source", ".", ":", "true", "false", "exit", "return", "wait", "trap", "ulimit", "fi", "done", "esac", "}", "{",
        "then", "else", "do", "break", "continue", "shift", "read", "setopt", "unsetopt", "emulate", "hash", "rehash",
    ]

    static let readers: Set<String> = ["cat", "head", "tail", "less", "more", "nl", "bat", "batcat", "strings", "xxd",
                                       "hexdump", "od", "tac", "rev", "sed", "awk", "gawk", "nawk", "mawk"]
    static let listers: Set<String> = ["ls", "tree", "exa", "eza", "lsd"]
    static let searchers: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag", "ack", "find", "fd", "fdfind", "mdfind", "locate"]
    static let inspectors: Set<String> = [
        "wc", "file", "stat", "du", "df", "pwd", "which", "whereis", "type", "echo", "printf", "test", "[", "[[",
        "basename", "dirname", "realpath", "readlink", "date", "uname", "whoami", "id", "hostname", "sw_vers", "uptime",
        "printenv", "ps", "pgrep", "lsof", "diff", "cmp", "comm", "cut", "tr", "column", "fold", "expand", "unexpand",
        "paste", "join", "seq", "jq", "md5", "md5sum", "shasum", "sha1sum", "sha256sum", "sha512sum", "cksum", "otool",
        "nm", "mdls", "vm_stat", "man", "tldr", "system_profiler", "ioreg", "dig", "host", "nslookup", "whois",
        "groups", "locale", "tty", "nproc", "arch", "cal", "getconf", "sysctl", "fc-list", "lipo", "dwarfdump",
    ]

    /// The words after env assignments and wrappers such as `env`, `time`, `command` and `xargs`.
    static func stripWrappers(_ words: [String]) -> ArraySlice<String> {
        var rest = words[...]
        while let first = rest.first {
            if isAssignment(first) {
                rest = rest.dropFirst()
                continue
            }
            switch (first as NSString).lastPathComponent {
            case "then", "else", "elif", "do", "if", "while", "until", "!", "{", "time", "command", "builtin", "exec", "nocorrect", "noglob":
                if first == "command", rest.dropFirst().first == "-v" { return rest }
                rest = rest.dropFirst()
            case "env":
                var next = rest.dropFirst()
                while let word = next.first, word.hasPrefix("-") || isAssignment(word) {
                    next = next.dropFirst()
                    if word == "-u" || word == "-C" || word == "-S" { next = next.dropFirst() }
                }
                if next.isEmpty { return rest }
                rest = next
            case "nice":
                rest = rest.dropFirst()
                if rest.first == "-n" { rest = rest.dropFirst(2) } else if rest.first?.hasPrefix("-") == true { rest = rest.dropFirst() }
            case "timeout", "gtimeout":
                rest = rest.dropFirst()
                while rest.first?.hasPrefix("-") == true { rest = rest.dropFirst() }
                rest = rest.dropFirst()
            case "stdbuf":
                rest = rest.dropFirst()
                while rest.first?.hasPrefix("-") == true { rest = rest.dropFirst() }
            default:
                return rest
            }
        }
        return rest
    }

    /// A line number or count in a command, if it's a sane one, so the range after it can't overflow.
    static func lineNumber(_ text: some StringProtocol) -> Int? {
        guard let value = Int(text), (0...1_000_000_000).contains(value) else { return nil }
        return value
    }

    /// `-n`, `-En`: short options run together, one of them among `letters`.
    static func isShortCluster(_ word: String, containing letters: String) -> Bool {
        guard word.hasPrefix("-"), !word.hasPrefix("--"), word.count >= 2 else { return false }
        let options = word.dropFirst()
        return options.allSatisfy(\.isLetter) && options.contains(where: letters.contains)
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first.map { $0.isLetter || $0 == "_" } == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func classify(_ simple: ShellCommand.Simple) -> Effect {
        let words = Array(stripWrappers(simple.words))
        guard let first = words.first else { return .neutral }
        let program = (first as NSString).lastPathComponent
        let args = Array(words.dropFirst())
        if neutral.contains(program) || (program == "for" || program == "select" || program == "case" || program == "function") {
            return .neutral
        }
        // `name()` function definitions and bare `)` case labels.
        if program.hasSuffix(")") { return .neutral }
        if program == "botchu-subagent" { return DelegationCall.parse(words).map(Effect.delegation) ?? .inspect }
        if ["sudo", "doas", "nohup", "watch", "caffeinate", "sleep", "open", "osascript", "eval", "ssh", "su"].contains(program) {
            return .changes
        }
        if args.count == 1, ["--version", "-version", "-V", "--help", "-h", "help", "version"].contains(args[0]) { return .inspect }
        switch program {
        case "cat", "less", "more", "bat", "batcat", "strings", "xxd", "hexdump", "od", "tac", "rev":
            return .read(paths: positionals(args, values: ["-s", "-n", "-c", "-l", "--style", "--theme", "--language", "-H", "--line-range"]), range: nil)
        case "nl":
            return .read(paths: positionals(args, values: ["-b", "-s", "-w", "-v", "-i", "-n", "-d", "-l", "-h", "-f"]), range: nil)
        case "head":
            return headTail(args, tail: false)
        case "tail":
            // Following a file never ends: a long-running command, not a read.
            if args.contains(where: { $0 == "--follow" || $0.hasPrefix("--follow=") || isShortCluster($0, containing: "fF") }) {
                return .changes
            }
            return headTail(args, tail: true)
        case "sed":
            return sed(args)
        case "awk", "gawk", "nawk", "mawk":
            return awk(args)
        case "ls", "tree", "exa", "eza", "lsd":
            return .list(positionals(args, values: ["-L", "-I", "-P", "--ignore", "--color", "--sort", "--time-style", "-T", "-w"]))
        case "grep", "egrep", "fgrep":
            return search(args, values: ["-e", "-f", "-m", "-A", "-B", "-C", "-d", "-D", "--include", "--exclude",
                                         "--exclude-dir", "--label", "--context", "--max-count", "--regexp", "--file",
                                         "--after-context", "--before-context", "--color", "--colour", "--binary-files"])
        case "rg":
            if args.contains("--files") {
                return .search(pattern: "files", paths: positionals(args, values: rgValues))
            }
            return search(args, values: rgValues)
        case "ag", "ack":
            return search(args, values: ["-G", "--ignore", "--ignore-dir", "-m", "-A", "-B", "-C", "--depth", "--type"])
        case "fd", "fdfind":
            if args.contains(where: { ["-x", "--exec", "-X", "--exec-batch"].contains($0) }) { return .changes }
            let found = positionals(args, values: ["-e", "--extension", "-t", "--type", "-d", "--max-depth", "-E", "--exclude",
                                                   "--min-depth", "--exact-depth", "-S", "--size", "--changed-within", "-j", "-c", "--color", "-g"])
            return .search(pattern: found.first ?? "", paths: Array(found.dropFirst()))
        case "find":
            return find(args)
        case "mdfind", "locate":
            return .search(pattern: positionals(args, values: ["-onlyin", "-name", "-attr", "-s"]).joined(separator: " "), paths: [])
        case "git":
            return git(args)
        case "gh":
            return gh(args)
        case "curl":
            return curl(args)
        case "wget":
            let toStdout = args.contains { $0 == "-qO-" || $0 == "-O-" || $0 == "--output-document=-" || $0 == "-qO" } ||
                zip(args, args.dropFirst()).contains { ($0 == "-O" || $0 == "-qO") && $1 == "-" }
            return toStdout ? .fetch(args.last { !$0.hasPrefix("-") } ?? "") : .changes
        case "sort":
            return args.contains { $0 == "-o" || $0.hasPrefix("--output") || ($0.hasPrefix("-o") && !$0.hasPrefix("--")) } ? .changes : .inspect
        case "uniq":
            return positionals(args, values: ["-f", "-s", "-w"]).count >= 2 ? .changes : .inspect
        case "env", "printenv":
            return .inspect
        case "sysctl":
            return args.contains { $0 == "-w" || $0.contains("=") } ? .changes : .inspect
        case "swift":
            return ["describe", "dump-package", "show-dependencies", "tools-version"].contains(args.dropFirst().first ?? "")
                && args.first == "package" && !args.contains("--set") ? .inspect : .changes
        case "xcodebuild":
            return args.contains { ["-list", "-showsdks", "-showBuildSettings", "-showdestinations", "-version"].contains($0) } ? .inspect : .changes
        case "xcrun":
            if args.first == "simctl" { return args.dropFirst().first == "list" ? .inspect : .changes }
            return args.contains { ["--find", "-f", "--show-sdk-path", "--show-sdk-version", "--show-sdk-platform-path"].contains($0) } ? .inspect : .changes
        case "npm", "pnpm", "yarn":
            return ["ls", "list", "view", "info", "outdated", "why", "explain", "root", "prefix", "bin"].contains(args.first ?? "") ? .inspect : .changes
        case "pip", "pip3":
            return ["list", "show", "freeze", "check"].contains(args.first ?? "") ? .inspect : .changes
        case "brew":
            return ["list", "ls", "info", "search", "--prefix", "config", "deps", "uses", "outdated", "leaves", "desc", "doctor"].contains(args.first ?? "") ? .inspect : .changes
        case "go":
            return ["version", "env", "list", "doc"].contains(args.first ?? "") ? .inspect : .changes
        case "defaults":
            return ["read", "read-type", "domains", "find"].contains(args.first ?? "") ? .inspect : .changes
        case "plutil":
            return args.contains { $0 == "-p" || $0 == "-lint" } ? .inspect : .changes
        case "codesign":
            return args.contains { ["-d", "-dv", "-dvv", "-dvvv", "--display", "-v", "--verify"].contains($0) } && !args.contains { $0 == "-s" || $0 == "--sign" } ? .inspect : .changes
        case "launchctl":
            return ["list", "print", "blame", "dumpstate"].contains(args.first ?? "") ? .inspect : .changes
        case "log":
            return args.first == "show" ? .inspect : .changes
        case "diskutil":
            return ["list", "info"].contains(args.first ?? "") ? .inspect : .changes
        case "pmset":
            return args.first == "-g" ? .inspect : .changes
        case "base64":
            return args.contains { $0 == "-o" || $0 == "--output" || $0 == "-i" } ? .changes : .inspect
        case "yq":
            return args.contains { $0 == "-i" || $0 == "--inplace" } ? .changes : .inspect
        case "xargs":
            return xargs(args, simple: simple)
        default:
            return inspectors.contains(program) ? .inspect : .changes
        }
    }

    static let rgValues: Set<String> = [
        "-e", "--regexp", "-f", "--file", "-g", "--glob", "--iglob", "-t", "--type", "-T", "--type-not", "-m", "--max-count",
        "-A", "-B", "-C", "--after-context", "--before-context", "--context", "--max-depth", "-d", "-M", "--max-columns",
        "-j", "--threads", "--sort", "--sortr", "-E", "--encoding", "--colors", "--type-add", "-r", "--replace", "--pre",
        "--pre-glob", "--context-separator", "--field-match-separator", "--ignore-file", "--max-filesize", "--path-separator",
        "--color", "--colour",
    ]

    static func valueFlags(for program: String) -> Set<String> {
        switch program {
        case "head", "tail": ["-n", "-c"]
        case "sed": ["-e", "-f"]
        case "grep", "egrep", "fgrep": ["-e", "-f", "-m", "-A", "-B", "-C"]
        case "rg": rgValues
        case "git": ["-C", "-c"]
        case "gh": ["--repo", "-R"]
        case "nl": ["-b", "-s", "-w", "-v", "-i", "-n"]
        case "awk", "gawk": ["-F", "-v", "-f"]
        case "find": []
        default: []
        }
    }

    /// The words that aren't options or their values.
    static func positionals(_ args: [String], values: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        var optionsEnded = false
        while index < args.count {
            let word = args[index]
            if optionsEnded || !word.hasPrefix("-") || word == "-" {
                result.append(word)
            } else if word == "--" {
                optionsEnded = true
            } else if values.contains(word) {
                index += 1
            }
            index += 1
        }
        return result
    }

    private static func headTail(_ args: [String], tail: Bool) -> Effect {
        var count: Int?
        var fromStart: Int?
        var bytes = false
        var files: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            var value: String?
            if word == "-n" || word == "--lines" {
                value = index + 1 < args.count ? args[index + 1] : nil
                index += 1
            } else if word.hasPrefix("--lines=") {
                value = String(word.dropFirst(8))
            } else if word.hasPrefix("-n"), word.count > 2 {
                value = String(word.dropFirst(2))
            } else if word == "-c" || word.hasPrefix("--bytes") {
                bytes = true
                if word == "-c" { index += 1 }
            } else if word.hasPrefix("-"), word.count > 1, word.dropFirst().allSatisfy(\.isNumber) {
                value = String(word.dropFirst())
            } else if word.hasPrefix("+"), tail {
                value = word
            } else if !word.hasPrefix("-") || word == "-" {
                files.append(word)
            }
            if let value {
                if value.hasPrefix("+"), let n = lineNumber(value.dropFirst()) { fromStart = n } else { count = lineNumber(value) }
            }
            index += 1
        }
        guard !bytes else { return .read(paths: files, range: nil) }
        let range: LineRange
        if tail {
            range = fromStart.map { LineRange(start: $0, end: nil) } ?? LineRange(last: count ?? 10)
        } else {
            range = LineRange(start: 1, end: count ?? 10)
        }
        return .read(paths: files, range: range)
    }

    private static func sed(_ args: [String]) -> Effect {
        if args.contains(where: { $0.hasPrefix("--in-place") || isShortCluster($0, containing: "i") || ($0.hasPrefix("-i") && !$0.hasPrefix("--")) }) {
            return .changes
        }
        var script: String?
        var files: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if word == "-e" || word == "--expression" {
                if script == nil, index + 1 < args.count { script = args[index + 1] }
                index += 1
            } else if word == "-f" {
                return .changes
            } else if word.hasPrefix("-"), word != "-" {
                // -n, -E, -r, -u, -s: no values.
            } else if script == nil {
                script = word
            } else {
                files.append(word)
            }
            index += 1
        }
        // A script that writes (`w file`) or runs (`e`) changes something.
        if let script, script.range(of: #"(^|[;\s}])[0-9,$/]*\s*[we]\s"#, options: .regularExpression) != nil { return .changes }
        let quiet = args.contains { $0 == "--quiet" || $0 == "--silent" || isShortCluster($0, containing: "n") }
        return .read(paths: files, range: quiet ? script.flatMap(LineRange.init(sedScript:)) : nil)
    }

    private static func awk(_ args: [String]) -> Effect {
        if args.contains(where: { $0 == "-i" || $0 == "inplace" || $0.hasPrefix("-i") }) { return .changes }
        var program: String?
        var files: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if word == "-F" || word == "-v" {
                index += 1
            } else if word == "-f" {
                return .changes
            } else if word.hasPrefix("-"), word != "-" {
            } else if program == nil {
                program = word
            } else if !ShellFacts.isAssignment(word) {
                files.append(word)
            }
            index += 1
        }
        guard let program else { return .changes }
        if program.contains("system(") || program.range(of: #"print[f]?[^;}]*>"#, options: .regularExpression) != nil ||
            program.range(of: #"\|\s*""#, options: .regularExpression) != nil || program.contains("getline") && program.contains("|") {
            return .changes
        }
        return .read(paths: files, range: LineRange(awkProgram: program))
    }

    private static func search(_ args: [String], values: Set<String>) -> Effect {
        var pattern: String?
        var index = 0
        while index < args.count {
            if args[index] == "-e" || args[index] == "--regexp", index + 1 < args.count {
                pattern = pattern ?? args[index + 1]
            } else if args[index].hasPrefix("--regexp=") {
                pattern = pattern ?? String(args[index].dropFirst(9))
            }
            index += 1
        }
        let found = positionals(args, values: values)
        if let pattern { return .search(pattern: pattern, paths: found) }
        return .search(pattern: found.first ?? "", paths: Array(found.dropFirst()))
    }

    static let readOnlyExec: Set<String> = ["grep", "egrep", "fgrep", "rg", "cat", "head", "tail", "wc", "ls", "stat", "file",
                                            "basename", "dirname", "echo", "printf", "du", "md5", "md5sum", "shasum", "sha256sum",
                                            "nl", "strings", "otool", "test", "["]

    private static func find(_ args: [String]) -> Effect {
        var paths: [String] = []
        var index = 0
        while index < args.count, !args[index].hasPrefix("-"), !["(", "!", ")", ","].contains(args[index]) {
            paths.append(args[index])
            index += 1
        }
        var pattern: String?
        while index < args.count {
            let word = args[index]
            if ["-delete", "-fprint", "-fprint0", "-fprintf", "-fls"].contains(word) { return .changes }
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(word) {
                let program = index + 1 < args.count ? (args[index + 1] as NSString).lastPathComponent : ""
                guard readOnlyExec.contains(program) else { return .changes }
            }
            if ["-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-wholename"].contains(word), index + 1 < args.count {
                pattern = pattern.map { $0 + " " + args[index + 1] } ?? args[index + 1]
            }
            index += 1
        }
        return .search(pattern: pattern ?? "", paths: paths)
    }

    static let gitReading: Set<String> = [
        "status", "log", "diff", "show", "blame", "annotate", "shortlog", "describe", "rev-parse", "rev-list", "ls-files",
        "ls-tree", "ls-remote", "cat-file", "grep", "merge-base", "name-rev", "for-each-ref", "show-ref", "count-objects",
        "check-ignore", "check-attr", "var", "help", "version", "whatchanged", "range-diff", "cherry", "show-branch",
        "verify-commit", "verify-tag", "diff-tree", "diff-index", "diff-files", "fsck",
    ]

    private static func git(_ args: [String]) -> Effect {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"].contains(args[index]) { index += 1 }
            index += 1
        }
        guard index < args.count else { return .inspect }
        let sub = args[index]
        let rest = Array(args[(index + 1)...])
        let flagsOnly = rest.allSatisfy { $0.hasPrefix("-") }
        switch sub {
        case "grep":
            let found = positionals(rest, values: ["-e", "-f", "-m", "-A", "-B", "-C", "--max-depth"])
            return .search(pattern: found.first ?? "", paths: Array(found.dropFirst()))
        case "ls-files":
            return .list(positionals(rest, values: ["-x", "--exclude", "-X", "--exclude-from", "--format"]))
        case "diff":
            return rest.contains { $0.hasPrefix("--output") } ? .changes : .inspect
        case _ where gitReading.contains(sub):
            return .inspect
        case "branch":
            let listing: Set<String> = ["-a", "-r", "-v", "-vv", "--list", "-l", "--show-current", "--contains", "--merged",
                                        "--no-merged", "--sort", "--format", "--points-at", "--column", "--no-column",
                                        "--color", "--no-color", "--all", "--remotes", "--verbose", "-av", "-avv", "-rv"]
            return rest.isEmpty || rest.allSatisfy({ listing.contains($0) || $0.hasPrefix("--sort=") || $0.hasPrefix("--format=") })
                || rest.contains("--list") || rest.contains("--show-current") ? .inspect : .changes
        case "tag":
            return rest.isEmpty || rest.contains("-l") || rest.contains("--list") || rest.contains("--contains") || rest.contains("--points-at") ? .inspect : .changes
        case "remote":
            return rest.isEmpty || flagsOnly || ["show", "get-url"].contains(rest.first ?? "") ? .inspect : .changes
        case "config":
            return rest.contains { ["--get", "--get-all", "--list", "-l", "--get-regexp", "--get-urlmatch"].contains($0) } ? .inspect : .changes
        case "stash":
            return ["list", "show"].contains(rest.first ?? "") ? .inspect : .changes
        case "worktree":
            return rest.first == "list" ? .inspect : .changes
        case "reflog":
            return rest.isEmpty || rest.first == "show" || flagsOnly ? .inspect : .changes
        case "symbolic-ref":
            return positionals(rest, values: ["-m"]).count <= 1 && !rest.contains("-d") && !rest.contains("--delete") ? .inspect : .changes
        case "notes":
            return ["show", "list"].contains(rest.first ?? "") ? .inspect : .changes
        case "submodule":
            return rest.first == "status" ? .inspect : .changes
        default:
            return .changes
        }
    }

    private static func gh(_ args: [String]) -> Effect {
        let words = positionals(args, values: ["--repo", "-R", "--hostname", "--jq", "-q", "--template", "-t", "--json",
                                               "--limit", "-L", "--state", "-s", "--search", "-S", "--label", "-l", "--author",
                                               "-A", "--assignee", "-a", "--base", "-B", "--head", "-H", "--branch", "-b",
                                               "--workflow", "-w", "--commit", "-c", "--user", "-u", "--status", "--event", "-e",
                                               "--created", "--paginate", "--cache", "-H", "--header", "--preview", "-p"])
        guard let group = words.first else { return .inspect }
        let verb = words.dropFirst().first ?? ""
        let target = words.dropFirst(2).first ?? ""
        let name = (["gh", group, verb] + (target.isEmpty ? [] : [target])).joined(separator: " ")
        switch group {
        case "api":
            let writes = args.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) || $0.hasPrefix("--field=") || $0.hasPrefix("--raw-field=") }
            if writes { return .changes }
            for (flag, value) in zip(args, args.dropFirst()) where flag == "-X" || flag == "--method" {
                if !["GET", "HEAD"].contains(value.uppercased()) { return .changes }
            }
            if args.contains(where: { $0.hasPrefix("--method=") && !$0.uppercased().hasSuffix("GET") }) { return .changes }
            return .fetch("gh api " + verb)
        case "search", "status":
            return .fetch(name)
        case "auth":
            return verb == "status" ? .inspect : .changes
        case "browse":
            return .changes
        default:
            return ["view", "list", "status", "diff", "checks", "ls"].contains(verb) ? .fetch(name) : .changes
        }
    }

    private static func curl(_ args: [String]) -> Effect {
        let writing: Set<String> = ["-o", "-O", "--output", "--remote-name", "--remote-name-all", "-d", "--data", "--data-raw",
                                    "--data-binary", "--data-urlencode", "--json", "-F", "--form", "--form-string", "-T",
                                    "--upload-file", "-J", "-D", "--dump-header", "-c", "--cookie-jar"]
        for (index, word) in args.enumerated() {
            if writing.contains(word) || writing.contains(where: { word.hasPrefix($0 + "=") }) {
                // `-D -` and `-o -` only print.
                if ["-D", "--dump-header", "-o", "--output"].contains(word), index + 1 < args.count, args[index + 1] == "-" { continue }
                if ["-D", "--dump-header", "-o", "--output"].contains(word), index + 1 < args.count, args[index + 1] == "/dev/null" { continue }
                return .changes
            }
            if word == "-X" || word == "--request", index + 1 < args.count, !["GET", "HEAD"].contains(args[index + 1].uppercased()) {
                return .changes
            }
            // Combined short options such as `-sSLo` end with one that takes the file.
            if word.hasPrefix("-"), !word.hasPrefix("--"), word.count > 2, let last = word.last, "oOdFTD".contains(last) {
                if (last == "o" || last == "D"), index + 1 < args.count, args[index + 1] == "-" || args[index + 1] == "/dev/null" { continue }
                return .changes
            }
        }
        let url = args.first { $0.contains("://") } ?? args.last { !$0.hasPrefix("-") } ?? ""
        return .fetch(url)
    }

    private static func xargs(_ args: [String], simple: ShellCommand.Simple) -> Effect {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            if ["-n", "-I", "-P", "-L", "-s", "-E", "-d", "-J", "-R", "-S"].contains(args[index]) { index += 1 }
            index += 1
        }
        guard index < args.count else { return .inspect }
        var inner = simple
        inner.words = Array(args[index...])
        inner.piped = false
        let effect = classify(inner)
        // Its files come through the pipe, so what it reads is unknown: it counts as a search or a
        // command, not as reading a file.
        switch effect {
        case .read, .list: return .inspect
        default: return effect
        }
    }
}

/// Lines of a file a read covered: `L1–120`, `from L211` or the last 30 lines.
public struct LineRange: Hashable, Sendable {
    public var start: Int?
    public var end: Int?
    /// `tail -n 30`: the last lines, whose numbers aren't known.
    public var last: Int?

    public init(start: Int?, end: Int?) {
        self.start = start
        self.end = end
        last = nil
    }

    public init(last: Int) {
        self.last = last
    }

    /// `1,120p`, `40p` or `211,$p`.
    init?(sedScript script: String) {
        let pattern = #"^\s*(\d+)\s*(?:,\s*(\d+|\$))?\s*p\s*;?\s*$"#
        guard let match = script.range(of: pattern, options: .regularExpression) else { return nil }
        let text = String(script[match]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "p;"))
        let parts = body.split(separator: ",").map(String.init)
        guard let first = parts.first.flatMap({ ShellFacts.lineNumber($0) }) else { return nil }
        if parts.count < 2 { self.init(start: first, end: first) } else { self.init(start: first, end: parts[1] == "$" ? nil : ShellFacts.lineNumber(parts[1])) }
    }

    /// `NR>=10 && NR<=40`, `NR==7`, `NR>5`.
    init?(awkProgram program: String) {
        let compact = program.replacingOccurrences(of: " ", with: "")
        func number(after marker: String) -> Int? {
            guard let range = compact.range(of: marker) else { return nil }
            return ShellFacts.lineNumber(compact[range.upperBound...].prefix { $0.isASCII && $0.isNumber })
        }
        if let line = number(after: "NR==") {
            self.init(start: line, end: line)
        } else if let low = number(after: "NR>=") ?? number(after: "NR>").map({ $0 + 1 }) {
            self.init(start: low, end: number(after: "NR<=") ?? number(after: "NR<").map { $0 - 1 })
        } else if let high = number(after: "NR<=") ?? number(after: "NR<").map({ $0 - 1 }) {
            self.init(start: 1, end: high)
        } else {
            return nil
        }
    }

    public var label: String {
        if let last { return last == 1 ? "last line" : "last \(last) lines" }
        switch (start, end) {
        case let (start?, end?) where start == end: return "L\(start)"
        case let (start?, end?): return "L\(start)–\(end)"
        case let (start?, nil): return "from L\(start)"
        case let (nil, end?): return "L1–\(end)"
        case (nil, nil): return ""
        }
    }

    /// Ranges merged where they overlap or touch, numbered ones first, in order.
    public static func merged(_ ranges: [LineRange]) -> [LineRange] {
        var numbered = ranges.filter { $0.last == nil && ($0.start != nil || $0.end != nil) }
            .map { (start: $0.start ?? 1, end: $0.end ?? Int.max) }
            .sorted { $0.start < $1.start }
        var result: [LineRange] = []
        var current = numbered.isEmpty ? nil : numbered.removeFirst()
        for next in numbered {
            guard let open = current else { break }
            if next.start <= (open.end == Int.max ? Int.max : open.end + 1) {
                current = (open.start, max(open.end, next.end))
            } else {
                result.append(LineRange(start: open.start, end: open.end == Int.max ? nil : open.end))
                current = next
            }
        }
        if let open = current { result.append(LineRange(start: open.start, end: open.end == Int.max ? nil : open.end)) }
        let tails = Set(ranges.compactMap(\.last)).sorted().map { LineRange(last: $0) }
        return result + tails
    }
}
