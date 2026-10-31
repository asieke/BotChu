import Foundation
import Testing
@testable import BotChuCore

/// A Project Area's turns fold their work before the reply into one row (#425).
private let root = "/work/BotChu"
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

private func tool(_ name: String, _ input: String, arguments: [String: Any]? = nil, state: ChatMessage.ToolState = .done,
                  date: Date, duration: Double? = nil) -> ChatMessage {
    let id = UUID()
    var message = ChatMessage(id: id, role: .tool, date: date, toolID: id.uuidString, toolName: name, toolInput: input,
                              toolOutput: state == .running ? nil : "ok", toolState: state,
                              toolArguments: arguments.flatMap { ToolArguments.digest($0) })
    message.toolDuration = duration
    return message
}

private func command(_ line: String, state: ChatMessage.ToolState = .done, date: Date) -> ChatMessage {
    tool("Bash", line, arguments: ["command": line], state: state, date: date, duration: state == .running ? nil : 2)
}

private func edit(_ file: String, date: Date) -> ChatMessage {
    tool("Edit", "\(root)/\(file)", arguments: ["file_path": "\(root)/\(file)", "old_string": "a", "new_string": "b"], date: date)
}

private func read(_ file: String, date: Date) -> ChatMessage {
    tool("Read", "\(root)/\(file)", arguments: ["file_path": "\(root)/\(file)"], date: date)
}

private func say(_ role: ChatMessage.Role, _ text: String, _ date: Date, by speaker: UUID? = nil) -> ChatMessage {
    var message = ChatMessage(role: role, text: text, date: date)
    message.speakerBotID = speaker
    return message
}

private func transcript(_ messages: [ChatMessage]) -> ActivityTranscript {
    var transcript = ActivityTranscript(root: root)
    transcript.update(messages)
    return transcript
}

/// What a folded item shows, to compare two foldings.
private func shown(_ items: ChunkedArray<ActivityItem>) -> [String] {
    items.map { item in
        switch item {
        case .message(let message): "message \(message.id) \(message.text)"
        case .tool(let tool): "tool \(tool.id) \(tool.state)"
        case .exploration(let group): "group \(group.id) \(group.revision)"
        case .work(let work): "work \(work.id) open \(work.isOpen) running \(work.running) \(work.items.map(\.id)) \(work.headline) \(work.lastAction)"
        }
    }
}

/// The owner's request, then three interim messages and six calls (a command and an edit after
/// each), then the reply.
private func turn(from base: Double = 0, reply: Bool = true) -> [ChatMessage] {
    var messages = [say(.user, "Fix the build.", at(base))]
    for step in 0..<3 {
        let t = base + 10 + Double(step) * 30
        messages.append(say(.assistant, "I'll check part \(step) first.\nThen the rest.", at(t)))
        messages.append(command("swift build --package-path macOS", date: at(t + 5)))
        messages.append(edit("Sources/Part\(step).swift", date: at(t + 10)))
    }
    if reply { messages.append(say(.assistant, "**Fixed.** The build passes.", at(base + 130))) }
    return messages
}

@Suite struct WorkFoldingTests {
    @Test func aTurnsWorkFoldsIntoOneRowBeforeItsReplyWithEveryItemInOrder() throws {
        let messages = turn()
        let items = WorkFolding.fold(transcript(messages).items)
        #expect(items.count == 3)
        guard case .message(let request) = items[0], case .work(let work) = items[1], case .message(let reply) = items[2] else {
            Issue.record("Not a request, a work row and a reply: \(shown(items))")
            return
        }
        #expect(request.role == .user && reply.text.hasPrefix("**Fixed.**"))
        // Opened, it shows all nine items, as they came.
        #expect(work.items.count == 9)
        #expect(work.items.map(\.id) == messages[1...9].map(\.id))
        #expect(work.id == messages[1].id)
        // Worked from the first interim message until the reply began.
        #expect(work.started == at(10) && work.finished == at(130))
        #expect(work.counts.files == 3 && work.counts.commands == 3 && work.counts.messages == 3 && work.counts.calls == 6)
        #expect(work.headline == "Worked 2 min · 3 files · 3 commands")
        #expect(!work.running)
    }

    @Test func aRunningTurnsRowIsOpenWithItsLiveLastAction() throws {
        var messages = turn(reply: false)
        messages.append(command("swift test --package-path macOS", state: .running, date: at(110)))
        let items = WorkFolding.fold(transcript(messages).items)
        #expect(items.count == 2)
        guard case .work(let work) = items.last else { Issue.record("No work row last: \(shown(items))"); return }
        #expect(work.isOpen && work.running)
        #expect(work.items.count == 10)
        #expect(work.lastAction == "Running swift test --package-path macOS")
        // An interim message streaming after the calls shows in full until a call follows it.
        messages[messages.count - 1] = command("swift test --package-path macOS", date: at(110))
        messages.append(say(.assistant, "Tests pass; one more look.", at(120)))
        let streaming = WorkFolding.fold(transcript(messages).items)
        guard case .work(let before) = streaming[1], case .message(let last) = streaming[2] else { Issue.record("\(shown(streaming))"); return }
        #expect(before.isOpen && !before.running && last.text.hasPrefix("Tests pass"))
        messages.append(read("README.md", date: at(125)))
        let folded = WorkFolding.fold(transcript(messages).items)
        #expect(folded.count == 2)
        guard case .work(let after) = folded[1] else { Issue.record("\(shown(folded))"); return }
        #expect(after.id == before.id && after.items.count == 12 && after.lastAction == "Read README.md")
    }

    @Test func aReplyAloneStaysAsItIsAndEachTurnFoldsApart() {
        let quick = [say(.user, "Hi", at(0)), say(.assistant, "Hello.", at(1))]
        #expect(shown(WorkFolding.fold(transcript(quick).items)) == shown(transcript(quick).items))
        let two = turn() + turn(from: 200)
        let items = WorkFolding.fold(transcript(two).items)
        #expect(items.map { if case .work = $0 { "work" } else { "message" } } == ["message", "work", "message", "message", "work", "message"])
        // A turn that ended without a reply folds whole, closed once the owner writes again.
        let stopped = turn(reply: false) + [say(.note, "Stopped", at(140)), say(.user, "Go on", at(150))]
        let folded = WorkFolding.fold(transcript(stopped).items)
        guard case .work(let work) = folded[1] else { Issue.record("\(shown(folded))"); return }
        #expect(work.items.count == 9 && !work.isOpen && folded.count == 4)
    }

    @Test func subagentCallsStayRowsOfTheirOwnAndCameoTurnsFoldApart() {
        let cameo = UUID()
        let messages = [say(.user, "Ship #12", at(0)),
                        say(.assistant, "Handing it off.", at(1)),
                        command("botchu-subagent spawn --agent 'Helper' --title '#12' --brief 'Fix it'", date: at(2)),
                        command("swift build --package-path macOS", date: at(3)),
                        say(.assistant, "Started.", at(4)),
                        say(.assistant, "Looking.", at(5), by: cameo),
                        command("swift build --package-path macOS", date: at(6)).withSpeaker(cameo),
                        say(.assistant, "Looks fine.", at(7), by: cameo)]
        let items = WorkFolding.fold(transcript(messages).items)
        let kinds = items.map { item -> String in
            switch item {
            case .message(let message): "\(message.speakerBotID == nil ? "" : "cameo ")\(message.text)"
            case .tool(let tool): "tool \(tool.activity.intent)"
            case .exploration: "group"
            case .work(let work): "\(work.items.first?.speaker == nil ? "" : "cameo ")work \(work.items.count)"
            }
        }
        #expect(kinds == ["Ship #12", "work 1", "tool subagent", "work 1", "Started.", "cameo work 2", "cameo Looks fine."])
    }

    /// Folding as the transcript grows shows what folding it afresh shows, and folds again only the
    /// turn still going, not the settled turns before it.
    @Test func foldingAsTheThreadGrowsMatchesFoldingAfreshAndLeavesSettledTurnsAlone() {
        var messages: [ChatMessage] = []
        for n in 0..<40 { messages += turn(from: Double(n) * 200) }
        var live = ActivityTranscript(root: root)
        var folding = WorkFolding()
        live.update(messages)
        #expect(shown(folding.fold(live)) == shown(WorkFolding.fold(live.items)))
        let base = Double(40) * 200
        var steps: [(inout [ChatMessage]) -> Void] = [
            { $0.append(say(.user, "One more thing.", at(base))) },
            { $0.append(say(.assistant, "I'll look", at(base + 1))) },
            { $0[$0.count - 1].text += " at the tests." },
            { $0.append(command("swift test", state: .running, date: at(base + 2))) },
            { $0[$0.count - 1] = command("swift test", date: at(base + 2)).withID($0[$0.count - 1].id) },
            { $0.append(read("README.md", date: at(base + 5))) },
            { $0.append(read("AGENTS.md", date: at(base + 6))) },
            { $0.append(say(.assistant, "All", at(base + 7))) },
            { $0[$0.count - 1].text += " green." },
        ]
        steps.append { $0.append(say(.user, "Thanks", at(base + 9))) }
        for step in steps {
            step(&messages)
            live.update(messages)
            let folded = folding.fold(live)
            #expect(shown(folded) == shown(WorkFolding.fold(transcript(messages).items)))
            // The turn going on, and the one before it until the owner's message after it settles: not the 440 items before.
            #expect(folding.lastExamined <= 24, "Folded \(folding.lastExamined) items again")
        }
        // A thread edited (regrouped from the start) folds afresh.
        messages.removeFirst(2)
        live.update(messages, verify: true)
        #expect(shown(folding.fold(live)) == shown(WorkFolding.fold(transcript(messages).items)))
    }

    @Test func durationsReadAsMinutesAndHours() {
        #expect(TurnWork.duration(0) == "0 s")
        #expect(TurnWork.duration(42.4) == "42 s")
        #expect(TurnWork.duration(150) == "2 min")
        #expect(TurnWork.duration(3_600) == "1 h")
        #expect(TurnWork.duration(3_900) == "1 h 5 min")
    }
}

private extension ChatMessage {
    func withSpeaker(_ speaker: UUID) -> ChatMessage {
        var message = self
        message.speakerBotID = speaker
        return message
    }

    func withID(_ id: UUID) -> ChatMessage {
        ChatMessage(id: id, role: role, date: date, toolID: toolID, toolName: toolName, toolInput: toolInput, toolOutput: toolOutput,
                    toolState: toolState, toolArguments: toolArguments)
    }
}
