import Foundation
import Testing
@testable import BotChuCore

/// #114: choosing a BotChu bot with `@`, a repository with `#`, and asking for a task with `/task`
/// from Telegram. The gateway's handling of these is in `TelegramTests`.
struct TelegramSelectionTests {
    let danny = BotRosterEntry(bot: Bot(id: UUID(uuidString: "DA000000-0000-4000-8000-000000000001")!, name: "Danny", emoji: "🧭",
                                        title: "COO", workspace: "/tmp/danny"))
    let duck = BotRosterEntry(bot: Bot(id: UUID(uuidString: "D0C00000-0000-4000-8000-000000000002")!, name: "QA Duck", emoji: "🦆",
                                       title: "A Duck that QAs", workspace: "/tmp/duck"))
    let qa = BotRosterEntry(bot: Bot(id: UUID(uuidString: "0A000000-0000-4000-8000-000000000003")!, name: "QA", title: "Checks",
                                     workspace: "/tmp/qa"))
    let botchu = ProjectCatalogEntry(name: "BotChu", repo: "asieke/BotChu", status: .active)
    let gitchu = ProjectCatalogEntry(name: "GitChu", repo: "asieke/GitChu", status: .paused)
    let ranch = ProjectCatalogEntry(name: "Ranch Treasurer", repo: "asieke/ranch-treasurer", status: .active)

    var directory: TelegramDirectory { TelegramDirectory(bots: [danny, duck, qa], projects: [botchu, gitchu, ranch], login: "asieke") }

    func parse(_ text: String, in directory: TelegramDirectory? = nil) -> TelegramAddress? {
        try? TelegramAddress.parse(text, in: directory ?? self.directory, username: "chu_bot").get()
    }

    func problem(_ text: String, in directory: TelegramDirectory? = nil) -> String? {
        guard case .failure(let problem) = TelegramAddress.parse(text, in: directory ?? self.directory, username: "chu_bot") else { return nil }
        return problem.message
    }

    @Test func addressWordsNameABotByItsWholeNameAndARepositoryByOwnerAndName() {
        #expect(parse("@Danny fix the login bug") == TelegramAddress(bot: danny, body: "fix the login bug"))
        #expect(parse("  @danny: can you look?") == TelegramAddress(bot: danny, body: "can you look?"))
        // The longest name that matches wins: "QA Duck" over "QA".
        #expect(parse("@QA Duck check this")?.bot == duck)
        #expect(parse("@QA check this")?.bot == qa)
        #expect(parse("@qa duck")?.bot == duck)
        // In any order, each once, and the repository as the catalog writes it.
        #expect(parse("#asieke/botchu @Danny /task Fix the login bug")
            == TelegramAddress(bot: danny, repo: "asieke/BotChu", isTask: true, body: "Fix the login bug"))
        #expect(parse("/task@chu_bot #GitChu, rename the sync") == TelegramAddress(repo: "asieke/GitChu", isTask: true, body: "rename the sync"))
        // Telegram's own `@chu_bot`, from a message written in inline mode, is left out.
        #expect(parse("@chu_bot @Danny hi") == TelegramAddress(bot: danny, body: "hi"))
        #expect(parse("@chu_bot hello") == TelegramAddress(body: "hello"))
        // Choosing alone: nothing to send.
        #expect(parse("@Danny #asieke/BotChu")?.isSelection == true)
        #expect(parse("@Danny")?.isSelection == true)
        #expect(parse("/task @Danny")?.isSelection == false)
    }

    @Test func plainMessagesHashtagsAndLaterMentionsStayText() {
        #expect(parse("hello @Danny") == TelegramAddress(body: "hello @Danny"))
        #expect(parse("#1 priority today") == TelegramAddress(body: "#1 priority today"))
        #expect(parse("#todo buy milk") == TelegramAddress(body: "#todo buy milk"))
        #expect(parse("/tasks please") == TelegramAddress(body: "/tasks please"))
        // A message goes to one bot: a second `@` is the message's text, as is a hashtag after a bot.
        #expect(parse("@Danny @QA Duck please pair on this") == TelegramAddress(bot: danny, body: "@QA Duck please pair on this"))
        #expect(parse("@Danny #todo later") == TelegramAddress(bot: danny, body: "#todo later"))
        #expect(!TelegramAddress.mayAddress("hello"))
        #expect(TelegramAddress.mayAddress(" @Danny hi") && TelegramAddress.mayAddress("#x") && TelegramAddress.mayAddress("/task x"))
        #expect(TelegramAddress.mayAddress("/task@chu_bot x") && !TelegramAddress.mayAddress("/tasks"))
    }

    @Test func unknownDeletedOrAmbiguousTargetsAreRefusedNeverGuessed() throws {
        // Never part of a name: "Dan" is not Danny, and a deleted bot's name matches nothing.
        let unknown = try #require(problem("@Dan please"))
        #expect(unknown.contains("“Dan”") && unknown.contains("wasn't sent") && unknown.contains("Danny, QA Duck, QA"))
        #expect(problem("@Dannyx hi") != nil)
        #expect(problem("@Danny hi", in: TelegramDirectory(bots: [duck], projects: [botchu])) != nil)

        // Two bots of one name: neither is chosen until the ID tells them apart.
        let twin = BotRosterEntry(bot: Bot(id: UUID(uuidString: "DB000000-0000-4000-8000-000000000004")!, name: "danny", title: "Ops",
                                           workspace: "/tmp/twin"))
        let twins = TelegramDirectory(bots: [danny, twin], projects: [botchu])
        let ambiguous = try #require(problem("@Danny hi", in: twins))
        #expect(ambiguous.contains("@Danny [da000000] (COO)") && ambiguous.contains("@danny [db000000] (Ops)"))
        #expect(parse("@Danny [db000000] hi", in: twins) == TelegramAddress(bot: twin, body: "hi"))
        #expect(parse("@Danny [DA000000]", in: twins)?.bot == danny)
        #expect(problem("@Danny [dc000000] hi", in: twins) != nil)
        #expect(twins.word(for: danny) == "@Danny [da000000]")
        #expect(directory.word(for: danny) == "@Danny")

        #expect(try #require(problem("#asieke/Nope fix it")).contains("isn't in your Projects"))
        let forks = TelegramDirectory(bots: [danny], projects: [botchu, ProjectCatalogEntry(name: "BotChu", repo: "fork/BotChu")])
        #expect(try #require(problem("#BotChu fix it", in: forks)).contains("#asieke/BotChu, #fork/BotChu"))
        #expect(parse("#fork/botchu fix it", in: forks)?.repo == "fork/BotChu")
        // Before a catalog is saved, `owner/name` can't be checked, and a bare name is text.
        let unloaded = TelegramDirectory(bots: [danny], projects: nil)
        #expect(try #require(problem("#asieke/BotChu fix it", in: unloaded)).contains("hasn't loaded your Projects"))
        #expect(parse("#BotChu fix it", in: unloaded) == TelegramAddress(body: "#BotChu fix it"))
    }

    @Test func inlineSuggestionsKeepBotsAndRepositoriesApartAndFilterAsTyped() {
        func answer(_ query: String, in directory: TelegramDirectory? = nil, current: UUID? = nil) -> TelegramSuggestions {
            TelegramSuggestions.answer(query, in: directory ?? self.directory, username: "chu_bot", current: current)
        }
        // Nothing typed yet, or `@`: every bot, in the sidebar's order, and no repository.
        #expect(answer("").items.map(\.message) == ["@Danny", "@QA Duck", "@QA"])
        #expect(answer("@").items.map(\.message) == ["@Danny", "@QA Duck", "@QA"])
        // Filtered by name or title as typed; the `@` is optional, since `@chu_bot` was one.
        #expect(answer("@qa").items.map(\.message) == ["@QA", "@QA Duck"])
        #expect(answer("dan").items.map(\.message) == ["@Danny"])
        #expect(answer("@QA D").items.map(\.message) == ["@QA Duck"])
        #expect(answer("@coo").items.map(\.message) == ["@Danny"])
        let first = answer("@dan").items.first
        #expect(first == TelegramSuggestions.Item(title: "🧭 Danny", description: "COO", message: "@Danny"))
        // `#`: repositories only, as `owner/name`.
        #expect(answer("#").items.map(\.title) == ["asieke/BotChu", "asieke/ranch-treasurer", "asieke/GitChu"])
        #expect(answer("#bot").items.map(\.message) == ["#asieke/BotChu"])
        #expect(answer("#asieke/ranch").items.map(\.title) == ["asieke/ranch-treasurer"])
        #expect(answer("#ranch").items.first?.description == "Ranch Treasurer · active · This Mac")
        #expect(answer("#bot").items.allSatisfy { !$0.message.contains("@") })
        #expect(answer("@dan").items.allSatisfy { !$0.message.contains("#") })
        // Both in one choice: what's chosen before the word being typed goes with it.
        #expect(answer("@Danny #bo").items.map(\.message) == ["@Danny #asieke/BotChu"])
        #expect(answer("#asieke/GitChu @qa d").items.map(\.message) == ["@QA Duck #asieke/GitChu"])
        // Another bot replaces the one chosen before it.
        #expect(answer("@Danny @qa d").items.map(\.message) == ["@QA Duck"])
        // A draft is never offered a list, since choosing would send and lose it.
        #expect(answer("@Danny please fix the login bug on the settings page").items.isEmpty)
        #expect(answer("@Danny /task fix #bo").items.isEmpty)
        #expect(answer("/task #bo").items.isEmpty)
        // Empty lists say why.
        #expect(answer("@zed").note == "No bot is called “zed”")
        #expect(answer("#zed").note == "No repository matches “zed”")
        #expect(answer("#", in: TelegramDirectory(bots: [danny], projects: nil)).note == "Projects aren’t loaded in BotChu yet")
        #expect(answer("@", in: TelegramDirectory()).note == "BotChu has no bots yet")
        // The bot the chat talks to now says so.
        #expect(answer("", current: duck.id).items[1].description == "A Duck that QAs · talking to it now")
    }

    @Test func aChosenSuggestionNamesExactlyWhatItShowed() {
        let twin = BotRosterEntry(bot: Bot(id: UUID(uuidString: "DB000000-0000-4000-8000-000000000004")!, name: "Danny", title: "COO",
                                           workspace: "/tmp/twin"))
        let twins = TelegramDirectory(bots: [danny, twin, duck], projects: [botchu, gitchu])
        let bots = TelegramSuggestions.answer("dan", in: twins, username: "chu_bot", current: nil).items
        #expect(bots.map(\.description) == ["COO · ID da000000", "COO · ID db000000"])
        #expect(bots.map(\.message) == ["@Danny [da000000]", "@Danny [db000000]"])
        for (item, bot) in zip(bots, [danny, twin]) {
            let chosen = try? TelegramAddress.parse(item.message, in: twins, username: "chu_bot").get()
            #expect(chosen?.bot?.id == bot.id && chosen?.isSelection == true)
        }
        for item in TelegramSuggestions.answer("@Danny [db000000] #", in: twins, username: "chu_bot", current: nil).items {
            let chosen = try? TelegramAddress.parse(item.message, in: twins, username: "chu_bot").get()
            #expect(chosen?.bot?.id == twin.id && chosen?.repo == item.title && chosen?.isSelection == true)
        }
    }

    @Test func savedStateFromBeforeChoicesLoadsAndChoicesSurviveARelaunch() throws {
        let bot = UUID(), message = UUID()
        // telegram.json as #60 wrote it: no choices, and a reply's bot was the chat's bot in Settings.
        let old = #"{"botUserID":123,"offset":11,"pending":[{"id":"\#(message)","botID":"\#(bot)","chat":42,"replyTo":7,"sent":1}]}"#
        let state = try JSONDecoder().decode(TelegramState.self, from: Data(old.utf8))
        #expect(state.pending == [TelegramPendingReply(id: message, botID: bot, chat: 42, replyTo: 7, sent: 1)])
        #expect(state.pending.first?.mapped == bot)
        #expect(state.selections.isEmpty && state.offset == 11)

        // A chat with no bot in Settings that chose one: nil stays nil.
        let chosen = TelegramState(botUserID: 123, offset: 12,
                                   pending: [TelegramPendingReply(id: message, botID: bot, chat: 42, replyTo: 7, mapped: nil)],
                                   selections: [TelegramSelection(chat: 42, mapped: nil, botID: bot, botName: "Danny", repo: "asieke/BotChu")])
        let decoded = try JSONDecoder().decode(TelegramState.self, from: JSONEncoder().encode(chosen))
        #expect(decoded == chosen)
        #expect(decoded.pending.first?.mapped == nil)
        #expect(decoded.selections.first?.recipient == bot)
    }
}
