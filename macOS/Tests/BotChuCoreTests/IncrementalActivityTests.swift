import Foundation
import Testing
@testable import BotChuCore

/// A transcript kept up to date as a thread streams in (#108): each update does work for what
/// changed, never for the whole of a long exploration, and shows exactly what grouping the thread
/// afresh shows.
private let root = "/work/BotChu"

private func tool(_ name: String, _ input: String, arguments: [String: Any]? = nil, output: String? = "ok",
                  state: ChatMessage.ToolState = .done, date: Date = Date(), id: UUID = UUID()) -> ChatMessage {
    ChatMessage(id: id, role: .tool, date: date, toolID: id.uuidString, toolName: name, toolInput: input,
                toolOutput: state == .running ? nil : output, toolState: state, toolArguments: arguments.flatMap { ToolArguments.digest($0) })
}

private func read(_ path: String, offset: Int? = nil, limit: Int? = nil, output: String = "ok", state: ChatMessage.ToolState = .done,
                  id: UUID = UUID()) -> ChatMessage {
    var arguments: [String: Any] = ["file_path": path]
    if let offset { arguments["offset"] = offset }
    if let limit { arguments["limit"] = limit }
    return tool("Read", path, arguments: arguments, output: output, state: state, id: id)
}

/// The calls of a long exploration: reads of distinct files in four folders, searches and listings.
private func exploring(_ index: Int, state: ChatMessage.ToolState = .done, id: UUID = UUID()) -> ChatMessage {
    let folder = ["App", "Chat", "Inspector", "Sidebar"][index % 4]
    switch index % 3 {
    case 0: return read("\(root)/macOS/Sources/BotChu/\(folder)/File\(index).swift", offset: 1, limit: 120, state: state, id: id)
    case 1: return tool("Grep", "func tab", arguments: ["pattern": "func tab", "path": "\(root)/macOS/Sources"], state: state, id: id)
    default: return tool("Bash", "ls -la \(root)/macOS/Sources/BotChu/\(folder)", state: state, id: id)
    }
}

/// Everything the chat shows of the items, to compare two transcripts.
private func shown(_ items: ChunkedArray<ActivityItem>) -> [String] {
    items.map { item in
        switch item {
        case .message(let message):
            return "message \(message.id) \(message.role) \(message.text)"
        case .tool(let tool):
            return "tool \(tool.id) \(tool.activity.intent) \(tool.state) \(tool.activity.title) \(tool.activity.failure ?? "-") \(tool.activity.runIDs)"
        case .exploration(let group):
            let entries = group.entries.map { "\($0.id) \($0.range) \($0.state) \($0.detail ?? "-") \($0.failure ?? "-") \($0.activity.title)" }
            return "group \(group.id) open \(group.isOpen) running \(group.running) calls \(group.calls.map(\.id)) "
                + "states \(group.calls.map { $0.toolState?.rawValue ?? "-" }) entries \(entries) files \(group.files) "
                + "counts \(group.counts) location \(group.location) failures \(group.failures) failed \(group.failureCount) "
                + "finished \(group.finished.timeIntervalSinceReferenceDate) summary \(group.summary)"
        }
    }
}

private func fresh(_ messages: [ChatMessage]) -> ActivityTranscript {
    var transcript = ActivityTranscript(root: root)
    transcript.update(messages)
    return transcript
}

/// SplitMix64: the same sequence on every run.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct IncrementalExplorationTests {
    @Test(arguments: [400, 1_000, 5_000])
    func oneCallInALiveGroupCostsTheSameWhateverItsSize(count: Int) {
        var messages = [ChatMessage(role: .user, text: "Trace it")] + (0..<count).map { exploring($0) }
        var transcript = ActivityTranscript(root: root)
        transcript.update(messages)
        #expect(transcript.items.count == 2)
        // A call starts…
        let id = UUID()
        messages.append(exploring(count, state: .running, id: id))
        let before = transcript.items.last
        transcript.update(messages)
        let started = transcript.lastWork
        #expect(started.processed == 1)
        #expect(started.described == 1)
        #expect(started.aggregated == 1)
        #expect(started.checked <= 1)
        #expect(started.folders <= 8)
        #expect(transcript.items.last != before)
        // …and finishes: taken out of the summary and put back, nothing else.
        messages[messages.count - 1] = exploring(count, state: .done, id: id)
        transcript.update(messages)
        let finished = transcript.lastWork
        #expect(finished.processed == 1)
        #expect(finished.described == 1)
        #expect(finished.aggregated == 2)
        #expect(finished.checked == 1)
        #expect(finished.folders <= 8)
        // Nothing changed: nothing is done, and the group compares equal without its calls being compared.
        let settled = transcript.items.last
        transcript.update(messages)
        #expect(transcript.lastWork == ActivityTranscript.Work(checked: 1))
        #expect(transcript.items.last == settled)
        // It keeps state only for the call that can still change.
        #expect(transcript.retained.groups == 1)
        #expect(transcript.retained.undoable <= 1)
        #expect(transcript.retained.descriptions <= 1)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
    }

    @Test func summariesStayRightThroughRepeatsFailuresFoldersAndOutOfOrderEnds() {
        let path = "\(root)/.botchu/tasks/F35D2397220/thread.jsonl"
        var messages: [ChatMessage] = [ChatMessage(role: .user, text: "Go")]
        var transcript = ActivityTranscript(root: root)
        func step(_ change: (inout [ChatMessage]) -> Void) {
            change(&messages)
            transcript.update(messages)
            #expect(shown(transcript.items) == shown(fresh(messages).items))
        }
        // Three reads start at once, in parallel; then a repeated read and a search.
        let a = UUID(), b = UUID(), c = UUID()
        step { $0 += [read(path, offset: 1, limit: 30, state: .running, id: a), read(path, offset: 31, limit: 30, state: .running, id: b),
                     read("\(root)/macOS/Sources/BotChu/App/AppModel.swift", state: .running, id: c)] }
        // They finish out of order: the last first, then the first failing, then the middle one.
        step { $0[3] = read("\(root)/macOS/Sources/BotChu/App/AppModel.swift", id: c) }
        step { $0[1] = read(path, offset: 1, limit: 30, output: "File does not exist.", state: .failed, id: a) }
        step { $0[2] = read(path, offset: 31, limit: 30, id: b) }
        // The same failure twice, in a nested folder, and one in a folder holding the others.
        step { $0 += [read("\(root)/macOS/Sources/BotChu/Chat/Gone.swift", output: "File does not exist.", state: .failed),
                     read("\(root)/macOS/Sources/BotChu/Chat/Gone.swift", output: "File does not exist.", state: .failed),
                     tool("Grep", "x", arguments: ["pattern": "x", "path": "\(root)/macOS/Sources"]),
                     tool("Bash", "ls \(root)/macOS/Sources/BotChu/Inspector")] }
        guard case .exploration(let group) = transcript.items.last else { Issue.record("no group"); return }
        #expect(group.failures.map(\.reason) == ["not found"])
        #expect(group.failures[0].count == 3)
        #expect(group.failures[0].names == ["thread.jsonl", "Gone.swift"])
        #expect(group.entries.map(\.count) == [1, 1, 1, 2, 1, 1])
        // `Sources`, searched, holds the folders read and listed: it adds nothing.
        #expect(group.location == "macOS/Chat, App, Inspector · .botchu/F35D2397220")
        // A call that is cancelled when the turn stops.
        step { $0.append(read("\(root)/README.md", state: .running)) }
        step { ThreadAssembler.closeRunningTools(&$0) }
        // An edit and a side-effecting command stand on their own.
        step { $0 += [tool("Edit", "\(root)/README.md", arguments: ["file_path": "\(root)/README.md", "old_string": "a", "new_string": "b"]),
                     tool("Bash", "swift build --package-path macOS", state: .running)] }
        let kinds = transcript.items.map { item -> String in
            switch item {
            case .message: "message"
            case .tool(let tool): tool.activity.intent.rawValue
            case .exploration: "explored"
            }
        }
        #expect(kinds == ["message", "explored", "edit", "command"])
        step { $0[$0.count - 1] = tool("Bash", "swift build --package-path macOS", id: $0[$0.count - 1].id) }
        step { $0.append(ChatMessage(role: .assistant, text: "Built.")) }
    }

    @Test func aCallWhoseKindArrivesLateRegroups() {
        var messages = [ChatMessage(role: .user, text: "Go"), read("\(root)/a.swift"), read("\(root)/b.swift")]
        var transcript = fresh(messages)
        // Claude Code starts a call before its input arrives: a shell call with no command yet.
        let id = UUID()
        messages.append(tool("Bash", "", state: .running, id: id))
        transcript.update(messages)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
        // It turns out to read, and joins the group; or to build, and stands alone.
        for input in ["cat \(root)/c.swift", "swift build", "cat \(root)/d.swift"] {
            messages[messages.count - 1] = tool("Bash", input, state: .running, id: id)
            transcript.update(messages)
            #expect(shown(transcript.items) == shown(fresh(messages).items))
        }
        guard case .exploration(let group) = transcript.items.last else { Issue.record("no group"); return }
        #expect(group.calls.count == 3)
    }

    @Test func sameLengthChangesAreSeen() {
        let id = UUID()
        var messages = [ChatMessage(role: .user, text: "Go"), read("\(root)/a.swift", output: "File does not exist.", state: .failed, id: id)]
        var transcript = fresh(messages)
        // The last call: a turn may still write into it.
        messages[1].toolOutput = "EACCES: no access!!."
        #expect(messages[1].toolOutput?.utf8.count == "File does not exist.".utf8.count)
        transcript.update(messages)
        guard case .exploration(let group) = transcript.items.last else { Issue.record("no group"); return }
        #expect(group.failures.map(\.reason) == ["permission denied"])
        // An input and arguments of the same length, naming another file.
        messages[1] = read("\(root)/b.swift", id: id)
        transcript.update(messages)
        guard case .exploration(let changed) = transcript.items.last else { Issue.record("no group"); return }
        #expect(changed.files.map(\.name) == ["b.swift"])
        #expect(shown(transcript.items) == shown(fresh(messages).items))
        // A finished call further back changes only by an edit of the thread, which is verified.
        messages.append(ChatMessage(role: .assistant, text: "Done."))
        messages.append(ChatMessage(role: .user, text: "And?"))
        transcript.update(messages)
        #expect(transcript.settledItems >= 2)
        messages[1].toolInput = "\(root)/c.swift"
        messages[1].toolArguments = ToolArguments.digest(["file_path": "\(root)/c.swift"])
        transcript.update(messages, verify: true)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
        // Verifying an unchanged thread changes nothing.
        let generation = transcript.generation
        transcript.update(messages, verify: true)
        #expect(transcript.generation == generation)
        #expect(transcript.lastWork.processed == 0)
    }

    @Test func replacedAndRepairedThreadsAreRegroupedFromTheChange() {
        var messages: [ChatMessage] = []
        for turn in 0..<40 {
            messages.append(ChatMessage(role: .user, text: "Step \(turn)"))
            messages += (0..<4).map { exploring(turn * 7 + $0) }
            messages.append(ChatMessage(role: .assistant, text: "Done \(turn)"))
        }
        var transcript = fresh(messages)
        let settled = transcript.settledItems
        // A message near the end is replaced (an edit of the thread): only the items from it go.
        messages[messages.count - 3] = read("\(root)/edited.swift")
        transcript.update(messages, verify: true)
        #expect(transcript.lastWork.processed <= 10)
        #expect(transcript.settledItems >= settled - 2)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
        // A note put back at the start (a recovered queue): it starts over.
        messages.insert(ChatMessage(role: .note, text: "Recovered"), at: 0)
        transcript.update(messages, verify: true)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
        // A shorter thread.
        messages.removeLast(7)
        transcript.update(messages, verify: true)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
    }

    /// The chat shows a message being sent at the thread's end before the thread holds it (#355):
    /// its turn taking it in leaves the items as they are, and one taken away again (its queue
    /// couldn't be saved, or Stop) leaves the thread's own grouping, all without `verify`.
    @Test func aMessageShownAtTheEndThenTakenInOrAwayGroupsAsTheThread() {
        var messages: [ChatMessage] = [ChatMessage(role: .user, text: "Look around")]
        messages += (0..<6).map { exploring($0) }
        messages.append(ChatMessage(role: .assistant, text: "Done."))
        var transcript = fresh(messages)
        let sending = ChatMessage(role: .user, text: "And now?")
        transcript.update(messages + [sending])
        #expect(shown(transcript.items) == shown(fresh(messages + [sending]).items))
        // Taken in: the same message, now the thread's.
        let structure = transcript.structure
        transcript.update(messages + [sending])
        #expect(transcript.structure == structure)
        #expect(transcript.lastWork.processed == 0)
        // Taken away, after a group too.
        transcript.update(messages)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
        messages.removeLast()
        transcript.update(messages)
        transcript.update(messages + [sending])
        transcript.update(messages)
        #expect(shown(transcript.items) == shown(fresh(messages).items))
        // Taken in after a note the turn adds before it.
        let note = ChatMessage(role: .note, text: "New session on Claude")
        transcript.update(messages + [sending])
        transcript.update(messages + [note, sending])
        #expect(shown(transcript.items) == shown(fresh(messages + [note, sending]).items))
    }

    /// Random turns, written as the CLIs' parsers write them: calls starting, their input arriving,
    /// finishing out of order or failing, replies streaming, turns stopping; now and then an edit of
    /// the thread. After every change the transcript shows what grouping the thread afresh shows.
    @Test func randomTurnsMatchAFreshGrouping() {
        let folders = ["\(root)/macOS/Sources/BotChu/App", "\(root)/macOS/Sources/BotChu/Chat", "\(root)/macOS/Sources/BotChuCore",
                       "\(root)/docs", "/tmp/x/y"]
        for seed in 0..<160 {
            var random = Seeded(state: UInt64(seed))
            var messages: [ChatMessage] = []
            var transcript = ActivityTranscript(root: root)
            let start = Date(timeIntervalSinceReferenceDate: 1_000)
            var clock = 0.0
            func call(state: ChatMessage.ToolState, id: UUID = UUID()) -> ChatMessage {
                let folder = folders[Int.random(in: 0..<folders.count, using: &random)]
                let file = "\(folder)/F\(Int.random(in: 0..<6, using: &random)).swift"
                let failed = Int.random(in: 0..<6, using: &random) == 0
                let output = failed ? ["File does not exist.", "EACCES: permission denied"][Int.random(in: 0..<2, using: &random)] : "ok"
                let finalState = state == .running ? .running : failed ? .failed : state
                var message: ChatMessage
                switch Int.random(in: 0..<9, using: &random) {
                case 0, 1, 2:
                    let offset = [1, 31, 61, 200][Int.random(in: 0..<4, using: &random)]
                    message = read(file, offset: offset, limit: 30, output: output, state: finalState, id: id)
                case 3: message = tool("Grep", "x", arguments: ["pattern": "x", "path": folder], output: output, state: finalState, id: id)
                case 4: message = tool("Bash", "ls \(folder)", output: output, state: finalState, id: id)
                case 5: message = tool("Bash", "cat \(file)", output: output, state: finalState, id: id)
                case 6: message = tool("Bash", "swift build", output: output, state: finalState, id: id)
                case 7: message = tool("Edit", file, arguments: ["file_path": file, "old_string": "a", "new_string": "b"], state: finalState, id: id)
                default: message = tool("WebFetch", "https://example.com", arguments: ["url": "https://example.com"], output: output, state: finalState, id: id)
                }
                clock += 1
                message.date = start.addingTimeInterval(clock)
                if finalState != .running { message.toolDuration = Double(Int.random(in: 0..<5, using: &random)) }
                return message
            }
            for _ in 0..<70 {
                var verify = false
                let running = messages.indices.filter { messages[$0].toolState == .running }
                switch Int.random(in: 0..<20, using: &random) {
                case 0, 1:
                    messages.append(ChatMessage(role: [.user, .assistant, .note][Int.random(in: 0..<3, using: &random)], text: "Text"))
                case 2:
                    if messages.last?.role == .assistant { messages[messages.count - 1].text += " more" }
                case 3, 4, 5, 6, 7:
                    messages.append(call(state: .running))
                case 8, 9, 10:
                    messages.append(call(state: .done))
                case 11, 12, 13, 14:
                    // A running call finishes, in any order.
                    if let index = running.randomElement(using: &random) {
                        var done = call(state: .done, id: messages[index].id)
                        done.date = messages[index].date
                        messages[index] = done
                    }
                case 15, 16:
                    // A running call's input arrives, perhaps of another kind.
                    if let index = running.randomElement(using: &random) {
                        var again = call(state: .running, id: messages[index].id)
                        again.date = messages[index].date
                        messages[index] = again
                    }
                case 17:
                    ThreadAssembler.closeRunningTools(&messages)
                case 18:
                    // An edit of the thread: a finished call further back, rewritten.
                    if messages.count > 2, let index = messages.indices.dropLast().filter({ messages[$0].role == .tool }).randomElement(using: &random) {
                        var edited = call(state: .done, id: messages[index].id)
                        edited.date = messages[index].date
                        messages[index] = edited
                        verify = true
                    }
                default:
                    if !messages.isEmpty, Int.random(in: 0..<3, using: &random) == 0 {
                        messages.removeLast()
                        verify = true
                    }
                }
                transcript.update(messages, verify: verify)
                let expected = fresh(messages)
                #expect(shown(transcript.items) == shown(expected.items), "seed \(seed)")
                #expect(transcript.launches == expected.launches, "seed \(seed)")
                if shown(transcript.items) != shown(expected.items) { return }
            }
        }
    }

    @Test func settledGroupsLetGoOfTheirRunningState() {
        var messages = [ChatMessage(role: .user, text: "Go")] + (0..<300).map { exploring($0) }
        var transcript = fresh(messages)
        #expect(transcript.retained.groups == 1)
        messages.append(ChatMessage(role: .assistant, text: "Found it."))
        transcript.update(messages)
        #expect(transcript.settledItems == 2)
        #expect(transcript.retained == ActivityTranscript.Retained(watched: 1))
        guard case .exploration(let group) = transcript.items[1] else { Issue.record("no group"); return }
        // Every call's details are still there, from the messages.
        #expect(group.calls.count == 300)
        #expect(group.calls(of: group.entries[5]).first?.id == messages[6].id)
    }

    @Test func aLongThreadsNewestPartGroupsAsTheWholeDoes() throws {
        var messages: [ChatMessage] = []
        for turn in 0..<120 {
            messages.append(ChatMessage(role: .user, text: "Step \(turn)"))
            messages += (0..<8).map { exploring(turn * 10 + $0) }
            messages.append(tool("Bash", "swift build"))
            messages.append(ChatMessage(role: .assistant, text: "Done \(turn)"))
        }
        let start = try #require(ActivityTranscript.recentStart(in: messages, keeping: 300, scanning: 600))
        #expect(messages[start].role != .tool)
        #expect(messages.count - start >= 300)
        var recent = ActivityTranscript(root: root, skipping: start, of: messages)
        #expect(recent.backlog(messages) == messages.count - start)
        recent.update(messages)
        let whole = fresh(messages)
        #expect(shown(recent.items) == Array(shown(whole.items).suffix(recent.items.count)))
        // A reply streaming in meanwhile.
        messages.append(ChatMessage(role: .assistant, text: "More"))
        recent.update(messages)
        #expect(recent.lastExamined == 1)
        // The newest messages all tool calls of one group: nothing can be grouped apart from the rest.
        let calls = (0..<1_000).map { exploring($0) }
        #expect(ActivityTranscript.recentStart(in: [ChatMessage(role: .user, text: "Go")] + calls, keeping: 300, scanning: 600) == nil)
    }
}

@Suite struct SubagentCardsCacheTests {
    private func spawn(_ index: Int, printing id: UUID?, state: ChatMessage.ToolState = .done, date: Date, messageID: UUID = UUID()) -> ChatMessage {
        var message = tool("Bash", "botchu-subagent spawn --agent 'Helper \(index)' --title 'Area \(index)' --brief 'Look'",
                           output: id.map { $0.uuidString.lowercased() + "\n" } ?? "", state: state, date: date, id: messageID)
        if state != .running { message.toolDuration = 0.5 }
        return message
    }

    private func run(_ index: Int, id: UUID, created: Date, phase: SubagentPhase = .running) -> SubagentRun {
        SubagentRun(id: id, rootBotID: UUID(), depth: 1, targetBot: Bot(name: "Helper \(index)", workspace: "/tmp/helper"),
                    title: "Area \(index)", brief: "Look", workingDirectory: "/tmp", phase: phase, createdAt: created)
    }

    @Test func repliesStreamingInLeaveThePlacementAlone() {
        let start = Date().addingTimeInterval(-600)
        let ids = (0..<5).map { _ in UUID() }
        var messages = [ChatMessage(role: .user, text: "Fan out")]
        messages += ids.enumerated().map { spawn($0, printing: $1, date: start.addingTimeInterval(Double($0))) }
        messages.append(ChatMessage(role: .assistant, text: "Waiting"))
        var runs = ids.enumerated().map { run($0, id: $1, created: start.addingTimeInterval(Double($0) + 0.3)) }
        var transcript = fresh(messages)
        var cache = SubagentCardsCache()
        var cards = cache.cards(for: transcript, runs: runs)
        #expect(cache.rebuilds == 1)
        #expect(cards.runs(for: transcript.items[1]).map(\.id) == [ids[0]])
        for i in 0..<20 {
            messages[messages.count - 1].text += " token\(i)"
            transcript.update(messages)
            cards = cache.cards(for: transcript, runs: runs)
        }
        #expect(cache.rebuilds == 1)
        // A run's record changes (it finished): worked out again, once.
        runs[2].phase = .completed
        runs[2].finishedAt = Date()
        cards = cache.cards(for: transcript, runs: runs)
        cards = cache.cards(for: transcript, runs: runs)
        #expect(cache.rebuilds == 2)
        #expect(cards.runs(for: transcript.items[3]).first?.phase == .completed)
    }

    @Test func lateIdsAndRecordsAttachToTheirCallOnce() {
        let start = Date().addingTimeInterval(-600)
        let first = UUID(), second = UUID(), launch = UUID()
        // A spawn still running, whose id isn't printed yet, and no run recorded yet.
        var messages = [ChatMessage(role: .user, text: "Go"), spawn(0, printing: nil, state: .running, date: start, messageID: launch)]
        var transcript = fresh(messages)
        var cache = SubagentCardsCache()
        var runs: [SubagentRun] = []
        var cards = cache.cards(for: transcript, runs: runs)
        #expect(cards.runs(for: transcript.items[1]).isEmpty)
        // The run's record arrives: placed by time and agent.
        runs.append(run(0, id: first, created: start.addingTimeInterval(0.3)))
        cards = cache.cards(for: transcript, runs: runs)
        #expect(cards.runs(for: transcript.items[1]).map(\.id) == [first])
        #expect(cache.rebuilds == 2)
        // The call finishes, printing the id: still one card, for the same run.
        messages[1] = spawn(0, printing: first, date: start, messageID: launch)
        transcript.update(messages)
        cards = cache.cards(for: transcript, runs: runs)
        #expect(cards.runs(for: transcript.items[1]).map(\.id) == [first])
        #expect(cache.rebuilds == 3)
        // A run no call accounts for shows after the item before it, and moves with new items.
        runs.append(run(9, id: second, created: start.addingTimeInterval(100)))
        messages.append(ChatMessage(role: .assistant, text: "Later"))
        messages[2].date = start.addingTimeInterval(50)
        transcript.update(messages)
        cards = cache.cards(for: transcript, runs: runs)
        #expect(cards.unplaced(after: messages[2].id).map(\.id) == [second])
        let rebuilds = cache.rebuilds
        messages[2].text += " still"
        transcript.update(messages)
        _ = cache.cards(for: transcript, runs: runs)
        #expect(cache.rebuilds == rebuilds)
        messages.append(ChatMessage(role: .user, text: "Next", date: start.addingTimeInterval(60)))
        transcript.update(messages)
        cards = cache.cards(for: transcript, runs: runs)
        #expect(cache.rebuilds == rebuilds + 1)
        #expect(cards.unplaced(after: messages[3].id).map(\.id) == [second])
    }
}

@Suite struct ToolCallTallyTests {
    @Test func countsAsTheTranscriptStreamsWithoutRescanningIt() {
        var messages = [ChatMessage(role: .user, text: "Brief")] + (0..<2_000).map { exploring($0) }
        var tally = ToolCallTally()
        tally.update(messages)
        #expect(tally.counts == ToolCounts(messages: messages))
        #expect(tally.lastExamined == messages.count)
        // A reply streams in: only it is looked at.
        messages.append(ChatMessage(role: .assistant, text: "Looking"))
        tally.update(messages)
        messages[messages.count - 1].text += " more"
        tally.update(messages)
        #expect(tally.lastExamined == 0)
        // Calls start without a name, get one later, finish out of order.
        let a = UUID(), b = UUID()
        messages += [tool("", "", state: .running, id: a), tool("", "", state: .running, id: b)]
        tally.update(messages)
        messages[messages.count - 1].toolName = "Read"
        messages[messages.count - 2].toolName = "Bash"
        tally.update(messages)
        #expect(tally.lastExamined == 2)
        messages[messages.count - 2].toolState = .done
        messages.append(ChatMessage(role: .assistant, text: "Done"))
        tally.update(messages)
        #expect(tally.counts == ToolCounts(messages: messages))
        #expect(tally.counts.parts == ["\(tally.counts.tools) tool calls", "\(tally.counts.shell) shell"])
        // A transcript replaced by another is counted again.
        let replaced = [ChatMessage(role: .user, text: "Again"), tool("Bash", "ls")]
        tally.update(replaced)
        #expect(tally.counts == ToolCounts(tools: 1, shell: 1))
        #expect(ToolCounts().parts.isEmpty)
    }
}

@Suite struct ChunkedArrayTests {
    @Test func behavesAsAnArray() {
        var chunked = ChunkedArray<Int>()
        var array: [Int] = []
        var random = Seeded(state: 7)
        for _ in 0..<3_000 {
            switch Int.random(in: 0..<10, using: &random) {
            case 0 where !array.isEmpty:
                #expect(chunked.removeLast() == array.removeLast())
            case 1:
                let index = Int.random(in: 0...array.count, using: &random)
                chunked.removeSuffix(from: index)
                array.removeSubrange(index...)
            case 2 where !array.isEmpty:
                let index = Int.random(in: 0..<array.count, using: &random)
                chunked[index] = -index
                array[index] = -index
            default:
                let value = Int.random(in: 0..<1_000, using: &random)
                chunked.append(value)
                array.append(value)
            }
            #expect(Array(chunked) == array)
        }
        let copy = chunked
        chunked.append(1)
        #expect(copy.count == chunked.count - 1)
        #expect(ChunkedArray(array) == ChunkedArray(array))
    }
}
