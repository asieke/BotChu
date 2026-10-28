import Foundation

/// Sail Research, a Responses API for long-running agent work whose Flex completion window queues
/// requests for a lower price. BotChu's Sail account sends every request on Flex. Flex is taken
/// only by background Responses requests (`background: true` with
/// `metadata.completion_window = "flex"`), not by Chat Completions, Messages or foreground
/// Responses, and a background request can't stream: each one is submitted, then polled at
/// `GET /responses/{id}` until it ends (`SailClient`). A request carries the whole conversation
/// (no `previous_response_id`), and the client runs the function tools (`SailToolbox`). Sail
/// can't cancel or delete a response, so stopping in BotChu stops only BotChu's side.
public enum Sail {
    public static let apiBase = URL(string: "https://api.sailresearch.com/v1")!
    public static let dashboard = URL(string: "https://app.sailresearch.com/dashboard")!
    /// Where the helper reads the key: BotChu sets it from the Keychain for each run, and never
    /// passes it to a host or to the agent's own tools.
    public static let keyVariable = "SAIL_API_KEY"
    /// Replaces `apiBase`, for a stand-in server.
    public static let baseVariable = "BOTCHU_SAIL_BASE_URL"
    public static let completionWindow = "flex"
    /// The headless agent BotChu runs for a Sail account, built beside the app (`SailCommand`).
    public static let helperName = "botchu-sail"

    /// The command that runs the helper built beside `executable` (the app's own binary), or its
    /// bare name, for the login shell's PATH, when there's none.
    public static func helperCommand(besides executable: URL?) -> String {
        guard let executable else { return helperName }
        return Shell.quote(executable.deletingLastPathComponent().appendingPathComponent(helperName).path)
    }
}

/// Whether BotChu can start a Sail run.
public enum SailLaunch {
    /// Why a run can't start, in the conversation's words, or nil when it can: the helper is built
    /// beside BotChu and the key never leaves this Mac, so a run on a host can't use Sail.
    public static func problem(remote: Bool, key: String?) -> String? {
        if remote {
            return "Sail runs on This Mac only, where its helper and key are. Run this on This Mac, or choose another account for it."
        }
        if key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            return "Add your Sail API key in BotChu ▸ Settings ▸ Sail first."
        }
        return nil
    }
}

/// Where a Sail response is, as `GET /responses/{id}` says.
public enum SailStatus: Equatable, Sendable {
    case queued, inProgress, completed, incomplete, failed, cancelled
    /// A status this version doesn't know, polled on as if still running.
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "queued": self = .queued
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "incomplete": self = .incomplete
        case "failed": self = .failed
        case "cancelled", "canceled": self = .cancelled
        default: self = .other(raw)
        }
    }

    public var raw: String {
        switch self {
        case .queued: "queued"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .incomplete: "incomplete"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .other(let raw): raw
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .incomplete, .failed, .cancelled: true
        case .queued, .inProgress, .other: false
        }
    }

    public var label: String {
        switch self {
        case .queued: "queued"
        case .inProgress: "in progress"
        case .other(let raw): raw.replacingOccurrences(of: "_", with: " ")
        default: raw
        }
    }
}

/// The request bodies and conversation items BotChu sends.
public enum SailRequest {
    /// One background request on Flex with the whole conversation. Never `stream`,
    /// `previous_response_id` or `service_tier`: Flex is chosen by the metadata alone.
    public static func body(model: String, instructions: String, input: [SailJSON], tools: [SailJSON], effort: String?) -> SailJSON {
        var body: [String: SailJSON] = [
            "model": .string(model),
            "input": .array(input),
            "background": true,
            "metadata": ["completion_window": .string(Sail.completionWindow)],
        ]
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }
        if !tools.isEmpty { body["tools"] = .array(tools) }
        if let effort, !effort.isEmpty { body["reasoning"] = ["effort": .string(effort)] }
        return .object(body)
    }

    /// The owner's message, with PNG images (BotChu's attachments) inline.
    public static func userMessage(_ text: String, images: [Data] = []) -> SailJSON {
        var content: [SailJSON] = [["type": "input_text", "text": .string(text)]]
        for image in images {
            content.append(["type": "input_image", "image_url": .string("data:image/png;base64," + image.base64EncodedString())])
        }
        return ["role": "user", "content": .array(content)]
    }

    public static func functionOutput(callID: String, output: String) -> SailJSON {
        ["type": "function_call_output", "call_id": .string(callID), "output": .string(output)]
    }
}

/// A function call in a response's output, for the client to run.
public struct SailFunctionCall: Equatable, Sendable {
    public var callID: String
    public var name: String
    /// JSON text, as the model wrote it.
    public var arguments: String

    public init(callID: String, name: String, arguments: String) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

/// A response as Sail returns it on submission and on each poll.
public struct SailResponse: Equatable, Sendable {
    public var id: String
    public var status: SailStatus
    public var model: String?
    public var output: [SailJSON]
    public var errorMessage: String?
    public var errorCode: String?
    public var incompleteReason: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(id: String, status: SailStatus, model: String? = nil, output: [SailJSON] = [], errorMessage: String? = nil,
                errorCode: String? = nil, incompleteReason: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.id = id
        self.status = status
        self.model = model
        self.output = output
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.incompleteReason = incompleteReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func parse(_ data: Data) throws -> SailResponse {
        guard let json = try? SailJSON.parse(data), let id = json["id"]?.string, !id.isEmpty else {
            throw SailFailure(.malformed, "Sail answered with something that isn't a response: \(SailHTTP.snippet(data))")
        }
        let error = json["error"]
        return SailResponse(id: id, status: SailStatus(json["status"]?.string ?? "queued"), model: json["model"]?.string,
                            output: json["output"]?.array ?? [],
                            errorMessage: error?["message"]?.string ?? error?.string,
                            errorCode: error?["code"]?.string ?? error?["type"]?.string,
                            incompleteReason: json["incomplete_details"]?["reason"]?.string,
                            inputTokens: json["usage"]?["input_tokens"]?.int, outputTokens: json["usage"]?["output_tokens"]?.int)
    }

    /// The text of each output message, in order (a refusal reads as text).
    public var texts: [String] {
        output.compactMap { item -> String? in
            guard item["type"]?.string == "message" || (item["type"] == nil && item["role"]?.string == "assistant") else { return nil }
            let text = Self.text(of: item["content"])
            return text.isEmpty ? nil : text
        }
    }

    public var functionCalls: [SailFunctionCall] {
        output.compactMap { item in
            guard item["type"]?.string == "function_call", let name = item["name"]?.string,
                  let id = item["call_id"]?.string ?? item["id"]?.string else { return nil }
            return SailFunctionCall(callID: id, name: name, arguments: Self.arguments(of: item))
        }
    }

    /// The output as the next request's input: each message as assistant text and each function
    /// call as it was, without the ids and statuses of this response's items. Reasoning stays out.
    public var conversationItems: [SailJSON] {
        output.compactMap { item -> SailJSON? in
            switch item["type"]?.string {
            case "message":
                let text = Self.text(of: item["content"])
                return text.isEmpty ? nil : ["role": "assistant", "content": .string(text)]
            case "function_call":
                guard let name = item["name"]?.string, let id = item["call_id"]?.string ?? item["id"]?.string else { return nil }
                return ["type": "function_call", "call_id": .string(id), "name": .string(name),
                        "arguments": .string(Self.arguments(of: item))]
            default:
                return nil
            }
        }
    }

    /// A call's arguments as JSON text, also when a server sends them as an object.
    private static func arguments(of item: SailJSON) -> String {
        guard let arguments = item["arguments"] else { return "{}" }
        return arguments.string ?? arguments.text
    }

    private static func text(of content: SailJSON?) -> String {
        if let string = content?.string { return string }
        return (content?.array ?? []).compactMap { part -> String? in
            switch part["type"]?.string {
            case "output_text", "text": part["text"]?.string
            case "refusal": part["refusal"]?.string
            default: nil
            }
        }.joined(separator: "\n")
    }
}

/// Why a Sail request didn't go through, in words for the conversation.
public struct SailFailure: Error, Equatable, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The key is missing or refused.
        case key
        /// The model or request can't run on Flex: the owner chooses what to do.
        case flex
        /// Sail has no such response.
        case notFound
        /// Sail turned the request down for another reason.
        case rejected
        /// Sail couldn't be reached, or kept asking to wait, as long as BotChu tried.
        case unavailable
        case malformed
    }

    public var kind: Kind
    public var status: Int?
    public var message: String
    public var errorDescription: String? { message }

    public init(_ kind: Kind, status: Int? = nil, _ message: String) {
        self.kind = kind
        self.status = status
        self.message = message
    }
}

/// How Sail's HTTP answers read.
public enum SailHTTP {
    /// A rate limit, a timeout, a conflict with a submission still being taken, or the server's own
    /// failure: worth trying again, after a wait, with the same idempotency key.
    public static func isTransient(_ status: Int) -> Bool {
        [408, 409, 425, 429].contains(status) || (500...599).contains(status)
    }

    /// How long Sail asks to wait: `retry-after-ms`, or `Retry-After` in seconds or as an HTTP date.
    public static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        if let ms = response.value(forHTTPHeaderField: "retry-after-ms").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), ms >= 0 {
            return ms / 1_000
        }
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// The message of an error body (`{"error": {"message"}}`, `{"detail"}` or `{"message"}`), or the
    /// start of the body.
    public static func message(_ data: Data) -> String {
        if let json = try? SailJSON.parse(data) {
            if let message = json["error"]?["message"]?.string ?? json["error"]?.string ?? json["detail"]?.string ?? json["message"]?.string {
                return message
            }
        }
        return snippet(data)
    }

    static func snippet(_ data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(empty)" : text
    }

    /// What a refused submission means for the owner. A model or request Sail won't take on Flex
    /// says so with the choices there are, as BotChu never moves work to a faster, pricier window.
    public static func submissionFailure(status: Int, data: Data, model: String) -> SailFailure {
        let said = message(data)
        switch status {
        case 401, 403:
            return SailFailure(.key, status: status, "Sail refused the API key (HTTP \(status): \(said)). Check it in BotChu ▸ Settings ▸ Sail.")
        default:
            let lower = said.lowercased()
            if [400, 404, 422].contains(status), lower.contains("completion_window") || lower.contains("flex") {
                return SailFailure(.flex, status: status, """
                    Sail won't run \(model) on Flex (HTTP \(status): \(said)). BotChu sends every Sail request on Flex and \
                    doesn't move work to a faster, pricier completion window on its own. Choose a model that takes Flex in \
                    BotChu ▸ Settings ▸ Sail or this conversation's model menu, or switch the conversation to another account.
                    """)
            }
            return SailFailure(.rejected, status: status, "Sail rejected the request for \(model) (HTTP \(status): \(said)).")
        }
    }

    public static func pollFailure(status: Int, data: Data, id: String) -> SailFailure {
        let said = message(data)
        switch status {
        case 401, 403:
            return SailFailure(.key, status: status, "Sail refused the API key while checking \(id) (HTTP \(status): \(said)). Check it in BotChu ▸ Settings ▸ Sail.")
        case 404:
            return SailFailure(.notFound, status: status, "Sail no longer has response \(id) (HTTP 404: \(said)).")
        default:
            return SailFailure(.rejected, status: status, "Sail couldn't report on response \(id) (HTTP \(status): \(said)).")
        }
    }
}
