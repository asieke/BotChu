import Foundation
import Testing
@testable import BotChuCore

/// `@mention` cameo turns in Project Areas (#399 decision 8, #406): who answers the owner's
/// message, which turns a reply starts (hop cap, bots already running or waiting), the cameo's
/// session slot, its context, and how its messages name it.
@Suite struct CameoRoutingTests {
    let fox = Bot(name: "Product Fox", emoji: "🦊", accountID: "codex-work", model: "gpt-6-luna", workspace: "/Users/a/BOTS/product-fox")
    let tenX = Bot(name: "10x Engineer Bot", emoji: "🛠️", accountID: "claude-work", model: "opus", reasoningEffort: .high,
                   workspace: "/Users/a/BOTS/10x")
    let duck = Bot(name: "QA Duck", emoji: "🦆", accountID: "claude-personal", model: "sonnet", workspace: "/Users/a/BOTS/qa-duck")
    let qa = Bot(name: "QA", emoji: "❓", accountID: "claude-personal", model: "", workspace: "/Users/a/BOTS/qa")

    var directory: MentionDirectory { MentionDirectory(agents: [fox, tenX, duck, qa].map(BotRosterEntry.init)) }

    func reference(_ bot: Bot, in text: String) -> MessageReference {
        let location = (text as NSString).range(of: "@" + bot.name).location
        return .agent(BotRosterEntry(bot: bot), at: location)
    }

    @Test func theBotsChosenWithAtAnswerInMentionOrderAndTheOwnerOnlyWhenChosenOrNoneIs() {
        let eligible: Set<UUID> = [fox.id, tenX.id, duck.id]
        let text = "@10x Engineer Bot solve #86"
        // Fox's area: 10x answers, Fox doesn't.
        #expect(CameoRouting.answerers(of: [reference(tenX, in: text)], owner: fox.id, eligible: eligible) == [tenX.id])
        let both = "@QA Duck then @10x Engineer Bot, and @QA Duck again"
        #expect(CameoRouting.answerers(of: [reference(tenX, in: both), reference(duck, in: both)], owner: fox.id, eligible: eligible)
                == [duck.id, tenX.id])
        let withOwner = "@10x Engineer Bot and @Product Fox"
        #expect(CameoRouting.answerers(of: [reference(fox, in: withOwner), reference(tenX, in: withOwner)], owner: fox.id,
                                       eligible: eligible) == [tenX.id, fox.id])
        #expect(CameoRouting.answerers(of: [], owner: fox.id, eligible: eligible) == [fox.id])
        // Only bots that can take a turn (a remote queue bot, a deleted one, a project) choose anyone.
        let project = MessageReference(kind: .project, target: "asieke/BotChu", label: "#asieke/BotChu")
        #expect(CameoRouting.answerers(of: [reference(qa, in: "@QA"), project], owner: fox.id, eligible: eligible) == [fox.id])
    }

    @Test func aReplyGivesEachBotItMentionsOneTurnOneHopOnUntilHopTwo() {
        // 10x answers the owner (hop 0), mentions QA Duck: one QA Duck turn at hop 1.
        let fromTenX = CameoRouting.turns(after: "Done in #412. @QA Duck please verify; @qa-duck, see the PR.", by: tenX.id, hop: 0,
                                          directory: directory, busy: [])
        #expect(fromTenX == [AreaTurn(botID: duck.id, hop: 1, mentionedBy: tenX.id)])
        // Its `@Product Fox` gives Fox (the area's own bot) a turn at hop 2.
        let fromDuck = CameoRouting.turns(after: "Verified. @Product Fox, it's ready.", by: duck.id, hop: 1, directory: directory, busy: [])
        #expect(fromDuck == [AreaTurn(botID: fox.id, hop: 2, mentionedBy: duck.id)])
        // A mention in Fox's hop-2 reply starts nothing.
        #expect(CameoRouting.turns(after: "Thanks @10x Engineer Bot and @QA Duck", by: fox.id, hop: 2, directory: directory, busy: []).isEmpty)
        // In order of first mention, each once.
        let many = CameoRouting.turns(after: "@QA Duck and @10x-engineer-bot, then @QA Duck", by: fox.id, hop: 0, directory: directory, busy: [])
        #expect(many.map(\.botID) == [duck.id, tenX.id] && many.allSatisfy { $0.hop == 1 })
    }

    @Test func aBotAlreadyRunningOrWaitingInTheConversationGetsNoTurn() {
        // The speaker mentioning itself, or a bot already waiting, starts nothing.
        #expect(CameoRouting.turns(after: "I, @10x Engineer Bot, will ask @QA Duck", by: tenX.id, hop: 0, directory: directory,
                                   busy: [duck.id]).isEmpty)
        #expect(CameoRouting.turns(after: "@QA Duck @Product Fox", by: tenX.id, hop: 0, directory: directory, busy: [duck.id])
                == [AreaTurn(botID: fox.id, hop: 1, mentionedBy: tenX.id)])
    }

    @Test func mentionsInARepliesTextMatchTheLongestNameAtAWordsEndOutsideCode() {
        let found = { (text: String) in self.directory.agentsMentioned(in: text).map(\.name) }
        #expect(found("@QA Duck, look") == ["QA Duck"])
        #expect(found("@qa look") == ["QA"])
        #expect(found("@qa-duck: look, and @PRODUCT FOX too") == ["QA Duck", "Product Fox"])
        #expect(found("@QA Ducks") == ["QA"])
        #expect(found("mail fox@product fox.com or @Product Foxes").isEmpty)
        #expect(found("`@QA Duck` in code, and\n```\n@Product Fox\n```\n").isEmpty)
        #expect(found("no mention here").isEmpty)
        #expect(MentionDirectory().agentsMentioned(in: "@QA Duck").isEmpty)
    }

    @Test func aCameoRunsOnItsOwnSettingsWithTheAreasSlotForIt() throws {
        var area = BotTask(repoArea: "asieke/protagonist-v2", checkout: "/w/protagonist-v2", for: fox)
        area.sessionID = "fox-session"
        area.sessionAccountID = "codex-work"
        let first = tenX.cameo(in: area)
        #expect(first.accountID == "claude-work" && first.model == "opus" && first.reasoningEffort == .high)
        #expect(first.sessionID == nil && first.resumableSessionID == nil)
        var turn = first
        turn.sessionID = "10x-session"
        turn.sessionAccountID = "claude-work"
        area.setCameoSession(CameoSession(turn), of: tenX.id)
        #expect(tenX.cameo(in: area).resumableSessionID == "10x-session")
        #expect(area.sessionID == "fox-session" && duck.cameo(in: area).sessionID == nil)
        // Saved and read again; an area saved before cameos reads as having none.
        let decoded = try JSONDecoder().decode(BotTask.self, from: JSONEncoder().encode(area))
        #expect(decoded.cameoSession(of: tenX.id)?.sessionID == "10x-session")
        var old = BotTask(repoArea: "asieke/BotChu", checkout: "/w/BotChu", for: fox)
        old.cameos = nil
        let oldJSON = try #require(String(data: JSONEncoder().encode(old), encoding: .utf8))
        #expect(!oldJSON.contains("cameos"))
        #expect(try JSONDecoder().decode(BotTask.self, from: Data(oldJSON.utf8)).cameos == nil)
        area.setCameoSession(nil, of: tenX.id)
        #expect(area.cameos == nil)
    }

    @Test func aCameoTurnsMessagesNameItsBotAndOlderThreadsReadAsBefore() throws {
        var assembler = ThreadAssembler(speaker: tenX.id)
        var messages: [ChatMessage] = []
        for event: AgentEvent in [.textDelta("On it."), .toolStarted(id: "t1", name: "Bash", input: "gh issue view 86"),
                                  .toolFinished(id: "t1", name: "Bash", output: "ok", isError: false), .text("Done."), .failed("boom")] {
            assembler.apply(event, to: &messages)
        }
        #expect(messages.count == 4 && messages.allSatisfy { $0.speakerBotID == tenX.id })
        var own = ThreadAssembler()
        var ownMessages: [ChatMessage] = []
        own.apply(.text("Mine."), to: &ownMessages)
        #expect(ownMessages.first?.speakerBotID == nil)
        let stream = TurnStream(account: Accounts.account(id: "claude-work"), invocation: Invocation(arguments: []), speaker: tenX.id)
        #expect(stream.endNote(status: 1, stderr: "", stopped: false, byOwner: false, lingered: false)?.speakerBotID == tenX.id)
        let legacy = #"{"id":"\#(UUID().uuidString)","role":"assistant","text":"hi","date":0}"#
        #expect(try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8)).speakerBotID == nil)
    }

    @Test func eachSpeakersRunOfTheTranscriptStartsWithItsAvatarAndGroupsApart() {
        func read(_ path: String, by speaker: UUID? = nil) -> ChatMessage {
            var call = ChatMessage(role: .tool, toolName: "Read", toolInput: "/r/\(path)", toolState: .done)
            call.speakerBotID = speaker
            return call
        }
        var cameoReply = ChatMessage(role: .assistant, text: "Checked.")
        cameoReply.speakerBotID = duck.id
        let messages = [ChatMessage(role: .user, text: "@QA Duck look"), read("a.swift"), read("b.swift"),
                        read("c.swift", by: duck.id), read("d.swift", by: duck.id), cameoReply]
        var transcript = ActivityTranscript(root: "/r")
        transcript.update(messages)
        let items = Array(transcript.items)
        #expect(items.count == 4)
        #expect(items.map(\.speaker) == [nil, nil, duck.id, duck.id])
        #expect(items[1].startsBotTurn(after: items[0]) && items[2].startsBotTurn(after: items[1]))
        #expect(!items[3].startsBotTurn(after: items[2]))
    }

    @Test func aResumedSessionHearsWhatOtherBotsSaidSinceItsLastTurn() throws {
        func reply(_ text: String, by bot: Bot?) -> ChatMessage {
            var message = ChatMessage(role: .assistant, text: text)
            message.speakerBotID = bot?.id
            return message
        }
        let names = Dictionary(uniqueKeysWithValues: [fox, tenX, duck].map { ($0.id, $0.name) })
        let owner2 = ChatMessage(role: .user, text: "@10x Engineer Bot solve #86")
        let thread = [ChatMessage(role: .user, text: "hello"), reply("Hi, Fox here.", by: nil), owner2,
                      reply("Fixed in #412. @QA Duck verify", by: tenX), ChatMessage(role: .user, text: "thanks")]
        // Fox, resumed for the owner's "thanks": the owner's message to 10x and 10x's reply.
        let forFox = try #require(CameoRouting.since(lastTurnOf: fox.id, owner: fox.id, in: thread, excluding: thread[4].id, names: names))
        #expect(forFox.contains("Owner: @10x Engineer Bot solve #86") && forFox.contains("10x Engineer Bot: Fixed in #412."))
        #expect(!forFox.contains("thanks") && !forFox.contains("Hi, Fox here"))
        // QA Duck, mentioned: everything (it never took a turn), Fox's replies by name.
        let forDuck = try #require(CameoRouting.since(lastTurnOf: duck.id, owner: fox.id, in: Array(thread.prefix(4)), excluding: nil, names: names))
        #expect(forDuck.contains("Product Fox: Hi, Fox here.") && forDuck.contains("10x Engineer Bot: Fixed"))
        // Nothing said by another bot since: nothing to hear (an area of one bot is unchanged).
        let plain = [ChatMessage(role: .user, text: "a"), reply("b", by: nil), ChatMessage(role: .user, text: "c")]
        #expect(CameoRouting.since(lastTurnOf: fox.id, owner: fox.id, in: plain, excluding: plain[2].id, names: names) == nil)
        // A new session's recap names who wrote each reply.
        let recap = BotContext.recap(thread, voices: TurnVoices(me: tenX.id, owner: fox.id, names: names))
        #expect(recap.contains("Product Fox: Hi, Fox here.") && recap.contains("You: Fixed in #412."))
        #expect(BotContext.recap(thread).contains("You: Hi, Fox here."))
    }

    @Test func aCameoIsToldItsIdentityWhoseAreaItIsAndToLeaveTheAreaAsItIs() {
        let area = BotTask(repoArea: "asieke/protagonist-v2", checkout: "/w/protagonist-v2", for: fox)
        let preamble = BotContext.cameoPreamble(bot: tenX, owner: fox, area: area, memory: "- 10x lesson", sharedMemory: "",
                                                history: [], instructions: "Ship it.")
        #expect(preamble.contains("You are 10x Engineer Bot, a persistent bot in BotChu, taking a turn in Product Fox's Project Area “protagonist-v2” at /w/protagonist-v2"))
        #expect(preamble.contains("- 10x lesson") && preamble.contains("Ship it."))
        #expect(preamble.contains("/Users/a/BOTS/10x/MEMORY.md"))
        #expect(preamble.contains("never switch a branch, edit or commit in it"))
        #expect(preamble.contains("/w/protagonist-v2/.claude/worktrees/<type>-<slug>"))
        #expect(preamble.contains("`@<bot name>` in your reply gives that bot a turn here after yours"))
        #expect(preamble.contains("/Users/a/BOTS/product-fox/.botchu/tasks/\(area.id.uuidString.lowercased())/thread.jsonl"))
        let folder = BotTask(folderArea: "Notes", folder: "/x/notes", for: fox)
        let folderPreamble = BotContext.cameoPreamble(bot: tenX, owner: fox, area: folder, memory: "", sharedMemory: "", history: [])
        #expect(folderPreamble.contains("You are in /x/notes, the folder of Product Fox's area, which isn't yours: read it, but never change its files."))
        // The area's own bot hears that others take turns too.
        let own = BotContext.taskPreamble(bot: fox, task: area, memory: "", sharedMemory: "", history: [])
        #expect(own.contains("`@<bot name>` in your reply gives that bot a turn here after yours"))
        #expect(CameoRouting.prompt(mentionedBy: "QA Duck").hasPrefix("QA Duck mentioned you in this conversation"))
        #expect(CameoRouting.prompt(mentionedBy: nil).hasPrefix("Your owner mentioned you"))
    }
}
