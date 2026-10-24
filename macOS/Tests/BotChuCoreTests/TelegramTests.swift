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

        // Another token, for another bot: its updates are numbered afresh, and replies owed are kept.
        try TelegramState(botUserID: 123, offset: 500, pending: [TelegramPendingReply(id: UUID(), botID: bot, chat: 42, replyTo: 1)]).save(to: folder.state)
        let other = TelegramStandIn(botID: 456)
        let replaced = TelegramGateway(token: "456:AnotherFakeToken", chats: chats, app: app, stateURL: folder.state, transport: other, timing: Self.fast)
        try await replaced.connect()
        #expect(await replaced.savedState.botUserID == 456)
        #expect(await replaced.savedState.offset == nil)
        #expect(await replaced.savedState.pending.count == 1)

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
}

// MARK: Stand-ins

/// A Telegram update as the Bot API sends it.
private func update(_ id: Int64, chat: Int64, text: String?, message: Int64? = nil, from: Int64? = nil, type: String = "private",
                    isBot: Bool = false, edited: Bool = false, first: String = "Alex", username: String = "alex") -> String {
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
    private let botID: Int64

    init(updates batches: [[String]] = [], botID: Int64 = 123) {
        self.batches = batches
        self.botID = botID
    }

    func script(_ method: String, _ answers: Answer...) { scripted[method, default: []] += answers }
    func add(_ batch: [String]) { batches.append(batch) }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let method = request.url?.lastPathComponent ?? ""
        requests.append(Request(method: method, url: request.url?.absoluteString ?? "", body: request.httpBody ?? Data()))
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
    private(set) var delivered: [Delivered] = []
    private(set) var statuses: [TelegramGateway.Status] = []
    private(set) var refusals: [TelegramRefusal] = []
    private(set) var failures: [(id: UUID, reason: String)] = []

    init(bots: [UUID: String]) { names = bots }

    func name(of botID: UUID) -> String? { names[botID] }

    func deliver(_ text: String, id: UUID, to botID: UUID) -> TelegramDelivery {
        guard names[botID] != nil else { return .unavailable }
        if threads[botID, default: []].contains(where: { $0.id == id }) || queues[botID]?.messages.contains(where: { $0.id == id }) == true {
            return .duplicate
        }
        delivered.append(Delivered(id: id, text: text, bot: botID))
        return take(ChatMessage(id: id, role: .user, text: text), in: botID)
    }

    func progress(of id: UUID, for botID: UUID) -> TelegramProgress {
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
