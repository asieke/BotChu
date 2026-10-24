import Foundation

/// Turns one CLI's JSON lines into `AgentEvent`s. A parser keeps state across the lines of one run,
/// so each run gets a fresh one. Lines that are not JSON (warnings some CLIs print) are ignored.
public protocol StreamParser {
    mutating func parse(line: String) -> [AgentEvent]
}

public enum StreamParsers {
    public static func make(for kind: AgentKind) -> any StreamParser {
        switch kind {
        case .claude: ClaudeParser()
        case .codex: CodexParser()
        case .antigravity: AntigravityParser()
        case .muse: MuseParser()
        case .pi: PiParser()
        }
    }
}

typealias JSON = [String: Any]

func decode(_ line: String) -> JSON? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSON
}

/// A one-line description of a tool's input: the field a person would look for first, else the
/// whole input as compact JSON.
public func summarizeToolInput(_ value: Any?) -> String {
    guard let value else { return "" }
    if let string = value as? String { return string }
    if let dict = value as? [String: Any] {
        for key in ["command", "CommandLine", "cmd", "file_path", "path", "AbsolutePath", "TargetFile", "pattern",
                    "query", "Query", "url", "Url", "prompt", "description"] {
            if let s = dict[key] as? String, !s.isEmpty { return s }
            if let a = dict[key] as? [String] { return a.joined(separator: " ") }
        }
    }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: data, encoding: .utf8) else { return "\(value)" }
    return s
}

/// Text from a tool result's content, which is a string or a list of `{type: text, text}` blocks.
func contentText(_ value: Any?) -> String {
    if let s = value as? String { return s }
    if let blocks = value as? [[String: Any]] {
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    return ""
}

/// `claude -p --output-format stream-json --verbose --include-partial-messages`.
public struct ClaudeParser: StreamParser {
    /// Messages whose text arrived as deltas, so their whole `assistant` copy is skipped.
    private var streamedMessages: Set<String> = []
    private var currentMessage: String?
    /// The content block index of each text block of the current message.
    private var textBlocks: Set<Int> = []
    private var toolNames: [String: String] = [:]
    private var reportedModel: String?

    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let obj = decode(line), let type = obj["type"] as? String else { return [] }
        // A subagent's work stays inside its Task tool call.
        if let parent = obj["parent_tool_use_id"] as? String, !parent.isEmpty { return [] }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String { return [.session(id)] }
        case "stream_event":
            guard let event = obj["event"] as? JSON, let eventType = event["type"] as? String else { return [] }
            switch eventType {
            case "message_start":
                currentMessage = (event["message"] as? JSON)?["id"] as? String
                textBlocks = []
            case "content_block_start":
                if (event["content_block"] as? JSON)?["type"] as? String == "text", let index = event["index"] as? Int {
                    textBlocks.insert(index)
                }
            case "content_block_delta":
                if let delta = event["delta"] as? JSON, delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    if let currentMessage { streamedMessages.insert(currentMessage) }
                    return [.textDelta(text)]
                }
            case "content_block_stop":
                if let index = event["index"] as? Int, textBlocks.contains(index) { return [.textEnd] }
            default: break
            }
        case "assistant":
            guard let message = obj["message"] as? JSON, let content = message["content"] as? [JSON] else { return [] }
            let streamed = (message["id"] as? String).map { streamedMessages.contains($0) } ?? false
            var events: [AgentEvent] = []
            // The model that wrote the message. The init event only repeats the --model asked for,
            // even one that doesn't exist; a message Claude Code makes up itself says "<synthetic>".
            if let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<"), model != reportedModel {
                reportedModel = model
                events.append(.model(model))
            }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if !streamed, let text = block["text"] as? String { events.append(.text(text)) }
                case "tool_use":
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "Tool"
                    toolNames[id] = name
                    events.append(.toolStarted(id: id, name: name, input: summarizeToolInput(block["input"]),
                                               arguments: ToolArguments.digest(block["input"])))
                default: break
                }
            }
            return events
        case "user":
            // With --replay-user-messages, each message Claude Code takes from stdin comes back.
            if obj["isReplay"] as? Bool == true { return [.inputTaken] }
            guard let content = (obj["message"] as? JSON)?["content"] as? [JSON] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolFinished(id: id, name: toolNames[id] ?? "Tool", output: contentText(block["content"]),
                                     isError: block["is_error"] as? Bool ?? false)
            }
        case "result":
            if obj["is_error"] as? Bool == true || (obj["subtype"] as? String).map({ $0 != "success" }) == true {
                let reason = (obj["result"] as? String) ?? (obj["errors"] as? [String])?.joined(separator: "\n")
                return [.failed(reason?.isEmpty == false ? reason! : "Claude Code stopped with \(obj["subtype"] as? String ?? "an error").")]
            }
            return [.finished]
        default: break
        }
        return []
    }
}

/// `codex exec --json`.
public struct CodexParser: StreamParser {
    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let obj = decode(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            if let id = obj["thread_id"] as? String { return [.session(id)] }
        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? JSON, let itemType = item["type"] as? String else { return [] }
            let id = item["id"] as? String ?? UUID().uuidString
            let completed = type == "item.completed"
            switch itemType {
            case "agent_message":
                if completed, let text = item["text"] as? String { return [.text(text)] }
            case "command_execution":
                let command = Self.unwrapShell(item["command"] as? String ?? "")
                if completed {
                    let exit = item["exit_code"] as? Int
                    let failed = (exit.map { $0 != 0 } ?? false) || item["status"] as? String == "failed"
                    return [.toolStarted(id: id, name: "Shell", input: command),
                            .toolFinished(id: id, name: "Shell", output: item["aggregated_output"] as? String ?? "", isError: failed, exitCode: exit)]
                }
                return [.toolStarted(id: id, name: "Shell", input: command)]
            case "file_change":
                let paths = (item["changes"] as? [JSON])?.compactMap { change -> String? in
                    guard let path = change["path"] as? String else { return nil }
                    return "\(change["kind"] as? String ?? "edit") \(path)"
                }.joined(separator: "\n") ?? ""
                if completed {
                    return [.toolStarted(id: id, name: "Edit files", input: paths),
                            .toolFinished(id: id, name: "Edit files", output: paths, isError: item["status"] as? String == "failed")]
                }
                return [.toolStarted(id: id, name: "Edit files", input: paths)]
            case "mcp_tool_call":
                let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
                let input = summarizeToolInput(item["arguments"])
                let arguments = ToolArguments.digest(item["arguments"])
                if completed {
                    let output = summarizeToolInput((item["result"] as? JSON)?["content"].map(contentText) ?? item["error"])
                    return [.toolStarted(id: id, name: name, input: input, arguments: arguments),
                            .toolFinished(id: id, name: name, output: output, isError: item["status"] as? String == "failed")]
                }
                return [.toolStarted(id: id, name: name, input: input, arguments: arguments)]
            case "web_search":
                let query = item["query"] as? String ?? ""
                return completed
                    ? [.toolStarted(id: id, name: "Web search", input: query), .toolFinished(id: id, name: "Web search", output: "", isError: false)]
                    : [.toolStarted(id: id, name: "Web search", input: query)]
            case "error":
                if let message = item["message"] as? String { return [.failed(message)] }
            default: break
            }
        case "turn.failed":
            let message = (obj["error"] as? JSON)?["message"] as? String ?? "Codex stopped with an error."
            return [.failed(message)]
        case "error":
            if let message = obj["message"] as? String { return [.failed(message)] }
        case "turn.completed":
            return [.finished]
        default: break
        }
        return []
    }

    /// `/bin/zsh -lc 'ls -la'` → `ls -la`: the shell wrapper Codex puts around every command.
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc "] where command.hasPrefix(prefix) {
            var inner = String(command.dropFirst(prefix.count))
            if inner.count >= 2, let first = inner.first, first == inner.last, first == "'" || first == "\"" {
                inner = String(inner.dropFirst().dropLast())
            }
            return inner
        }
        return command
    }
}

/// `agy -p --output-format stream-json` (Antigravity CLI).
public struct AntigravityParser: StreamParser {
    private var completedResponse = false
    private var reportedError = false

    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let obj = decode(line), let event = obj["event"] as? String else { return [] }
        switch event {
        case "init":
            if let id = obj["conversation_id"] as? String { return [.session(id)] }
        case "step_update":
            guard let step = obj["step_update"] as? JSON else { return [] }
            let state = step["state"] as? String ?? ""
            let index = step["step_index"] as? Int ?? 0
            switch step["step_type"] as? String {
            case "agent_response":
                var events: [AgentEvent] = []
                if let delta = step["text_delta"] as? String { events.append(.textDelta(delta)) }
                if state == "DONE" {
                    completedResponse = true
                    events.append(.textEnd)
                }
                return events
            case "tool", "subagent":
                let id = "step-\(index)"
                let info = step["tool_info"] as? JSON
                let subagents = (step["subagent_info"] as? JSON)?["subagents"] as? [JSON]
                let name = step["tool_name"] as? String ?? info?["name"] as? String ?? "Tool"
                // A launch starts as `tool` but completes as `subagent`, without tool_info.
                // DONE acknowledges the launch; the child replies arrive later in the parent's text.
                let roles = subagents?.compactMap { $0["role"] as? String }.joined(separator: "\n")
                let parameters = info?["parameters"] as? JSON
                let input = roles ?? parameters?["Role"] as? String ?? summarizeToolInput(info?["parameters"])
                let arguments = ToolArguments.digest(parameters)
                if state == "ACTIVE" { return [.toolStarted(id: id, name: name, input: input, arguments: arguments)] }
                if state == "DONE" || state == "ERROR" || state == "CANCELED" {
                    let launched = subagents?.map { child in
                        let role = child["role"] as? String ?? "Subagent"
                        let conversation = child["conversation_id"] as? String ?? ""
                        return "Launched \(role)" + (conversation.isEmpty ? "" : "\nConversation: \(conversation)")
                    }.joined(separator: "\n\n")
                    let output = state == "DONE"
                        ? (info?["output"] as? String ?? launched ?? "")
                        : (info?["output"] as? String ?? "Antigravity reported \(state).")
                    let failed = state != "DONE" || output.hasPrefix("Command failed")
                    return [.toolStarted(id: id, name: name, input: input, arguments: arguments),
                            .toolFinished(id: id, name: name, output: output, isError: failed)]
                }
            default: break
            }
        case "result":
            let result = obj["result"] as? JSON
            let status = result?["status"] as? String ?? ""
            // Status summarizes the whole trajectory, including earlier failed turns.
            // response is the assistant's reply, never an error diagnostic.
            if reportedError { return [] } // The error event already reported this failure.
            if status == "SUCCESS" || completedResponse { return [.finished] }
            return [.failed("Antigravity stopped: \(status.isEmpty ? "unknown status" : status).")]
        case "error":
            reportedError = true
            let message = (obj["error"] as? JSON)?["message"] as? String ?? obj["error"] as? String ?? obj["message"] as? String
            return [.failed(message ?? "Antigravity reported an error.")]
        default: break
        }
        return []
    }
}

/// `muse exec --json`: a log of records, of which BotChu reads the reply text, tool results and the
/// run's end.
public struct MuseParser: StreamParser {
    private var streamed = false
    private var sentSession = false

    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let obj = decode(line), let type = obj["payload_type"] as? String else { return [] }
        var events: [AgentEvent] = []
        if !sentSession, let stream = obj["stream"] as? JSON, stream["kind"] as? String == "session",
           let id = stream["id"] as? String {
            sentSession = true
            events.append(.session(id))
        }
        let payload = obj["payload"] as? JSON ?? [:]
        switch type {
        case "run.output.delta":
            if let text = payload["text"] as? String {
                streamed = true
                events.append(.textDelta(text))
            }
        case "run.usage":
            // The models the run used, by calls. `run.model.configured` only repeats the --model
            // asked for, even one that doesn't exist.
            let models = (payload["models"] as? [JSON] ?? []).compactMap { entry -> (String, Int)? in
                guard let model = entry["model"] as? String, !model.isEmpty else { return nil }
                return (model, entry["calls"] as? Int ?? 0)
            }
            if let top = models.max(by: { $0.1 < $1.1 }) { events.append(.model(top.0)) }
        case "tool.result":
            let id = payload["call_id"] as? String ?? UUID().uuidString
            let facts = payload["correlation_facts"] as? JSON
            let name = facts?["tool_name"] as? String ?? "Tool"
            let raw = payload["text"] as? String ?? ""
            var input = ""
            var output = raw
            var arguments: String?
            var exit: Int?
            if let detail = decode(raw) {
                input = summarizeToolInput(detail)
                if let out = detail["output"] as? String { output = out }
                arguments = ToolArguments.digest(detail, dropping: ["output"])
                exit = detail["exit_code"] as? Int
            }
            let failed = (facts?["outcome"] as? String).map { $0 != "success" } ?? false
            events += [.toolStarted(id: id, name: name, input: input, arguments: arguments),
                       .toolFinished(id: id, name: name, output: output, isError: failed, exitCode: exit)]
        default:
            if type.hasPrefix("run.terminal") {
                let terminal = payload["terminal"] as? String ?? ""
                if terminal == "completed" {
                    if !streamed, let text = payload["text"] as? String { events.append(.text(text)) }
                    events += [.textEnd, .finished]
                } else {
                    let reason = payload["reason"] as? String ?? payload["text"] as? String
                    events.append(.failed(reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Muse stopped: \(terminal.isEmpty ? "unknown" : terminal)."))
                }
            }
        }
        return events
    }
}

/// `pi -p --mode json`.
public struct PiParser: StreamParser {
    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let obj = decode(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "session":
            if let id = obj["id"] as? String { return [.session(id)] }
        case "message_update":
            guard let event = obj["assistantMessageEvent"] as? JSON else { return [] }
            switch event["type"] as? String {
            case "text_delta":
                if let delta = event["delta"] as? String { return [.textDelta(delta)] }
            case "text_end":
                return [.textEnd]
            default: break
            }
        case "tool_execution_start":
            let id = obj["toolCallId"] as? String ?? UUID().uuidString
            return [.toolStarted(id: id, name: obj["toolName"] as? String ?? "Tool", input: summarizeToolInput(obj["args"]),
                                 arguments: ToolArguments.digest(obj["args"]))]
        case "tool_execution_end":
            let id = obj["toolCallId"] as? String ?? UUID().uuidString
            let result = obj["result"] as? JSON
            let isError = obj["isError"] as? Bool ?? obj["is_error"] as? Bool ?? false
            return [.toolFinished(id: id, name: obj["toolName"] as? String ?? "Tool",
                                  output: contentText(result?["content"]), isError: isError)]
        case "message_end":
            guard let message = obj["message"] as? JSON, message["role"] as? String == "assistant" else { return [] }
            if message["stopReason"] as? String == "error" || message["stopReason"] as? String == "aborted" {
                let reason = message["errorMessage"] as? String
                return [.failed(reason.flatMap { $0.isEmpty ? nil : $0 } ?? "The model stopped with an error.")]
            }
        case "agent_end":
            return [.finished]
        default: break
        }
        return []
    }
}
