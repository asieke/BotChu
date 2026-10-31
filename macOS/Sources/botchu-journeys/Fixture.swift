import Foundation
import BotChuCore

/// The synthetic data the journeys run on (#323): 15 bots, each with 2 Project Areas (its
/// repository's and a folder's) and 2 open tasks from before areas in that repository (#402), a 5,000-message
/// conversation (the first bot's Home, shown at launch), a group of 5,000 tool calls (the second
/// bot's Home) and 200 Inbox deliveries, every bot on the fake Claude Code profile. Identities are
/// fixed and dates follow from the time it is made, so each run shows the same thing.
struct Fixture {
    static let names = ["Atlas", "Beacon", "Cobalt", "Delta", "Ember", "Fable", "Garnet", "Harbor", "Iris", "Juniper",
                        "Kestrel", "Lumen", "Meridian", "Nova", "Orchid"]
    static let emoji = ["🧭", "🗼", "🔷", "🔺", "🔥", "📖", "💎", "⚓️", "🌈", "🌲", "🦅", "💡", "🧿", "✨", "🌸"]
    /// The profile `BOTCHU_PROFILE` adds first, which every bot and task runs on.
    static let accountID = "custom-review-0"
    static let longConversation = 5_000
    static let groupCalls = 5_000
    /// Each bot's conversations beside Home: its 2 areas, then its 2 tasks.
    static let tasksPerBot = 4
    static let areasPerBot = 2
    static let deliveries = 200

    let data: URL
    let bots: [Bot]
    /// Each bot's Home conversation's last item (its last message), and each task's, by the bot's or
    /// the task's id, which shows when it is opened.
    let lastItem: [UUID: UUID]

    var longBot: Bot { bots[0] }
    var groupBot: Bot { bots[1] }

    /// A bot's areas, then its open tasks, in the order they were made.
    func tasks(of bot: Bot) -> [UUID] {
        guard let index = bots.firstIndex(where: { $0.id == bot.id }) else { return [] }
        return (0..<Self.tasksPerBot).map { Self.id(100 + index * Self.tasksPerBot + $0) }
    }

    /// A bot's 2 Project Areas, its repository's then its folder's.
    func areas(of bot: Bot) -> [UUID] { Array(tasks(of: bot).prefix(Self.areasPerBot)) }

    func delivery(_ n: Int) -> UUID { Self.id(10_000 + n) }

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8323-%012llx", UInt64(n)))!
    }

    static func make(in data: URL, fakeCLI: String) throws -> Fixture {
        try? FileManager.default.removeItem(at: data)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let now = Date()
        let account = Account(id: accountID, name: "Journey Claude", kind: .claude, defaultCommand: fakeCLI, symbol: "terminal")
        var bots: [Bot] = [], lastItem: [UUID: UUID] = [:], entries: [Store.Entry] = []
        var serial = 1_000
        func next() -> UUID {
            serial += 1
            return id(serial)
        }
        for (index, name) in names.enumerated() {
            var bot = Bot(id: id(index + 1), name: name, emoji: emoji[index], title: "Journey bot \(index + 1)",
                          instructions: "Be brief.", accountID: accountID,
                          workspace: data.appendingPathComponent("bots/\(name.lowercased())").path,
                          createdAt: now.addingTimeInterval(-60 * 86_400))
            bot.accountProfile = account
            let home = BotHome(workspace: bot.workspace)
            try home.save(bot)
            let start = now.addingTimeInterval(-Double(index + 1) * 3_600 - 40 * 86_400)
            let thread: [ChatMessage] = switch index {
            case 0: conversation(count: longConversation, bot: name, start: start, id: next)
            case 1: group(calls: groupCalls, bot: name, start: start, id: next)
            default: conversation(count: 40, bot: name, start: start, id: next)
            }
            _ = try home.writeTranscript(thread)
            lastItem[bot.id] = thread.last?.id
            for n in 0..<tasksPerBot {
                let checkout = data.appendingPathComponent("repos/repo-\(index)").path
                let made = start.addingTimeInterval(Double(n) * 600)
                var task: BotTask
                switch n {
                case 0: task = BotTask(repoArea: "journeys/repo-\(index)", checkout: checkout, for: bot, at: made)
                case 1:
                    let folder = (bot.workspace as NSString).appendingPathComponent("\(Areas.folderName)/notes")
                    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    task = BotTask(folderArea: "Notes", folder: folder, for: bot, at: made)
                default:
                    task = BotTask(for: bot, repo: "journeys/repo-\(index)", checkout: checkout, work: nil,
                                   brief: "Task \(n + 1) of \(name): tidy the module and open a pull request.",
                                   branch: "feat/\(name.lowercased())-\(n + 1)", title: "repo-\(index) · Task \(n + 1)")
                    task.folder = checkout
                    task.createdAt = made
                }
                task.id = id(100 + index * tasksPerBot + n)
                try home.save(task)
                let taskThread = conversation(count: 12, bot: name, start: task.createdAt, id: next)
                _ = try home.writeTranscript(taskThread, task: task.id)
                lastItem[task.id] = taskThread.last?.id
            }
            bots.append(bot)
            entries.append(Store.Entry(id: bot.id, workspace: bot.workspace))
        }
        let purposes: [Delivery.Purpose] = [.needsInput, .review, .completed, .fyi]
        for n in 0..<deliveries {
            let bot = bots[n % bots.count]
            let delivery = Delivery(id: id(10_000 + n), botID: bot.id, taskID: n.isMultiple(of: 3) ? id(100 + (n % bots.count) * tasksPerBot) : nil,
                                    title: "Delivery \(n + 1) from \(bot.name)",
                                    note: "Finished part \(n + 1): the change is in a pull request, with its tests passing. Look when you can.",
                                    purpose: purposes[n % purposes.count], sentAt: now.addingTimeInterval(-Double(n) * 2_700))
            try InboxFolder(home: BotHome(workspace: bot.workspace)).save(delivery, contents: [:])
        }
        try Store(root: data).saveIndex(entries)
        try makeRepository(at: data.appendingPathComponent("repos/\(TaskNaming.repoName(taskRepo))"))
        let fixture = Fixture(data: data, bots: bots, lastItem: lastItem)
        try fixture.markProjectsSynced()
        return fixture
    }

    /// The fixture's project, which Projects lists: a local repository without an origin, in the
    /// repositories folder BotChu uses with `BOTCHU_DATA_DIR`, so a worktree is made here and
    /// nothing reaches GitHub.
    static let taskRepo = "journeys/repo-0"

    static func makeRepository(at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# repo-0\n\nThe journeys' project.\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        for arguments in [["init", "--quiet", "--initial-branch=main"], ["add", "README.md"],
                          ["-c", "user.name=Journeys", "-c", "user.email=journeys@example.invalid", "commit", "--quiet", "-m", "Start"]] {
            try AppUnderTest.run("/usr/bin/git", ["-C", folder.path] + arguments)
        }
    }

    /// Projects' catalog as synced a day from now, listing the task project, so BotChu doesn't sync
    /// it with GitHub at launch or in the rest of the run (`ProjectSync.staleAfter` is two minutes).
    func markProjectsSynced() throws {
        var snapshot = ProjectSnapshot(login: "journeys")
        snapshot.pages = [ProjectSnapshot.Page(etag: "", repos: [ProjectSnapshot.Listed(nameWithOwner: Self.taskRepo, description: "The journeys' project",
                                                                                        pushedAt: Date(), updatedAt: Date())])]
        snapshot.syncedAt = Date().addingTimeInterval(86_400)
        snapshot.fullSyncedAt = Date().addingTimeInterval(86_400)
        try JSONEncoder().encode(snapshot).write(to: data.appendingPathComponent("projects.json"), options: .atomic)
    }

    /// `count` messages in turns of twelve, as an agent works: the owner's message, nine calls (Read,
    /// Grep and Bash) with about a kilobyte of output each, and two replies; the last is a reply.
    static func conversation(count: Int, bot: String, start: Date, id: () -> UUID) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        var clock = start
        func date() -> Date {
            clock = clock.addingTimeInterval(7)
            return clock
        }
        var turn = 0
        while messages.count < count - 1 {
            messages.append(ChatMessage(id: id(), role: .user, text: "Step \(turn): keep going with the next part of the refactor.", date: date()))
            for call in 0..<9 where messages.count < count - 1 {
                let file = "macOS/Sources/BotChu/\(["App", "Chat", "Inspector", "Sidebar"][call % 4])/File\(call).swift"
                let (name, input) = call % 3 == 0 ? ("Read", file) : call % 3 == 1 ? ("Grep", "func tab\\(of") : ("Bash", "swift build --package-path macOS")
                messages.append(ChatMessage(id: id(), role: .tool, date: date(), toolID: "call-\(turn)-\(call)", toolName: name, toolInput: input,
                                            toolOutput: String(repeating: "line \(call) of the output, with some words in it\n", count: 20),
                                            toolState: .done, toolExitCode: name == "Bash" ? 0 : nil))
                if (call == 4 || call == 8), messages.count < count - 1 {
                    messages.append(ChatMessage(id: id(), role: .assistant, text: reply(turn: turn, part: call), date: date()))
                }
            }
            turn += 1
        }
        messages.append(ChatMessage(id: id(), role: .assistant, text: "**\(bot) is up to date.** The last step built cleanly; nothing else is waiting.", date: date()))
        return messages
    }

    /// The owner's request, `calls` exploration calls in one run (one group), and the reply.
    static func group(calls: Int, bot: String, start: Date, id: () -> UUID) -> [ChatMessage] {
        var clock = start
        func date() -> Date {
            clock = clock.addingTimeInterval(1)
            return clock
        }
        var messages = [ChatMessage(id: id(), role: .user, text: "Read through the whole repository and list every place that writes a file.", date: date())]
        for call in 0..<calls {
            let (name, input) = call % 3 == 0 ? ("Read", "Sources/Module\(call % 40)/File\(call).swift")
                : call % 3 == 1 ? ("Grep", "write\\(to: in Module\(call % 40)") : ("Glob", "Sources/Module\(call % 40)/**/*.swift")
            messages.append(ChatMessage(id: id(), role: .tool, date: date(), toolID: "group-\(call)", toolName: name, toolInput: input,
                                        toolOutput: "Sources/Module\(call % 40)/File\(call).swift:\(call % 300 + 1): try data.write(to: url)\n",
                                        toolState: .done))
        }
        messages.append(ChatMessage(id: id(), role: .assistant, text: "**\(bot) read \(calls) places.** Every write goes through `Store.save`, apart from two caches.", date: date()))
        return messages
    }

    static func reply(turn: Int, part: Int) -> String {
        var text = """
            Turn \(turn).\(part): the next part is done. I moved the parsing into `Core` and kept the view thin, so the \
            change stays testable without a window.

            - Updated `TranscriptModel` to read the new field.
            - Added a test for the empty case.
            - Left the old path in place until the migration runs.

            ```swift
            let rows = transcript.items(for: messages)
            precondition(!rows.isEmpty)
            ```
            """
        if turn.isMultiple(of: 10) {
            text += "\n\n| Step | Time | Result |\n| :--- | ---: | :--- |\n| Build | 41 s | ok |\n| Tests | 12 s | ok |\n"
        }
        return text
    }
}
