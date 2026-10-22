// Runs two real turns on each account named (all accounts when none is), the way the app does:
// a new session that opens with the bot's context, then a resumed one that must remember a code word.
// Prints each thread and exits non-zero when an account fails. Needs the CLIs signed in.
//
//   swift run --package-path macOS botchu-smoke claude-personal codex-dev
//   OPENROUTER_API_KEY=… swift run --package-path macOS botchu-smoke openrouter
import Foundation
import BotChuCore

// Each line as it is printed, also when the output goes to a file.
setvbuf(stdout, nil, _IOLBF, 0)

let requested = Array(CommandLine.arguments.dropFirst())
let accounts = requested.isEmpty ? Accounts.all : requested.map { Accounts.account(id: $0) }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-smoke-\(UUID().uuidString)")

struct Turn {
    var messages: [ChatMessage] = []
    var session: String?
    var status: Int32 = 0
    var stderr = ""
}

func runTurn(_ bot: Bot, prompt: String, history: [ChatMessage]) async -> Turn {
    let resume = bot.resumableSessionID
    let preamble = resume == nil
        ? BotContext.sessionPreamble(bot: bot, memory: Workspace.read(bot.workspace + "/MEMORY.md"), sharedMemory: "", history: history)
        : nil
    let invocation = CommandBuilder.invocation(
        kind: bot.account.kind, prompt: BotContext.prompt(for: prompt, preamble: preamble), model: bot.model, sessionID: resume, reasoningEffort: bot.reasoningEffort,
        openRouterKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"])
    return await withCheckedContinuation { continuation in
        var turn = Turn()
        var parser = StreamParsers.make(for: bot.account.kind)
        var assembler = ThreadAssembler()
        let run = AgentRun(command: bot.account.defaultCommand, invocation: invocation, directory: URL(fileURLWithPath: bot.workspace))
        run.onLines = { lines in
            for line in lines {
                for event in parser.parse(line: line) {
                    if case .session(let reported) = event {
                        turn.session = CommandBuilder.resumeID(kind: bot.account.kind, invocation: invocation, reported: reported)
                    }
                    assembler.apply(event, to: &turn.messages)
                }
            }
        }
        run.onExit = { status, stderr in
            assembler.apply(.textEnd, to: &turn.messages)
            ThreadAssembler.closeRunningTools(&turn.messages)
            turn.status = status
            turn.stderr = stderr
            continuation.resume(returning: turn)
        }
        do { try run.start() } catch {
            turn.messages.append(ChatMessage(role: .error, text: "\(error)"))
            continuation.resume(returning: turn)
        }
    }
}

func show(_ messages: [ChatMessage]) {
    for m in messages {
        switch m.role {
        case .tool: print("    [\(m.toolState?.rawValue ?? "?")] \(m.toolName ?? "") \(m.toolInput?.prefix(60) ?? "")")
        default: print("    \(m.role.rawValue): \(m.text.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        }
    }
}

Task {
    var failures: [String] = []
    for account in accounts {
        let word = "ZEBRA\(Int.random(in: 100...999))"
        var bot = Bot(name: "Smoke", title: "A test bot", instructions: "Answer in as few words as possible.",
                      accountID: account.id, workspace: root.appendingPathComponent(account.id).path)
        bot.selectModel(ProcessInfo.processInfo.environment["BOTCHU_SMOKE_MODEL"] ?? "")
        bot.reasoningEffort = ProcessInfo.processInfo.environment["BOTCHU_SMOKE_EFFORT"].flatMap(ReasoningEffort.init(rawValue:))
        try? Workspace.prepare(bot: bot, sharedMemoryPath: root.appendingPathComponent("MEMORY.md").path)
        print("== \(account.name)")
        let started = Date()
        let first = await runTurn(bot, prompt: "The code word is \(word). Use your shell tool to run `ls`, then reply with just: stored", history: [])
        show(first.messages)
        guard let session = first.session, !first.messages.contains(where: { $0.role == .error }),
              first.messages.contains(where: { $0.role == .assistant }) else {
            print("    FAIL: first turn (exit \(first.status)) \(first.stderr.suffix(400))")
            failures.append(account.id)
            continue
        }
        bot.sessionID = session
        bot.sessionAccountID = account.id
        let second = await runTurn(bot, prompt: "What is the code word? Reply with just the word.", history: first.messages)
        show(second.messages)
        let reply = second.messages.filter { $0.role == .assistant }.map(\.text).joined()
        let ok = reply.contains(word) && !second.messages.contains(where: { $0.role == .error })
        print("    \(ok ? "OK" : "FAIL: resumed turn did not recall \(word) (exit \(second.status)) \(second.stderr.suffix(300))") in \(Int(Date().timeIntervalSince(started)))s")
        if !ok { failures.append(account.id) }
    }
    try? FileManager.default.removeItem(at: root)
    print(failures.isEmpty ? "smoke: all passed" : "smoke: failed: \(failures.joined(separator: ", "))")
    exit(failures.isEmpty ? 0 : 1)
}
dispatchMain()
