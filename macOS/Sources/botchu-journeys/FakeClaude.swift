import Foundation

/// The fixture's Claude Code CLI (`botchu-journeys fake-claude`, through the profile's wrapper
/// script): every `-p` turn replays the captured stream (`ClaudeStream`) under the session it was
/// asked to resume, or a new one, a line every `BOTCHU_JOURNEY_FAKE_INTERVAL` milliseconds (30 by
/// default, about the captured pace); anything else exits at once with no output. With
/// `BOTCHU_JOURNEY_FAKE_LOG`, it appends each invocation and when it wrote each line
/// (`<uptime ns> <line index>`), so a journey can time a chunk from when the CLI wrote it.
enum FakeClaude {
    static func run(_ arguments: [String]) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let log = environment["BOTCHU_JOURNEY_FAKE_LOG"].flatMap { path -> FileHandle? in
            let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        func record(_ line: String) { try? log?.write(contentsOf: Data((line + "\n").utf8)) }
        record("\(DispatchTime.now().uptimeNanoseconds) run \(arguments.joined(separator: " ").prefix(300))")
        guard arguments.contains("-p") || arguments.contains("--print") else { return 0 }
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let session = value(after: "--resume") ?? value(after: "--session-id") ?? UUID().uuidString.lowercased()
        let interval = environment["BOTCHU_JOURNEY_FAKE_INTERVAL"].flatMap(Double.init) ?? 30
        // With live input, the turn starts on the first message written to stdin, echoed as Claude Code
        // echoes it with `--replay-user-messages`.
        if value(after: "--input-format") == "stream-json", let line = readLine(), !line.isEmpty {
            if arguments.contains("--replay-user-messages") { write(echo(line, session: session)) }
        }
        for (index, line) in ClaudeStream.turn.enumerated() {
            write(line.replacingOccurrences(of: ClaudeStream.session, with: session))
            record("\(DispatchTime.now().uptimeNanoseconds) \(index)")
            if index < ClaudeStream.turn.count - 1 { usleep(useconds_t(interval * 1_000)) }
        }
        return 0
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

    /// The wrapper the profile runs (BotChu runs a profile's command through a login shell).
    static func writeWrapper(at url: URL, harness: String) throws {
        let quoted = "'" + harness.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\nexec \(quoted) fake-claude \"$@\"\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
