import Foundation
import BotChuCore

/// `@mention` cameo turns in Project Areas (#399 decision 8, #406, #424): who answers a message
/// there, and which turns a reply starts (`CameoRouting`). The area's own bot answers in the
/// conversation's turn; another bot's cameo turn runs beside it as a run of the area's conversation
/// (`SubagentRuntime.startCameo`), on that bot's settings and session slot, whose reply goes into
/// the conversation as that bot's once it ends. Home is unchanged.
extension AppModel {
    /// The bot taking a cameo turn in the conversation's own turn now: none since #424, where cameo
    /// turns run beside it, each with a card of its own.
    func cameoSpeaker(of target: ChatTarget) -> Bot? { nil }

    /// The bots that can take a turn in an area: those running a local CLI.
    var areaTurnBots: Set<UUID> { Set(bots.filter { !$0.isRemoteQueue }.map(\.id)) }

    /// Who answers `message` in the area `target`, in order: the bot a request posted there asked
    /// (`AreaPost`), else the bots chosen in it from `@` completion, else the area's own bot.
    /// BotChu's heartbeat is the area's own bot's.
    func answerers(of message: ChatMessage, in target: ChatTarget) -> [UUID] {
        guard message.heartbeat == nil else { return [target.botID] }
        if let asked = message.speakerBotID { return areaTurnBots.contains(asked) ? [asked] : [target.botID] }
        return CameoRouting.answerers(of: message.mentions, owner: target.botID, eligible: areaTurnBots)
    }

    /// The area's own bot's `turn` starts in `target`, with `message` when the owner's message starts it.
    func beginAreaTurn(_ turn: AreaTurn, message: UUID?, in target: ChatTarget) {
        areaSpeakers[target] = AreaSpeaker(turn: turn, message: message)
    }

    /// The area's own bot's turn in `target` ended. When it went on to its end (`continues`), the
    /// bots its reply mentions get their turns; otherwise its own waiting turns are called off.
    func endAreaTurn(_ target: ChatTarget, reply: [ChatMessage], continues: Bool) {
        guard let speaker = areaSpeakers.removeValue(forKey: target) else { return }
        guard continues else {
            areaTurns[target] = nil
            return
        }
        let text = reply.filter { $0.role == .assistant && $0.speakerBotID == nil }.map(\.text).joined(separator: "\n\n")
        startTurns(mentionedIn: text, by: speaker.turn.botID, hop: speaker.turn.hop, in: target)
    }

    /// The bots running or waiting in the area `target`, which a reply's mention gives no turn:
    /// the cameo turns, and the area's own bot's turns waiting. The area's own bot running doesn't
    /// count, as it hasn't read the reply: a mention gives it a turn after its running one.
    func areaBusy(_ target: ChatTarget) -> Set<UUID> {
        (areaRooms[target]?.busy ?? []).union((areaTurns[target] ?? []).map(\.botID))
    }

    /// The turns a reply by `speaker` at `hop` gives the bots it mentions (`CameoRouting.turns`):
    /// the area's own bot's waits for its conversation's turn, and the others start at once.
    func startTurns(mentionedIn text: String, by speaker: UUID, hop: Int, in target: ChatTarget) {
        let directory = MentionDirectory(agents: bots.filter { !$0.isRemoteQueue }.map(BotRosterEntry.init))
        let more = CameoRouting.turns(after: text, by: speaker, hop: hop, directory: directory, busy: areaBusy(target))
        guard !more.isEmpty else { return }
        let own = more.filter { $0.botID == target.botID }
        if !own.isEmpty { areaTurns[target] = (areaTurns[target] ?? []) + own }
        startCameoTurns(more.filter { $0.botID != target.botID }, in: target)
        if !own.isEmpty { sendNextQueued(to: target) }
    }

    /// Starts each of `turns`, other bots' cameo turns in the area `target`, at once beside the
    /// conversation's own turn (#424); one for a bot already running there waits for it (`AreaRoom`).
    func startCameoTurns(_ turns: [AreaTurn], in target: ChatTarget) {
        for turn in turns { startCameoTurn(turn, in: target) }
    }

    private func startCameoTurn(_ turn: AreaTurn, in target: ChatTarget) {
        guard !storageMovePending, let area = task(target), area.isArea, let directory = area.folder,
              let bot = bot(turn.botID), !bot.isRemoteQueue else { return }
        let id = UUID()
        var room = areaRooms[target] ?? AreaRoom()
        let starts = room.admit(turn, run: id)
        areaRooms[target] = room
        guard starts else { return }
        let history = thread(target)
        let message = turn.messageID.flatMap { id in history.last { $0.id == id } }
        let brief: String
        let title: String
        if let message, turn.hop == 0 {
            // The owner's message, with what its mentions point at.
            brief = deliveredText(of: message, for: target, recipient: turn.botID)
            title = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Turn in \(area.title)"
        } else {
            let by = turn.mentionedBy.flatMap { self.bot($0)?.name }
            brief = CameoRouting.prompt(mentionedBy: by)
            title = "Mentioned by \(by ?? "the owner")"
        }
        delegation.startCameo(turn, id: id, settings: bot.cameo(in: area), title: title, brief: brief, in: target,
                              directory: directory, hostID: area.hostID)
        // A request posted into the area for this bot hears that its turn started.
        reportTaskStart(target, failure: nil)
    }

    /// What a cameo turn's CLI is asked (`SubagentRuntime.launch`): in a new session (or when its
    /// bot's context changed), who it is, whose area it's in and the conversation so far; in a
    /// resumed one, what other bots said since its last turn; then what became of its notes, and
    /// its brief.
    func cameoPrompt(for run: SubagentRun, bot: Bot, context: SessionPreparation.Snapshot, resuming: Bool, remote: Bool,
                     roster: [BotRosterEntry]) -> String {
        let target = ChatTarget(botID: run.rootBotID, taskID: run.rootTaskID)
        let key = Self.cameoMemoryKey(run.targetBotID, in: target)
        let history = thread(target)
        let voices = turnVoices(for: run.targetBotID, in: target)
        var sections: [String] = []
        if !resuming || cameoContexts[key] != context.revision, let area = task(target), let owner = self.bot(target.botID) {
            sections.append(BotContext.cameoPreamble(bot: bot, owner: owner, area: area, memory: context.memory,
                sharedMemory: context.sharedMemory, history: resuming ? [] : history.filter { $0.id != run.cameo?.messageID },
                voices: voices, soul: context.soul, instructions: context.instructions, team: context.team, skills: context.skills))
            if !resuming { sections.append(BotContext.subagentsSection(availableBots: roster)) }
            if !remote, let tools = tools.instructions(), !resuming { sections.append(tools) }
            cameoContexts[key] = context.revision
        }
        var updates: [String] = []
        if resuming, let voices,
           let since = CameoRouting.since(lastTurnOf: run.targetBotID, owner: target.botID, in: history, excluding: run.cameo?.messageID,
                                          names: voices.names) {
            updates.append(since)
        }
        if let notes = BotContext.memoryUpdates(memoryReports.removeValue(forKey: key) ?? []) { updates.append(notes) }
        return BotContext.prompt(for: run.brief, preamble: sections.isEmpty ? nil : sections.joined(separator: "\n\n"),
                                 updates: updates.isEmpty ? nil : updates.joined(separator: "\n\n"))
    }

    /// Cameo turn `run` ended (`SubagentRuntime.commit`) with its transcript `messages`. Its reply
    /// goes into the area's conversation as its bot's, and the bots it mentions get their turns;
    /// then its bot's next turn waiting there starts. A turn stopped or failed says so on its card
    /// and calls off its bot's turns waiting.
    func cameoEnded(_ run: SubagentRun, messages: [ChatMessage]) {
        guard let turn = run.cameo else { return }
        let target = ChatTarget(botID: run.rootBotID, taskID: run.rootTaskID)
        let completed = run.phase == .completed
        var room = areaRooms[target] ?? AreaRoom()
        let next = room.end(run: run.id, of: run.targetBotID, continues: completed)
        areaRooms[target] = room.isEmpty ? nil : room
        guard task(target)?.isArea == true, !terminating else { return }
        if completed, let reply = run.handoffOutput, !reply.isEmpty {
            var message = ChatMessage(role: .assistant, text: reply)
            message.speakerBotID = run.targetBotID
            append(message, to: target)
            saveThread(target)
            if visibleBotID != target.botID || tab(of: target.botID) != target { unread.insert(target) }
            let said = messages.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n\n")
            startTurns(mentionedIn: said, by: run.targetBotID, hop: turn.hop, in: target)
        }
        if let next { startCameoTurn(next, in: target) }
    }

    /// Where what a cameo bot's notes became waits for its next turn in the area: a key of its own,
    /// apart from the area's own bot's.
    static func cameoMemoryKey(_ botID: UUID, in target: ChatTarget) -> ChatTarget { ChatTarget(botID: botID, taskID: target.taskID) }

    /// Changes `botID`'s session slot in the area `target` (`BotTask.cameos`), saving it when it changed.
    func changeCameo(_ target: ChatTarget, of botID: UUID, _ edit: (inout Bot) -> Void) {
        guard let i = taskIndex(target), var area = tasks[target.botID]?[i], area.isArea, let bot = bot(botID) else { return }
        var settings = bot.cameo(in: area)
        let before = CameoSession(settings)
        edit(&settings)
        let after = CameoSession(settings)
        guard after != before else { return }
        area.setCameoSession(after, of: botID)
        tasks[target.botID]?[i] = area
        saveTask(area, of: target.botID)
    }

    /// The names of the bots, for a recap of an area conversation (`TurnVoices`).
    func turnVoices(for speaker: UUID, in target: ChatTarget) -> TurnVoices? {
        guard task(target)?.isArea == true else { return nil }
        return TurnVoices(me: speaker, owner: target.botID, names: Dictionary(bots.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }
}

/// The area's own bot's turn starting or running in an area, and the owner's message it started with.
struct AreaSpeaker {
    var turn: AreaTurn
    var message: UUID?
}
