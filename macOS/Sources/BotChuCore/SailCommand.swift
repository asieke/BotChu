import Foundation

/// `botchu-sail`, the headless agent behind a Sail account, which BotChu runs as it runs the
/// other accounts' CLIs (`AgentRun`): one turn per run, its events as JSON lines on stdout
/// (`SailEvent`), its key in `SAIL_API_KEY`.
///
///     botchu-sail --session-id ID [--resume] [--model M] [--effort E] [--image PATH]… [--state-dir DIR] [--] PROMPT
///
/// Stopped by a signal, it ends the command a tool is running and says what it left at Sail; the
/// next run in the session picks that up.
public enum SailCommand {
    public struct Options: Equatable, Sendable {
        public var sessionID: String?
        public var resume = false
        public var model: String?
        public var effort: String?
        public var completionWindow: SailCompletionWindow = .flex
        public var images: [String] = []
        public var stateDirectory: String?
        public var prompt = ""

        public init() {}
    }

    public static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var prompt: String?
        var index = 0
        func value(_ name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw SailFailure(.malformed, "\(name) needs a value.") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--session-id": options.sessionID = try value(argument)
            case "--resume": options.resume = true
            case "--model": options.model = try value(argument)
            case "--effort": options.effort = try value(argument)
            case "--completion-window":
                guard let window = SailCompletionWindow(rawValue: try value(argument)) else {
                    throw SailFailure(.malformed, "Completion window must be asap, balanced, or flex.")
                }
                options.completionWindow = window
            case "--image": options.images.append(try value(argument))
            case "--state-dir": options.stateDirectory = try value(argument)
            case "--":
                let rest = arguments[(index + 1)...]
                guard prompt == nil, rest.count == 1 else { throw SailFailure(.malformed, "Give one prompt.") }
                prompt = rest.first
                index = arguments.count
                continue
            default:
                if argument.hasPrefix("--") { throw SailFailure(.malformed, "Unknown option \(argument).") }
                guard prompt == nil else { throw SailFailure(.malformed, "Give one prompt.") }
                prompt = argument
            }
            index += 1
        }
        guard let prompt else { throw SailFailure(.malformed, "Give a prompt.") }
        options.prompt = prompt
        return options
    }

    /// Runs one turn and returns the exit status: 0 when it ended well, 1 when it failed, 2 when
    /// it couldn't start.
    public static func main(arguments: [String], environment: [String: String], directory: URL,
                            handleSignals: Bool = true, write: @escaping @Sendable (String) -> Void = SailOutput.standard) async -> Int32 {
        let options: Options
        let images: [Data]
        do {
            options = try parse(arguments)
            images = try options.images.map { path -> Data in
                do { return try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
                    throw SailFailure(.malformed, "Couldn't read the attached image \(path).")
                }
            }
        } catch {
            write(SailEvent.failed((error as? SailFailure)?.message ?? error.localizedDescription).line)
            return 2
        }
        let key = environment[Sail.keyVariable]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = environment[Sail.baseVariable].flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? Sail.apiBase
        let store = SailSessionStore(directory: options.stateDirectory.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? SailSessionStore.defaultDirectory)
        let live = SailLive()
        let agent = SailAgent(client: SailClient(key: key, baseURL: base), store: store,
                              toolbox: SailToolbox(directory: directory, environment: environment, live: live),
                              instructions: SailInstructions.make(directory: directory), live: live)
        let sources = handleSignals ? installSignalHandlers(live: live, write: write) : []
        defer { sources.forEach { $0.cancel() } }
        let turn = SailAgent.Turn(sessionID: options.sessionID ?? UUID().uuidString.lowercased(), resume: options.resume,
                                  model: options.model ?? "", effort: options.effort, completionWindow: options.completionWindow, prompt: options.prompt, images: images)
        return await agent.run(turn) { write($0.line) } ? 0 : 1
    }

    /// INT (Stop), TERM and HUP end the running command and print what remains at Sail, then exit.
    /// So does BotChu going away without stopping it: a helper nobody reads stops waiting, and runs
    /// no tools, until its conversation's next message picks its submission up.
    static func installSignalHandlers(live: SailLive, write: @escaping @Sendable (String) -> Void) -> [any DispatchSourceProtocol] {
        signal(SIGPIPE, SIG_IGN)
        let queue = DispatchQueue(label: "BotChu.sail.signals")
        let end: @Sendable (Int32) -> Void = { status in
            if let notice = live.stop() { write(notice.line) }
            exit(status)
        }
        var sources: [any DispatchSourceProtocol] = [SIGINT, SIGTERM, SIGHUP].map { number -> any DispatchSourceProtocol in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { end(128 + number) }
            source.resume()
            return source
        }
        let parent = getppid()
        let orphan = DispatchSource.makeTimerSource(queue: queue)
        orphan.schedule(deadline: .now() + 5, repeating: 5)
        orphan.setEventHandler { if getppid() != parent { end(128 + SIGHUP) } }
        orphan.resume()
        sources.append(orphan)
        return sources
    }
}

/// The helper's stdout, one whole line at a time.
public enum SailOutput {
    private static let lock = NSLock()

    public static let standard: @Sendable (String) -> Void = { line in
        lock.lock()
        defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}
