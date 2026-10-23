import Foundation
import Testing
@testable import BotChuCore

/// A tool call as a CLI's parser leaves it in the thread.
private func call(_ name: String, _ input: String = "", arguments: [String: Any]? = nil, output: String? = "ok",
                  state: ChatMessage.ToolState = .done, exitCode: Int? = nil, date: Date = Date()) -> ChatMessage {
    var message = ChatMessage(role: .tool, date: date, toolID: UUID().uuidString, toolName: name, toolInput: input,
                              toolOutput: output, toolState: state, toolArguments: arguments.flatMap { ToolArguments.digest($0) },
                              toolExitCode: exitCode)
    if state == .running { message.toolOutput = nil }
    return message
}

private func describe(_ message: ChatMessage, root: String? = "/work/BotChu") -> ToolActivity {
    ToolActivity.describe(message, root: root)
}

@Suite struct ShellReadingTests {
    /// Read-only commands as Codex, Claude Code, Antigravity and Pi ran them in real sessions.
    @Test(arguments: [
        "cat README.md",
        "tail -n 30 \"10x Bot/.botchu/thread.jsonl\"",
        "head -20 Sources/App.swift",
        "sed -n '1,120p' macOS/Sources/BotChu/Chat/ChatView.swift",
        "nl -ba macOS/Sources/BotChuCore/ProjectOverview.swift | sed -n '79,99p'",
        "rg -n 'BotChu|identity' /Users/me/.codex/memories/MEMORY.md",
        "rg --files macOS | rg 'NewTask|ProjectCells'",
        "ls -la",
        "find . -name '*.swift' -maxdepth 3",
        "find /Applications/Xcode.app -name '*.swiftinterface' -path '*DeviceActivity*'",
        "git status -sb",
        "git log -5 --format='%an <%ae>'",
        "git diff origin/main...HEAD -- macOS/Sources/BotChu/App/AppModel.swift",
        "git -C /tmp/repo log --oneline",
        "pwd; git rev-parse --show-toplevel; git status -sb; cat PROJECT.md README.md AGENTS.md",
        "cd macOS && grep -n \"func tab\" Sources/BotChu/App/*.swift | head -20",
        "wc -l a.swift b.swift",
        "gh pr view 45 --repo asieke/BotChu --json author,headRefOid",
        "gh api repos/asieke/GitChu/readme --jq .content | base64 -d",
        "curl -s https://example.com/docs",
        "tail -20 /tmp/qa45-check.log; ps -axo pid,etime,command | rg 'swift-test'",
        "for f in a.swift b.swift; do wc -l \"$f\"; done",
        "jq '.name' package.json",
        "echo 'x; rm -rf /'",
        "f=$(ls Sources | head -1); cat \"Sources/$f\"",
        "awk 'NR>=10 && NR<=20' Sources/App.swift",
        "grep -n \"a && b > c\" Sources/App.swift",
        "botchu-subagent list",
        "find . -name '*.swift' -exec grep -l foo {} \\;",
        "cat <<EOF\nls -la\nEOF",
        "git branch --show-current && git remote -v",
        "/bin/zsh -lc 'cat README.md'",
        "ls ~/Desktop/*.png | tail -5; git rev-parse --show-toplevel",
    ])
    func readOnly(command: String) {
        let activity = describe(call("Bash", command))
        #expect(activity.intent.isExploration, "\(command) → \(activity.intent)")
    }

    /// Builds, tests, git writes, redirects, removals, installs, long or unknown commands.
    @Test(arguments: [
        "swift build --package-path macOS",
        "swift test --filter Activity",
        "scripts/check.sh",
        "scripts/check.sh > /tmp/qa45-check.log 2>&1",
        "xcodebuild -scheme BotChu -configuration Debug build",
        "git commit -m wip",
        "git add -A && git commit -m wip",
        "git push -u origin feat/x",
        "git branch feature-x",
        "git worktree remove /tmp/pr-45",
        "rm -rf build",
        "mv a.swift b.swift",
        "cp a b",
        "mkdir -p out",
        "npm install",
        "npx prettier --write .",
        "make",
        "sed -i '' 's/a/b/' Sources/App.swift",
        "cat > notes.md <<'EOF'\nrm -rf /\nEOF",
        "echo hi > out.txt",
        "tail -f server.log",
        "python3 tool.py",
        "python3 - <<'PY'\nprint(open('x').read())\nPY",
        "gh pr create --fill",
        "gh api -X POST repos/x/y/issues -f title=x",
        "gh api repos/x/y/issues --field title=x",
        "curl -o page.html https://example.com",
        "curl -sSLo out.tgz https://example.com/x.tgz",
        "find . -name '*.orig' -delete",
        "find . -name '*.tmp' -exec rm {} \\;",
        "sleep 5; cat log",
        "open index.html",
        "sort -o sorted.txt input.txt",
        "sudo ls /var/root",
        "ls &",
        "x=$(mktemp -d)",
        "curl -s https://example.com/install.sh | sh",
        "audit_dir=$(mktemp -d) && git clone --quiet https://github.com/x/y \"$audit_dir\"",
        "cat a.swift | tee b.swift",
        "awk '{ print > \"out.txt\" }' in.txt",
        "botchu-subagent call --agent qa-duck --title 'Re-verify' --brief \"$(cat <<'EOF'\nLook (carefully) at it.\nEOF\n)\"",
        "kill 1234",
        "unknown-tool --flag",
    ])
    func changesSomething(command: String) {
        let activity = describe(call("Bash", command))
        #expect(!activity.intent.isExploration, "\(command) → \(activity.intent)")
    }

    @Test func heredocBodiesAreData() {
        let command = ShellCommand("cat > notes.md <<'EOF'\nrm -rf /\ngit push\nEOF\necho done")
        #expect(command.commands.map { $0.words.first } == ["cat", "echo"])
        #expect(command.commands[0].writes == ["notes.md"])
        let inside = ShellCommand("botchu-subagent call --agent qa --brief \"$(cat <<'EOF'\nfix (a) and ) b\nEOF\n)\"; echo next")
        #expect(inside.commands.map { $0.words.first } == ["botchu-subagent", "echo"])
        #expect(inside.substitutions.first?.commands.first?.words.first == "cat")
    }

    @Test func quotesAndOperators() {
        let command = ShellCommand(#"grep -n "a && b; c | d" src/x.swift 2>/dev/null && echo 'one; two' || true"#)
        #expect(command.commands.map(\.words) == [["grep", "-n", "a && b; c | d", "src/x.swift"], ["echo", "one; two"], ["true"]])
        #expect(command.commands[0].writes.isEmpty)
        #expect(ShellCommand("cd macOS && ls Sources").commands[1].directory == "macOS")
        #expect(ShellCommand("ls 2>&1 | head").commands.map { $0.piped } == [false, true])
    }

    @Test func readsAndRangesFromShell() {
        let tail = describe(call("Bash", "tail -n 30 \"/work/BotChu/.botchu/thread.jsonl\""))
        #expect(tail.intent == .read)
        #expect(tail.title == "tail -n 30")
        #expect(tail.subtitle == ".botchu/thread.jsonl")
        #expect(tail.detail == "last 30 lines")
        let sed = describe(call("Shell", "nl -ba macOS/Sources/BotChuCore/ProjectOverview.swift | sed -n '79,99p'"))
        #expect(sed.reads == [ShellFacts.Read(path: "macOS/Sources/BotChuCore/ProjectOverview.swift", range: LineRange(start: 79, end: 99))])
        #expect(sed.detail == "L79–99")
        let head = describe(call("run_command", "head -n 40 a.swift"))
        #expect(head.reads.first?.range == LineRange(start: 1, end: 40))
        let several = describe(call("Shell", "pwd; git status -sb; cat PROJECT.md README.md AGENTS.md; cat /Users/me/x.md"))
        #expect(several.reads.map(\.path) == ["PROJECT.md", "README.md", "AGENTS.md", "/Users/me/x.md"])
        #expect(several.inspections == 2)
        #expect(several.detail == "+3 more")
        let cd = describe(call("Bash", "cd /work/BotChu/macOS && cat Package.swift"))
        #expect(cd.reads.first?.path == "/work/BotChu/macOS/Package.swift")
        let search = describe(call("Bash", "rg -n 'func tab' macOS/Sources"))
        #expect(search.intent == .search)
        #expect(search.searches == [ShellFacts.Search(pattern: "func tab", paths: ["macOS/Sources"])])
        let list = describe(call("Bash", "ls -la macOS/Sources"))
        #expect(list.intent == .list && list.lists == ["macOS/Sources"])
        let awk = describe(call("Bash", "awk 'NR>=10 && NR<=20' a.swift"))
        #expect(awk.reads.first?.range == LineRange(start: 10, end: 20))
        // A command run in a folder Antigravity names (`Cwd`).
        let agy = describe(call("run_command", "cat README.md", arguments: ["CommandLine": "cat README.md", "Cwd": "/work/BotChu/docs"]))
        #expect(agy.reads.first?.path == "/work/BotChu/docs/README.md")
    }

    /// As Codex ran it in the smoke turn: files read in a loop are the loop's words.
    @Test func loopsReadTheirWords() {
        let loop = describe(call("Shell", #"for file in SOUL.md MEMORY.md INSTRUCTIONS.md ../MEMORY.md; do if [ -f "$file" ]; then echo "--- $file"; cat "$file"; fi; done"#))
        #expect(loop.intent == .inspect || loop.intent == .read)
        #expect(loop.intent.isExploration)
        #expect(loop.title == "for file in SOUL.md MEMORY.md INSTRUCTIONS.md ../MEMORY.md")
        #expect(loop.reads.map(\.path) == ["SOUL.md", "MEMORY.md", "INSTRUCTIONS.md", "../MEMORY.md"])
        let unknown = describe(call("Bash", #"f=$(ls | head -1); cat "$f""#))
        #expect(unknown.reads.isEmpty && unknown.intent.isExploration)
    }

    @Test func searchesThatFindNothingAreNotFailures() {
        let grep = describe(call("Bash", "rg -n nothing-here Sources", output: "Exit code 1\n", state: .failed))
        #expect(grep.failure == nil)
        #expect(grep.noMatches)
        #expect(grep.detail == "no matches")
        let missing = describe(call("Bash", "cat nope.swift", output: "Exit code 1\ncat: nope.swift: No such file or directory", state: .failed))
        #expect(missing.failure == "not found")
    }
}

@Suite struct ToolNamingTests {
    @Test func claudeCodeTools() {
        let read = describe(call("Read", "/work/BotChu/macOS/Sources/BotChu/App/AppModel.swift",
                                 arguments: ["file_path": "/work/BotChu/macOS/Sources/BotChu/App/AppModel.swift", "offset": 120, "limit": 60]))
        #expect(read.intent == .read)
        #expect(read.title == "AppModel.swift")
        #expect(read.subtitle == "macOS/Sources/BotChu/App")
        #expect(read.detail == "L120–179")
        // Saved before arguments were kept: the path alone.
        let old = describe(call("Read", "/work/BotChu/README.md"))
        #expect(old.title == "README.md" && old.detail == nil)
        let grep = describe(call("Grep", "func tab", arguments: ["pattern": "func tab", "path": "/work/BotChu/macOS", "glob": "*.swift"]))
        #expect(grep.intent == .search)
        #expect(grep.title == "“func tab”")
        #expect(grep.subtitle == "in macOS · *.swift")
        #expect(describe(call("Glob", "**/*.swift", arguments: ["pattern": "**/*.swift"])).intent == .search)
        #expect(describe(call("LS", "/work/BotChu/macOS")).intent == .list)
        #expect(describe(call("WebFetch", "https://example.com/a/b", arguments: ["url": "https://www.example.com/a/b", "prompt": "Summarize"])).title == "example.com/a/b")
        #expect(describe(call("WebSearch", "swift observation", arguments: ["query": "swift observation"])).intent == .fetch)
        let edit = describe(call("Edit", "/work/BotChu/a.swift", arguments: ["file_path": "/work/BotChu/a.swift",
                                                                             "old_string": "let a = 1\nlet b = 2\nlet c = 3",
                                                                             "new_string": "let a = 1\nlet b = 20\nlet c = 3\nlet d = 4"]))
        #expect(edit.intent == .edit)
        #expect(edit.diff == DiffStats(added: 2, removed: 1))
        #expect(edit.detail == "+2 −1")
        let write = describe(call("Write", "/work/BotChu/new.swift", arguments: ["file_path": "/work/BotChu/new.swift", "content": "a\nb\nc\n"]))
        #expect(write.diff == DiffStats(added: 3, removed: 0) && write.verb == "Wrote")
        let multi = describe(call("MultiEdit", "/work/BotChu/a.swift", arguments: ["file_path": "/work/BotChu/a.swift", "edits": [
            ["old_string": "a", "new_string": "b"], ["old_string": "c", "new_string": "d\ne"]]]))
        #expect(multi.diff == DiffStats(added: 3, removed: 2))
        let task = describe(call("Task", "Find the parser", arguments: ["description": "Find the parser", "prompt": "Look…", "subagent_type": "Explore"]))
        #expect(task.intent == .subagent && task.nativeSubagent == NativeSubagent(kind: "Explore", task: "Find the parser"))
        let todo = describe(call("TodoWrite", "", arguments: ["todos": [["content": "A", "status": "completed", "activeForm": "Doing A"],
                                                                         ["content": "B", "status": "in_progress", "activeForm": "Doing B"]]]))
        #expect(todo.intent == .plan && todo.detail == "1/2 done" && todo.subtitle == "Doing B")
        #expect(describe(call("ExitPlanMode", "")).intent == .question)
        #expect(describe(call("mcp__linear__get_issue", "ABC-1")).intent == .fetch)
        #expect(describe(call("mcp__linear__create_issue", "x")).intent == .other)
        #expect(describe(call("mcp__linear__create_issue", "x")).title == "linear: create_issue")
    }

    @Test func codexTools() {
        let edits = describe(call("Edit files", "update /work/BotChu/a.swift\nadd /work/BotChu/b.swift"))
        #expect(edits.intent == .edit && edits.edits.count == 2 && edits.title == "2 files")
        #expect(describe(call("Web search", "weather")).intent == .fetch)
        #expect(describe(call("github.search_issues", "{}")).intent == .fetch)
        let shell = describe(call("Shell", "swift test", output: "Building…\nTest run passed", exitCode: 0))
        #expect(shell.intent == .command && shell.exitCode == 0)
        #expect(shell.output == OutputPreview(firstLine: "Building…", moreLines: 1))
    }

    @Test func antigravityTools() {
        let read = describe(call("read_file", #"{"EndLine":250,"Path":"/work/BotChu/macOS/Sources/BotChu/Chat/ChatView.swift","StartLine":1}"#,
                                 output: "202 lines, 9203 bytes"))
        #expect(read.intent == .read && read.title == "ChatView.swift" && read.detail == "L1–250")
        let from = describe(call("read_file", #"{"Path":"/work/x/thread.jsonl","StartLine":160}"#))
        #expect(from.detail == "from L160")
        let failedRead = describe(call("read_file", #"{"Path":"/work/x/Pets.swift"}"#, output: "Antigravity reported ERROR.", state: .failed))
        #expect(failedRead.failure == "failed")
        #expect(describe(call("edit_file", #"{"Path":"/work/BotChu/a.swift"}"#)).intent == .edit)
        #expect(describe(call("write_file", #"{"Path":"/work/BotChu/a.json"}"#)).intent == .edit)
        let command = describe(call("run_command", "./scripts/check.sh", output: "Command exited with code 1.\nOutput:\nerror: x"))
        #expect(command.intent == .command && command.exitCode == 1 && command.output?.firstLine == "error: x")
        #expect(describe(call("search_web", "swift sprite sheet")).intent == .fetch)
        #expect(describe(call("invoke_subagent", "ScreenTime Researcher", arguments: ["Role": "ScreenTime Researcher", "TypeName": "research"])).intent == .subagent)
        #expect(describe(call("list_dir", #"{"DirectoryPath":"/work/BotChu/macOS"}"#)).intent == .list)
        #expect(describe(call("grep_search", #"{"Query":"func tab","SearchPath":"/work/BotChu"}"#)).intent == .search)
        #expect(describe(call("view_file", #"{"AbsolutePath":"/work/BotChu/a.swift"}"#)).intent == .read)
        #expect(describe(call("manage_task", #"{"Action":"kill","TaskId":"t-1"}"#)).intent == .other)
        let sandbox = describe(call("run_command", "cat .env", output: "Command failed to run: sandbox configuration error: readonly *.env*", state: .failed))
        #expect(sandbox.failure == "blocked")
    }

    @Test func museAndPiTools() {
        #expect(describe(call("bash", "ls", arguments: ["command": "ls", "exit_code": 0], exitCode: 0)).intent == .list)
        let read = describe(call("read", "/work/BotChu/MEMORY.md", arguments: ["path": "/work/BotChu/MEMORY.md", "offset": 10, "limit": 5]))
        #expect(read.intent == .read && read.detail == "L10–14")
        let edit = describe(call("edit", "/work/BotChu/MEMORY.md", arguments: ["path": "/work/BotChu/MEMORY.md", "oldText": "a", "newText": "a\nb"]))
        #expect(edit.diff == DiffStats(added: 1, removed: 0))
        #expect(describe(call("grep", "TODO", arguments: ["pattern": "TODO", "path": "src"])).intent == .search)
        #expect(describe(call("find", "*.md", arguments: ["pattern": "*.md"])).intent == .search)
        #expect(describe(call("ls", "src", arguments: ["path": "src"])).intent == .list)
        let timeout = describe(call("bash", "sleep 90", output: "Command timed out after 60 seconds", state: .failed))
        #expect(timeout.intent == .command && timeout.failure == "timed out")
    }

    @Test func exitCodesAndPreviews() {
        #expect(ToolActivity.exitCode(in: "Exit code 2\nerror: x") == 2)
        #expect(ToolActivity.exitCode(in: "Command exited with code 0.\n\nNo output from the command.") == 0)
        let build = "** BUILD SUCCEEDED **\n" + (1...212).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        #expect(ToolActivity.preview(build) == OutputPreview(firstLine: "** BUILD SUCCEEDED **", moreLines: 212))
        #expect(ToolActivity.preview("(Bash completed with no output)") == nil)
        let failed = describe(call("Bash", "swift build", output: "Exit code 1\nerror: no such module 'X'", state: .failed))
        #expect(failed.exitCode == 1 && failed.output?.firstLine == "error: no such module 'X'")
        #expect(failed.failure == "exit 1" || failed.failure == "not found")
    }

    @Test func failureReasonsMatchAcrossFiles() {
        #expect(ToolActivity.failureReason(output: "<tool_use_error>File does not exist.</tool_use_error>") == "not found")
        #expect(ToolActivity.failureReason(output: "cat: /a/b.swift: No such file or directory") == "not found")
        #expect(ToolActivity.failureReason(output: "EACCES: permission denied, open '/x'") == "permission denied")
        #expect(ToolActivity.failureReason(output: "EISDIR: illegal operation on a directory") == "is a folder")
        #expect(ToolActivity.failureReason(output: "File content (40000 tokens) exceeds maximum allowed tokens") == "too large")
        #expect(ToolActivity.failureReason(output: "Antigravity reported ERROR.") == "failed")
        #expect(ToolActivity.failureReason(output: "boom at /work/a.swift:12") == ToolActivity.failureReason(output: "boom at /work/b.swift:40"))
    }
}

@Suite struct ArgumentDigestTests {
    @Test func longTextIsShortenedAndEditsBecomeLineCounts() throws {
        let content = String(repeating: "line\n", count: 2_000)
        let digest = try #require(ToolArguments.digest(["file_path": "/a.swift", "content": content]))
        #expect(digest.utf8.count < 1_000)
        let args = try #require(ToolArguments.parse(digest))
        #expect(ToolArguments.diff(in: args) == DiffStats(added: 2_000, removed: 0))
        #expect(args["file_path"] as? String == "/a.swift")
        #expect(ToolArguments.digest(["command": "ls", "description": "List files"]) == #"{"command":"ls","description":"List files"}"#)
        #expect(ToolArguments.digest("ls") == nil)
    }

    @Test func lineDiffCountsOnlyChangedLines() {
        #expect(ToolArguments.lineDiff("a\nb\nc\nd\ne", "a\nb\nX\nd\ne") == DiffStats(added: 1, removed: 1))
        #expect(ToolArguments.lineDiff("a\nb", "a\nb\nc\nd") == DiffStats(added: 2, removed: 0))
        #expect(ToolArguments.lineDiff("x\ny\nz", "") == DiffStats(added: 0, removed: 3))
        #expect(ToolArguments.lineDiff("a\nb\nc", "c\nb\na") == DiffStats(added: 2, removed: 2))
        let patch = ["patch": "*** Begin Patch\n*** Update File: a.swift\n@@\n-old\n+new\n+more\n*** End Patch"]
        #expect(ToolArguments.diffStats(patch) == DiffStats(added: 2, removed: 1))
    }
}

@Suite struct ExplorationGroupTests {
    let root = "/work/BotChu"

    private func read(_ path: String, offset: Int? = nil, limit: Int? = nil, state: ChatMessage.ToolState = .done,
                      output: String = "ok", date: Date = Date()) -> ChatMessage {
        var args: [String: Any] = ["file_path": path]
        if let offset { args["offset"] = offset }
        if let limit { args["limit"] = limit }
        return call("Read", path, arguments: args, output: output, state: state, date: date)
    }

    private func items(_ messages: [ChatMessage]) -> [ActivityItem] {
        var transcript = ActivityTranscript(root: root)
        transcript.update(messages)
        return transcript.items
    }

    @Test func consecutiveReadsFoldUntilTextACommandOrAnEdit() {
        let user = ChatMessage(role: .user, text: "Trace it")
        let text = ChatMessage(role: .assistant, text: "I'll trace it.")
        let messages = [user, text,
                        read("\(root)/macOS/Sources/BotChu/App/AppModel.swift"),
                        call("Grep", "func tab", arguments: ["pattern": "func tab", "path": "\(root)/macOS/Sources"]),
                        call("Bash", "ls macOS/Sources/BotChu/Chat"),
                        call("Bash", "swift build --package-path macOS"),
                        read("\(root)/README.md"),
                        call("Edit", "\(root)/README.md", arguments: ["file_path": "\(root)/README.md", "old_string": "a", "new_string": "b"]),
                        read("\(root)/PROJECT.md"),
                        ChatMessage(role: .assistant, text: "Done."),
                        read("\(root)/AGENTS.md"),
                        call("Task", "Explore", arguments: ["description": "Explore the sidebar"]),
                        read("\(root)/CLAUDE.md")]
        let kinds = items(messages).map { item -> String in
            switch item {
            case .message(let message): message.role.rawValue
            case .tool(let tool): tool.activity.intent.rawValue
            case .exploration(let group): "explored \(group.calls.count)"
            }
        }
        #expect(kinds == ["user", "assistant", "explored 3", "command", "explored 1", "edit", "explored 1", "assistant",
                          "explored 1", "subagent", "explored 1"])
        guard case .exploration(let first) = items(messages)[2] else { Issue.record("no group"); return }
        #expect(first.summary == "1 file · 1 folder · 1 search")
        #expect(!first.isOpen)
        guard case .exploration(let last) = items(messages).last! else { Issue.record("no group"); return }
        #expect(last.isOpen)
    }

    @Test func summaryNamesFilesFoldersAndFailures() {
        let folders = ["App", "Chat", "Inspector", "Sidebar"]
        var messages = (0..<19).map { i in read("\(root)/macOS/Sources/BotChu/\(folders[i % 4])/File\(i).swift") }
        messages.insert(read("\(root)/macOS/Sources/BotChu/App/File0.swift"), at: 1)
        messages.append(read("\(root)/macOS/Sources/BotChuCore/BotStatus.swift"))
        messages.append(call("Grep", "tab(of", arguments: ["pattern": "tab(of"]))
        for name in ["MainWindow", "Pets", "MessageRow", "MarkdownView", "A", "B", "C"] {
            messages.append(read("\(root)/macOS/Sources/BotChu/\(name).swift", state: .failed, output: "File does not exist."))
        }
        messages.append(read("\(root)/x.swift", state: .failed, output: "EACCES: permission denied"))
        guard case .exploration(let group) = items(messages).first else { Issue.record("no group"); return }
        #expect(group.counts.files == 20)
        #expect(group.counts.searches == 1)
        #expect(group.summary == "20 files · 1 search")
        #expect(group.location == "BotChu/App, Chat, Inspector, Sidebar · BotChuCore")
        let searched = items(messages.dropLast(9) + [call("Grep", "x", arguments: ["pattern": "x", "path": "\(root)/macOS/Sources"])])
        guard case .exploration(let wide) = searched.first else { Issue.record("no group"); return }
        #expect(wide.location == "BotChu/App, Chat, Inspector, Sidebar · BotChuCore")
        #expect(group.files.first == FileChip(path: "\(root)/macOS/Sources/BotChu/App/File0.swift", name: "File0.swift", reads: 2))
        #expect(group.failures.map(\.reason) == ["not found", "permission denied"])
        #expect(group.failures[0].count == 7)
        #expect(group.failures[0].names.prefix(4) == ["MainWindow.swift", "Pets.swift", "MessageRow.swift", "MarkdownView.swift"])
        #expect(group.failureCount == 8)
    }

    @Test func repeatedReadsShowOnceWithMergedRanges() {
        let path = "\(root)/.botchu/tasks/F35D2397220/thread.jsonl"
        let messages = [read(path, offset: 1, limit: 30), read(path, offset: 31, limit: 30), read("\(root)/steps/38/output.txt"),
                        read(path, offset: 100, limit: 10)]
        guard case .exploration(let group) = items(messages).first else { Issue.record("no group"); return }
        #expect(group.entries.count == 3)
        #expect(group.entries[0].count == 2)
        #expect(group.entries[0].detail == "×2 · L1–60")
        // The calls underneath stay inspectable.
        #expect(group.entries[0].calls.map(\.id) == [messages[0].id, messages[1].id])
        #expect(group.files.first?.reads == 3)
    }

    @Test func durationAndLiveState() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var first = read("\(root)/a.swift", date: start)
        first.toolDuration = 0.5
        var second = read("\(root)/b.swift", date: start.addingTimeInterval(4))
        second.toolDuration = 2.2
        let running = read("\(root)/c.swift", state: .running, date: start.addingTimeInterval(7))
        guard case .exploration(let done) = items([first, second]).first, case .exploration(let live) = items([first, second, running]).first else {
            Issue.record("no group"); return
        }
        #expect(abs(done.finished.timeIntervalSince(done.started) - 6.2) < 0.001)
        #expect(!done.running)
        #expect(live.running && live.isOpen)
        #expect(live.entries.last?.state == .running)
    }
}

@Suite struct IncrementalTranscriptTests {
    @Test func streamingTouchesOnlyTheTail() {
        var messages: [ChatMessage] = []
        for turn in 0..<300 {
            messages.append(ChatMessage(role: .user, text: "Step \(turn)"))
            for i in 0..<5 { messages.append(call("Read", "/work/f\(turn)-\(i).swift")) }
            messages.append(call("Bash", "swift build"))
            messages.append(ChatMessage(role: .assistant, text: "Done \(turn)"))
        }
        var transcript = ActivityTranscript(root: "/work")
        transcript.update(messages)
        #expect(transcript.items.count == 1_200)
        #expect(transcript.lastExamined == messages.count)
        // A reply streaming in: only the last message is looked at again.
        messages[messages.count - 1].text += " and more"
        transcript.update(messages)
        #expect(transcript.lastExamined == 1)
        guard case .message(let last) = transcript.items.last else { Issue.record("no reply"); return }
        #expect(last.text == "Done 299 and more")
        // A new exploration: the reply settles, and only the open group is examined as it grows.
        messages.append(call("Read", "/work/new.swift", state: .running))
        transcript.update(messages)
        #expect(transcript.lastExamined <= 2)
        for i in 0..<50 { messages.append(call("Grep", "pattern\(i)")) }
        transcript.update(messages)
        #expect(transcript.lastExamined == 51)
        messages[messages.count - 51].toolState = .done
        messages.append(ChatMessage(role: .assistant, text: "Found it."))
        transcript.update(messages)
        let settledBefore = transcript.settledItems
        messages[messages.count - 1].text += " Really."
        transcript.update(messages)
        #expect(transcript.lastExamined == 1)
        #expect(transcript.settledItems == settledBefore)
        #expect(transcript.items.count == 1_202)
    }

    @Test func runningCallsKeepTheirItemOpenAndReplacedThreadsStartOver() {
        var messages = [call("Read", "/work/a.swift", state: .running), call("Bash", "swift build", state: .running),
                        ChatMessage(role: .assistant, text: "Waiting")]
        var transcript = ActivityTranscript(root: "/work")
        transcript.update(messages)
        #expect(transcript.settledItems == 0)
        messages[0].toolState = .done
        transcript.update(messages)
        #expect(transcript.settledItems == 1)
        // A new session replaces the thread.
        transcript.update([ChatMessage(role: .note, text: "New session")])
        #expect(transcript.items.count == 1 && transcript.lastExamined == 1)
        transcript.update([])
        #expect(transcript.items.isEmpty)
    }
}

@Suite struct DelegationCardTests {
    @Test func parsesCallsSpawnsAndWaits() {
        let spawn = describe(call("Bash", "first=$(botchu-subagent spawn --agent 'QA Bot' --title 'Check it' --brief 'Run tests.')\nsecond=$(botchu-subagent spawn --agent docs --brief 'Notes')\nbotchu-subagent wait \"$first\" \"$second\""))
        #expect(spawn.intent == .subagent)
        #expect(spawn.delegation?.launches.map(\.agent) == ["QA Bot", "docs"])
        #expect(spawn.delegation?.launches.first?.title == "Check it")
        #expect(spawn.delegation?.waitsFor == 2)
        let id = UUID()
        let called = describe(call("Bash", "botchu-subagent call --agent=it-racoon --brief x",
                                   output: "=== Sub-agent: IT Racoon (\(id.uuidString.lowercased())) ===\nAll good.\nStatus: completed"))
        #expect(called.delegation?.launches.first?.agent == "it-racoon" && called.delegation?.launches.first?.waits == true)
        #expect(called.runIDs == [id])
        let wait = describe(call("Bash", "botchu-subagent wait \(id.uuidString)"))
        #expect(wait.intent == .subagent && wait.delegation?.isLaunch == false && wait.delegation?.waitsFor == 1)
    }

    @Test func runsGoToTheCallThatStartedThem() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let printed = UUID(), byTitle = UUID(), byTime = UUID(), stray = UUID()
        let launches = [
            SubagentPlacement.Launch(messageID: UUID(), started: start, finished: start.addingTimeInterval(1), printedIDs: [printed],
                                     launches: [.init(agent: "qa", title: nil, waits: false)]),
            SubagentPlacement.Launch(messageID: UUID(), started: start.addingTimeInterval(10), finished: nil, printedIDs: [],
                                     launches: [.init(agent: "docs", title: "Release notes", waits: true),
                                                .init(agent: "qa", title: nil, waits: true)]),
        ]
        let runs = [
            SubagentPlacement.Run(id: printed, createdAt: start.addingTimeInterval(1.5), title: "Run tests", agent: "QA"),
            SubagentPlacement.Run(id: byTime, createdAt: start.addingTimeInterval(11), title: "Check", agent: "QA"),
            SubagentPlacement.Run(id: byTitle, createdAt: start.addingTimeInterval(12), title: "Release notes", agent: "Docs"),
            SubagentPlacement.Run(id: stray, createdAt: start.addingTimeInterval(500), title: "Later", agent: "QA"),
        ]
        let placed = SubagentPlacement.assign(launches: launches, runs: runs, now: start.addingTimeInterval(20))
        #expect(placed[launches[0].messageID] == [printed])
        #expect(placed[launches[1].messageID] == [byTime, byTitle])
        // A call dated after now (the clock moved back) places nothing, and doesn't trap.
        let future = SubagentPlacement.Launch(messageID: UUID(), started: start.addingTimeInterval(9_999), finished: nil, printedIDs: [],
                                              launches: [.init(agent: "qa", title: nil, waits: true)])
        #expect(SubagentPlacement.assign(launches: [future], runs: runs, now: start)[future.messageID] == [])
        let items = [(id: UUID(), date: start), (id: UUID(), date: start.addingTimeInterval(400))]
        #expect(SubagentPlacement.anchors(for: [runs[3]], items: items) == [items[1].id: [stray]])
    }

    @Test func seventeenSpawnsAreSeventeenCards() {
        let ids = (0..<17).map { _ in UUID() }
        let start = Date()
        let messages = ids.enumerated().map { index, id in
            call("Bash", "botchu-subagent spawn --agent 'Helper \(index)' --title 'Area \(index)' --brief 'Look'",
                 output: id.uuidString.lowercased() + "\n", date: start.addingTimeInterval(Double(index)))
        }
        var transcript = ActivityTranscript()
        transcript.update(messages)
        let launches = transcript.items.compactMap { item -> SubagentPlacement.Launch? in
            guard case .tool(let tool) = item, let delegation = tool.activity.delegation else { return nil }
            return SubagentPlacement.Launch(messageID: tool.id, started: tool.message.date, finished: tool.message.date,
                                            printedIDs: tool.activity.runIDs, launches: delegation.launches)
        }
        let runs = ids.enumerated().map { SubagentPlacement.Run(id: $1, createdAt: start.addingTimeInterval(Double($0) + 0.3), title: "Area \($0)", agent: "Helper \($0)") }
        let placed = SubagentPlacement.assign(launches: launches, runs: runs)
        #expect(launches.count == 17)
        #expect(placed.values.map(\.count) == Array(repeating: 1, count: 17))
        #expect(Set(placed.values.flatMap { $0 }) == Set(ids))
    }
}

@Suite struct FolderSummaryTests {
    @Test func namesSharedFoldersOnce() {
        let root = "/work/BotChu"
        #expect(FolderSummary.describe(files: ["\(root)/steps/38/output.txt"], root: root) == "steps/38")
        #expect(FolderSummary.describe(files: ["\(root)/a.swift"], root: root) == "")
        #expect(FolderSummary.describe(files: ["\(root)/a/b/c/d.swift"], root: root) == "b/c")
        #expect(FolderSummary.describe(files: ["\(root)/x/one/a.swift", "\(root)/y/b.swift", "\(root)/z/c.swift", "\(root)/w/d.swift"],
                                       root: root) == "x/one · y · z · +1 more")
        #expect(FolderSummary.describe(files: [NSHomeDirectory() + "/Desktop/a.png"], root: root) == "~/Desktop")
        // A searched folder holding the others adds nothing; the busiest folder comes first.
        let sources = "\(root)/macOS/Sources"
        #expect(FolderSummary.describe(files: ["\(sources)/BotChuCore/BotStatus.swift", "\(sources)/BotChu/App/A.swift", "\(sources)/BotChu/Chat/B.swift",
                                              "\(sources)/BotChu/App/C.swift"], folders: [sources], root: root) == "BotChu/App, Chat · BotChuCore")
        #expect(FolderSummary.describe(files: ["\(root)/.botchu/tasks/2DB14BE2-49F0-4D1F-B8C5-3F35D2397220/thread.jsonl"], root: root)
                == "tasks/…F35D2397220")
    }
}
