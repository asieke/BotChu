import Foundation
import Testing
@testable import BotChuCore

/// #128: the conversation column's states, texts and dots, and when it folds into the rail.
@Suite struct ConversationTabsTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let bot = Bot(name: "10x Engineer Bot", workspace: "/w/bot")
    let issue = BotTask(repo: "asieke/BotChu", checkout: "/w/BotChu",
                        work: .init(number: 113, title: "Show repository issues and their count in the Task Activity sidebar",
                                    url: URL(string: "https://github.com/asieke/BotChu/issues/113")!, isPullRequest: false))

    private func status(_ messages: [ChatMessage], run: RunState? = nil) -> BotStatus {
        BotStatus.make(bot: bot, messages: messages, run: run)
    }

    @Test func stateComesFromTheStatusUnreadAndPullRequest() {
        let last = now.addingTimeInterval(-120)
        let replied = [ChatMessage(role: .user, text: "Go", date: last.addingTimeInterval(-5)), ChatMessage(role: .assistant, text: "Done", date: last)]
        #expect(TabState(status: status(replied), unread: false) == .idle(since: last))
        #expect(TabState(status: status(replied), unread: true, pullRequest: 122) == .news(pullRequest: 122, at: last))
        let started = now.addingTimeInterval(-252)
        #expect(TabState(status: status(replied, run: RunState(startedAt: started, preparing: true)), unread: true) == .preparing)
        #expect(TabState(status: status(replied, run: RunState(startedAt: started)), unread: false) == .starting(since: started))
        #expect(TabState(status: status(replied, run: RunState(startedAt: started, hasOutput: true, activity: .coding)), unread: true)
                == .working(.coding, since: started))
        // A failed turn stays red, also once looked at (no longer unread), until the next turn starts.
        let failed = replied + [ChatMessage(role: .user, text: "Again", date: last), ChatMessage(role: .error, text: "It broke", date: last)]
        #expect(TabState(status: status(failed), unread: true) == .failed(at: last))
        #expect(TabState(status: status(failed), unread: false) == .failed(at: last))
        #expect(TabState(status: status(failed + [ChatMessage(role: .user, text: "Once more")], run: RunState(startedAt: now)),
                                  unread: false) == .starting(since: now))
        // BotChu's notes after the error don't clear it.
        #expect(TabState(status: status(failed + [ChatMessage(role: .note, text: "Session reset")]), unread: false).kind == .failed)
    }

    @Test func eachStateNamesItselfWithATime() {
        let since = now.addingTimeInterval(-252)
        let cases: [(TabState, String?, String?, String?)] = [
            (.idle(since: now.addingTimeInterval(-90)), nil, "1m", "1 minute ago"),
            (.idle(since: nil), nil, nil, nil),
            (.preparing, "Making the worktree…", nil, nil),
            (.starting(since: now.addingTimeInterval(-4)), "Starting…", "0:04", "4 seconds"),
            (.working(.coding, since: since), "Editing code…", "4:12", "4 minutes 12 seconds"),
            (.working(.thinking, since: now.addingTimeInterval(-3_601)), "Thinking…", "1:00:01", "1 hour 1 second"),
            (.news(pullRequest: 122, at: now.addingTimeInterval(-360)), "Finished · PR #122", "6m", "6 minutes ago"),
            (.news(pullRequest: nil, at: now.addingTimeInterval(-7_200)), "Finished", "2h", "2 hours ago"),
            (.failed(at: now.addingTimeInterval(-86_400 * 3)), "Turn failed", "3d", "3 days ago"),
            (.failed(at: now.addingTimeInterval(-10)), "Turn failed", "now", "just now"),
        ]
        for (state, text, time, spoken) in cases {
            #expect(state.text == text)
            #expect(state.time(at: now) == time)
            #expect(state.spokenTime(at: now) == spoken)
        }
        // A clock that moved backwards shows no negative time.
        #expect(TabState.idle(since: now.addingTimeInterval(30)).time(at: now) == "now")
        #expect(TabState.working(.coding, since: now.addingTimeInterval(30)).time(at: now) == "0:00")
    }

    @Test func onlyATurnEndingPopsTheDot() {
        typealias Kind = TabState.Kind
        #expect(Kind.news.endsTurn(from: .working))
        #expect(Kind.failed.endsTurn(from: .starting))
        #expect(Kind.idle.endsTurn(from: .preparing))
        #expect(!Kind.working.endsTurn(from: .starting))
        #expect(!Kind.idle.endsTurn(from: .news))
        #expect(!Kind.starting.endsTurn(from: .idle))
        #expect([Kind.preparing, .starting, .working].allSatisfy { $0.isActive })
        #expect(![Kind.idle, .news, .failed].contains { $0.isActive })
    }

    @Test func aTaskTabShowsItsRepositoryProminentlyAndWhatItIsDoing() {
        let working = TabState.working(.coding, since: now.addingTimeInterval(-252))
        let tab = ConversationTab(task: issue, machine: nil, state: working)
        // The first, prominent line: the repository it works in and the issue's number.
        #expect(tab.name == "BotChu" && tab.numberText == "#113")
        #expect(tab.title == "BotChu #113")
        // The second: what it is doing, with its time.
        #expect(tab.detail == "Editing code…")
        #expect(tab.state.time(at: now) == "4:12")
        #expect(tab.help(shortcut: "⌘2") == "Show repository issues and their count in the Task Activity sidebar\nasieke/BotChu · Issue #113 · This Mac · ⌘2")
        #expect(tab.spoken(at: now)
                == "BotChu #113, Show repository issues and their count in the Task Activity sidebar, Editing code…, 4 minutes 12 seconds")
        // Idle, the second line says what it is about.
        let idle = ConversationTab(task: issue, machine: nil, state: .idle(since: now.addingTimeInterval(-3_600)))
        #expect(idle.detail == "Show repository issues and their count in the Task Activity sidebar")
        #expect(idle.spoken(at: now) == "BotChu #113, Show repository issues and their count in the Task Activity sidebar, 1 hour ago")
        // Finished with its pull request, or failed.
        #expect(ConversationTab(task: issue, machine: nil, state: .news(pullRequest: 122, at: now)).detail == "Finished · PR #122")
        // On a host, without a shortcut (past the first eight tasks).
        let far = ConversationTab(task: issue, machine: "Far Mac", state: .failed(at: now))
        #expect(far.title == "BotChu #113" && far.machine == "Far Mac")
        #expect(far.detail == "Turn failed")
        #expect(far.help(shortcut: nil).hasSuffix("asieke/BotChu · Issue #113 · Far Mac"))
        #expect(far.spoken(at: now).hasPrefix("BotChu #113 on Far Mac, Show repository issues"))
    }

    @Test func aReviewABriefAndAnIssueNotLookedUpYet() {
        var review = BotTask(repo: "octocat/Hello-World", checkout: "/w/Hello-World",
                             work: .init(number: 41, title: "Add a greeting to the README", url: URL(string: "https://github.com/octocat/Hello-World/pull/41")!,
                                         isPullRequest: true), review: .review)
        review.pullRequest = 41
        let tab = ConversationTab(task: review, machine: nil, state: .news(pullRequest: 41, at: now))
        #expect(tab.isReview && tab.title == "Hello-World #41")
        #expect(tab.detail == "Finished · PR #41")
        #expect(tab.help(shortcut: "⌘5") == "Add a greeting to the README\noctocat/Hello-World · Pull request #41 review · This Mac · ⌘5")
        #expect(tab.spoken(at: now).hasPrefix("Review of Hello-World #41, Add a greeting to the README, Finished · PR #41"))

        // A brief has no number: the repository alone, and the brief's words, more of them than the
        // title's 28 characters.
        let brief = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu", brief: "Speed up the sync of large repositories by batching requests\nDetails…")
        #expect(brief.title == "GitChu · Speed up the sync of large…")
        let briefTab = ConversationTab(task: brief, machine: nil, state: .idle(since: nil))
        #expect(briefTab.number == nil && briefTab.numberText == nil)
        #expect(briefTab.title == "GitChu")
        #expect(briefTab.detail == "Speed up the sync of large repositories by batching requests")
        #expect(briefTab.help(shortcut: "⌘3").hasSuffix("asieke/GitChu · This Mac · ⌘3"))
        // A title of its own, after the repository's name, or whole.
        #expect(ConversationTab.subject(of: BotTask(title: "GitChu · Tidy up", repo: "asieke/GitChu", checkout: "/w", brief: "Something else")) == "Tidy up")
        #expect(ConversationTab.subject(of: BotTask(title: "Tidy up", repo: "asieke/GitChu", checkout: "/w")) == "Tidy up")
        // An issue whose title isn't read yet names the issue, not "BotChu #113" again.
        let unread = BotTask(repo: "asieke/BotChu", checkout: "/w", work: .init(number: 113, isPullRequest: false, repo: "asieke/BotChu"))
        let unreadTab = ConversationTab(task: unread, machine: nil, state: .idle(since: nil))
        #expect(unreadTab.title == "BotChu #113" && unreadTab.detail == "Issue #113")
        let named = BotTask(title: "ScreenTimeDaddy improvements", repo: "fixture/repo", checkout: "/w",
                            work: .init(number: 41, isPullRequest: false, repo: "fixture/repo"))
        #expect(ConversationTab.subject(of: named) == "ScreenTimeDaddy improvements")
    }

    @Test func homeNamesItsAccountOrItsState() {
        let idle = ConversationTab.home(account: "Claude Dev", state: .idle(since: now.addingTimeInterval(-120)))
        #expect(idle.title == "Home" && idle.numberText == nil)
        #expect(idle.detail == "Claude Dev")
        #expect(idle.state.time(at: now) == "2m")
        #expect(idle.spoken(at: now) == "Home, Claude Dev, 2 minutes ago")
        #expect(idle.help(shortcut: "⌘1") == "Home · ⌘1")
        let working = ConversationTab.home(account: "Claude Dev", state: .working(.thinking, since: now.addingTimeInterval(-5)))
        #expect(working.detail == "Thinking…")
    }

    @Test func shortcutsCoverHomeAndTheFirstEightTasks() {
        #expect(ConversationTab.shortcut(forTab: 0) == "⌘1")
        #expect(ConversationTab.shortcut(forTab: 8) == "⌘9")
        #expect(ConversationTab.shortcut(forTab: 9) == nil)
        #expect(ConversationTab.shortcut(forTab: -1) == nil)
    }

    @Test func botRowShowsDotsForBusyConversationsAndSaysWhatItDoes() {
        let brief = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu", brief: "Speed up the sync")
        let idle = TabState.idle(since: nil)
        let working = TabState.working(.coding, since: now)
        // Nothing open: the account.
        let quiet = BotRowSummary(account: "Claude Dev", home: idle, tasks: [])
        #expect(quiet.dots.isEmpty && quiet.more == 0 && quiet.subtitle == "Claude Dev" && quiet.spokenDots.isEmpty)
        // Open tasks, all idle: how many, and no dots.
        let open = BotRowSummary(account: "Claude Dev", home: idle, tasks: [(issue, idle), (brief, idle)])
        #expect(open.dots.isEmpty && open.subtitle == "2 tasks")
        #expect(BotRowSummary(account: "Claude Dev", home: idle, tasks: [(issue, idle)]).subtitle == "1 task")
        // One running: which; a brief by its repository.
        #expect(BotRowSummary(account: "Claude Dev", home: idle, tasks: [(issue, working), (brief, idle)]).subtitle == "Working on #113")
        #expect(BotRowSummary(account: "Claude Dev", home: idle, tasks: [(issue, .news(pullRequest: nil, at: now)), (brief, .starting(since: now))])
            .subtitle == "Working on GitChu")
        // Only Home working: its activity.
        #expect(BotRowSummary(account: "Claude Dev", home: working, tasks: [(issue, idle)]).subtitle == "Editing code…")
        // Many: at most four dots in tab order, Home first, then +N.
        let busy = BotRowSummary(account: "Claude Dev", home: .failed(at: now), tasks: [
            (issue, working), (brief, .preparing), (issue, idle), (issue, .news(pullRequest: 1, at: now)), (issue, working), (issue, .starting(since: now)),
        ])
        #expect(busy.dots == [.failed, .working, .preparing, .news])
        #expect(busy.more == 2)
        #expect(busy.subtitle == "4 tasks running")
        #expect(busy.spokenDots == "1 preparing, 1 starting, 2 working, 1 finished, 1 failed")
    }

    @Test func theColumnFoldsIntoTheRailWhenTheChatWouldBeTooNarrow() {
        typealias Layout = ConversationColumnLayout
        // The issue's figures: a 250-point bot list and the 380-point status sidebar.
        func available(window: Double) -> Double { window - 250 - 380 }
        #expect(Layout.readableWidth(available: available(window: 1_680), column: Layout.width) == 760)
        #expect(Layout.readableWidth(available: available(window: 1_600), column: Layout.width) == 682)
        #expect(!Layout.showsRail(available: available(window: 1_600), column: Layout.width, collapsed: false))
        #expect(Layout.showsRail(available: available(window: 1_500), column: Layout.width, collapsed: false))
        #expect(Layout.readableWidth(available: available(window: 1_500), column: Layout.railWidth) == 760)
        // Exactly 600 still reads; the owner's collapse always wins.
        #expect(!Layout.showsRail(available: 600 + 240 + 48, column: 240, collapsed: false))
        #expect(Layout.showsRail(available: 599 + 240 + 48, column: 240, collapsed: false))
        #expect(Layout.showsRail(available: 3_000, column: 240, collapsed: true))
        // A wider column folds sooner; widths stay within 200 to 320.
        #expect(Layout.showsRail(available: 950, column: 320, collapsed: false))
        #expect(!Layout.showsRail(available: 950, column: 200, collapsed: false))
        #expect(Layout.clamped(120) == 200 && Layout.clamped(500) == 320 && Layout.clamped(260) == 260)
        #expect(Layout.showsRail(available: 950, column: 900, collapsed: false) == Layout.showsRail(available: 950, column: 320, collapsed: false))
    }
}
