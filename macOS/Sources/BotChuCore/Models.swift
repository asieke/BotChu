import Foundation

/// What a conversation runs on: an account, a model and reasoning effort, and the CLI session it
/// continues. A bot's own conversation (its Home) has its own, and so does each of its tasks.
public protocol RunSettings {
    var accountID: String { get set }
    var accountProfile: Account? { get set }
    /// Empty means the CLI's own default model.
    var model: String { get set }
    /// Pi’s provider ID; nil migrates to OpenRouter. Other runtimes have no provider choice.
    var providerID: String? { get set }
    /// Nil leaves reasoning effort to the CLI.
    var reasoningEffort: ReasoningEffort? { get set }
    /// Codex's Fast tier (#249): faster turns that use more of the allowance. Nil is off.
    var fastMode: Bool? { get set }
    /// The CLI session the conversation continues, and the account it belongs to.
    var sessionID: String? { get set }
    var sessionAccountID: String? { get set }
    var sessionScope: RunSessionScope? { get set }
    /// The model the CLI last said it ran, and for which account and choice.
    var reportedModel: ReportedModel? { get set }
}

extension RunSettings {
    public var account: Account { accountProfile.flatMap { $0.id == accountID ? $0 : nil } ?? Accounts.account(id: accountID) }

    public var effectiveProviderID: String? { ModelProvider.effectiveID(providerID, runtime: account.kind) }
    public var modelProvider: ModelProvider? { effectiveProviderID.map(ModelProvider.init) }
    public var executionScope: RunSessionScope { RunSessionScope(account: account, providerID: providerID) }
    public var usesLegacyOpenRouterKey: Bool { account.usesLegacyOpenRouterKey(providerID: providerID) }

    /// The model ID the CLI reported for the current account and model choice, or nil when it
    /// hasn't reported one since either changed.
    public var resolvedModel: String? {
        guard let reportedModel, reportedModel.accountID == accountID, reportedModel.requested == model,
              ModelProvider.effectiveID(reportedModel.providerID, runtime: account.kind) == effectiveProviderID else { return nil }
        return reportedModel.id
    }

    /// Records the model a turn's CLI said it ran; `requested` is the model choice the turn ran with.
    /// Returns whether anything changed. The choice itself (`model`) never changes here.
    @discardableResult
    public mutating func recordReportedModel(_ id: String, requested: String) -> Bool {
        let reported = ReportedModel(id: id, accountID: accountID, requested: requested, providerID: providerID)
        guard !id.isEmpty, reportedModel != reported else { return false }
        reportedModel = reported
        return true
    }

    /// The session to resume for the next turn, or nil when the next turn starts a new one. A
    /// session only resumes on the account that made it.
    public var resumableSessionID: String? {
        guard sessionAccountID == accountID else { return nil }
        if let sessionScope { return account.runtime.adapter.canResume(from: sessionScope, to: executionScope) ? sessionID : nil }
        // Sessions saved before provider support belonged to OpenRouter on Pi.
        guard account.kind != .pi || effectiveProviderID == ModelProvider.openRouter.id else { return nil }
        return sessionID
    }
}

public struct Bot: Identifiable, Codable, Hashable, Sendable, RunSettings {
    /// Nil in existing saves means a local CLI bot.
    public var kind: Kind?
    public enum Kind: String, Codable, Sendable { case localCLI, remoteQueue }
    public var isRemoteQueue: Bool { kind == .remoteQueue }
    /// App-owned history storage for a remote bot; never a CLI workspace.
    public var remoteStorage: String?
    public var persistencePath: String { isRemoteQueue ? (remoteStorage ?? workspace) : workspace }
    /// An agent owns tasks and scheduled jobs; a specialist is only called as a sub-agent
    /// (`botchu-subagent`), with its own Home, memory and account all the same (#250). Saves from
    /// before roles decode as an agent (`KeyedDecodingContainer.decode(_:forKey:)` below).
    public var role: Role = .agent
    public enum Role: String, Codable, Sendable, CaseIterable { case agent, specialist }
    /// A remote queue bot is neither: it is messaged, never delegated to.
    public var isSpecialist: Bool { role == .specialist && !isRemoteQueue }
    /// Whether tasks, dispatches and scheduled jobs can be the bot's own.
    public var canOwnTasks: Bool { !isRemoteQueue && !isSpecialist }
    /// Why the bot can't own a task or a job's run, in the words a refused request hears; nil when it can.
    public var taskOwnershipProblem: String? {
        if isRemoteQueue { return "Remote queue bots do not run local tasks." }
        if isSpecialist { return "“\(name)” is a specialist and cannot own tasks; call it with botchu-subagent instead." }
        return nil
    }
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
    public var providerID: String?
    /// Nil leaves reasoning effort to the CLI. Optional for compatibility with saved bots.
    public var reasoningEffort: ReasoningEffort?
    /// Codex's Fast tier; nil is off, as in bots saved before it (#249).
    public var fastMode: Bool?
    /// Absolute path of the bot's workspace folder.
    public var workspace: String
    /// How the bot looks, in the owner's words: what its pet is drawn from. Optional for
    /// compatibility with saved bots.
    public var appearance: String?
    /// The slugs of shared skills turned off for this bot (`Skills`); nil keeps every one on.
    public var disabledSkills: [String]?
    /// The CLI session the thread continues, and the account it belongs to. A session only
    /// resumes on the account that made it.
    public var sessionID: String?
    public var sessionAccountID: String?
    public var sessionScope: RunSessionScope?
    public var reportedModel: ReportedModel?
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, emoji: String = "🤖", title: String = "", instructions: String = "",
        accountID: String = Accounts.defaultID, model: String = "", reasoningEffort: ReasoningEffort? = nil, workspace: String,
        appearance: String? = nil, sessionID: String? = nil, sessionAccountID: String? = nil, createdAt: Date = Date(),
        role: Role = .agent
    ) {
        self.role = role
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

extension KeyedDecodingContainer {
    /// A bot.json from before roles has no `role`: it is an agent. The synthesized decoding of `Bot`
    /// picks this overload over the generic one.
    public func decode(_ type: Bot.Role.Type, forKey key: Key) throws -> Bot.Role {
        try decodeIfPresent(type, forKey: key) ?? .agent
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
    /// On a receipt about another bot's task (one this conversation handed to it), that bot.
    public var taskBotID: UUID?
    /// A tool call's structured arguments, as compact JSON with long strings shortened
    /// (`ToolArguments.digest`), when its CLI reports them. Nil in threads saved before.
    public var toolArguments: String?
    /// A shell command's exit status, when its CLI reports one.
    public var toolExitCode: Int?
    /// Seconds from a tool call's start to its result, when both were seen.
    public var toolDuration: Double?
    public var attachments: [ImageAttachment]?
    public var images: [ImageAttachment] { attachments ?? [] }
    /// Documents sent with the message (`FileAttachment`); a remote queue bot's messages carry
    /// them both ways. Nil in messages without any, and in threads saved before.
    public var files: [FileAttachment]?
    public var documents: [FileAttachment] { files ?? [] }
    /// A message between bots rather than from the owner (`AgentLink`): in a remote queue bot's Home,
    /// the bot that sent it and from which conversation; in that conversation, the remote bot whose
    /// reply it is. Nil otherwise, and in threads saved before.
    public var fromAgent: AgentLink?
    /// On the owner's message, the agents and projects chosen in it from `@` and `#` completion
    /// (`MessageReference`). Nil in messages without any, and in threads saved before.
    public var references: [MessageReference]?
    public var mentions: [MessageReference] { references ?? [] }
    /// On a receipt about a scheduled job's run (`JobReceipt`), the run it reports on.
    public var jobRun: JobRunLink?
    /// On the owner's message, the delivery it replies to from the Inbox (`InboxReply`); on a note,
    /// the delivery it shows in the chat as a card. Nil otherwise, and in threads saved before.
    public var delivery: UUID?
    /// On BotChu's "Stopped" note, the owner stopped the turn there (`stopNote`), so the
    /// conversation shows it stopped until its next message (#218). Nil otherwise, and in threads
    /// saved before.
    public var stopped: Bool?
    /// On BotChu's heartbeat message (`Heartbeat`), sent in the owner's place, its number in a row.
    /// Nil otherwise, and in threads saved before.
    public var heartbeat: Int?

    public init(
        id: UUID = UUID(), role: Role, text: String = "", date: Date = Date(), toolID: String? = nil,
        toolName: String? = nil, toolInput: String? = nil, toolOutput: String? = nil, toolState: ToolState? = nil,
        taskID: UUID? = nil, images: [ImageAttachment] = [], toolArguments: String? = nil, toolExitCode: Int? = nil,
        references: [MessageReference] = []
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
        self.references = references.isEmpty ? nil : references
    }
    /// BotChu's note at the end of a stopped turn: marked `stopped` when the owner stopped it, not
    /// when BotChu stopped it to quit.
    public static func stopNote(byOwner: Bool, date: Date = Date()) -> ChatMessage {
        var note = ChatMessage(role: .note, text: "Stopped", date: date)
        if byOwner { note.stopped = true }
        return note
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
    public var providerID: String?

    public init(id: String, accountID: String, requested: String, providerID: String? = nil) {
        self.id = id
        self.accountID = accountID
        self.requested = requested
        self.providerID = providerID
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
    /// The connectors the CLI reported at the start of its turn (Claude Code's `system/init`).
    case connectors([Connector])
    /// What each of the CLI's background tasks still running does, whenever that changes; empty
    /// once none is (Claude Code's `system/background_tasks_changed`). Its turn can end while they
    /// run: the CLI then waits for them and carries on with their results in a new turn (#255).
    case backgroundTasks([BotActivity])
}

/// Applies a run's events to a thread. Kept free of UI so it can be tested.
public struct ThreadAssembler {
    /// The assistant message text is being appended to, if any.
    public private(set) var openTextID: UUID?

    public init() {}

    public mutating func apply(_ event: AgentEvent, to messages: inout [ChatMessage]) {
        switch event {
        case .model, .connectors, .backgroundTasks:
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
