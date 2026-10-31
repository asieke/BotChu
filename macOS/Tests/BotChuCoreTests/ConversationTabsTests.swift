import Foundation
import Testing
@testable import BotChuCore

/// #128: the conversation column's states, texts and dots, and the owner's column width.
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

    /// #324: a bot's row says what it runs on, whatever it does, with a dot for each open task (an
    /// idle one a ring) and for Home while it isn't idle.
    @Test func botRowShowsADotPerOpenTaskAndWhatItRunsOn() {
        let idle = TabState.idle(since: nil)
        let working = TabState.working(.coding, since: now)
        let runsOn = "Claude Dev · Opus 5.5"
        // Nothing open: no dots.
        let quiet = BotRowSummary(runsOn: runsOn, home: idle, tasks: [])
        #expect(quiet.dots.isEmpty && quiet.more == 0 && quiet.subtitle == runsOn && quiet.spokenDots.isEmpty)
        // Three idle tasks: three rings.
        let open = BotRowSummary(runsOn: runsOn, home: idle, tasks: [idle, idle, idle])
        #expect(open.dots == [.idle, .idle, .idle] && open.more == 0 && open.subtitle == runsOn && open.spokenDots == "3 idle")
        // One of them working: its dot first, and the subtitle as it was.
        let one = BotRowSummary(runsOn: runsOn, home: idle, tasks: [idle, working, idle])
        #expect(one.dots == [.working, .idle, .idle] && one.subtitle == runsOn && one.spokenDots == "1 working, 2 idle")
        // Only Home working: its dot, never its activity.
        let home = BotRowSummary(runsOn: runsOn, home: working, tasks: [idle])
        #expect(home.dots == [.working, .idle] && home.subtitle == runsOn && home.spokenDots == "1 working, 1 idle")
        // Many: at most eight dots (#359), the most urgent first (#218), in tab order among equals, then +N.
        let busy = BotRowSummary(runsOn: runsOn, home: .failed(at: now), tasks: [
            working, .preparing, idle, .news(pullRequest: 1, at: now), working, .starting(since: now),
            idle, working, .news(pullRequest: 2, at: now),
        ])
        #expect(busy.dots == [.failed, .working, .preparing, .working, .starting, .working, .news, .news])
        #expect(busy.more == 2)
        #expect(busy.subtitle == runsOn)
        #expect(busy.spokenDots == "1 failed, 1 preparing, 1 starting, 3 working, 2 finished, 2 idle")
        // Eight fill the row exactly: no +N.
        let eight = BotRowSummary(runsOn: runsOn, home: idle, tasks: Array(repeating: working, count: 8))
        #expect(eight.dots == Array(repeating: .working, count: 8) && eight.more == 0 && eight.spokenDots == "8 working")
    }

    /// #218: a full row keeps its urgent dots, however late their tabs come, and counts the rest.
    @Test func aFullRowKeepsItsUrgentDotsAndCountsTheRest() {
        let working = TabState.working(.coding, since: now)
        let asking = TabState.needsInput(requests: 1, at: now)
        let runsOn = "Claude Dev · default"
        let row = BotRowSummary(runsOn: runsOn, home: .news(pullRequest: nil, at: now), tasks: [
            working, working, working, .idle(since: now), working, .idle(since: now), working, .stopped(at: now), asking,
        ])
        #expect(row.dots == [.needsInput, .stopped, .working, .working, .working, .working, .working, .news])
        #expect(row.more == 2)
        #expect(row.spokenDots == "1 needs input, 1 stopped, 5 working, 1 finished, 2 idle")
        // What waits on the owner leads the dots, never the subtitle (#324).
        #expect(row.subtitle == runsOn)
        let two = BotRowSummary(runsOn: runsOn, home: asking, tasks: [.needsInput(requests: 2, at: now)])
        #expect(two.subtitle == runsOn && two.dots == [.needsInput, .needsInput] && two.spokenDots == "2 need input")
        // An idle Home has no dot, and idle tasks are rings, however many are open.
        let quiet = BotRowSummary(runsOn: runsOn, home: .idle(since: now), tasks: [.idle(since: now), .idle(since: nil)])
        #expect(quiet.dots == [.idle, .idle] && quiet.more == 0 && quiet.spokenDots == "2 idle")
    }

    /// #250: a collapsed heading, such as the sidebar's Specialists, shows its bots' dots together:
    /// the most urgent first, at most eight (#359), then +N counting the rest and each row's own +N.
    @Test func aCollapsedHeadingShowsItsBotsDotsTogether() {
        let working = TabState.working(.coding, since: now)
        let idle = BotRowSummary(runsOn: "Claude Dev · default", home: .idle(since: now), tasks: [])
        let thinking = BotRowSummary(runsOn: "Codex Work · default", home: working, tasks: [])
        let asking = BotRowSummary(runsOn: "Claude Dev · default", home: .needsInput(requests: 1, at: now), tasks: [working])
        let quiet = BotRowSummary(merging: [("Mike", idle)])
        #expect(quiet.dots.isEmpty && quiet.more == 0 && quiet.spokenDots.isEmpty)
        let two = BotRowSummary(merging: [("Mike", idle), ("David", thinking), ("Ann", asking)])
        #expect(two.dots == [.needsInput, .working, .working])
        #expect(two.more == 0)
        #expect(two.spokenDots == "David: 1 working; Ann: 1 needs input, 1 working")
        let full = BotRowSummary(runsOn: "Claude Dev · default", home: working, tasks: Array(repeating: working, count: 9))
        #expect(full.dots.count == 8 && full.more == 2)
        let many = BotRowSummary(merging: [("David", thinking), ("Ann", full), ("Bea", asking)])
        #expect(many.dots == [.needsInput] + Array(repeating: .working, count: 7))
        #expect(many.more == 3 + 2)
        // A bot's idle tasks are rings there too, after the others' busy dots (#324).
        let resting = BotRowSummary(runsOn: "Claude Dev · default", home: .idle(since: now), tasks: [.idle(since: now)])
        let mixed = BotRowSummary(merging: [("Mike", resting), ("David", thinking)])
        #expect(mixed.dots == [.working, .idle] && mixed.spokenDots == "Mike: 1 idle; David: 1 working")
    }

    /// #237: a bot row's dots are its tabs' own states, never others. For every Home with every
    /// pair of tasks, and for rows with more than eight busy tabs, the dots and +N count exactly the
    /// open tasks and Home while it isn't idle (#324), kind for kind, the most urgent first, and the
    /// tooltip names them all; answering a request, then reading the finished turn, changes the
    /// row's dot as the tab's.
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
        let kinds: [TabState.Kind] = [.needsInput, .failed, .stopped, .preparing, .starting, .working, .news, .idle]
        for (home, tasks) in rows {
            let row = BotRowSummary(runsOn: "Claude Dev · default", home: home, tasks: tasks)
            let shown = ([home].filter { $0.kind != .idle } + tasks).map(\.kind)
            let label = "Home \(home.kind), tasks \(tasks.map(\.kind))"
            #expect(row.dots.count + row.more == shown.count, "\(label)")
            #expect(row.dots.map(\.urgency) == Array(shown.map(\.urgency).sorted(by: >).prefix(BotRowSummary.dotLimit)), "\(label): \(row.dots)")
            #expect(row.spokenDots.isEmpty == shown.isEmpty, "\(label)")
            for kind in kinds {
                let count = shown.filter { $0 == kind }.count
                // None made up or recoloured, and the tooltip counts those past the eighth too.
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
            let row = BotRowSummary(runsOn: "Claude Dev · default", home: .idle(since: nil), tasks: [state])
            #expect(row.dots == [state.kind])
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

    @Test func savedAndDraggedColumnWidthsStayWithinTheReadableRange() {
        typealias Layout = ConversationColumnLayout
        #expect(Layout.clamped(Layout.width) == Layout.width)
        for (requested, expected) in [(-Double.infinity, 200.0), (0, 200), (56, 200), (199, 200),
                                      (200, 200), (240, 240), (260, 260), (320, 320), (500, 320), (.infinity, 320)] {
            #expect(Layout.clamped(requested) == expected)
            // A saved width can be restored and used as the start of the next drag unchanged.
            #expect(Layout.clamped(Layout.clamped(requested)) == expected)
        }
    }
}
