import Foundation
import Testing
@testable import BotChuCore

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("botchu-areas-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// Project Areas (#399, #400): the model, the one owner of a repository, moving an area to another
/// bot, hiding it, and the launch migration of open tasks.
@Suite struct AreaTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let fox = Bot(name: "Product Fox", emoji: "🦊", accountID: "codex-work", model: "gpt-6-luna", reasoningEffort: .medium,
                  workspace: "/Users/a/BOTS/product-fox")
    let tenX = Bot(name: "10x Engineer Bot", emoji: "🛠️", accountID: "claude-work", model: "opus", reasoningEffort: .high,
                   workspace: "/Users/a/BOTS/10x")

    func openTask(_ repo: String, of bot: Bot, at offset: TimeInterval = 0) -> BotTask {
        var task = BotTask(for: bot, repo: repo, checkout: "/w/\(TaskNaming.repoName(repo))", work: nil, brief: "Tidy", branch: "feat/tidy")
        task.folder = "/w/\(TaskNaming.repoName(repo))/.claude/worktrees/feat-tidy"
        task.createdAt = date.addingTimeInterval(offset)
        return task
    }

    @Test func aRepoAreaIsATaskInItsCheckoutWithoutABranch() {
        let area = BotTask(repoArea: "asieke/GitChu", checkout: "/w/GitChu", for: fox, at: date)
        #expect(area.isArea && area.area == AreaInfo(kind: .repo, name: "GitChu", attachedAt: date))
        #expect(area.title == "GitChu" && area.repo == "asieke/GitChu")
        #expect(area.branch.isEmpty && area.folder == area.checkout && area.work == nil && area.brief.isEmpty)
        #expect(area.accountID == "codex-work" && area.model == "gpt-6-luna" && area.reasoningEffort == .medium)
        #expect(!area.makesWorktree)
        let folder = BotTask(folderArea: "Taxes 2027", folder: "/Users/a/BOTS/product-fox/areas/taxes-2027", for: fox, at: date)
        #expect(folder.area?.kind == .folder && folder.title == "Taxes 2027" && folder.repo.isEmpty)
        #expect(folder.folder == folder.checkout && !folder.makesWorktree)
        #expect(openTask("a/b", of: fox).makesWorktree && !openTask("a/b", of: fox).isArea)
        #expect(TaskNaming.title(area: AreaInfo(kind: .repo, name: "BotChu")) == "BotChu")
    }

    @Test func anAreaRoundTripsAndAnOldTaskDecodesAsATask() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BotHome(workspace: root.path)
        let area = BotTask(repoArea: "asieke/BotChu", checkout: "/w/BotChu", for: fox, at: date)
        try home.save(area)
        #expect(try Store.decoder.decode(BotTask.self, from: Store.encoder.encode(area)) == area)
        #expect(home.loadTasks() == [area])
        // A task.json from before areas has no `area` key.
        let old = UUID()
        try FileManager.default.createDirectory(at: home.taskURL(old), withIntermediateDirectories: true)
        try #"{"accountID":"codex-work","branch":"feat/x","checkout":"/w/GitChu","createdAt":"2027-01-15T08:00:00Z","id":"\#(old.uuidString)","model":"","origin":"owner","repo":"asieke/GitChu","title":"GitChu · X","brief":"X"}"#
            .write(to: home.taskURL(old).appendingPathComponent("task.json"), atomically: true, encoding: .utf8)
        let loaded = home.loadTasks()
        #expect(loaded.count == 2)
        let legacy = try #require(loaded.first { $0.id == old })
        #expect(legacy.area == nil && !legacy.isArea && legacy.makesWorktree)
    }

    @Test func areasListInAttachOrderAndARepoHasOneOwner() {
        let later = BotTask(repoArea: "asieke/GitChu", checkout: "/w/GitChu", for: fox, at: date.addingTimeInterval(60))
        var moved = BotTask(repoArea: "asieke/rowchuk", checkout: "/w/rowchuk", for: fox, at: date.addingTimeInterval(-600))
        moved.area?.attachedAt = date.addingTimeInterval(120)
        let first = BotTask(folderArea: "Notes", folder: "/x/notes", for: fox, at: date)
        let task = openTask("asieke/GitChu", of: fox)
        #expect(Areas.areas(in: [task, moved, later, first]).map(\.id) == [first.id, later.id, moved.id])

        var hidden = BotTask(repoArea: "asieke/BotChu", checkout: "/w/BotChu", for: tenX, at: date)
        hidden.archivedAt = date
        let bots: [(botID: UUID, tasks: [BotTask])] = [(fox.id, [task, later, first]), (tenX.id, [hidden, openTask("asieke/mono-mac", of: tenX)])]
        #expect(Areas.owner(of: "asieke/gitchu", among: bots)?.botID == fox.id)
        #expect(Areas.owner(of: "asieke/GitChu", among: bots)?.area.id == later.id)
        // Hidden areas own their repository too; open tasks and folder areas own nothing.
        #expect(Areas.owner(of: "asieke/BotChu", among: bots)?.botID == tenX.id)
        #expect(Areas.owner(of: "asieke/mono-mac", among: bots) == nil)
        #expect(Areas.owner(of: "", among: bots) == nil)
    }

    /// #402: Col 2 lists the open areas in attach order, each with its repository's open tasks
    /// indented under it, then the other open tasks and job runs flat; hidden areas apart.
    @Test func theColumnNestsTasksUnderTheirAreaAndListsHiddenAreasApart() {
        let botchu = BotTask(repoArea: "asieke/BotChu", checkout: "/w/BotChu", for: fox, at: date)
        let notes = BotTask(folderArea: "Kalshi 15m Crypto", folder: "/b/areas/kalshi-15m-crypto", for: fox, at: date.addingTimeInterval(60))
        var hidden = BotTask(repoArea: "asieke/laser-city", checkout: "/w/laser-city", for: fox, at: date.addingTimeInterval(30))
        hidden.archivedAt = date
        let inBotChu = openTask("asieke/botchu", of: fox, at: -60)
        let elsewhere = openTask("asieke/GitChu", of: fox, at: -30)
        var closed = openTask("asieke/BotChu", of: fox, at: 10)
        closed.archivedAt = date
        let daily = Job(botID: fox.id, title: "Daily", prompt: "Triage.",
                        schedule: JobSchedule(kind: .daily, hour: 6, minute: 6, timeZone: JobScheduleTests.newYork))
        let job = JobTasks.task(for: fox, job: daily, run: JobRun(trigger: .manual, scheduledFor: nil, timeZone: JobScheduleTests.newYork, reservedAt: date),
                                startedAt: date.addingTimeInterval(20))
        let layout = ProjectAreasLayout(tasks: [inBotChu, elsewhere, notes, closed, job, hidden, botchu])
        typealias Row = ProjectAreasLayout.Row
        #expect(layout.rows == [Row(id: botchu.id, isArea: true, nested: false), Row(id: inBotChu.id, isArea: false, nested: true),
                                Row(id: notes.id, isArea: true, nested: false),
                                Row(id: elsewhere.id, isArea: false, nested: false), Row(id: job.id, isArea: false, nested: false)])
        #expect(layout.hidden == [hidden.id])
        // A bot with no tasks has only Home.
        #expect(ProjectAreasLayout(tasks: []).rows.isEmpty && ProjectAreasLayout(tasks: []).hidden.isEmpty)
        // A hidden area's tasks list flat.
        #expect(ProjectAreasLayout(tasks: [hidden, openTask("asieke/laser-city", of: fox)]).rows.map(\.nested) == [false])
    }

    /// #402: a row dragged onto a bot carries its bot and area, and nothing else reads as one.
    @Test func aDraggedAreaCarriesItsBotAndItself() {
        let bot = UUID(), area = UUID()
        let dragged = Areas.draggedArea(Areas.dragPayload(botID: bot, areaID: area))
        #expect(dragged?.botID == bot && dragged?.areaID == area)
        #expect(Areas.draggedArea(BotSections.dragPayload(bot)) == nil)
        #expect(Areas.draggedArea(Data("not/an area".utf8)) == nil && Areas.draggedArea(nil) == nil)
    }

    /// #402: an area's row names it, and says its repository or its `~` folder.
    @Test func anAreasTabNamesItAndItsPlace() {
        let repo = ConversationTab(task: BotTask(repoArea: "asieke/BotChu", checkout: "/w/BotChu", for: fox, at: date), machine: nil, state: .idle(since: nil))
        #expect(repo.area == .repo && repo.name == "BotChu" && repo.title == "BotChu" && repo.subject == "asieke/BotChu")
        #expect(repo.help(shortcut: "⌘2") == "asieke/BotChu\nasieke/BotChu · This Mac · ⌘2")
        let folder = ConversationTab(task: BotTask(folderArea: "Kalshi 15m Crypto", folder: NSHomeDirectory() + "/BOTS/t/areas/kalshi-15m-crypto",
                                                   for: fox, at: date), machine: nil, state: .idle(since: nil))
        #expect(folder.area == .folder && folder.title == "Kalshi 15m Crypto" && folder.subject == "~/BOTS/t/areas/kalshi-15m-crypto")
        #expect(ConversationTab.abbreviated("/Users/ab", home: "/Users/a") == "/Users/ab")
        #expect(ConversationTab(task: openTask("a/b", of: fox), machine: nil, state: .idle(since: nil)).area == nil)
    }

    /// #402: open areas stay, so the bot's row shows a dot for one only while it isn't idle, as for Home.
    @Test func aBotsRowShowsAnAreaOnlyWhileItIsNotIdle() {
        let idle = TabState.idle(since: date), working = TabState.working(.coding, since: date)
        let row = BotRowSummary(runsOn: "x", home: idle, areas: [idle, working, idle], tasks: [idle])
        #expect(row.dots == [.working, .idle] && row.spokenDots == "1 working, 1 idle")
        #expect(BotRowSummary(runsOn: "x", home: idle, areas: [idle, idle], tasks: []).dots.isEmpty)
    }

    @Test func folderAreasGetASlugFolderInTheWorkspace() {
        #expect(Areas.slug("Taxes 2027: the Ranch!") == "taxes-2027-the-ranch")
        #expect(Areas.slug("Café ☕️") == "cafe")
        #expect(Areas.slug("☕️") == "area")
        let workspace = "/Users/a/BOTS/product-fox"
        #expect(Areas.folder(named: "Notes", workspace: workspace, taken: []) == "/Users/a/BOTS/product-fox/areas/notes")
        #expect(Areas.folder(named: "Notes", workspace: workspace, taken: ["/Users/a/BOTS/product-fox/areas/notes"])
                == "/Users/a/BOTS/product-fox/areas/notes-2")
    }

    @Test func anAreaMovesOnlyWhileNothingRunsInIt() {
        let area = BotTask(repoArea: "asieke/GitChu", checkout: "/w/GitChu", for: fox, at: date)
        #expect(Areas.moveProblem(area, from: fox, to: tenX, running: false, activeSubagents: 0) == nil)
        #expect(Areas.moveProblem(area, from: fox, to: tenX, running: true, activeSubagents: 0) != nil)
        #expect(Areas.moveProblem(area, from: fox, to: tenX, running: false, activeSubagents: 1) != nil)
        #expect(Areas.moveProblem(area, from: fox, to: fox, running: false, activeSubagents: 0) != nil)
        #expect(Areas.moveProblem(openTask("a/b", of: fox), from: fox, to: tenX, running: false, activeSubagents: 0) != nil)
        var specialist = tenX
        specialist.role = .specialist
        #expect(Areas.moveProblem(area, from: fox, to: specialist, running: false, activeSubagents: 0) != nil)
    }

    @Test func aMovedAreaIsTheNewBotsWithItsTranscriptAndRunsAndNoSession() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var fox = fox, tenX = tenX
        fox.workspace = root.appendingPathComponent("fox").path
        tenX.workspace = root.appendingPathComponent("10x").path
        let source = BotHome(workspace: fox.workspace), destination = BotHome(workspace: tenX.workspace)
        var area = BotTask(repoArea: "asieke/GitChu", checkout: "/w/GitChu", for: fox, at: date)
        area.sessionID = "s1"
        area.sessionAccountID = "codex-work"
        try source.save(area)
        let thread = [ChatMessage(role: .user, text: "Scope #48", date: date), ChatMessage(role: .assistant, text: "Scoped.", date: date)]
        try source.saveThread(thread, task: area.id)
        let run = SubagentRun(rootBotID: fox.id, rootTaskID: area.id, depth: 1, targetBot: tenX, title: "#48", brief: "Fix #48",
                              workingDirectory: "/w/GitChu", phase: .completed, createdAt: date)
        try source.saveSubagent(run)
        try source.saveSubagentThread([ChatMessage(role: .assistant, text: "Done", date: date)], id: run.id, taskID: area.id)

        let moved = Areas.moved(area, to: tenX, at: date.addingTimeInterval(60))
        #expect(moved.accountID == "claude-work" && moved.model == "opus" && moved.reasoningEffort == .high)
        #expect(moved.sessionID == nil && moved.sessionAccountID == nil && moved.area?.attachedAt == date.addingTimeInterval(60))
        try Areas.move(moved, from: source, to: destination, botID: tenX.id)

        #expect(source.loadTasks().isEmpty && !FileManager.default.fileExists(atPath: source.taskURL(area.id).path))
        #expect(destination.loadTasks() == [moved])
        #expect(destination.loadThread(task: area.id) == thread)
        let runs = destination.loadSubagents(taskID: area.id)
        #expect(runs.map(\.id) == [run.id] && runs.first?.rootBotID == tenX.id)
        #expect(destination.loadSubagentThread(id: run.id, taskID: area.id).map(\.text) == ["Done"])
        // A folder already there for it is never overwritten.
        try source.save(area)
        #expect(throws: (any Error).self) { try Areas.move(moved, from: source, to: destination, botID: tenX.id) }
        #expect(destination.loadThread(task: area.id) == thread)
    }

    @Test func theLaunchGivesEachRepoOneAreaUnderTheFirstBotOnce() throws {
        let a = openTask("o/r", of: fox, at: 0), b = openTask("o/r", of: tenX, at: -60)
        var closed = openTask("o/closed", of: fox)
        closed.archivedAt = date
        var review = openTask("o/review", of: fox)
        review.review = .review
        let job = Job(botID: fox.id, title: "Daily", prompt: "Look.", schedule: JobSchedule(kind: .daily, hour: 6, minute: 0, timeZone: "UTC"))
        let run = JobRun(trigger: .manual, scheduledFor: nil, timeZone: "UTC", reservedAt: date)
        var jobTask = JobTasks.task(for: fox, job: job, run: run, startedAt: date)
        jobTask.repo = "o/job"
        var remote = openTask("o/remote", of: tenX)
        remote.hostID = UUID()
        let other = openTask("o/other", of: tenX)
        var specialist = Bot(name: "Duck", emoji: "🦆", workspace: "/Users/a/BOTS/duck")
        specialist.role = .specialist
        let duckTask = openTask("o/duck", of: specialist)

        var bots: [(bot: Bot, tasks: [BotTask])] = [(fox, [a, closed, review, jobTask]), (tenX, [b, remote, other]), (specialist, [duckTask])]
        let made = Areas.migrations(bots, at: date)
        #expect(made.map(\.botID) == [fox.id, tenX.id])
        #expect(made.map(\.area.repo) == ["o/r", "o/other"])
        #expect(made[0].area.checkout == a.checkout && made[0].area.folder == a.checkout && made[0].area.isArea)
        #expect(made[0].area.accountID == fox.accountID && made[1].area.accountID == tenX.accountID)
        #expect(Areas.areas(in: [made[1].area, made[0].area]).map(\.id) == made.map(\.area.id))

        bots[0].tasks.append(made[0].area)
        bots[1].tasks.append(made[1].area)
        #expect(Areas.migrations(bots, at: date.addingTimeInterval(60)).isEmpty)
        // A hidden area still owns its repository.
        bots[0].tasks[bots[0].tasks.count - 1].archivedAt = date
        #expect(Areas.migrations(bots, at: date.addingTimeInterval(60)).isEmpty)
    }

    @Test func anAreaTurnIsToldItWorksInTheCheckoutAndNeverChangesIt() {
        let area = BotTask(repoArea: "asieke/GitChu", checkout: "/w/GitChu", for: fox, at: date)
        let preamble = BotContext.taskPreamble(bot: fox, task: area, memory: "", sharedMemory: "", history: [])
        #expect(preamble.contains("in the main checkout of asieke/GitChu at /w/GitChu"))
        #expect(preamble.contains("never switch a branch, edit or commit in it"))
        #expect(preamble.contains("`botchu-subagent` children"))
        #expect(preamble.contains("/w/GitChu/.claude/worktrees/<type>-<slug>"))
        #expect(preamble.contains("Project Area “GitChu”"))
        #expect(!preamble.contains("which BotChu made (or reopened) for this task"))
        let folder = BotTask(folderArea: "Notes", folder: "/x/notes", for: fox, at: date)
        let folderPreamble = BotContext.taskPreamble(bot: fox, task: folder, memory: "", sharedMemory: "", history: [])
        #expect(folderPreamble.contains("You are in /x/notes, the folder of your Project Area “Notes”"))

        let run = SubagentRun(rootBotID: fox.id, rootTaskID: area.id, depth: 1, targetBot: tenX, title: "#48", brief: "Fix #48",
                              workingDirectory: "/w/GitChu")
        let child = BotContext.subagentPreamble(bot: tenX, run: run, callerDescription: "Product Fox", memory: "", sharedMemory: "",
                                                areaCheckout: "/w/GitChu")
        #expect(child.contains("You start in the main checkout at /w/GitChu"))
        #expect(!BotContext.subagentPreamble(bot: tenX, run: run, callerDescription: "Product Fox", memory: "", sharedMemory: "")
            .contains("You start in the main checkout"))
    }
}
