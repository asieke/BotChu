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
        saved.pending[0].presentationVersion = 0 // multipart answer sent before the upgrade
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

    @Test func aTurnsFinalReplyIsConciseAndFailureRecoveryStaysVisible() {
        let message = ChatMessage(role: .user, text: "hello")
        let reply = { (turn: [ChatMessage]) in TelegramReply.compose(after: message.id, in: [message] + turn, botName: "Fixture") }
        #expect(reply([ChatMessage(role: .error, text: "Reconnecting... 1/5"), ChatMessage(role: .assistant, text: " Done. ")]) == "Done.")
        #expect(reply([ChatMessage(role: .assistant, text: "So far"), ChatMessage(role: .error, text: "codex exited with status 1:\nsecret stderr")])
            == "⚠️ Fixture couldn't finish this turn. Check the error in BotChu, then send a follow-up to retry.\n\nSo far")
        #expect(reply([ChatMessage(role: .assistant, text: "Partial"), ChatMessage(role: .note, text: "Stopped")]) == "⏹ Stopped in BotChu. This result may be incomplete; send a follow-up to continue.\n\nPartial")
        #expect(reply([ChatMessage(role: .tool, toolName: "Bash"), ChatMessage(role: .note, text: "Saved 1 note")])
            == "Fixture ended without a final answer. Ask it to explain the result or continue.")
        #expect(reply([ChatMessage(role: .assistant, text: "A"), ChatMessage(role: .assistant, text: "B"), ChatMessage(role: .user, text: "next"),
                       ChatMessage(role: .assistant, text: "C")]) == "B")
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
        // Exercise the transport checkpoint with a multipart answer independently of presentation.
        await app.reportProgress(.answered(reply))
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

    @Test func conciseRepliesOfferFullDetailsOnePageAtATimeAcrossRelaunches() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID()
        let app = FakeBotChu(bots: [bot: "Danny"])
        let chats = [TelegramChat(id: 42, botID: bot), TelegramChat(id: 43, botID: bot)]
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "explain", message: 7)]])
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        let long = "The migration passed.\n" + (1...200).map { "Step \($0) moved the records and retained their original identifiers." }.joined(separator: "\n") + "\nWarning: production remains unverified.\nPlease approve the production check?"
        await app.finishTurn(of: bot, with: [ChatMessage(role: .tool, text: "secret raw log"), ChatMessage(role: .assistant, text: long)])
        try await gateway.flushReplies()
        let summary = try #require(await telegram.sent.first)
        #expect(summary.text.contains("production remains unverified") && summary.text.contains("Please approve"))
        #expect(summary.text.contains("/details") && summary.text.utf16.count < 1_600)
        #expect(await telegram.sent.count == 1)
        #expect(TelegramState.load(from: folder.state).details.count == 1)

        let relaunched = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        await telegram.add([update(11, chat: 42, text: "/details", message: 8)])
        try await relaunched.poll()
        let first = try #require(await telegram.sent.last)
        #expect(first.text.hasPrefix("Danny — reply details (1/"))
        #expect(first.text.contains("Step 1 moved") && first.text.hasSuffix("Next: /details 2"))
        #expect(first.text.utf16.count <= TelegramReply.limit && first.replyTo == 8)
        await telegram.add([update(12, chat: 42, text: "/details 2", message: 9), update(13, chat: 43, text: "/details", message: 1)])
        try await relaunched.poll()
        let sent = await telegram.sent
        #expect(sent.count == 4)
        #expect(sent[2].text.contains("reply details (2/") && sent[2].text != first.text)
        #expect(sent[3].text == "No delivered reply is available yet. Ask a bot something first.")
        #expect(await app.delivered.count == 1) // /details never starts a CLI turn
        #expect(!sent.contains { $0.text.contains("secret raw log") })
        #expect(try !String(contentsOf: folder.state, encoding: .utf8).contains("Step 1")) // IDs only
    }

    @Test func detailsNeverCrossRevokedChatsOrMappingsAndDoNotAcceptInvalidPages() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let bot = UUID(), other = UUID()
        let app = FakeBotChu(bots: [bot: "Danny", other: "Other"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "hello", message: 7)]])
        let chats = [TelegramChat(id: 42, botID: bot)]
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        await app.finishTurn(of: bot, with: [ChatMessage(role: .assistant, text: "Private answer.")])
        try await gateway.flushReplies()
        await telegram.add([update(11, chat: 42, text: "/details -1"), update(12, chat: 42, text: "/details 999"), update(13, chat: 42, text: "/details foo bar"), update(14, chat: 99, text: "/details")])
        try await gateway.poll()
        #expect(await telegram.sent.count == 4)
        #expect(await telegram.sent.last?.text.contains("Use /details") == true)
        #expect(await app.delivered.count == 1)

        // Authorization can change while Home is being loaded for /details.
        let hold = Suspension()
        await app.holdDetails(at: hold)
        await telegram.add([update(15, chat: 42, text: "/details")])
        let reading = Task { try await gateway.poll() }
        try await hold.waitUntilEntered()
        await app.authorize([])
        await hold.release()
        try await reading.value
        #expect(await telegram.sent.count == 4)
        await app.authorize([TelegramChat(id: 42, botID: other)])

        // Remapping discards the pointer, including after restarting the gateway.
        let remapped = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: other)], app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        await telegram.add([update(16, chat: 42, text: "/details")])
        try await remapped.poll()
        #expect(await remapped.savedState.details.isEmpty)
        #expect(await telegram.sent.last?.text == "No delivered reply is available yet. Ask a bot something first.")
        await app.authorize([])
        await telegram.add([update(17, chat: 42, text: "/details")])
        try await remapped.poll()
        #expect(await telegram.sent.count == 5)
    }

    // MARK: Choosing with @, # and /task (#114)

    static let botchu = ProjectCatalogEntry(name: "BotChu", repo: "asieke/BotChu", status: .active)
    static let throughGateway: [String: Any] = ["via_bot": ["id": 123, "is_bot": true, "first_name": "Chu", "username": "chu_bot"]]

    static func messageID(_ message: Int64, chat: Int64 = 42) -> UUID { TelegramInbound.messageID(bot: 123, chat: chat, message: message) }

    @Test func choosingABotSendsLaterMessagesToItsHomeAndItsRepliesSayWhoAnswers() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID(), danny = UUID()
        let app = FakeBotChu(bots: [fixture: "Fixture", danny: "Danny"])
        await app.title(danny, "COO")
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "@Danny", message: 1), update(11, chat: 42, text: "hello", message: 2)]])
        let chats = [TelegramChat(id: 42, botID: fixture)]
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        // Choosing starts nothing and says who the chat talks to now; the next message goes to Danny's Home.
        #expect(await telegram.sent == [Sent(chat: 42, text: TelegramReply.selected(bot: "Danny (COO)", repo: nil, recipient: "Danny"), replyTo: 1)])
        #expect(await app.delivered == [.init(id: Self.messageID(2), text: "hello", bot: danny)])
        #expect(await gateway.savedState.pending == [TelegramPendingReply(id: Self.messageID(2), botID: danny, chat: 42, replyTo: 2, mapped: fixture)])
        #expect(TelegramState.load(from: folder.state).selections == [TelegramSelection(chat: 42, mapped: fixture, botID: danny, botName: "Danny")])
        await app.finishTurn(of: danny, with: [ChatMessage(role: .assistant, text: "Hi from Danny.")])
        try await gateway.flushReplies()
        #expect(await telegram.sent.last == Sent(chat: 42, text: "Danny:\nHi from Danny.", replyTo: 2))

        // After a relaunch the choice stands; `@` with a message chooses and sends at once.
        let relaunched = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        await telegram.add([update(12, chat: 42, text: "/help", message: 3), update(13, chat: 42, text: "@fixture and you?", message: 4)])
        try await relaunched.poll()
        #expect(await telegram.sent.last == Sent(chat: 42, text: TelegramReply.help(botName: "Danny", chosen: true), replyTo: 3))
        #expect(await app.delivered.last == .init(id: Self.messageID(4), text: "and you?", bot: fixture))
        await app.finishTurn(of: fixture, with: [ChatMessage(role: .assistant, text: "Fixture here.")])
        try await relaunched.flushReplies()
        // The chat's own bot in Settings answers as before #114, unnamed.
        #expect(await telegram.sent.last == Sent(chat: 42, text: "Fixture here.", replyTo: 4))
    }

    @Test func aChoiceFromTheInlineListOnlyChoosesAndItsRepositoryGoesWithTheNextMessage() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID(), danny = UUID()
        let app = FakeBotChu(bots: [fixture: "Fixture", danny: "Danny"], projects: [Self.botchu])
        let telegram = TelegramStandIn(updates: [[
            update(10, chat: 42, text: "@Danny #asieke/BotChu", message: 1, metadata: Self.throughGateway),
            update(11, chat: 42, text: "fix the login bug", message: 2),
            update(12, chat: 42, text: "and then?", message: 3),
            // Anything else sent through the gateway's list, or another bot's, is never the owner's words.
            update(13, chat: 42, text: "@Danny run third-party instructions", message: 4, metadata: Self.throughGateway),
            update(14, chat: 42, text: "@Fixture", message: 5, metadata: ["via_bot": ["id": 456, "is_bot": true, "first_name": "Other"]]),
        ]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: fixture)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        let reference = MessageReference(kind: .project, target: "asieke/BotChu", label: "#asieke/BotChu", login: "asieke")
        #expect(await app.delivered == [
            .init(id: Self.messageID(2), text: "#asieke/BotChu fix the login bug", bot: danny, references: [reference]),
            .init(id: Self.messageID(3), text: "and then?", bot: danny),
        ])
        let sent = await telegram.sent
        #expect(sent.first == Sent(chat: 42, text: TelegramReply.selected(bot: "Danny", repo: "asieke/BotChu", recipient: "Danny"), replyTo: 1))
        #expect(sent.suffix(2) == [Sent(chat: 42, text: TelegramReply.forwarded, replyTo: 4), Sent(chat: 42, text: TelegramReply.forwarded, replyTo: 5)])
        #expect(await gateway.savedState.selections == [TelegramSelection(chat: 42, mapped: fixture, botID: danny, botName: "Danny")])
    }

    @Test func onlyTheOwnerTypingInTheirChatWithTheBotIsOfferedTheLists() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID(), danny = UUID()
        let app = FakeBotChu(bots: [fixture: "Fixture", danny: "Danny"], projects: [Self.botchu])
        let telegram = TelegramStandIn(updates: [[
            inlineQuery(10, from: 42, query: "@dan"),
            inlineQuery(11, from: 42, query: "@Danny #bot"),
            inlineQuery(12, from: 99, query: "@"),
            inlineQuery(13, from: 42, query: "@", chatType: "private"),
            inlineQuery(14, from: 42, query: "@", chatType: nil),
            inlineQuery(15, from: 42, query: "@", isBot: true),
        ]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: fixture)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        let answers = await telegram.inlineAnswers
        #expect(answers.map { $0["inline_query_id"] as? String } == ["10", "11"])
        #expect(answers.allSatisfy { $0["is_personal"] as? Bool == true && ($0["cache_time"] as? NSNumber)?.intValue == 0 })
        func messages(_ answer: [String: Any]) -> [String] {
            (answer["results"] as? [[String: Any]] ?? []).compactMap { ($0["input_message_content"] as? [String: Any])?["message_text"] as? String }
        }
        #expect(messages(answers[0]) == ["@Danny"])
        #expect(messages(answers[1]) == ["@Danny #asieke/BotChu"])
        #expect((answers[0]["results"] as? [[String: Any]])?.first?["type"] as? String == "article")
        #expect(await telegram.sent.isEmpty)
        #expect(await app.delivered.isEmpty)
        #expect(await app.refusals.isEmpty)
        #expect(await gateway.savedState.offset == 16)

        // Removed from Settings: offered nothing.
        await app.authorize([])
        await telegram.add([inlineQuery(16, from: 42, query: "@")])
        try await gateway.poll()
        #expect(await telegram.inlineAnswers.count == 2)
    }

    @Test func aTaskRequestMakesATaskOfItsOwnForTheChosenBotInTheChosenRepository() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID(), danny = UUID()
        let app = FakeBotChu(bots: [fixture: "Fixture", danny: "Danny"], projects: [Self.botchu])
        let request = update(10, chat: 42, text: "/task @Danny #asieke/BotChu Fix the login bug", message: 1)
        let telegram = TelegramStandIn(updates: [[
            request,
            update(11, chat: 42, text: "/task fix it", message: 2),
            update(12, chat: 42, text: "#BotChu", message: 3),
            update(13, chat: 42, text: "/task Update the docs", message: 4),
            update(14, chat: 42, text: "/task #BotChu", message: 5),
        ]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: fixture)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        #expect(await app.tasks == [
            .init(id: Self.messageID(1), brief: "Fix the login bug", repo: "asieke/BotChu", bot: danny),
            .init(id: Self.messageID(4), brief: "Update the docs", repo: "asieke/BotChu", bot: danny),
        ])
        // A task isn't a Home message, and no Telegram reply is owed for it: its conversation is its own.
        #expect(await app.delivered.isEmpty)
        #expect(await gateway.savedState.pending.isEmpty)
        let first = TaskNaming.title(repo: "asieke/BotChu", work: nil, brief: "Fix the login bug")
        let second = TaskNaming.title(repo: "asieke/BotChu", work: nil, brief: "Update the docs")
        #expect(await telegram.sent.map(\.text) == [
            TelegramReply.taskStarted(first, bot: "Danny", repo: "asieke/BotChu"),
            TelegramReply.taskNeedsRepository,
            TelegramReply.selected(bot: nil, repo: "asieke/BotChu", recipient: "Danny"),
            TelegramReply.taskStarted(second, bot: "Danny", repo: "asieke/BotChu"),
            TelegramReply.taskNeedsBrief,
        ])
        #expect(await gateway.savedState.selections == [TelegramSelection(chat: 42, mapped: fixture, botID: danny, botName: "Danny")])

        // Telegram sending the request again (its offset lost in a crash) finds the same task.
        let again = try TemporaryFolder()
        defer { again.remove() }
        await telegram.add([request])
        let relaunched = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: fixture)], app: app, stateURL: again.state,
                                         transport: telegram, timing: Self.fast)
        try await relaunched.poll()
        #expect(await app.tasks.count == 2)
        #expect(await telegram.sent.last?.text == TelegramReply.taskAlreadyStarted(first))
    }

    @Test func changingTheRecipientLeavesQueuedMessagesAndOwedRepliesWithTheirBotAndChat() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID(), danny = UUID()
        let app = FakeBotChu(bots: [fixture: "Fixture", danny: "Danny"])
        let telegram = TelegramStandIn(updates: [[
            update(10, chat: 42, text: "first", message: 1),
            update(11, chat: 42, text: "second", message: 2),
            update(12, chat: 42, text: "@Danny third", message: 3),
            update(13, chat: 43, text: "from the other chat", message: 4),
        ]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: fixture), TelegramChat(id: 43, botID: fixture)],
                                      app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        // Choosing Danny in one chat moves nothing already queued, and nothing of the other chat's.
        #expect(await app.delivered.map(\.bot) == [fixture, fixture, danny, fixture])
        #expect(await app.queuedTexts(fixture) == ["second", "from the other chat"])
        #expect(await gateway.savedState.pending.map { [$0.chat, $0.replyTo] } == [[42, 1], [42, 2], [42, 3], [43, 4]])

        await app.finishTurn(of: danny, with: [ChatMessage(role: .assistant, text: "Danny's answer")])
        for answer in ["first answer", "second answer", "other chat's answer"] {
            await app.finishTurn(of: fixture, with: [ChatMessage(role: .assistant, text: answer)])
        }
        try await gateway.flushReplies()
        let replies = await telegram.sent.filter { !$0.text.hasPrefix("⏳") }
        #expect(replies == [
            Sent(chat: 42, text: "first answer", replyTo: 1),
            Sent(chat: 42, text: "second answer", replyTo: 2),
            Sent(chat: 42, text: "Danny:\nDanny's answer", replyTo: 3),
            Sent(chat: 43, text: "other chat's answer", replyTo: 4),
        ])
    }

    @Test func aChosenBotThatIsDeletedIsNeverReplacedByAnother() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID(), danny = UUID()
        let app = FakeBotChu(bots: [fixture: "Fixture", danny: "Danny"])
        let telegram = TelegramStandIn(updates: [[update(10, chat: 42, text: "@Danny", message: 1)]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: fixture)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        await app.remove(danny)
        await telegram.add([
            update(11, chat: 42, text: "hello?", message: 2),
            update(12, chat: 42, text: "/start", message: 3),
            update(13, chat: 42, text: "@Danny again", message: 4),
            update(14, chat: 42, text: "@Fixture", message: 5),
            update(15, chat: 42, text: "hello", message: 6),
        ])
        try await gateway.poll()
        #expect(await app.delivered == [.init(id: Self.messageID(6), text: "hello", bot: fixture)])
        let bots = await app.directory().bots
        #expect(await telegram.sent.dropFirst().map(\.text) == [
            TelegramReply.chosenUnavailable("Danny"),
            TelegramReply.chosenGone("Danny"),
            TelegramReply.unknownBot("Danny", among: bots),
            TelegramReply.selected(bot: "Fixture", repo: nil, recipient: "Fixture"),
        ])
    }

    @Test(arguments: [false, true])
    func remappingAChatInSettingsSetsItsChoicesAndTheirRepliesAside(remapped: Bool) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID(), danny = UUID(), other = UUID()
        let owed = TelegramPendingReply(id: UUID(), botID: danny, chat: 42, replyTo: 7, mapped: fixture)
        try TelegramState(botUserID: 123, offset: 11, pending: [owed],
                          selections: [TelegramSelection(chat: 42, mapped: fixture, botID: danny, botName: "Danny")]).save(to: folder.state)
        let app = FakeBotChu(bots: [fixture: "Fixture", danny: "Danny", other: "Other"])
        let chats = [TelegramChat(id: 42, botID: remapped ? other : fixture)]
        await app.authorize(chats)
        await app.reportProgress(.answered("Danny's reply"))
        let telegram = TelegramStandIn(updates: [[update(11, chat: 42, text: "next", message: 8)]])
        let gateway = TelegramGateway(token: Self.token, chats: chats, app: app, stateURL: folder.state, transport: telegram, timing: Self.fast)
        try await gateway.poll()
        #expect(await app.delivered.map(\.bot) == [remapped ? other : danny])
        #expect(await gateway.savedState.selections.isEmpty == remapped)
        try await gateway.flushReplies()
        #expect(await telegram.sent.contains(Sent(chat: 42, text: "Danny:\nDanny's reply", replyTo: 7)) == !remapped)
        #expect(await gateway.savedState.pending.isEmpty)
    }

    @Test func addressWordsThatNameNothingSendNothingAndChooseNothing() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let fixture = UUID()
        let app = FakeBotChu(bots: [fixture: "Fixture"], projects: [Self.botchu])
        let telegram = TelegramStandIn(updates: [[
            update(10, chat: 42, text: "@Nobody hi", message: 1),
            update(11, chat: 42, text: "#asieke/Nope fix it", message: 2),
            update(12, chat: 42, text: "/task #asieke/Nope fix it", message: 3),
            update(13, chat: 42, text: "#todo buy milk", message: 4),
            update(14, chat: 42, text: "hello", message: 5),
        ]])
        let gateway = TelegramGateway(token: Self.token, chats: [TelegramChat(id: 42, botID: fixture)], app: app, stateURL: folder.state,
                                      transport: telegram, timing: Self.fast)
        try await gateway.poll()
        #expect(await app.delivered == [.init(id: Self.messageID(4), text: "#todo buy milk", bot: fixture),
                                        .init(id: Self.messageID(5), text: "hello", bot: fixture)])
        #expect(await app.tasks.isEmpty)
        let bots = await app.directory().bots
        #expect(await telegram.sent.prefix(3).map(\.text) == [TelegramReply.unknownBot("Nobody", among: bots),
                                                              TelegramReply.unknownRepository("asieke/Nope"),
                                                              TelegramReply.unknownRepository("asieke/Nope")])
        #expect(await gateway.savedState.selections.isEmpty)
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

/// An inline query as the Bot API sends it: what `from` types after the bot's username, in the chat
/// `chatType` says ("sender": their own chat with the bot).
private func inlineQuery(_ id: Int64, from: Int64, query: String, chatType: String? = "sender", isBot: Bool = false) -> String {
    var body: [String: Any] = ["id": String(id), "from": ["id": from, "is_bot": isBot, "first_name": "Alex"], "query": query, "offset": ""]
    if let chatType { body["chat_type"] = chatType }
    return String(decoding: try! JSONSerialization.data(withJSONObject: ["update_id": id, "inline_query": body]), as: UTF8.self)
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
        case "sendChatAction", "answerInlineQuery": return ok("true")
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
    var inlineAnswers: [[String: Any]] { requests.filter { $0.method == "answerInlineQuery" }.map(\.json) }
    var timeouts: [Int64] { requests.filter { $0.method == "getUpdates" }.compactMap { number($0.json["timeout"]) } }
}

/// BotChu's side, as `AppModel` behaves: one queue per bot's Home, a turn at a time.
private actor FakeBotChu: TelegramApp {
    struct Delivered: Equatable {
        let id: UUID
        let text: String
        let bot: UUID
        var references: [MessageReference] = []
    }

    struct StartedTask: Equatable {
        let id: UUID
        let brief: String
        let repo: String
        let bot: UUID
    }

    private var names: [UUID: String]
    private var titles: [UUID: String] = [:]
    private var projects: [ProjectCatalogEntry]?
    private(set) var tasks: [StartedTask] = []
    private var threads: [UUID: [ChatMessage]] = [:]
    private var queues: [UUID: MessageQueue] = [:]
    private var running: Set<UUID> = []
    private var chats: [TelegramChat]?
    private var stopped = false
    private var beforeDelivery: Suspension?
    private var afterDelivery: Suspension?
    private var beforeProgress: Suspension?
    private var beforeDetails: Suspension?
    private var progressOverride: TelegramProgress?
    private(set) var progressReads = 0
    private(set) var delivered: [Delivered] = []
    private(set) var statuses: [TelegramGateway.Status] = []
    private(set) var refusals: [TelegramRefusal] = []
    private(set) var failures: [(id: UUID, reason: String)] = []

    init(bots: [UUID: String], projects: [ProjectCatalogEntry]? = nil) {
        names = bots
        self.projects = projects
    }

    func name(of botID: UUID) -> String? { names[botID] }

    /// The bots by name, as the sidebar lists them, and the Projects catalog.
    func directory() -> TelegramDirectory {
        let bots = names.sorted { ($0.value, $0.key.uuidString) < ($1.value, $1.key.uuidString) }.map {
            BotRosterEntry(bot: Bot(id: $0.key, name: $0.value, title: titles[$0.key] ?? "", workspace: "/tmp/\($0.key)"))
        }
        return TelegramDirectory(bots: bots, projects: projects, login: "asieke")
    }

    func title(_ botID: UUID, _ title: String) { titles[botID] = title }

    func authorize(_ chats: [TelegramChat]) { self.chats = chats }
    func stop() { stopped = true }
    func holdDelivery(at suspension: Suspension, after: Bool = false) {
        if after { afterDelivery = suspension } else { beforeDelivery = suspension }
    }
    func holdProgress(at suspension: Suspension) { beforeProgress = suspension }
    func holdDetails(at suspension: Suspension) { beforeDetails = suspension }
    func reportProgress(_ progress: TelegramProgress) { progressOverride = progress }

    func authorization(for chat: Int64, botID: UUID?) -> TelegramAuthorization {
        if Task.isCancelled || stopped { return .stopped }
        if let chats {
            guard let allowed = chats.first(where: { $0.id == chat }), allowed.botID == botID else { return .revoked }
        }
        return .allowed
    }

    func deliver(_ text: String, references: [MessageReference], id: UUID, to botID: UUID, from chat: Int64,
                 mapped: UUID?) async -> TelegramDelivery {
        if let hold = beforeDelivery {
            beforeDelivery = nil
            await hold.pause()
        }
        guard case .allowed = authorization(for: chat, botID: mapped) else { return .discarded }
        guard names[botID] != nil else { return .unavailable }
        if threads[botID, default: []].contains(where: { $0.id == id }) || queues[botID]?.messages.contains(where: { $0.id == id }) == true {
            return .duplicate
        }
        delivered.append(Delivered(id: id, text: text, bot: botID, references: references))
        let result = take(ChatMessage(id: id, role: .user, text: text), in: botID)
        if let hold = afterDelivery {
            afterDelivery = nil
            await hold.pause()
        }
        return result
    }

    /// A task of its own under the bot, as `AppModel.startTask` records one (`TaskHandoffRuntimeTests`
    /// and `TelegramBridgeTests` check the real one).
    func startTask(_ brief: String, in repo: String, id: UUID, for botID: UUID, from chat: Int64, mapped: UUID?) async -> TelegramTaskStart {
        guard case .allowed = authorization(for: chat, botID: mapped) else { return .discarded }
        guard names[botID] != nil else { return .unavailable }
        let title = TaskNaming.title(repo: repo, work: nil, brief: brief)
        if tasks.contains(where: { $0.id == id }) { return .duplicate(title: title) }
        tasks.append(StartedTask(id: id, brief: brief, repo: repo, bot: botID))
        return .started(title: title, unsaved: nil)
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

    func fullReply(of id: UUID, for botID: UUID) async -> String? {
        if let hold = beforeDetails {
            beforeDetails = nil
            await hold.pause()
        }
        guard let name = names[botID] else { return nil }
        return TelegramReply.full(after: id, in: threads[botID] ?? [], botName: name)
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
