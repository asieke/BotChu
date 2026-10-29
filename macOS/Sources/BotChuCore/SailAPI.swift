import Foundation

/// Sail's request scheduling and price tier. Existing conversations keep Flex.
public enum SailCompletionWindow: String, Codable, CaseIterable, Sendable {
    case asap, balanced, flex
    public var title: String { switch self { case .asap: "ASAP"; case .balanced: "Balanced"; case .flex: "Flex" } }
    public var background: Bool { self != .asap }
    public var priceSource: String { self == .flex ? "sail" : "sail-" + rawValue }
    public static func from(_ body: SailJSON) -> Self {
        body["metadata"]?["completion_window"]?.string.flatMap(Self.init(rawValue:)) ?? .flex
    }
}

/// Sail Research's Responses API. Flex and Balanced use background submission and polling;
/// ASAP uses a foreground response. Stopping BotChu cannot cancel a request already at Sail.
public enum Sail {
    public static let apiBase = URL(string: "https://api.sailresearch.com/v1")!
    /// Sail's Usage API, which reports what the key's organization has spent and what it has left
    /// (`GET /v2/usage/summary`): the same numbers its dashboard's Billing page shows.
    public static let usageURL = URL(string: "https://api.sailresearch.com/v2/usage/summary")!
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
    /// The whole conversation in the chosen window. ASAP is foreground; Balanced and Flex
    /// are background. No streaming, previous_response_id, or service_tier.
    public static func body(model: String, instructions: String, input: [SailJSON], tools: [SailJSON], effort: String?, completionWindow: SailCompletionWindow = .flex) -> SailJSON {
        var body: [String: SailJSON] = [
            "model": .string(model),
            "input": .array(input),
            "background": .bool(completionWindow.background),
            "metadata": ["completion_window": .string(completionWindow.rawValue)],
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
    public var cachedInputTokens: Int?
    public var reasoningTokens: Int?

    public init(id: String, status: SailStatus, model: String? = nil, output: [SailJSON] = [], errorMessage: String? = nil,
                errorCode: String? = nil, incompleteReason: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cachedInputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.id = id
        self.status = status
        self.model = model
        self.output = output
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.incompleteReason = incompleteReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
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
                            inputTokens: json["usage"]?["input_tokens"]?.int, outputTokens: json["usage"]?["output_tokens"]?.int,
                            cachedInputTokens: json["usage"]?["input_tokens_details"]?["cached_tokens"]?.int,
                            reasoningTokens: json["usage"]?["output_tokens_details"]?["reasoning_tokens"]?.int)
    }

    /// Output includes reasoning, and input includes cached tokens.
    var turnUsage: TurnUsage? {
        func nonnegative(_ count: Int?) -> Int? { count.flatMap { $0 >= 0 ? $0 : nil } }
        return UsageParsing.turn(ModelUsage(model: model ?? "",
            uncachedInput: UsageParsing.uncached(nonnegative(inputTokens), nonnegative(cachedInputTokens)), cacheRead: nonnegative(cachedInputTokens),
            output: nonnegative(outputTokens), reasoning: nonnegative(reasoningTokens)))
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

    /// A refused submission names the selected window and the choices available.
    public static func submissionFailure(status: Int, data: Data, model: String, completionWindow: SailCompletionWindow = .flex) -> SailFailure {
        let said = message(data)
        switch status {
        case 401, 403:
            return SailFailure(.key, status: status, "Sail refused the API key (HTTP \(status): \(said)). Check it in BotChu ▸ Settings ▸ Sail.")
        default:
            if [400, 404, 422].contains(status), isAboutFlex(said) {
                return SailFailure(.flex, status: status, flexRefusal(model: model, said: "HTTP \(status): \(said)", completionWindow: completionWindow))
            }
            return SailFailure(.rejected, status: status, "Sail rejected the request for \(model) (HTTP \(status): \(said)).")
        }
    }

    /// Whether what Sail said is about the completion window.
    public static func isAboutFlex(_ said: String) -> Bool {
        let lower = said.lowercased()
        return lower.contains("completion_window") || lower.contains("completion window") || lower.contains("flex")
    }

    /// BotChu never switches completion windows automatically.
    public static func flexRefusal(model: String, said: String, completionWindow: SailCompletionWindow = .flex) -> String {
        "Sail won't run \(model) on \(completionWindow.title) (\(said)). Choose another completion window or model in this conversation's model menu. BotChu does not change the window automatically."
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
