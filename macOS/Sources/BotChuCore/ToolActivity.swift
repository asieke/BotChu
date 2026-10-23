import Foundation

/// What a tool call is for, as the chat groups it. Reading, listing, searching, fetching and other
/// read-only commands are exploration, which folds into one group; everything else stands alone.
public enum ToolIntent: String, Sendable, Equatable, CaseIterable {
    case read, list, search, fetch, inspect
    /// A shell command that changes something, runs long, or isn't known to only read.
    case command
    /// Writes or edits files.
    case edit
    /// Hands work to another agent: Claude Code's Task, Antigravity's invoke_subagent, or
    /// `botchu-subagent`.
    case subagent
    /// Updates the agent's own plan or to-do list.
    case plan
    /// Asks the owner something, such as approving a plan.
    case question
    case other

    public var isExploration: Bool {
        switch self {
        case .read, .list, .search, .fetch, .inspect: true
        default: false
        }
    }

    /// What a running row says it is doing.
    public var doing: String {
        switch self {
        case .read: "Reading"
        case .list: "Listing"
        case .search: "Searching"
        case .fetch: "Fetching"
        case .inspect, .command: "Running"
        case .edit: "Editing"
        case .subagent: "Delegating"
        case .plan: "Planning"
        case .question: "Asking"
        case .other: "Using"
        }
    }
}

/// Lines an edit added and removed.
public struct DiffStats: Hashable, Sendable {
    public var added: Int
    public var removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    public var label: String {
        removed == 0 ? "+\(added)" : "+\(added) −\(removed)"
    }
}

/// A command's output as a card shows it: its first line and how many more there are.
public struct OutputPreview: Hashable, Sendable {
    public var firstLine: String
    public var moreLines: Int
    public var isEmpty: Bool { firstLine.isEmpty && moreLines == 0 }
}

/// A sub-agent started by the CLI itself, which BotChu has no thread for.
public struct NativeSubagent: Hashable, Sendable {
    /// The kind of agent (`Explore`, `general-purpose`), when the CLI names it.
    public var kind: String
    public var task: String
}

/// One tool call, described for people: its file names, folders, line ranges and patterns rather
/// than raw JSON, and whether it only reads. Built from a saved `ChatMessage` of any of the five
/// CLIs; calls saved before `toolArguments` existed are described from their one-line input.
public struct ToolActivity: Equatable, Sendable {
    public var intent: ToolIntent
    /// Ran through a shell tool, so its row shows the command line.
    public var isShell = false
    /// The row's main text: a file name, a command's program and options, a pattern.
    public var title: String
    /// Beside it, quieter: the folder, the command's arguments.
    public var subtitle = ""
    /// At the row's end: a line range, `no matches`, `+12 −3`.
    public var detail: String?
    /// Files read, with the lines read.
    public var reads: [ShellFacts.Read] = []
    /// Folders listed.
    public var lists: [String] = []
    /// Folders searched (one entry per search; empty when the search names none).
    public var searches: [ShellFacts.Search] = []
    public var fetches = 0
    /// Other read-only commands it ran.
    public var inspections = 0
    /// Files written or edited.
    public var edits: [String] = []
    /// How an edit card names what it did: `Edited`, `Wrote`, `Created`, `Deleted`.
    public var verb: String?
    public var diff: DiffStats?
    /// The whole command line, for shell calls.
    public var command: String?
    public var exitCode: Int?
    /// Why it failed, short and the same for the same kind of failure (`not found`).
    public var failure: String?
    /// A search that ran and found nothing; not a failure.
    public var noMatches = false
    public var output: OutputPreview?
    public var delegation: DelegationCall?
    /// The run ids a `botchu-subagent` call printed.
    public var runIDs: [UUID] = []
    public var nativeSubagent: NativeSubagent?

    public init(intent: ToolIntent, title: String) {
        self.intent = intent
        self.title = title
    }

    /// Every file it touched: read, listed, searched, edited.
    public var paths: [String] {
        reads.map(\.path) + lists + searches.flatMap(\.paths) + edits
    }

    // MARK: Describing

    public static func describe(_ message: ChatMessage, root: String? = nil) -> ToolActivity {
        let name = message.toolName ?? "Tool"
        let key = toolKey(name)
        let input = message.toolInput ?? ""
        let output = message.toolOutput ?? ""
        let args = ToolArguments.parse(message.toolArguments)
            ?? (input.hasPrefix("{") ? ToolArguments.parse(input) : nil) ?? [:]
        var activity: ToolActivity
        if shellTools.contains(key) {
            let line = string(args, ["command", "CommandLine", "cmd", "commandLine", "script"]) ?? input
            let directory = string(args, ["Cwd", "cwd", "workdir", "directory", "working_directory"])
            activity = shell(line, directory: directory, root: root)
        } else if readTools.contains(key) {
            activity = readTool(args, input: input, root: root)
        } else if listTools.contains(key) {
            let path = string(args, ["path", "DirectoryPath", "directory", "dir", "relative_workspace_path", "Path", "AbsolutePath"]) ?? pathLike(input) ?? "."
            activity = ToolActivity(intent: .list, title: display(folder: path, root: root))
            activity.lists = [path]
        } else if searchTools.contains(key) {
            activity = searchTool(args, input: input, key: key, root: root)
        } else if fetchTools.contains(key) {
            activity = fetchTool(args, input: input, key: key)
        } else if editTools.contains(key) {
            activity = editTool(args, input: input, key: key, root: root)
        } else if subagentTools.contains(key) {
            let kind = string(args, ["subagent_type", "TypeName", "type", "agent", "agent_type"]) ?? ""
            let task = string(args, ["description", "Role", "task", "title", "name"])
                ?? string(args, ["prompt", "Prompt", "message"]).map(firstLine) ?? firstLine(input)
            activity = ToolActivity(intent: .subagent, title: task.isEmpty ? "Sub-agent" : task)
            activity.subtitle = kind
            activity.nativeSubagent = NativeSubagent(kind: kind, task: task)
        } else if planTools.contains(key) {
            activity = planTool(args, input: input)
        } else if questionTools.contains(key) {
            let question = string(args, ["question", "Question", "prompt", "message"])
                ?? ((args["questions"] as? [[String: Any]])?.first.flatMap { $0["question"] as? String })
            activity = ToolActivity(intent: .question, title: question.map(firstLine) ?? (key == "exitplanmode" ? "Plan ready for approval" : "Asked a question"))
        } else if isReadingService(key) {
            activity = ToolActivity(intent: .fetch, title: serviceName(name))
            activity.subtitle = firstLine(input)
            activity.fetches = 1
        } else {
            activity = ToolActivity(intent: .other, title: serviceName(name))
            activity.subtitle = firstLine(input)
        }
        activity.finish(with: message, output: output)
        return activity
    }

    /// The facts that need the call's result: exit code, failure, output preview.
    private mutating func finish(with message: ChatMessage, output: String) {
        exitCode = message.toolExitCode ?? (isShell ? Self.exitCode(in: output) : nil)
        if delegation != nil { runIDs = DelegationCall.runIDs(in: output) }
        if isShell, exitCode == nil, message.toolState == .done { exitCode = 0 }
        // Exploration rows don't show output, so only cards that do look through it.
        if !intent.isExploration, isShell || intent == .other || intent == .subagent, !output.isEmpty {
            self.output = Self.preview(output)
        }
        guard message.toolState == .failed else {
            if intent == .search, message.toolState == .done, Self.isEmptyResult(Self.strippingHeaders(output)) {
                noMatches = true
                detail = detail.map { "no matches · " + $0 } ?? "no matches"
            }
            return
        }
        // grep and rg exit 1 when nothing matched: a search that found nothing, not a failure.
        if intent == .search, exitCode == 1 || exitCode == nil, Self.isEmptyResult(Self.strippingHeaders(output)) {
            noMatches = true
            detail = "no matches"
            return
        }
        failure = Self.failureReason(output: output, exitCode: exitCode)
    }

    // MARK: Shell

    static func shell(_ line: String, directory: String?, root: String?) -> ToolActivity {
        var command = ShellCommand(unwrapped(line))
        if let directory {
            command.commands = command.commands.map { simple in
                var simple = simple
                simple.directory = ShellPaths.join(directory, simple.directory ?? ".")
                return simple
            }
        }
        let facts = ShellFacts(command)
        let first = facts.meaningful.first
        var activity = ToolActivity(intent: .command, title: first.map { ShellFacts.head(of: $0) } ?? firstLine(line))
        activity.isShell = true
        activity.command = line
        if let first {
            activity.subtitle = ShellFacts.arguments(of: first).map { humanize(word: $0, directory: first.directory, root: root) }
                .joined(separator: " ")
        }
        if let delegation = facts.delegation {
            activity.intent = .subagent
            activity.delegation = delegation
            return activity
        }
        guard facts.readOnly else { return activity }
        activity.reads = facts.reads
        activity.lists = facts.lists
        activity.searches = facts.searches
        activity.fetches = facts.fetches.count
        activity.inspections = facts.inspections.count
        // The row is named for what the first command does.
        switch first.map(ShellFacts.classify) {
        case .read?: activity.intent = facts.reads.isEmpty ? .inspect : .read
        case .list?: activity.intent = .list
        case .search?: activity.intent = .search
        case .fetch?: activity.intent = .fetch
        default: activity.intent = .inspect
        }
        var details: [String] = []
        if facts.reads.count == 1, let range = facts.reads[0].range { details.append(range.label) }
        if facts.meaningful.count > 1 { details.append("+\(facts.meaningful.count - 1) more") }
        activity.detail = details.isEmpty ? nil : details.joined(separator: " · ")
        return activity
    }

    /// `/bin/zsh -lc '…'` and a command line that is one quoted word, as some CLIs save them.
    static func unwrapped(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c ", "sh -c ", "bash -c ", "zsh -c "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.count >= 2, let first = text.first, first == text.last, first == "'" || first == "\"" {
            let inner = String(text.dropFirst().dropLast())
            // Only when the quotes wrap the whole line, not two quoted words.
            if !inner.contains(first) { return inner }
        } else if let first = text.first, first == "\"", !text.dropFirst().contains("\"") {
            // An opening quote whose closing one was lost.
            return String(text.dropFirst())
        }
        return text
    }

    // MARK: Other tools

    private static func readTool(_ args: [String: Any], input: String, root: String?) -> ToolActivity {
        let path = string(args, ["file_path", "path", "Path", "AbsolutePath", "TargetFile", "file", "filename", "notebook_path",
                                 "FilePath", "absolute_path", "filePath"]) ?? pathLike(input) ?? input
        var range: LineRange?
        let start = int(args, ["StartLine", "start_line", "startLine"])
        let end = int(args, ["EndLine", "end_line", "endLine"])
        if start != nil || end != nil {
            range = LineRange(start: max(1, start ?? 1), end: end)
        } else if let offset = int(args, ["offset", "Offset"]) {
            let first = max(1, offset)
            range = int(args, ["limit", "Limit"]).map { LineRange(start: first, end: first + max(1, $0) - 1) } ?? LineRange(start: first, end: nil)
        } else if let limit = int(args, ["limit", "Limit"]) {
            range = LineRange(start: 1, end: limit)
        } else if let view = args["view_range"] as? [Any], view.count == 2, let first = number(view[0]) {
            let last = number(view[1])
            range = LineRange(start: first, end: last.flatMap { $0 < 0 ? nil : $0 })
        }
        var activity = ToolActivity(intent: .read, title: fileName(path))
        activity.subtitle = display(folder: parent(path), root: root)
        activity.reads = [ShellFacts.Read(path: path, range: range)]
        activity.detail = range?.label
        return activity
    }

    private static func searchTool(_ args: [String: Any], input: String, key: String, root: String?) -> ToolActivity {
        let pattern = string(args, ["pattern", "Query", "query", "regex", "SearchPattern", "search", "Pattern", "name", "glob_pattern"]) ?? firstLine(input)
        let path = string(args, ["path", "SearchPath", "SearchDirectory", "directory", "dir", "DirectoryPath", "Path", "target_directory"])
        let glob = string(args, ["glob", "include", "Includes", "FilePattern", "type"])
        var activity = ToolActivity(intent: .search, title: key == "toolsearch" ? "tools: \(pattern)" : quoted(pattern))
        var place: [String] = []
        if let path { place.append("in " + display(folder: path, root: root)) }
        if let glob { place.append(glob) }
        activity.subtitle = place.joined(separator: " · ")
        activity.searches = [ShellFacts.Search(pattern: pattern, paths: path.map { [$0] } ?? [])]
        return activity
    }

    private static func fetchTool(_ args: [String: Any], input: String, key: String) -> ToolActivity {
        if let url = string(args, ["url", "Url", "URL", "uri"]) ?? (input.contains("://") ? firstLine(input) : nil) {
            var activity = ToolActivity(intent: .fetch, title: shortURL(url))
            activity.subtitle = string(args, ["prompt", "Prompt"]).map(firstLine) ?? ""
            activity.fetches = 1
            return activity
        }
        let query = string(args, ["query", "Query", "q", "search_term"]) ?? firstLine(input)
        var activity = ToolActivity(intent: .fetch, title: quoted(query))
        activity.subtitle = "web search"
        activity.fetches = 1
        return activity
    }

    private static func editTool(_ args: [String: Any], input: String, key: String, root: String?) -> ToolActivity {
        var paths: [String] = []
        var verb = key.contains("write") || key.contains("create") ? "Wrote" : "Edited"
        if let path = string(args, ["file_path", "path", "Path", "TargetFile", "notebook_path", "AbsolutePath", "filename", "FilePath", "filePath"]) {
            paths = [path]
        } else if key == "edit files" || key == "apply_patch" || key == "patch" {
            // Codex's file changes, one `kind path` a line.
            for line in input.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, ["add", "update", "delete", "edit", "create", "remove", "move"].contains(parts[0]) {
                    paths.append(parts[1])
                    if parts[0] == "add" || parts[0] == "create" { verb = "Created" } else if parts[0] == "delete" || parts[0] == "remove" { verb = paths.count == 1 ? "Deleted" : verb }
                } else if !line.isEmpty, !line.contains(" ") {
                    paths.append(String(line))
                }
            }
        } else if let path = pathLike(input) {
            paths = [path]
        }
        var activity = ToolActivity(intent: .edit, title: paths.count == 1 ? fileName(paths[0]) : paths.isEmpty ? serviceName(key) : "\(paths.count) files")
        activity.subtitle = paths.count == 1 ? display(folder: parent(paths[0]), root: root) : paths.prefix(4).map(fileName).joined(separator: ", ")
        activity.edits = paths
        activity.diff = ToolArguments.diff(in: args)
        activity.detail = activity.diff?.label
        activity.verb = verb
        return activity
    }

    private static func planTool(_ args: [String: Any], input: String) -> ToolActivity {
        let items = (args["todos"] as? [[String: Any]]) ?? (args["plan"] as? [[String: Any]]) ?? (args["steps"] as? [[String: Any]]) ?? []
        var activity = ToolActivity(intent: .plan, title: "Updated the plan")
        if !items.isEmpty {
            let done = items.filter { ($0["status"] as? String) == "completed" }.count
            let current = items.first { ($0["status"] as? String) == "in_progress" }
            activity.detail = "\(done)/\(items.count) done"
            activity.subtitle = (current?["activeForm"] as? String) ?? (current?["content"] as? String) ?? (current?["step"] as? String) ?? ""
        } else {
            activity.subtitle = firstLine(input)
        }
        return activity
    }

    // MARK: Results

    /// `Exit code 2` (Claude Code), `Command exited with code 0.` (Antigravity), `exit status 1`.
    static func exitCode(in output: String) -> Int? {
        let head = output.prefix(200)
        for pattern in [#"^Exit code (\d+)"#, #"^Command exited with code (\d+)"#, #"^Command failed with exit code (\d+)"#] {
            if let range = head.range(of: pattern, options: .regularExpression) {
                return Int(head[range].split(separator: " ").last?.trimmingCharacters(in: .punctuationCharacters) ?? "")
            }
        }
        let tail = output.suffix(200)
        if let range = tail.range(of: #"(exit(ed)? (with )?(code|status)|exit code:?) \d+"#, options: [.regularExpression, .caseInsensitive]) {
            return Int(tail[range].split(separator: " ").last ?? "")
        }
        return nil
    }

    /// The output without the lines a CLI adds about the exit status.
    static func strippingHeaders(_ output: String) -> Substring {
        var text = output[...]
        for pattern in [#"^Exit code \d+\n?"#, #"^Command exited with code \d+\.?\n?"#, #"^Command failed with exit code \d+\.?\n?"#, #"^\s*Output:\n"#] {
            if let range = text.range(of: pattern, options: .regularExpression) { text = text[range.upperBound...] }
        }
        return text
    }

    static func isEmptyResult(_ output: Substring) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || ["No matches found", "No files found", "No output from the command.", "(Bash completed with no output)",
                                   "(no output)", "Found 0 files", "No matches found."].contains(trimmed)
    }

    static func isEmptyResult(_ output: String) -> Bool { isEmptyResult(output[...]) }

    /// The first line of a command's output, and how many follow.
    static func preview(_ output: String) -> OutputPreview? {
        let body = strippingHeaders(output)
        if isEmptyResult(body) { return nil }
        // Counting lines walks the bytes once; outputs of a megabyte stay fast.
        var lines = 0
        var first: Substring?
        var lineStart = body.startIndex
        var index = body.startIndex
        let utf8 = body.utf8
        var byte = utf8.startIndex
        while byte != utf8.endIndex {
            if utf8[byte] == UInt8(ascii: "\n") {
                index = byte
                let line = body[lineStart..<index]
                if first == nil, !line.trimmingCharacters(in: .whitespaces).isEmpty { first = line } else if first != nil { lines += 1 }
                lineStart = body.index(after: index)
            }
            byte = utf8.index(after: byte)
        }
        let last = body[lineStart...]
        if !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if first == nil { first = last } else { lines += 1 }
        }
        guard let first else { return nil }
        // Trailing blank lines aren't more output.
        var trailing = 0
        var cursor = body.endIndex
        while cursor > body.startIndex {
            let before = body.index(before: cursor)
            if body[before] == "\n" { trailing += 1; cursor = before } else if body[before] == " " || body[before] == "\t" || body[before] == "\r" { cursor = before } else { break }
        }
        return OutputPreview(firstLine: String(first.prefix(300)).trimmingCharacters(in: .whitespaces),
                             moreLines: max(0, lines - max(0, trailing - 1)))
    }

    /// Why a call failed, worded so that the same problem reads the same for every file.
    public static func failureReason(output: String, exitCode: Int? = nil) -> String {
        let text = output.lowercased()
        let checks: [(String, [String])] = [
            ("not found", ["does not exist", "no such file", "not found", "enoent", "cannot find", "couldn't find", "could not find", "doesn't exist", "file not exist"]),
            ("permission denied", ["permission denied", "eacces", "operation not permitted", "not permitted"]),
            ("is a folder", ["is a directory", "eisdir"]),
            ("too large", ["too large", "exceeds maximum", "exceeds the maximum", "file content (", "too big"]),
            ("timed out", ["timed out", "timeout"]),
            ("blocked", ["sandbox", "blocked", "denied by"]),
            ("interrupted", ["interrupted", "cancelled", "canceled"]),
        ]
        for (reason, needles) in checks where needles.contains(where: text.contains) { return reason }
        if let exitCode, exitCode != 0 { return "exit \(exitCode)" }
        let line = firstLine(String(strippingHeaders(output)))
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(/|~/)[^\s'":,]+(:\d+)*"#, with: "…", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.lowercased().hasPrefix("antigravity reported") { return "failed" }
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    // MARK: Names

    static let shellTools: Set<String> = ["bash", "shell", "run_command", "run_shell_command", "exec_command", "command", "terminal",
                                          "local_shell", "execute_command", "run_terminal_cmd", "shell_command", "run_in_terminal", "exec"]
    static let readTools: Set<String> = ["read", "read_file", "view_file", "view", "view_file_outline", "view_code_item", "notebookread",
                                         "read_many_files", "readfile", "open_file", "cat", "get_file_contents", "read_text_file"]
    static let listTools: Set<String> = ["ls", "list_dir", "list_directory", "listdir", "list_files", "list", "list_allowed_directories", "directory_tree"]
    static let searchTools: Set<String> = ["grep", "glob", "grep_search", "find_by_name", "find", "find_files", "file_search", "search_files",
                                           "codebase_search", "search", "ripgrep", "toolsearch", "semantic_search", "search_code"]
    static let fetchTools: Set<String> = ["webfetch", "websearch", "web search", "web_search", "search_web", "read_url_content", "fetch",
                                          "fetch_url", "web_fetch", "browse", "google_search", "google_web_search", "url_fetch", "read_url"]
    static let editTools: Set<String> = ["edit", "write", "multiedit", "notebookedit", "edit_file", "write_file", "replace_file_content",
                                         "multi_replace_file_content", "write_to_file", "create_file", "apply_patch", "edit files",
                                         "str_replace_editor", "str_replace_based_edit_tool", "patch", "insert", "create", "delete_file",
                                         "replace", "move_file"]
    static let subagentTools: Set<String> = ["task", "agent", "invoke_subagent", "spawn_agent", "delegate", "dispatch_agent", "subagent"]
    static let planTools: Set<String> = ["todowrite", "todoread", "update_plan", "plan", "write_todos", "todo"]
    static let questionTools: Set<String> = ["askuserquestion", "exitplanmode", "request_user_input", "ask_user", "ask_followup_question",
                                             "ask_question", "request_approval"]

    static func toolKey(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasPrefix("mcp__") { return lower.components(separatedBy: "__").last ?? lower }
        return lower
    }

    /// An MCP tool that reads by its name: `github.search_issues`, `mcp__linear__get_issue`.
    static func isReadingService(_ key: String) -> Bool {
        let tool = key.split(separator: ".").last.map(String.init) ?? key
        return ["get_", "list_", "search_", "read_", "fetch_", "view_", "find_", "query_", "describe_", "lookup_", "show_"].contains { tool.hasPrefix($0) }
    }

    /// `mcp__linear__get_issue` → `linear: get_issue`.
    static func serviceName(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.components(separatedBy: "__").dropFirst()
            return parts.count >= 2 ? "\(parts.dropLast().joined(separator: " ")): \(parts.last!)" : name
        }
        if name.contains("."), !name.contains(" ") {
            let parts = name.split(separator: ".")
            return "\(parts.dropLast().joined(separator: ".")): \(parts.last!)"
        }
        return name
    }

    // MARK: Helpers

    static func string(_ args: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = args[key] as? String, !value.isEmpty { return value }
            if let value = args[key] as? [String], !value.isEmpty { return value.joined(separator: " ") }
        }
        return nil
    }

    static func int(_ args: [String: Any], _ keys: [String]) -> Int? {
        for key in keys { if let value = args[key].flatMap(number) { return value } }
        return nil
    }

    static func number(_ value: Any) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    static func quoted(_ text: String) -> String {
        let line = firstLine(text)
        return line.isEmpty ? "" : "“\(line)”"
    }

    /// A one-line input that looks like a path.
    static func pathLike(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), !text.hasPrefix("{"), text.contains("/") || text.contains(".") else { return nil }
        return text
    }

    public static func fileName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent
    }

    /// A folder as the chat shows it: relative to the conversation's folder when inside it, else
    /// from `~`.
    public static func display(folder: String, root: String?) -> String {
        if folder.isEmpty || folder == "." { return "" }
        if let root, !root.isEmpty {
            let base = root.hasSuffix("/") ? String(root.dropLast()) : root
            if folder == base { return "" }
            if folder.hasPrefix(base + "/") { return String(folder.dropFirst(base.count + 1)) }
        }
        let home = NSHomeDirectory()
        if folder.hasPrefix(home + "/") { return "~/" + folder.dropFirst(home.count + 1) }
        if folder == home { return "~" }
        return folder.hasPrefix("./") ? String(folder.dropFirst(2)) : folder
    }

    /// A shell word as a row shows it: paths relative to the conversation's folder.
    static func humanize(word: String, directory: String?, root: String?) -> String {
        guard word.contains("/"), !word.contains("://"), !word.contains(" ") else { return word }
        let full = ShellPaths.join(directory, word)
        let shown = display(folder: full, root: root)
        return shown.isEmpty ? "." : shown
    }

    static func shortURL(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return firstLine(url) }
        let path = components.path == "/" ? "" : components.path
        let text = host.replacingOccurrences(of: "www.", with: "") + path
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }
}

/// A tool call's structured arguments as BotChu keeps them (`ChatMessage.toolArguments`): compact
/// JSON, with long strings shortened, and an edit's old and new text replaced by what the chat
/// needs from them, the lines added and removed (`_diff`).
public enum ToolArguments {
    static let longest = 400

    public static func digest(_ value: Any?, dropping: Set<String> = []) -> String? {
        guard let dictionary = value as? [String: Any], !dictionary.isEmpty else { return nil }
        let diff = diffStats(dictionary)
        for limit in [longest, 120] {
            var out: [String: Any] = [:]
            for (key, value) in dictionary where !dropping.contains(key) { out[key] = shorten(value, limit: limit, depth: 0) }
            if let diff { out["_diff"] = [diff.added, diff.removed] }
            guard JSONSerialization.isValidJSONObject(out),
                  let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            if data.count <= 6_000 || limit == 120 { return String(decoding: data, as: UTF8.self) }
        }
        return nil
    }

    public static func parse(_ text: String?) -> [String: Any]? {
        guard let text, text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The digest's `_diff`, else lines counted from edit text still in the arguments.
    public static func diff(in args: [String: Any]) -> DiffStats? {
        if let pair = args["_diff"] as? [Any], pair.count == 2, let added = ToolActivity.number(pair[0]), let removed = ToolActivity.number(pair[1]) {
            return DiffStats(added: added, removed: removed)
        }
        return nil
    }

    private static func shorten(_ value: Any, limit: Int, depth: Int) -> Any {
        switch value {
        case let text as String:
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        case let list as [Any]:
            guard depth < 3 else { return "…" }
            return list.prefix(20).map { shorten($0, limit: limit, depth: depth + 1) }
        case let dictionary as [String: Any]:
            guard depth < 3 else { return "…" }
            return dictionary.mapValues { shorten($0, limit: limit, depth: depth + 1) }
        case is NSNumber, is NSNull:
            return value
        default:
            return "\(value)"
        }
    }

    static let editPairs: [(String, String)] = [("old_string", "new_string"), ("oldText", "newText"), ("old_str", "new_str"),
                                                ("oldString", "newString"), ("TargetContent", "ReplacementContent")]
    static let wholeFile = ["content", "contents", "file_text", "CodeContent", "new_source"]

    /// Lines an edit's arguments add and remove: old and new text (also in a list of edits), a whole
    /// file's content, or a patch.
    static func diffStats(_ args: [String: Any]) -> DiffStats? {
        func pairStats(_ dictionary: [String: Any]) -> DiffStats? {
            for (old, new) in editPairs {
                if let before = dictionary[old] as? String, let after = dictionary[new] as? String {
                    return lineDiff(before, after)
                }
            }
            return nil
        }
        if let stats = pairStats(args) { return stats }
        for key in ["edits", "ReplacementChunks", "changes"] {
            if let edits = args[key] as? [[String: Any]] {
                let all = edits.compactMap(pairStats)
                if !all.isEmpty { return DiffStats(added: all.map(\.added).reduce(0, +), removed: all.map(\.removed).reduce(0, +)) }
            }
        }
        for key in wholeFile {
            if let content = args[key] as? String { return DiffStats(added: lines(content).count, removed: 0) }
        }
        for key in ["patch", "input", "diff"] {
            if let patch = args[key] as? String, patch.contains("*** Begin Patch") || patch.hasPrefix("---") || patch.contains("\n@@") {
                var added = 0, removed = 0
                for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 } else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
                }
                return DiffStats(added: added, removed: removed)
            }
        }
        return nil
    }

    static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// Lines added and removed between two texts: the common start and end don't count, and what
    /// is left is compared line by line when it's small enough.
    public static func lineDiff(_ old: String, _ new: String) -> DiffStats {
        var a = lines(old)[...], b = lines(new)[...]
        while let x = a.first, let y = b.first, x == y { a = a.dropFirst(); b = b.dropFirst() }
        while let x = a.last, let y = b.last, x == y { a = a.dropLast(); b = b.dropLast() }
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 40_000 else { return DiffStats(added: b.count, removed: a.count) }
        // Longest common subsequence, one row at a time.
        let left = Array(a), right = Array(b)
        var previous = [Int](repeating: 0, count: right.count + 1)
        var current = previous
        for i in 1...left.count {
            for j in 1...right.count {
                current[j] = left[i - 1] == right[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        let common = previous[right.count]
        return DiffStats(added: right.count - common, removed: left.count - common)
    }
}

/// `botchu-subagent` in a command line: the agents it calls or spawns, and how many runs it waits for.
public struct DelegationCall: Hashable, Sendable {
    public struct Launch: Hashable, Sendable {
        public var agent: String
        public var title: String?
        /// `call` waits for the run to finish; `spawn` returns its id at once.
        public var waits: Bool
    }

    public var launches: [Launch] = []
    /// Ids or variables given to `wait`.
    public var waitsFor = 0

    public init() {}

    public var isLaunch: Bool { !launches.isEmpty }

    static func parse(_ words: [String]) -> DelegationCall? {
        guard words.count >= 2 else { return nil }
        var call = DelegationCall()
        switch words[1] {
        case "call", "spawn":
            func value(_ flag: String) -> String? {
                for (index, word) in words.enumerated() {
                    if word == flag, index + 1 < words.count { return words[index + 1] }
                    if word.hasPrefix(flag + "=") { return String(word.dropFirst(flag.count + 1)) }
                }
                return nil
            }
            call.launches = [Launch(agent: value("--agent") ?? "", title: value("--title"), waits: words[1] == "call")]
        case "wait":
            call.waitsFor = words.dropFirst(2).filter { !$0.hasPrefix("-") }.count
        default:
            return nil
        }
        return call
    }

    func merged(with other: DelegationCall) -> DelegationCall {
        var merged = self
        merged.launches += other.launches
        merged.waitsFor += other.waitsFor
        return merged
    }

    /// Run ids in a call's output: `spawn` prints one a line, `call` and `wait` one in each
    /// `=== Sub-agent: Name (id) ===` heading.
    public static func runIDs(in output: String) -> [UUID] {
        var ids: [UUID] = []
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        var search = output.startIndex..<output.endIndex
        while let range = output.range(of: pattern, options: .regularExpression, range: search) {
            if let id = UUID(uuidString: String(output[range])), !ids.contains(id) { ids.append(id) }
            search = range.upperBound..<output.endIndex
        }
        return ids
    }
}
