import Foundation
import Testing
@testable import BotChuCore

@Suite struct TelegramTests {
    static let token = "123:AAFakeTokenForTestsOnly_x-y"
    static let fast: TelegramGateway.Timing = {
        var timing = TelegramGateway.Timing()
        timing.replyInterval = 0.005
        timing.sendAttempts = 3
        return timing
    }()

    @Test func anAllowedChatsTextRunsInItsBotsHomeAndTheReplyGoesBack() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "hello", message: 7)]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        let id = TelegramInbound.messageID(bot: 123, chat: 42, message: 7)
        #expect(await app.delivered == [.init(id: id, text: "hello", bot: bot)])
        #expect(await gateway.savedState.offset == 11)
        #expect(await gateway.savedState.pending == [TelegramPendingReply(id: id, botID: bot, chat: 42, replyTo: 7)])
        #expect(await TelegramState.load(from: folder.state) == gateway.savedState)
        #expect(await telegram.offsets == [nil])

        try await gateway.flushReplies()
        #expect(await telegram.typings == [42])
        #expect(await telegram.sent.isEmpty)
        await app.finishTurn(of: bot, with: [ChatMessage(role: .tool, toolName: "Read"), ChatMessage(role: .assistant, text: "Hi! All good.")])
        try await gateway.flushReplies()
        #expect(await telegram.sent == [Sent(chat: 42, text: "Hi! All good.", replyTo: 7)])
        #expect(await gateway.savedState.pending.isEmpty)
        #expect(TelegramState.load(from: folder.state).pending.isEmpty)

        // The token goes into the address alone: no body, saved state or status holds it.
        let requests = await telegram.requests
        #expect(requests.allSatisfy { $0.url.hasPrefix("https://api.telegram.org/bot\(Self.token)/") })
        #expect(!requests.contains { String(decoding: $0.body, as: UTF8.self).contains("AAFake") })
        #expect(try !String(contentsOf: folder.state, encoding: .utf8).contains("AAFake"))
        #expect(try !String(contentsOf: folder.state, encoding: .utf8).contains("hello"))
    }

    @Test func strangersGroupsImpostorsAndBotsAreRefusedBeforeAnything() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[
            update(10, chat: 99, text: "hi", first: "Stranger", username: "stranger"),
            // A group the owner allowed by mistake: only private chats can reach a bot.
            update(11, chat: -100, text: "hi everyone", from: 42, type: "group"),
            update(12, chat: 42, text: "pretending", from: 77),
            update(13, chat: 42, text: "beep", isBot: true),
        ]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot), TelegramChat(id: -100, botID: bot)],
                                      app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        #expect(await app.delivered.isEmpty)
        #expect(await telegram.sent.isEmpty)
        #expect(await telegram.typings.isEmpty)
        let refusals = await app.refusals
        #expect(refusals.map(\.id) == [99, -100, 42, 42])
        #expect(refusals.first == TelegramRefusal(id: 99, name: "Stranger (@stranger)", isPrivate: true))
        #expect(refusals[1] == TelegramRefusal(id: -100, name: "Family", isPrivate: false))
        #expect(refusals.dropFirst(2).allSatisfy { !$0.isPrivate })
        #expect(await gateway.savedState.offset == 14)
        #expect(await gateway.savedState.pending.isEmpty)
    }

    @Test func eachChatReachesOnlyItsOwnBotAndRepliesReturnOnlyToIt() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let first = UUID(), second = UUID()
        let app = FakeBotChu(bots: [first: "First", second: "Second"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "for first", message: 1),
                                                  update(11, chat: 43, text: "for second", message: 1)]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: first), TelegramChat(id: 43, botID: second)],
                                      app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        let firstID = TelegramInbound.messageID(bot: 123, chat: 42, message: 1)
        let secondID = TelegramInbound.messageID(bot: 123, chat: 43, message: 1)
        #expect(firstID != secondID)
        #expect(await app.delivered == [.init(id: firstID, text: "for first", bot: first), .init(id: secondID, text: "for second", bot: second)])

        await app.finishTurn(of: first, with: [ChatMessage(role: .assistant, text: "first's reply")])
        // The owner, at the Mac, in the same conversation: that exchange stays in BotChu.
        await app.type("from the Mac", in: first)
        await app.finishTurn(of: first, with: [ChatMessage(role: .assistant, text: "private to the Mac")])
        await app.finishTurn(of: second, with: [ChatMessage(role: .assistant, text: "second's reply")])
        try await gateway.flushReplies()
        #expect(await telegram.sent == [Sent(chat: 42, text: "first's reply", replyTo: 1), Sent(chat: 43, text: "second's reply", replyTo: 1)])
    }

    @Test func unchosenRemovedAndUnsupportedInputsGetAClearAnswerAndNoTurn() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID(), removed = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[
            update(10, chat: 42, text: "/start", message: 1),
            update(11, chat: 42, text: nil, message: 2),
            update(12, chat: 42, text: "hello, edited", message: 3, edited: true),
            update(13, chat: 43, text: "hello", message: 4),
            update(14, chat: 44, text: "hello", message: 5),
            update(15, chat: 42, text: "/help@chu_bot", message: 6),
        ]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot), TelegramChat(id: 43), TelegramChat(id: 44, botID: removed)],
                                      app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        let help = TelegramReply.help(botName: "Fixture", chosen: true)
        #expect(help.contains("Fixture's Home"))
        #expect(await telegram.sent == [
            Sent(chat: 42, text: help, replyTo: 1),
            Sent(chat: 42, text: TelegramReply.unsupported(edited: false), replyTo: 2),
            Sent(chat: 42, text: TelegramReply.unsupported(edited: true), replyTo: 3),
            Sent(chat: 43, text: TelegramReply.unrouted, replyTo: 4),
            Sent(chat: 44, text: TelegramReply.unavailable, replyTo: 5),
            Sent(chat: 42, text: help, replyTo: 6),
        ])
        #expect(await app.delivered.isEmpty)
        #expect(await gateway.savedState.pending.isEmpty)
        #expect(await gateway.savedState.offset == 16)

        // A bot deleted after it took a message: the chat hears so, and nothing more is owed.
        await telegram.add([update(16, chat: 42, text: "still there?", message: 7)])
        try await gateway.poll()
        #expect(await gateway.savedState.pending.count == 1)
        await app.remove(bot)
        try await gateway.flushReplies()
        #expect(await telegram.sent.last == Sent(chat: 42, text: TelegramReply.unavailable, replyTo: 7))
        #expect(await gateway.savedState.pending.isEmpty)
    }

    @Test func aBusyConversationQueuesMessagesAndAnswersEachInTurn() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let clock = TestClock()
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "first", message: 1), update(11, chat: 42, text: "second", message: 2)]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast, now: { clock.now })
        try await gateway.poll()
        #expect(await app.threadTexts(bot) == ["first"])
        #expect(await app.queuedTexts(bot) == ["second"])
        #expect(await telegram.sent == [Sent(chat: 42, text: TelegramReply.busy("Fixture"), replyTo: 2)])

        try await gateway.flushReplies()
        try await gateway.flushReplies()
        // "typing…" lasts five seconds: it isn't sent again sooner.
        #expect(await telegram.typings == [42])
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "one")])
        clock.advance(5)
        try await gateway.flushReplies()
        #expect(await telegram.sent.last == Sent(chat: 42, text: "one", replyTo: 1))
        #expect(await telegram.typings == [42, 42])
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "two")])
        try await gateway.flushReplies()
        #expect(await telegram.sent.last == Sent(chat: 42, text: "two", replyTo: 2))
        #expect(await gateway.savedState.pending.isEmpty)

        // A queue paused after Stop or a failure: the chat is told once, and the reply still comes.
        await app.type("at the Mac", in: bot)
        await telegram.add([update(12, chat: 42, text: "third", message: 3)])
        try await gateway.poll()
        await app.pause(bot)
        try await gateway.flushReplies()
        try await gateway.flushReplies()
        #expect(await telegram.sent.suffix(2) == [Sent(chat: 42, text: TelegramReply.busy("Fixture"), replyTo: 3),
                                                  Sent(chat: 42, text: TelegramReply.paused("Fixture"), replyTo: 3)])
        await app.resume(bot)
        await app.finishTurn(of: bot, with: [])
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "three")])
        try await gateway.flushReplies()
        #expect(await telegram.sent.last == Sent(chat: 42, text: "three", replyTo: 3))
    }

    @Test func updatesTelegramSendsAgainNeverStartASecondTurn() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let hello = update(10, chat: 42, text: "hello", message: 7)
        let telegram = TelegramStandIn(updates: [[hello, hello]])
        let chats = [TelegramChat(id: 42, botID: bot)]
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        #expect(await app.delivered.count == 1)

        // A crash after the message was queued but before the offset and the owed reply were saved:
        // Telegram sends it again after the relaunch.
        try TelegramState(botUserID: 123).save(to: folder.state)
        await telegram.add([hello])
        let relaunched = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await relaunched.poll()
        #expect(await app.delivered.count == 1)
        #expect(await app.threadTexts(bot) == ["hello"])
        let id = TelegramInbound.messageID(bot: 123, chat: 42, message: 7)
        #expect(await relaunched.savedState.pending == [TelegramPendingReply(id: id, botID: bot, chat: 42, replyTo: 7)])
        #expect(await relaunched.savedState.offset == 11)
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "once")])
        try await relaunched.flushReplies()
        #expect(await telegram.sent == [Sent(chat: 42, text: "once", replyTo: 7)])
    }

    @Test func aRelaunchGoesOnFromTheSavedOffsetAndTheRepliesOwed() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let chats = [TelegramChat(id: 42, botID: bot)]
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "write a lot", message: 7)]])
        let before = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await before.poll()
        let long = String(repeating: "word ", count: 600) + "\n\n" + String(repeating: "more ", count: 600)
        let messages = TelegramReply.messages(long)
        #expect(messages.count == 2)
        // BotChu quit after Telegram took the reply's first message.
        var saved = TelegramState.load(from: folder.state)
        saved.pending[0].sent = 1
        try saved.save(to: folder.state)
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: long)])

        let after = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await after.poll()
        #expect(await telegram.offsets == [nil, 11])
        try await after.flushReplies()
        #expect(await telegram.sent == [Sent(chat: 42, text: messages[1], replyTo: nil)])
        #expect(await after.savedState.pending.isEmpty)

        // Another token, for another bot: neither offsets nor replies cross Telegram identities.
        try TelegramState(botUserID: 123, offset: 500, pending: [TelegramPendingReply(id: UUID(), botID: bot, chat: 42, replyTo: 1)]).save(to: folder.state)
        let other = TelegramStandIn(botID: 456)
        let replaced = TelegramGateway(token: "456:AnotherFakeToken", chats: chats, app: app, stateURL: folder.state, transport: other, timing: Self.fast)
        try await replaced.connect()
        #expect(await replaced.savedState.botUserID == 456)
        #expect(await replaced.savedState.offset == nil)
        #expect(await replaced.savedState.pending.isEmpty)
        try await replaced.flushReplies()
        #expect(await other.sent.isEmpty)
        #expect(TelegramState.load(from: folder.state).pending.isEmpty)

        // The chat-to-bot mapping as Settings keeps it.
        let mapping = [TelegramChat(id: 42, botID: bot, label: "Alex (@alex)"), TelegramChat(id: 43)]
        #expect(try JSONDecoder().decode([TelegramChat].self, from: JSONEncoder().encode(mapping)) == mapping)
    }

    @Test func networkFailuresBackOffAndReconnectAndOnlyTheOwnerCanRestartAStop() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn()
        await telegram.script("getMe", .offline(.notConnectedToInternet), .offline(.timedOut))
        await telegram.script("getUpdates", .updates([update(10, chat: 42, text: "back online")]),
                              .http(401, #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#))
        let waits = Waits()
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast, sleep: { seconds in
                                          await waits.record(seconds)
                                          try await Task.sleep(nanoseconds: 1_000_000)
                                      })
        try await withDeadline { await gateway.run() }
        #expect(await waits.longer == [1, 2])
        #expect(await app.delivered.map(\.text) == ["back online"])
        // After a failure, a quick look rather than a long wait.
        #expect(await telegram.timeouts.first == 0)
        let statuses = await app.statuses
        #expect(statuses.first == .connecting)
        #expect(statuses.contains(.retrying(reason: "This Mac is offline.", seconds: 1)))
        #expect(statuses.contains(.retrying(reason: "Telegram didn't answer in time.", seconds: 2)))
        #expect(statuses.contains(.connected("@chu_bot")))
        guard case .stopped(let reason) = statuses.last else { Issue.record("Not stopped: \(statuses)"); return }
        #expect(reason.contains("refused the bot token"))

        // Telegram's own wait is kept to, and another program reading the bot stops the gateway.
        let busy = TelegramStandIn()
        await busy.script("getMe", .http(429, #"{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 3","parameters":{"retry_after":3}}"#))
        await busy.script("getUpdates", .http(409, #"{"ok":false,"error_code":409,"description":"Conflict: terminated by other getUpdates request"}"#))
        let conflicted = FakeBotChu(bots: [bot: "Fixture"])
        let slowed = Waits()
        let second = TelegramGateway(token: Self.token, chats: [], app: conflicted, stateURL: folder.url.appendingPathComponent("other.json"),
                                     transport: busy, timing: Self.fast, sleep: { seconds in
                                         await slowed.record(seconds)
                                         try await Task.sleep(nanoseconds: 1_000_000)
                                     })
        try await withDeadline { await second.run() }
        #expect(await slowed.longer == [3])
        guard case .stopped(let conflict) = await conflicted.statuses.last else { Issue.record("Not stopped"); return }
        #expect(conflict.contains("Another program is reading this bot's messages"))
    }

    @Test func repliesTelegramDoesntTakeAreRetriedBoundedlyThenReported() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let clock = TestClock()
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "one", message: 1)]])
        await telegram.script("sendMessage", .http(502, "<html>Bad Gateway</html>"), .http(500, #"{"ok":false,"error_code":500,"description":"Internal Server Error"}"#),
                              .offline(.timedOut))
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast, now: { clock.now })
        try await gateway.poll()
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "reply one")])
        try await gateway.flushReplies()
        try await gateway.flushReplies()
        #expect(await telegram.sendAttempts == 1)
        clock.advance(5)
        try await gateway.flushReplies()
        #expect(await telegram.sendAttempts == 2)
        clock.advance(10)
        try await gateway.flushReplies()
        #expect(await telegram.sendAttempts == 3)
        let failures = await app.failures
        #expect(failures.count == 1)
        #expect(failures.first?.reason == "Telegram didn't take it after 3 tries. Telegram didn't answer in time.")
        #expect(await gateway.savedState.pending.isEmpty)

        // Refused outright (the owner blocked the bot): reported at once, not tried again.
        await telegram.script("sendMessage", .http(403, #"{"ok":false,"error_code":403,"description":"Forbidden: bot was blocked by the user"}"#))
        await telegram.add([update(11, chat: 42, text: "two", message: 2)])
        try await gateway.poll()
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "reply two")])
        try await gateway.flushReplies()
        #expect(await app.failures.last?.reason == "Telegram refused it: Forbidden: bot was blocked by the user.")
        #expect(await telegram.sendAttempts == 4)

        // A send that timed out may have arrived: it is sent again (at least once), and the reply is done.
        await telegram.script("sendMessage", .offline(.networkConnectionLost))
        await telegram.add([update(12, chat: 42, text: "three", message: 3)])
        try await gateway.poll()
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "reply three")])
        try await gateway.flushReplies()
        clock.advance(5)
        try await gateway.flushReplies()
        #expect(await telegram.sent == [Sent(chat: 42, text: "reply three", replyTo: 3)])
        #expect(await app.failures.count == 2)
        #expect(await gateway.savedState.pending.isEmpty)

        // Offline for longer than the tries allow: a send that can't reach Telegram isn't counted,
        // and waits at most five minutes between tries until it goes.
        await telegram.script("sendMessage", .offline(.notConnectedToInternet), .offline(.notConnectedToInternet), .offline(.cannotFindHost),
                              .offline(.notConnectedToInternet), .offline(.dnsLookupFailed), .offline(.notConnectedToInternet), .offline(.cannotConnectToHost),
                              .http(429, #"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}"#))
        await telegram.add([update(13, chat: 42, text: "four", message: 4)])
        try await gateway.poll()
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "reply four")])
        let tried = await telegram.sendAttempts
        for _ in 0..<9 {
            try await gateway.flushReplies()
            clock.advance(300)
        }
        #expect(await telegram.sendAttempts == tried + 9)
        #expect(await telegram.sent.last == Sent(chat: 42, text: "reply four", replyTo: 4))
        #expect(await app.failures.count == 2)
        #expect(await gateway.savedState.pending.isEmpty)
        #expect(TelegramGateway.backoff(after: 20, base: 5, cap: 300) == 300)
    }

    @Test func aTurnsReplyIsWhatItSaidAndAFailureStaysInBotChu() {
        let message = ChatMessage(role: .user, text: "hello")
        let reply = { (turn: [ChatMessage]) in TelegramReply.compose(after: message.id, in: [message] + turn, botName: "Fixture") }
        #expect(reply([ChatMessage(role: .error, text: "Reconnecting... 1/5"), ChatMessage(role: .assistant, text: " Done. ")]) == "Done.")
        #expect(reply([ChatMessage(role: .assistant, text: "So far"), ChatMessage(role: .error, text: "codex exited with status 1:\nsecret stderr")])
            == "So far\n\n⚠️ Fixture couldn't finish this turn. What went wrong is in BotChu.")
        #expect(reply([ChatMessage(role: .assistant, text: "Partial"), ChatMessage(role: .note, text: "Stopped")]) == "Partial\n\n⏹ Stopped in BotChu.")
        #expect(reply([ChatMessage(role: .tool, toolName: "Bash"), ChatMessage(role: .note, text: "Saved 1 note")])
            == "Fixture finished without a written reply. What it did is in BotChu.")
        #expect(reply([ChatMessage(role: .assistant, text: "A"), ChatMessage(role: .assistant, text: "B"), ChatMessage(role: .user, text: "next"),
                       ChatMessage(role: .assistant, text: "C")]) == "A\n\nB")
        #expect(TelegramReply.compose(after: UUID(), in: [message], botName: "Fixture") == nil)

        let next = ChatMessage(role: .user, text: "next")
        #expect(TelegramProgress.of(message.id, thread: [message], queue: nil, running: true, botName: "Fixture") == .working)
        #expect(TelegramProgress.of(message.id, thread: [message, ChatMessage(role: .assistant, text: "A"), next], queue: nil, running: true,
                                    botName: "Fixture") == .answered("A"))
        var queue = MessageQueue()
        queue.enqueue(message)
        #expect(TelegramProgress.of(message.id, thread: [], queue: queue, running: true, botName: "Fixture") == .queued(paused: false))
        queue.markInFlight(message.id)
        #expect(TelegramProgress.of(message.id, thread: [], queue: queue, running: true, botName: "Fixture") == .working)
        var paused = MessageQueue()
        paused.enqueue(message)
        paused.pause()
        #expect(TelegramProgress.of(message.id, thread: [], queue: paused, running: false, botName: "Fixture") == .queued(paused: true))
        #expect(TelegramProgress.of(message.id, thread: [], queue: MessageQueue(), running: false, botName: "Fixture")
            == .gone(TelegramReply.withdrawn("Fixture")))
    }

    @Test func longRepliesSplitWithinTelegramsLimitWhereTheTextBreaks() {
        #expect(TelegramReply.messages("  short  ") == ["short"])
        #expect(TelegramReply.messages(" \n ").isEmpty)
        let first = String(repeating: "a", count: 3_000), second = String(repeating: "b", count: 3_000)
        #expect(TelegramReply.messages(first + "\n\n" + second) == [first, second])

        let prose = (0..<400).map { "Sentence \($0) of a long reply, with words." + ($0 % 7 == 6 ? "\n\n" : " ") }.joined()
        let pieces = TelegramReply.messages(prose)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.utf16.count <= TelegramReply.limit && !$0.isEmpty })
        #expect(pieces.joined().filter { !$0.isWhitespace } == prose.filter { !$0.isWhitespace })

        // Never inside a character, however many UTF-16 units it takes.
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 1_000)
        let emoji = TelegramReply.messages(family)
        #expect(emoji.count == 3)
        #expect(emoji.allSatisfy { $0.utf16.count <= TelegramReply.limit && $0.allSatisfy { $0 == "👨‍👩‍👧‍👦" } })
        #expect(emoji.joined() == family)

        // A cut at a line keeps the next line's indentation.
        let code = (0..<400).map { "    let value\($0) = \($0)\n" }.joined()
        let lines = TelegramReply.messages(code)
        #expect(lines.count == 3)
        #expect(lines.dropFirst().allSatisfy { $0.hasPrefix("    let value") })

        let huge = TelegramReply.messages(String(repeating: "word ", count: 20_000))
        #expect(huge.count == TelegramReply.maxMessages)
        #expect(huge.allSatisfy { $0.utf16.count <= TelegramReply.limit })
        #expect(huge.last?.hasSuffix("… The rest of this reply is in BotChu.") == true)
    }

    @Test func theTokenNeverAppearsInAnErrorOrStatus() async throws {
        let offline = TelegramStandIn()
        await offline.script("getMe", .offline(.notConnectedToInternet))
        do {
            _ = try await TelegramClient(token: Self.token, transport: offline).me()
            Issue.record("Expected a failure")
        } catch let error as TelegramError {
            #expect(error == TelegramError(kind: .offline, reason: "This Mac is offline."))
        }

        let echoing = TelegramStandIn()
        // Should Telegram ever echo the token (or its secret half), it is cut out of what is shown.
        await echoing.script("getMe", .http(401, #"{"ok":false,"error_code":401,"description":"Rejected bot 123 AAFakeTokenForTestsOnly_x-y"}"#))
        do {
            _ = try await TelegramClient(token: Self.token, transport: echoing).me()
            Issue.record("Expected a failure")
        } catch let error as TelegramError {
            #expect(error.kind == .unauthorized && error.stopsGateway)
            #expect(!error.reason.contains("AAFake"))
            #expect(error.reason.contains("Rejected bot 123 …"))
        }

        // Something that isn't a token never goes into an address.
        let untouched = TelegramStandIn()
        for token in ["", "abc", "123:", ":abc", "123:abc/../../getMe", "12a:abc", "123:abc def"] {
            #expect(!TelegramClient.isPlausibleToken(token))
            await #expect(throws: TelegramError.self) { try await TelegramClient(token: token, transport: untouched).me() }
        }
        #expect(await untouched.requests.isEmpty)
        #expect(TelegramClient.isPlausibleToken(Self.token))
    }

    @Test func messageIDsAreStableAndDistinctPerBotChatAndMessage() {
        let id = TelegramInbound.messageID(bot: 123, chat: 42, message: 7)
        #expect(id == TelegramInbound.messageID(bot: 123, chat: 42, message: 7))
        let others = [TelegramInbound.messageID(bot: 456, chat: 42, message: 7), TelegramInbound.messageID(bot: 123, chat: 43, message: 7),
                      TelegramInbound.messageID(bot: 123, chat: 42, message: 8), TelegramInbound.messageID(bot: 12, chat: 342, message: 7)]
        #expect(Set(others + [id]).count == 5)
        #expect(id.uuidString.dropFirst(14).first == "8")
    }

    @Test func anUpdateThatCantBeReadDoesntHoldUpTheOthers() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[#"{"update_id":10,"message":{"unexpected":true}}"#, #"{"update_id":11,"callback_query":{"id":"x"}}"#,
                                                  update(12, chat: 42, text: "after")]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        #expect(await app.delivered.map(\.text) == ["after"])
        #expect(await app.refusals.isEmpty)
        #expect(await gateway.savedState.offset == 13)
    }

    @Test func forwardedUsersChannelsLegacyOriginsAndViaBotNeverStartATurn() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let metadata: [[String: Any]] = [
            ["forward_origin": ["type": "user", "date": 1_760_000_000,
                                "sender_user": ["id": 99, "is_bot": false, "first_name": "Third party"]]],
            ["forward_origin": ["type": "channel", "date": 1_760_000_000, "message_id": 50,
                                "chat": ["id": -100, "type": "channel", "title": "Announcements"]]],
            ["via_bot": ["id": 456, "is_bot": true, "first_name": "Inline bot"]],
            ["forward_origin": ["type": "unknown_future_origin"]],
            ["forward_from": ["id": 99, "is_bot": false, "first_name": "Third party"]],
            ["forward_from_chat": ["id": -100, "type": "channel"]],
            ["forward_from_message_id": 50], ["forward_signature": "Third party"],
            ["forward_sender_name": "Hidden user"], ["forward_date": 1_760_000_000],
            ["is_automatic_forward": true],
        ]
        let telegram = TelegramStandIn(updates: [metadata.enumerated().map {
            update(Int64(10 + $0.offset), chat: 42, text: $0.offset == 0 ? "/help" : "run third-party instructions", metadata: $0.element)
        }])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram)
        try await gateway.poll()
        #expect(await app.delivered.isEmpty)
        #expect(await gateway.savedState.pending.isEmpty)
        #expect(await telegram.sent.count == metadata.count)
        #expect(await telegram.sent.allSatisfy { $0.chat == 42 && $0.text == TelegramReply.forwarded })
    }

    @Test(arguments: ["removed", "remapped", "unchosen"])
    func savedRepliesAreDiscardedWhenTheirChatNoLongerReachesTheSameBot(change: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let pending = TelegramPendingReply(id: UUID(), botID: bot, chat: 42, replyTo: 7)
        try TelegramState(botUserID: 123, offset: 11, pending: [pending]).save(to: folder.state)
        let app = FakeBotChu(bots: [bot: "Fixture"])
        await app.reportProgress(.answered("private reply"))
        let chats: [TelegramChat] = change == "removed" ? [] : [TelegramChat(id: 42, botID: change == "remapped" ? UUID() : nil)]
        let telegram = TelegramStandIn()
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram)
        try await gateway.connect()
        try await gateway.flushReplies()
        #expect(await app.progressReads == 0)
        #expect(await telegram.sent.isEmpty)
        #expect(await telegram.typings.isEmpty)
        #expect(TelegramState.load(from: folder.state).pending.isEmpty)
    }

    @Test(arguments: [TelegramProgress.answered("private reply"), .working, .queued(paused: true)])
    func revocationDuringAProgressReadStopsRepliesTypingAndNotices(progress: TelegramProgress) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "hello")]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram)
        try await gateway.poll()
        await app.reportProgress(progress)
        let hold = Suspension()
        await app.holdProgress(at: hold)
        let flushing = Task { try await gateway.flushReplies() }
        try await hold.waitUntilEntered()
        await app.authorize([])
        await hold.release()
        try await flushing.value
        #expect(await telegram.sent.isEmpty)
        #expect(await telegram.typings.isEmpty)
        #expect(TelegramState.load(from: folder.state).pending.isEmpty)
    }

    @Test(arguments: ["fetch", "delivery", "accepted"])
    func cancellingAFetchedBatchStopsFurtherDeliveriesAndCheckpointsAcceptedWork(phase: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "first"), update(11, chat: 42, text: "second")]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram)
        let hold = Suspension()
        if phase == "fetch" { await telegram.hold("getUpdates", at: hold) }
        else { await app.holdDelivery(at: hold, after: phase == "accepted") }
        let polling = Task { try await gateway.poll() }
        try await hold.waitUntilEntered()
        polling.cancel()
        await hold.release()
        await #expect(throws: CancellationError.self) { try await polling.value }
        #expect(await app.delivered.map(\.text) == (phase == "accepted" ? ["first"] : []))
        #expect(TelegramState.load(from: folder.state).offset == (phase == "accepted" ? 11 : nil))
        #expect(TelegramState.load(from: folder.state).pending.count == (phase == "accepted" ? 1 : 0))
        #expect(await telegram.sent.isEmpty)
        #expect(await telegram.typings.isEmpty)
    }

    @Test(arguments: ["stopped", "removed", "remapped"])
    func deliveryRevalidatesCurrentSettingsAfterSuspension(change: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "first"), update(11, chat: 42, text: "second")]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram)
        let hold = Suspension()
        await app.holdDelivery(at: hold)
        let polling = Task { try await gateway.poll() }
        try await hold.waitUntilEntered()
        if change == "stopped" { await app.stop() }
        else { await app.authorize(change == "removed" ? [] : [TelegramChat(id: 42, botID: UUID())]) }
        await hold.release()
        await #expect(throws: CancellationError.self) { try await polling.value }
        #expect(await app.delivered.isEmpty)
        #expect(await telegram.sent.isEmpty)
        #expect(TelegramState.load(from: folder.state).offset == nil)
    }

    @Test func savedRepliesWaitForTheTelegramIdentityAndTokenRotationKeepsOnlyThatIdentity() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let pending = TelegramPendingReply(id: UUID(), botID: bot, chat: 42, replyTo: 7)
        try TelegramState(botUserID: 123, offset: 11, pending: [pending]).save(to: folder.state)
        let app = FakeBotChu(bots: [bot: "Fixture"])
        await app.reportProgress(.answered("private reply"))
        let telegram = TelegramStandIn()
        let gateway = TelegramGateway(token: "123:RotatedFakeToken", chats: [TelegramChat(id: 42, botID: bot)], app: app,
                                      stateURL: folder.state, transport: telegram)
        let hold = Suspension()
        await telegram.hold("getMe", at: hold)
        let connecting = Task { try await gateway.connect() }
        try await hold.waitUntilEntered()
        try await gateway.flushReplies()
        #expect(await telegram.sent.isEmpty)
        #expect(await app.progressReads == 0)
        await hold.release()
        _ = try await connecting.value
        #expect(await gateway.savedState.pending == [pending])
        try await gateway.flushReplies()
        #expect(await telegram.sent == [Sent(chat: 42, text: "private reply", replyTo: 7)])
    }

    @Test func admissionCapsPendingWorkAndRateLimitsOverflowNotices() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let clock = TestClock()
        let telegram = TelegramStandIn(updates: [(1...30).map { update(Int64($0), chat: 42, text: "message \($0)") }])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, now: { clock.now })
        try await gateway.poll()
        #expect(await app.delivered.count == 10)
        #expect(await gateway.savedState.pending.count == 10)
        #expect(await telegram.sent.filter { $0.text == TelegramReply.tooManyWaiting }.count == 1)
        clock.advance(59)
        await telegram.add([update(31, chat: 42, text: "still full")])
        try await gateway.poll()
        #expect(await telegram.sent.filter { $0.text == TelegramReply.tooManyWaiting }.count == 1)
        clock.advance(1)
        await telegram.add([update(32, chat: 42, text: "still full")])
        try await gateway.poll()
        #expect(await telegram.sent.filter { $0.text == TelegramReply.tooManyWaiting }.count == 2)
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "first reply")])
        try await gateway.flushReplies()
        await telegram.add([update(33, chat: 42, text: "space again")])
        try await gateway.poll()
        #expect(await app.delivered.count == 11)
        #expect(await app.delivered.last?.text == "space again")
        #expect(await gateway.savedState.pending.count == 10)
    }

    @Test func admissionAlsoHasAGlobalBoundAcrossChats() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let chats = (1...101).map { TelegramChat(id: Int64($0), botID: bot) }
        let telegram = TelegramStandIn(updates: [(1...100).map { update(Int64($0), chat: Int64($0), text: "hello") },
                                                [update(101, chat: 101, text: "one too many")]])
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram)
        try await gateway.poll()
        try await gateway.poll()
        #expect(await app.delivered.count == TelegramGateway.pendingLimit)
        #expect(await gateway.savedState.pending.count == TelegramGateway.pendingLimit)
        #expect(await telegram.sent.last == Sent(chat: 101, text: TelegramReply.tooManyWaiting, replyTo: 101))
    }

    @Test func a429StopsAllRepliesNoticesAndTypingAcrossChatsUntilItsCooldownExpires() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bots = (0..<4).map { _ in UUID() }
        let app = FakeBotChu(bots: Dictionary(uniqueKeysWithValues: bots.map { ($0, "Fixture") }))
        let chats = bots.enumerated().map { TelegramChat(id: Int64(42 + $0.offset), botID: $0.element) }
        let clock = TestClock()
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "first"), update(11, chat: 43, text: "second"),
                                                  update(12, chat: 44, text: "working"), update(13, chat: 45, text: "working"),
                                                  update(14, chat: 45, text: "paused next")]])
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram,
                                      now: { clock.now })
        try await gateway.poll()
        await app.pause(bots[3])
        await app.finishTurn(of: bots[0], with: [ChatMessage(role: .assistant, text: "reply one")])
        await app.finishTurn(of: bots[1], with: [ChatMessage(role: .assistant, text: "reply two")])
        let before = await telegram.sendAttempts
        await telegram.script("sendMessage", .http(429, rateLimit))
        let hold = Suspension()
        await telegram.hold("sendMessage", at: hold)
        let flushing = Task { try await gateway.flushReplies() }
        try await hold.waitUntilEntered()
        // A concurrent help notice cannot start while the reply's 429 response is in flight.
        await telegram.add([update(15, chat: 44, text: "/help")])
        try await gateway.poll()
        #expect(await telegram.sendAttempts == before + 1)
        await hold.release()
        try await flushing.value
        await telegram.add([update(16, chat: 44, text: "/help"), update(17, chat: 44, text: nil), update(18, chat: 44, text: "busy")])
        try await gateway.poll()
        clock.advance(6)
        try await gateway.flushReplies()
        #expect(await telegram.sendAttempts == before + 1)
        #expect(await telegram.typings.isEmpty)
        #expect(await app.failures.isEmpty)
        clock.advance(1)
        try await gateway.flushReplies()
        #expect(await telegram.sent.contains(Sent(chat: 42, text: "reply one", replyTo: 10)))
        #expect(await telegram.sent.contains(Sent(chat: 43, text: "reply two", replyTo: 11)))
        #expect(await telegram.sent.contains(Sent(chat: 45, text: TelegramReply.paused("Fixture"), replyTo: 14)))
        #expect(await telegram.typings == [44, 45])
    }

    @Test(arguments: ["typing", "notice"])
    func a429FromTypingOrANoticeAlsoDelaysReplies(source: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let clock = TestClock()
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "hello")]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, now: { clock.now })
        try await gateway.poll()
        if source == "typing" {
            await telegram.script("sendChatAction", .http(429, rateLimit))
            try await gateway.flushReplies()
        } else {
            await telegram.script("sendMessage", .http(429, rateLimit))
            await telegram.add([update(11, chat: 42, text: "/help")])
            try await gateway.poll()
        }
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "reply")])
        try await gateway.flushReplies()
        #expect(await telegram.sent.isEmpty)
        clock.advance(7)
        try await gateway.flushReplies()
        #expect(await telegram.sent == [Sent(chat: 42, text: "reply", replyTo: 10)])
    }

    @Test(arguments: [false, true])
    func aFailedCheckpointStopsPollingAndRecoversWithoutLosingReplies(relaunch: Bool) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let chats = [TelegramChat(id: 42, botID: bot)]
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let updates = [update(10, chat: 42, text: "first"), update(11, chat: 42, text: "second")]
        let telegram = TelegramStandIn(updates: [updates])
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram,
                                      sleep: { _ in throw CancellationError() })
        try await gateway.connect()
        let checkpoint = try Data(contentsOf: folder.state)
        // A directory in place of the file reliably fails an atomic save, even on hosts whose
        // test user could bypass permissions. Everything is inside this test's temporary folder.
        try FileManager.default.removeItem(at: folder.state)
        try FileManager.default.createDirectory(at: folder.state, withIntermediateDirectories: false)
        for _ in 0..<2 {
            await #expect(throws: TelegramGateway.CheckpointError.self) { try await gateway.poll() }
        }
        #expect(await telegram.offsets == [nil])
        #expect(await app.delivered.map(\.text) == ["first"])
        #expect(await gateway.savedState.pending.count == 1)
        await gateway.run()
        #expect(await app.statuses.contains { if case .retrying(let reason, _) = $0 { return reason == TelegramGateway.saveFailure }; return false })
        #expect(await telegram.offsets == [nil])

        try FileManager.default.removeItem(at: folder.state)
        try checkpoint.write(to: folder.state)
        await telegram.add(updates)
        let recovered = relaunch ? TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram) : gateway
        try await recovered.poll()
        #expect(await telegram.offsets == [nil, relaunch ? nil : 11])
        #expect(await app.delivered.map(\.text) == ["first", "second"])
        #expect(TelegramState.load(from: folder.state).pending.count == 2)
        #expect(TelegramState.load(from: folder.state).offset == 12)
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "one")])
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "two")])
        try await recovered.flushReplies()
        #expect(await telegram.sent.suffix(2).map(\.text) == ["one", "two"])
    }

    @Test func aFailedReplyCheckpointStopsFurtherSendsWithoutConsumingSendRetries() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Fixture"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "write a lot")]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: bot)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        let reply = String(repeating: "a", count: 3_000) + "\n\n" + String(repeating: "b", count: 3_000)
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: reply)])
        let checkpoint = try Data(contentsOf: folder.state)
        let hold = Suspension()
        await telegram.hold("sendMessage", at: hold)
        let flushing = Task { try await gateway.flushReplies() }
        try await hold.waitUntilEntered()
        try FileManager.default.removeItem(at: folder.state)
        try FileManager.default.createDirectory(at: folder.state, withIntermediateDirectories: false)
        await hold.release()
        await #expect(throws: TelegramGateway.CheckpointError.self) { try await flushing.value }
        // More failures than the uncertain-send retry budget still cannot discard the reply.
        for _ in 0...Self.fast.sendAttempts {
            await #expect(throws: TelegramGateway.CheckpointError.self) { try await gateway.flushReplies() }
            await #expect(throws: TelegramGateway.CheckpointError.self) { try await gateway.poll() }
        }
        #expect(await telegram.sendAttempts == 1)
        #expect(await telegram.offsets == [nil])
        #expect(await gateway.savedState.pending.first?.sent == 1)
        #expect(await app.failures.isEmpty)
        try FileManager.default.removeItem(at: folder.state)
        try checkpoint.write(to: folder.state)
        try await gateway.flushReplies()
        #expect(await telegram.sent.map(\.text) == TelegramReply.messages(reply))
        #expect(TelegramState.load(from: folder.state).pending.isEmpty)
    }

    @Test func oneOversizedGraphemeIsReplacedWithoutLosingTheRestOfTheReply() {
        let enormous = "a" + String(repeating: "\u{301}", count: 5_000)
        #expect(enormous.count == 1)
        let pieces = TelegramReply.messages("before " + enormous + " after")
        #expect(pieces.allSatisfy { !$0.isEmpty && $0.utf16.count <= TelegramReply.limit })
        #expect(pieces.contains("�"))
        #expect(pieces.joined().contains("before") && pieces.joined().contains("after"))
        #expect(TelegramReply.messages(enormous) == ["�"])
    }
}

// MARK: Stand-ins

private let rateLimit = #"{"ok":false,"error_code":429,"description":"Too Many Requests","parameters":{"retry_after":7}}"#

/// Deliberately ignores cancellation until released, as a callback already queued on another
/// executor can. Tests control the exact interleaving without network requests or timing races.
private actor Suspension {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation {
            entered = true
            continuation = $0
        }
    }

    func waitUntilEntered() async throws {
        for _ in 0..<500 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// A Telegram update as the Bot API sends it.
private func update(_ id: Int64, chat: Int64, text: String?, message: Int64? = nil, from: Int64? = nil, type: String = "private",
                    isBot: Bool = false, edited: Bool = false, first: String = "Alex", username: String = "alex",
                    metadata: [String: Any] = [:]) -> String {
    var chatObject: [String: Any] = ["id": chat, "type": type]
    if type == "private" {
        chatObject["first_name"] = first
        chatObject["username"] = username
    } else {
        chatObject["title"] = "Family"
    }
    var body: [String: Any] = ["message_id": message ?? id, "date": 1_760_000_000, "chat": chatObject,
                               "from": ["id": from ?? chat, "is_bot": isBot, "first_name": first, "username": username]]
    if let text {
        body["text"] = text
    } else {
        body["photo"] = [["file_id": "file", "file_unique_id": "unique", "width": 90, "height": 90]]
    }
    body.merge(metadata) { _, new in new }
    let object: [String: Any] = ["update_id": id, edited ? "edited_message" : "message": body]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private struct Sent: Equatable {
    let chat: Int64
    let text: String
    let replyTo: Int64?
}

/// Telegram's Bot API, played here: it answers from a script, then with the next batch of updates
/// (or none), and records every request. Nothing leaves the Mac.
private actor TelegramStandIn: TelegramTransport {
    enum Answer {
        case http(Int, String)
        case offline(URLError.Code)
        case updates([String])
    }

    struct Request {
        let method: String
        let url: String
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private(set) var requests: [Request] = []
    private var batches: [[String]]
    private var scripted: [String: [Answer]] = [:]
    private var holds: [String: Suspension] = [:]
    private let botID: Int64

    init(updates batches: [[String]] = [], botID: Int64 = 123) {
        self.batches = batches
        self.botID = botID
    }

    func script(_ method: String, _ answers: Answer...) { scripted[method, default: []] += answers }
    func add(_ batch: [String]) { batches.append(batch) }
    func hold(_ method: String, at suspension: Suspension) { holds[method] = suspension }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.url?.lastPathComponent ?? ""
        requests.append(Request(method: method, url: request.url?.absoluteString ?? "", body: request.httpBody ?? Data()))
        if let hold = holds.removeValue(forKey: method) { await hold.pause() }
        if let answer = scripted[method]?.first {
            scripted[method]?.removeFirst()
            switch answer {
            case .http(let status, let body): return (Data(body.utf8), status)
            case .offline(let code): throw URLError(code, userInfo: [NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString ?? ""])
            case .updates(let updates): return ok("[" + updates.joined(separator: ",") + "]")
            }
        }
        switch method {
        case "getMe": return ok(#"{"id":\#(botID),"is_bot":true,"first_name":"Chu","username":"chu_bot"}"#)
        case "getUpdates": return ok("[" + (batches.isEmpty ? [] : batches.removeFirst()).joined(separator: ",") + "]")
        case "sendMessage":
            let json = requests[requests.count - 1].json
            sent.append(Sent(chat: number(json["chat_id"]) ?? 0, text: json["text"] as? String ?? "",
                             replyTo: number((json["reply_parameters"] as? [String: Any])?["message_id"])))
            return ok(#"{"message_id":\#(1_000 + requests.count),"date":0,"chat":{"id":1,"type":"private"}}"#)
        case "sendChatAction": return ok("true")
        default: return (Data(#"{"ok":false,"error_code":404,"description":"Not Found"}"#.utf8), 404)
        }
    }

    private func ok(_ result: String) -> (Data, Int) { (Data(#"{"ok":true,"result":\#(result)}"#.utf8), 200) }

    private func number(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }

    /// The messages Telegram took: requests it answered with a failure sent nothing.
    private(set) var sent: [Sent] = []

    var sendAttempts: Int { requests.filter { $0.method == "sendMessage" }.count }
    var typings: [Int64] { requests.filter { $0.method == "sendChatAction" }.compactMap { number($0.json["chat_id"]) } }
    var offsets: [Int64?] { requests.filter { $0.method == "getUpdates" }.map { number($0.json["offset"]) } }
    var timeouts: [Int64] { requests.filter { $0.method == "getUpdates" }.compactMap { number($0.json["timeout"]) } }
}

/// BotChu's side, as `AppModel` behaves: one queue per bot's Home, a turn at a time.
private actor FakeBotChu: TelegramApp {
    struct Delivered: Equatable {
        let id: UUID
        let text: String
        let bot: UUID
    }

    private var names: [UUID: String]
    private var threads: [UUID: [ChatMessage]] = [:]
    private var queues: [UUID: MessageQueue] = [:]
    private var running: Set<UUID> = []
    private var chats: [TelegramChat]?
    private var stopped = false
    private var beforeDelivery: Suspension?
    private var afterDelivery: Suspension?
    private var beforeProgress: Suspension?
    private var progressOverride: TelegramProgress?
    private(set) var progressReads = 0
    private(set) var delivered: [Delivered] = []
    private(set) var statuses: [TelegramGateway.Status] = []
    private(set) var refusals: [TelegramRefusal] = []
    private(set) var failures: [(id: UUID, reason: String)] = []

    init(bots: [UUID: String]) { names = bots }

    func name(of botID: UUID) -> String? { names[botID] }

    func authorize(_ chats: [TelegramChat]) { self.chats = chats }
    func stop() { stopped = true }
    func holdDelivery(at suspension: Suspension, after: Bool = false) {
        if after { afterDelivery = suspension } else { beforeDelivery = suspension }
    }
    func holdProgress(at suspension: Suspension) { beforeProgress = suspension }
    func reportProgress(_ progress: TelegramProgress) { progressOverride = progress }

    func authorization(for chat: Int64, botID: UUID?) -> TelegramAuthorization {
        if Task.isCancelled || stopped { return .stopped }
        if let chats {
            guard let allowed = chats.first(where: { $0.id == chat }), allowed.botID == botID else { return .revoked }
        }
        return .allowed
    }

    func deliver(_ text: String, id: UUID, to botID: UUID, from chat: Int64) async -> TelegramDelivery {
        if let hold = beforeDelivery {
            beforeDelivery = nil
            await hold.pause()
        }
        guard case .allowed = authorization(for: chat, botID: botID) else { return .discarded }
        guard names[botID] != nil else { return .unavailable }
        if threads[botID, default: []].contains(where: { $0.id == id }) || queues[botID]?.messages.contains(where: { $0.id == id }) == true {
            return .duplicate
        }
        delivered.append(Delivered(id: id, text: text, bot: botID))
        let result = take(ChatMessage(id: id, role: .user, text: text), in: botID)
        if let hold = afterDelivery {
            afterDelivery = nil
            await hold.pause()
        }
        return result
    }

    func progress(of id: UUID, for botID: UUID) async -> TelegramProgress {
        progressReads += 1
        if let hold = beforeProgress {
            beforeProgress = nil
            await hold.pause()
        }
        if let progressOverride { return progressOverride }
        guard let name = names[botID] else { return .gone(TelegramReply.unavailable) }
        return .of(id, thread: threads[botID] ?? [], queue: queues[botID], running: running.contains(botID), botName: name)
    }

    func replyFailed(_ id: UUID, for botID: UUID, reason: String) { failures.append((id, reason)) }
    func gatewayChanged(_ status: TelegramGateway.Status) { statuses.append(status) }
    func refused(_ chat: TelegramRefusal) { refusals.append(chat) }

    /// The owner typing at the Mac.
    func type(_ text: String, in botID: UUID) { _ = take(ChatMessage(role: .user, text: text), in: botID) }

    @discardableResult
    private func take(_ message: ChatMessage, in botID: UUID) -> TelegramDelivery {
        guard running.contains(botID) || queues[botID]?.messages.isEmpty == false else {
            threads[botID, default: []].append(message)
            running.insert(botID)
            return .queued(busy: false)
        }
        var queue = queues[botID] ?? MessageQueue()
        queue.enqueue(message)
        queues[botID] = queue
        return .queued(busy: running.contains(botID))
    }

    /// The turn under way ends with `messages`; the next queued message starts the next turn.
    func finishTurn(of botID: UUID, with messages: [ChatMessage]) {
        threads[botID, default: []] += messages
        running.remove(botID)
        if var queue = queues[botID], let next = queue.next {
            queue.remove(next.id)
            queues[botID] = queue
            threads[botID, default: []].append(next)
            running.insert(botID)
        }
    }

    func pause(_ botID: UUID) { queues[botID]?.pause() }
    func resume(_ botID: UUID) { queues[botID]?.resume() }
    func remove(_ botID: UUID) { names[botID] = nil }
    func threadTexts(_ botID: UUID) -> [String] { threads[botID, default: []].filter { $0.role == .user }.map(\.text) }
    func queuedTexts(_ botID: UUID) -> [String] { queues[botID]?.messages.map(\.text) ?? [] }
}

private actor Waits {
    private(set) var all: [Double] = []
    func record(_ seconds: Double) { all.append(seconds) }
    /// The gateway's backoffs, without the reply loop's short pauses.
    var longer: [Double] { all.filter { $0 >= 1 } }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(_ seconds: Double) {
        lock.lock()
        date += seconds
        lock.unlock()
    }
}

private struct TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-telegram-\(UUID().uuidString)", isDirectory: true)
    var state: URL { url.appendingPathComponent("telegram.json") }

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Runs `work`, failing the test rather than hanging it when it doesn't end within ten seconds.
private func withDeadline(_ work: @escaping @Sendable () async -> Void) async throws {
    let task = Task { await work() }
    let watchdog = Task {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        task.cancel()
        Issue.record("Timed out")
    }
    await task.value
    watchdog.cancel()
}
