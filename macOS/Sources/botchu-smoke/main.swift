// Runs two real turns on each account named (all accounts when none is), the way the app does:
// a new session that opens with the bot's context, then a resumed one that must remember a code word.
// A CLI that takes input mid-turn (Claude Code) gets a third turn, with a follow-up written to it
// during its tool call, which it must take and answer in that same turn.
// Prints each thread and exits non-zero when an account fails. Needs the CLIs signed in.
//
//   swift run --package-path macOS botchu-smoke claude-personal codex-dev
//   OPENROUTER_API_KEY=… swift run --package-path macOS botchu-smoke openrouter
import Foundation
import BotChuCore

// Each line as it is printed, also when the output goes to a file.
setvbuf(stdout, nil, _IOLBF, 0)

// Optional image fixture is attached on both the new and resumed turn.
let smokeImage = ProcessInfo.processInfo.environment["BOTCHU_SMOKE_IMAGE"].map { URL(fileURLWithPath: $0) }
let imageExpected = ProcessInfo.processInfo.environment["BOTCHU_SMOKE_IMAGE_EXPECT"]
let usageOnly = CommandLine.arguments.dropFirst().first == "--usage"
let requested = Array(CommandLine.arguments.dropFirst(usageOnly ? 2 : 1))
let accounts = requested.isEmpty ? Accounts.all : requested.map { Accounts.account(id: $0) }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-smoke-\(UUID().uuidString)")

struct Turn {
    var messages: [ChatMessage] = []
    var session: String?
    var status: Int32 = 0
    var stderr = ""
    /// Follow-ups the CLI took during the turn.
    var followUpsTaken = 0
}

/// `followUp` is written to a CLI that takes input mid-turn at its first tool call.
func runTurn(_ bot: Bot, prompt: String, history: [ChatMessage], followUp: String? = nil) async -> Turn {
    let resume = bot.resumableSessionID
    let preamble = resume == nil
        ? BotContext.sessionPreamble(bot: bot, memory: Workspace.read(bot.workspace + "/MEMORY.md"), sharedMemory: "", history: history,
                                     soul: Workspace.read(bot.workspace + "/SOUL.md"))
        : nil
    let kind = bot.account.kind
    let fullPrompt = BotContext.prompt(for: prompt, preamble: preamble)
    var invocation = CommandBuilder.invocation(
        kind: bot.account.kind, prompt: fullPrompt, model: bot.model, sessionID: resume, reasoningEffort: bot.reasoningEffort,
        openRouterKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], liveInput: CommandBuilder.takesInputMidTurn(kind))
    if let smokeImage {
        do { invocation = try ImageDelivery.attaching([smokeImage], to: invocation, kind: bot.account.kind, prompt: fullPrompt) }
        catch { return Turn(messages: [ChatMessage(role: .error, text: error.localizedDescription)], status: -1) }
    }
    return await withCheckedContinuation { continuation in
        var turn = Turn()
        var assembler = ThreadAssembler()
        var ledger = InputLedger()
        var pending = followUp
        let run = AgentRun(command: bot.account.defaultCommand, invocation: invocation, directory: URL(fileURLWithPath: bot.workspace))
        // As the app does: parsed off the main thread, delivered in batches.
        run.deliverEvents(parsedBy: StreamParsers.make(for: kind)) { events in
            for event in events {
                switch event {
                case .session(let reported):
                    turn.session = CommandBuilder.resumeID(kind: kind, invocation: invocation, reported: reported)
                case .inputTaken:
                    if ledger.taken(), let followUp {
                        turn.followUpsTaken += 1
                        assembler.apply(event, to: &turn.messages)
                        turn.messages.append(ChatMessage(role: .user, text: followUp))
                    }
                case .toolStarted:
                    // As the app does: written once the CLI has echoed the prompt.
                    if let text = pending, ledger.acceptsFollowUps, let line = CommandBuilder.inputLine(kind: kind, text: text), run.send(line) {
                        ledger.wrote()
                        pending = nil
                    }
                case .finished, .failed:
                    if invocation.input != nil, ledger.turnEnded() { run.closeInput() }
                default: break
                }
                if case .inputTaken = event { continue }
                assembler.apply(event, to: &turn.messages)
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
        case .tool:
            // How the chat files the call: its intent, what it names, and the facts it kept.
            let activity = ToolActivity.describe(m)
            let facts = [activity.detail, m.toolExitCode.map { "exit \($0)" }, m.toolArguments == nil ? nil : "arguments kept",
                         m.toolDuration.map { String(format: "%.1fs", $0) }].compactMap { $0 }
            print("    [\(m.toolState?.rawValue ?? "?")] \(m.toolName ?? "") \(m.toolInput?.prefix(60) ?? "")")
            print("      → \(activity.intent.rawValue): \(activity.title)" + (facts.isEmpty ? "" : " · " + facts.joined(separator: " · ")))
        default: print("    \(m.role.rawValue): \(m.text.replacingOccurrences(of: "\n", with: " ").prefix(160))")
        }
    }
}

Task {
    var failures: [String] = []
    for account in accounts {
        if usageOnly {
            print("== \(account.name) usage")
            do {
                let reading = try await ProviderUsageClient.read(UsageRequest(account: account, command: account.defaultCommand),
                    openRouterKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"])
                for window in reading.windows {
                    let percent = window.usedPercent.map { "\($0.formatted(.number.precision(.fractionLength(1))))% used" } ?? "not reported"
                    let reset = window.resetsAt?.formatted(.iso8601) ?? window.resetDescription ?? "not reported"
                    print("    \(window.title): \(percent); reset \(reset)")
                }
                if let note = reading.note { print("    \(note)") }
                print("    OK")
            } catch {
                print("    FAIL: \((error as? UsageFailure)?.message ?? "Usage query failed")")
                failures.append(account.id)
            }
            continue
        }
        let word = "ZEBRA\(Int.random(in: 100...999))"
        var bot = Bot(name: "Smoke", title: "A test bot", instructions: "Answer in as few words as possible.",
                      accountID: account.id, workspace: root.appendingPathComponent(account.id).path)
        if ProcessInfo.processInfo.environment["BOTCHU_SMOKE_CUSTOM_PROFILE"] == "1" {
            bot.selectAccount(Account(id: "custom-" + account.id, name: account.name + " profile", kind: account.kind,
                                      defaultCommand: account.defaultCommand, symbol: account.symbol))
            // A custom profile must work after the same persistence round trip used by a bot.
            if let data = try? JSONEncoder().encode(bot), let restored = try? JSONDecoder().decode(Bot.self, from: data) { bot = restored }
        }
        bot.selectModel(ProcessInfo.processInfo.environment["BOTCHU_SMOKE_MODEL"] ?? "")
        bot.reasoningEffort = ProcessInfo.processInfo.environment["BOTCHU_SMOKE_EFFORT"].flatMap(ReasoningEffort.init(rawValue:))
        try? Workspace.prepare(bot: bot, sharedMemoryPath: root.appendingPathComponent("MEMORY.md").path)
        print("== \(account.name)")
        let started = Date()
        let imageRequest = smokeImage == nil ? "" : " Also read the large word in the attached image and include it in your reply."
        let first = await runTurn(bot, prompt: "The code word is \(word). Use your shell tool to run `ls`, then reply with: stored." + imageRequest, history: [])
        show(first.messages)
        guard let session = first.session, !first.messages.contains(where: { $0.role == .error }),
              first.messages.contains(where: { $0.role == .assistant }),
              imageExpected.map({ expected in first.messages.filter { $0.role == .assistant }.map(\.text).joined().localizedCaseInsensitiveContains(expected) }) ?? true else {
            print("    FAIL: first turn (exit \(first.status)) \(first.stderr.suffix(400))")
            failures.append(account.id)
            continue
        }
        bot.sessionID = session
        bot.sessionAccountID = bot.accountID
        precondition(bot.resumableSessionID == session, "The second smoke turn must resume its profile’s session")
        let second = await runTurn(bot, prompt: "What is the code word? Reply with the word." + imageRequest, history: first.messages)
        show(second.messages)
        let reply = second.messages.filter { $0.role == .assistant }.map(\.text).joined()
        let ok = reply.contains(word) && !second.messages.contains(where: { $0.role == .error }) && (imageExpected.map { reply.localizedCaseInsensitiveContains($0) } ?? true)
        print("    \(ok ? "OK" : "FAIL: resumed turn did not recall \(word) (exit \(second.status)) \(second.stderr.suffix(300))") in \(Int(Date().timeIntervalSince(started)))s")
        if !ok { failures.append(account.id); continue }
        guard CommandBuilder.takesInputMidTurn(account.kind) else { continue }
        let third = await runTurn(bot, prompt: "Use your shell tool to run `sleep 8`, then reply with just: slept",
                                  history: first.messages + second.messages,
                                  followUp: "Also, after the command, add the code word to your reply.")
        show(third.messages)
        let steered = third.messages.filter { $0.role == .assistant }.map(\.text).joined()
        let steerOK = third.followUpsTaken == 1 && steered.contains(word) && !third.messages.contains(where: { $0.role == .error })
        print("    \(steerOK ? "OK: took the follow-up mid-turn" : "FAIL: follow-up taken \(third.followUpsTaken) times, reply \(steered.prefix(120)) (exit \(third.status)) \(third.stderr.suffix(300))")")
        if !steerOK { failures.append(account.id) }
    }
    try? FileManager.default.removeItem(at: root)
    print(failures.isEmpty ? "smoke: all passed" : "smoke: failed: \(failures.joined(separator: ", "))")
    exit(failures.isEmpty ? 0 : 1)
}
dispatchMain()
