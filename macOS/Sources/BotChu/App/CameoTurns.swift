import Foundation
import BotChuCore

/// `@mention` cameo turns in Project Areas (#399 decision 8, #406): who answers a message there,
/// whose turn runs, on which settings and session slot, and which turns a reply starts
/// (`CameoRouting`). Turns in one conversation stay sequential; Home is unchanged.
extension AppModel {
    /// The bot taking a cameo turn in the conversation now, which the chat shows working.
    func cameoSpeaker(of target: ChatTarget) -> Bot? { cameoTurns[target].flatMap(bot) }

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

    /// `turn` starts in the area `target`, with `message` when the owner's message starts it.
    func beginAreaTurn(_ turn: AreaTurn, message: UUID?, in target: ChatTarget) {
        areaSpeakers[target] = AreaSpeaker(turn: turn, message: message)
        let cameo = turn.botID == target.botID ? nil : turn.botID
        if cameoTurns[target] != cameo { cameoTurns[target] = cameo }
    }

    /// The area turn running in `target` ended. When it went on to its end (`continues`), the bots
    /// its reply mentions get their turns after those waiting; otherwise none waiting starts.
    func endAreaTurn(_ target: ChatTarget, reply: [ChatMessage], continues: Bool) {
        guard let speaker = areaSpeakers.removeValue(forKey: target) else { return }
        if cameoTurns[target] != nil { cameoTurns[target] = nil }
        guard continues else {
            areaTurns[target] = nil
            return
        }
        let text = reply.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n\n")
        let directory = MentionDirectory(agents: bots.filter { !$0.isRemoteQueue }.map(BotRosterEntry.init))
        let waiting = areaTurns[target] ?? []
        let more = CameoRouting.turns(after: text, by: speaker.turn.botID, hop: speaker.turn.hop, directory: directory,
                                      busy: Set(waiting.map(\.botID)))
        if !more.isEmpty { areaTurns[target] = waiting + more }
    }

    /// The settings of the cameo turn starting or running in `target`: its bot's own, with the
    /// area's session slot for it; nil for any other turn.
    func cameoSettings(of target: ChatTarget) -> Bot? {
        guard let turn = areaSpeakers[target]?.turn, turn.botID != target.botID, let area = task(target), area.isArea,
              let bot = bot(turn.botID) else { return nil }
        return bot.cameo(in: area)
    }

    /// What the turn starting in `target` runs on: a cameo's settings, else the conversation's.
    func turnSettings(of target: ChatTarget) -> (any RunSettings)? { cameoSettings(of: target) ?? runSettings(of: target) }

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

/// Whose turn is starting or running in an area, and the owner's message it started with.
struct AreaSpeaker {
    var turn: AreaTurn
    var message: UUID?
}
