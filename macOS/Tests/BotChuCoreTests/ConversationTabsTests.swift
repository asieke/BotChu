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
            (.stopped(at: now.addingTimeInterval(-180)), "Stopped", "3m", "3 minutes ago"),
            (.needsInput(requests: 1, at: now.addingTimeInterval(-60)), "Needs input", "1m", "1 minute ago"),
            (.needsInput(requests: 3, at: nil), "3 requests need input", nil, nil),
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
        #expect(![Kind.idle, .news, .failed, .stopped, .needsInput].contains { $0.isActive })
        #expect(Kind.stopped.endsTurn(from: .working))
        #expect(!Kind.needsInput.endsTurn(from: .idle) && !Kind.idle.endsTurn(from: .needsInput))
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
        #expect(idle.spoken(at: now) == "BotChu #113, Show repository issues and their count in the Task Activity sidebar, Idle, 1 hour ago")
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

    /// #192: a task's three lines: where, its saved summary (else what it is about), then its state.
    @Test func aTaskTabShowsItsSummaryThenItsState() {
        var task = issue
        task.summary = " Issue count sidebar "
        let working = ConversationTab(task: task, machine: nil, state: .working(.thinking, since: now.addingTimeInterval(-252)))
        #expect(working.title == "BotChu #113")
        #expect(working.label == "Issue count sidebar")
        #expect(working.status == "Thinking…")
        // The tooltip still has the issue's whole title; VoiceOver reads both.
        #expect(working.help(shortcut: "⌘2").hasPrefix("Show repository issues and their count in the Task Activity sidebar\n"))
        #expect(working.spoken(at: now) == "BotChu #113, Issue count sidebar, Show repository issues and their count in the Task Activity sidebar, "
                + "Thinking…, 4 minutes 12 seconds")
        #expect(working.railHelp(at: now, shortcut: "⌘2") == "BotChu #113\nIssue count sidebar\nThinking… · 4:12 · ⌘2")
        // Idle, its state says so, rather than repeating what it is about.
        let idle = ConversationTab(task: task, machine: "Far Mac", state: .idle(since: now.addingTimeInterval(-120)))
        #expect(idle.status == "Idle")
        #expect(idle.railHelp(at: now, shortcut: nil) == "BotChu #113 · Far Mac\nIssue count sidebar\nIdle · 2m")
        #expect(ConversationTab(task: task, machine: nil, state: .failed(at: now)).status == "Turn failed")
        // A task from before summaries, or one whose summary didn't come: what it is about, as before.
        let old = ConversationTab(task: issue, machine: nil, state: .idle(since: nil))
        #expect(old.summary == nil && old.label == "Show repository issues and their count in the Task Activity sidebar")
        var blank = issue
        blank.summary = "  "
        #expect(ConversationTab(task: blank, machine: nil, state: .idle(since: nil)).summary == nil)
        // Home keeps its two lines: its account, or what it is doing.
        let home = ConversationTab.home(account: "Claude Dev", state: .idle(since: now.addingTimeInterval(-120)))
        #expect(home.status == "Claude Dev")
        #expect(home.railHelp(at: now, shortcut: "⌘1") == "Home\nClaude Dev · 2m · ⌘1")
        let busyHome = ConversationTab.home(account: "Claude Dev", state: .working(.thinking, since: now.addingTimeInterval(-5)))
        #expect(busyHome.railHelp(at: now, shortcut: "⌘1") == "Home\nThinking… · 0:05 · ⌘1")
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
        // Many: at most four dots, the most urgent first (#218), in tab order among equals, then +N.
        let busy = BotRowSummary(account: "Claude Dev", home: .failed(at: now), tasks: [
            (issue, working), (brief, .preparing), (issue, idle), (issue, .news(pullRequest: 1, at: now)), (issue, working), (issue, .starting(since: now)),
        ])
        #expect(busy.dots == [.failed, .working, .preparing, .working])
        #expect(busy.more == 2)
        #expect(busy.subtitle == "4 tasks running")
        #expect(busy.spokenDots == "1 failed, 1 preparing, 1 starting, 2 working, 1 finished")
    }

    /// #218: a full row keeps its urgent dots, however late their tabs come, and counts the rest.
    @Test func aFullRowKeepsItsUrgentDotsAndCountsTheRest() {
        let brief = BotTask(repo: "asieke/GitChu", checkout: "/w/GitChu", brief: "Speed up the sync")
        let working = TabState.working(.coding, since: now)
        let asking = TabState.needsInput(requests: 1, at: now)
        let row = BotRowSummary(account: "Claude Dev", home: .news(pullRequest: nil, at: now), tasks: [
            (issue, working), (issue, working), (issue, working), (issue, .idle(since: now)), (issue, working),
            (issue, .stopped(at: now)), (brief, asking),
        ])
        #expect(row.dots == [.needsInput, .stopped, .working, .working])
        #expect(row.more == 3)
        #expect(row.spokenDots == "1 needs input, 1 stopped, 4 working, 1 finished")
        // What waits on the owner leads the subtitle: which task, Home, or how many.
        #expect(row.subtitle == "Needs input on GitChu")
        #expect(BotRowSummary(account: "Claude Dev", home: asking, tasks: [(issue, working)]).subtitle == "Needs input")
        let two = BotRowSummary(account: "Claude Dev", home: asking, tasks: [(issue, .needsInput(requests: 2, at: now))])
        #expect(two.subtitle == "2 need input" && two.dots == [.needsInput, .needsInput] && two.spokenDots == "2 need input")
        // An idle-only bot has no dots, however many tasks it has open.
        let quiet = BotRowSummary(account: "Claude Dev", home: .idle(since: now), tasks: [(issue, .idle(since: now)), (brief, .idle(since: nil))])
        #expect(quiet.dots.isEmpty && quiet.more == 0 && quiet.spokenDots.isEmpty)
    }

    /// #237: a bot row's dots are its tabs' own states, never others. For every Home with every
    /// pair of tasks, and for rows with more than four busy tabs, the dots and +N count exactly the
    /// tabs that aren't idle, kind for kind, the most urgent first, and the tooltip names them all;
    /// answering a request, then reading the finished turn, changes the row's dot as the tab's.
    @Test func aRowsDotsAreItsTabsOwnStates() {
        let states: [TabState] = [.idle(since: now), .preparing, .starting(since: now), .working(.coding, since: now),
                                  .news(pullRequest: 7, at: now), .failed(at: now), .stopped(at: now), .needsInput(requests: 1, at: now)]
        var rows: [(home: TabState, tasks: [TabState])] = []
        for home in states {
            for first in states {
                for second in states { rows.append((home: home, tasks: [first, second])) }
            }
        }
        rows.append((home: .needsInput(requests: 2, at: now), tasks: states))
        rows.append((home: .news(pullRequest: nil, at: now), tasks: states.reversed() + states))
        let kinds: [TabState.Kind] = [.needsInput, .failed, .stopped, .preparing, .starting, .working, .news]
        for (home, tasks) in rows {
            let row = BotRowSummary(account: "Claude Dev", home: home, tasks: tasks.map { (task: issue, state: $0) })
            let busy = ([home] + tasks).map(\.kind).filter { $0 != .idle }
            let label = "Home \(home.kind), tasks \(tasks.map(\.kind))"
            #expect(row.dots.count + row.more == busy.count, "\(label)")
            #expect(row.dots.map(\.urgency) == Array(busy.map(\.urgency).sorted(by: >).prefix(BotRowSummary.dotLimit)), "\(label): \(row.dots)")
            #expect(row.spokenDots.isEmpty == busy.isEmpty, "\(label)")
            for kind in kinds {
                let count = busy.filter { $0 == kind }.count
                // None made up or recoloured, and the tooltip counts those past the fourth too.
                #expect(row.dots.filter { $0 == kind }.count <= count, "\(label): \(row.dots)")
                if count > 0 { #expect(row.spokenDots.contains("\(count) \(kind.name(count: count))"), "\(label): \(row.spokenDots)") }
            }
        }
        let last = now.addingTimeInterval(-120)
        let replied = status([ChatMessage(role: .user, text: "Go", date: last.addingTimeInterval(-5)),
                              ChatMessage(role: .assistant, text: "Done", date: last)])
        let steps = [TabState(status: replied, unread: true, awaitingInput: [now]), TabState(status: replied, unread: true),
                     TabState(status: replied, unread: false)]
        #expect(steps.map(\.kind) == [.needsInput, .news, .idle])
        for state in steps {
            let row = BotRowSummary(account: "Claude Dev", home: .idle(since: nil), tasks: [(task: issue, state: state)])
            #expect(row.dots == (state.kind == .idle ? [] : [state.kind]))
        }
    }

    /// #218: waiting on the owner outranks everything, then a failed or stopped turn, then a turn
    /// under way, then a finished one not yet seen, then idle.
    @Test func theMostUrgentStateWins() {
        let last = now.addingTimeInterval(-120)
        let asked = [now.addingTimeInterval(-600), now.addingTimeInterval(-60)]
        let replied = [ChatMessage(role: .user, text: "Go", date: last.addingTimeInterval(-5)), ChatMessage(role: .assistant, text: "Done", date: last)]
        let failed = replied + [ChatMessage(role: .error, text: "It broke", date: last)]
        let stopped = replied + [.stopNote(byOwner: true, date: now)]
        let running = RunState(startedAt: last, hasOutput: true, activity: .coding)
        for status in [status(replied), status(failed), status(stopped), status(replied, run: running)] {
            for unread in [false, true] {
                #expect(TabState(status: status, unread: unread, awaitingInput: asked) == .needsInput(requests: 2, at: asked[1]))
            }
        }
        #expect(TabState(status: status(failed), unread: true).kind == .failed)
        #expect(TabState(status: status(stopped), unread: true).kind == .stopped)
        #expect(TabState(status: status(replied, run: running), unread: true).kind == .working)
        #expect(TabState(status: status(replied), unread: true).kind == .news)
        #expect(TabState(status: status(replied), unread: false).kind == .idle)
        let kinds: [TabState.Kind] = [.needsInput, .failed, .stopped, .working, .starting, .preparing, .news, .idle]
        #expect(kinds.map(\.urgency) == [4, 3, 3, 2, 2, 2, 1, 0])
    }

    /// #218: the owner's Stop shows until the next turn, isn't a finished turn however it is looked
    /// at, and comes back from the saved thread on relaunch, from the note's mark, not its words.
    @Test func anOwnersStopLastsUntilTheNextTurnAndAcrossRelaunch() throws {
        let last = now.addingTimeInterval(-120)
        let replied = [ChatMessage(role: .user, text: "Go", date: last.addingTimeInterval(-5)), ChatMessage(role: .assistant, text: "Partial", date: last)]
        let stopped = replied + [.stopNote(byOwner: true, date: now)]
        #expect(TabState(status: status(stopped), unread: true) == .stopped(at: last))
        // Opening it (no longer unread) leaves it stopped; a finished turn turns idle.
        #expect(TabState(status: status(stopped), unread: false) == .stopped(at: last))
        #expect(TabState(status: status(replied), unread: false) == .idle(since: last))
        #expect(TabState(status: status(stopped + [ChatMessage(role: .note, text: "New session")]), unread: false).kind == .stopped)
        #expect(TabState.stopped(at: last).text == "Stopped" && !TabState.Kind.stopped.isActive)
        // The next turn clears it.
        let again = stopped + [ChatMessage(role: .user, text: "Go on", date: now)]
        #expect(TabState(status: status(again, run: RunState(startedAt: now)), unread: false) == .starting(since: now))
        #expect(TabState(status: status(again + [ChatMessage(role: .assistant, text: "Done", date: now)]), unread: false) == .idle(since: now))
        // Stopped to quit BotChu, or a "Stopped" note without the mark (as threads saved before
        // have), is no stop of the owner's.
        #expect(TabState(status: status(replied + [.stopNote(byOwner: false)]), unread: true).kind == .news)
        #expect(TabState(status: status(replied + [ChatMessage(role: .note, text: "Stopped")]), unread: false).kind == .idle)
        // Relaunch: from the saved transcript, and from a summary kept as the thread grew.
        let saved = try JSONDecoder().decode([ChatMessage].self, from: JSONEncoder().encode(stopped))
        #expect(ThreadSummary(saved).stoppedAt == now && ThreadSummary(saved) == ThreadSummary(stopped))
        var kept = ThreadSummary(replied)
        kept.extend(with: stopped, from: replied.count)
        #expect(kept.stoppedAt == now)
        kept.extend(with: stopped + [ChatMessage(role: .note, text: "New session")], from: stopped.count)
        #expect(kept.stoppedAt == now)
        kept.extend(with: again, from: stopped.count)
        #expect(kept.stoppedAt == nil && kept == ThreadSummary(again))
        let digest = try JSONDecoder().decode(ThreadDigest.self, from: JSONEncoder().encode(ThreadDigest(stopped)))
        #expect(digest.summary.stoppedAt == now)
        // A digest saved before #218 still reads, with no stop.
        let old = #"{"summary":{"messageCount":2,"toolCallCount":0},"count":2,"lastReplyCut":false}"#
        #expect(try JSONDecoder().decode(ThreadDigest.self, from: Data(old.utf8)).summary.stoppedAt == nil)
        #expect(status(stopped).phase == .stopped && status(replied).phase == .idle)
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
