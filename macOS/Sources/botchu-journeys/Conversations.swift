import AppKit
import BotChuCore

/// Journeys 4, 5, 6 and 12: a bot's conversations, typing and streaming.
extension Journeys {
    // MARK: 4. Switching task tabs

    /// Selects the first bot's tasks in the tabs beside its chat, each followed by its Home (the
    /// 5,000-message conversation), `repeats` times each, timed until the chat shows the tab's rows.
    func switchTasks() -> [JourneyResult] {
        var tasks: [Double] = [], home: [Double] = []
        var problem: String?
        do {
            let bot = fixture.longBot
            try show(bot)
            let ids = fixture.tasks(of: bot)
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
        let start = AppUnderTest.now
        try tab.press()
        let shown = try app.mark(FrameMarks.chat(task ?? bot.id), after: start)
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
            // Each streamer was still writing its reply after the typing ended.
            let log = FakeLog.read(app)
            let runs = log.filter { $0.time >= began && $0.text.hasPrefix("run ") && $0.text.contains(" -p") }.count
            let ended = log.filter { $0.time >= began && $0.time <= typed && $0.text == "end" }.count
            guard runs >= streamers.count, ended == 0 else {
                throw HarnessFailure("Of the \(streamers.count) streams, \(runs) started and \(ended) ended before the typing did "
                                     + String(format: "(%.1f s after it started)", Self.ms(typing, typed) / 1_000))
            }
            try app.requireBackground()
            // The streams end before the next journey.
            _ = try? FakeLog.waitFor(app, count: streamers.count, of: "end", after: began, timeout: Double(Self.typingStream) + 10)
            app.settle(quiet: 0.5)
        } catch {
            problem = "\(error)"
        }
        return [result(5, "echo while 4 stream (p95 of \(Self.typed.count) keys)", .instant, samples, problem: problem)]
    }

    static let typingStream = 12

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
            guard let end = try FakeLog.waitFor(app, count: 1, of: "end", after: start, timeout: Double(Self.streamSeconds) + 30).last else {
                throw HarnessFailure("The reply didn't end")
            }
            try awaitIdle()
            app.settle()
            let deltas = FakeLog.read(app).filter { $0.time >= start && $0.time <= end.time && $0.text.hasPrefix("delta ") }
                .compactMap { line in Int(line.text.dropFirst(6)).map { (time: line.time, length: $0) } }
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

    /// A bot delegates to a sub-agent run that streams for a while, shown in the status sidebar's
    /// Sub-agents, while the owner types in the bot's own message box: each repeat's sample is the
    /// p95 of its echoes.
    func typingWhileSubagentStreams() -> [JourneyResult] {
        let bot = fixture.bots[9]
        var samples: [Double] = []
        var problem: String?
        do {
            let began = AppUnderTest.now
            try send("Ask a sub-agent for a long reply. journey-subagent=\(Self.subagentStream)", to: bot)
            guard let tab = try app.window().first(identifier: "inspector-tab-subagents") else { throw HarnessFailure("The status sidebar has no Sub-agents tab") }
            try tab.press()
            let run = try waitFor("The sub-agent's run in the status sidebar", timeout: 20) {
                try app.window().first(where: { $0.identifier.hasPrefix("subagent-") && $0.identifier != "subagents-inspector" })
            }
            _ = try FakeLog.waitFor(app, count: 1, of: "delta", after: began, timeout: 20)
            let composer = try composer()
            try composer.set(kAXValueAttribute, to: "" as CFString)
            let typing = AppUnderTest.now
            for _ in 0..<repeats { samples.append(Self.p95(try type(Self.typed, into: composer))) }
            let typed = AppUnderTest.now
            let streamed = FakeLog.read(app).filter { $0.time >= typing && $0.time <= typed && $0.text.hasPrefix("delta ") }.count
            guard streamed > 0 else { throw HarnessFailure("The sub-agent wrote nothing while the owner typed") }
            guard try app.window().first(identifier: run.identifier) != nil else { throw HarnessFailure("The sub-agent's run left the status sidebar") }
            try composer.set(kAXValueAttribute, to: "" as CFString)
            if let activity = try app.window().first(identifier: "inspector-tab-activity") { try activity.press() }
            try app.requireBackground()
        } catch {
            problem = "\(error)"
        }
        return [result(12, "echo while a sub-agent streams (p95 of \(Self.typed.count) keys)", .instant, samples, problem: problem)]
    }

    static let subagentStream = 12
}

/// What the fake CLI logged (`FakeClaude`): `<uptime ns> <text>` lines.
enum FakeLog {
    struct Line {
        var time: UInt64
        var text: String
    }

    static func read(_ app: AppUnderTest) -> [Line] {
        guard let path = app.environment["BOTCHU_JOURNEY_FAKE_LOG"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " "), let time = UInt64(line[..<space]) else { return nil }
            return Line(time: time, text: String(line[line.index(after: space)...]))
        }
    }

    /// Waits until `count` lines starting with `prefix` were logged after `start`.
    @discardableResult
    static func waitFor(_ app: AppUnderTest, count: Int, of prefix: String, after start: UInt64, timeout: TimeInterval) throws -> [Line] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = read(app).filter { $0.time >= start && $0.text.hasPrefix(prefix) }
            if found.count >= count { return found }
            guard Date() < deadline else { throw HarnessFailure("The fake CLI logged \(found.count) of \(count) \"\(prefix)\" within \(Int(timeout)) s") }
            usleep(50_000)
        }
    }
}
