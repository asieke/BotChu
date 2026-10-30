import AppKit
import BotChuCore

/// Journeys 4, 5, 6 and 12: a bot's conversations, typing and streaming.
extension Journeys {
    // MARK: 4. Switching task tabs

    /// Selects the first bot's tasks in the tabs beside its chat, each followed by its Home (the
    /// 5,000-message conversation), `repeats` times each, timed until the chat shows the tab's rows.
    /// A first round isn't counted: going back to Home the first time after a launch shows it, but
    /// SwiftUI doesn't tell its rows they appeared, so no mark comes.
    func switchTasks() -> [JourneyResult] {
        var tasks: [Double] = [], home: [Double] = []
        var problem: String?
        do {
            let bot = fixture.longBot
            try show(bot)
            let ids = fixture.tasks(of: bot)
            if let first = try app.window().first(identifier: "conversation-tab-\(ids[ids.count - 1].uuidString)"),
               let homeTab = try app.window().first(identifier: "conversation-tab-home") {
                _ = try press(first)
                app.settle()
                _ = try press(homeTab)
                app.settle()
            }
            for index in 0..<repeats {
                tasks.append(try selectTab(ids[index % ids.count], of: bot))
                home.append(try selectTab(nil, of: bot))
            }
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(4, "switch task", .within(50), tasks, problem: problem),
                result(4, "switch to Home (5,000 messages)", .within(50), home, problem: problem)]
    }

    /// Presses a task's tab, or Home's; the time until its chat shows a row, then checks its latest
    /// message shows.
    private func selectTab(_ task: UUID?, of bot: Bot) throws -> Double {
        let identifier = task.map { "conversation-tab-\($0.uuidString)" } ?? "conversation-tab-home"
        guard let tab = try app.window().first(identifier: identifier) else { throw HarnessFailure("The column beside the chat has no \(identifier)") }
        let (start, shown) = try press(tab, until: FrameMarks.chat(task ?? bot.id))
        app.settle()
        guard let last = fixture.lastItem[task ?? bot.id], try app.window().first(identifier: "chat-item-\(last.uuidString)") != nil else {
            throw HarnessFailure("After its tab was pressed, the chat doesn't show \(task.map { "task \($0.uuidString)" } ?? "Home")'s latest message")
        }
        return Self.ms(start, shown.nanoseconds)
    }

    // MARK: 5. Typing while four conversations stream

    static let typed = "Journeys type here "

    /// Four other bots stream long replies while the owner types in the first bot's message box:
    /// each repeat types a few words a character at a time; its sample is the p95 of their echoes.
    /// The words stay in the box as a draft, which journey 13 expects after a relaunch.
    func typingWhileStreaming() -> [JourneyResult] {
        var samples: [Double] = []
        var problem: String?
        do {
            let began = AppUnderTest.now
            let streamers = Array(fixture.bots[2...5])
            for bot in streamers { try send("Write a long reply. journey-stream=\(Self.typingStream)", to: bot) }
            let started = FakeLog.streaming(try FakeLog.waitFor(app, "\(streamers.count) streams", after: began, timeout: 20) {
                FakeLog.streaming($0).count >= streamers.count
            })
            let bot = fixture.longBot
            try show(bot)
            let composer = try composer()
            try composer.set(kAXValueAttribute, to: "" as CFString)
            let typing = AppUnderTest.now
            for _ in 0..<repeats { samples.append(Self.p95(try type(Self.typed, into: composer))) }
            let typed = AppUnderTest.now
            let expected = String(repeating: Self.typed, count: repeats)
            guard composer.text == expected else { throw HarnessFailure("The message box says \"\(composer.text.prefix(80))\", not what was typed") }
            left.draft = (bot, expected)
            // Each stream was still going when the typing ended.
            let ended = FakeLog.ended(FakeLog.read(app).filter { $0.time >= began && $0.time <= typed }).intersection(started)
            guard ended.isEmpty else {
                throw HarnessFailure("\(ended.count) of the \(streamers.count) streams ended before the typing did "
                                     + String(format: "(%.1f s after it started)", Self.ms(typing, typed) / 1_000))
            }
            try app.requireBackground()
            // The streams end before the next journey.
            _ = try? FakeLog.waitFor(app, "the streams' ends", after: began, timeout: Double(Self.typingStream) + 15) {
                FakeLog.ended($0).isSuperset(of: started)
            }
            app.settle(quiet: 0.5)
        } catch {
            problem = "\(error)"
        }
        return [result(5, "echo while 4 stream (p95 of \(Self.typed.count) keys)", .instant, samples, problem: problem)]
    }

    static let typingStream = 6

    // MARK: 6. Sending, and a streamed reply

    /// Sends `repeats` messages that the fake CLI answers at once, timed until each shows in the
    /// chat; then one it answers for 30 s, a chunk every 30 ms: each chunk timed from when the CLI
    /// wrote it until the chat showed it, and the main thread's longest busy stretch, both per 5 s,
    /// with the working ring in the status sidebar still turning.
    func sendAndStream() -> [JourneyResult] {
        let bot = fixture.bots[6]
        var shown: [Double] = [], chunks: [Double] = [], frames: [Double] = []
        var problem: String?
        do {
            for index in 0..<repeats {
                shown.append(try send("Quick question \(index + 1). journey-stream=0", to: bot))
                try awaitIdle()
                app.settle()
            }
            let text = "Tell me about lighthouses at length. journey-stream=\(Self.streamSeconds)"
            let start = AppUnderTest.now
            try send(text, to: bot)
            left.sent = (bot, text)
            let lines = try FakeLog.waitFor(app, "the reply's end", after: start, timeout: Double(Self.streamSeconds) + 30) { lines in
                lines.contains { $0.words.first == "end" && FakeLog.streaming(lines).contains($0.pid ?? 0) }
            }
            try awaitIdle()
            app.settle()
            let deltas = lines.compactMap { line in line.length.map { (time: line.time, length: $0) } }
            guard let first = deltas.first, let last = deltas.last else { throw HarnessFailure("The fake CLI wrote no chunks") }
            let shownLengths = app.marks(from: start).compactMap { mark in
                FrameMarks.streamedLength(mark.name, of: bot.id).map { (time: mark.nanoseconds, length: $0) }
            }
            let window = (last.time - first.time) / UInt64(Self.streamWindows)
            var ring: [Int] = []
            for n in 0..<Self.streamWindows {
                let from = first.time + UInt64(n) * window, to = n == Self.streamWindows - 1 ? last.time : from + window
                let latencies = deltas.filter { $0.time >= from && $0.time < to }.map { delta in
                    shownLengths.first(where: { $0.length >= delta.length && $0.time >= delta.time }).map { Self.ms(delta.time, $0.time) } ?? .infinity
                }
                chunks.append(latencies.max() ?? .infinity)
                frames.append(app.longestBusy(from: from, to: to))
                ring.append(app.marks(from: from, to: to).count(where: { $0.name == FrameMarks.avatarFrame }))
            }
            if let missing = chunks.firstIndex(of: .infinity) {
                throw HarnessFailure("The chat never showed a chunk the CLI wrote in the stream's part \(missing + 1)")
            }
            // At least 5 of the ring's 30 frames a second in every part.
            let seconds = Double(window) / 1_000_000_000
            if ring.contains(where: { Double($0) < 5 * seconds }) {
                throw HarnessFailure("The working ring stopped turning while the reply streamed (frames per part: \(ring.map(String.init).joined(separator: ", ")))")
            }
            print("journeys: 6 stream: \(deltas.count) chunks over \(String(format: "%.1f", Self.ms(first.time, last.time) / 1_000)) s; ring frames per part \(ring.map(String.init).joined(separator: ", "))")
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(6, "message shows", .instant, shown, problem: problem),
                result(6, "chunk shows (worst per 5 s)", .within(50), chunks, problem: problem),
                result(6, "longest frame while streaming (per 5 s)", .smooth, frames, problem: problem)]
    }

    static let streamSeconds = 30
    static let streamWindows = 6

    // MARK: 12. Typing while a sub-agent streams

    /// A bot delegates to a sub-agent run that streams a working transcript for a while (`subagentTools`
    /// tool calls first, more as it goes), shown in the status sidebar's Sub-agents, while the owner
    /// types in the bot's own message box: first with the list of runs shown, then with the run's
    /// details and their open Transcript. Each repeat's sample is the p95 of its echoes.
    func typingWhileSubagentStreams() -> [JourneyResult] {
        let bot = fixture.bots[9]
        var list: [Double] = [], transcript: [Double] = []
        var listProblem: String?, transcriptProblem: String?
        let began = AppUnderTest.now
        func running() throws -> Bool {
            try app.window().first(identifier: "inspector-tab-subagents")?.label.hasSuffix("1 running") == true
        }
        func row() throws -> AXElement? {
            guard try running() else { return nil }
            return try app.window().first { $0.role == kAXButtonRole as String && $0.label.hasPrefix("Journey sub-agent, \(bot.name)") }
        }
        do {
            try send("Ask a sub-agent for a long reply. journey-subagent=\(Self.subagentStream) journey-tools=\(Self.subagentTools)", to: bot)
            guard let tab = try app.window().first(identifier: "inspector-tab-subagents") else { throw HarnessFailure("The status sidebar has no Sub-agents tab") }
            try tab.press()
            try FakeLog.waitFor(app, "the sub-agent's stream", after: began, timeout: 20) { !FakeLog.streaming($0).isEmpty }
            app.settle(quiet: 0.2, limit: 2)
            guard try row() != nil else { throw HarnessFailure("The status sidebar's Sub-agents doesn't show the sub-agent running") }
            let composer = try composer()
            try composer.set(kAXValueAttribute, to: "" as CFString)
            let typing = AppUnderTest.now
            for _ in 0..<repeats { list.append(Self.p95(try type(Self.typed, into: composer))) }
            try checkStreamed(since: typing, running: try row() != nil)
        } catch {
            listProblem = "\(error)"
        }
        // Then the run's details, its Transcript open while it runs, on a long transcript.
        do {
            if let listProblem { throw HarnessFailure(listProblem) }
            guard let run = try row() else { throw HarnessFailure("The status sidebar's Sub-agents doesn't show the sub-agent running") }
            try run.press()
            let header: AXElement
            do {
                header = try waitFor("The sub-agent's Transcript") { try transcriptHeader() }
            } catch {
                // What the details show instead, for whoever reads the log.
                var lines: [String] = [], top = try app.window().first(identifier: "subagents-inspector")
                for _ in 0..<4 { top = top?.parent ?? top }
                top?.dump(maxDepth: 9, into: &lines)
                print("journeys: the Sub-agents tab shows:\n" + lines.prefix(200).joined(separator: "\n"))
                throw error
            }
            print("journeys: the sub-agent's Transcript: \(header)")
            guard Self.isExpanded(header) else { throw HarnessFailure("The sub-agent's Transcript (\(header)) isn't open while it runs") }
            app.settle(quiet: 0.2, limit: 2)
            let composer = try composer()
            let typing = AppUnderTest.now
            for _ in 0..<repeats { transcript.append(Self.p95(try type(Self.typed, into: composer))) }
            try checkStreamed(since: typing, running: try running())
        } catch {
            transcriptProblem = "\(error)"
        }
        do {
            try composer().set(kAXValueAttribute, to: "" as CFString)
            if let back = try button("Back to Sub-agents") { try back.press() }
            if let activity = try app.window().first(identifier: "inspector-tab-activity") { try activity.press() }
            try app.requireBackground()
        } catch {
            listProblem = listProblem ?? "\(error)"
            transcriptProblem = transcriptProblem ?? "\(error)"
        }
        // The run ends before the next journey, or this one's second attempt.
        _ = try? FakeLog.waitFor(app, "the sub-agent's end", after: began, timeout: Double(Self.subagentStream) + 15) { lines in
            let streamed = FakeLog.streaming(lines)
            return !streamed.isEmpty && FakeLog.ended(lines).isSuperset(of: streamed)
        }
        app.settle(quiet: 0.5)
        return [result(12, "echo while a sub-agent streams (p95 of \(Self.typed.count) keys)", .instant, list, problem: listProblem),
                result(12, "echo with its Transcript open on \(Self.subagentTools)+ items (p95 of \(Self.typed.count) keys)", .instant,
                       transcript, problem: transcriptProblem)]
    }

    /// The run's Transcript heading, which says whether it's open: the element its title names,
    /// or the one around its title's text (a disclosure's heading needn't be a button).
    private func transcriptHeader() throws -> AXElement? {
        let title = try app.window().first { element in
            [element.label, element.title, element.text].contains { $0.lowercased().hasPrefix("transcript") }
        }
        guard let title else { return nil }
        if title.role != kAXStaticTextRole as String { return title }
        return title.ancestor { $0.role != kAXStaticTextRole as String && $0.role != kAXGroupRole as String } ?? title
    }

    /// Whether a disclosure's heading says it's open: in its value, as a word or a number, or as expanded.
    static func isExpanded(_ element: AXElement) -> Bool {
        let value = element.value(kAXValueAttribute)
        return (value as? String) == "Expanded" || (value as? NSNumber)?.boolValue == true
            || (element.value(kAXExpandedAttribute) as? Bool) == true
    }

    /// The sub-agent wrote while the owner typed, and still shows running.
    private func checkStreamed(since typing: UInt64, running: Bool) throws {
        let typed = AppUnderTest.now
        let streamed = FakeLog.read(app).filter { $0.time >= typing && $0.time <= typed && $0.length != nil }.count
        guard streamed > 0 else { throw HarnessFailure("The sub-agent wrote nothing while the owner typed") }
        guard running else { throw HarnessFailure("The sub-agent stopped running in the status sidebar while the owner typed") }
    }

    /// Long enough for both rounds of typing.
    static let subagentStream = 30
    /// More than the Sub-agents tab lists at once (#361).
    static let subagentTools = 160
}

/// What the fake CLI logged (`FakeClaude`): `<uptime ns> <text>` lines.
enum FakeLog {
    struct Line {
        var time: UInt64
        var text: String

        var words: [Substring] { text.split(separator: " ") }
        /// The process a `run`, `delta` or `end` line is about.
        var pid: Int32? {
            switch words.first {
            case "run", "end": words.count > 1 ? Int32(words[1]) : nil
            case "delta": words.count > 2 ? Int32(words[2]) : nil
            default: nil
            }
        }
        /// A `delta` line's reply length.
        var length: Int? { words.first == "delta" && words.count > 1 ? Int(words[1]) : nil }
        /// A turn's run (`-p`), not a probe of the CLI.
        var isTurn: Bool { words.first == "run" && text.contains(" -p ") }
    }

    static func read(_ app: AppUnderTest) -> [Line] {
        guard let path = app.environment["BOTCHU_JOURNEY_FAKE_LOG"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " "), let time = UInt64(line[..<space]) else { return nil }
            return Line(time: time, text: String(line[line.index(after: space)...]))
        }
    }

    /// Waits until `find` finds what it wants in what was logged after `start`.
    @discardableResult
    static func waitFor(_ app: AppUnderTest, _ what: String, after start: UInt64, timeout: TimeInterval, _ find: ([Line]) -> Bool) throws -> [Line] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let lines = read(app).filter { $0.time >= start }
            if find(lines) { return lines }
            guard Date() < deadline else { throw HarnessFailure("The fake CLI didn't log \(what) within \(Int(timeout)) s") }
            usleep(50_000)
        }
    }

    /// The processes that wrote reply chunks after `start`.
    static func streaming(_ lines: [Line]) -> Set<Int32> { Set(lines.filter { $0.length != nil }.compactMap(\.pid)) }

    /// The processes that ended their turn.
    static func ended(_ lines: [Line]) -> Set<Int32> { Set(lines.filter { $0.words.first == "end" }.compactMap(\.pid)) }
}
