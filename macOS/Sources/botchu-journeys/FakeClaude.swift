import Foundation

/// The fixture's Claude Code CLI (`botchu-journeys fake-claude`, through the profile's wrapper
/// script): every `-p` turn replays the captured stream (`ClaudeStream`) under the session it was
/// asked to resume, or a new one, a line every `BOTCHU_JOURNEY_FAKE_INTERVAL` milliseconds (30 by
/// default, about the captured pace); anything else exits at once with no output. With
/// `BOTCHU_JOURNEY_FAKE_LOG`, it appends each invocation (`run <pid> <arguments>`), when it wrote
/// each line (`<uptime ns> <line index>`) and when the turn ended (`end <pid>`), so a journey can
/// time a chunk from when the CLI wrote it.
///
/// A journey steers a turn with words in its message (`Directive`): `journey-stream=<seconds>`
/// replays the reply's text over and over for that long (`0`: the captured reply at once), logging
/// each text chunk as `<uptime ns> delta <reply length in UTF-16 units> <pid>`; `journey-subagent=<seconds>`
/// first starts a sub-agent run of the same bot through BotChu's `botchu-subagent`, told to stream
/// for that long, and waits for it, as a bot that delegates does.
enum FakeClaude {
    struct Directive: Equatable {
        var stream: Double?
        var subagent: Double?

        init(_ text: String) {
            func seconds(_ key: String) -> Double? {
                guard let range = text.range(of: key + "=") else { return nil }
                return Double(text[range.upperBound...].prefix(while: { $0.isNumber || $0 == "." }))
            }
            stream = seconds("journey-stream")
            subagent = seconds("journey-subagent")
        }
    }

    static func run(_ arguments: [String]) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let log = environment["BOTCHU_JOURNEY_FAKE_LOG"].flatMap { path -> FileHandle? in
            let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        func record(_ line: String) { try? log?.write(contentsOf: Data((line + "\n").utf8)) }
        record("\(DispatchTime.now().uptimeNanoseconds) run \(getpid()) \(arguments.joined(separator: " ").prefix(300))")
        guard arguments.contains("-p") || arguments.contains("--print") else { return 0 }
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let session = value(after: "--resume") ?? value(after: "--session-id") ?? UUID().uuidString.lowercased()
        var interval = environment["BOTCHU_JOURNEY_FAKE_INTERVAL"].flatMap(Double.init) ?? 30
        // With live input, the turn starts on the first message written to stdin, echoed as Claude Code
        // echoes it with `--replay-user-messages`.
        var message = arguments.joined(separator: " ")
        if value(after: "--input-format") == "stream-json", let line = readLine(), !line.isEmpty {
            message = line
            if arguments.contains("--replay-user-messages") { write(echo(line, session: session)) }
        }
        let directive = Directive(message)
        if let seconds = directive.subagent { delegate(streaming: seconds, record: record) }
        if directive.stream == 0 { interval = 0 }
        if let seconds = directive.stream, seconds > 0 {
            stream(for: seconds, interval: interval, session: session, record: record)
            return 0
        }
        for (index, line) in ClaudeStream.turn.enumerated() {
            write(line.replacingOccurrences(of: ClaudeStream.session, with: session))
            record("\(DispatchTime.now().uptimeNanoseconds) \(index)")
            if index < ClaudeStream.turn.count - 1, interval > 0 { usleep(useconds_t(interval * 1_000)) }
        }
        record("\(DispatchTime.now().uptimeNanoseconds) end \(getpid())")
        return 0
    }

    /// The captured turn with its text chunks replayed, a paragraph after another, until `seconds`
    /// have gone; the full message and the result then carry all of it.
    private static func stream(for seconds: Double, interval: Double, session: String, record: (String) -> Void) {
        let lines = ClaudeStream.turn.map { $0.replacingOccurrences(of: ClaudeStream.session, with: session) }
        let deltas = lines.indices.filter { lines[$0].contains(#""type":"text_delta""#) }
        guard let first = deltas.first, let last = deltas.last else { return }
        for line in lines[..<first] { write(line) }
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        var text = "", cycle = 0
        while DispatchTime.now().uptimeNanoseconds < end {
            for (n, index) in deltas.enumerated() {
                var line = lines[index]
                var chunk = ClaudeStream.text(of: line) ?? ""
                if cycle > 0, n == 0 {
                    chunk = "\n\n" + chunk
                    line = ClaudeStream.replacingText(of: line, with: chunk) ?? line
                }
                write(line)
                text += chunk
                // As the chat shows it: without the whitespace it ends with so far.
                let shown = text.utf16.count - text.reversed().prefix(while: \.isWhitespace).reduce(0) { $0 + $1.utf16.count }
                record("\(DispatchTime.now().uptimeNanoseconds) delta \(shown) \(getpid())")
                usleep(useconds_t(max(interval, 1) * 1_000))
                if DispatchTime.now().uptimeNanoseconds >= end { break }
            }
            cycle += 1
        }
        for line in lines[(last + 1)...] {
            write(ClaudeStream.replacingText(of: line, with: text) ?? line)
        }
        record("\(DispatchTime.now().uptimeNanoseconds) end \(getpid())")
    }

    /// Starts a sub-agent run of this bot that streams for `seconds`, and waits for its handoff.
    private static func delegate(streaming seconds: Double, record: (String) -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard let bin = environment["BOTCHU_BIN_DIR"], let bot = environment["BOTCHU_CALLER_BOT_ID"] else {
            record("\(DispatchTime.now().uptimeNanoseconds) subagent unavailable")
            return
        }
        let tool = (bin as NSString).appendingPathComponent("botchu-subagent")
        let spawned = run(tool, ["spawn", "--agent", bot, "--title", "Journey sub-agent",
                                 "--brief", "Stream a long reply. journey-stream=\(Int(seconds))"])
        let id = spawned.trimmingCharacters(in: .whitespacesAndNewlines)
        record("\(DispatchTime.now().uptimeNanoseconds) subagent \(id.isEmpty ? "failed" : id)")
        if !id.isEmpty { _ = run(tool, ["wait", id]) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return process.terminationStatus == 0 ? output : ""
    }

    private static func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// The owner's message as Claude Code replays it: as written, with the session it went to.
    private static func echo(_ line: String, session: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return line }
        object["session_id"] = session
        object["parent_tool_use_id"] = NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return line }
        return String(decoding: data, as: UTF8.self)
    }

    /// The wrapper the profile runs (BotChu runs a profile's command through a login shell). BotChu
    /// leaves its own `BOTCHU_` variables out of a CLI's environment, so the log's path is set here.
    static func writeWrapper(at url: URL, harness: String, log: URL) throws {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try "#!/bin/sh\nBOTCHU_JOURNEY_FAKE_LOG=\(quoted(log.path)) exec \(quoted(harness)) fake-claude \"$@\"\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

extension ClaudeStream {
    /// A text chunk's text.
    static func text(of line: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let event = object["event"] as? [String: Any], let delta = event["delta"] as? [String: Any] else { return nil }
        return delta["text"] as? String
    }

    /// The line with its text replaced: a text chunk's, the full message's or the result's; nil for
    /// a line without text.
    static func replacingText(of line: String, with text: String) -> String? {
        guard var object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        if var event = object["event"] as? [String: Any], var delta = event["delta"] as? [String: Any], delta["text"] != nil {
            delta["text"] = text
            event["delta"] = delta
            object["event"] = event
        } else if var message = object["message"] as? [String: Any], var content = message["content"] as? [[String: Any]],
                  let index = content.firstIndex(where: { $0["type"] as? String == "text" }) {
            content[index]["text"] = text
            message["content"] = content
            object["message"] = message
        } else if object["result"] is String {
            object["result"] = text
        } else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The UTF-16 length of the reply after each text chunk of the captured turn.
    static var replyLengths: [Int] {
        var length = 0
        return turn.compactMap { text(of: $0) }.map { length += $0.utf16.count; return length }
    }
}
