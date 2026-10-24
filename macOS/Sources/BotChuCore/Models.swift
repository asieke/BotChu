import Foundation

/// What a conversation runs on: an account, a model and reasoning effort, and the CLI session it
/// continues. A bot's own conversation (its Home) has its own, and so does each of its tasks.
public protocol RunSettings {
    var accountID: String { get set }
    var accountProfile: Account? { get set }
    /// Empty means the CLI's own default model.
    var model: String { get set }
    /// Nil leaves reasoning effort to the CLI.
    var reasoningEffort: ReasoningEffort? { get set }
    /// The CLI session the conversation continues, and the account it belongs to.
    var sessionID: String? { get set }
    var sessionAccountID: String? { get set }
    /// The model the CLI last said it ran, and for which account and choice.
    var reportedModel: ReportedModel? { get set }
}

extension RunSettings {
    public var account: Account { accountProfile.flatMap { $0.id == accountID ? $0 : nil } ?? Accounts.account(id: accountID) }

    /// The model ID the CLI reported for the current account and model choice, or nil when it
    /// hasn't reported one since either changed.
    public var resolvedModel: String? {
        guard let reportedModel, reportedModel.accountID == accountID, reportedModel.requested == model else { return nil }
        return reportedModel.id
    }

    /// Records the model a turn's CLI said it ran; `requested` is the model choice the turn ran with.
    /// Returns whether anything changed. The choice itself (`model`) never changes here.
    @discardableResult
    public mutating func recordReportedModel(_ id: String, requested: String) -> Bool {
        let reported = ReportedModel(id: id, accountID: accountID, requested: requested)
        guard !id.isEmpty, reportedModel != reported else { return false }
        reportedModel = reported
        return true
    }

    /// The session to resume for the next turn, or nil when the next turn starts a new one. A
    /// session only resumes on the account that made it.
    public var resumableSessionID: String? {
        sessionAccountID == accountID ? sessionID : nil
    }
}

public struct Bot: Identifiable, Codable, Hashable, Sendable, RunSettings {
    public var id: UUID
    public var name: String
    public var emoji: String
    /// The public one-liner shown under the name.
    public var title: String
    /// Private instructions, from before they moved to `INSTRUCTIONS.md` in the workspace. Still
    /// decoded from older bot.json, and set by the New Bot sheet: `Workspace.migrateInstructions`
    /// writes them into that file once and clears this.
    public var instructions: String
    public var accountID: String
    /// Custom profiles travel with the bot so its CLI family survives relaunch and workspace moves.
    public var accountProfile: Account?
    /// Empty means the CLI's own default model.
    public var model: String
    /// Nil leaves reasoning effort to the CLI. Optional for compatibility with saved bots.
    public var reasoningEffort: ReasoningEffort?
    /// Absolute path of the bot's workspace folder.
    public var workspace: String
    /// How the bot looks, in the owner's words: what its pet is drawn from. Optional for
    /// compatibility with saved bots.
    public var appearance: String?
    /// The CLI session the thread continues, and the account it belongs to. A session only
    /// resumes on the account that made it.
    public var sessionID: String?
    public var sessionAccountID: String?
    public var reportedModel: ReportedModel?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, emoji: String = "🤖", title: String = "", instructions: String = "",
        accountID: String = Accounts.defaultID, model: String = "", reasoningEffort: ReasoningEffort? = nil, workspace: String,
        appearance: String? = nil, sessionID: String? = nil, sessionAccountID: String? = nil, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.title = title
        self.instructions = instructions
        self.accountID = accountID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.workspace = workspace
        self.appearance = appearance
        self.sessionID = sessionID
        self.sessionAccountID = sessionAccountID
        self.createdAt = createdAt
    }

    /// A folder name made from the bot's name: lowercase letters, digits and hyphens.
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("-"), !out.isEmpty {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "bot" : out
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user, assistant, tool, error
        /// A line from BotChu itself, such as "New session".
        case note
        /// A line from BotChu in a bot's Home thread about one of its tasks (`TaskReceipt`), which
        /// its next Home turn hears about.
        case receipt

        /// BotChu's own lines, which aren't part of the conversation.
        public var isNote: Bool { self == .note || self == .receipt }
    }

    public enum ToolState: String, Codable, Sendable {
        case running, done, failed, interrupted
    }

    public var id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    public var toolID: String?
    public var toolName: String?
    public var toolInput: String?
    public var toolOutput: String?
    public var toolState: ToolState?
    /// On a receipt, the task it reports on; nil for a task BotChu couldn't start.
    public var taskID: UUID?
    /// A tool call's structured arguments, as compact JSON with long strings shortened
    /// (`ToolArguments.digest`), when its CLI reports them. Nil in threads saved before.
    public var toolArguments: String?
    /// A shell command's exit status, when its CLI reports one.
    public var toolExitCode: Int?
    /// Seconds from a tool call's start to its result, when both were seen.
    public var toolDuration: Double?
    public var attachments: [ImageAttachment]?
    public var images: [ImageAttachment] { attachments ?? [] }

    public init(
        id: UUID = UUID(), role: Role, text: String = "", date: Date = Date(), toolID: String? = nil,
        toolName: String? = nil, toolInput: String? = nil, toolOutput: String? = nil, toolState: ToolState? = nil,
        taskID: UUID? = nil, images: [ImageAttachment] = [], toolArguments: String? = nil, toolExitCode: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.toolID = toolID
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.toolState = toolState
        self.taskID = taskID
        self.attachments = images.isEmpty ? nil : images
        self.toolArguments = toolArguments
        self.toolExitCode = toolExitCode
    }
    /// Older versions missed AGY's subagent terminal events and saved them as failures.
    /// No result was recorded, so show an unknown completion instead of inventing success or failure.
    public func displayedToolState(for kind: AgentKind) -> ToolState {
        if kind == .antigravity, toolName == "invoke_subagent", toolState == .failed, toolOutput == nil {
            return .interrupted
        }
        return toolState ?? .done
    }
}

/// The model ID a CLI said it ran (such as `claude-opus-5-5` for the alias `opus`), for the account
/// and the model choice (`requested`, empty for the account's default) it ran with. A later change of
/// either leaves it unresolved again rather than showing a version that may no longer apply.
public struct ReportedModel: Codable, Hashable, Sendable {
    public var id: String
    public var accountID: String
    public var requested: String

    public init(id: String, accountID: String, requested: String) {
        self.id = id
        self.accountID = accountID
        self.requested = requested
    }
}

/// What a CLI's stream says happened, in the order it happened.
public enum AgentEvent: Equatable, Sendable {
    case session(String)
    /// The model the CLI says it ran, by its full ID, where its stream reports one.
    case model(String)
    /// More text for the reply being written.
    case textDelta(String)
    /// A whole block of reply text, for CLIs (or blocks) that do not stream.
    case text(String)
    /// The reply being written is complete; the next text starts a new message.
    case textEnd
    /// `arguments` is the call's structured input as `ToolArguments.digest` keeps it.
    case toolStarted(id: String, name: String, input: String, arguments: String? = nil)
    case toolFinished(id: String, name: String, output: String, isError: Bool, exitCode: Int? = nil)
    case failed(String)
    case finished
    /// The CLI took the next message written to its stdin (Claude Code's replay of it). The
    /// first is the turn's prompt; later ones are follow-ups, which then join the transcript.
    case inputTaken
}

/// Applies a run's events to a thread. Kept free of UI so it can be tested.
public struct ThreadAssembler {
    /// The assistant message text is being appended to, if any.
    public private(set) var openTextID: UUID?

    public init() {}

    public mutating func apply(_ event: AgentEvent, to messages: inout [ChatMessage]) {
        switch event {
        case .model:
            break
        case .session, .finished:
            openTextID = nil
        case .inputTaken:
            // A follow-up the caller adds next ends the reply being written.
            apply(.textEnd, to: &messages)
        case .textDelta(let delta):
            if let id = openTextID, let i = Self.index(of: id, in: messages) {
                messages[i].text += delta
            } else {
                // Leading newlines would start the bubble with blank space.
                let trimmed = String(delta.drop(while: { $0.isNewline }))
                guard !trimmed.isEmpty else { return }
                let message = ChatMessage(role: .assistant, text: trimmed)
                openTextID = message.id
                messages.append(message)
            }
        case .text(let text):
            openTextID = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            messages.append(ChatMessage(role: .assistant, text: trimmed))
        case .textEnd:
            if let id = openTextID, let i = Self.index(of: id, in: messages) {
                messages[i].text = messages[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            openTextID = nil
        case let .toolStarted(id, name, input, arguments):
            apply(.textEnd, to: &messages)
            if let i = messages.lastIndex(where: { $0.toolID == id }) {
                messages[i].toolName = name
                if !input.isEmpty { messages[i].toolInput = input }
                if let arguments { messages[i].toolArguments = arguments }
            } else {
                messages.append(ChatMessage(role: .tool, toolID: id, toolName: name, toolInput: input, toolState: .running,
                                            toolArguments: arguments))
            }
        case let .toolFinished(id, name, output, isError, exitCode):
            apply(.textEnd, to: &messages)
            let state: ChatMessage.ToolState = isError ? .failed : .done
            if let i = messages.lastIndex(where: { $0.toolID == id }) {
                messages[i].toolOutput = output
                messages[i].toolState = state
                if let exitCode { messages[i].toolExitCode = exitCode }
                // Only a call seen starting earlier has a duration; one reported whole has none.
                let elapsed = Date().timeIntervalSince(messages[i].date)
                if messages[i].toolDuration == nil, elapsed > 0.05 { messages[i].toolDuration = elapsed }
                if messages[i].toolName?.isEmpty ?? true { messages[i].toolName = name }
            } else {
                messages.append(ChatMessage(role: .tool, toolID: id, toolName: name, toolInput: "", toolOutput: output, toolState: state,
                                            toolExitCode: exitCode))
            }
        case .failed(let reason):
            apply(.textEnd, to: &messages)
            messages.append(ChatMessage(role: .error, text: reason))
        }
    }

    /// The reply being written is at the end of the thread, or near it (a note can follow it), so
    /// look from the end: a long thread isn't scanned for every delta.
    private static func index(of id: UUID, in messages: [ChatMessage]) -> Int? {
        if let last = messages.indices.last, messages[last].id == id { return last }
        return messages.lastIndex { $0.id == id }
    }

    /// A missing terminal event is not evidence that the tool failed.
    public static func closeRunningTools(_ messages: inout [ChatMessage]) {
        for i in messages.indices where messages[i].toolState == .running {
            messages[i].toolState = .interrupted
        }
    }
}
